# AGENTS.md

Infrastructure-as-code repo for a home Kubernetes cluster (k3s). No application code, no tests. Two independent subsystems with their own lint pipelines.

## Repository Layout

- `ansible/` — Provision bare-metal nodes (NFS, k3s cluster install, staging/production). Has its own `Makefile`, `ansible.cfg`, and `requirements.yml`.
- `argocd/` — ArgoCD "App of Apps" GitOps manifests for the k3s cluster. Has its own `Makefile`.
- `k8s/apps/` — Standalone K8s manifests (not managed by ArgoCD).
- `.devcontainer/` — Full dev toolchain container (ansible, kubectl, kustomize, kubeconform, kubeseal, kompose).

## Lint & Verify

**Each subsystem has its own Makefile — always `cd` into the directory first.**

### Ansible (`ansible/`)

```
cd ansible
make check          # lint + syntax-check playbooks + validate all inventories
make lint           # ansible-lint only
make install-lint   # pip install ansible + ansible-lint (via requirements.txt)
make install-requirements  # ansible-galaxy collection install (k3s-ansible, kubernetes.core)
```

CI runs: `make install-lint` → `make install-requirements` → `make check`

### ArgoCD (`argocd/`)

```
cd argocd
make check          # lint-yaml + validate-kustomize + validate-manifests (runs all three)
make lint           # same as check
```

Requires on PATH: `yamllint`, `kustomize`, `kubeconform`

Yamllint config (inline in Makefile): disables line-length, truthy check-keys, document-start.
Kubeconform skips: `Application, IPAddressPool, L2Advertisement, SealedSecret, ConfigMap, Ingress`

## ArgoCD App Structure

Two umbrella "App of Apps" in `argocd/k3s/`:
- `application-infrastructure.yaml` → `argocd/k3s/apps/infrastructure/` (platform: cert-manager, longhorn, metallb, sealed-secrets, loki, grafana, etc.)
- `application-application.yaml` → `argocd/k3s/apps/application/` (user apps: dawarich, firecrawl, librechat, searxng, etc.)

Each subdirectory under `apps/` is a kustomize overlay.

## Ansible Key Commands

All run from `ansible/`. Default inventory is staging (`ansible.cfg`).

`common` (also the first step of `make install-k3s`, runnable standalone as `make common`) disables and masks multipathd on all nodes — required before k3s/storage provisioning.

| Command | What it does |
|---------|-------------|
| `make install-k3s` | Multi-step: common (disable multipathd) → nfs-client → btrfs-longhorn → k3s install → kubeconfig → fetch-kubeconfig → argocd. **Order matters — do not reorder.** |
| `make deploy-nfs` | NFS server setup via `inventories/k3s/inventory-nfs.yml` |
| `make deploy-staging` | Run `site.yml` against staging inventory |
| `make deploy-production` | Run `site.yml` against production inventory |
| `make upgrade-k3s` | Rolling upgrade of k3s cluster |

## Secrets

- `secret.yaml` and `secrets.yaml` are **gitignored** at root level.
- Sealed Secrets (`kubeseal`) is used for encrypting secrets in-cluster. Sealed secret manifests are safe to commit.
- Never commit plaintext secrets.

## Dependencies

- Ansible collection `k3s-io/k3s-ansible` is pinned to a **specific git SHA** in `ansible/requirements.yml` (not a release tag).
- Renovate is configured to auto-update ArgoCD apps, Helm values, GitHub Actions, and Ansible deps weekly (Monday before 9am JST).

## Observability Stack

### Architecture

- Metrics: node_exporter (installed on VMs via Ansible) -> technitium-sd (Technitium DNS zones -> Prometheus HTTP SD, 30s poll) -> vmagent -> VictoriaMetrics (vmsingle). Registering a DNS A record is the only onboarding step for metrics.
- Logs (VMs): fluent-bit (journald) -> k3s-router nginx reverse proxy on port 3100 (DNS name k3s-router.k8s.cloud-milky.solufit.net) -> metallb LoadBalancer 10.2.0.110:3100 -> Loki. The nginx proxy on the router decouples VM-side config from cluster internals.
- Logs (k8s pods): fluent-bit DaemonSet -> Loki (log_type=container).
- New VM onboarding: register DNS A record (metrics auto-start) + run scripts/install-fluent-bit.sh one-liner (logs start). The script is byte-identical to the fluent_bit Ansible role.

### Verified pitfalls (do not reintroduce)

- The fluent-bit deb package does NOT create a service user (postinst only runs ldconfig/daemon-reload; the unit runs as root). Create the fluent-bit user/group BEFORE the buffer directory task or `install -o` fails on fresh VMs.
- LogQL regex line filter operator is `|~` (`|=~` is invalid syntax). Case-insensitive: `|~ "(?i)pattern"`.
- Select VM syslog streams with `hostname=~".+"` — k8s container logs from the DaemonSet have no hostname label and will pollute VM-scoped panels.
- On VM agents the `service_name` label is always fluent-bit (useless). Filter by systemd unit instead: `| json unit="SYSTEMD_UNIT"`.
- nginx on k3s-router MUST keep `access_log off` — the router's own journald is collected by fluent-bit, so access logging creates an amplification loop.
- Template-cloned VMs share the same /etc/machine-id (known, accepted — hostnames never change; regenerate per-VM if that assumption changes).

### Grafana dashboards (ConfigMap + sidecar)

- Dashboards are ConfigMaps (label grafana_dashboard: "1", namespace monitoring) auto-loaded by the Grafana sidecar. After a ConfigMap change, propagation to Grafana takes a few minutes — verify the served definition via the Grafana API before concluding a dashboard fix failed.
- Loki instant metric queries in a table panel return one [Time, Value] frame per series with labels on the Value field. Working transform chain: labelsToFields -> (let the table panel merge frames itself) -> renameByRegex. Do NOT use `concat` (renders empty) or `organize.indexByName` with renamed columns.
- renameByRegex options key is `renamePattern` (NOT `rename` — an unknown key is silently ignored and the default `$1` replacement is applied, showing a literal "$1" column). Avoid parentheses in rename values.
- journald level filtering: `| json priority="PRIORITY" | priority=~"[0-3]"` for error-level (emerg/alert/crit/err).

### Local environment quirks

- `commit.gpgsign=true` is set but no signing key is configured. Commit with `-c commit.gpgsign=false` (do not change git config).
- Ansible commands require `LC_ALL=C.UTF-8` (system locales are not generated; plain runs fail with "could not initialize the preferred locale").