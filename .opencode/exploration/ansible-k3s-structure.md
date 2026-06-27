# Ansible k3s Provisioning — Structure Exploration

Scope: `/home/ubuntu/homelab/ansible/` (+ the pinned `k3s-io/k3s-ansible` collection installed at `~/.ansible/collections/ansible_collections/k3s/orchestration/`).
Purpose: reference for planning a **Harbor registry deployment + k3s `registries.yaml` provisioning**.

---

## TL;DR for Harbor/registries.yaml planning

1. **The `k3s-io/k3s-ansible` collection NATIVELY supports `registries_config_yaml`** — it writes it verbatim to `/etc/rancher/k3s/registries.yaml` on **every node** (server + agent) via the collection's `prereq` role. You do NOT need a custom role/template to push `registries.yaml`; just uncomment & populate `registries_config_yaml` in `inventories/k3s/inventory.yml`. (Caveat: it only applies at install/`site`-playbook time, see §2/§10.)
2. **No existing `registries.yaml` / containerd mirror / private registry config exists** anywhere in `ansible/`. The only references are: (a) commented-out template in the inventory, (b) Harbor research notes in `.opencode/`, (c) unrelated `registry:` image-registry fields in `argocd/.../librechat`.
3. **No ansible-vault, no `group_vars`/`host_vars` content** — secrets are handled in-cluster via SealedSecrets, not by ansible. `token: "changeme!"` is plaintext in the inventory.
4. The repo's config-deployment idiom for templated files is `ansible.builtin.template: src: X.j2 dest: ... notify: Restart <svc>` + a handler. The k3s collection instead uses `ansible.builtin.copy: content: "{{ var }}"`.

---

## 1. k3s install inventory — `ansible/inventories/k3s/inventory.yml` (58 lines, FULL)

**File path:** `/home/ubuntu/homelab/ansible/inventories/k3s/inventory.yml`

**Structure:** group `k3s_cluster` with two children groups `server` and `agent`. One server, two agents. (Note: the section is **not** literally named `server_flags` — it is `extra_server_args`. The "manifests" comment block is at lines 42–58.)

### Topology
```yaml
k3s_cluster:
  children:
    server:
      hosts:
        k3s-controller-a.k8s.cloud-milky.solufit.net:
    agent:
      hosts:
        k3s-worker-a.k8s.cloud-milky.solufilky.solufit.net:
        k3s-worker-b.k8s.cloud-milky.solufit.net:
```

### Required vars (lines 13–24)
```yaml
  vars:
    ansible_port: 22
    ansible_user: ubuntu
    k3s_version: v1.35.3+k3s1
    token: "changeme!"            # <-- plaintext, vault-recommended (see §6)
    api_endpoint: "k3s-controller.k8s.cloud-milky.solufit.net"
```

### extra_server_args (lines 26–32) — the "server flags" section
```yaml
    extra_server_args: >-
      --disable traefik
      --disable local-storage
      --disable servicelb
      --flannel-backend=host-gw
```
> This is a folded scalar passed straight to the k3s installer as `INSTALL_K3S_EXEC` for server nodes. The collection default is `extra_server_args: ""`. The agent equivalent is `extra_agent_args: ""` (commented).

### Commented optional vars (lines 33–58) — incl. manifests + registries
The block documents the collection's optional knobs. **Directly relevant to Harbor:**
```yaml
    # Manifests or Airgap should be either full paths or relative to the playbook directory.
    # List of locally available manifests to apply to the cluster, useful for PVCs or Traefik modifications.
    # extra_manifests: [ '/path/to/manifest1.yaml', '/path/to/manifest2.yaml' ]   # line 44
    # airgap_dir: /tmp/k3s-airgap-images                                          # line 45

    # server_config_yaml:  |          # -> /etc/rancher/k3s/config.yaml (server)   line 47
    # agent_config_yaml:  |           # -> /etc/rancher/k3s/config.yaml (agent)    line 51
    # registries_config_yaml:  |      # -> /etc/rancher/k3s/registries.yaml        line 55
    #   Containerd can be configured to connect to private registries ...
    #   See https://docs.k3s.io/installation/private-registry
```

### Existing registries.yaml handling
**None active.** Only the commented `registries_config_yaml:` stub. To enable, uncomment and supply YAML body. See §2 for how the collection consumes it.

---

## 2. k3s-ansible collection usage

### Pinning — `ansible/requirements.yml` (6 lines)
```yaml
---
collections:
  - name: https://github.com/k3s-io/k3s-ansible.git
    type: git
    version: 2c3f3773c704bd00bf7f6fc340cac8ab7ce9121b   # pinned SHA (not a tag)
  - name: kubernetes.core
```

### Installed namespace / FQCN
Installed (via `make install-requirements` = `ansible-galaxy collection install -r requirements.yml`) into:
`~/.ansible/collections/ansible_collections/k3s/orchestration/`
→ **FQCN is `k3s.orchestration`** (namespace `k3s`, collection `orchestration`), **NOT** `k3s_io.k3s_ansible` as the upstream git name suggests.

### Collection playbook actually invoked — `k3s.orchestration.site`
Referenced in `Makefile` (lines 53–54, 59):
```
ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml
ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml --tags kubeconfig
ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml --tags upgrade
```
Source: `~/.ansible/collections/ansible_collections/k3s/orchestration/playbooks/site.yml`
```yaml
---
- name: Cluster prep
  hosts: k3s_cluster
  gather_facts: true
  become: true
  roles:
    - role: prereq      # <-- handles registries.yaml + extra_manifests HERE
    - role: airgap
    - role: raspberrypi

- name: Setup K3S server
  hosts: server
  become: true
  roles:
    - role: k3s_server   # writes /etc/rancher/k3s/config.yaml (server)

- name: Setup K3S agent
  hosts: agent
  become: true
  roles:
    - role: k3s_agent    # writes /etc/rancher/k3s/config.yaml (agent) if agent_config_yaml set
```

### How variables are passed
No `vars_files:` / no `extra_vars` on the CLI — variables come from the **inventory `k3s_cluster.vars`** (§1) merged over the role defaults. The collection's role defaults set the keys it expects (`api_port`, `server_group=server`, `agent_group=agent`, `extra_server_args=""`, `extra_agent_args=""`, `k3s_server_location`, `systemd_dir`, etc.).

### `registries_config_yaml` / `extra_manifests` mechanism — THE key finding
Implemented in **`roles/prereq/tasks/main.yml`** (lines 289–333), runs on **all `k3s_cluster` hosts** (server AND agent) before install:

**extra_manifests (lines 306–319):** copies each listed file into `/var/lib/rancher/k3s/server/manifests/` (k3s auto-applies manifests dropped here). Paths must be absolute or relative to the playbook dir.
```yaml
- name: Setup extra manifests
  when: extra_manifests is defined
  block:
    - name: Make manifests directory
      ansible.builtin.file:
        path: "/var/lib/rancher/k3s/server/manifests"
        mode: "0700"
        state: directory
    - name: Copy manifests
      ansible.builtin.copy:
        src: "{{ item }}"
        dest: "/var/lib/rancher/k3s/server/manifests"
        mode: "0600"
      loop: "{{ extra_manifests }}"
```

**registries_config_yaml (lines 321–333):** writes the var verbatim to `/etc/rancher/k3s/registries.yaml` on every node:
```yaml
- name: Setup optional private registry configuration
  when: registries_config_yaml is defined
  block:
    - name: Make k3s config directory
      ansible.builtin.file:
        path: "/etc/rancher/k3s"
        mode: "0755"
        state: directory
    - name: Copy config values
      ansible.builtin.copy:
        content: "{{ registries_config_yaml }}"
        dest: "/etc/rancher/k3s/registries.yaml"
        mode: "0644"
```
> For Harbor, this is exactly the knob you want — populate it with a `mirrors:` + `configs:` block pointing at the Harbor registry endpoint. k3s/containerd reads `/etc/rancher/k3s/registries.yaml` at runtime. No restart handling is wired in the collection (the file is laid down before k3s starts), so post-install changes need a `systemctl restart k3s/k3s-agent`.

### Other config knobs the collection supports (defaults)
- `roles/k3s_server/defaults/main.yml`: `k3s_server_location`, `systemd_dir=/etc/systemd/system`, `api_port=6443`, `kubeconfig=~/.kube/config.new`, `user_kubectl=true`, `cluster_context=k3s-ansible`, `use_external_database=false`, `extra_server_args=""`, `extra_install_envs={}`.
- `roles/k3s_agent/defaults/main.yml`: `extra_agent_args=""`, plus server/location/systemd/api_port.
- `server_config_yaml` (server) / `agent_config_yaml` (agent): raw YAML written to `/etc/rancher/k3s/config.yaml` (merged with generated config on the server).
- `extra_service_envs`: list of `KEY=VAL` lines appended to the k3s systemd env file.

---

## 3. Existing registries / containerd / mirror references

Searched whole repo for `registr(y|ies)|containerd|mirror|harbor`. **In `ansible/`: zero active config** — only the commented stub in `inventory.yml` (lines 55–58).

Elsewhere (NOT in ansible, listed for completeness):
- `.opencode/research/harbor-helm-chart.md` — prior Harbor research (Helm chart, Traefik ingress, NFS PVCs).
- `.opencode/artifacts/task-outputs/*.md` — Harbor ArgoCD planning notes.
- `argocd/k3s/apps/application/librechat/application.yaml` — unrelated `registry:` (image repo) fields.
- `.github/renovate.json` — unrelated `registryUrlTemplate`.

**Conclusion:** no private registry mirror is currently configured on the cluster. Adding one via `registries_config_yaml` is greenfield.

---

## 4. Custom file deployment / templates — the two idioms

### Idiom A — role with a Jinja2 template + handler (repo-local roles)
Used by `roles/fluent_bit/` and `roles/node_exporter/`. Canonical pattern (`roles/fluent_bit/tasks/main.yml` lines 49–57):
```yaml
- name: Deploy Fluent Bit configuration
  ansible.builtin.template:
    src: fluent-bit.conf.j2          # lives in roles/<role>/templates/
    dest: "{{ fluent_bit_config_path }}"
    owner: root
    group: root
    mode: "0644"
  become: true
  notify: Restart fluent-bit         # handler in roles/<role>/handlers/main.yml
```
Templates present:
- `/home/ubuntu/homelab/ansible/roles/fluent_bit/templates/fluent-bit.conf.j2` (uses `{{ ansible_hostname }}`, `{{ fluent_bit_loki_host }}`, `{{ fluent_bit_loki_port }}`)
- `/home/ubuntu/homelab/ansible/roles/node_exporter/templates/node_exporter.service.j2` (systemd unit)

### Idiom B — inline `copy` with `content: |` or `content: "{{ var }}"`
Used by `playbooks/router.yml` (netplan, lines 23–54) and by the **k3s collection** itself for `registries.yaml` / `config.yaml` (see §2). No `.j2` template writes to `/etc/rancher/k3s/` today.

### NFS role's file-config pattern (`lineinfile` for /etc/exports)
`roles/nfs_server/tasks/main.yml` lines 77–84 uses `ansible.builtin.lineinfile` to edit `/etc/exports` + `notify: Restart NFS server`.

### Recommendation for Harbor `registries.yaml`
Prefer the **native collection knob** (`registries_config_yaml` in inventory) over a custom role — it already targets `/etc/rancher/k3s/registries.yaml` on all nodes. If you want a separately-runnable, idempotent, templated approach (e.g. for re-applying after Harbor TLS changes without re-running the full installer), follow Idiom A: new role `roles/k3s_registries/` with `templates/registries.yaml.j2` + handler `systemctl restart k3s` (server) / `k3s-agent` (agent). Lint will require `ansible.builtin.*` FQCN and a handler for any service restart.

---

## 5. NFS role — `ansible/roles/nfs_server/`

**Files:** `tasks/main.yml`, `defaults/main.yml`, `handlers/main.yml`.

### Defaults (`roles/nfs_server/defaults/main.yml`)
```yaml
nfs_export_path: "/srv/nfs/k3s"
nfs_allowed_network: "10.2.0.0/24"
nfs_block_device: "/dev/vda"
nfs_filesystem_type: "btrfs"
nfs_mount_point: "/srv/nfs"
```
Overridden per-inventory in `inventories/k3s/inventory-nfs.yml` (same values). 

### What it does (`tasks/main.yml`, 87 lines)
1. Asserts `/dev/vda` exists; formats it **btrfs** (idempotent via `blkid` check) if blank.
2. Creates mount point `/srv/nfs`, adds fstab entry `… defaults,compress=zstd 0 2`, mounts it.
3. Installs `nfs-kernel-server`.
4. Creates export dir `/srv/nfs/k3s` (owner `nobody:nogroup`, mode `0777`).
5. Starts/enables `nfs-kernel-server`.
6. Appends to `/etc/exports`:
   ```
   /srv/nfs/k3s 10.2.0.0/24(rw,sync,no_subtree_check,no_root_squash)
   ```
7. `meta: flush_handlers` → handler `Restart NFS server` restarts the service immediately.

**Export path:** `/srv/nfs/k3s`. **Allowed network:** `10.2.0.0/24`. **Options:** `rw,sync,no_subtree_check,no_root_squash`. (Relevant: Harbor `registry` PVC backed by the `nfs` storage class lands here.)

---

## 6. Vault / secrets

**Ansible Vault is NOT used anywhere.** grep for `vault|ansible.?vault|!vault|\$ANSIBLE_VAULT` over `ansible/` returns exactly **one** hit: a comment in `inventory.yml` line 21 suggesting you *could* vault the token.

- `group_vars/` and `host_vars/` are **empty** (only `.keep` placeholder).
- `inventories/staging/hosts.ini` → `localhost ansible_connection=local`. `inventories/production/hosts.ini` → placeholder only.
- `token: "changeme!"` is plaintext in the inventory (the k3s cluster join token).
- Other playbook secrets: none embedded. `playbooks/argocd.yml` uses no passwords (Argo installed via public Helm chart).

Per repo `AGENTS.md`: in-cluster secrets are managed with **Sealed Secrets** (`kubeseal`) at the k8s layer, not via ansible. So Harbor admin password / DB password / secret key should follow the SealedSecret convention (already noted in `.opencode/research/harbor-helm-chart.md`), not ansible vault.

---

## 7. Makefile — `ansible/Makefile` (98 lines, FULL)

**File path:** `/home/ubuntu/homelab/ansible/Makefile`

### Toolchain targets
| Target | Command |
|---|---|
| `install-lint` | `pip install --break-system-packages -r requirements.txt` (ansible + ansible-lint) |
| `install-requirements` | `ansible-galaxy -vv collection install -r requirements.yml` (installs `k3s.orchestration` + `kubernetes.core`) |
| `lint` | `ansible-lint -vv .` |
| `check` | `lint` + syntax-check `site.yml` and `playbooks/*.yml` + `ansible-inventory --list` against all 7 inventory files (staging, production, k3s, k3s-nfs, k3s-router, k3s-node-exporter, k3s-fluent-bit). |

### Core k3s targets
| Target | Effect |
|---|---|
| `make install-k3s` | **Ordered pipeline (see below)** — full cluster bring-up. |
| `make upgrade-k3s` | `k3s.orchestration.site --tags upgrade` |
| `make reboot-k3s` | `ansible -m reboot --become` on `k3s_cluster` |
| `make copy-kubeconfig` | `playbooks/fetch-kubeconfig.yml` |
| `make deploy-argocd` | `playbooks/argocd.yml` |
| `make deploy-longhorn` | `playbooks/btrfs-longhorn.yml` |
| `make deploy-nfs-client` | `playbooks/nfs-client.yml` |

### `make install-k3s` order (lines 50–56) — DO NOT REORDER
```
1. ansible-playbook ... playbooks/nfs-client.yml          # install nfs-common on all nodes
2. ansible-playbook ... playbooks/btrfs-longhorn.yml       # format/mount /dev/vda btrfs -> /mnt/longhorn
3. ansible-playbook ... k3s.orchestration.site ...         # FULL k3s install (prereq -> server -> agent)
4. ansible-playbook ... k3s.orchestration.site ... --tags kubeconfig   # generate/fetch kubeconfig
5. ansible-playbook ... playbooks/fetch-kubeconfig.yml     # copy /etc/rancher/k3s/k3s.yaml -> ~/.kube/config, rewrite 127.0.0.1 -> api_endpoint
6. ansible-playbook ... playbooks/argocd.yml               # helm-install argo-cd + apply the two App-of-Apps
```

### Auxiliary targets (NFS/router/monitoring)
`ping`, `inventory-list`, `ping-nfs`/`deploy-nfs`/`restart-nfs`, `ping-router`/`deploy-router`, `ping-node-exporter`/`deploy-node-exporter`/`restart-node-exporter`, `ping-fluent-bit`/`deploy-fluent-bit`/`restart-fluent-bit`, `deploy-staging`, `deploy-production`.

---

## 8. Site playbook structure & orchestration

**`ansible/site.yml` is a STUB** (8 lines) — it just pings all hosts:
```yaml
---
- name: Main Playbook
  hosts: all
  gather_facts: true
  tasks:
    - name: Ping all hosts
      ansible.builtin.ping:
```
There is **no master playbook** that chains everything. Real orchestration lives in the **`Makefile`** (§7), which invokes a sequence of independent playbooks:

| Playbook | Path | Hosts | Role/Action |
|---|---|---|---|
| nfs-server.yml | `playbooks/nfs-server.yml` | `nfs_servers` | role `nfs_server` (§5) |
| nfs-client.yml | `playbooks/nfs-client.yml` | `k3s_cluster` | install `nfs-common` |
| btrfs-longhorn.yml | `playbooks/btrfs-longhorn.yml` | `k3s_cluster` | role `btrfs_longhorn` (format `/dev/vda` → `/mnt/longhorn`) |
| (collection) | `k3s.orchestration.site` | `k3s_cluster` → `server` → `agent` | prereq/airgap/raspberrypi → k3s_server → k3s_agent |
| fetch-kubeconfig.yml | `playbooks/fetch-kubeconfig.yml` | `server[0]` | fetch `k3s.yaml`, rewrite `127.0.0.1`→`api_endpoint` |
| argocd.yml | `playbooks/argocd.yml` | `server[0]` | helm install `argo-cd` 9.5.19 + apply `application-infrastructure.yaml` & `application-application.yaml` |
| router.yml | `playbooks/router.yml` | `k3s_router` | NAT gateway (sysctl, netplan, iptables MASQUERADE `10.2.0.0/24`) |
| node-exporter.yml | `playbooks/node-exporter.yml` | `nfs_servers:k3s_router` | role `node_exporter` (systemd unit from `.j2`) |
| fluent-bit.yml | `playbooks/fluent-bit.yml` | `nfs_servers:k3s_router` | role `fluent_bit` (apt repo + templated conf → Loki) |

> **Implication for Harbor:** to add `registries.yaml` provisioning, the natural integration point is either (a) populate `registries_config_yaml` in `inventory.yml` so the collection lays it down during step 3 of `make install-k3s`, or (b) a new `make deploy-registries` target + playbook invoking a new role, for re-runnability without reinstalling k3s.

---

## 9. Lint config

### `ansible/ansible.cfg` (6 lines)
```ini
[defaults]
inventory = ./inventories/staging
roles_path = ./roles
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
```
> Default inventory is **staging** (the `localhost` stub). The k3s playbooks are always run with an explicit `-i inventories/k3s/...`.

### `ansible/.ansible-lint` (7 lines)
```yaml
---
profile: null        # default profile (= "production"/gen-aware baseline)
exclude_paths:
  - .git/
  - .github/
verbosity: 1
```
No rules skipped/relaxed beyond defaults. Roles linted (the comment hints you *could* exclude `roles/` but it is currently NOT excluded — so all four repo-local roles must pass ansible-lint).

### Conventions new tasks MUST follow to pass lint
- **FQCN only**: `ansible.builtin.apt/file/copy/template/systemd/get_url/lineinfile/...`, `ansible.posix.sysctl/mount`, `community.general.filesystem`, `kubernetes.core.k8s/helm/helm_repository`. (All existing tasks use FQCN.)
- **`become: true`** on every privileged task (the existing roles set it per-task; `make install-k3s` playbooks set it at play level for some, per-task for others).
- **Handler for any restart**: `notify: Restart <svc>` + matching `handlers/main.yml` (see nfs_server, fluent_bit, node_exporter).
- **Mode quoted**: `mode: "0644"` / `'0755'` (string) — already the house style.
- **`changed_when`/`failed_when`** on `command`/`shell` (see `fetch-kubeconfig.yml`, `router.yml`, nfs `blkid`).

---

## 10. Concrete options for wiring Harbor `registries.yaml` (recommendations)

Given the above, two viable approaches:

**Option 1 (minimal, install-time):** uncomment in `inventories/k3s/inventory.yml`:
```yaml
    registries_config_yaml:  |
      mirrors:
        docker.io:
          endpoint:
            - "https://harbor-k3s.lapis-dev.work"   # Harbor proxy cache
      configs:
        "harbor-k3s.lapis-dev.work":
          auth:
            username: admin
            password_file: /etc/rancher/k3s/harbor-pull.txt   # or inline (vault!)
```
Pros: zero new code, collection writes it to every node during `make install-k3s`. Cons: only applied at install; needs full `site` re-run to change; secrets are plaintext (no vault in this repo).

**Option 2 (re-runnable, matches repo idiom):** new role `roles/k3s_registries/` with:
- `templates/registries.yaml.j2` (Idiom A from §4),
- `tasks/main.yml`: `ansible.builtin.template` → `/etc/rancher/k3s/registries.yaml`, `notify: Restart k3s (server) / k3s-agent (agent)`,
- `handlers/main.yml` with the two restarts,
- a new `playbooks/registries.yml` (hosts `k3s_cluster`, `become: true`) + `make deploy-registries` Makefile target.
Pros: idempotent, re-runnable, templatable, lint-clean. Cons: more files; must branch restart by node role (server vs agent) — gate with `when: "'server' in group_names"`.

In both cases, Harbor itself is deployed via ArgoCD (GitOps), not ansible — see `.opencode/research/harbor-helm-chart.md` for the chart/Application manifest plan.

---

## Appendix — all files read

Inventory & config:
- `/home/ubuntu/homelab/ansible/inventories/k3s/inventory.yml` (§1)
- `/home/ubuntu/homelab/ansible/inventories/k3s/inventory-nfs.yml`
- `/home/ubuntu/homelab/ansible/inventories/k3s/inventory-router.yml`
- `/home/ubuntu/homelab/ansible/inventories/k3s/inventory-node-exporter.yml`
- `/home/ubuntu/homelab/ansible/inventories/k3s/inventory-fluent-bit.yml`
- `/home/ubuntu/homelab/ansible/inventories/staging/hosts.ini`, `production/hosts.ini`
- `/home/ubuntu/homelab/ansible/ansible.cfg`, `.ansible-lint`, `requirements.txt`, `requirements.yml`

Playbooks: `site.yml`, `playbooks/{nfs-server,nfs-client,btrfs-longhorn,fetch-kubeconfig,argocd,router,node-exporter,fluent-bit}.yml`, `Makefile`, `README.md`.

Roles: `roles/nfs_server/{tasks,defaults,handlers}/main.yml`, `roles/btrfs_longhorn/{tasks,defaults}/main.yml`, `roles/fluent_bit/{tasks,defaults}/main.yml` + `templates/fluent-bit.conf.j2`, `roles/node_exporter/{tasks,defaults}/main.yml` + `templates/node_exporter.service.j2`.

Collection (`k3s.orchestration`): `playbooks/site.yml`, `inventory-sample.yml`, `README.md`, `roles/prereq/tasks/main.yml` (lines 280–333) + `defaults/main.yml`, `roles/k3s_server/{tasks,defaults}/main.yml`, `roles/k3s_agent/{tasks,defaults}/main.yml`.
