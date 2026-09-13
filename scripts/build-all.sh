#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command go
require_command cargo

ensure_locked_sources

maclet_source=$(component_source maclet)
macker_source=$(component_source macker)
darwin_vxlan_source=$(component_source darwin-vxlan)
ensure_build_directories

log "building maclet ($MACGRUBER_GOOS/$MACGRUBER_GOARCH)"
(
    cd "$maclet_source"
    CGO_ENABLED=0 GOOS="$MACGRUBER_GOOS" GOARCH="$MACGRUBER_GOARCH" \
        GOTOOLCHAIN="$MACGRUBER_GO_TOOLCHAIN" \
        go build -trimpath -o "$MACGRUBER_BUILD_ROOT/bin/maclet" .
)

log "building macker ($MACGRUBER_GOOS/$MACGRUBER_GOARCH)"
(
    cd "$macker_source"
    CGO_ENABLED=0 GOOS="$MACGRUBER_GOOS" GOARCH="$MACGRUBER_GOARCH" \
        GOTOOLCHAIN="$MACGRUBER_GO_TOOLCHAIN" \
        go build -trimpath -o "$MACGRUBER_BUILD_ROOT/bin/macker" ./cmd/macker
)

log "building darwin-vxlan ($MACGRUBER_RUST_TARGET)"
rust_args=(build --release)
if [[ -n "$MACGRUBER_RUST_TARGET" ]]; then
    rust_args+=(--target "$MACGRUBER_RUST_TARGET")
fi
(
    cd "$darwin_vxlan_source"
    if [[ -n "$MACGRUBER_MACOSX_DEPLOYMENT_TARGET" ]]; then
        MACOSX_DEPLOYMENT_TARGET="$MACGRUBER_MACOSX_DEPLOYMENT_TARGET" cargo "${rust_args[@]}"
    else
        cargo "${rust_args[@]}"
    fi
)
if [[ -n "$MACGRUBER_RUST_TARGET" ]]; then
    darwin_vxlan_binary="$darwin_vxlan_source/target/$MACGRUBER_RUST_TARGET/release/darwin-vxlan"
else
    darwin_vxlan_binary="$darwin_vxlan_source/target/release/darwin-vxlan"
fi
[[ -x "$darwin_vxlan_binary" ]] || die "darwin-vxlan build did not produce $darwin_vxlan_binary"
cp "$darwin_vxlan_binary" "$MACGRUBER_BUILD_ROOT/bin/darwin-vxlan"

log "building bundled skopeo $MACGRUBER_SKOPEO_VERSION ($MACGRUBER_GOOS/$MACGRUBER_GOARCH)"
# Recent Go releases reject GOBIN for cross-compiled `go install` binaries.
# Let Go place the target binary under its architecture-specific GOPATH bin,
# then copy the result into the architecture-specific bundle directory.
skopeo_gopath=$(mktemp -d "${TMPDIR:-/tmp}/macgrubernetes-skopeo-gopath.XXXXXX")
cleanup_skopeo_gopath() {
    chmod -R u+w "$skopeo_gopath" 2>/dev/null || true
    rm -rf "$skopeo_gopath"
}
trap cleanup_skopeo_gopath EXIT
CGO_ENABLED=0 GOOS="$MACGRUBER_GOOS" GOARCH="$MACGRUBER_GOARCH" \
    GOTOOLCHAIN="$MACGRUBER_GO_TOOLCHAIN" \
    GOPATH="$skopeo_gopath" \
    go install -tags containers_image_openpgp \
    "$MACGRUBER_SKOPEO_MODULE/cmd/skopeo@$MACGRUBER_SKOPEO_VERSION"
skopeo_binary="$skopeo_gopath/bin/${MACGRUBER_GOOS}_${MACGRUBER_GOARCH}/skopeo"
if [[ ! -x "$skopeo_binary" ]]; then
    # Native Go installs use GOPATH/bin without an architecture suffix.
    skopeo_binary="$skopeo_gopath/bin/skopeo"
fi
[[ -x "$skopeo_binary" ]] || die "skopeo build did not produce a target binary"
cp "$skopeo_binary" "$MACGRUBER_BUILD_ROOT/bin/skopeo"

log "binaries written to $MACGRUBER_BUILD_ROOT/bin"
