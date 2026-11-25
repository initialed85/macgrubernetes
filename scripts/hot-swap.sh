#!/usr/bin/env bash

# Emergency swap of a bundled binary on a darwin node. The measured reason this script
# exists is NODE-MAINTENANCE.md: ~/.macgrubernetes/bin is a symlink into
# releases/<tag>/bin, so `cp x bin/maclet` rewrites a released build's bytes in place;
# truncating a live linker-signed Mach-O breaks its code signature pages and macOS
# kills every exec (DiagnosticReports say CODESIGNING "Invalid Page"). cp to .new,
# ad-hoc sign, atomic mv; nothing else. Prefer installing a fresh release via
# install.sh - a hot-swap edits a release that should match its published checksum.

set -euo pipefail

name=${1:-}
src=${2:-}
mode=${3:-}

usage() {
    printf 'usage: hot-swap.sh <binary-name> <staged-source-path> [--no-kickstart]\n' >&2
    printf 'run on the node; stages into ~/.macgrubernetes/bin via copy+codesign+mv\n' >&2
}

case "$name" in ""|-h|--help) usage; exit 1 ;; esac
[[ -n "$src" && -f "$src" ]] || { usage; printf 'hot-swap: staged source missing or not a file: %s\n' "${src:-<none>}" >&2; exit 1; }
[[ "$mode" == "--no-kickstart" || -z "$mode" ]] || { usage; exit 1; }

install_dir=${MACGRUBER_INSTALL_DIR:-$HOME/.macgrubernetes}
bin_dir="$install_dir/bin"

# Resolve the live path once so the rename happens in the directory the entry lives in
# (the release dir behind the symlink): mv within a directory replaces the directory
# entry and leaves the old inode - and any running exec through it - alone.
live_dir=$(cd "$bin_dir" && pwd -P)
[[ -f "$live_dir/$name" ]] || { printf 'hot-swap: no live binary at %s/%s\n' "$bin_dir" "$name" >&2; exit 1; }

printf 'hot-swap: source %s sha256 %s\n' "$src" "$(shasum -a 256 "$src" | awk '{print $1}')"
cp "$src" "$live_dir/$name.new"
codesign -f -s - "$live_dir/$name.new"
codesign -v "$live_dir/$name.new"
mv "$live_dir/$name.new" "$live_dir/$name"
installed_sha=$(shasum -a 256 "$bin_dir/$name" | awk '{print $1}')
printf 'hot-swap: installed %s/%s sha256 %s\n' "$bin_dir" "$name" "$installed_sha"

# Provenance pairing (macker's rule, adopted here): a binary sha256 alone cannot certify a
# green lifecycle stage - codesign -s - changes the bytes, so the installed hash is not the
# CI artifact hash and is certainly not a source commit. Record timestamp, component, the
# staged source hash, the installed hash, and the source commit/build tag together.
# Set MACGRUB_PROVENANCE_REF='<component> <build-tag> <commit>' when swapping anything built
# from a repo; without it the swap is logged as unattributed and the next audit can't map it.
ref=${MACGRUB_PROVENANCE_REF:-}
[[ -n "$ref" ]] || printf 'hot-swap: WARNING MACGRUB_PROVENANCE_REF unset - recording unattributed swap\n' >&2
printf '%s\t%s\tsource-sha256=%s\tinstalled-sha256=%s\tref=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" \
    "$(shasum -a 256 "$src" | awk '{print $1}')" "$installed_sha" \
    "${ref:-<unknown>}" >> "$install_dir/provenance.log"

if [[ "$mode" != "--no-kickstart" ]]; then
    label=cc.initialed85.$name
    launchctl kickstart -k "system/$label" || \
        printf 'hot-swap: kickstart system/%s failed - is that the right LaunchDaemon label?\n' "$label" >&2
    # launchd ThrottleInterval is 30s: a kickstart right after a kill is throttled.
    printf 'hot-swap: swapped and kicked %s; wait ~45s before trusting status checks\n' "$name"
fi
