# Ansible Project Template

This is a best-practice directory structure for Ansible.

## Directory Structure

- `ansible.cfg`: Ansible configuration file.
- `site.yml`: Main entry point playbook.
- `inventories/`: Environment-specific inventory files.
  - `staging/`: Staging environment inventory.
  - `production/`: Production environment inventory.
- `group_vars/`: Variables applied to specific groups of hosts.
- `host_vars/`: Variables applied to specific hosts.
- `roles/`: Reusable roles.
- `playbooks/`: Individual playbooks for specific tasks.
- `library/`: Custom Ansible modules.
- `filter_plugins/`: Custom Jinja2 filters.
- `Makefile`: Shortcut commands for common tasks.

## Usage

You can use the provided `Makefile` to run common commands.

### Ping all hosts in staging
```bash
make ping
```

### Deploy to staging
```bash
make deploy-staging
```

### Deploy to production
```bash
make deploy-production
```
