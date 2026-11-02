#!/usr/bin/env bash
# Determinism report for the macgrubernetes release lane.
#
# Answers one question per release: did the bundle change, and if it did, is there a commit that explains it.
# Advisory, and it exits 0 whatever it finds.
#
# Why it exists. build-52 through build-57 have byte-identical bundles because the commits between them
# touched the installer and comments. That is only visible if someone compares releases by hand, and the
# failure mode worth catching is the opposite one: a bundle that moves with nothing in the repo to explain
# it. Two things can do that. A runner toolchain upgrade, since the lane pins no Go, Rust or clang and the
# darwin agent resolves image to a host binary, so a Homebrew go bump or an Xcode point release moves every
# binary while not one repo file differs. And a build script that picks up a floating dependency. Either
# would otherwise surface later as a node that cannot reproduce a release, on a Mac, with no clues.
#
# Why the two lists are derived rather than written out. An earlier version kept a hand-maintained list of
# bundle files and a hand-maintained allowlist of "binary-affecting" repo paths. Both rot, and they rot in
# the worst direction: the peer found that scripts/macgrubernetes.sh is copied into the bundle as the
# launcher and my allowlist missed it, so a legitimate launcher edit would have been reported as an
# unexplained bundle change. A hand list has to be remembered every time someone adds a cp line, and the
# failure mode when they forget is a check that blocks or misattributes real work. So:
#   - the bundle file list is the extracted tarball itself, so any file packaging adds is compared by default;
#   - every changed file in the commit range is an input, so nothing can be "missed" as non-affecting.
# The cost of the second is that a docs-only commit now "explains" a change. That is not a loss: the report
# prints the commits and the differing files, and the interesting verdict is the one that fires when the
# range is empty AND the toolchain is unchanged, which is genuine non-determinism and nothing else.
#
# Why advisory rather than a gate. A gate with a false-positive rate gets disabled the first time it fires on
# someone mid deploy, which is worse than no gate. It reports on every run instead, so it is never a
# safeguard that has only been seen declining to act, and every skip path prints a named verdict
# (INCONCLUSIVE or UNVERIFIED) rather than a bare "skipping", because a verdict indistinguishable from
# silence is not a check.
#
# Usage, from the release lane, where the build step has already written dist/ and .release/TAG:
#   TAG=$(cat .release/TAG) PREV_TAG=build-56 \
#   MACGRUBER_BUILD_ROOT=.det/current/macgrubernetes-$TAG-darwin-arm64 \
#   MACGRUBER_REPO_DIR=$CI_WORKSPACE bash scripts/determinism-report.sh
# The previous release is downloaded from the GitHub API, so the runner needs a token: CI_TOKEN or GH_TOKEN.

set -uo pipefail

API="https://api.github.com/repos/${CI_REPO:-initialed85/macgrubernetes}"
REPO_DIR="${MACGRUBER_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CURRENT_ROOT="${MACGRUBER_BUILD_ROOT:-}"
TAG="${TAG:-}"
PREV_TAG="${PREV_TAG:-}"
# VERSION holds the tag string, so it differs on every release by construction. It is excluded from the
# comparison rather than reported as a difference, which is the thing that would otherwise drown the signal.
EXCLUDE="VERSION"

if [ -z "$CURRENT_ROOT" ] || [ ! -d "$CURRENT_ROOT" ]; then
  echo "determinism: INCONCLUSIVE - no build root at '${MACGRUBER_BUILD_ROOT:-<unset>}', nothing compared"
  exit 0
fi
if [ -z "$PREV_TAG" ]; then
  echo "determinism: INCONCLUSIVE - no previous tag to compare against (first release, or the tag did not parse as build-N)"
  exit 0
fi
if [ -z "${CI_TOKEN:-${GH_TOKEN:-}}" ]; then
  echo "determinism: UNVERIFIED - no CI_TOKEN or GH_TOKEN, cannot download the previous release"
  exit 0
fi

# The previous tarball is downloaded, not rebuilt, so this reports what the last release shipped rather than
# what a fresh build of the last commit would produce. Those are the same thing only if the lane is
# reproducible, and that is the question, so it must not be assumed here.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
url=$(curl -sf "$API/releases/tags/$PREV_TAG" | grep -oE '"browser_download_url": *"[^"]*\.tar\.gz"' | sed -E 's/.*"(https[^"]*)"/\1/' | head -1)
if [ -z "$url" ]; then
  echo "determinism: INCONCLUSIVE - could not download $PREV_TAG, not reporting a difference"
  exit 0
fi
if ! curl -sfL "$url" -o "$tmp/prev.tar.gz"; then
  echo "determinism: INCONCLUSIVE - could not fetch $url"
  exit 0
fi
mkdir -p "$tmp/prev"
# GNU tar warns on stderr for every LIBARCHIVE.xattr header in a macOS-built archive, which is dozens of
# lines of noise for a known condition. The exit code is still what decides, so nothing is hidden here.
if ! tar -xzf "$tmp/prev.tar.gz" -C "$tmp/prev" 2>/dev/null; then
  echo "determinism: INCONCLUSIVE - could not unpack $PREV_TAG, not reporting a difference"
  exit 0
fi
prev_root=$(find "$tmp/prev" -maxdepth 2 -type d -name 'macgrubernetes-*' | head -1)
if [ -z "$prev_root" ]; then
  echo "determinism: INCONCLUSIVE - no package directory inside the $PREV_TAG tarball"
  exit 0
fi

# Bundle contents are the union of both trees, so a file that appeared or disappeared is a difference
# rather than a missing file. That is the whole point: an unexamined file is a silent hole. The earlier
# hand list compared 9 files of the 86 this actually walks, and missed the AppleDouble sidecars entirely.
#
# Built with a read loop, not mapfile: this step runs on the darwin agent, where image: bash resolves to
# the HOST binary, and macOS ships bash 3.2, which has no mapfile. A missing mapfile would have left the
# list empty, and the step's exit status is what publish depends on.
bundle_files=()
while IFS= read -r f; do
  [ -n "$f" ] && bundle_files+=("$f")
done < <(
  { (cd "$CURRENT_ROOT" && find . -type f | sed 's#^\./##'); (cd "$prev_root" && find . -type f | sed 's#^\./##'); } \
    | sort -u | grep -vxF "$EXCLUDE"
)
if [ ${#bundle_files[@]} -eq 0 ]; then
  echo "determinism: UNVERIFIED - walked both trees and found no files, which is not a comparison"
  exit 0
fi

sha256_of() {
  local f=$1
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}'; else shasum -a 256 "$f" | awk '{print $1}'; fi
}

diff_files=()
for f in "${bundle_files[@]}"; do
  # Both start empty, and absence is what empty means here. Writing cur=$prev=<sentinel> looked tidy and
  # died under set -u on the first iteration, because $prev was itself unbound at that point: exit 1 from
  # a step publish depends on.
  cur=""
  prev=""
  [ -f "$CURRENT_ROOT/$f" ] && cur=$(sha256_of "$CURRENT_ROOT/$f")
  [ -f "$prev_root/$f" ] && prev=$(sha256_of "$prev_root/$f")
  if [ "$cur" != "$prev" ]; then
    case "$f" in
      bin/*) kind=binary ;;
      *) kind=non-binary ;;
    esac
    diff_files+=("$kind $f")
  fi
done

# The toolchain asset is what separates "the host moved" from "the build is not reproducible". Older releases
# have no such file, so an absent toolchain comparison is stated, not assumed to be equal.
tc_now="dist/toolchain-$TAG.txt"
tc_prev_url=$(curl -sf "$API/releases/tags/$PREV_TAG" | grep -oE '"browser_download_url": *"[^"]*toolchain-[^"]*"' | sed -E 's/.*"(https[^"]*)"/\1/' | head -1)
tc_moved=unknown
if [ -n "$tc_prev_url" ] && curl -sfL "$tc_prev_url" -o "$tmp/prev-toolchain.txt" && [ -f "$tc_now" ]; then
  if diff -q "$tmp/prev-toolchain.txt" "$tc_now" >/dev/null 2>&1; then tc_moved=no; else tc_moved=yes; fi
fi

if [ ${#diff_files[@]} -eq 0 ]; then
  echo "determinism: bundle is byte-identical to $PREV_TAG across ${#bundle_files[@]} files"
  exit 0
fi

# Was there a commit range to blame? Empty means the same tree was built twice, which is the case that
# actually matters.
range_base=$(git -C "$REPO_DIR" rev-parse --verify "$PREV_TAG^{commit}" 2>/dev/null || true)
if [ -z "$range_base" ]; then
  echo "determinism: UNVERIFIED - $PREV_TAG is not resolvable in this checkout, so the report cannot say whether a commit explains the difference"
  for d in "${diff_files[@]}"; do echo "  changed: $d"; done
  exit 0
fi
changed=$(git -C "$REPO_DIR" log --oneline "$range_base..$TAG" 2>/dev/null || echo "")
n_changed=$(printf '%s' "$changed" | grep -c . || true)

printf 'determinism: %s differs from %s (%s files)\n' "$TAG" "$PREV_TAG" "${#diff_files[@]}"
for d in "${diff_files[@]}"; do echo "  changed: $d"; done
if [ "$tc_moved" = yes ]; then
  echo "determinism: TOOLCHAIN MOVED between $PREV_TAG and $TAG, which explains a bundle change with no source change"
  diff "$tmp/prev-toolchain.txt" "$tc_now" | sed 's/^/    /'
elif [ "$tc_moved" = no ]; then
  echo "determinism: toolchain recorded as unchanged between $PREV_TAG and $TAG"
else
  echo "determinism: toolchain comparison unavailable (no asset on $PREV_TAG, or none written this run), so the host is not ruled out"
fi
if [ "$n_changed" -eq 0 ]; then
  if [ "$tc_moved" = no ]; then
    echo "determinism: UNEXPECTED - the tree is identical to $PREV_TAG and the toolchain is unchanged, so the build is not reproducible"
  else
    echo "determinism: UNEXPECTED - no commit in $PREV_TAG..$TAG explains the difference"
  fi
  exit 0
fi
echo "determinism: explained by $n_changed commit(s) in $PREV_TAG..$TAG:"
printf '%s\n' "$changed" | sed 's/^/    /'
