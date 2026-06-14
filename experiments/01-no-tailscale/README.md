# Experiment 01 — Zero-touch DNS + ingress, no Tailscale

## Goal
Prove the core promise of the setup on the **local network only**: bring up the
cluster, deploy the `echo` app declaratively, and reach it **by name**
(`echo.home.lan`) with no manual DNS edits — verified with `dig` and `curl`.

Specifically, confirm:
1. `install.sh` (without `--with-router`) brings the whole stack up clean.
2. ExternalDNS auto-publishes `echo.home.lan` into etcd from the HTTPRoute.
3. The authoritative CoreDNS answers `echo.home.lan` → Gateway LB IP.
4. The Cilium Gateway routes the HTTP request to the echo pod.

## Environment (from `.env`)
| Key | Value |
|-----|-------|
| Cluster | `homelab` |
| TLD | `home.lan` |
| Authoritative DNS (LB IP) | `172.28.210.53:53` |
| Shared Gateway (LB IP) | `172.28.210.80:80/443` |
| LB pool | `172.28.210.0/24` |
| Tailscale | **disabled** |

## Constraints / assumptions
- Tailscale router is **off** — this experiment does not test remote access.
- The LAN router is **not yet** conditional-forwarding `home.lan`, so name-based
  `curl` from a normal device may not resolve. We therefore verify two ways:
  - `dig` directly against the authoritative server `@172.28.210.53` (proves DNS).
  - `curl --resolve` pinned to the Gateway IP (proves routing) — independent of
    whether the LAN router forwards yet.
- LB IPs must be ARP-reachable on the host's `eth0` segment (Cilium L2).

## Method
```bash
cd /home/radr/pers/k3d-lab
./install.sh --verbose                       # no --with-router

# deploy echo
cd test/echo
set -a; source ../../.env; set +a
kubectl kustomize . | envsubst '${LOCAL_TLD}' | kubectl apply -f -
kubectl -n echo rollout status deploy/echo

# verify DNS (authoritative server)
dig @172.28.210.53 echo.home.lan +short      # expect 172.28.210.80

# verify ExternalDNS wrote the record
kubectl -n external-dns logs deploy/external-dns | grep -i echo
kubectl -n dns-system exec etcd-0 -- etcdctl get --prefix /skydns

# verify routing (independent of LAN DNS)
curl -s --resolve echo.home.lan:80:172.28.210.80 http://echo.home.lan | jq .host

# verify name-based (only after router forwards home.lan -> 172.28.210.53)
curl -s http://echo.home.lan | jq .host
```

## Success criteria
- `dig @172.28.210.53 echo.home.lan` returns `172.28.210.80`.
- `curl --resolve ...` returns echo JSON with `"host": "echo.home.lan"`.
- etcd contains a `/skydns/.../echo` record.

## Outcome
**PASS (2026-06-14).** Zero-touch DNS + ingress verified end-to-end from the host:
`dig @172.28.210.53 echo.home.lan` → `172.28.210.80`, `curl` via the Gateway returns
the echo-server JSON, and `example.com` resolves via upstream forwarding. The run
surfaced **5 bugs**, all fixed and committed to the repo so a fresh `./install.sh`
reproduces the working state:

1. `.env` `UPSTREAM_DNS` needed quoting (space in value).
2. `CLUSTER_SUBNET` overlapped `docker_default` → `172.21.50.0/24`.
3. ExternalDNS ClusterRole missing `namespaces` (gateway-httproute source).
4. ExternalDNS + CoreDNS-auth couldn't reach etcd by hostname (gRPC resolver +
   inherited search domains) → pinned `etcd-client` ClusterIP, referenced by IP.
5. DNS LB IP unreachable when its L2 lease landed on a node without a local pod →
   coredns-auth became a DaemonSet with `externalTrafficPolicy: Local`.

Env caveat (this AWS host only): a host route `ip route add 172.28.210.0/24 dev
br-<k3dnet>` was required to ARP the LB IPs across the docker bridge. A real home
host with a bridged NIC does not need it. See [journal/](journal/) for the detail.
