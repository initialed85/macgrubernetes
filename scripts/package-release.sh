#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

version=${VERSION:-${MACGRUBER_VERSION:-}}
[[ -n "$version" ]] || die "VERSION is required (for example: make package VERSION=0.1.0)"

bin_dir="$MACGRUBER_BUILD_ROOT/bin"
longhorn_nfs_gateway_source=$(component_source longhorn-nfs-gateway)
for binary in maclet macker darwin-vxlan skopeo; do
    [[ -x "$bin_dir/$binary" ]] || die "missing built binary: $bin_dir/$binary (run make build)"
done
[[ -f "$MACGRUBER_ROOT/skopeo-policy.json" ]] || die "missing bundled Skopeo policy: $MACGRUBER_ROOT/skopeo-policy.json"

require_command tar
require_command shasum

mkdir -p "$MACGRUBER_ROOT/dist"
staging=$(mktemp -d "${TMPDIR:-/tmp}/macgrubernetes-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT

package_name="macgrubernetes-$version-darwin-$MACGRUBER_PACKAGE_ARCH"
package_root="$staging/$package_name"
mkdir -p "$package_root/bin" "$package_root/gateway"
cp "$bin_dir/maclet" "$bin_dir/macker" "$bin_dir/darwin-vxlan" "$bin_dir/skopeo" "$package_root/bin/"

# Ad-hoc sign the bundled binaries. They arrive from `make build` already
# carrying the Go/Rust linker's ad-hoc signature, which is a CSSLOT blob
# appended to the end of the file with no LC_CODE_SIGNATURE load command
# pointing at it, so a load-command scan finds nothing and the signature is
# still real. That signature is destroyed by any post-link rewrite -- strip,
# lipo, install_name_tool -- and if a leg ever changes linker, buildmode or
# SDK the guarantee disappears, at which point Apple Silicon answers
# `Killed: 9` at exec instead of a clean error. Signing here makes it a
# property of the release rather than of the current toolchain, and it runs
# before the checksums below so the published .sha256 covers signed bytes.
if command -v codesign >/dev/null 2>&1; then
    for binary in maclet macker darwin-vxlan skopeo; do
        codesign --force --sign - "$package_root/bin/$binary"
    done
else
    echo "warning: no codesign on this host; bundling only the linker's own signature" >&2
fi

cp "$MACGRUBER_ROOT/skopeo-policy.json" "$package_root/bin/policy.json"
cp -R "$longhorn_nfs_gateway_source/deploy" "$package_root/gateway/"
cp -R "$longhorn_nfs_gateway_source/config" "$package_root/gateway/"
cp "$longhorn_nfs_gateway_source/README.md" "$package_root/gateway/COMPONENT-README.md"
cp "$longhorn_nfs_gateway_source/docs/handoff.md" "$package_root/gateway/"
cp "$longhorn_nfs_gateway_source/deploy/README.md" "$package_root/gateway/README.md"
cp "$MACGRUBER_ROOT/components.lock" "$package_root/"
cp "$MACGRUBER_ROOT/scripts/macgrubernetes.sh" "$package_root/macgrubernetes.sh"
chmod 0755 "$package_root/macgrubernetes.sh"
printf '%s\n' "$version" > "$package_root/VERSION"
if [[ -f "$MACGRUBER_ROOT/README.md" ]]; then
    cp "$MACGRUBER_ROOT/README.md" "$package_root/"
fi
if [[ -f "$MACGRUBER_ROOT/macgruber.png" ]]; then
    cp "$MACGRUBER_ROOT/macgruber.png" "$package_root/"
fi

archive="$MACGRUBER_ROOT/dist/$package_name.tar.gz"
tar -czf "$archive" -C "$staging" "$package_name"
(
    cd "$MACGRUBER_ROOT/dist"
    shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
)
log "created $archive"
