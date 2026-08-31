# Macgrubernetes

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

Macgrubernetes pins compatible component commits in [`components.lock`](components.lock),
pulls those revisions, builds the binaries together, and assembles a release
bundle. This repository intentionally contains integration tooling and release
artifacts rather than copies of the component source trees.

## Requirements

The current target is Darwin/arm64 on Apple Silicon. Building requires:

- macOS with the required `vmnet` entitlement/privilege setup for the network
  transport
- Bash and Git
- Go 1.22 or newer
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

The package contains:

```text
macgrubernetes-<version>-darwin-arm64/
└── bin/
    ├── maclet
    ├── macker
    └── darwin-vxlan
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

The lockfile records a repository URL, the human-facing branch/tag reference,
and the immutable commit used for the build. To update one component to the
current remote revision of its locked ref:

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
must never follow a moving branch without recording its resolved commit.

## Continuous integration

GitHub Actions runs `make test` and `make build` on macOS for every push and
pull request. The workflow uses the commits pinned in `components.lock`, so a
lockfile update is exercised as a complete integration change.

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
