# Macgrubernetes

![macgruber](./macgruber.png)

> Native macOS workloads in Kubernetes, somehow.

Macgrubernetes is the integration and packaging project for running trusted
native Darwin/Apple Silicon workloads as part of a Kubernetes cluster. It does
not try to reproduce Linux container isolation on macOS. Instead, it combines a
Darwin node agent, a native-process workload runtime, and a Flannel-compatible
network transport into one reproducible release.

The source remains split across focused repositories:

| Component | Role | Repository |
| --- | --- | --- |
| `maclet` | Kubernetes node agent and native workload reconciler | [initialed85/maclet](https://github.com/initialed85/maclet) |
| `macker` | Trusted native Darwin workload runtime | [initialed85/macker](https://github.com/initialed85/macker) |
| `darwin-vxlan` | macOS vmnet-backed Flannel-compatible VXLAN transport | [initialed85/darwin-vxlan](https://github.com/initialed85/darwin-vxlan) |

Macgrubernetes pins compatible component release tags and commits in
[`components.lock`](components.lock), pulls those revisions, builds the binaries
together, and assembles a release bundle. This repository intentionally contains
integration tooling and release artifacts rather than copies of the component
source trees.

## Requirements

The current target is Darwin/arm64 on Apple Silicon. Building requires:

- macOS with the required `vmnet` entitlement/privilege setup for the network
  transport
- Bash and Git
- Go 1.26.5 or newer
- Rust/Cargo with the `aarch64-apple-darwin` target

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

Build all three Darwin/arm64 binaries into `.build/bin`:

```sh
make build
```

Create a release archive under `dist/`:

```sh
make package VERSION=0.1.0
```

The package contains the three executables and a launch wrapper:

```text
macgrubernetes-<version>-darwin-arm64/
├── macgrubernetes.sh
├── components.lock
├── VERSION
├── macgruber.png
└── bin/
    ├── maclet
    ├── macker
    └── darwin-vxlan
```

After extracting the archive, start the packaged agent with:

```sh
cd macgrubernetes-<version>-darwin-arm64
./macgrubernetes.sh
```

The wrapper resolves sensible defaults without requiring paths into the source
checkouts:

- binaries are resolved relative to the extracted archive
- state defaults to `${HOME}/.maclet`
- the API server and peer context are read from the current `kubectl` context
  when available
- the node IP, ExternalIP, and VXLAN local address are read from the default
  route interface using `ipconfig getifaddr`
- the VXLAN remote defaults to the API server host
- peer kubeconfig defaults to `$KUBECONFIG` or `${HOME}/.kube/config`
- if a bundled executable retains macOS quarantine metadata, the wrapper warns
  and uses `sudo` to remove quarantine only from the binaries it will run
- a token is read from `MACGRUBER_TOKEN_FILE` or
  `${HOME}/.macgrubernetes/token` when present (the underlying `MACLET_TOKEN`
  environment variable is also inherited); a token is only required for a
  first join, not when existing `${HOME}/.maclet` state is reused

The API server is the only operational value the wrapper cannot reliably invent.
Set `MACGRUBER_SERVER` or pass `--server` when it cannot be obtained from
`kubectl`. All normal maclet flags can be appended to the wrapper command and
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

## Install the latest release

On an Apple Silicon Mac, install the latest non-prerelease release with the
cheeky one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/initialed85/macgrubernetes/master/scripts/install.sh | bash
```

The installer verifies the release checksum and stores downloads, versioned
releases, and stable launch links under `${HOME}/.macgrubernetes`. It prints the
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

## Continuous integration

GitHub Actions runs `make test` and `make build` on macOS for every push and
pull request. The normal CI workflow validates the commits pinned in
`components.lock`.

The release workflow first runs `scripts/update.sh`, so each master/manual
release couples the latest tagged `maclet`, `macker`, and `darwin-vxlan` revisions
available at that run. It then tests, builds, packages, uploads the archive, and
publishes a `build-${{ github.run_number }}` GitHub release. Pull requests build
and upload an artifact but do not publish a release.

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
