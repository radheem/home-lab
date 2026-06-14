# Runbook — WSL cluster, browse `*.home.lan` from Windows (no Tailscale)

Run the homelab cluster inside **WSL2** and reach its assigned hostnames
(`grafana.home.lan`, `hatchet.home.lan`, …) from a **Windows browser**.

## 0. Prerequisites
- **WSL2** with a Linux distro (Ubuntu 24.04 tested) and **Docker in WSL** (Docker
  Desktop WSL integration or native `docker`).
- In WSL — same CLIs/versions as [deploy-local.md](deploy-local.md):
  `docker 29.4.1 · k3d v5.8.3 · kubectl v1.31.0 · helm v3.18.2 · jq 1.7 · envsubst (gettext 0.21)`
  plus **`socat`** and **`tmux`** (`sudo apt-get install -y socat tmux`) for the
  `tools/lb-forward.sh` port forwarders.
- On **Windows**: a browser, Administrator access (to edit `hosts` + trust the CA).
- Full version matrix: [README Prerequisites](../../README.md#prerequisites).

## 1. Bring up the cluster (in WSL)

Follow [deploy-local.md](deploy-local.md) **inside your WSL distro** — `./install.sh`,
then `./components.sh deploy` for the add-ons. Everything there applies unchanged.

Two WSL specifics:
- Use Docker running in WSL (Docker Desktop's WSL integration, or native `docker` in
  the distro). k3d nodes are containers on a docker bridge inside WSL.
- **The WSL host needs a route to the LB pool** (the same "host caveat" from
  deploy-local.md — WSL has no bridged LAN NIC). Add it once per WSL session:
  ```bash
  CLUSTER=$(. ./.env >/dev/null 2>&1; echo $LOCAL_HOST)
  BR=br-$(docker network ls --filter name=k3d-$CLUSTER --format '{{.ID}}')
  sudo ip route add 172.28.210.0/24 dev "$BR"        # = LB_CIDR from .env
  # verify: curl -s -o /dev/null -w '%{http_code}\n' --resolve whoami.home.lan:80:172.28.210.80 http://whoami.home.lan  -> 200
  ```

> Why not `kubectl port-forward`? The Cilium Gateway Service is **selectorless**
> (eBPF-managed), so port-forward can't attach. We forward to the Gateway's **LB IP**
> instead.

## 2. Expose the services on WSL's `0.0.0.0` (so Windows can reach them)

WSL2 forwards a port listening in WSL to Windows `localhost`. Use the helper
`tools/lb-forward.sh` — it reads the Gateway/DNS LB IPs from `.env` and runs `socat`
forwarders in a **detached tmux session** (so they survive your terminal). All HTTP
hostnames share the Gateway IP, so one forwarder per port covers every HTTP host.

```bash
sudo apt-get install -y socat tmux

# DNS(53 udp+tcp) + Gateway(80,443) from .env — sudo because ports <1024:
sudo ./tools/lb-forward.sh up

# raw-TCP services have per-deploy LB IPs — pass them with --ip:
kubectl get svc -A | awk '$3=="LoadBalancer"{printf "%-12s %-16s %s\n",$1,$2,$5}'
sudo ./tools/lb-forward.sh add 5432  5432  --ip <postgres-LB-IP> --name postgres
sudo ./tools/lb-forward.sh add 27017 27017 --ip <ferretdb-LB-IP> --name ferretdb
sudo ./tools/lb-forward.sh add 4222  4222  --ip <nats-LB-IP>     --name nats

./tools/lb-forward.sh status      # list forwarders + listeners
./tools/lb-forward.sh down        # stop them all (kills the tmux session)
# inspect a forwarder live:  tmux attach -t lb-forward   (detach: Ctrl-b d)
```

> Prefer no sudo? Use high host ports (`add 8080 80 --to gateway`) and hit
> `localhost:8080` from Windows. Manual one-off equivalent:
> `socat TCP4-LISTEN:80,fork,reuseaddr,bind=0.0.0.0 TCP4:<gateway-LB-IP>:80`.

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
  ([tailscale-access.md](tailscale-access.md)); for the Tailscale+SSH variant from
  another machine see [misc/templ-tailscale-local-access.md](../misc/templ-tailscale-local-access.md).
- If a forwarder dies when the cluster is recreated, the LB IPs are pinned
  (`172.28.210.53/.80`) but per-service IPs may shift — re-check with the `get svc` line.
