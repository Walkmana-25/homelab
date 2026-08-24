# homelab
My Home Lab

## Required Software

- Kubectl
- Helm
- ArgoCD CLI
- Kustomize

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