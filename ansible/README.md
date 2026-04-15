# Ansible Project

This project manages homelab infrastructure using Ansible, including NFS storage and k3s clusters.

## Prerequisites

Install the required Ansible collections (k3s-ansible):

```bash
make install-requirements
```

## Directory Structure

- `ansible.cfg`: Ansible configuration file.
- `site.yml`: Main entry point playbook.
- `requirements.yml`: External collection requirements.
- `inventories/`: Environment-specific inventory files.
  - `k3s/`: k3s cluster and NFS server inventory.
  - `staging/`: Staging environment inventory.
  - `production/`: Production environment inventory.
- `roles/`: Reusable roles.
  - `nfs_server/`: Role for setting up an NFS kernel server.
- `playbooks/`: Individual playbooks for specific tasks.
- `Makefile`: Shortcut commands for common tasks.

## Usage

### NFS Server Setup

1. Edit `inventories/k3s/inventory-nfs.yml` to set your host IP and configuration.
2. Run deployment:
   ```bash
   make deploy-nfs
   ```

### k3s Cluster Setup

1. Edit `inventories/k3s/inventory.yml` to configure your nodes.
2. Install the cluster and fetch kubeconfig:
   ```bash
   make install-k3s
   ```

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make install-requirements` | Install required Ansible collections |
| `make ping-nfs` | Ping NFS servers |
| `make deploy-nfs` | Setup NFS server |
| `make restart-nfs` | Restart NFS service |
| `make ping-k3s` | Ping k3s cluster nodes |
| `make install-k3s` | Install k3s and fetch kubeconfig |
| `make upgrade-k3s` | Upgrade k3s cluster |
| `make reboot-k3s` | Reboot all k3s cluster nodes |
| `make ping` | Ping all hosts in staging |
| `make deploy-staging` | Deploy to staging |
| `make deploy-production` | Deploy to production |
