#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command git
[[ -f "$MACGRUBER_LOCKFILE" ]] || die "component lockfile not found: $MACGRUBER_LOCKFILE"

mkdir -p "$MACGRUBER_BUILD_ROOT/src"

while IFS='|' read -r component repository pattern tag commit remainder; do
    [[ -z "${component//[[:space:]]/}" ]] && continue
    [[ "$component" == \#* ]] && continue
    [[ -n "${remainder:-}" ]] && die "invalid lockfile entry for $component"
    [[ -n "$repository" && -n "$pattern" && -n "$tag" && -n "$commit" ]] || die "incomplete lockfile entry for $component"

    case "$component" in
        maclet|macker|darwin-vxlan) ;;
        *) die "unknown component in lockfile: $component" ;;
    esac

    destination="$MACGRUBER_BUILD_ROOT/src/$component"
    if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
        die "component destination exists but is not a Git checkout: $destination"
    fi
    if [[ ! -d "$destination/.git" ]]; then
        log "cloning $component from $repository"
        git clone "$repository" "$destination"
    fi

    if [[ -n "$(git -C "$destination" status --porcelain)" ]]; then
        die "refusing to update dirty component checkout: $destination"
    fi

    git -C "$destination" remote set-url origin "$repository"
    log "fetching $component tag=$tag"
    git -C "$destination" fetch --prune origin "refs/tags/$tag:refs/tags/$tag"
    tag_commit=$(git -C "$destination" rev-parse "$tag^{commit}" 2>/dev/null || true)
    [[ "$tag_commit" == "$commit" ]] || die "$component tag $tag resolves to ${tag_commit:-nothing}, expected $commit"
    git -C "$destination" checkout --detach --quiet "$commit"

    actual=$(git -C "$destination" rev-parse HEAD)
    [[ "$actual" == "$commit" ]] || die "$component checked out $actual, expected $commit"
    log "ready $component $tag @ ${actual:0:12}"
done < "$MACGRUBER_LOCKFILE"
