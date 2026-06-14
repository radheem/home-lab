# Experiment 02 — Same, reachable over Tailscale/Headscale

## Goal
Prove the **same** `echo.home.lan` service is reachable from a **remote machine on
the tailnet**, by advertising the LoadBalancer pool (`172.28.210.0/24`) through a
Tailscale subnet router connected to the self-hosted Headscale control plane.

Because both pinned IPs live inside the advertised pool, a tailnet client can:
- query the authoritative DNS at `172.28.210.53`, and
- reach the Gateway at `172.28.210.80`.

## Environment (from `.env`)
| Key | Value |
|-----|-------|
| Cluster | `qube-homelab` |
| Authoritative DNS (LB IP) | `172.28.210.53` |
| Shared Gateway (LB IP) | `172.28.210.80` |
| Advertised route (`TS_ROUTES`) | `172.28.210.0/24` |
| Headscale (`TS_LOGIN_SERVER`) | `https://abc.yourcompany.com` |
| Tailscale | **enabled** (`--with-router`) |

## Constraints / assumptions
- `TS_AUTHKEY` + `TS_LOGIN_SERVER` are configured in `.env` (creds present).
- **Manual gate:** the advertised subnet route must be **approved in the Headscale
  control plane** before it carries traffic. The run therefore pauses after the
  subnet-router pod is up and registered, the operator approves the route, then
  testing resumes. (This is the one non-automatable step.)
- A second tailnet-connected machine is needed to run the remote `dig`/`curl`.
- Builds on Experiment 01: the cluster + echo app are already deployed; this adds
  only the subnet router. (If starting fresh, run `./install.sh --with-router`.)

## Method
```bash
cd /home/radr/pers/k3d-lab

# If the cluster is already up from Exp 01, just add the router:
bash tailscale/manage.sh install \
  --cluster-name qube-homelab \
  --authkey "$TS_AUTHKEY" --login-server "$TS_LOGIN_SERVER" \
  --routes 172.28.210.0/24
# (or from scratch: ./install.sh --with-router)

# confirm the router registered
bash tailscale/manage.sh status --cluster-name qube-homelab

# >>> PAUSE: approve the 172.28.210.0/24 route in Headscale admin <<<

# From ANOTHER tailnet machine:
dig @172.28.210.53 echo.home.lan +short                                  # -> 172.28.210.80
curl -s --resolve echo.home.lan:80:172.28.210.80 http://echo.home.lan | jq .host
```

## Success criteria
- Subnet-router pod is `Running` and registered in Headscale.
- After route approval, from a remote tailnet host:
  - `dig @172.28.210.53 echo.home.lan` returns `172.28.210.80`.
  - `curl --resolve ...` returns echo JSON (`"host": "echo.home.lan"`).

## Outcome
_TBD — filled in after the run. See [journal/](journal/)._
