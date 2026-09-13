#!/usr/bin/env bash

set -euo pipefail

MACGRUBER_ROOT=${MACGRUBER_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
MACGRUBER_LOCKFILE=${MACGRUBER_LOCKFILE:-"$MACGRUBER_ROOT/components.lock"}
MACGRUBER_BUILD_ROOT=${MACGRUBER_BUILD_ROOT:-"$MACGRUBER_ROOT/.build"}
MACGRUBER_SOURCE_MODE=${MACGRUBER_SOURCE_MODE:-locked}
MACGRUBER_SOURCE_ROOT=${MACGRUBER_SOURCE_ROOT:-"$MACGRUBER_ROOT/.."}
MACGRUBER_GOOS=${MACGRUBER_GOOS:-darwin}
MACGRUBER_GOARCH=${MACGRUBER_GOARCH:-arm64}
case "$MACGRUBER_GOARCH" in
    arm64)
        MACGRUBER_PACKAGE_ARCH=${MACGRUBER_PACKAGE_ARCH:-arm64}
        MACGRUBER_DEFAULT_RUST_TARGET=aarch64-apple-darwin
        MACGRUBER_DEFAULT_GO_TOOLCHAIN=local
        MACGRUBER_DEFAULT_SKOPEO_MODULE=go.podman.io/skopeo
        MACGRUBER_DEFAULT_SKOPEO_VERSION=v1.23.0
        ;;
    amd64)
        MACGRUBER_PACKAGE_ARCH=${MACGRUBER_PACKAGE_ARCH:-amd64}
        MACGRUBER_DEFAULT_RUST_TARGET=x86_64-apple-darwin
        MACGRUBER_DEFAULT_GO_TOOLCHAIN=go1.22.12
        MACGRUBER_DEFAULT_SKOPEO_MODULE=github.com/containers/skopeo
        MACGRUBER_DEFAULT_SKOPEO_VERSION=v1.18.0
        ;;
    *) printf 'macgrubernetes: error: MACGRUBER_GOARCH must be arm64 or amd64 (got: %s)\n' "$MACGRUBER_GOARCH" >&2; exit 1 ;;
esac
MACGRUBER_RUST_TARGET=${MACGRUBER_RUST_TARGET:-$MACGRUBER_DEFAULT_RUST_TARGET}
MACGRUBER_GO_TOOLCHAIN=${MACGRUBER_GO_TOOLCHAIN:-$MACGRUBER_DEFAULT_GO_TOOLCHAIN}
MACGRUBER_SKOPEO_MODULE=${MACGRUBER_SKOPEO_MODULE:-$MACGRUBER_DEFAULT_SKOPEO_MODULE}
MACGRUBER_SKOPEO_VERSION=${MACGRUBER_SKOPEO_VERSION:-$MACGRUBER_DEFAULT_SKOPEO_VERSION}
MACGRUBER_MACOSX_DEPLOYMENT_TARGET=${MACGRUBER_MACOSX_DEPLOYMENT_TARGET:-}
case "$MACGRUBER_BUILD_ROOT" in
    /*) ;;
    *) MACGRUBER_BUILD_ROOT="$MACGRUBER_ROOT/$MACGRUBER_BUILD_ROOT" ;;
esac

log() {
    printf 'macgrubernetes: %s\n' "$*"
}

die() {
    printf 'macgrubernetes: error: %s\n' "$*" >&2
    exit 1
}

case "$MACGRUBER_SOURCE_MODE" in
    locked|local) ;;
    *) die "MACGRUBER_SOURCE_MODE must be locked or local (got: $MACGRUBER_SOURCE_MODE)" ;;
esac

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

lock_value() {
    local component=$1
    local field=$2
    awk -F'|' -v component="$component" -v field="$field" '
        $0 !~ /^[[:space:]]*#/ && $1 == component {
            print $(field)
            exit
        }
    ' "$MACGRUBER_LOCKFILE"
}

component_source_override() {
    case "$1" in
        maclet) printf '%s\n' "${MACLET_SOURCE:-}" ;;
        macker) printf '%s\n' "${MACKER_SOURCE:-}" ;;
        darwin-vxlan) printf '%s\n' "${DARWIN_VXLAN_SOURCE:-}" ;;
        *) die "unknown component: $1" ;;
    esac
}

component_source() {
    local component=$1
    local override
    override=$(component_source_override "$component")
    if [[ -n "$override" ]]; then
        [[ -d "$override" ]] || die "$component source override does not exist: $override"
        (CDPATH= cd -- "$override" && pwd)
        return
    fi

    if [[ "$MACGRUBER_SOURCE_MODE" == local ]]; then
        local sibling="$MACGRUBER_SOURCE_ROOT/$component"
        [[ -d "$sibling" ]] || die "local component checkout not found: $sibling"
        (CDPATH= cd -- "$sibling" && pwd)
        return
    fi

    local fetched="$MACGRUBER_BUILD_ROOT/src/$component"
    [[ -d "$fetched" ]] || die "locked component is not synced: $component (run make sync)"
    (CDPATH= cd -- "$fetched" && pwd)
}

component_revision() {
    lock_value "$1" 5
}

component_tag() {
    lock_value "$1" 4
}

component_tag_pattern() {
    lock_value "$1" 3
}

component_url() {
    lock_value "$1" 2
}

ensure_locked_sources() {
    [[ "$MACGRUBER_SOURCE_MODE" == local ]] && return
    local component
    for component in maclet macker darwin-vxlan; do
        if [[ ! -d "$MACGRUBER_BUILD_ROOT/src/$component/.git" ]]; then
            "$MACGRUBER_ROOT/scripts/sync-components.sh"
            return
        fi
    done
}

ensure_build_directories() {
    mkdir -p "$MACGRUBER_BUILD_ROOT/bin" "$MACGRUBER_ROOT/dist"
}
