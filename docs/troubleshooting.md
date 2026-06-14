# Troubleshooting

Set the context first:
```bash
export KUBECONFIG=$PWD/kubeconfig-<CLUSTER_NAME>.yaml
kubectl get pods -A
```

## DNS resolution

**`dig @172.28.240.53 whoami.home.lan` returns nothing / times out**
1. Is the LB IP actually assigned and announced?
   ```bash
   kubectl -n dns-system get svc coredns-auth          # EXTERNAL-IP should be 172.28.240.53
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

**External names don't resolve (e.g. `dig @172.28.240.53 example.com` fails)**
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
