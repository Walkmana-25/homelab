# Repository Guide

Last reviewed: 2026-10-15

## Overview

This repository manages a home k3s cluster as code. It has two independently verified control planes:

- **Ansible** provisions bare-metal and VM prerequisites, storage, cluster services, observability agents, and Argo CD.
- **Argo CD** reconciles cluster workloads from GitOps manifests under `argocd/k3s/apps/`.

There is no application test suite. Validation is based on Ansible lint/syntax checks, YAML lint, kustomize builds, and Kubernetes manifest schema validation.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `ansible/` | Playbooks, inventories, roles, plugins, requirements, and provisioning Makefile |
| `argocd/` | Argo CD Application manifests and kustomize overlays |
| `k8s/apps/` | Standalone Kubernetes manifests not managed by Argo CD |
| `scripts/` | VM image tooling and the Fluent Bit bootstrap script |
| `.devcontainer/` | Development toolchain definition |
| `docs/` | Operational guides and procedures |

The two Argo CD umbrella Applications are:

- `argocd/k3s/application-infrastructure.yaml` → `argocd/k3s/apps/infrastructure/`
- `argocd/k3s/application-application.yaml` → `argocd/k3s/apps/application/`

Infrastructure includes cert-manager, MetalLB, Longhorn, Piraeus/LINSTOR, sealed-secrets, Reflector, Fluent Bit, Loki, Grafana, VictoriaMetrics, Harbor, and supporting controllers. Application overlays include services such as LibreChat, LiteLLM, SearXNG, Firecrawl, Headroom, MCP proxy, and Dawarich.

## Development and Validation

Install and verify Ansible from its own directory:

```bash
cd ansible
make install-lint
make install-requirements
make check
```

`make check` runs `ansible-lint`, syntax-checks all playbooks, and validates every committed inventory. Use `LC_ALL=C.UTF-8` on hosts where system locales are incomplete.

Verify Argo CD manifests from `argocd/`:

```bash
cd argocd
make check
```

This target runs yamllint, builds every kustomize overlay, and validates rendered resources with kubeconform. Argo CD checks require `yamllint`, `kustomize`, and `kubeconform` on `PATH`.

CI runs the Ansible sequence and Argo CD checks on pushes to `main` and pull requests.

### Python and Ansible version constraints

- CI pins Python 3.14 in `.github/workflows/ansible-check.yml` and logs the runtime with `python -V`, `ansible --version`, and `ansible-lint --version`.
- `ansible/requirements.txt` pins `ansible-core` to the 2.21.x line; local and devcontainer environments install Ansible from the distribution packages and are therefore not covered by this pin.
- ansible-core < 2.22 does not support Python 3.15: on CPython 3.15, `dataclasses._is_type` was removed, so Ansible crashes with `AttributeError: module 'dataclasses' has no attribute '_is_type'` (ansible/ansible#87677).
- Upgrading CI to Python 3.15 therefore requires ansible-core >= 2.22 (GA 2026-11-02), a matching bump of the pin in `ansible/requirements.txt`, and removing the `python` rule in `.github/renovate.json`.

## Provisioning Workflow

Key Ansible commands must be run from `ansible/`:

| Command | Purpose |
| --- | --- |
| `make common` | Disable and mask `multipathd` before storage setup |
| `make deploy-nfs` | Configure the NFS server |
| `make install-k3s` | Run the full ordered k3s bootstrap and install Argo CD |
| `make upgrade-k3s` | Perform a rolling k3s upgrade |
| `make deploy-staging` / `make deploy-production` | Apply `site.yml` to the selected environment |
| `make deploy-node-exporter` | Install VM metrics agents |
| `make deploy-fluent-bit` | Install VM journald log agents |
| `make deploy-linstor` | Assert the configured LINSTOR installation |
| `make update-linstor` | Explicitly update pinned LINSTOR packages |

`make install-k3s` runs common, NFS client, Btrfs/Longhorn preparation, k3s installation, kubeconfig retrieval, and Argo CD setup in that order. Do not reorder these steps. Provisioning commands require approved inventories and credentials; treat them as cluster-mutating operations.

## Observability Architecture

- **VM metrics:** `node_exporter` → Technitium DNS service discovery → `vmagent` → VictoriaMetrics.
- **VM logs:** Fluent Bit reads journald and sends logs through the k3s-router reverse proxy to Loki.
- **Pod logs:** the Fluent Bit DaemonSet sends container logs directly to Loki with `log_type=container`.

For a new VM, registering its DNS A record enables metric discovery, and running `scripts/install-fluent-bit.sh` enables log shipping. The bootstrap configuration is intended to match the Ansible Fluent Bit configuration.

### Operational Invariants

- Create the `fluent-bit` user and group before creating its buffer directory; the deb package does not create the service account.
- Use the LogQL line-filter operator `|~`, not `|=~`.
- Scope VM syslog queries with `hostname=~".+"`; container logs have no usable hostname label.
- Filter VM records by the parsed `SYSTEMD_UNIT`, not `service_name`, which is always `fluent-bit`.
- Keep `access_log off` on the k3s-router nginx log proxy to prevent journald ingestion amplification.
- Preserve the Grafana table transform chain: `labelsToFields` → panel frame merge → `renameByRegex`; do not use `concat`.
- The `renameByRegex` option key is `renamePattern`.
- Filter journald error-level records with `| json priority="PRIORITY" | priority=~"[0-3]"`.

Grafana dashboards are ConfigMaps labeled `grafana_dashboard: "1"` in the monitoring namespace and loaded by the sidecar. Allow time for propagation and verify the served dashboard through the Grafana API before assuming a change failed.

## Storage

Longhorn uses prepared Btrfs storage. LINSTOR uses pinned LINBIT packages and the Piraeus Operator. `linstor_target_version` in `ansible/roles/linstor/defaults/main.yml` is the package version source of truth.

See [`linstor-update.md`](linstor-update.md) for compatibility checks, update commands, verification, rollback conditions, and data-preservation rules.

## Dependencies and Automation

- The `k3s-io/k3s-ansible` collection is pinned to a Git SHA in `ansible/requirements.yml`.
- Renovate updates Argo CD targets, GitHub Actions, selected Helm versions, and selected images on Mondays before 09:00 JST.
- Piraeus Operator automation is intentionally disabled; update it manually after checking LINSTOR compatibility.

## Secrets and Configuration

- Do not commit plaintext credentials, tokens, private keys, or kubeconfigs.
- Root-level `secret.yaml` and `secrets.yaml` paths are gitignored.
- Prefer SealedSecrets for user-managed Kubernetes secrets; encrypted SealedSecret manifests may be committed.
- Keep environment-specific values in inventories or explicit manifest values, and review secrets before rendering manifests.

## Contribution Workflow

1. Make a focused change and update the corresponding documentation.
2. Run the checks for the subsystem you changed.
3. Use Conventional Commits, for example `feat(litellm): expose web search as an MCP tool`, `fix(searxng): bound result size`, or `docs(argocd): document application overlays`.
4. In a pull request, state intent, affected systems, rollout and rollback notes, and validation performed.

Avoid imperative cluster changes that are not represented in this repository. Reconcile drift by updating the manifests or playbooks first.
