# registry test — push to the in-cluster registry, then deploy from it

End-to-end check for the in-cluster image registry (`./install.sh --with-registry`).
It pushes an image to `${REGISTRY_HOST}` and deploys a workload that the k3s nodes pull
back **by that same name** via the containerd mirror. If the pod reaches `Running`, the
push path and the node-pull path both work.

## What it deploys (namespace `registry-test`)
- `deploy.yaml` — `ealen/echo-server` re-published as `${REGISTRY_HOST}/echo-test:1.0`
- `service.yaml` — ClusterIP `echo-reg:8080` → pod 3000
- `httproute.yaml` — HTTPRoute on `shared-gateway`, host `echo-reg.${LOCAL_TLD}`

## 1. Push an image to the cluster registry
On a LAN box that resolves `${LOCAL_TLD}` and trusts `home-lab-ca.crt`, this is just a
normal `docker push` (see [docs/runbooks/registry.md](../../docs/runbooks/registry.md)):
```bash
docker pull ealen/echo-server:0.9.2
docker tag  ealen/echo-server:0.9.2 ${REGISTRY_HOST}/echo-test:1.0
docker push ${REGISTRY_HOST}/echo-test:1.0
```
From the cluster host without LAN DNS/routing (e.g. a cloud VM), push over a port-forward
with `crane` (no daemon trust needed; the registry stores by repo path, not hostname):
```bash
kubectl -n registry port-forward svc/registry 5000:443 &
docker run --rm --network host gcr.io/go-containerregistry/crane \
  copy --insecure ealen/echo-server:0.9.2 localhost:5000/echo-test:1.0
```

## 2. Deploy from the registry
```bash
set -a; source ../../.env; set +a            # from test/registry/
kubectl kustomize . | envsubst '${LOCAL_TLD} ${REGISTRY_HOST}' | kubectl apply -f -
kubectl -n registry-test rollout status deploy/echo-reg   # Running == node pulled from the registry
kubectl -n registry-test describe pod -l app=echo-reg | grep -A2 'Pulled\|Pulling'
```

## 3. Verify it serves
```bash
dig @${DNS_LB_IP} echo-reg.${LOCAL_TLD} +short                      # -> ${GATEWAY_LB_IP}
curl -s --resolve echo-reg.${LOCAL_TLD}:80:${GATEWAY_LB_IP} http://echo-reg.${LOCAL_TLD} | jq .host
```

## Teardown
```bash
kubectl delete ns registry-test
```
