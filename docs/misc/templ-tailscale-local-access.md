# Template — temporary local access to `*.home.lan` over Tailscale

Use the cluster's assigned hostnames from a **remote laptop** when the cluster runs on
another machine and both are on the same tailnet — **without** approving a Tailscale
subnet route. It works because every HTTP hostname sits behind the **one Gateway LB IP**
(differentiated by `Host` header), so an SSH port-forward + a local `/etc/hosts`
override is enough.

> This exercises the **Gateway hostname routing + TLS** end-to-end. It does *not* use
> the cluster's CoreDNS (you override resolution locally). For the fully DNS-resolved
> path with zero local config, approve the Tailscale subnet route instead
> ([tailscale-access.md](../runbooks/tailscale-access.md) + experiments 02/03).

## Fill in for your cluster

| Placeholder | This cluster (example) | How to find it |
|---|---|---|
| `<REMOTE_TS>` | `100.64.0.10` (`homelab`) | `tailscale ip` on the remote |
| `<GATEWAY_IP>` | `172.28.210.80` | `kubectl -n gateway-system get gateway shared-gateway -o jsonpath='{.status.addresses[0].value}'` |
| `<NATS_IP>` | `172.28.210.54` | `kubectl -n messaging get svc nats -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` |
| `<POSTGRES_IP>` | `172.28.210.55` | `kubectl -n cnpg-system get svc homelab-pg -o jsonpath='{...ingress[0].ip}'` |
| `<FERRETDB_IP>` | `172.28.210.56` | `kubectl -n cnpg-system get svc ferretdb -o jsonpath='{...ingress[0].ip}'` |
| TLD | `home.lan` | `LOCAL_TLD` in `.env` |

Prereq: the **remote host** can reach the LB IPs. On a non-bridged/cloud host add a
route once (see [deploy-local.md](../runbooks/deploy-local.md) §host caveat):
`sudo ip route add <LB_CIDR> dev br-<k3dnet>`.

## HTTP UIs (Grafana, Hatchet, whoami…) — one tunnel for all

> Two footguns: the file is **`/etc/hosts`** (plural, not `/etc/host`), and `ssh -N`
> runs in the foreground — keep it in one terminal and run `curl`/the browser in
> another.

```bash
# 1) on your laptop, add to /etc/hosts (PLURAL) — every gateway-fronted name -> loopback:
echo '127.0.0.1  grafana.home.lan hatchet.home.lan whoami.home.lan' | sudo tee -a /etc/hosts
getent hosts grafana.home.lan        # sanity: prints 127.0.0.1 grafana.home.lan

# 2) Terminal A — forward the Gateway over Tailscale (sudo binds low ports; keep running):
sudo ssh -N -L 80:<GATEWAY_IP>:80 -L 443:<GATEWAY_IP>:443 radr@<REMOTE_TS>

# 3) Terminal B — browse / curl:
curl -i http://grafana.home.lan      # expect 302 -> /login
#   http://grafana.home.lan   http://hatchet.home.lan   http://whoami.home.lan
```

Tunnel-only sanity check (bypasses /etc/hosts; run with Terminal A up):
```bash
curl -i -H 'Host: grafana.home.lan' http://127.0.0.1     # 302 == tunnel + Gateway OK
```
Add more hostnames by just appending them to the `/etc/hosts` line — they all ride the
same tunnel (the Gateway routes by `Host`).

### HTTPS (internal CA)
```bash
# on the remote, export the CA and copy it to your laptop:
kubectl --kubeconfig ~/pers/k3d-lab/kubeconfig-<CLUSTER>.yaml -n cert-manager \
  get secret home-lab-ca-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > home-lab-ca.crt
```
Trust `home-lab-ca.crt` in your OS/browser, then `https://grafana.home.lan` validates
against the `*.home.lan` wildcard.

## Raw-TCP services (NATS, Postgres, FerretDB) — one `-L` per service

Each has its own LB IP, so forward each to the same local port:
```bash
sudo ssh -N \
  -L 4222:<NATS_IP>:4222 \
  -L 5432:<POSTGRES_IP>:5432 \
  -L 27017:<FERRETDB_IP>:27017 \
  radr@<REMOTE_TS>

# /etc/hosts:  127.0.0.1 nats.home.lan postgres.home.lan ferretdb.home.lan
psql -h postgres.home.lan -U dbadmin -d appdb     # pw: components/components.secrets.env
nats --server nats://nats.home.lan:4222 server info
mongosh mongodb://ferretdb.home.lan:27017
```

## Teardown
Ctrl-C the `ssh -N` tunnels and remove the lines you added to `/etc/hosts`. Nothing
on the cluster changes.

## Limitations
- Overrides DNS locally (tests Gateway routing/TLS, not cluster CoreDNS/ExternalDNS).
- One tunnel process per terminal; `sudo` only needed for ports <1024 (use high local
  ports + `:port` URLs to avoid sudo).
- The real, zero-config path is the approved Tailscale subnet route.
