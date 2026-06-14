# Architecture

k3d-lab is a single-host Kubernetes home-lab (k3s-in-Docker via k3d) whose defining
feature is **zero-touch DNS**: deploy an app with an `HTTPRoute` carrying a
`*.home.lan` hostname and it becomes reachable by name from the LAN — no manual DNS,
no per-app config. This document explains how the pieces fit together.

> Values below use the `.env.example` defaults: TLD `home.lan`, LB pool
> `172.28.210.0/24`, authoritative DNS `172.28.210.53`, shared Gateway
> `172.28.210.80`, pod CIDR `10.42.0.0/16`, service CIDR `10.43.0.0/16`.

## 1. The big picture

```mermaid
flowchart TB
    subgraph LAN["Local network / Tailnet"]
        dev["Device<br/>(laptop, phone)"]
        router["LAN router<br/>conditional-forward<br/>home.lan -> 172.28.210.53"]
    end

    subgraph host["Single host (Docker)"]
        subgraph k3d["k3d cluster (k3s nodes as containers)"]
            cil["Cilium datapath<br/>kube-proxy replacement · L2 · LB-IPAM · Gateway API"]

            subgraph dnsns["ns: dns-system"]
                cdnsauth["CoreDNS (authoritative)<br/>DaemonSet · LB 172.28.210.53:53<br/>zone home.lan + forward 1.1.1.1"]
                etcd["etcd<br/>record store (/skydns)"]
            end
            edns["ExternalDNS<br/>ns: external-dns"]
            gw["Cilium Gateway<br/>ns: gateway-system<br/>LB 172.28.210.80 :80/:443"]
            kdns["cluster CoreDNS (kube-dns)<br/>ns: kube-system · 10.43.0.10"]
            cm["cert-manager<br/>internal CA -> *.home.lan"]

            subgraph appns["ns: echo / demo / ..."]
                app["App Pod + Service"]
                hr["HTTPRoute<br/>host: app.home.lan"]
            end
        end
        store[("host disk<br/>local-path PVCs")]
    end

    dev -->|"DNS query *.home.lan"| router --> cdnsauth
    dev -->|"HTTP/HTTPS"| gw --> app
    hr -. attaches .-> gw
    edns -->|watch HTTPRoutes| hr
    edns -->|write A records| etcd
    cdnsauth -->|read zone| etcd
    kdns -->|"forward home.lan"| cdnsauth
    cm -->|wildcard TLS secret| gw
    etcd --- store
    app --- store
    cil -.-> cdnsauth & gw & app
```

## 2. Two DNS planes (and why)

There are **two** CoreDNS deployments with distinct jobs. Merging them onto one
host-exposed resolver is a footgun, so they stay separate.

```mermaid
flowchart LR
    subgraph cluster["in-cluster resolution"]
        pod["any Pod"] -->|"/etc/resolv.conf<br/>10.43.0.10"| kdns["cluster CoreDNS<br/>(kube-dns)"]
        kdns -->|"cluster.local"| ksvc["k8s services"]
        kdns -->|"home.lan zone"| auth
    end
    subgraph lan["LAN resolution"]
        client["LAN device"] -->|":53 @172.28.210.53"| auth["authoritative CoreDNS"]
    end
    auth -->|"zone home.lan<br/>etcd plugin"| etcd[("etcd /skydns")]
    auth -->|"everything else"| up["upstream<br/>1.1.1.1 · 9.9.9.9"]
```

- **Cluster CoreDNS (kube-dns)** — serves `cluster.local`; pods point at it
  (`10.43.0.10`). It also forwards the `home.lan` zone to the authoritative server so
  pods can resolve lab hostnames too.
- **Authoritative CoreDNS** — owns `home.lan`. Reads records from etcd (written by
  ExternalDNS) and forwards anything else to public upstreams. Exposed to the LAN on
  a pinned Cilium LoadBalancer IP `172.28.210.53` as a **DaemonSet** with
  `externalTrafficPolicy: Local` (so the node holding the L2 lease always has a local
  backend — see [experiment 01](../experiments/01-no-tailscale/) bug #5).

## 3. Zero-touch publish flow

What happens when you deploy an app and its `HTTPRoute`:

```mermaid
sequenceDiagram
    actor U as You
    participant K as kube-apiserver
    participant E as ExternalDNS
    participant ETCD as etcd (/skydns)
    participant C as CoreDNS (authoritative)
    U->>K: kubectl apply HTTPRoute (host app.home.lan -> shared-gateway)
    E->>K: watch HTTPRoutes + parent Gateway
    Note over E: derive app.home.lan -> Gateway LB IP 172.28.210.80
    E->>ETCD: write A record + TXT ownership
    C->>ETCD: read zone home.lan (etcd plugin)
    Note over C: app.home.lan now answerable
    U-->>C: dig @172.28.210.53 app.home.lan
    C-->>U: 172.28.210.80
```

ExternalDNS uses `--source=gateway-httproute` and `--provider=coredns`, talking to
etcd at a pinned ClusterIP **by IP** (`10.43.0.20`) to avoid a gRPC-resolver issue
with k8s hostnames ([experiment 01](../experiments/01-no-tailscale/) bug #4).

## 4. End-to-end request path

```mermaid
sequenceDiagram
    actor D as LAN device
    participant R as Router (fwd home.lan)
    participant DNS as CoreDNS auth (172.28.210.53)
    participant GW as Cilium Gateway (172.28.210.80)
    participant S as App Service
    participant P as App Pod
    D->>R: resolve app.home.lan
    R->>DNS: query home.lan zone
    DNS-->>D: 172.28.210.80 (Gateway IP)
    D->>GW: HTTP/HTTPS Host: app.home.lan
    Note over GW: HTTPRoute hostname match + TLS terminate (wildcard cert)
    GW->>S: route to backend
    S->>P: load-balance (Cilium eBPF)
    P-->>D: response
```

## 5. Networking (Cilium)

Cilium replaces flannel, kube-proxy, and servicelb. k3s ships none of those (disabled
in `config/k3d-config.yaml`).

```mermaid
flowchart TB
    subgraph cilium["Cilium"]
        kpr["kube-proxy replacement<br/>(eBPF service LB)"]
        nat["native routing<br/>pod CIDR 10.42.0.0/16"]
        gwapi["Gateway API<br/>(GatewayClass: cilium)"]
        lbipam["LB-IPAM<br/>pool 172.28.210.0/24"]
        l2["L2 announcements<br/>ARP on eth0"]
        hub["Hubble (flow observability)"]
    end
    svc["Service type=LoadBalancer<br/>(coredns-auth, gateway)"] --> lbipam
    lbipam -->|assign pinned IP| svc
    svc --> l2
    l2 -->|"ARP reply on LAN segment"| ext["LAN devices reach LB IPs"]
    gwapi --> gwsvc["per-Gateway LB Service"] --> lbipam
```

- **LB-IPAM** hands IPs from `172.28.210.0/24`; services pin theirs with
  `lbipam.cilium.io/ips`.
- **L2 announcements** answer ARP for those IPs on the node `eth0` segment, making
  them reachable on the LAN without an external load balancer.
- **Gateway API** is served natively by Cilium's Envoy — the shared Gateway is the
  single HTTP/HTTPS entrypoint (`172.28.210.80`).

## 6. TLS (cert-manager)

Local TLS for an internal TLD uses an internal CA (public ACME can't validate
`home.lan`). See [cert-manager.md](cert-manager.md).

```mermaid
flowchart LR
    ssi["ClusterIssuer<br/>selfsigned-bootstrap"] --> caCert["Certificate: home-lab-ca<br/>(isCA) -> secret home-lab-ca-tls"]
    caCert --> caIssuer["ClusterIssuer: home-lab-ca<br/>(CA)"]
    caIssuer --> wc["Certificate: wildcard-tls<br/>*.home.lan -> secret in gateway-system"]
    wc --> gwl["Gateway HTTPS listener<br/>terminates TLS"]
    trust["trust home-lab-ca.crt<br/>on devices (once)"] -.-> gwl
```

## 7. Storage

```mermaid
flowchart LR
    pvc["PVC (etcd, apps)"] --> sc["StorageClass: local-path<br/>(k3s provisioner)"]
    sc --> mnt["/var/lib/rancher/k3s/storage<br/>in each node"]
    mnt --> hostdir[("CLUSTER_VOLUME_STORE<br/>on host disk")]
```

The k3s local-path provisioner backs all PVCs; the node mount is bind-mounted to a
host directory (`CLUSTER_VOLUME_STORE`), so data persists on the device.

## 8. Remote access (optional, Tailscale)

A subnet router advertises the LB pool to a Headscale tailnet, so the same LB IPs are
reachable remotely. The advertised route must be approved (see
[runbook-tailscale.md](runbook-tailscale.md) and
[experiment 03](../experiments/03-remote-route-approval/)).

```mermaid
flowchart LR
    remote["Remote tailnet device"] -->|"100.64.x"| tailnet(("Headscale tailnet"))
    tailnet --> tsr["subnet-router Pod<br/>ns: tailscale-lb<br/>advertises 172.28.210.0/24"]
    tsr --> lbips["LB IPs<br/>172.28.210.53 (DNS)<br/>172.28.210.80 (Gateway)"]
    api["approve-route.sh<br/>(Headscale API key)"] -.->|enable route| tailnet
```

## 9. Component inventory

| Namespace | Component | Kind | Purpose |
|-----------|-----------|------|---------|
| `kube-system` | Cilium + operator | DaemonSet/Deploy | CNI, service LB, Gateway, L2, LB-IPAM |
| `kube-system` | CoreDNS (kube-dns) | Deployment | cluster DNS (`10.43.0.10`) + `home.lan` forward |
| `dns-system` | etcd | StatefulSet | DNS record store (`/skydns`), PVC on host |
| `dns-system` | CoreDNS (authoritative) | DaemonSet | serves `home.lan`, LB `172.28.210.53:53` |
| `external-dns` | ExternalDNS | Deployment | HTTPRoute -> etcd record automation |
| `gateway-system` | shared-gateway | Gateway | HTTP/HTTPS entrypoint, LB `172.28.210.80` |
| `cert-manager` | cert-manager | Deployments | internal CA, `*.home.lan` wildcard cert |
| `tailscale-lb` | subnet-router | Deployment | (optional) advertise LB pool to tailnet |
| `echo`/`demo` | echo / whoami | Deploy+Svc+HTTPRoute | example/test workloads |

## 10. Key design decisions

- **Two CoreDNS planes** keep cluster DNS and LAN-authoritative DNS isolated.
- **Pinned LB IPs** (DNS `.53`, Gateway `.80`) give stable, reboot-safe targets the
  router can forward to.
- **etcd addressed by IP** (`10.43.0.20`) sidesteps a gRPC hostname-resolution issue.
- **Authoritative CoreDNS as DaemonSet + `externalTrafficPolicy: Local`** so L2
  ingress always lands on a node with a local backend.
- **Internal CA for TLS** because public ACME can't issue for a local-only TLD.

All of these were validated (and several discovered) in the
[experiments](../experiments/).
