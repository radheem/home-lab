#!/usr/bin/env bash
###############################################################################
# k3d-lab one-click installer.
#
#   ./install.sh [--env-file FILE] [--with-router] [--verbose]
#
# Brings up: k3d cluster -> Cilium (Gateway API, L2, LB-IPAM) -> cluster DNS ->
# etcd + authoritative CoreDNS -> ExternalDNS -> cert-manager (internal CA) ->
# shared Gateway -> demo app. Idempotent-ish: re-run after fixing a failure.
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

ENV_FILE="${ROOT_DIR}/.env"
WITH_ROUTER=false
WITH_REGISTRY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)   ENV_FILE="$2"; shift 2 ;;
    --with-router) WITH_ROUTER=true; shift ;;
    --with-registry) WITH_REGISTRY=true; shift ;;
    --verbose|-v) set -x; shift ;;
    -h|--help)
      echo "Usage: $0 [--env-file FILE] [--with-router] [--with-registry] [--verbose]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# --- Preflight ----------------------------------------------------------------
step "Preflight"
require_tools k3d kubectl helm docker jq envsubst
load_env "$ENV_FILE"

# --- 1. Cluster ---------------------------------------------------------------
step "Creating k3d cluster '${CLUSTER_NAME}'"
if k3d cluster get "${CLUSTER_NAME}" >/dev/null 2>&1; then
  die "cluster '${CLUSTER_NAME}' already exists — run ./uninstall.sh first"
fi
mkdir -p "${CLUSTER_VOLUME_STORE}"
render "${ROOT_DIR}/config/k3d-config.yaml" > "${ROOT_DIR}/.render-k3d-config.yaml"
# Wire the nodes' containerd to the in-cluster registry (mirror -> pinned LB IP).
[ "$WITH_REGISTRY" = "true" ] && render "${ROOT_DIR}/config/k3d-registries.yaml" >> "${ROOT_DIR}/.render-k3d-config.yaml"
k3d cluster create "${CLUSTER_NAME}" --config "${ROOT_DIR}/.render-k3d-config.yaml"
rm -f "${ROOT_DIR}/.render-k3d-config.yaml"
export_kubeconfig

step "Waiting for API server"
retries=0
until kubectl get nodes >/dev/null 2>&1; do
  retries=$((retries+1)); [ "$retries" -ge 30 ] && die "API server not ready"
  log_info "waiting for API server... ($retries/30)"; sleep 2
done
log_info "API server is ready"

# --- 2. BPF filesystem (Cilium needs it shared) -------------------------------
step "Mounting BPF filesystem on nodes"
for node in $(k3d node list --no-headers | awk -v c="${CLUSTER_NAME}" '$0 ~ c {print $1}'); do
  log_info "bpffs -> $node"
  docker exec -t "$node" mount bpffs /sys/fs/bpf -t bpf 2>/dev/null || true
  docker exec -t "$node" mount --make-shared /sys/fs/bpf 2>/dev/null || true
done

# --- 3. Gateway API CRDs ------------------------------------------------------
step "Installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- 4. Cilium ----------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION}"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  -f "${ROOT_DIR}/config/cilium-values.yaml" \
  --set k8sServiceHost="k3d-${CLUSTER_NAME}-server-0" \
  --set rollOutCiliumPods=true
wait_rollout kube-system ds/cilium 300s
wait_rollout kube-system deployment/cilium-operator 300s

# --- 5. LB pool + L2 announcements -------------------------------------------
step "Configuring LoadBalancer IP pool + L2 announcements"
apply_kustomize "${ROOT_DIR}/manifests/00-cluster-net"

# --- 6. Namespaces ------------------------------------------------------------
ensure_ns dns-system external-dns gateway-system demo

# --- 7. Cluster DNS (kube-dns) ------------------------------------------------
step "Installing cluster CoreDNS (kube-dns)"
helm repo add coredns https://coredns.github.io/helm >/dev/null 2>&1 || true
helm repo update >/dev/null
render "${ROOT_DIR}/config/coredns-cluster-values.yaml" > "${ROOT_DIR}/.render-coredns.yaml"
helm upgrade --install coredns coredns/coredns \
  --version "${COREDNS_CHART_VERSION}" \
  --namespace kube-system \
  -f "${ROOT_DIR}/.render-coredns.yaml"
rm -f "${ROOT_DIR}/.render-coredns.yaml"
wait_rollout kube-system deployment/coredns 180s

# --- 8. etcd + authoritative CoreDNS -----------------------------------------
step "Deploying etcd + authoritative CoreDNS"
apply_kustomize "${ROOT_DIR}/manifests/10-dns-system"
kubectl -n dns-system rollout status statefulset/etcd --timeout=180s
kubectl -n dns-system rollout status ds/coredns-auth --timeout=180s

# --- 9. ExternalDNS -----------------------------------------------------------
step "Deploying ExternalDNS (coredns provider)"
apply_kustomize "${ROOT_DIR}/manifests/20-external-dns"
wait_rollout external-dns deployment/external-dns 180s

# --- 10. cert-manager + internal CA ------------------------------------------
step "Installing cert-manager ${CERT_MANAGER_VERSION}"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "${CERT_MANAGER_VERSION}" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
wait_rollout cert-manager deployment/cert-manager 180s
wait_rollout cert-manager deployment/cert-manager-webhook 180s
log_info "Creating internal CA issuers + wildcard certificate"
apply_kustomize "${ROOT_DIR}/manifests/40-cert-manager"
kubectl -n gateway-system wait --for=condition=Ready certificate/wildcard-tls --timeout=180s

# --- 11. Shared Gateway -------------------------------------------------------
step "Creating shared Gateway"
apply_kustomize "${ROOT_DIR}/manifests/30-gateway"
kubectl -n gateway-system wait --for=condition=Programmed gateway/shared-gateway --timeout=180s || \
  log_warn "Gateway not Programmed yet — check 'kubectl -n gateway-system describe gateway shared-gateway'"

# --- 12. Demo app -------------------------------------------------------------
step "Deploying demo app (whoami)"
apply_kustomize "${ROOT_DIR}/manifests/50-examples"
wait_rollout demo deployment/whoami 120s

# --- 13. Optional in-cluster image registry ----------------------------------
if [ "$WITH_REGISTRY" = "true" ]; then
  step "Deploying in-cluster image registry (${REGISTRY_HOST:-registry.${LOCAL_TLD}})"
  ensure_ns registry
  apply_kustomize "${ROOT_DIR}/manifests/60-registry"
  kubectl -n registry wait --for=condition=Ready certificate/registry-tls --timeout=120s
  wait_rollout registry deployment/registry 180s
fi

# --- 14. Optional Tailscale subnet router ------------------------------------
if [ "$WITH_ROUTER" = "true" ]; then
  step "Installing Tailscale subnet router"
  [ -n "${TS_AUTHKEY:-}" ] || die "--with-router needs TS_AUTHKEY in .env"
  bash "${ROOT_DIR}/tailscale/manage.sh" install \
    --cluster-name "${CLUSTER_NAME}" \
    --authkey "${TS_AUTHKEY}" \
    --login-server "${TS_LOGIN_SERVER}" \
    --routes "${TS_ROUTES:-$LB_CIDR}"
fi

# --- Summary ------------------------------------------------------------------
step "Done"
cat <<EOF

$(_c '1;32' 'k3d-lab is up.')

  KUBECONFIG     : ${KUBECONFIG}
  Authoritative DNS (LAN): ${DNS_LB_IP}:53
  Shared Gateway (HTTP/S): ${GATEWAY_LB_IP}:80,443
  Demo app               : http://whoami.${LOCAL_TLD}

NEXT — point your LAN at this DNS (pick one):
  * Router: conditional-forward zone '${LOCAL_TLD}' -> ${DNS_LB_IP}
  * Or set ${DNS_LB_IP} as a device's DNS server.

VERIFY:
  dig @${DNS_LB_IP} whoami.${LOCAL_TLD} +short      # -> ${GATEWAY_LB_IP}
  dig @${DNS_LB_IP} example.com +short              # upstream forwarding works
  curl -H 'Host: whoami.${LOCAL_TLD}' http://${GATEWAY_LB_IP}

TLS: trust the CA on your devices —
  kubectl -n cert-manager get secret home-lab-ca-tls -o jsonpath='{.data.tls\\.crt}' | base64 -d > home-lab-ca.crt

EOF

if [ "$WITH_REGISTRY" = "true" ]; then
cat <<EOF
$(_c '1;32' 'Image registry is up') at https://${REGISTRY_HOST} (${REGISTRY_LB_IP}).

  PUSH (from any LAN device, after trusting home-lab-ca.crt above):
    docker tag myapp:dev ${REGISTRY_HOST}/myapp:dev
    docker push ${REGISTRY_HOST}/myapp:dev
  USE in a manifest:  image: ${REGISTRY_HOST}/myapp:dev   # nodes pull it automatically
  See docs/runbooks/registry.md (incl. enabling auth).

EOF
fi
