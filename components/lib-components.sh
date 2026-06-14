#!/usr/bin/env bash
# Helpers for the component deployer. Sourced by components.sh (which has already
# sourced ../lib/common.sh, so log_info/log_warn/log_err/die/ensure_ns exist).

REGISTRY_DIR="${COMPONENTS_DIR}/registry"

# --- metadata access (registry/<name>/component.yaml) -----------------------
comp_meta() {  # comp_meta <name> <yq-expr>   e.g. comp_meta grafana '.type'
  yq -r "$2 // \"\"" "${REGISTRY_DIR}/$1/component.yaml"
}
comp_exists() { [ -f "${REGISTRY_DIR}/$1/component.yaml" ]; }
all_components() { for d in "${REGISTRY_DIR}"/*/; do basename "$d"; done; }

# --- selection file access (components.yaml) --------------------------------
SELECTION="${SELECTION:-${COMPONENTS_DIR}/components.yaml}"
sel() { yq -r "$1 // \"\"" "$SELECTION"; }          # raw selection query
# NOTE: this repo's `yq` is the Python jq-wrapper. Use jq syntax: bracket form for
# hyphenated keys (.components["node-exporter"]), ascii_upcase, and (.x // [])[] guards.
comp_enabled() { [ "$(sel ".components[\"$1\"].enabled")" = "true" ]; }
domain() { local d; d="$(sel '.defaults.domain')"; echo "${d:-${LOCAL_TLD:-home.lan}}"; }

# Export this component's config node as COMP_<KEY>=... env vars (+ DOMAIN).
# values/manifests reference ${COMP_HOSTNAME}, ${COMP_STORAGESIZE}, ${DOMAIN}, etc.
export_comp_env() {  # <name>
  unset $(compgen -v | grep '^COMP_' || true) 2>/dev/null || true
  export DOMAIN; DOMAIN="$(domain)"
  local kv
  while IFS= read -r kv; do [ -n "$kv" ] && export "COMP_${kv}"; done < <(
    yq -r ".components[\"$1\"] // {} | to_entries | .[] | select(.key != \"enabled\") | (.key | ascii_upcase) + \"=\" + (.value | tostring)" "$SELECTION"
  )
}

# envsubst scoped to only our own vars (never eat helm/template $ tokens).
comp_envsubst() {
  local vars; vars="$(compgen -v | grep -E '^(COMP_|SECRET_)' | sed 's/^/$/' | tr '\n' ' ')"
  envsubst "\$DOMAIN $vars"
}

# --- secrets (gitignored components.secrets.env) ---------------------------
SECRETS_FILE="${COMPONENTS_DIR}/components.secrets.env"
load_secrets() { if [ -f "$SECRETS_FILE" ]; then set -a; . "$SECRETS_FILE"; set +a; fi; }
# Ensure SECRET_<KEY> exists; generate + persist if missing. Returns the value.
ensure_secret() {  # <KEY>
  local var="SECRET_$1"
  if [ -z "${!var:-}" ]; then
    local val; val="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)"
    printf '%s=%s\n' "$var" "$val" >> "$SECRETS_FILE"
    export "$var=$val"
    log_warn "generated $var -> $SECRETS_FILE (gitignored)"
  fi
}

# --- dependency resolution (topological sort) ------------------------------
# Echoes enabled components + their transitive deps, in install order.
resolve_order() {
  local enabled=() c
  for c in $(all_components); do comp_enabled "$c" && enabled+=("$c"); done
  declare -A SEEN=() DONE=(); local order=()
  _visit() {
    local n="$1"
    [ -n "${DONE[$n]:-}" ] && return 0
    [ -n "${SEEN[$n]:-}" ] && die "dependency cycle at $n"
    SEEN[$n]=1
    local dep
    for dep in $(comp_meta "$n" '(.dependsOn // [])[]'); do
      comp_exists "$dep" || die "$n depends on unknown component: $dep"
      _visit "$dep"
    done
    DONE[$n]=1; order+=("$n")
  }
  for c in "${enabled[@]}"; do _visit "$c"; done
  printf '%s\n' "${order[@]}"
}

# --- platform preflight (homelab provides these) ---------------------------
preflight_platform() {
  local missing=()
  kubectl -n cert-manager get deploy cert-manager >/dev/null 2>&1 || missing+=("cert-manager")
  kubectl -n gateway-system get gateway shared-gateway >/dev/null 2>&1 || missing+=("shared-gateway")
  kubectl -n external-dns get deploy external-dns >/dev/null 2>&1 || missing+=("external-dns")
  kubectl get storageclass local-path >/dev/null 2>&1 || missing+=("local-path StorageClass")
  kubectl get ciliumloadbalancerippool >/dev/null 2>&1 || missing+=("Cilium LB-IPAM pool")
  if [ ${#missing[@]} -ne 0 ]; then
    log_err "missing platform prerequisites: ${missing[*]}"
    die "run ./install.sh first (the homelab provides cert-manager, gateway, external-dns, storage, LB-IPAM)"
  fi
  # ExternalDNS must watch Services for LoadBalancer hostnames to publish.
  if ! kubectl -n external-dns get deploy external-dns -o yaml | grep -q -- '--source=service'; then
    log_warn "homelab ExternalDNS lacks --source=service; LoadBalancer hostnames (NATS/Postgres/FerretDB) won't publish."
    log_warn "  fix: re-run ./install.sh after pulling the updated manifests/20-external-dns."
  fi
  log_info "platform prerequisites OK"
}

# --- waits -----------------------------------------------------------------
wait_crd() {  # <crd-name> [timeout]
  log_info "waiting for CRD $1 Established"
  kubectl wait --for=condition=Established "crd/$1" --timeout="${2:-120s}"
}

# Poll a CloudNativePG Cluster to the 'healthy' phase (no kubectl condition exists).
wait_cnpg() {  # <ns> <cluster> [secs]
  local ns="$1" c="$2" max="${3:-600}" t=0
  log_info "waiting for CNPG cluster $c healthy (<=${max}s)"
  until kubectl -n "$ns" get cluster "$c" -o jsonpath='{.status.phase}' 2>/dev/null | grep -qi healthy; do
    t=$((t+10)); [ "$t" -ge "$max" ] && { log_err "CNPG $c not healthy in ${max}s"; return 1; }
    sleep 10
  done
  log_info "CNPG cluster $c healthy"
}
