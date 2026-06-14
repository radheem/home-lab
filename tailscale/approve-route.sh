#!/usr/bin/env bash
###############################################################################
# Approve a subnet router's advertised route in Headscale via the HTTP API,
# without SSHing to the control host. See experiments/03-remote-route-approval.
#
#   set -a; source .env; set +a
#   bash tailscale/approve-route.sh [CIDR] [NODE_NAME]
#
# Requires (from .env or env):
#   HEADSCALE_API_KEY   admin Bearer token  (NOT the node auth key)
#   HEADSCALE_URL       e.g. https://abc.yourcompany.com  (falls back to TS_LOGIN_SERVER)
#   CIDR                route to approve    (arg 1, else TS_ROUTES, else LB_CIDR)
#   NODE_NAME           router hostname     (arg 2, else ${CLUSTER_NAME}-ts-router)
###############################################################################
set -euo pipefail

API_KEY="${HEADSCALE_API_KEY:?set HEADSCALE_API_KEY (a Headscale API key, not the auth key)}"
URL="${HEADSCALE_URL:-${TS_LOGIN_SERVER:?set HEADSCALE_URL or TS_LOGIN_SERVER}}"
URL="${URL%/}"
CIDR="${1:-${TS_ROUTES:-${LB_CIDR:?set CIDR / TS_ROUTES / LB_CIDR}}}"
NODE="${2:-${CLUSTER_NAME:-${LOCAL_HOST:?set CLUSTER_NAME/LOCAL_HOST or pass NODE_NAME}}-ts-router}"
command -v jq >/dev/null || { echo "jq required"; exit 1; }

auth=(-H "Authorization: Bearer ${API_KEY}")
say() { echo "[approve-route] $*"; }
say "headscale=$URL node=$NODE route=$CIDR"

# Detect API generation by probing the legacy routes endpoint.
code=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$URL/api/v1/routes" || true)

if [ "$code" = "200" ]; then
  # ---- Headscale <= 0.25: per-route id + /enable ----
  say "using legacy routes API (/api/v1/routes)"
  rid=$(curl -s "${auth[@]}" "$URL/api/v1/routes" \
    | jq -r --arg n "$NODE" --arg c "$CIDR" \
        '.routes[]? | select((.node.givenName==$n or .node.name==$n) and .prefix==$c) | .id' | head -1)
  [ -n "${rid:-}" ] || { say "no matching advertised route found (is the router up & advertising $CIDR?)"; exit 1; }
  say "enabling route id=$rid"
  curl -s -X POST "${auth[@]}" "$URL/api/v1/routes/$rid/enable" >/dev/null
  say "enabled."
elif [ "$code" = "401" ] || [ "$code" = "403" ]; then
  echo "[approve-route] API rejected the key ($code). HEADSCALE_API_KEY must be an"
  echo "                admin API key (headscale apikeys create), not the node auth key."
  exit 1
else
  # ---- Headscale >= 0.26: node-based approval ----
  say "routes API returned $code; using node API (/api/v1/node/.../approve_routes)"
  node_json=$(curl -s "${auth[@]}" "$URL/api/v1/node")
  nid=$(echo "$node_json" | jq -r --arg n "$NODE" \
        '.nodes[]? | select(.givenName==$n or .name==$n) | .id' | head -1)
  [ -n "${nid:-}" ] || { say "node $NODE not found"; exit 1; }
  # approve_routes SETS the full approved list -> merge existing + new
  routes=$(echo "$node_json" | jq -c --arg n "$NODE" --arg c "$CIDR" \
    '[.nodes[]? | select(.givenName==$n or .name==$n) | (.approvedRoutes // [])[]] + [$c] | unique')
  say "node id=$nid setting approvedRoutes=$routes"
  curl -s -X POST "${auth[@]}" -H 'Content-Type: application/json' \
    -d "{\"routes\":$routes}" "$URL/api/v1/node/$nid/approve_routes" >/dev/null
  say "approved."
fi

say "verify:  tailscale status --json | jq -r '.Peer[]|select(.HostName==\"$NODE\")|.PrimaryRoutes'"
