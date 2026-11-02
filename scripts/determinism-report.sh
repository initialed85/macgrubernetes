#!/usr/bin/env bash
#
# Compare this build's bundle against the previous release and say whether the
# commit range gives a reason for any difference.
#
# Advisory by design. It prints a verdict and exits 0. A guard that blocks a
# release would see a runner toolchain upgrade as "binaries changed with no
# source change" and stop a release the repo did nothing to deserve, and a gate
# with a known false-positive rate gets disabled the first time it fires at
# someone at 2am. The point of this is to make silent non-determinism visible on
# every run so it can be promoted to a hard failure once it has been right about
# a few real changes.
#
# macgrubernetes contains no Go or Rust of its own. The binaries come from
# component checkouts pinned by components.lock, so that file is a
# binary-affecting input even though it looks like metadata, and the skopeo
# version and module live in scripts/build-all.sh.

set -euo pipefail

repo=${CI_REPO:-initialed85/macgrubernetes}
tag=${TAG:?TAG must be set to the release being reported on}
prev_tag=${PREV_TAG:-}
commit_before=${CI_COMMIT_BEFORE:-}
commit_after=${CI_COMMIT_AFTER:-}
# Where the git history lives, for blaming a difference on the commit range. The
# CI default is the workspace the build ran in; MACGRUBER_REPO_DIR lets the script
# be run against a downloaded bundle on its own, which is how it gets tested.
repo_dir=${MACGRUBER_REPO_DIR:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/macgruber-determinism.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The agent is macOS and has shasum, not sha256sum; this box is the other way
# round. Picking whichever exists is what lets the same script be tested here and
# run there, rather than discovering the difference in a release that is already
# published.
if command -v sha256sum >/dev/null 2>&1; then
    HASH=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    HASH=shasum
else
    printf 'determinism: no sha256 tool found, cannot compare\n'
    exit 0
fi
hash_file() {
    if [[ "$HASH" == sha256sum ]]; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Files whose bytes should only ever move when an input below moves with them.
bundle=(
    bin/maclet
    bin/macker
    bin/darwin-vxlan
    bin/skopeo
    bin/policy.json
    macgrubernetes.sh
    components.lock
    gateway/deploy/kustomization.yaml
    README.md
)

# An input that legitimately changes bundle bytes. Listing only the files the
# build actually consumes, rather than all of scripts/, is what keeps the check
# honest: install.sh and this script live in scripts/ too and cannot move a
# binary, so a blanket scripts/ rule would let any installer commit "explain" an
# unexplained difference. .woodpecker/ is deliberately absent, because the lane is
# not supposed to change bytes and a release that moves binaries with only a
# pipeline edit is exactly the thing worth flagging.
inputs_re='^(scripts/(build-all|sync-components|common|package-release)\.sh$|components\.lock$|Makefile$|skopeo-policy\.json$)'

hash_bundle() {
    local root=$1 file
    for file in "${bundle[@]}"; do
        if [[ -e "$root/$file" ]]; then
            printf '%s %s\n' "$(hash_file "$root/$file")" "$file"
        else
            printf 'missing %s\n' "$file"
        fi
    done
}

verdict_prefix="determinism:"

# Every path that cannot complete a comparison prints INCONCLUSIVE, never a bare
# "skipping". The first version of this script saved the download under a short
# name while the published .sha256 lists the real archive name, so verification
# could not find its file, every run reported "checksum failed; skipping" and
# exited 0, and the check would have looked like a pass while never comparing
# anything. A verdict that cannot be distinguished from silence is not a check.
if [[ -z "$prev_tag" ]]; then
    printf '%s INCONCLUSIVE - no previous tag given, nothing to compare against\n' "$verdict_prefix"
    exit 0
fi

# The previous release is fetched under its real name, because the published
# .sha256 lists that name and a checksum file is only usable against the filename
# it was written for.
prev_pkg="macgrubernetes-$prev_tag-darwin-arm64"
prev_archive="$prev_pkg.tar.gz"
if ! curl --fail --silent --show-error --location --retry 3 \
        -o "$work/$prev_archive" \
        "https://github.com/$repo/releases/download/$prev_tag/$prev_archive" ||
   ! curl --fail --silent --show-error --location --retry 3 \
        -o "$work/$prev_archive.sha256" \
        "https://github.com/$repo/releases/download/$prev_tag/$prev_archive.sha256"; then
    printf '%s INCONCLUSIVE - could not fetch %s, not reporting a difference\n' \
        "$verdict_prefix" "$prev_tag"
    exit 0
fi
if [[ "$HASH" == sha256sum ]]; then
    verify_out=$(cd "$work" && sha256sum -c "$prev_archive.sha256" 2>&1)
else
    verify_out=$(cd "$work" && shasum -a 256 -c "$prev_archive.sha256" 2>&1)
fi || {
    printf '%s INCONCLUSIVE - previous archive failed its checksum: %s\n' \
        "$verdict_prefix" "$verify_out"
    exit 0
}
tar -xzf "$work/$prev_archive" -C "$work" 2>/dev/null || {
    printf '%s INCONCLUSIVE - could not extract the previous archive\n' "$verdict_prefix"
    exit 0
}

current_root=${MACGRUBER_BUILD_ROOT:?MACGRUBER_BUILD_ROOT must be set}
if [[ ! -d "$current_root" ]]; then
    printf '%s INCONCLUSIVE - build root %s not found\n' "$verdict_prefix" "$current_root"
    exit 0
fi

hash_bundle "$current_root" > "$work/current.txt"
hash_bundle "$work/$prev_pkg" > "$work/previous.txt"

if diff -q "$work/current.txt" "$work/previous.txt" >/dev/null; then
    printf '%s bundle is byte-identical to %s across %s files\n' \
        "$verdict_prefix" "$prev_tag" "${#bundle[@]}"
    exit 0
fi

# `diff` exits 1 when the files differ, and with pipefail on that killed the
# script on precisely the path worth reporting -- the identical bundle printed a
# verdict and the differing one died silently with no output at all. The `|| true`
# has to sit inside the braces, or it belongs to the wrong stage of the pipeline.
# Field 3 is the filename: hash_bundle prints hash, then name.
changed=$( { diff "$work/previous.txt" "$work/current.txt" || true; } |
    { grep '^[<>]' || true; } | awk '{print $3}' | sort -u | tr '\n' ' ')

cause=unavailable
if [[ -z "$repo_dir" ]]; then
    repo_dir=$(cd "$current_root/../.." 2>/dev/null && pwd -P || true)
fi
if [[ -n "$commit_before" && -n "$commit_after" && "$commit_before" =~ ^[0-9a-f]{40}$ &&
      -n "$repo_dir" && -d "$repo_dir/.git" ]]; then
    # A shallow clone or a force-push can make the range unresolvable. That is not
    # the same as a range with no build inputs in it, and reporting it as UNEXPECTED
    # would send someone hunting for a cause that the checkout simply cannot show.
    if touched=$(git -C "$repo_dir" diff --name-only "$commit_before" "$commit_after" 2>/dev/null); then
        cause=resolved
    else
        touched=""
    fi
else
    touched=""
fi

if [[ "$cause" != resolved ]]; then
    printf '%s UNVERIFIED - bytes moved in [%s] and the commit range could not be resolved (shallow clone, force push, or CI vars unset). Not a verdict on the build, just a missing comparison.\n' \
        "$verdict_prefix" "$changed"
    printf '%s runner toolchain: %s / %s\n' "$verdict_prefix" \
        "$(go version 2>/dev/null || echo 'go not on PATH')" \
        "$(rustc -V 2>/dev/null || echo 'rustc not on PATH')"
elif [[ -z "$touched" ]]; then
    printf '%s UNEXPECTED - bytes moved in [%s] with an empty commit range. Nothing in this push explains it, so suspect the toolchain: %s / %s\n' \
        "$verdict_prefix" "$changed" \
        "$(go version 2>/dev/null || echo 'go not on PATH')" \
        "$(rustc -V 2>/dev/null || echo 'rustc not on PATH')"
else
    explain=$(printf '%s\n' "$touched" | grep -Ec "$inputs_re" || true)
    printf '%s bundle differs from %s in [%s]\n' "$verdict_prefix" "$prev_tag" "$changed"
    if [[ "$explain" -gt 0 ]]; then
        printf '%s explained: %s file(s) in the commit range are build inputs (%s)\n' \
            "$verdict_prefix" "$explain" "$(printf '%s\n' "$touched" | grep -E "$inputs_re" | tr '\n' ' ')"
    else
        printf '%s UNEXPECTED - %s files changed in the range, none of them build inputs: %s\n' \
            "$verdict_prefix" "$(printf '%s\n' "$touched" | grep -vc "$inputs_re" || true)" \
            "$(printf '%s\n' "$touched" | grep -v "$inputs_re" | tr '\n' ' ')"
    fi
fi
exit 0
