# Runbook — Tailscale / Headscale remote access

Make the cluster's LoadBalancer IPs (`LB_CIDR`, incl. the DNS `172.28.210.53` and
Gateway `172.28.210.80`) reachable from anywhere on your tailnet, by running a
**subnet router** that advertises `LB_CIDR` to Headscale.

> Prereq: the cluster is already up and verified per [runbook-local.md](runbook-local.md).
> Partly exercised in [Experiment 02](../experiments/02-with-tailscale/);
> remote approval designed in [Experiment 03](../experiments/03-remote-route-approval/).

## 1. Configure `.env` (Tailscale section)
```ini
TS_AUTHKEY=<headscale pre-auth key>          # node registration key
TS_LOGIN_SERVER=https://abc.yourcompany.com  # your Headscale URL
TS_ROUTES=${LB_CIDR}                          # what the router advertises
# For remote route approval (see step 3, Experiment 03):
HEADSCALE_API_KEY=<admin API key>            # NOT the auth key; optional but recommended
HEADSCALE_URL=${TS_LOGIN_SERVER}
```
`.env` is gitignored — never commit these.

## 2. Deploy the subnet router
On a fresh cluster you can do it in one shot: `./install.sh --with-router`.
Against an already-running cluster, add just the router:
```bash
export KUBECONFIG=$PWD/kubeconfig-$CLUSTER_NAME.yaml
set -a; source .env; set +a
bash tailscale/manage.sh install \
  --cluster-name "$CLUSTER_NAME" \
  --authkey "$TS_AUTHKEY" --login-server "$TS_LOGIN_SERVER" \
  --routes "$TS_ROUTES"
```
Confirm it registered:
```bash
kubectl -n tailscale-lb get pods
kubectl -n tailscale-lb logs deploy/tailscale-subnet-router-lb | grep -iE 'machineAuthorized|routes='
# expect: machineAuthorized=true ... routes=[172.28.210.0/24]
```
> Note: `manage.sh install` ignores the kube context arg and uses the *current*
> kubeconfig context — make sure `KUBECONFIG` points at this cluster first.

## 3. Approve the advertised route
A subnet route does **nothing** until approved in Headscale. The node auth key
cannot approve it (it returns 401 against the API — see Exp 02/03). Pick one:

**A. Remotely via the API (no control-plane host access)** — needs `HEADSCALE_API_KEY`:
```bash
set -a; source .env; set +a
bash tailscale/approve-route.sh           # enables LB_CIDR for <host>-ts-router
```

**B. On the control host (if you have access):**
```bash
headscale routes list                     # find the route id
headscale routes enable -r <id>
# (headscale >=0.26):  headscale nodes approve-routes -i <node-id> -r 172.28.210.0/24
```

**C. Zero-touch forever:** configure `autoApprovers` + a tagged auth key once, then
approval is automatic on every deploy. See
[Experiment 03 README](../experiments/03-remote-route-approval/README.md).

Confirm approved (the CIDR appears in `PrimaryRoutes`):
```bash
tailscale status --json | jq -r '.Peer[]|select(.HostName=="'"$CLUSTER_NAME"'-ts-router")|.PrimaryRoutes'
# expect: ["172.28.210.0/24"]
```

## 4. Verify from a remote tailnet machine
Run these from **another** tailnet device (not the cluster host — it may have a
direct LAN/bridge route that bypasses the tailnet):
```bash
dig @172.28.210.53 echo.home.lan +short                       # -> 172.28.210.80
curl --resolve echo.home.lan:80:172.28.210.80 http://echo.home.lan   # echo JSON
```
For name-based access tailnet-wide, point that device's DNS at `172.28.210.53`
(or configure Headscale DNS to forward `home.lan` there).

## 5. Alternative when you cannot approve routes at all
Expose a single service as its own tailnet host (no route approval needed) using
`tailscale serve` on the already-registered router node:
```bash
POD=$(kubectl -n tailscale-lb get pod -l app=tailscale-subnet-router-lb -o jsonpath='{.items[0].metadata.name}')
kubectl -n tailscale-lb exec "$POD" -- \
  tailscale --socket=/tmp/tailscaled.sock serve --bg --tcp=80 tcp://172.28.210.80:80
# then from any tailnet host (raw TCP preserves the Host header -> Gateway routes it):
curl --resolve echo.home.lan:80:<router-tailnet-ip> http://echo.home.lan
```
This proves remote reachability via a host proxy rather than an advertised subnet.

## 6. Teardown
```bash
bash tailscale/manage.sh uninstall --cluster-name "$CLUSTER_NAME"
# and remove/expire the Headscale node + API key if no longer needed
```

Problems? See [troubleshooting.md](troubleshooting.md).
