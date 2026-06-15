# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-06-15

First tagged release — a declarative, single-host k3d home-lab platform with
zero-touch LAN DNS, automatic wildcard TLS, a selectable add-on stack, and an
optional in-cluster image registry.

### Added

#### Platform
- Declarative **k3d** cluster running **kube-proxy-free** with **Cilium** as the sole
  CNI: eBPF datapath, native routing, **L2 announcements + LB-IPAM** (bare-Docker
  `LoadBalancer` IPs), Gateway API, and Hubble.
- **Zero-touch LAN DNS**: **ExternalDNS** publishes `HTTPRoute`/`Service` hostnames into
  **etcd**, served by an authoritative **CoreDNS** for the local zone; a separate cluster
  `kube-dns` forwards the zone so pods resolve it too. Pinned LB IPs for DNS and Gateway.
- **Wildcard TLS** for the shared **Cilium Gateway** via a **cert-manager** internal CA
  (`*.<LOCAL_TLD>`); trust the CA once per device.
- One-click `install.sh` / `uninstall.sh`; `.env`-driven and version-pinned
  (k3s, Cilium, Gateway API, cert-manager, CoreDNS, ExternalDNS).

#### In-cluster image registry (`--with-registry`)
- Push images from any LAN device to `registry.<LOCAL_TLD>` and have the k3s nodes pull
  them by the same name — no more `k3d image import` from the host.
- Registry exposed on a **dedicated pinned LB IP** with **HTTPS via the internal CA**
  (cert SANs cover both the hostname and the IP) and an auto-published DNS record;
  **no auth** by default.
- Node-side pulls wired at cluster-create via a k3s `registries.yaml` mirror
  (`registry.<LOCAL_TLD>` → the registry's LB IP), so nodes don't depend on LAN DNS.
- `manifests/60-registry/`, `config/k3d-registries.yaml`, and the `--with-registry`
  installer flag.

#### Add-ons & access
- Selectable **component registry** (monitoring / messaging / workflow / database):
  VictoriaMetrics, OpenTelemetry, Grafana, NATS, Hatchet, CloudNativePG, FerretDB,
  node-exporter — deployed via `components/components.sh`.
- Optional **Tailscale / Headscale** subnet router (`--with-router`) and
  `tools/lb-forward.sh` for reaching LB IPs across hosts.

#### Docs & tests
- Runbooks: deploy locally, deploy/add components (day-2), Tailscale access,
  WSL → Windows, **image registry** (incl. enabling auth), and **pulling from a private
  external registry** (Docker Hub).
- MkDocs Material site published to GitHub Pages.
- `test/echo` and `test/registry` (end-to-end push-then-deploy check for the registry).

[0.0.1]: https://github.com/radheem/home-lab/releases/tag/v0.0.1
