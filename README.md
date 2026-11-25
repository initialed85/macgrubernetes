# Macgrubernetes

![macgruber](./macgruber.png)

> Native macOS workloads in Kubernetes, somehow.

Macgrubernetes is the integration and packaging project for running trusted
native Darwin workloads on Apple Silicon and Intel Macs as part of a Kubernetes cluster. It does
not try to reproduce Linux container isolation on macOS. Instead, it combines a
Darwin node agent, a native-process workload runtime, and a Flannel-compatible
network transport into one reproducible release.

The source remains split across focused repositories:

| Component | Role | Repository |
| --- | --- | --- |
| `maclet` | Kubernetes node agent and native workload reconciler | [initialed85/maclet](https://github.com/initialed85/maclet) |
| `macker` | Trusted native Darwin workload runtime | [initialed85/macker](https://github.com/initialed85/macker) |
| `darwin-vxlan` | macOS vmnet-backed Flannel-compatible VXLAN transport | [initialed85/darwin-vxlan](https://github.com/initialed85/darwin-vxlan) |
| `longhorn-nfs-gateway` | Optional cluster-side Longhorn-to-generic-NFS gateway | [initialed85/longhorn-storage-gateway](https://github.com/initialed85/longhorn-storage-gateway) |

Macgrubernetes pins compatible component release tags and commits in
[`components.lock`](components.lock), pulls those revisions, builds the binaries
together, and assembles a release bundle. This repository intentionally contains
integration tooling and release artifacts rather than copies of the component
source trees.

## Requirements

Supported release targets are Darwin/arm64 on Apple Silicon and Darwin/amd64
(x86_64) on Intel Macs. Catalina/Intel support is experimental: GitHub Actions
cross-builds and natively tests the amd64 artifact on a newer Intel macOS
runner, but the actual Catalina/vmnet behavior must be validated on hardware.
The amd64 bundle deliberately uses a Go 1.22 toolchain, Skopeo 1.18, and a
10.15 deployment target because newer Go/Skopeo releases emit newer minimum
macOS versions. The Catalina darwin-vxlan build omits macOS 11-only vmnet
network-isolation APIs and therefore has weaker concurrent-bridge isolation.
Building requires:

- macOS with the required `vmnet` entitlement/privilege setup for the network
  transport
- Bash and Git
- Go 1.26.5 or newer
- Rust/Cargo with `aarch64-apple-darwin` or `x86_64-apple-darwin`, depending on
  the selected target

The resulting binaries are trusted native processes. They share the host
kernel, filesystem dependencies, and network stack according to the behavior
documented by their component repositories.

## Quick start

Fetch the exact revisions recorded by the integration lockfile:

```sh
make sync
```

Run component unit tests, vet Go code, and run the mocked VXLAN test suite:

```sh
make test
```

Build the Darwin/arm64 binaries into `.build/bin` (including the bundled
registry client):

```sh
make build
```

Build the Darwin/amd64 bundle into `.build/amd64`:

```sh
make build-amd64
```

The amd64 bundle is intended for Intel Macs, including the experimental Catalina
path. Its binaries are built with a 10.15 deployment target; it still requires
runtime validation of Catalina's vmnet privileges and behavior.

Create a release archive under `dist/`:

```sh
make package VERSION=0.1.0
```

The package contains the four runtime executables, including the bundled
Skopeo registry client, an optional cluster-side Longhorn gateway deployment,
and a launch wrapper:

```text
macgrubernetes-<version>-darwin-<arm64|amd64>/
├── macgrubernetes.sh
├── components.lock
├── VERSION
├── macgruber.png
└── bin/
    ├── maclet
    ├── macker
    ├── darwin-vxlan
    ├── skopeo
    └── policy.json
└── gateway/
    ├── deploy/
    ├── config/
    ├── README.md
    ├── COMPONENT-README.md
    └── handoff.md
```

After extracting the archive, start the packaged agent with:

```sh
cd macgrubernetes-<version>-darwin-<arm64|amd64>
./macgrubernetes.sh
```

The wrapper resolves sensible defaults without requiring paths into the source
checkouts:

- binaries are resolved relative to the extracted archive
- state defaults to `${HOME}/.maclet`
- the API server is read from the current `kubectl` context when available;
  set `MACGRUBER_SERVER` or pass `--server` to avoid that optional lookup
- the node IP, ExternalIP, and VXLAN local address are read from the default
  route interface using `ipconfig getifaddr`
- the VXLAN remote defaults to the API server host
- maclet obtains its K3s controller client certificate with the join token,
  so peer discovery does not require a kubeconfig or `kubectl`; set
  `MACGRUBER_PEER_KUBECONFIG` only for an explicit peer-credential override or
  privileged cleanup/leave operations
- if a bundled executable retains macOS quarantine metadata, the wrapper warns
  and uses `sudo` to remove quarantine only from the binaries it will run
- a token is read from `MACGRUBER_TOKEN_FILE` or
  `${HOME}/.macgrubernetes/token` when present (the underlying `MACLET_TOKEN`
  environment variable is also inherited); a token is only required for a
  first join, not when existing `${HOME}/.maclet` state is reused
- the packaged Skopeo client and its default policy are passed to Macker so
  missing Darwin images can be pulled without a separate Homebrew install;
  set `MACGRUBER_SKOPEO_POLICY` or `CONTAINERS_POLICY_JSON` to use a stricter
  policy

The API server is the only operational value the wrapper cannot reliably invent.
Set `MACGRUBER_SERVER` or pass `--server` when it cannot be obtained from the
optional `kubectl` lookup. All normal maclet flags can be appended to the wrapper command and
override generated defaults. Common environment overrides include
`MACGRUBER_INTERFACE`, `MACGRUBER_NODE_IP`, `MACGRUBER_EXTERNAL_IP`,
`MACGRUBER_VXLAN_LOCAL`, `MACGRUBER_VXLAN_REMOTE`, `MACGRUBER_NODE_NAME`, and
`MACGRUBER_STATE_DIR`.

To unregister an installed node, stop the running agent first and use the
launcher’s leave command. It reuses the persisted state and peer kubeconfig:

```sh
${HOME}/.macgrubernetes/macgrubernetes.sh leave
```

Pass maclet’s leave options when needed, for example
`--kubeconfig /path/to/admin-kubeconfig --context home-dev`.

## Optional Longhorn gateway

Build 40 and later include the pinned cluster-side
`longhorn-nfs-gateway` v0.1.2 deployment artifacts. In the default `auto`
mode, the Macgrubernetes launcher installs or updates the owned gateway once
per cluster; use `MACGRUBER_GATEWAY_MODE=never` to disable this lifecycle, or
`required` to fail startup if installation cannot be completed. The launcher
removes only gateway-owned resources when the last native node leaves and
never deletes PVCs, PVs, or Longhorn volumes. An existing gateway namespace is
adopted only when it carries the Macgrubernetes ownership marker.

To install the bundled manifests manually:

```sh
kubectl apply -k ${HOME}/.macgrubernetes/gateway/deploy
```

Create an export after creating a Longhorn PVC by copying and editing the
bundled sample:

```sh
cp ${HOME}/.macgrubernetes/gateway/config/samples/longhornnfsexport.yaml /tmp/longhorn-export.yaml
# edit /tmp/longhorn-export.yaml
kubectl apply -f /tmp/longhorn-export.yaml
```

The gateway owns only its CRD, controller, helper workloads, Services,
ConfigMaps, NetworkPolicies, and RBAC. It never deletes PVCs or PVs. Follow
`${HOME}/.macgrubernetes/gateway/README.md` for the required deletion order:
delete gateway exports and wait for finalizers before removing the controller
and CRD.

```sh
kubectl delete longhornnfsexports.storage.k8s-darwin.dev --all --all-namespaces
kubectl delete -k ${HOME}/.macgrubernetes/gateway/deploy
```

RWO and RWX Longhorn paths have separate acceptance requirements; review the
gateway documentation before using it with production storage. A ready export
publishes the generic handoff annotations `nfs-server`, `nfs-export`,
`nfs-version`, `nfs-mount-port`, `nfs-port`, and `nfs-generation`. Gateway
mounts use macOS's canonical `mount_nfs -L -P -T -3` flags with the advertised
NFS and mountd ports; direct `nfs.csi.k8s.io` PV mount options are not changed.
If a native Pod uses `subPath`, that directory must already exist below the
export root (for example, `/export/usr/share/nginx/html`); otherwise the Pod
remains Pending with a missing-subPath diagnostic.

## Install the latest release

On a supported Apple Silicon or Intel Mac, install the matching latest
non-prerelease release with the cheeky one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/initialed85/macgrubernetes/master/scripts/install.sh | bash
```

The installer detects `arm64` or `x86_64`, selects the matching release
archive, verifies its checksum, and stores downloads, versioned releases, and
stable launch links under `${HOME}/.macgrubernetes`. It prints the
exact command to run when installation finishes. Set `MACGRUBER_INSTALL_DIR`
when a different location is required:

```sh
curl -fsSL https://raw.githubusercontent.com/initialed85/macgrubernetes/master/scripts/install.sh \\
  | MACGRUBER_INSTALL_DIR="$HOME/opt/macgrubernetes" bash
```

The installed launcher is then available at:

```sh
${HOME}/.macgrubernetes/macgrubernetes.sh
```

## Local component development

For active work in sibling checkouts, avoid copying or committing component
source into this repository. Use local mode instead:

```sh
make test-local
make build-local
```

By default local mode looks for sibling repositories next to this checkout:

```text
Projects/Home/
├── macgrubernetes/
├── maclet/
├── macker/
└── darwin-vxlan/
```

A different source root or individual checkout can be supplied explicitly:

```sh
MACGRUBER_SOURCE_ROOT=/path/to/components make build-local
MACLET_SOURCE=/path/to/maclet make test-local
```

Local mode never changes or checks out component branches. Locked mode uses
`.build/src/` and checks out the exact commits from `components.lock`.

## Updating the integration set

The lockfile records a repository URL, the tag-selection rule, the selected tag,
and the immutable commit used for the build. `scripts/update.sh` understands the
release conventions used by the component repositories:

- `maclet` and `macker`: highest numeric `build-N` tag
- `darwin-vxlan`: highest stable `vX.Y.Z` tag

Update one component, then sync and test the resulting integration set:

```sh
make update COMPONENT=maclet
make sync
make test
```

To update every component:

```sh
make update
make sync
make test
```

Review the resulting `components.lock` diff as an integration change. Builds
never follow a moving branch without recording the resolved release tag and
commit.

maclet `build-69` (c4f4427): maclet master sat at build-68's 2a321d5 while `1eab383`
(the lifecycle-stage honesty change - reject falsified mechanism claims in Pod status)
existed only as a dangling detached-HEAD object. build-69 is the first tag whose checkout
carries the stage script, so `test-native-workload-lifecycle.sh` must run from a checkout
at build-69 or later.

maclet `build-71` (8304a4c) on darwin, measured on the real agent host (icarus-2, go1.26.5
darwin/arm64): full `go test ./pkg/maclet/` suite **3/3 green** and
`TestNodeHeartbeatRecordsRenewedNodeAndLease` 10/10 green in isolation, so bundle CI
pipeline 1375's heartbeat failure (fake-API round exceeding the test's 30ms schedule, log
lines 49-51) is an environment flake, not a build-71 defect. One trap for anyone running
maclet's suite over a bare ssh session on the node: maclet shells out to `sysctl`, which
lives in `/sbin`, so a PATH without `/usr/sbin:/sbin` fails
`TestReadNodeWorkingSetOnDarwin` with "sysctl: executable file not found" - a harness
artifact, not a maclet bug.

Do-not-select tags (they exist upstream, they are valid builds, and they must not be
pinned): macker `build-33` (dee408c) and `build-34` (fe460eb) put the retracted false
kernel claim - "this kernel does not register the null filesystem at all" - in the
Pod-facing `reason` that maclet copies verbatim into Pod status (measured live on
icarus-2: a refused :ro Pod's Pending message contained that exact sentence); fe460eb's
test even asserts the phrase, test-locking the wrong claim. macker `build-35` (7468fd2)
and `build-36` (da1138e) additionally carry the false "ENOTSUP" guidance wording. The
correct text lands at ff7b159-onward. macker `build-40` (2250a51) is stale rather than
false-poisoned: its guidance reports the bindfs entitlement refusal as a measured fact,
which the node measurement falsified - bindfs draws ENODEV, the name is unregistered - so
treat 40 as superseded, and build-41 as the first tag whose operator-facing text is the
measured truth. No released bundle ever pinned 35/36: only the never-cut build-62
candidate lock touched 36. Any swap must verify the installed build's `guidance` against
the acceptance markers in NODE-MAINTENANCE.md before citing a green lifecycle result.

## Hot-swapping a binary on a darwin node

`~/.macgrubernetes/bin` is a symlink into `releases/<tag>/bin`, so writing through it
rewrites a released build's bytes in place; on macOS that codesign-kills the binary
(`CODESIGNING … "Invalid Page"` crash reports, maclet's 2026-11-25 incident on icarus-2).
The rules and the sanctioned procedure - copy to `.new`, `codesign -f -s -`, atomic `mv`,
kickstart with a ThrottleInterval wait - are in `NODE-MAINTENANCE.md`, and
`scripts/hot-swap.sh` (shipped in the release) performs them. A hot-swap is an emergency
path: it makes the installed release stop matching its published checksum, and the
release archive plus its `.sha256` asset are then the only source of truth for restoring
the original bytes.

## Continuous integration

GitHub Actions runs `make test` and `make build` for both Darwin/arm64 and
Darwin/amd64 on every push and pull request. The arm64 job uses an Apple Silicon
runner; the amd64 job uses an Intel macOS runner and exercises the x86_64 build
path. The pinned component commits in `components.lock` are validated for both
architectures.

The release workflow first runs `scripts/update.sh`, so each master/manual
release couples the latest tagged `maclet`, `macker`, and `darwin-vxlan` revisions
available at that run. It then tests, builds, packages, and uploads both
architecture archives before publishing a `build-${{ github.run_number }}`
GitHub release. Pull requests build and upload both artifacts but do not publish
a release.

## Repository boundaries

The component repositories remain independently testable and releasable:

- `macker` can be used as a native workload runtime without Kubernetes.
- `maclet` can be developed and tested against a cluster independently of the
  release packaging.
- `darwin-vxlan` owns the low-level macOS networking implementation and its
  mocked transport tests.

Macgrubernetes is the release train that proves a selected set of those
components work together. A future unified command may supervise the same
processes, but separate executables and subprocesses are intentional for now.
