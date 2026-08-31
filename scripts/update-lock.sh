#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command git
[[ -f "$MACGRUBER_LOCKFILE" ]] || die "component lockfile not found: $MACGRUBER_LOCKFILE"

requested=${COMPONENT:-${1:-}}
updated=0

while IFS='|' read -r component repository ref commit remainder; do
    [[ -z "${component//[[:space:]]/}" ]] && continue
    [[ "$component" == \#* ]] && continue
    [[ -n "${remainder:-}" ]] && die "invalid lockfile entry for $component"
    if [[ -n "$requested" && "$requested" != "$component" ]]; then
        continue
    fi

    resolved=$(git ls-remote "$repository" "refs/heads/$ref" | awk 'NR == 1 { print $1 }')
    if [[ -z "$resolved" ]]; then
        resolved=$(git ls-remote "$repository" "$ref" | awk 'NR == 1 { print $1 }')
    fi
    [[ -n "$resolved" ]] || die "could not resolve $component ref $ref"

    temporary=$(mktemp "${TMPDIR:-/tmp}/macgrubernetes-lock.XXXXXX")
    awk -F'|' -v OFS='|' -v target="$component" -v resolved="$resolved" '
        $0 !~ /^[[:space:]]*#/ && $1 == target { $4 = resolved }
        { print }
    ' "$MACGRUBER_LOCKFILE" > "$temporary"
    mv "$temporary" "$MACGRUBER_LOCKFILE"
    log "updated $component $ref: ${commit:0:12} -> ${resolved:0:12}"
    updated=1
done < "$MACGRUBER_LOCKFILE"

if [[ -n "$requested" && "$updated" -eq 0 ]]; then
    die "component not found in lockfile: $requested"
fi
