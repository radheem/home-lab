# Runbook — Pull from a private external registry (Docker Hub, GHCR, …)

Give the cluster credentials so it can pull **private** images from an external
registry. Two mechanisms: per-namespace `imagePullSecret` (recommended, day-2) or a
cluster-wide credential baked into the nodes' `registries.yaml`.

> Examples use Docker Hub. For GHCR use `--docker-server=ghcr.io`; for any other
> registry, its hostname. Always use an **access token**, never your account password.

## 1. Mechanism A — `imagePullSecret` (recommended)
Per-namespace, no cluster reinstall, the standard Kubernetes path.

Create the secret (Docker Hub: generate a PAT at *Account → Security → Access Tokens*):
```bash
kubectl -n demo create secret docker-registry regcred \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<dockerhub-user> \
  --docker-password=<access-token>
```
Use it. Either reference it on the Pod:
```yaml
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: app
      image: docker.io/<user>/<private-image>:<tag>
```
…or attach it to the namespace's `default` ServiceAccount so **every** pod inherits it:
```bash
kubectl -n demo patch sa default -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

Verify the pull works:
```bash
kubectl -n demo run pulltest --image=docker.io/<user>/<private-image>:<tag> --restart=Never
kubectl -n demo describe pod pulltest | sed -n '/Events/,$p'   # expect "Pulled", not 401/Forbidden
```

## 2. Mechanism B — cluster-wide via `registries.yaml`
Transparent for *all* namespaces (no per-pod secret), good for a permanent base-registry
credential or a pull-through mirror. It lives in the nodes' containerd config, which k3s
reads **only at startup**, so this needs a cluster reinstall.

Add a `configs` entry to `config/k3d-registries.yaml` (the block appended at cluster
create). For authenticated Docker Hub pulls:
```yaml
registries:
  config: |
    configs:
      "registry-1.docker.io":
        auth:
          username: "<dockerhub-user>"
          password: "<access-token>"
```
Then recreate so the nodes pick it up:
```bash
./uninstall.sh && ./install.sh        # add --with-registry if you also run the in-cluster registry
```
> Keep real credentials out of git. `config/k3d-registries.yaml` is committed, so put
> secrets in your gitignored `.env` and template them in, or apply Mechanism A instead.

### Optional: pull-through cache mirror
To cut Docker Hub rate-limit hits, point the mirror at a local pull-through cache
(a `registry:2` running with `proxy.remoteurl=https://registry-1.docker.io`) and add a
`mirrors."docker.io".endpoint` entry alongside the `configs` block. Out of scope here.

## 3. Docker Hub specifics
- **Server string:** `https://index.docker.io/v1/` for the secret; the image namespace is
  `docker.io/...` (or bare `<user>/<img>`, which resolves to `docker.io`).
- **Rate limits:** anonymous pulls are throttled per IP; authenticating (either mechanism)
  raises the limit. A pull-through cache helps further.
- **Tokens:** scope a PAT to read-only for pulls; revoke it independently of your password.

## 4. Security note
`kubernetes.io/dockerconfigjson` Secrets are **base64, not encrypted** — anyone with
`get secret` in the namespace can read them. Keep credential files gitignored, prefer
short-lived/scoped tokens, and grant the secret only to the namespaces that need it.

More: [troubleshooting.md](../troubleshooting.md) · hosting your own in-cluster registry:
[registry.md](registry.md).
