# Documentation

This directory is the operational source of truth for the homelab repository.

Last reviewed: 2026-10-15

## Guides

| Document | Purpose |
| --- | --- |
| [`repository-guide.md`](repository-guide.md) | Architecture, provisioning, validation, observability, security, and contribution workflow |
| [`linstor-update.md`](linstor-update.md) | Safe LINSTOR package and Piraeus Operator update, verification, and rollback procedure |

## Maintenance Rules

- Update the relevant guide in the same change as an infrastructure, deployment, or security behavior change.
- Record commands exactly as they should be run, including the required working directory.
- Keep environment-specific hostnames, IPs, and credentials out of narrative examples unless they are already committed operational endpoints.
