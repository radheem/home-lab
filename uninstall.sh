#!/usr/bin/env bash
###############################################################################
# Tear down the k3d-lab cluster.
#   ./uninstall.sh [--env-file FILE] [--purge-data]
# --purge-data also deletes the on-disk PVC store (${CLUSTER_VOLUME_STORE}).
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

ENV_FILE="${ROOT_DIR}/.env"
PURGE_DATA=false
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --purge-data) PURGE_DATA=true; shift ;;
    -h|--help) echo "Usage: $0 [--env-file FILE] [--purge-data]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_env "$ENV_FILE"

step "Removing Tailscale subnet router (if present)"
KUBECONFIG_FILE="${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}.yaml"
if [ -f "$KUBECONFIG_FILE" ] && k3d cluster get "${CLUSTER_NAME}" >/dev/null 2>&1; then
  export KUBECONFIG="$KUBECONFIG_FILE"
  bash "${ROOT_DIR}/tailscale/manage.sh" uninstall --cluster-name "${CLUSTER_NAME}" 2>/dev/null || true
fi

step "Deleting k3d cluster '${CLUSTER_NAME}'"
if k3d cluster get "${CLUSTER_NAME}" >/dev/null 2>&1; then
  k3d cluster delete "${CLUSTER_NAME}"
else
  log_warn "cluster '${CLUSTER_NAME}' does not exist"
fi

rm -f "${KUBECONFIG_FILE}"
log_info "Removed ${KUBECONFIG_FILE}"

if [ "$PURGE_DATA" = "true" ]; then
  step "Purging PVC store ${CLUSTER_VOLUME_STORE}"
  if [ -n "${CLUSTER_VOLUME_STORE}" ] && [ -d "${CLUSTER_VOLUME_STORE}" ]; then
    if [ "$(id -u)" = 0 ]; then rm -rf "${CLUSTER_VOLUME_STORE}"; else sudo rm -rf "${CLUSTER_VOLUME_STORE}"; fi
    log_info "deleted ${CLUSTER_VOLUME_STORE}"
  fi
fi

step "Done"
