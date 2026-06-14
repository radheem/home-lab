# Runbook — WSL cluster, browse `*.home.lan` from Windows (no Tailscale)

Run the homelab cluster inside **WSL2** and reach its assigned hostnames
(`grafana.home.lan`, `hatchet.home.lan`, …) from a **Windows browser**.

## 1. Bring up the cluster (in WSL)

Follow [runbook-local.md](runbook-local.md) **inside your WSL distro** — `./install.sh`,
then `./components.sh deploy` for the add-ons. Everything there applies unchanged.

Two WSL specifics:
- Use Docker running in WSL (Docker Desktop's WSL integration, or native `docker` in
  the distro). k3d nodes are containers on a docker bridge inside WSL.
- **The WSL host needs a route to the LB pool** (the same "host caveat" from
  runbook-local — WSL has no bridged LAN NIC). Add it once per WSL session:
  ```bash
  CLUSTER=qube-$(. ./.env >/dev/null 2>&1; echo $LOCAL_HOST)
  BR=br-$(docker network ls --filter name=k3d-$CLUSTER --format '{{.ID}}')
  sudo ip route add 172.28.210.0/24 dev "$BR"        # = LB_CIDR from .env
  # verify: curl -s -o /dev/null -w '%{http_code}\n' --resolve whoami.home.lan:80:172.28.210.80 http://whoami.home.lan  -> 200
  ```

> Why not `kubectl port-forward`? The Cilium Gateway Service is **selectorless**
> (eBPF-managed), so port-forward can't attach. We forward to the Gateway's **LB IP**
> instead.

## 2. Expose the services on WSL's `0.0.0.0` (so Windows can reach them)

WSL2 forwards a port listening in WSL to Windows `localhost`. Run a TCP forwarder
(`socat`) from WSL ports → the cluster LB IPs. All HTTP hostnames share the Gateway IP
(`172.28.210.80`), so **one forwarder per port** covers every HTTP host.

```bash
sudo apt-get install -y socat

# HTTP + HTTPS gateway (covers grafana, hatchet, whoami, ... — routed by Host header).
# Keep these running (a terminal each, or append & / use tmux).
sudo socat TCP-LISTEN:80,fork,reuseaddr,bind=0.0.0.0  TCP:172.28.210.80:80
sudo socat TCP-LISTEN:443,fork,reuseaddr,bind=0.0.0.0 TCP:172.28.210.80:443
```

For raw-TCP services, forward each to its own LB IP (get them with the commands shown):
```bash
# discover the LB IPs:
kubectl get svc -A | awk '$3=="LoadBalancer"{printf "%-12s %-16s %s\n",$1,$2,$5}'
#   messaging   nats        172.28.210.54
#   cnpg-system homelab-pg  172.28.210.55
#   cnpg-system ferretdb    172.28.210.56

sudo socat TCP-LISTEN:5432,fork,reuseaddr,bind=0.0.0.0  TCP:172.28.210.55:5432   # postgres
sudo socat TCP-LISTEN:27017,fork,reuseaddr,bind=0.0.0.0 TCP:172.28.210.56:27017  # ferretdb
sudo socat TCP-LISTEN:4222,fork,reuseaddr,bind=0.0.0.0  TCP:172.28.210.54:4222   # nats
```

## 3. Tell Windows the hostnames point at localhost

Edit `C:\Windows\System32\drivers\etc\hosts` **as Administrator** (Notepad → Run as
administrator), add:
```
127.0.0.1  grafana.home.lan hatchet.home.lan whoami.home.lan
127.0.0.1  postgres.home.lan ferretdb.home.lan nats.home.lan
```
(`127.0.0.1` works because WSL2 maps Windows `localhost` to the WSL listeners.)

## 4. Browse from Windows

```
http://grafana.home.lan      http://hatchet.home.lan      http://whoami.home.lan
```
Windows `localhost:80` → WSL socat → Gateway `172.28.210.80:80` → routed by `Host`.

Quick check from PowerShell (bypasses the hosts file):
```powershell
curl.exe -i -H "Host: grafana.home.lan" http://127.0.0.1     # expect 302 -> /login
```

### HTTPS (internal CA)
```bash
# in WSL: export the CA
kubectl -n cert-manager get secret home-lab-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /mnt/c/Users/<you>/home-lab-ca.crt
```
```powershell
# in an Administrator PowerShell: trust it
certutil -addstore -f "Root" C:\Users\<you>\home-lab-ca.crt
```
Then `https://grafana.home.lan` validates against the `*.home.lan` wildcard.

## 5. TCP services from Windows
With the matching socat forwarders + hosts entries running:
```
psql  -h postgres.home.lan -U dbadmin -d appdb           # pw: components/components.secrets.env (in WSL)
mongosh mongodb://ferretdb.home.lan:27017
# NATS: any client at nats://nats.home.lan:4222
```

## Teardown
- Ctrl-C the `socat` processes; remove the lines from the Windows `hosts` file.
- `sudo ip route del 172.28.210.0/24 dev "$BR"` (optional; gone on WSL restart anyway).

## Notes / gotchas
- File is `hosts` (no extension) — Windows path above; in WSL it's `/etc/hosts`.
- WSL **mirrored** networking mode (`.wslconfig` `networkingMode=mirrored`) also works
  and can even reach the WSL IP directly; `bind=0.0.0.0` keeps both modes working.
- This overrides DNS on Windows (tests Gateway routing + TLS, not the cluster's
  CoreDNS). The zero-config alternative is the Tailscale subnet route
  ([runbook-tailscale.md](runbook-tailscale.md)); for the Tailscale+SSH variant from
  another machine see [misc/templ-tailscale-local-access.md](misc/templ-tailscale-local-access.md).
- If a forwarder dies when the cluster is recreated, the LB IPs are pinned
  (`172.28.210.53/.80`) but per-service IPs may shift — re-check with the `get svc` line.
