#!/usr/bin/env bash

set -euo pipefail

repository=${MACGRUBER_REPOSITORY:-initialed85/macgrubernetes}
home=${HOME:?HOME must be set}
install_dir=${MACGRUBER_INSTALL_DIR:-$home/.macgrubernetes}
download_dir="$install_dir/downloads"
release_dir="$install_dir/releases"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    cat <<'EOF'
Usage: install.sh

Downloads the latest Macgrubernetes Darwin/arm64 release into
${HOME}/.macgrubernetes. Set MACGRUBER_INSTALL_DIR to choose another location.
EOF
    exit 0
fi

case "$(uname -s)" in
    Darwin) ;;
    *)
        printf 'macgrubernetes: error: this installer requires macOS\n' >&2
        exit 1
        ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ;;
    *)
        printf 'macgrubernetes: error: this release is for Apple Silicon (arm64)\n' >&2
        exit 1
        ;;
esac

for command in curl shasum tar mktemp; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'macgrubernetes: error: required command not found: %s\n' "$command" >&2
        exit 1
    }
done

api_url="https://api.github.com/repos/$repository/releases/latest"
printf 'macgrubernetes: finding the latest release from %s\n' "$repository"
release_json=$(curl --fail --silent --show-error --location --retry 3 "$api_url")
tag=$(printf '%s\n' "$release_json" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[[ -n "$tag" ]] || {
    printf 'macgrubernetes: error: GitHub did not return a latest release tag\n' >&2
    exit 1
}
if [[ ! "$tag" =~ ^(build-[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf 'macgrubernetes: error: refusing unexpected release tag: %s\n' "$tag" >&2
    exit 1
fi

package_name="macgrubernetes-$tag-darwin-arm64"
archive_name="$package_name.tar.gz"
checksum_name="$archive_name.sha256"
mkdir -p "$download_dir" "$release_dir"
archive="$download_dir/$archive_name"
checksum="$download_dir/$checksum_name"

printf 'macgrubernetes: downloading %s\n' "$tag"
curl --fail --silent --show-error --location --retry 3 \
    -o "$archive" \
    "https://github.com/$repository/releases/download/$tag/$archive_name"
curl --fail --silent --show-error --location --retry 3 \
    -o "$checksum" \
    "https://github.com/$repository/releases/download/$tag/$checksum_name"
(
    cd "$download_dir"
    shasum -a 256 -c "$checksum_name"
)

staging=$(mktemp -d "${TMPDIR:-/tmp}/macgrubernetes-install.XXXXXX")
cleanup() {
    rm -rf "$staging"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$staging"
package_root="$staging/$package_name"
for path in \
    "$package_root/macgrubernetes.sh" \
    "$package_root/bin/maclet" \
    "$package_root/bin/macker" \
    "$package_root/bin/darwin-vxlan" \
    "$package_root/bin/skopeo" \
    "$package_root/bin/policy.json"; do
    [[ -e "$path" ]] || {
        printf 'macgrubernetes: error: release archive is missing %s\n' "$path" >&2
        exit 1
    }
done

installed_release="$release_dir/$tag"
rm -rf "$installed_release"
mv "$package_root" "$installed_release"

# Keep stable paths while retaining downloaded archives and versioned releases
# underneath ~/.macgrubernetes. Remove any pre-existing flat-install paths so a
# previous installer layout cannot swallow the replacement symlink into a bin/
# directory.
replace_link() {
    local link=$1
    local target=$2
    local temporary_link="$install_dir/.$link.new"
    rm -rf "$temporary_link"
    ln -s "$target" "$temporary_link"
    rm -rf "$install_dir/$link"
    mv "$temporary_link" "$install_dir/$link"
}

replace_link macgrubernetes.sh "releases/$tag/macgrubernetes.sh"
replace_link bin "releases/$tag/bin"
for link in components.lock README.md VERSION macgruber.png; do
    [[ -e "$installed_release/$link" ]] && replace_link "$link" "releases/$tag/$link"
done

printf '\n'
printf 'Macgrubernetes %s installed in %s\n\n' "$tag" "$install_dir"
printf '%s\n' "Here's how you run it:"
printf '  %s/macgrubernetes.sh\n\n' "$install_dir"
printf '%s\n' 'For a debug start with an explicit cluster API server:'
printf '  MACGRUBER_SERVER=https://your-k3s-server:6443 %s/macgrubernetes.sh --debug\n' "$install_dir"
printf '\n'
printf '%s\n' 'The launcher will discover the local interface, kubeconfig, peer context, and bundled binaries.'
