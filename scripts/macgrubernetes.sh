#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [[ -n "${MACGRUBER_BIN_DIR:-}" ]]; then
    BIN_DIR=$MACGRUBER_BIN_DIR
elif [[ -x "$SCRIPT_DIR/bin/maclet" ]]; then
    BIN_DIR="$SCRIPT_DIR/bin"
else
    BIN_DIR="$SCRIPT_DIR/../.build/bin"
fi

home=${HOME:-}

has_flag() {
    local flag=$1
    shift
    local argument
    for argument in "$@"; do
        case "$argument" in
            "$flag"|"$flag"=*) return 0 ;;
        esac
    done
    return 1
}

argument_value() {
    local flag=$1
    shift
    while [[ $# -gt 0 ]]; do
        [[ "$1" == -- ]] && return 1
        case "$1" in
            "$flag")
                [[ $# -ge 2 ]] || return 1
                printf '%s\n' "$2"
                return 0
                ;;
            "$flag"=*)
                printf '%s\n' "${1#*=}"
                return 0
                ;;
        esac
        shift
    done
    return 1
}

command=join
if [[ "${1:-}" == leave ]]; then
    command=leave
    shift
elif [[ "${1:-}" == join ]]; then
    shift
fi

if [[ "$command" == leave ]] && (has_flag --help "$@" || has_flag -h "$@"); then
    cat <<'EOF'
Usage: macgrubernetes.sh leave [maclet leave options]

Unregisters the node, removes cluster-side credentials and networking metadata,
and deletes the local maclet state. Stop the running macgrubernetes agent first.
The leave-specific maclet options are passed through unchanged.
EOF
    exit 0
fi
if [[ "$command" == join ]] && (has_flag --help "$@" || has_flag -h "$@"); then
    cat <<'EOF'
Usage: macgrubernetes.sh [maclet join options]

Starts the packaged maclet agent with the bundled macker, darwin-vxlan, and
Skopeo executables. Native Darwin image pulls therefore do not require a
separate Homebrew installation. Use `macgrubernetes.sh leave` to unregister the
node. Environment
variables prefixed MACGRUBER_ override defaults; any maclet flags supplied here
are passed through and take precedence.
EOF
    exit 0
fi

state_dir=${MACGRUBER_STATE_DIR:-${home:+$home/.maclet}}
cli_state_dir=$(argument_value --state-dir "$@" || true)
[[ -n "$cli_state_dir" ]] && state_dir=$cli_state_dir
state_dir=${state_dir:-.maclet}
if [[ -n "$home" && "$state_dir" == "~/"* ]]; then
    state_dir="$home/${state_dir#\~/}"
fi

value_from_default_kubeconfig() {
    local kubeconfig=${MACGRUBER_KUBECONFIG:-${KUBECONFIG:-}}
    local kubectl_args=()
    if [[ -n "$kubeconfig" ]]; then
        kubectl_args+=(--kubeconfig "$kubeconfig")
    fi
    kubectl "${kubectl_args[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

current_kube_context() {
    local kubeconfig=${MACGRUBER_KUBECONFIG:-${KUBECONFIG:-}}
    local kubectl_args=()
    if [[ -n "$kubeconfig" ]]; then
        kubectl_args+=(--kubeconfig "$kubeconfig")
    fi
    kubectl "${kubectl_args[@]}" config current-context 2>/dev/null || true
}

server=${MACGRUBER_SERVER:-}
cli_server=$(argument_value --server "$@" || true)
[[ -n "$cli_server" ]] && server=$cli_server
if [[ -z "$server" ]] && command -v kubectl >/dev/null 2>&1; then
    server=$(value_from_default_kubeconfig)
fi
node_name=${MACGRUBER_NODE_NAME:-}
if [[ -f "$state_dir/state.json" ]]; then
    if [[ -z "$server" ]]; then
        server=$(sed -n 's/.*"server"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "$state_dir/state.json" | head -1)
    fi
    if [[ -z "$node_name" ]]; then
        node_name=$(sed -n 's/.*"nodeName"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "$state_dir/state.json" | head -1)
    fi
fi
if [[ "$command" == join && -z "$server" ]] && ! has_flag --server "$@"; then
    printf 'macgrubernetes: error: no Kubernetes API server found; set MACGRUBER_SERVER or pass --server\n' >&2
    exit 1
fi

interface=${MACGRUBER_INTERFACE:-}
if [[ -z "$interface" ]] && command -v route >/dev/null 2>&1; then
    interface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
fi
interface=${interface:-en0}

node_ip=${MACGRUBER_NODE_IP:-}
if [[ -z "$node_ip" ]] && command -v ipconfig >/dev/null 2>&1; then
    node_ip=$(ipconfig getifaddr "$interface" 2>/dev/null || true)
fi
external_ip=${MACGRUBER_EXTERNAL_IP:-$node_ip}
vxlan_local=${MACGRUBER_VXLAN_LOCAL:-$node_ip}

server_host=${server#*://}
server_host=${server_host%%/*}
server_host=${server_host%%:*}
vxlan_remote=${MACGRUBER_VXLAN_REMOTE:-$server_host}

default_kubeconfig=${home:+$home/.kube/config}
peer_kubeconfig=${MACGRUBER_PEER_KUBECONFIG:-${KUBECONFIG:-$default_kubeconfig}}
peer_context=${MACGRUBER_PEER_CONTEXT:-}
if [[ -z "$peer_context" ]] && command -v kubectl >/dev/null 2>&1; then
    peer_context=$(current_kube_context)
fi

maclet_binary=${MACGRUBER_MACLET_BINARY:-$BIN_DIR/maclet}
macker_binary=${MACGRUBER_MACKER_BINARY:-$BIN_DIR/macker}
# A release bundles Skopeo next to Macker so image pulls do not depend on a
# Homebrew installation or the caller's PATH.
skopeo_binary=${MACGRUBER_SKOPEO_BINARY:-$BIN_DIR/skopeo}
skopeo_policy=${MACGRUBER_SKOPEO_POLICY:-$BIN_DIR/policy.json}
vxlan_binary=${MACGRUBER_VXLAN_BINARY:-$BIN_DIR/darwin-vxlan}
[[ -x "$maclet_binary" ]] || { printf 'macgrubernetes: error: maclet binary not found: %s\n' "$maclet_binary" >&2; exit 1; }
if [[ "$command" == join && ! -x "$macker_binary" ]] && ! has_flag --macker-binary "$@"; then
    printf 'macgrubernetes: error: macker binary not found: %s\n' "$macker_binary" >&2
    exit 1
fi

# macOS may quarantine every executable extracted from a downloaded archive.
# Remove that attribute only from the binaries this launcher will use, and only
# when it is present. The explicit warning is intentional because sudo is used.
unquarantine_binary() {
    local path=$1
    local name=$2
    [[ -e "$path" ]] || return 0
    xattr -p com.apple.quarantine "$path" >/dev/null 2>&1 || return 0
    printf '%s|%s\n' "$name" "$path"
}

unquarantine_binaries() {
    local -a names=()
    local -a paths=()
    local name path index names_text=''
    while IFS='|' read -r name path; do
        [[ -n "$name" && -n "$path" ]] || continue
        names+=("$name")
        paths+=("$path")
    done < <(
        unquarantine_binary "$maclet_binary" maclet
        if [[ "$command" == join ]]; then
            unquarantine_binary "$macker_binary" macker
            unquarantine_binary "$skopeo_binary" skopeo
            if [[ "${MACGRUBER_DISABLE_VXLAN:-0}" != 1 && "${MACGRUBER_DISABLE_VXLAN:-0}" != true ]]; then
                unquarantine_binary "$vxlan_binary" darwin-vxlan
            fi
        fi
    )
    ((${#paths[@]} > 0)) || return 0

    for name in "${names[@]}"; do
        [[ -n "$names_text" ]] && names_text+=', '
        names_text+=$name
    done
    printf 'macgrubernetes: warning: using sudo to un-quarantine %s\n' "$names_text" >&2
    printf '%s\n' 'macgrubernetes: warning: this removes macOS Gatekeeper quarantine; only continue with a trusted release' >&2
    for index in "${!paths[@]}"; do
        path=${paths[$index]}
        if ! sudo xattr -d com.apple.quarantine "$path"; then
            printf 'macgrubernetes: error: failed to un-quarantine %s: %s\n' "${names[$index]}" "$path" >&2
            exit 1
        fi
    done
}

if [[ "$command" == join ]]; then
    # CLI binary overrides are appended below and take precedence over generated
    # defaults, so inspect those effective paths before removing quarantine.
    effective_macker_binary=$macker_binary
    cli_macker_binary=$(argument_value --macker-binary "$@" || true)
    [[ -n "$cli_macker_binary" ]] && effective_macker_binary=$cli_macker_binary
    effective_vxlan_binary=$vxlan_binary
    cli_vxlan_binary=$(argument_value --vxlan-binary "$@" || true)
    [[ -n "$cli_vxlan_binary" ]] && effective_vxlan_binary=$cli_vxlan_binary
    macker_binary=$effective_macker_binary
    vxlan_binary=$effective_vxlan_binary
fi
unquarantine_binaries
if [[ "$command" == join && -z "${MACKER_SKOPEO:-}" && -x "$skopeo_binary" ]]; then
    export MACKER_SKOPEO="$skopeo_binary"
fi
if [[ "$command" == join && -z "${CONTAINERS_POLICY_JSON:-}" && -f "$skopeo_policy" ]]; then
    export CONTAINERS_POLICY_JSON="$skopeo_policy"
fi

if [[ "$command" == leave ]]; then
    args=(leave --state-dir "$state_dir")
    if [[ -z "$(argument_value --kubeconfig "$@" || true)" ]]; then
        leave_kubeconfig=${MACGRUBER_KUBECONFIG:-${MACGRUBER_PEER_KUBECONFIG:-}}
        [[ -n "$leave_kubeconfig" ]] && args+=(--kubeconfig "$leave_kubeconfig")
    fi
    if [[ -z "$(argument_value --context "$@" || true)" && -n "${MACGRUBER_PEER_CONTEXT:-}" ]]; then
        args+=(--context "$MACGRUBER_PEER_CONTEXT")
    fi
    [[ -n "$node_name" ]] && args+=(--node-name "$node_name")
    [[ "${MACGRUBER_INSECURE_SKIP_TLS_VERIFY:-0}" == 1 || "${MACGRUBER_INSECURE_SKIP_TLS_VERIFY:-0}" == true ]] && args+=(--insecure-skip-tls-verify)
    exec "$maclet_binary" "${args[@]}" "$@"
fi

args=(join --state-dir "$state_dir" --macker-binary "$macker_binary")
if [[ "${MACGRUBER_DISABLE_VXLAN:-0}" != 1 && "${MACGRUBER_DISABLE_VXLAN:-0}" != true ]]; then
    if [[ ! -x "$vxlan_binary" ]] && ! has_flag --vxlan-binary "$@"; then
        printf 'macgrubernetes: error: darwin-vxlan binary not found: %s\n' "$vxlan_binary" >&2
        exit 1
    fi
    args+=(--vxlan-binary "$vxlan_binary")
    [[ -n "$vxlan_remote" ]] && args+=(--vxlan-remote "$vxlan_remote")
    [[ -n "$vxlan_local" ]] && args+=(--vxlan-local "$vxlan_local")
fi
[[ -n "$server" ]] && args+=(--server "$server")
[[ -n "$node_name" ]] && args+=(--node-name "$node_name")
[[ -n "$node_ip" ]] && args+=(--node-ip "$node_ip")
[[ -n "$external_ip" ]] && args+=(--external-ip "$external_ip")
if [[ -n "$peer_kubeconfig" && -f "$peer_kubeconfig" ]]; then
    args+=(--peer-kubeconfig "$peer_kubeconfig")
fi
[[ -n "$peer_context" ]] && args+=(--peer-context "$peer_context")
[[ -n "${MACGRUBER_TOKEN_FILE:-}" ]] && args+=(--token-file "$MACGRUBER_TOKEN_FILE")
if [[ -z "${MACGRUBER_TOKEN_FILE:-}" && -f "$home/.macgrubernetes/token" ]]; then
    args+=(--token-file "$home/.macgrubernetes/token")
fi
[[ "${MACGRUBER_DEBUG:-0}" == 1 || "${MACGRUBER_DEBUG:-0}" == true ]] && args+=(--debug)
[[ "${MACGRUBER_ONCE:-0}" == 1 || "${MACGRUBER_ONCE:-0}" == true ]] && args+=(--once)
[[ "${MACGRUBER_INSECURE_SKIP_TLS_VERIFY:-0}" == 1 || "${MACGRUBER_INSECURE_SKIP_TLS_VERIFY:-0}" == true ]] && args+=(--insecure-skip-tls-verify)
[[ "${MACGRUBER_DNS_RESOLVER:-1}" == 0 || "${MACGRUBER_DNS_RESOLVER:-1}" == false ]] && args+=(--dns-resolver=false)
[[ -n "${MACGRUBER_VXLAN_GATEWAY_MAC:-}" ]] && args+=(--vxlan-gateway-mac "$MACGRUBER_VXLAN_GATEWAY_MAC")
[[ -n "${MACGRUBER_CLUSTER_CIDR:-}" ]] && args+=(--cluster-cidr "$MACGRUBER_CLUSTER_CIDR")
[[ -n "${MACGRUBER_SERVICE_CIDR:-}" ]] && args+=(--service-cidr "$MACGRUBER_SERVICE_CIDR")
[[ -n "${MACGRUBER_DRAIN_TIMEOUT:-}" ]] && args+=(--drain-timeout "$MACGRUBER_DRAIN_TIMEOUT")

exec "$maclet_binary" "${args[@]}" "$@"
