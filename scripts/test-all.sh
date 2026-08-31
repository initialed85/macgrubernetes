#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_command go
require_command cargo

ensure_locked_sources

maclet_source=$(component_source maclet)
macker_source=$(component_source macker)
darwin_vxlan_source=$(component_source darwin-vxlan)

log "testing maclet"
(
    cd "$maclet_source"
    go test ./...
    go vet ./...
    formatted=$(gofmt -l .)
    [[ -z "$formatted" ]] || die "unformatted Go files in maclet:\n$formatted"
    if [[ -f test-native-workload-lifecycle.sh ]]; then
        bash -n test-native-workload-lifecycle.sh
    fi
)

log "testing macker"
(
    cd "$macker_source"
    go test ./...
    go vet ./...
    formatted=$(gofmt -l .)
    [[ -z "$formatted" ]] || die "unformatted Go files in macker:\n$formatted"
    if [[ -f test.sh ]]; then
        bash -n test.sh
    fi
)

log "testing darwin-vxlan with vmnet mock"
(
    cd "$darwin_vxlan_source"
    cargo fmt --all -- --check
    cargo test --features vmnet-mock
)

log "all component tests passed"
