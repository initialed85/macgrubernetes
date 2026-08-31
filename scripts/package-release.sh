#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

version=${VERSION:-${MACGRUBER_VERSION:-}}
[[ -n "$version" ]] || die "VERSION is required (for example: make package VERSION=0.1.0)"

bin_dir="$MACGRUBER_BUILD_ROOT/bin"
for binary in maclet macker darwin-vxlan; do
    [[ -x "$bin_dir/$binary" ]] || die "missing built binary: $bin_dir/$binary (run make build)"
done

require_command tar
require_command shasum

mkdir -p "$MACGRUBER_ROOT/dist"
staging=$(mktemp -d "${TMPDIR:-/tmp}/macgrubernetes-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT

package_name="macgrubernetes-$version-darwin-arm64"
package_root="$staging/$package_name"
mkdir -p "$package_root/bin"
cp "$bin_dir/maclet" "$bin_dir/macker" "$bin_dir/darwin-vxlan" "$package_root/bin/"
cp "$MACGRUBER_ROOT/components.lock" "$package_root/"
printf '%s\n' "$version" > "$package_root/VERSION"
if [[ -f "$MACGRUBER_ROOT/README.md" ]]; then
    cp "$MACGRUBER_ROOT/README.md" "$package_root/"
fi

archive="$MACGRUBER_ROOT/dist/$package_name.tar.gz"
tar -czf "$archive" -C "$staging" "$package_name"
(
    cd "$MACGRUBER_ROOT/dist"
    shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
)
log "created $archive"
