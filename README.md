# homelab
My Home Lab

## Required Software

- Kubectl
- Helm
- ArgoCD CLI
- Kustomize

## Argo CD App-of-Apps Ownership Rule

`argocd/k3s/apps/application` and `argocd/k3s/apps/infrastructure` are umbrella
Applications: each renders every manifest below its directory, including the
child `Application` objects. A child Application's `spec.source.path` must
therefore **not** be a directory that the umbrella already renders in full,
otherwise both Applications manage the same objects. Only one of them can hold
the `argocd.argoproj.io/tracking-id` annotation, so the other stays permanently
`OutOfSync` behind a `SharedResourceWarning`, and both keep re-applying the
workload. `technitium-sd` hit this: its Deployment `generation` reached 39902
before the ownership was split.

When a child Application owns a directory under `argocd/k3s/apps/`:

- Reference only the manifest from the umbrella, e.g. `- technitium-sd/application.yaml`
  instead of `- technitium-sd`.
- Keep `application.yaml` out of that directory's `kustomization.yaml` so the
  child renders workloads only.
- This does not apply when the child points at a Helm chart or at a path outside
  the rendered tree (`k8s/apps/**`, upstream chart repos, another Git repo).

Look for overlapping ownership with:

```bash
kubectl -n argocd get apps -o json \
  | jq -r '.items[] | select(.status.conditions[]?.type=="SharedResourceWarning") | .metadata.name'
```

When moving resources from one Application to another, add
`argocd.argoproj.io/sync-options: Prune=false` first: the losing Application can
otherwise prune its own `Application` object and its `resources-finalizer`
cascades into the workloads.

## VM Log Collection Bootstrap

A one-liner to install Fluent Bit on a fresh Ubuntu VM and start shipping
journald logs to Loki (via the k3s-router ingress). The deployed configuration
is byte-identical to the `fluent_bit` Ansible role, so switching to Ansible
management later introduces zero drift and the script is fully idempotent.

```bash
curl -fsSL https://raw.githubusercontent.com/Walkmana-25/homelab/main/scripts/install-fluent-bit.sh | sudo bash
```

**Environment variables** (override the default Loki endpoint):

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_HOST` | `k3s-router.k8s.cloud-milky.solufit.net` | Loki ingestion host |
| `LOKI_PORT` | `3100` | Loki ingestion port |

**Prerequisites:** Ubuntu (APT), root access, and a unique `/etc/machine-id`
(regenerated automatically by cloud-init on template-based VMs).