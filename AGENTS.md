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

| Command | What it does |
|---------|-------------|
| `make install-k3s` | Multi-step: nfs-client → btrfs-longhorn → k3s install → kubeconfig → fetch-kubeconfig → argocd. **Order matters — do not reorder.** |
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