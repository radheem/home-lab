#!/usr/bin/env bash
###############################################################################
# Component deployer — selectable monitoring/messaging/workflow/database stack.
#
#   ./components.sh deploy [--only NAME] [--dry-run]
#   ./components.sh remove [--only NAME]
#   ./components.sh status
#   ./components.sh list
#
# Selection + per-component config: components.yaml (copy from .example).
# Secrets: components.secrets.env (gitignored, auto-generated).
# Reuses the homelab platform (cert-manager, Cilium Gateway, ExternalDNS,
# local-path, LB-IPAM) — run ./install.sh first.
###############################################################################
set -euo pipefail

COMPONENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${COMPONENTS_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=lib-components.sh
source "${COMPONENTS_DIR}/lib-components.sh"

CMD="${1:-deploy}"; shift || true
ONLY="" DRY=false ENV_FILE="${ROOT_DIR}/.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --selection) SELECTION="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -f "$SELECTION" ] || die "selection file not found: $SELECTION (cp components.yaml.example components.yaml)"
load_env "$ENV_FILE"
# Prefer this cluster's repo-local kubeconfig over any ambient KUBECONFIG
# (the user's shell may point KUBECONFIG at other clusters).
if [ -f "${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}.yaml" ]; then
  export KUBECONFIG="${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}.yaml"
fi
load_secrets

# --- render helpers ---------------------------------------------------------
# Copy a registry dir to a tmp and envsubst every yaml in place (so typed helm
# values are filled BEFORE kustomize --enable-helm runs).
render_dir_to_tmp() {  # <srcdir> ; echoes tmp path
  local src="$1" tmp; tmp="$(mktemp -d)"
  cp -r "$src"/. "$tmp"/
  local f
  while IFS= read -r f; do comp_envsubst < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done \
    < <(find "$tmp" -type f \( -name '*.yaml' -o -name '*.yml' \))
  echo "$tmp"
}

ensure_secrets_for() {  # <name>
  local s
  for s in $(comp_meta "$1" '(.secrets // [])[]'); do ensure_secret "$s"; done
}

# --- deploy / remove a single component ------------------------------------
deploy_component() {  # <name>
  local name="$1" type ns
  type="$(comp_meta "$name" '.type')"; ns="$(comp_meta "$name" '.namespace')"
  log_info "deploy ${name} (type=${type}, ns=${ns})"
  $DRY && return 0
  ensure_ns "$ns"
  export_comp_env "$name"; ensure_secrets_for "$name"

  case "$type" in
    helm)
      local repo chart ver release vf
      repo="$(comp_meta "$name" '.chart.repo')"; chart="$(comp_meta "$name" '.chart.name')"
      ver="$(comp_meta "$name" '.chart.version')"; release="$(comp_meta "$name" '.chart.release')"
      vf="${REGISTRY_DIR}/${name}/$(comp_meta "$name" '.chart.valuesFile')"
      local rendered; rendered="$(mktemp)"
      [ -f "$vf" ] && comp_envsubst < "$vf" > "$rendered" || : > "$rendered"
      helm upgrade --install "$release" "$chart" --repo "$repo" --version "$ver" \
        --namespace "$ns" --create-namespace -f "$rendered"
      rm -f "$rendered"
      ;;
    kustomize)
      # server-side apply: avoids the 256KB last-applied-config annotation limit
      # (large dashboard ConfigMaps) and is idempotent.
      kubectl kustomize "${REGISTRY_DIR}/${name}/kustomize" | comp_envsubst | kubectl apply --server-side --force-conflicts -f -
      ;;
    kustomize-helm)
      local tmp; tmp="$(render_dir_to_tmp "${REGISTRY_DIR}/${name}/kustomize")"
      kubectl kustomize --enable-helm "$tmp" | kubectl apply --server-side --force-conflicts -f -
      rm -rf "$tmp"
      ;;
    *) die "unknown component type for ${name}: ${type}" ;;
  esac

  # CRDs first (operators), then rollout/object waits.
  local crd w ct; ct="$(comp_meta "$name" '.crdTimeout')"
  for crd in $(comp_meta "$name" '(.crds // [])[]'); do wait_crd "$crd" "${ct:-120s}"; done
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    eval "$w"
  done < <(comp_meta "$name" '(.waits // [])[]')
  log_info "✓ ${name}"
}

remove_component() {  # <name>
  local name="$1" type ns; type="$(comp_meta "$name" '.type')"; ns="$(comp_meta "$name" '.namespace')"
  log_info "remove ${name}"
  $DRY && return 0
  export_comp_env "$name"
  case "$type" in
    helm) helm uninstall "$(comp_meta "$name" '.chart.release')" -n "$ns" 2>/dev/null || true ;;
    kustomize) kubectl kustomize "${REGISTRY_DIR}/${name}/kustomize" | comp_envsubst | kubectl delete -f - --ignore-not-found 2>/dev/null || true ;;
    kustomize-helm)
      local tmp; tmp="$(render_dir_to_tmp "${REGISTRY_DIR}/${name}/kustomize")"
      kubectl kustomize --enable-helm "$tmp" | kubectl delete -f - --ignore-not-found 2>/dev/null || true
      rm -rf "$tmp" ;;
  esac
}

# --- commands ---------------------------------------------------------------
do_deploy() {
  preflight_platform
  local order
  if [ -n "$ONLY" ]; then
    comp_exists "$ONLY" || die "unknown component: $ONLY"
    order="$(resolve_only "$ONLY")"     # target + its transitive deps
  else
    order="$(resolve_order)"
  fi
  [ -n "$order" ] || { log_warn "no components enabled in $SELECTION"; return 0; }
  log_info "install order: $(echo "$order" | tr '\n' ' ')"
  local c; for c in $order; do deploy_component "$c"; done
  $DRY && { log_info "(dry-run) nothing applied"; return 0; }
  print_summary $order
}

# deps of a single component (for --only), topo-ordered
resolve_only() {  # <name>
  declare -A DONE=(); local order=()
  _v() { local n="$1"; [ -n "${DONE[$n]:-}" ] && return; local d; for d in $(comp_meta "$n" '(.dependsOn // [])[]'); do _v "$d"; done; DONE[$n]=1; order+=("$n"); }
  _v "$1"; printf '%s\n' "${order[@]}"
}

do_remove() {
  local order
  if [ -n "$ONLY" ]; then order="$ONLY"; else order="$(resolve_order)"; fi
  # remove in reverse install order
  local rev=(); local c; for c in $order; do rev=("$c" "${rev[@]}"); done
  for c in "${rev[@]}"; do remove_component "$c"; done
}

do_status() {
  local c ns seen=" "
  for c in $(resolve_order); do
    ns="$(comp_meta "$c" '.namespace')"
    case "$seen" in *" $ns "*) ;; *) seen="$seen$ns "; echo "── namespace: $ns ──"; kubectl -n "$ns" get pods 2>/dev/null || true ;; esac
  done
}

do_list() {
  printf '%-26s %-12s %-14s %s\n' COMPONENT CATEGORY ENABLED DEPENDS_ON
  local c
  for c in $(all_components); do
    printf '%-26s %-12s %-14s %s\n' "$c" "$(comp_meta "$c" '.category')" \
      "$(comp_enabled "$c" && echo yes || echo no)" "$(comp_meta "$c" '(.dependsOn // [])[]' | tr '\n' ' ')"
  done
}

print_summary() {
  echo; log_info "deployed: $*"
  echo "Verify DNS:   dig @${DNS_LB_IP:-172.28.210.53} <name>.$(domain) +short"
  echo "Verify HTTP:  curl -H 'Host: <name>.$(domain)' http://${GATEWAY_LB_IP:-172.28.210.80}"
}

case "$CMD" in
  deploy) do_deploy ;;
  remove) do_remove ;;
  status) do_status ;;
  list)   do_list ;;
  *) die "unknown command: $CMD (deploy|remove|status|list)" ;;
esac
