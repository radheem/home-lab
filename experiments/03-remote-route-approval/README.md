# Experiment 03 — Approve subnet routes remotely (no Headscale host access)

## Goal
Experiment 02 blocked because the advertised subnet route `172.28.210.0/24` must be
**approved** in Headscale, and the operator can't reach the control-plane host. This
experiment documents (and scripts) how to approve routes **remotely via the Headscale
HTTP API**, so the tailscale deployment becomes fully drivable from the cluster host.

## Why the node auth key can't do it (recap from Exp 02)
- `TS_AUTHKEY` is a **pre-auth (node) key** — it only authorizes a node to *register*.
- Route approval is an **admin** action. The Headscale API rejects the auth key:
  `GET https://abc.yourcompany.com/api/v1/routes` → **401** with the auth key.
- You need a different credential: a Headscale **API key** (Bearer token), or a
  policy that auto-approves.

## The required setup

### Credential: a Headscale API key (one-time)
Created **once** by anyone with control-plane access (CLI or an existing admin), then
handed to you — you never need to log into the host again:
```bash
# on the headscale control host (one time):
headscale apikeys create --expiration 90d
# -> prints a token like:  abcdef0123...   (store it, it is shown once)
```
Store it on the cluster host, gitignored:
```bash
# append to k3d-lab/.env  (already covered by .gitignore)
HEADSCALE_API_KEY=<the-token>
HEADSCALE_URL=https://abc.yourcompany.com
```
API key ≠ auth key: the API key is an admin Bearer token for `/api/v1/*`; the auth
key only registers nodes.

### Two ways to use it

**A. Approve on demand (per deploy)** — `tailscale/approve-route.sh` (added by this
experiment). After deploying the router it finds the node's pending route and enables
it via the API. Handles both Headscale API generations:
- ≤0.25: `GET /api/v1/routes` → find id → `POST /api/v1/routes/{id}/enable`
- ≥0.26: `GET /api/v1/node` → `POST /api/v1/node/{id}/approve_routes` `{"routes":[...]}`
```bash
set -a; source .env; set +a
bash tailscale/approve-route.sh            # uses HEADSCALE_API_KEY + LB_CIDR + node name
```

**B. Auto-approve forever (set-and-forget)** — an `autoApprovers` ACL policy so any
router advertising the LB CIDR with the right tag is approved automatically at
registration (no per-deploy step, fixes all sibling clusters too). Requires:
1. A **tagged** pre-auth key: `headscale preauthkeys create --tags tag:k8s-lb ...`
   and the router uses it (set `TS_AUTHKEY` to the tagged key).
2. Policy additions (HuJSON), pushable via API if policy is DB-backed
   (`PUT /api/v1/policy`) or set on the host:
   ```jsonc
   {
     "tagOwners": { "tag:k8s-lb": ["your-user@"] },
     "autoApprovers": {
       "routes": {
         "172.28.210.0/24": ["tag:k8s-lb"],
         "172.28.0.0/16":   ["tag:k8s-lb"]   // optional: cover all lab LB pools
       }
     }
   }
   ```
With B in place, `install.sh --with-router` is truly one-click — no approval step.

## Constraints / assumptions
- Someone provisions the API key once (or the autoApprovers policy). After that,
  everything is remote. We cannot bootstrap an API key purely from the node auth key.
- API key has admin scope — treat it like a password (gitignored `.env`, rotate via
  `headscale apikeys expire`).

## Method (verification once a key exists)
```bash
set -a; source .env; set +a
# sanity: key works
curl -s -H "Authorization: Bearer $HEADSCALE_API_KEY" "$HEADSCALE_URL/api/v1/apikey" | jq '.apiKeys|length'
# approve our router's route
bash tailscale/approve-route.sh
# confirm approved (PrimaryRoutes now lists the CIDR)
tailscale status --json | jq -r '.Peer[]|select(.HostName=="homelab-ts-router")|.PrimaryRoutes'
```
Then resume **Experiment 02 Step 4** (dig/curl from a tailnet machine).

## Success criteria
- `approve-route.sh` returns success and the node's `PrimaryRoutes` includes
  `172.28.210.0/24`.
- A remote tailnet host can `dig @172.28.210.53 echo.home.lan` and `curl` the gateway.

## Outcome
_TBD — pending an API key. The script + setup are in place so this is a ~1-minute
step once the key is provided._
