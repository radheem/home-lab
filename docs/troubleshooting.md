# Troubleshooting

Set the context first:
```bash
export KUBECONFIG=$PWD/kubeconfig-<CLUSTER_NAME>.yaml
kubectl get pods -A
```

## Install / storage permissions

**`install.sh` fails creating the volume dir, or PVCs/pods can't write (permission denied)**
- `CLUSTER_VOLUME_STORE` (default `/db/srv/k3d-store`) is the host path that backs the
  k3s local-path provisioner (and the `/data` PVCs on it). If you don't own `/db` — or
  it doesn't exist / is read-only — `install.sh` (`mkdir -p`) or PVC provisioning fails.
- Pick **one**:
  - Point it at a directory you own, in `.env`:
    ```ini
    CLUSTER_VOLUME_STORE=$HOME/k3d-store      # or any path you can write
    ```
  - Or create the path and fix ownership/permissions:
    ```bash
    sudo mkdir -p /db/srv/k3d-store
    sudo chown -R "$(id -u):$(id -g)" /db/srv/k3d-store
    chmod -R u+rwX /db/srv/k3d-store
    ```
- Symptoms to confirm it's storage: install error at "Creating directory
  $CLUSTER_VOLUME_STORE", PVCs stuck `Pending`, or pods (etcd/postgres/grafana)
  CrashLooping on mount/permission errors:
  ```bash
  kubectl get pvc -A
  kubectl -n kube-system logs -l app=local-path-provisioner   # provisioner errors
  ```

**`install.sh` stuck at "Waiting for API server" / `kubectl: lookup <host>: no such host`**
- The kubeconfig's `server:` was set to `API_SERVER_FQDN` (from `.env`), which doesn't
  resolve on this machine. `install.sh` now rewrites the **local** kubeconfig to
  `https://127.0.0.1:${API_SERVER_PORT}` (127.0.0.1 is a TLS SAN), so pull latest and
  re-run. On an older checkout, fix the file in place:
  ```bash
  sed -i -E 's#(server: https://)[^:/]+(:16443)#\1127.0.0.1\2#' kubeconfig-<CLUSTER>.yaml
  ```
- `API_SERVER_FQDN` is only for **remote** API access (Tailscale/LAN), where that name
  is pointed at the host. It is unrelated to resolving **service** hostnames
  (`*.home.lan`) — for that see "Make it usable LAN-wide" in
  [runbook-local.md](runbook-local.md) (router conditional-forward or per-device DNS to
  the authoritative server `DNS_LB_IP`), or add `/etc/hosts` entries.

## DNS resolution

**`dig @172.28.210.53 whoami.home.lan` returns nothing / times out**
1. Is the LB IP actually assigned and announced?
   ```bash
   kubectl -n dns-system get svc coredns-auth          # EXTERNAL-IP should be 172.28.210.53
   kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy
   ```
   If `EXTERNAL-IP` is `<pending>`: the IP isn't in `LB_CIDR`, or no pool exists. If it's assigned but unreachable from the LAN, L2/ARP isn't working — confirm the policy `interfaces: ^eth0$` matches the node NIC, and that `LB_CIDR` is on a subnet your LAN can ARP for (bridged, not NAT'd behind the host).
2. Did ExternalDNS write the record?
   ```bash
   kubectl -n external-dns logs deploy/external-dns | grep -i whoami
   kubectl -n dns-system exec etcd-0 -- etcdctl get --prefix /skydns
   ```
   No record? Check the HTTPRoute has a `*.home.lan` hostname, a valid `parentRefs`,
   and that the parent Gateway has an address (`kubectl -n gateway-system get gateway`).
   Also confirm `--domain-filter` matches your TLD.
3. Authoritative CoreDNS healthy?
   ```bash
   kubectl -n dns-system logs deploy/coredns-auth
   kubectl -n dns-system exec deploy/coredns-auth -- nslookup whoami.home.lan 127.0.0.1
   ```

**External names don't resolve (e.g. `dig @172.28.210.53 example.com` fails)**
- The `.:53` block forwards to `${UPSTREAM_DNS}`. Check egress from the cluster and
  that those resolvers are reachable. Edit `UPSTREAM_DNS` in `.env` and re-apply.

**In-cluster pods can't resolve `*.home.lan`**
- The cluster CoreDNS needs the `home.lan -> ${DNS_LB_IP}` forward stanza:
  `kubectl -n kube-system get cm coredns -o yaml`. Re-run the cluster-CoreDNS helm step.

**ExternalDNS records never delete / stale entries**
- Policy is `sync`; if you switched from `upsert-only`, stale TXT ownership records
  may linger. Inspect `etcdctl get --prefix /skydns` and delete orphans, or change
  `--txt-owner-id`. If the `coredns` provider mis-handles the TXT registry, switch
  the arg to `--registry=noop` (records still work; you lose ownership tracking).

## Ingress / Gateway routing

**`curl http://whoami.home.lan` connection refused / no route**
```bash
kubectl -n gateway-system describe gateway shared-gateway      # Programmed? address assigned?
kubectl -n demo describe httproute whoami                      # Accepted + ResolvedRefs True?
kubectl -n gateway-system get svc                              # cilium-gateway-* svc has the LB IP?
```
- Gateway not `Programmed`: Cilium Gateway support requires `gatewayAPI.enabled`
  (it is, in `cilium-values.yaml`) **and** the Gateway API CRDs installed before
  Cilium reconciles. Restart the operator if needed: `kubectl -n kube-system rollout restart deploy/cilium-operator`.
- HTTPRoute `Accepted=False` with "NoMatchingParent": the listener `hostname`
  (`*.home.lan`) must cover the route hostname, and `allowedRoutes.namespaces.from: All`
  must be set (it is).

**Gateway LB IP not pinned to `GATEWAY_LB_IP`**
- Cilium honors `lbipam.cilium.io/ips` on the generated service and the Gateway
  `spec.addresses`. If it still floats, give it a dedicated pool with a
  `serviceSelector`, or check for IP conflicts in `LB_CIDR`.

**HTTPS cert errors**
```bash
kubectl -n gateway-system get certificate wildcard-tls
kubectl -n gateway-system describe certificate wildcard-tls
kubectl -n cert-manager logs deploy/cert-manager
```
- `wildcard-tls` not Ready usually means the `home-lab-ca` ClusterIssuer isn't ready
  (its CA secret `home-lab-ca-tls` hasn't been issued yet). Check the chain order.

## Cluster networking (Cilium)

**Cilium pods CrashLoop / `bpf` mount errors**
- Re-run the bpffs mount: `docker exec <node> mount bpffs /sys/fs/bpf -t bpf`.
- `cilium status`: `kubectl -n kube-system exec ds/cilium -- cilium status --verbose`.

**After a host reboot, LB IPs don't come back / IPAM split-brain**
- Cilium can keep stale `CiliumNode` IPs after node IP churn. Purge and let the
  operator recreate them:
  ```bash
  kubectl delete ciliumnodes --all
  kubectl -n kube-system rollout restart ds/cilium
  ```

## Observability

```bash
kubectl -n dns-system logs -f deploy/coredns-auth          # DNS query hit log
kubectl -n kube-system exec ds/cilium -- hubble observe    # live flows
# Hubble UI:
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```

## Components & monitoring

**`components.sh` targets the wrong cluster**
- It prefers the repo-local `kubeconfig-<CLUSTER_NAME>.yaml`. If preflight reports
  *all* platform prereqs missing on a healthy cluster, that file is absent/stale —
  regenerate it: `k3d kubeconfig get <CLUSTER_NAME> > kubeconfig-<CLUSTER_NAME>.yaml`.

**Apply fails: `metadata.annotations: Too long: may not be more than 262144 bytes`**
- A large object (e.g. a dashboard ConfigMap) exceeds the client-side
  `last-applied-configuration` annotation limit. Use **server-side apply**:
  `kubectl apply --server-side --force-conflicts -f -` (components.sh already does this).

**Grafana login fails / admin password mismatch**
- The chart's `grafana` secret can drift from the password persisted in Grafana's PVC
  after a redeploy. Reset it in-place:
  ```bash
  kubectl -n monitoring exec deploy/grafana -c grafana -- \
    grafana cli admin reset-admin-password '<newpass>'
  ```
  Or get the current secret value:
  `kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d`.
  For a clean secret-matched password: `./components.sh remove --only grafana` →
  `kubectl -n monitoring delete pvc -l app.kubernetes.io/name=grafana` → redeploy.

**A dashboard is empty (no data)**
1. Are the metrics in VictoriaMetrics? Query VMSingle directly:
   ```bash
   kubectl -n monitoring run vmq --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- \
     curl -s 'http://vmsingle-observability-vm.monitoring.svc:8429/api/v1/query?query=count(up)'
   # also try: cilium_version, cilium_operator_version, hubble_flows_processed_total, node_uname_info
   ```
2. Is the scrape target up? Check VMAgent: `kubectl -n monitoring get vmpodscrape,vmservicescrape`
   and `kubectl -n monitoring logs deploy/vmagent-observability-vmagent`.
3. Confirm the metric ports the scrapes target still match:
   ```bash
   kubectl -n kube-system get pod -l k8s-app=cilium \
     -o jsonpath='{range .items[0].spec.containers[*]}{range .ports[*]}{.name}={.containerPort} {end}{end}{"\n"}'
   # expect: prometheus=9962 hubble-metrics=9965 ; operator: prometheus=9963
   kubectl -n monitoring get svc prometheus-node-exporter -o jsonpath='{.spec.ports[0].name}{"\n"}'  # metrics
   ```
4. Datasource binding: the dashboard JSON must reference the VictoriaMetrics datasource
   `uid: victoriametrics` (prebuilt ones are pre-bound; for new imports set the datasource).

**Dashboard not appearing in Grafana**
- The sidecar imports ConfigMaps labeled `grafana_dashboard=1` (searchNamespace ALL):
  ```bash
  kubectl -n monitoring get cm -l grafana_dashboard=1
  POD=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
  kubectl -n monitoring logs "$POD" -c grafana-sc-dashboard | grep Writing      # sidecar wrote files
  kubectl -n monitoring logs "$POD" -c grafana | grep -i 'provision dashboards' # grafana loaded them
  ```

**Grafana CrashLoopBackOff: `failed to install plugin ... context deadline exceeded`**
- The pod has no egress to grafana.com for plugin downloads. Don't rely on external
  plugins — use built-in datasource types (VictoriaMetrics via the `prometheus` type,
  traces via `jaeger`), as `components/registry/grafana` does.

**NATS StatefulSet never Ready: `Waiting for routing` / `no meta leader`**
- A 1-node NATS **cluster** never elects a JetStream leader. Run NATS **standalone**
  (`config.cluster.enabled: false`) on a single host; cluster mode needs ≥3 replicas.

**k3d create fails: `Pool overlaps with other one on this address space`**
- `CLUSTER_SUBNET` overlaps an existing docker network. List them and pick a free /24:
  `docker network ls -q | xargs -r docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'`
