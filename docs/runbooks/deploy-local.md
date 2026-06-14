# Runbook — Local / LAN deployment (no Tailscale)

Bring up the cluster and verify zero-touch DNS + ingress on the local network.
Validated end-to-end in [Experiment 01](https://github.com/radheem/home-lab/tree/main/experiments/01-no-tailscale).

> Conventions: `CLUSTER_NAME=<LOCAL_HOST>` (e.g. `homelab`); set
> `export KUBECONFIG=$PWD/kubeconfig-$CLUSTER_NAME.yaml` after install. Values below
> use the defaults `DNS_LB_IP=172.28.210.53`, `GATEWAY_LB_IP=172.28.210.80`,
> `LOCAL_TLD=home.lan` — adjust to your `.env`.

## 1. Prerequisites
- Tools (the installer checks these) — tested versions:
  `docker 29.4.1 · k3d v5.8.3 · kubectl v1.31.0 · helm v3.18.2 · jq 1.7 · envsubst (gettext 0.21)`.
  `kubectl kustomize` is used, so no standalone `kustomize` is needed.
- Docker running; ports free; outbound internet (Helm charts, images, Gateway CRDs).
- OS tested: Ubuntu 24.04 LTS (kernel 6.17). Pinned platform versions (k3s/Cilium/
  Gateway API/cert-manager) live in `.env` — see the [README Prerequisites](https://github.com/radheem/home-lab/blob/main/README.md#prerequisites).

## 2. Configure `.env`
```bash
cd k3d-lab
cp .env.example .env      # if not already
$EDITOR .env
```
Checklist (lessons from Exp 01):
- `UPSTREAM_DNS` **must be quoted** — it has a space: `UPSTREAM_DNS="1.1.1.1 9.9.9.9"`.
- `CLUSTER_SUBNET` must **not overlap an existing docker network**. Check:
  ```bash
  docker network ls -q | xargs -r docker network inspect \
    -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'
  ```
  Pick a free /24 (e.g. `172.21.50.0/24`).
- `LB_CIDR` / `DNS_LB_IP` / `GATEWAY_LB_IP` on a subnet your LAN can ARP (bridged to
  the node NIC). The two pinned IPs must be inside `LB_CIDR`.

## 3. Deploy
```bash
./install.sh                 # add --verbose to trace
export KUBECONFIG=$PWD/kubeconfig-$(. ./.env >/dev/null 2>&1; echo $CLUSTER_NAME).yaml
```
The installer: creates the cluster → Cilium (Gateway API, L2, LB-IPAM) → cluster
CoreDNS → etcd + authoritative CoreDNS → ExternalDNS → cert-manager (+wildcard) →
shared Gateway → demo `whoami`.

## 4. Health checks
```bash
kubectl get nodes                                   # all Ready
kubectl get pods -A | grep -ivE 'Running|Completed' # (empty == healthy)
kubectl -n dns-system get svc coredns-auth          # EXTERNAL-IP == DNS_LB_IP
kubectl -n gateway-system get gateway shared-gateway # PROGRAMMED=True, ADDRESS==GATEWAY_LB_IP
kubectl -n external-dns logs deploy/external-dns --tail=5   # no crash/etcd errors
```

## 5. Deploy a test app (echo)
```bash
set -a; source .env; set +a
kubectl kustomize test/echo | envsubst '${LOCAL_TLD}' | kubectl apply -f -
kubectl -n echo rollout status deploy/echo
kubectl -n echo get httproute echo -o jsonpath='{.status.parents[0].conditions[*].type}={.status.parents[0].conditions[*].status}{"\n"}'
# expect: Accepted=True ResolvedRefs=True
```

## 6. Verify the pipeline
```bash
# record published in etcd by ExternalDNS:
kubectl -n dns-system exec etcd-0 -- etcdctl get --prefix /skydns | grep -A1 echo

# authoritative DNS answers (query the LB IP directly):
dig @172.28.210.53 echo.home.lan +short          # -> 172.28.210.80
dig @172.28.210.53 example.com  +short | head -1 # upstream forward works

# HTTP through the Gateway:
curl -s --resolve echo.home.lan:80:172.28.210.80 http://echo.home.lan | jq .host
```

## 7. Make it usable LAN-wide
Point your router to forward the zone to the DNS LB IP:
- **Router (recommended):** conditional-forward `home.lan` → `172.28.210.53`.
- **Per device:** set `172.28.210.53` as the DNS server.
Then any device resolves `*.home.lan` and `curl http://echo.home.lan` works by name.

### Host-on-the-same-box caveat (non-bridged / cloud hosts)
If the host has no bridged LAN NIC (e.g. a cloud VM), it can't ARP the L2-announced
LB IPs by default. Add a route to the k3d bridge so the host can reach them:
```bash
BR=br-$(docker network ls --filter name=k3d-$CLUSTER_NAME --format '{{.ID}}')
sudo ip route add <LB_CIDR> dev "$BR"      # e.g. 172.28.210.0/24
```
On a real home host with a bridged NIC this is unnecessary.

### L2 / LoadBalancer note
LB-announced services must use a node that has a local backend. Per-node services
(the Cilium Gateway Envoy) are fine; for plain Deployments behind an LB IP, run them
as a **DaemonSet** with `externalTrafficPolicy: Local` (as `coredns-auth` does) so the
node holding the L2 lease always has a local pod. See Exp 01 bug #5.

## 8. TLS (optional)
Trust the internal CA so `https://*.home.lan` validates:
```bash
kubectl -n cert-manager get secret home-lab-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > home-lab-ca.crt
# install home-lab-ca.crt into your OS/browser trust store (see docs/cert-manager.md)
```

## 9. Teardown
```bash
kubectl delete ns echo                 # remove test app
./uninstall.sh                         # delete cluster (+ --purge-data to wipe PVCs)
sudo ip route del <LB_CIDR> dev "$BR"  # if you added the host route
```

Problems? See [troubleshooting.md](../troubleshooting.md).
