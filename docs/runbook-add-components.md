# Runbook — add components to a running cluster (day-2)

Enhance an already-running cluster by enabling more of the add-on stack, or by adding
your own component to the registry. The deployer is **idempotent** and
**dependency-aware**, so this is safe to run against a live cluster — only the new
work is applied.

> This is the day-2 companion to [runbook-components.md](runbook-components.md) (first
> deploy). The cluster must already be up per [runbook-local.md](runbook-local.md).

## 0. Prerequisites
- A running, verified cluster (`./install.sh` done).
- Tools — tested versions: `kubectl v1.31.0 · helm v3.18.2 · yq (Python jq-wrapper) ·
  envsubst (gettext 0.21)`. Full matrix: [README Prerequisites](../README.md#prerequisites).
- `components.sh` auto-targets the repo-local `kubeconfig-<CLUSTER_NAME>.yaml`
  (it overrides any ambient `KUBECONFIG`).

## A. Enable an existing registry component

1. See what's available + the dependency graph:
   ```bash
   cd components
   ./components.sh list
   ```
2. Flip `enabled: true` (and set basic config) in `components.yaml`:
   ```yaml
   components:
     grafana: { enabled: true, hostname: grafana, storageSize: 10Gi }
   ```
3. Apply just that component (its dependencies are pulled automatically, in order):
   ```bash
   ./components.sh deploy --only grafana          # grafana -> victoria-metrics -> vm-operator
   # or re-run the whole selection (no-op for already-deployed components):
   ./components.sh deploy
   ./components.sh deploy --dry-run               # preview the resolved order, apply nothing
   ```
4. Verify (see §C).

Idempotency: `helm upgrade --install` and server-side `kubectl apply` mean re-running
never duplicates or churns healthy components — it only reconciles changes.

## B. Add a brand-new component to the registry

Create `components/registry/<name>/` with a `component.yaml` (metadata the deployer
reads) plus its assets. Three packaging types:

**Metadata (`component.yaml`)**
```yaml
name: <name>
category: monitoring|messaging|workflow|database|<your-group>
namespace: <target-namespace>
type: helm | kustomize | kustomize-helm
dependsOn: [<other-component>, ...]     # optional; auto-enabled when this is enabled
secrets: [SOME_PASSWORD]                # optional; generated into components.secrets.env
crds: [foos.example.com]                # optional; waited Established after a helm operator
crdTimeout: 180s                        # optional
waits:                                  # optional; bash eval'd after apply (rollout/health)
  - "kubectl -n <ns> rollout status deploy/<name> --timeout=180s"
# for type: helm
chart:
  repo: https://charts.example.com
  name: <chart>
  version: <x.y.z>
  release: <release>
  valuesFile: values.yaml               # templated, see Config below
```

**Assets by type**
- `helm` → `values.yaml` next to `component.yaml`.
- `kustomize` → a `kustomize/` dir (`kustomization.yaml` + manifests/CRs).
- `kustomize-helm` → a `kustomize/` dir whose `kustomization.yaml` has `helmCharts:`
  (rendered with `kubectl kustomize --enable-helm`); use this when you need a Helm
  chart **plus** extra manifests (e.g. an HTTPRoute). Put a top-level
  `namespace: <ns>` in the kustomization so all rendered objects get stamped.

**Config flows from `components.yaml` → env → templates**
- Every key under `components.<name>` (except `enabled`) is exported as
  `COMP_<UPPERCASE_KEY>` (e.g. `storageSize` → `${COMP_STORAGESIZE}`), plus `${DOMAIN}`.
- Declared `secrets:` become `${SECRET_<NAME>}` (auto-generated, gitignored).
- Reference these in `values.yaml` / kustomize files; the deployer `envsubst`s them
  (scoped to `COMP_*`, `SECRET_*`, `DOMAIN` — it won't touch other `$` tokens).

**Exposure conventions (so DNS is zero-touch)**
- HTTP UI → an `HTTPRoute` on the shared Gateway:
  ```yaml
  parentRefs: [{ name: shared-gateway, namespace: gateway-system }]
  hostnames: ["${COMP_HOSTNAME}.${DOMAIN}"]
  ```
- Raw TCP → a `type: LoadBalancer` Service with
  `external-dns.alpha.kubernetes.io/hostname: ${COMP_HOSTNAME}.${DOMAIN}` (LB IP is
  auto-assigned from `LB_CIDR`; the homelab ExternalDNS publishes it via `--source=service`).

Then enable it in `components.yaml` and `./components.sh deploy --only <name>`. Use the
existing `components/registry/*` as templates (e.g. `grafana` for kustomize-helm + HTTPRoute,
`nats` for a LoadBalancer chart, `postgres-cluster` for kustomize + generated secret).

## C. Verify
```bash
./components.sh status                                   # pods per namespace
dig @172.28.210.53 <name>.home.lan +short               # raw-TCP svc hostname
curl -H 'Host: <name>.home.lan' http://172.28.210.80    # HTTP UI via the Gateway
```

## D. Remove a component
```bash
./components.sh remove --only <name>     # one (helm uninstall / kubectl delete)
./components.sh remove                    # all enabled, reverse dependency order
```
(Removing does not delete its PVCs by default; delete them explicitly if you want the
data gone.)

## Notes
- Single host: add incrementally and watch resources (`kubectl top nodes`); trim
  replicas/storage in `components.yaml`. The full stack wants ~4 CPU / 8 GB.
- New CRDs from an operator component must be `Established` before its CR component
  applies — model the operator as a dependency with `crds:` (the deployer waits).
- Issues: [troubleshooting.md](troubleshooting.md) (§"Components & monitoring").
