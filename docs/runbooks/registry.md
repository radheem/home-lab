# Runbook — In-cluster image registry

Push images from any LAN device (`docker push registry.home.lan/...`) and have the
k3s nodes pull them automatically — no more `k3d image import` from the host. The
registry runs in-cluster, serves HTTPS via the internal CA, and has **no auth** by
default (enable it in §6).

> Conventions: values below use the defaults `REGISTRY_HOST=registry.home.lan`,
> `REGISTRY_LB_IP=172.28.210.81`, `DNS_LB_IP=172.28.210.53` — adjust to your `.env`.
> The registry IP must be inside `LB_CIDR`.

## 1. Enable it
The registry is opt-in. Bring up the cluster with the flag:
```bash
./install.sh --with-registry
export KUBECONFIG=$PWD/kubeconfig-$(. ./.env >/dev/null 2>&1; echo $CLUSTER_NAME).yaml
```
This deploys `manifests/60-registry/` (registry Deployment + pinned-IP LoadBalancer +
internal-CA cert) **and** wires the nodes' containerd to pull `registry.home.lan/*`
images from the registry's LB IP (`config/k3d-registries.yaml`, applied at cluster
create — so it can't be turned on for a running cluster without a reinstall).

Check it's healthy:
```bash
kubectl -n registry get pods,svc,certificate
# registry pod Running · svc EXTERNAL-IP == REGISTRY_LB_IP · certificate/registry-tls Ready
dig @172.28.210.53 registry.home.lan +short     # -> 172.28.210.81
```

## 2. Trust the internal CA (one-time, per pushing device)
Same CA you trust for `*.home.lan` HTTPS — skip if you already did it:
```bash
kubectl -n cert-manager get secret home-lab-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > home-lab-ca.crt
```
Make Docker trust it for this registry (Linux Docker Engine):
```bash
sudo mkdir -p /etc/docker/certs.d/registry.home.lan
sudo cp home-lab-ca.crt /etc/docker/certs.d/registry.home.lan/ca.crt
```
(Docker Desktop / Podman: add `home-lab-ca.crt` to the OS trust store instead — see
[docs/cert-manager.md](../cert-manager.md).) Verify the registry answers:
```bash
curl --cacert home-lab-ca.crt https://registry.home.lan/v2/_catalog   # {"repositories":[]}
```

## 3. Push an image (from any LAN device)
Your device must resolve `home.lan` (router conditional-forward to `DNS_LB_IP`, or set
it as your DNS server — see [deploy-local.md](deploy-local.md) §7).
```bash
docker pull alpine:3.20
docker tag  alpine:3.20 registry.home.lan/alpine:3.20
docker push registry.home.lan/alpine:3.20
```

## 4. Use it in the cluster
Reference the image by the **same name** — containerd pulls it via the mirror, so the
nodes don't need to resolve `home.lan`:
```bash
kubectl -n demo create deployment regtest --image=registry.home.lan/alpine:3.20 -- sleep 3600
kubectl -n demo rollout status deploy/regtest        # Running == node pulled it
```
If a pod is stuck `ImagePullBackOff`, see §7.

## 5. Verify
```bash
# what the registry holds:
curl --cacert home-lab-ca.crt https://registry.home.lan/v2/_catalog
curl --cacert home-lab-ca.crt https://registry.home.lan/v2/alpine/tags/list
```

## 6. Enable authentication (optional)
TLS is already in place, so this is just adding `htpasswd`. Create a **bcrypt** entry
(registry:2 requires bcrypt) and load it as a Secret:
```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn devuser 'change-me' > htpasswd
kubectl -n registry create secret generic registry-htpasswd --from-file=htpasswd
```
Patch the registry to use it (mount the secret + set the auth env):
```bash
kubectl -n registry set env deploy/registry \
  REGISTRY_AUTH=htpasswd \
  REGISTRY_AUTH_HTPASSWD_REALM='Registry Realm' \
  REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
kubectl -n registry patch deploy/registry --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"auth","secret":{"secretName":"registry-htpasswd"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"auth","mountPath":"/auth","readOnly":true}}
]'
kubectl -n registry rollout status deploy/registry
```
Now clients log in (works because the CA is already trusted):
```bash
docker login registry.home.lan -u devuser
```
**In-cluster pulls after enabling auth** need credentials too. Use an `imagePullSecret`
per namespace (day-2, no cluster reinstall):
```bash
kubectl -n demo create secret docker-registry reg-creds \
  --docker-server=registry.home.lan --docker-username=devuser --docker-password='change-me'
kubectl -n demo patch sa default -p '{"imagePullSecrets":[{"name":"reg-creds"}]}'
```
(Alternatively, put the credentials in the nodes' `registries.yaml` under
`configs."172.28.210.81".auth` in `config/k3d-registries.yaml` — but that's read only at
cluster create, so it needs a reinstall. The `imagePullSecret` above is the live path.)

> To make these manifest changes permanent, bake the `htpasswd` Secret + the auth env
> and volume into `manifests/60-registry/registry.yaml` instead of patching.

## 7. Notes & troubleshooting
- **Persistence:** images live on the host under `CLUSTER_VOLUME_STORE` (local-path PVC).
  They survive pod/cluster restarts but are wiped by `./uninstall.sh --purge-data`.
- **`x509`/TLS errors on push:** the CA isn't trusted on that device — redo §2.
- **`ImagePullBackOff` in-cluster:** confirm `--with-registry` was used at install
  (`grep -A3 registries .render-k3d-config.yaml` won't exist post-install; instead
  `docker exec k3d-$CLUSTER_NAME-server-0 cat /etc/rancher/k3s/registries.yaml`). The
  mirror should map `registry.home.lan` → `https://<REGISTRY_LB_IP>`.
- **Strict TLS for nodes (optional):** pulls use `insecure_skip_verify` by default. The
  cert carries the LB IP as a SAN, so you can mount `home-lab-ca.crt` into the nodes and
  set `ca_file` instead — see `config/k3d-registries.yaml`.

More: [troubleshooting.md](../troubleshooting.md) · connecting to an external private
registry: [private-registry.md](private-registry.md).
