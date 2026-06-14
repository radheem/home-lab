# echo test (adapted for k3d-lab)

Ported from the old `k3d/test/echo`. The old version created its **own** Gateway
(`echo-gateway`) and used `echo.example.com` with `curl --resolve`. The new version
follows the zero-touch contract: it attaches to the **shared** Gateway and uses
`echo.${LOCAL_TLD}`, so DNS is published automatically by ExternalDNS.

## What it deploys (namespace `echo`)
- `deploy.yaml` — `ealen/echo-server` (returns request JSON), port 3000
- `service.yaml` — ClusterIP `echo:8080` → pod 3000
- `httproute.yaml` — HTTPRoute on `shared-gateway` (ns `gateway-system`), host `echo.${LOCAL_TLD}`

## Deploy
`${LOCAL_TLD}` is templated, so render with `.env` then apply:
```bash
set -a; source ../../.env; set +a            # from test/echo/
kubectl kustomize . | envsubst '${LOCAL_TLD}' | kubectl apply -f -
```

## Verify (LAN — Experiment 1)
```bash
# DNS: the authoritative server should resolve the name to the Gateway IP
dig @${DNS_LB_IP} echo.${LOCAL_TLD} +short          # -> ${GATEWAY_LB_IP}

# HTTP via the Gateway (works even before the router forwards the zone)
curl -s --resolve echo.${LOCAL_TLD}:80:${GATEWAY_LB_IP} http://echo.${LOCAL_TLD} | jq .host

# Once the router conditional-forwards ${LOCAL_TLD} -> ${DNS_LB_IP}, plain name works:
curl -s http://echo.${LOCAL_TLD} | jq .host
```

## Verify (Tailnet — Experiment 2)
From another machine on the tailnet, after the subnet route (`${LB_CIDR}`) is
approved in Headscale (both `${DNS_LB_IP}` and `${GATEWAY_LB_IP}` live in it):
```bash
dig @${DNS_LB_IP} echo.${LOCAL_TLD} +short
curl -s --resolve echo.${LOCAL_TLD}:80:${GATEWAY_LB_IP} http://echo.${LOCAL_TLD} | jq .host
```

## Teardown
```bash
kubectl delete ns echo
```
