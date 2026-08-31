#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command git
[[ -f "$MACGRUBER_LOCKFILE" ]] || die "component lockfile not found: $MACGRUBER_LOCKFILE"

requested=${COMPONENT:-${1:-}}
updated=0

latest_tag() {
    local repository=$1
    local pattern=$2
    local selected

    case "$pattern" in
        build-*)
            selected=$(git ls-remote --tags --refs "$repository" "refs/tags/build-*" | awk '
                $2 ~ /^refs\/tags\/build-[0-9]+$/ {
                    tag = $2
                    sub(/^refs\/tags\//, "", tag)
                    number = substr(tag, 7) + 0
                    if (!found || number > best) {
                        found = 1
                        best = number
                        best_tag = tag
                    }
                }
                END {
                    if (found) print best_tag
                }
            ')
            ;;
        vX.Y.Z)
            selected=$(git ls-remote --tags --refs "$repository" "refs/tags/v*" | awk '
                $2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ {
                    tag = $2
                    sub(/^refs\/tags\//, "", tag)
                    version = substr(tag, 2)
                    split(version, parts, ".")
                    major = parts[1] + 0
                    minor = parts[2] + 0
                    patch = parts[3] + 0
                    if (!found || major > best_major ||
                        (major == best_major && minor > best_minor) ||
                        (major == best_major && minor == best_minor && patch > best_patch)) {
                        found = 1
                        best_major = major
                        best_minor = minor
                        best_patch = patch
                        best_tag = tag
                    }
                }
                END {
                    if (found) print best_tag
                }
            ')
            ;;
        *)
            die "unsupported tag pattern $pattern (use build-* or vX.Y.Z)"
            ;;
    esac

    [[ -n "$selected" ]] || die "no tags matching $pattern found in $repository"

    local resolved
    resolved=$(git ls-remote --tags "$repository" "refs/tags/$selected" "refs/tags/$selected^{}" | awk -v tag="$selected" '
        $2 == "refs/tags/" tag "^{}" { peeled = $1 }
        $2 == "refs/tags/" tag { direct = $1 }
        END {
            if (peeled != "") print peeled
            else if (direct != "") print direct
        }
    ')
    [[ -n "$resolved" ]] || die "could not resolve tag $selected in $repository"
    printf '%s\t%s\n' "$selected" "$resolved"
}

while IFS='|' read -r component repository pattern tag commit remainder; do
    [[ -z "${component//[[:space:]]/}" ]] && continue
    [[ "$component" == \#* ]] && continue
    [[ -n "${remainder:-}" ]] && die "invalid lockfile entry for $component"
    [[ -n "$repository" && -n "$pattern" && -n "$tag" && -n "$commit" ]] || die "incomplete lockfile entry for $component"
    if [[ -n "$requested" && "$requested" != "$component" ]]; then
        continue
    fi

    resolved=$(latest_tag "$repository" "$pattern")
    IFS=$'\t' read -r resolved_tag resolved_commit <<< "$resolved"
    [[ -n "$resolved_tag" && -n "$resolved_commit" ]] || die "could not resolve $component tag"

    temporary=$(mktemp "${TMPDIR:-/tmp}/macgrubernetes-lock.XXXXXX")
    awk -F'|' -v OFS='|' -v target="$component" -v tag="$resolved_tag" -v commit="$resolved_commit" '
        $0 !~ /^[[:space:]]*#/ && $1 == target { $4 = tag; $5 = commit }
        { print }
    ' "$MACGRUBER_LOCKFILE" > "$temporary"
    mv "$temporary" "$MACGRUBER_LOCKFILE"
    log "updated $component: $tag @ ${commit:0:12} -> $resolved_tag @ ${resolved_commit:0:12}"
    updated=1
done < "$MACGRUBER_LOCKFILE"

if [[ -n "$requested" && "$updated" -eq 0 ]]; then
    die "component not found in lockfile: $requested"
fi
