#!/usr/bin/env bash
# Shared helpers for install.sh / uninstall.sh. Sourced, not executed.

# --- Logging ------------------------------------------------------------------
_c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
log_info() { echo "$(_c '0;32' '[INFO]') $*"; }
log_warn() { echo "$(_c '0;33' '[WARN]') $*" >&2; }
log_err()  { echo "$(_c '0;31' '[ERR ]') $*" >&2; }
die()      { log_err "$*"; exit 1; }
step()     { echo; echo "$(_c '1;36' "=== $* ===")"; }

# Only the variables we intentionally template into manifests/configs. Keeping
# this list explicit prevents envsubst from eating unrelated `$` text.
ENVSUBST_VARS='${LOCAL_HOST} ${CLUSTER_NAME} ${API_SERVER_FQDN} ${API_SERVER_PORT} ${K3S_VERSION} ${SERVER_COUNT} ${AGENT_COUNT} ${CLUSTER_SUBNET} ${CLUSTER_VOLUME_STORE} ${LB_CIDR} ${DNS_LB_IP} ${GATEWAY_LB_IP} ${LOCAL_TLD} ${UPSTREAM_DNS}'

# --- Environment --------------------------------------------------------------
load_env() {
  local env_file="$1"
  [ -f "$env_file" ] || die "env file not found: $env_file (copy .env.example to .env)"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  log_info "Loaded env from $env_file"
  : "${CLUSTER_NAME:?CLUSTER_NAME must be set}"
  : "${LOCAL_TLD:?LOCAL_TLD must be set}"
  : "${DNS_LB_IP:?DNS_LB_IP must be set}"
  : "${GATEWAY_LB_IP:?GATEWAY_LB_IP must be set}"
  : "${LB_CIDR:?LB_CIDR must be set}"
  : "${CLUSTER_VOLUME_STORE:?CLUSTER_VOLUME_STORE must be set}"
}

require_tools() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]}"
  log_info "All required tools present: $*"
}

# --- kubeconfig ---------------------------------------------------------------
# Use a repo-local kubeconfig so we never depend on / clobber the user's default.
export_kubeconfig() {
  KUBECONFIG_FILE="${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}.yaml"
  k3d kubeconfig get "${CLUSTER_NAME}" > "${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"
  log_info "KUBECONFIG -> ${KUBECONFIG_FILE}"
}

# --- Apply helpers ------------------------------------------------------------
# Render a kustomize overlay, substitute env vars, apply.
apply_kustomize() {
  local dir="$1"
  log_info "Applying overlay: $dir"
  kubectl kustomize "$dir" | envsubst "$ENVSUBST_VARS" | kubectl apply -f -
}

# Render a single template file (envsubst) to stdout.
render() { envsubst "$ENVSUBST_VARS" < "$1"; }

ensure_ns() {
  for ns in "$@"; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  log_info "Namespaces ready: $*"
}

wait_rollout() {  # wait_rollout <ns> <type/name> [timeout]
  kubectl -n "$1" rollout status "$2" --timeout="${3:-180s}"
}
