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
        go build -trimpath -o "$MACGRUBER_BUILD_ROOT/bin/maclet" .
)

log "building macker ($MACGRUBER_GOOS/$MACGRUBER_GOARCH)"
(
    cd "$macker_source"
    CGO_ENABLED=0 GOOS="$MACGRUBER_GOOS" GOARCH="$MACGRUBER_GOARCH" \
        go build -trimpath -o "$MACGRUBER_BUILD_ROOT/bin/macker" ./cmd/macker
)

log "building darwin-vxlan ($MACGRUBER_RUST_TARGET)"
rust_args=(build --release)
if [[ -n "$MACGRUBER_RUST_TARGET" ]]; then
    rust_args+=(--target "$MACGRUBER_RUST_TARGET")
fi
(
    cd "$darwin_vxlan_source"
    cargo "${rust_args[@]}"
)
if [[ -n "$MACGRUBER_RUST_TARGET" ]]; then
    darwin_vxlan_binary="$darwin_vxlan_source/target/$MACGRUBER_RUST_TARGET/release/darwin-vxlan"
else
    darwin_vxlan_binary="$darwin_vxlan_source/target/release/darwin-vxlan"
fi
[[ -x "$darwin_vxlan_binary" ]] || die "darwin-vxlan build did not produce $darwin_vxlan_binary"
cp "$darwin_vxlan_binary" "$MACGRUBER_BUILD_ROOT/bin/darwin-vxlan"

log "binaries written to $MACGRUBER_BUILD_ROOT/bin"
