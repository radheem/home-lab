# Runbook — add-on components (monitoring / messaging / workflow / database)

Deploy a selectable stack on top of the homelab platform: pick components in a YAML
file, `./components.sh deploy`. Adapted from an external stack into the homelab
(`*.home.lan`, reusing cert-manager / Cilium Gateway / ExternalDNS / local-path).

> **Why bash+YAML, not Ansible?** The homelab and the source stack are already
> bash+kustomize+helm; the work is "render → apply → wait", which those tools do
> idempotently. `components/` generalizes that into a small registry + selector
> driven by `yq`. Ansible would add a Python/collections dependency and a rewrite
> for no real gain at single-host scale — revisit it only if this goes multi-host.

## Components

`./components.sh list` shows the registry + dependency graph. Enabling a component
auto-pulls its dependencies.

| Category | Components |
|----------|-----------|
| monitoring | `victoria-metrics` (VM/VL/VT + operator), `otel-collectors` (+ `otel-operator`), `grafana`, `node-exporter` |
| messaging | `nats` |
| workflow | `hatchet` (bundled postgres + rabbitmq) |
| database | `postgres-cluster` (+ `cnpg-operator`), `ferretdb` |

## 0. Prerequisites
- The homelab cluster is up and verified: [runbook-local.md](runbook-local.md).
  `components.sh` preflight checks cert-manager, the shared Gateway, ExternalDNS
  (with `--source=service`), `local-path`, and the Cilium LB-IPAM pool — and refuses
  to run if any is missing.
- Tools: `kubectl helm yq envsubst` (`yq` here is the Python jq-wrapper).
- The imported source lives in the gitignored `temp-artifacts/`; the committed,
  adapted versions are in `components/registry/`.

## 1. Select + configure
```bash
cd k3d-lab/components
cp components.yaml.example components.yaml      # gitignored
$EDITOR components.yaml                          # toggle enabled + set basic config
```
Each component takes basic config only — `hostname`, `storageSize`, `replicas`,
`instances`, `retention`. Secrets are NOT here: passwords (postgres admin, hatchet
admin) are generated on first deploy into `components.secrets.env` (gitignored).

## 2. Deploy
```bash
export KUBECONFIG=$PWD/../kubeconfig-qube-homelab.yaml   # or let components.sh auto-pick it
./components.sh deploy                 # all enabled, in dependency order
./components.sh deploy --only grafana  # one component (+ its deps)
./components.sh deploy --dry-run       # print resolved order, apply nothing
```
Start small on a single host — enable `node-exporter` + one category at a time
(the full stack wants ~4 CPU / 8 GB). `components.yaml` defaults trim replicas.

## 3. Verify per category
```bash
./components.sh status                  # pods per namespace

# DNS (raw-TCP services are published as LoadBalancer hostnames):
dig @172.28.210.53 nats.home.lan +short
dig @172.28.210.53 postgres.home.lan +short
dig @172.28.210.53 ferretdb.home.lan +short

# HTTP UIs via the shared Gateway:
curl -H 'Host: grafana.home.lan' http://172.28.210.80      # Grafana login
curl -H 'Host: hatchet.home.lan' http://172.28.210.80      # Hatchet frontend

# Postgres (admin password is in components.secrets.env):
PGPASSWORD=$(grep POSTGRES_ADMIN_PASSWORD components/components.secrets.env | cut -d= -f2) \
  psql -h <postgres-LB-IP> -U dbadmin -d appdb -c '\l'

# Grafana datasources should list VictoriaMetrics / VictoriaLogs / VictoriaTraces.
```
On the cluster host (no bridged NIC) add the LB route once, as in
[runbook-local.md](runbook-local.md) §"Host-on-the-same-box caveat".

## 4. Remove
```bash
./components.sh remove --only ferretdb   # one component
./components.sh remove                    # all enabled, reverse order
```

## Adaptation notes (vs. the source stack)
- Hostnames re-pointed to `*.home.lan` (driven by `components.yaml`).
- HTTP UIs (Grafana, Hatchet) use an **HTTPRoute on the shared Gateway**; raw-TCP
  endpoints (NATS, Postgres, FerretDB, Hatchet engine) use **LoadBalancer + ExternalDNS**
  (requires the homelab ExternalDNS `--source=service`, added to `manifests/20-external-dns`).
- LB IPs auto-assigned from the homelab `LB_CIDR` (no hardcoded IPs).
- Dropped: the stack's Porkbun ExternalDNS, its own cert-manager, the IRIS app layer +
  DB migration jobs, and company image registries. Internal object names neutralized
  (`homelab-pg`, `dbadmin`, `appdb`).
- Secrets generated + gitignored; never committed.

## Troubleshooting
- **Operator CRD waits time out** — the operator chart version may not ship that CRD;
  check `kubectl get crd | grep <group>` and the chart version in `registry/<op>/component.yaml`.
- **CR apply fails "no matches for kind"** — its operator isn't ready; deploy ordering
  handles this, but if you applied a CR component directly, deploy its operator first.
- **DNS hostname not resolving** — confirm ExternalDNS has `--source=service`
  (`kubectl -n external-dns get deploy external-dns -o yaml | grep source`) and that the
  Service got an EXTERNAL-IP from LB-IPAM.
- **Heavy / pods Pending** — single-host pressure; disable a category or trim replicas.
- General DNS/Gateway/Cilium issues: [troubleshooting.md](troubleshooting.md).
