# Repository Guidelines

## Project Structure

- `ansible/` provisions VMs and k3s: NFS, Longhorn, LINSTOR, router agents, node metrics, Fluent Bit, and Argo CD.
- `argocd/` contains the GitOps “App of Apps” manifests under `argocd/k3s/apps/`.
- `k8s/apps/` contains standalone manifests that are not managed by Argo CD.
- `scripts/` provides VM image and bootstrap tooling.
- `docs/` is the source of truth for operational procedures; start with `docs/README.md`.

## Build, Test, and Development Commands

Run Ansible checks from `ansible/`:

```bash
cd ansible
make install-lint          # install ansible and ansible-lint
make install-requirements  # install pinned Ansible collections
make check                 # lint, syntax-check, and validate inventories
```

Run Argo CD checks from `argocd/`:

```bash
cd argocd
make check                 # run yamllint, kustomize build, and kubeconform
```

There is no application test suite. CI runs both subsystem checks on pushes to `main` and pull requests.

## Style and Conventions

- YAML uses two-space indentation and descriptive, kebab-case filenames.
- Prefer Kubernetes manifests and kustomize overlays over imperative cluster changes.
- Keep Ansible tasks idempotent; use fully qualified module names where practical.
- Preserve playbook and install order in `ansible/Makefile`; `install-k3s` depends on that order.
- Update the matching document under `docs/` when behavior, architecture, or operational precautions change.

## Commit and Pull Request Guidelines

Use Conventional Commits, for example:

- `feat(litellm): expose web search as an MCP tool`
- `fix(searxng): bound result size`
- `docs(argocd): document application overlays`

Keep one logical change per commit. Pull requests should describe intent, blast radius, rollout or rollback steps, and validation output. Link related issues. Do not submit unverified cluster-state changes.

## Security and Configuration

Never commit plaintext credentials, kubeconfigs, tokens, or generated secret material. Files named `secret.yaml` or `secrets.yaml` are ignored at the repository root. Store user-managed Kubernetes secrets as SealedSecrets; plain SealedSecret manifests are safe to commit. Review image versions, Helm targets, and inventory-specific values before deployment.

## Agent-Specific Instructions

- Present a Japanese implementation plan and obtain approval before modifying files.
- Run read-only exploration first and delegate non-obvious technical research when needed.
- Do not run provisioning, deployment, upgrade, reboot, or Git state-changing commands without explicit approval.
- In this environment, run `LC_ALL=C.UTF-8` for Ansible commands and commit with `git -c commit.gpgsign=false`; do not alter global Git configuration.
