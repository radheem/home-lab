# k3d-lab — declarative home-lab k8s with zero-touch LAN DNS

A clean, declarative k3d setup. Deploy an app, attach an `HTTPRoute` with a
`*.home.lan` hostname, and it becomes reachable by name from any device on your
Wi-Fi — **no manual DNS edits**. DNS records are published automatically by
ExternalDNS into an authoritative CoreDNS that your LAN queries directly.

## Architecture

```
                LAN device (dig whoami.home.lan)
                          │  router conditional-forwards *.home.lan
                          ▼
        ┌──────────────── authoritative CoreDNS ────────────────┐
        │  Service type=LoadBalancer  @ 172.28.240.53:53 (L2/ARP) │
        │  zone home.lan -> etcd (/skydns)                        │
        │  zone .        -> forward 1.1.1.1 9.9.9.9               │
        └───────────────▲───────────────────────────────────────┘
                         │ reads                  ▲ writes records
                       etcd  ◄──────────────  ExternalDNS
                                              (--source=gateway-httproute)
                                                     │ watches
   app: Deployment + Service + HTTPRoute(whoami.home.lan) ──┘
                         │ attaches to
        ┌──────────── shared Cilium Gateway ─────────────┐
        │  LoadBalancer @ 172.28.240.80  :80 / :443(TLS) │
        │  wildcard cert *.home.lan  (cert-manager CA)    │
        └─────────────────────────────────────────────────┘

   CNI/datapath: Cilium (kube-proxy replacement, native routing,
   L2 announcements + LB-IPAM, Gateway API, Hubble).
   Storage: k3s local-path provisioner -> ${CLUSTER_VOLUME_STORE} on the host.
```

Two CoreDNS instances by design: the **cluster** CoreDNS (kube-dns, `cluster.local`)
and a separate **authoritative** CoreDNS for `home.lan` exposed to the LAN. The
cluster one forwards `home.lan` to the authoritative LB IP so pods resolve it too.

## Quickstart

```bash
cp .env.example .env        # edit IPs/TLD/storage to match your network
./install.sh                # one-click (add --with-router for Tailscale, --verbose to debug)
```

Then point your LAN at the DNS (one of):
- **Router (recommended):** conditional-forward the zone `home.lan` → `172.28.240.53`.
- **Per device:** set `172.28.240.53` as the DNS server.

Verify:
```bash
export KUBECONFIG=$PWD/kubeconfig-homelab.yaml
dig @172.28.240.53 whoami.home.lan +short     # -> 172.28.240.80
curl -H 'Host: whoami.home.lan' http://172.28.240.80
```

## Add your own app (the whole contract)

Copy `manifests/50-examples/whoami.yaml`: a Deployment, a Service, and an
`HTTPRoute` whose `parentRefs` point at `shared-gateway` (ns `gateway-system`)
with a `*.home.lan` hostname. Nothing else — DNS + HTTPS are automatic.

## Layout

| Path | What |
|------|------|
| `.env.example` | All tunables (copy to `.env`, gitignored) |
| `install.sh` / `uninstall.sh` | One-click lifecycle |
| `lib/common.sh` | Logging, env load, render+apply helpers |
| `config/` | k3d config, Cilium + cluster-CoreDNS Helm values (templated) |
| `manifests/00..50` | Kustomize overlays applied in order |
| `tailscale/` | Optional subnet router + `approve-route.sh` (`--with-router`) |
| `docs/` | Runbooks, troubleshooting, cert-manager notes |
| `experiments/` | End-to-end validation runs (local, tailscale, remote approval) |

## Runbooks & experiments
- How it all fits together (diagrams): [docs/architecture.md](docs/architecture.md)
- Deploy + verify locally: [docs/runbook-local.md](docs/runbook-local.md)
- Deploy + verify over Tailscale: [docs/runbook-tailscale.md](docs/runbook-tailscale.md)
- WSL cluster + browse from Windows: [docs/runbook-wsl-windows.md](docs/runbook-wsl-windows.md)
- Add-on components (monitoring/messaging/workflow/db): [docs/runbook-components.md](docs/runbook-components.md) — selectable via [components/](components/)
- Validation history & gotchas: [experiments/](experiments/) (01 local ✅, 02 tailscale ⏸, 03 remote approval 📐)

## TLS

`./install.sh` deploys cert-manager with an **internal CA** that issues a
`*.home.lan` wildcard for the Gateway. Trust it once per device:
```bash
kubectl -n cert-manager get secret home-lab-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > home-lab-ca.crt
```
Public ACME DNS-01 is **not possible for an internal-only TLD** — see
[`docs/cert-manager.md`](docs/cert-manager.md).

See [`docs/troubleshooting.md`](docs/troubleshooting.md) when something misbehaves.
