#!/usr/bin/env bash

set -euo pipefail

repository=${MACGRUBER_REPOSITORY:-initialed85/macgrubernetes}
home=${HOME:?HOME must be set}
install_dir=${MACGRUBER_INSTALL_DIR:-$home/.macgrubernetes}
download_dir="$install_dir/downloads"
release_dir="$install_dir/releases"
pin_file="$install_dir/pin"

# --release <tag> and MACGRUBER_RELEASE both pin this run; MACGRUBER_NO_PIN=1 or
# --no-pin installs without recording the pin.
want_tag=${MACGRUBER_RELEASE:-}
record_pin=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<'EOF'
Usage: install.sh [--release <tag>] [--no-pin]

Installs a Macgrubernetes Darwin/arm64 or Darwin/amd64 release into
${HOME}/.macgrubernetes. The release is chosen in this order:

  1. --release <tag>, or MACGRUBER_RELEASE=<tag>
  2. the tag in ${HOME}/.macgrubernetes/pin, written on first install
  3. releases/latest

The pin exists so a node stays on the build it was verified against instead of
racing the release lane: every reinstall used to follow latest, and a zero-code
release moved latest from build-52 to build-53 while a node was being checked.
Pass --no-pin (or MACGRUBER_NO_PIN=1) to install without writing or honouring a
pin. Set MACGRUBER_INSTALL_DIR to choose another location.
EOF
            exit 0
            ;;
        --release)
            [[ $# -ge 2 ]] || {
                printf 'macgrubernetes: error: --release needs a tag\n' >&2
                exit 1
            }
            want_tag=$2
            shift 2
            ;;
        --release=*)
            want_tag=${1#*=}
            shift
            ;;
        --no-pin)
            record_pin=0
            shift
            ;;
        *)
            printf 'macgrubernetes: error: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done
[[ "${MACGRUBER_NO_PIN:-}" == 1 ]] && record_pin=0

case "$(uname -s)" in
    Darwin) ;;
    *)
        printf 'macgrubernetes: error: this installer requires macOS\n' >&2
        exit 1
        ;;
esac
case "$(uname -m)" in
    arm64|aarch64) package_arch=arm64 ;;
    x86_64|amd64) package_arch=amd64 ;;
    *)
        printf 'macgrubernetes: error: unsupported macOS architecture: %s\n' "$(uname -m)" >&2
        exit 1
        ;;
esac

for command in curl shasum tar mktemp; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'macgrubernetes: error: required command not found: %s\n' "$command" >&2
        exit 1
    }
done

tag=""
source_of=""
if [[ -n "$want_tag" ]]; then
    # An explicit request wins over the pin, and is itself recorded below, so a
    # deliberate `--release build-50` makes the node stay on build-50.
    tag=$want_tag
    source_of="an explicit request"
elif [[ -s "$pin_file" ]]; then
    tag=$(tr -d '[:space:]' < "$pin_file")
    source_of="the pin in $pin_file"
else
    api_url="https://api.github.com/repos/$repository/releases/latest"
    printf 'macgrubernetes: finding the latest release from %s\n' "$repository"
    release_json=$(curl --fail --silent --show-error --location --retry 3 "$api_url")
    tag=$(printf '%s\n' "$release_json" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [[ -n "$tag" ]] || {
        printf 'macgrubernetes: error: GitHub did not return a latest release tag\n' >&2
        exit 1
    }
    source_of="releases/latest"
fi
printf 'macgrubernetes: installing %s from %s\n' "$tag" "$source_of"
# The same shape test applies to every source, not just the API response: a pin
# file is a file, and it can be edited, truncated by a partial write, or pointed
# at something that is not a release. Downloading an arbitrary tag path is how a
# bad pin becomes a confusing 404 instead of a clear refusal.
if [[ ! "$tag" =~ ^(build-[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf 'macgrubernetes: error: refusing unexpected release tag: %s\n' "$tag" >&2
    printf 'macgrubernetes: expected build-<N> or vX.Y.Z; fix or remove %s\n' "$pin_file" >&2
    exit 1
fi

package_name="macgrubernetes-$tag-darwin-$package_arch"
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
    "$package_root/bin/policy.json" \
    "$package_root/gateway/deploy/kustomization.yaml"; do
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
for link in components.lock README.md VERSION macgruber.png gateway; do
    [[ -e "$installed_release/$link" ]] && replace_link "$link" "releases/$tag/$link"
done

printf '\n'
printf 'Macgrubernetes %s installed in %s\n\n' "$tag" "$install_dir"
if [[ "$record_pin" == 1 ]]; then
    # Written after the install succeeds, so a failed run cannot leave a pin to a
    # build that was never installed. This is the whole point of the file: the
    # version a node runs becomes a decision that is recorded, not a race.
    tmp_pin="$pin_file.new"
    printf '%s\n' "$tag" > "$tmp_pin"
    mv "$tmp_pin" "$pin_file"
    printf 'Pinned to %s in %s. Remove or edit that file, or pass --release <tag>, to move.\n\n' "$tag" "$pin_file"
else
    printf 'Not writing a pin (--no-pin). This node will follow releases/latest on the next install.\n\n'
fi
printf '%s\n' "Here's how you run it:"
printf '  %s/macgrubernetes.sh\n\n' "$install_dir"
printf '%s\n' 'For a debug start with an explicit cluster API server:'
printf '  MACGRUBER_SERVER=https://your-k3s-server:6443 %s/macgrubernetes.sh --debug\n' "$install_dir"
printf '\n'
printf '%s\n' 'The launcher will discover the local interface, kubeconfig, peer context, and bundled binaries.'
