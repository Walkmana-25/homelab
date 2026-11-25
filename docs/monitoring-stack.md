# Monitoring Stack Migration to OCI

Last reviewed: 2026-11-25

Status: Proposed plan. No cluster, OCI, DNS, or deployment state has been
changed; the documentation changes are the only repository changes.

Japanese version: [monitoring-stack.ja.md](monitoring-stack.ja.md)

## Scope

Move the storage and presentation layer of the homelab monitoring stack from the
on-premises k3s cluster to a single Oracle Cloud Infrastructure (OCI) virtual
machine running Docker Compose:

- VictoriaMetrics (single-node) for metrics
- Loki (monolithic) for logs, with chunks and indexes in Backblaze B2
- Grafana for dashboards and alerting
- Caddy and `cloudflared` for the edge

The collection layer stays on-premises:

- `vmagent` continues to scrape the cluster and the VM node exporters.
- Fluent Bit continues to collect container and journald logs.
- `technitium-sd` continues to provide HTTP service discovery.

This split is deliberate. The collectors depend on the private `10.2.0.0/24`
network, Technitium DNS, and NFS/LINSTOR-backed PVCs. Moving them to OCI would
require a new site-to-site VPN and would make collection fragile. Remote write
and Loki push are outbound-only and fit the existing Cloudflare Tunnel model.

### Non-goals

- High availability. The OCI VM is a single point of failure. This is accepted.
- Migrating historical metrics or logs. The new stack starts empty; on-premises
  history expires under the existing retention policy.
- Running Kubernetes on OCI. The target is Docker Compose.
- Replacing Grafana alerting with `vmalert` or Alertmanager. See
  [Alert rule strategy](#alert-rule-strategy) for the trade-off.

## Current State

The monitoring stack is deployed by the Argo CD `infrastructure` root Application
into the `monitoring` namespace.

| Component | Current configuration | Evidence |
| --- | --- | --- |
| Metrics storage | VictoriaMetrics `vmsingle`, 180-day retention, 40Gi NFS PVC | `argocd/k3s/apps/infrastructure/victoria-metrics/application.yaml` |
| Metrics collection | `vmagent`, 60-second scrape interval, Technitium HTTP SD for VMs | same file, plus `technitium-sd/` |
| Visualization | Grafana chart 10.5.15, 1Gi `ssd` PVC, Cloudflare Tunnel ingress | `argocd/k3s/apps/infrastructure/grafana/application.yaml` |
| Datasources | Cluster-local `vmsingle` and `loki` Services | same file |
| Alerting | Grafana alerting, Discord contact point, provisioned from ConfigMaps | same file and `grafana/alert-rules/` |
| Log storage | Loki monolithic, filesystem store, 6-month retention, 64Gi NFS PVC | `argocd/k3s/apps/infrastructure/loki/application.yaml` |
| Log collection | Fluent Bit DaemonSet plus Ansible-managed VM agents | `fluent-bit/application.yaml`, `ansible/roles/fluent_bit/` |
| Public edge | Cloudflare Tunnel; no VPN, Gateway API, or NetworkPolicy | `cloudflare-tunnel-ingress-controller/application.yaml` |
| Secrets | SealedSecrets; sealing key rotation disabled | `sealed-secrets/application.yaml` |

There is no standalone Prometheus, Alertmanager, Tempo, Mimir, Thanos, or
Promtail. The observability data flow is:

```text
VM metrics:   node_exporter -> Technitium DNS SD -> vmagent -> VictoriaMetrics
VM logs:      Fluent Bit -> router nginx -> Loki
Pod logs:     Fluent Bit DaemonSet -> Loki
```

## Target Architecture

```text
On-premises k3s
  vmagent ---- remote_write (HTTPS + Basic Auth) ----+
  Fluent Bit -- Loki push (HTTPS + Basic Auth) ------+
  node_exporter / technitium-sd (unchanged)          |
                                                     |
                                                     v
OCI VM (Docker Compose)
  cloudflared -> Caddy -> Grafana:3000
                      -> VictoriaMetrics:8428  (/api/v1/write only)
                      -> Loki:3100             (/loki/api/v1/push only)

  Block volume: /srv/monitoring/vmdata, /srv/monitoring/lokidata
  Backblaze B2: Loki chunks and TSDB indexes
```

Design properties:

- No inbound port is required for Grafana or ingestion when Cloudflare Tunnel is
  used. The public IP is used for SSH (restricted) and outbound connectivity.
- Caddy is the only origin. It terminates no TLS when Cloudflare Tunnel is used;
  Cloudflare terminates TLS at the edge.
- Grafana is protected by Cloudflare Access. Ingestion endpoints use Caddy
  Basic Auth plus path restrictions, not Cloudflare Access, because Fluent Bit
  and `vmagent` need simple HTTP credentials.
- VictoriaMetrics and Loki are reachable only on the private Compose network.
- The alerting plane (Grafana and its external notification path) runs outside
  the homelab, so a homelab outage does not silence alerts. This requires
  absent-data and heartbeat rules; see
  [Alerting during a homelab outage](#alerting-during-a-homelab-outage).

## OCI Resource Design

| Resource | Plan |
| --- | --- |
| Shape | `VM.Standard.A1.Flex`, 4 OCPU, 24 GB RAM |
| OS | Ubuntu 24.04 LTS |
| Public IP | Reserved, if available; otherwise record the ephemeral IP and treat DNS carefully |
| Boot volume | 50 GiB |
| Block volume | 150 GiB, mounted at `/srv/monitoring` |
| VCN | Public subnet; no peering to the on-premises network |
| NSG ingress | TCP 22 from the administrator CIDR only; no 80/443 when using Cloudflare Tunnel |
| NSG egress | All destinations |
| Backup | OCI block volume daily backup, 7-14 day retention |
| Time sync | chrony; verify before starting Loki and VictoriaMetrics |

Reserved public IPs may incur a charge depending on the OCI tenancy; verify the
current pricing before reserving one.

Outbound transfer from OCI to B2 and Cloudflare counts toward OCI egress. The
Always Free allowance is 10 TB/month; verify the current limit before relying on
it.

The 200 GiB Always Free block storage allowance is consumed as:

```text
Boot       50 GiB
Metrics   100 GiB  /srv/monitoring/vmdata
Loki local 50 GiB  /srv/monitoring/lokidata
Total     200 GiB
```

If metrics grow beyond 100 GiB, either move Loki's local directories to the boot
volume and give metrics 150 GiB, or pay for an additional 50 GiB block volume.
Do not let the boot volume fill with Docker images and container logs; configure
Docker log rotation and monitor `/` separately.

A single 150 GiB filesystem lets Loki's local directories consume space intended
for metrics. Partition the volume or use separate volumes if hard isolation
between the 100 GiB metrics and 50 GiB Loki-local budgets matters. Otherwise,
monitor both directories and set alerts before either fills the shared volume.

### Public IP and SSH

The VM has a public IP. Treat it as an Internet-facing host:

- SSH key only; disable password authentication.
- Restrict TCP 22 in the NSG to a stable administrator CIDR. If the administrator
  IP is dynamic, use Cloudflare Tunnel SSH, Tailscale, or OCI Bastion instead of
  opening 22 to the world.
- Do not publish Caddy, Grafana, VictoriaMetrics, or Loki ports on the host.
- If direct HTTPS is chosen instead of Cloudflare Tunnel, allow 443 only from
  Cloudflare IP ranges and use Caddy with a DNS-01 or HTTP-01 certificate. This
  is more moving parts than the tunnel and is not the default recommendation.
- Use a reserved public IP if the OCI tenancy supports it, so DNS and SSH
  allowlists do not break on stop/start.

## Docker Compose Layout

```text
/opt/monitoring/
├── compose.yaml
├── .env                      # chmod 600, never committed
├── .env.example              # committed template with placeholders
├── secrets/
│   └── grafana_admin_password  # chmod 600, never committed
├── caddy/
│   └── Caddyfile
├── loki/
│   └── loki-config.yaml
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   ├── dashboards/
│   │   └── alerting/
│   └── dashboards/
├── deploy.sh
└── ci/
    ├── grafana-provisioning-test.sh
    └── deploy.sh
```

Services:

| Service | Image | Purpose | Persistence |
| --- | --- | --- | --- |
| `cloudflared` | `cloudflare/cloudflared:<pin>` | Outbound tunnel connector | none |
| `caddy` | `caddy:2.9` | Reverse proxy, Basic Auth, path restrictions | `caddy_data` |
| `grafana` | `grafana/grafana:<pin>` | UI and alerting | `/srv/monitoring/grafanadata` |
| `victoriametrics` | `victoriametrics/victoria-metrics:<pin>` | Metrics storage | `/srv/monitoring/vmdata` |
| `loki` | `grafana/loki:<pin>` | Log storage | `/srv/monitoring/lokidata` |
| `node-exporter` | `prom/node-exporter:<pin>` | OCI VM self-monitoring | none |

Pin exact image tags. Do not use `latest`. Record the currently deployed image
tags from the cluster before choosing the target versions:

```bash
kubectl -n monitoring get deploy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
```

Compose skeleton:

```yaml
name: monitoring

services:
  cloudflared:
    image: cloudflare/cloudflared:<pin>
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    restart: unless-stopped
    depends_on:
      - caddy

  caddy:
    image: caddy:2.9
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/healthz"]
      interval: 30s

  victoriametrics:
    image: victoriametrics/victoria-metrics:<pin>
    command:
      - -storageDataPath=/victoria-metrics-data
      - -retentionPeriod=6
      - -httpListenAddr=:8428
      - -dedup.minScrapeInterval=60s
    volumes:
      - /srv/monitoring/vmdata:/victoria-metrics-data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8428/health"]
      interval: 30s

  loki:
    image: grafana/loki:<pin>
    command: -config.file=/etc/loki/loki-config.yaml -config.expand-env=true
    env_file:
      - .env
    volumes:
      - ./loki/loki-config.yaml:/etc/loki/loki-config.yaml:ro
      - /srv/monitoring/lokidata:/var/loki
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3100/ready"]
      interval: 30s

  grafana:
    image: grafana/grafana:<pin>
    env_file:
      - .env
    environment:
      GF_SERVER_ROOT_URL: ${GRAFANA_ROOT_URL}
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - /srv/monitoring/grafanadata:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    secrets:
      - grafana_admin_password
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/health"]
      interval: 30s

volumes:
  caddy_data:

secrets:
  grafana_admin_password:
    file: ./secrets/grafana_admin_password
```

No public ports are published. Grafana binds only `127.0.0.1:3000` so local
health checks and the deploy script can reach it; external traffic still goes
through `cloudflared` and Caddy. `cloudflared` reaches `caddy:8080` over the
Compose network. Grafana reaches VictoriaMetrics and Loki by service name.

Set `GRAFANA_ROOT_URL` to `https://grafana-oci.<domain>` during validation and
change it to the production hostname at cutover. Add the production host route
to the Caddyfile at the same time.

Create a systemd unit so the stack starts at boot:

```ini
[Unit]
Description=Monitoring stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/monitoring
ExecStart=/usr/bin/docker compose up -d --wait
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

## Caddy and Cloudflare Tunnel

Create a dedicated Cloudflare Tunnel for the OCI stack. Do not reuse the
on-premises tunnel token; a separate tunnel makes rollback and DNS ownership
explicit.

Suggested hostnames:

| Hostname | Origin | Protection |
| --- | --- | --- |
| `grafana-oci.<domain>` | `http://caddy:8080` | Cloudflare Access |
| `vm-ingest.<domain>` | `http://caddy:8080` | Caddy Basic Auth, path restricted |
| `loki-ingest.<domain>` | `http://caddy:8080` | Caddy Basic Auth, path restricted |

`grafana-oci` is the validation hostname. The production `grafana-k8s` record is
switched only at cutover.

Caddyfile:

```caddyfile
{
  auto_https off
}

:8080 {
  @health {
    path /healthz
    remote_ip 127.0.0.1 ::1
  }
  handle @health {
    respond "ok" 200
  }

  @grafana host grafana-oci.lapis-dev.work
  handle @grafana {
    reverse_proxy grafana:3000
  }

  @vmpush {
    host vm-ingest.lapis-dev.work
    path /api/v1/write
  }
  handle @vmpush {
    basic_auth {
      ingest <bcrypt-hash>
    }
    reverse_proxy victoriametrics:8428
  }

  @lokipush {
    host loki-ingest.lapis-dev.work
    path /loki/api/v1/push
  }
  handle @lokipush {
    basic_auth {
      ingest <bcrypt-hash>
    }
    reverse_proxy loki:3100
  }

  respond 404
}
```

Generate the bcrypt hash with:

```bash
docker run --rm caddy:2.9 caddy hash-password --plaintext '<secret>'
```

Store the hash in the Caddyfile or inject it with `{$INGEST_PASSWORD_HASH}`.
Never commit the plaintext password. In the Cloudflare Zero Trust dashboard,
point the `grafana-oci`, `vm-ingest`, and `loki-ingest` public hostnames at
`http://caddy:8080`.

The Caddyfile above implements these restrictions:

- `vm-ingest` allows only `/api/v1/write`. Query endpoints stay internal.
- `loki-ingest` allows only `/loki/api/v1/push`. `/ready` and `/metrics` stay
  internal; use the Compose healthcheck instead.
- Everything else returns 404, so management APIs are not reachable.
- `/healthz` is a local Caddy health endpoint for the Compose healthcheck.

At cutover, add a `grafana-k8s.<domain>` host route that points to the same
Grafana upstream. Keep the `grafana-oci` route until rollback is no longer
needed.

## VictoriaMetrics

Run single-node VictoriaMetrics with the same retention semantics as the current
chart. The chart comment says the Helm key `retentionPeriod: 180d` maps to
`-retentionPeriod=6`; verify the exact flag against the pinned image before
deployment.

```text
-storageDataPath=/victoria-metrics-data
-retentionPeriod=6
-httpListenAddr=:8428
-dedup.minScrapeInterval=60s
```

`dedup.minScrapeInterval=60s` matches the 60-second scrape interval and removes
duplicate samples during dual-write.

### On-premises remote write

Add a `remoteWrite` entry to `vmagent` in
`argocd/k3s/apps/infrastructure/victoria-metrics/application.yaml`:

```yaml
vmagent:
  spec:
    remoteWrite:
      - url: https://vm-ingest.lapis-dev.work/api/v1/write
        basicAuth:
          username:
            name: vmagent-remote-write
            key: username
          password:
            name: vmagent-remote-write
            key: password
        queueConfig:
          capacity: 2500
          maxShards: 30
          maxSamplesPerSend: 10000
          batchSendDeadline: 5s
        tlsConfig:
          insecureSkipVerify: false
```

Add the `cluster=k3s` external label so the cloud and on-premises copies can be
distinguished during dual-write.

Keep the on-premises `vmsingle` running during the validation window. It is the
rollback target and a short-term local buffer. Configure a disk buffer for
`vmagent` remote write so a short OCI outage does not block collection:

```text
-remoteWrite.tmpDataPath=/tmp/vmagent-remotewrite
```

Mount an `emptyDir` or PVC at that path; `/tmp` inside the container is
ephemeral. Size the buffer for the expected OCI outage duration.

## Loki and Backblaze B2

Loki 3.x supports `zstd` chunk encoding, TSDB indexes, and S3-compatible object
storage. Verify the pinned image supports both before enabling them.

### Storage layout

| Path | Purpose | Size |
| --- | --- | --- |
| `/var/loki/chunks` | Chunk cache and WAL-adjacent data | part of 50 GiB |
| `/var/loki/wal` | Ingestion WAL | 10-20 GiB |
| `/var/loki/compactor` | Compactor working directory | 10-20 GiB |
| `/var/loki/index` | TSDB shipper active index/cache | 5-10 GiB |

Chunks and indexes live in B2. The local 50 GiB is for WAL, compactor work, and
caches; it is not the primary log store.

### Loki configuration

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /var/loki
  storage:
    s3:
      endpoint: https://s3.<region>.backblazeb2.com
      region: <region>
      bucketnames: <bucket>
      access_key_id: ${B2_ACCESS_KEY_ID}
      secret_access_key: ${B2_SECRET_ACCESS_KEY}
      s3forcepathstyle: true
      insecure: false

schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 4380h
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  volume_enabled: true
  ingestion_rate_mb: 20
  ingestion_burst_size_mb: 40

compactor:
  working_directory: /var/loki/compactor
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_cancel_period: 2h
  delete_request_store: s3

ingester:
  chunk_encoding: zstd
  max_chunk_age: 336h
```

Notes:

- `object_store: s3` must be set in `schema_config`; otherwise Loki continues to
  write chunks to the filesystem.
- `delete_request_store: s3` is required for compactor delete requests when the
  object store is S3.
- `s3forcepathstyle: true` is the safer starting point with a custom endpoint.
  Backblaze supports both path-style and virtual-hosted-style URLs.
- `-config.expand-env=true` allows `${B2_...}` substitution from `.env`.
- `max_chunk_age: 336h` preserves the current backlog-drain behavior. If the
  backlog problem is solved, reduce it to 2-6 hours to bound memory.
- `zstd` improves compression and reduces egress, but costs CPU. If CPU becomes
  a bottleneck during backlog drain, fall back to `gzip`.
- `reject_old_samples_max_age: 168h` drops buffered logs older than 7 days after
  an extended outage. If longer buffering is required, increase this value.

Validate before deployment:

```bash
docker run --rm \
  -v "$PWD/oci/monitoring/loki:/etc/loki:ro" \
  grafana/loki:<pin> \
  -config.file=/etc/loki/loki-config.yaml -verify-config
```

### Fluent Bit changes

Add a second Loki output for the cloud endpoint. Keep the local output during
dual-write.

```ini
[OUTPUT]
    Name          loki
    Match         kube.*
    Host          loki-ingest.lapis-dev.work
    Port          443
    URI           /loki/api/v1/push
    tls           On
    http_user     ${LOKI_INGEST_USER}
    http_passwd   ${LOKI_INGEST_PASSWORD}
    labels        job=fluent-bit,log_type=$log_type,namespace=$kubernetes['namespace_name'],pod=$kubernetes['pod_name'],container=$kubernetes['container_name']
    storage.path  /var/log/flb-buffer/
    storage.total_limit_size 2G
    retry_limit   False
```

The VM-side Ansible role (`ansible/roles/fluent_bit/`) needs the same second
output. Use a filesystem buffer so a short OCI outage does not drop logs.
Size the buffer for the expected outage duration; 2G is a starting point, not a
guarantee.

## Grafana Provisioning

Grafana runs with file-based provisioning. Do not edit dashboards, datasources,
contact points, or alert rules in the UI.

### Datasources

```yaml
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    uid: victoriametrics
    type: prometheus
    url: http://victoriametrics:8428
    isDefault: true
  - name: Loki
    uid: loki
    type: loki
    url: http://loki:3100
```

The UIDs must remain `victoriametrics` and `loki`. Existing alert rules reference
`datasourceUid: victoriametrics`.

### Dashboards

Extract the dashboard JSON from the existing ConfigMaps and place it under
`grafana/dashboards/`. Configure a file provider:

```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

### Alert rules

The existing alert rules are already Grafana provisioning YAML inside ConfigMaps.
Extract the inner document for each file:

```bash
mkdir -p oci/monitoring/grafana/provisioning/alerting
for f in argocd/k3s/apps/infrastructure/grafana/alert-rules/*.yaml; do
  name=$(basename "$f")
  yq ".data[\"${name%.yaml}.yaml\"]" "$f" \
    > "oci/monitoring/grafana/provisioning/alerting/rules-${name}"
done
```

Keep the alerting files flat in `provisioning/alerting/`; Grafana's recursive
loading behavior depends on the version.

Contact point:

```yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: discord-alerts
    receivers:
      - uid: discord-receiver
        type: discord
        settings:
          url: $__env{DISCORD_WEBHOOK_URL}
          message: |
            {{ template "default.message" . }}
```

Notification policy:

```yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: discord-alerts
    group_by: ['...']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
```

Use `$__env{...}` rather than `$VAR` for provisioning secrets. It is the
documented interpolation form.

Ensure the `Homelab` folder exists. Recent Grafana versions create provisioned
folders automatically, but verify it in the CI smoke test before relying on it.

### Alert rule strategy

Grafana alerting is the default because:

- The existing rules already use Grafana provisioning format.
- Contact points and notification policies are part of the same Git tree.
- No extra Alertmanager or `vmalert` containers are needed.

The trade-off is testability. Grafana alert rules are not plain Prometheus rules,
so `promtool` or `vmalert-tool` cannot unit-test them directly. CI instead starts
a disposable Grafana, mounts the provisioning directory, and asserts that the
rules and contact points load:

```bash
docker run -d --rm --name grafana-check \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -e DISCORD_WEBHOOK_URL=https://example.invalid \
  -v "$PWD/oci/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro" \
  grafana/grafana:<pin>

for i in $(seq 1 60); do
  curl -fsS http://localhost:3000/api/health >/dev/null && break
  sleep 1
done

curl -fsS -u admin:admin \
  http://localhost:3000/api/v1/provisioning/alert-rules | jq 'length'
curl -fsS -u admin:admin \
  http://localhost:3000/api/v1/provisioning/contact-points | jq 'length'
```

If rule-level unit tests become important, migrate evaluation to `vmalert` with
Prometheus-style rules and keep Grafana for visualization. That is a larger
change and is not required for the first migration.

### Alerting during a homelab outage

The main reason to put Grafana in OCI is to keep alerting alive when the
homelab fails. Threshold rules such as `up == 0` are not enough: if the
on-premises network or `vmagent` dies, the series disappears instead of
becoming 0. Add:

- Absent-data rules with `noDataState: Alerting` for critical jobs:
  - `absent(up{job="node-exporter-vms"})`
  - `absent(up{job="kube-state-metrics"})`
  - `absent(up{job="kubelet"})` if the kubelet is scraped
- A heartbeat from the on-premises router or a small VM to OCI, independent of
  k3s:
  - A systemd timer pushes a synthetic metric or log every minute.
  - An alert fires if the heartbeat is missing for 5-10 minutes.
- `noDataState: Alerting` and `execErrState: Alerting` on critical rules.
- External uptime checks on Grafana and the ingest endpoints, plus a
  dead-man's switch that notifies Discord if the OCI stack itself stops.
- A secondary notification path (email or SMS) in case Discord or Cloudflare is
  unavailable.

Without these, moving Grafana to OCI gives you a dashboard that is up during an
outage but may not tell you that the homelab is down.

## CI/CD

### Choice

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| GitHub Actions + SSH deploy | Explicit, easy rollback, fits GitHub | Needs a secure SSH path | Recommended |
| Pull-based systemd timer | No inbound SSH, simple | Slower, Git credentials on VM | Acceptable fallback |
| Ansible from CI | Reuses existing `ansible/`, idempotent | More playbook maintenance | Acceptable |
| Watchtower | Automatic image updates | Does not manage config, uncontrolled restarts | Not recommended |
| Portainer/Coolify/Dockge | UI convenience | New attack surface, drifts from Git | Not recommended |

### CI validation

Run on pull requests and on pushes to `main` when `oci/monitoring/**` changes:

```yaml
name: monitoring-ci
on:
  pull_request:
    paths: ["oci/monitoring/**"]
  push:
    branches: [main]
    paths: ["oci/monitoring/**"]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Compose config
        run: |
          cp oci/monitoring/.env.example oci/monitoring/ci/test.env
          docker compose \
            --env-file oci/monitoring/ci/test.env \
            -f oci/monitoring/compose.yaml config -q
      - name: Caddy validate
        run: |
          docker run --rm \
            -v "$PWD/oci/monitoring/caddy:/etc/caddy:ro" \
            caddy:2.9 caddy validate --config /etc/caddy/Caddyfile
      - name: Loki config
        run: |
          docker run --rm \
            -v "$PWD/oci/monitoring/loki:/etc/loki:ro" \
            grafana/loki:<pin> \
            -config.file=/etc/loki/loki-config.yaml -verify-config
      - name: YAML lint
        run: yamllint oci/monitoring
      - name: Grafana provisioning smoke test
        run: ./oci/monitoring/ci/grafana-provisioning-test.sh
```

Also validate dashboard JSON with `jq empty` and alert rule files with `yq`.
The CI environment file should contain dummy values for every variable referenced
by the Compose file so interpolation errors are caught before merge.

### CD deploy

Use a GitHub Environment with required reviewers. Do not deploy from every
push; require approval for `production`.

```yaml
name: monitoring-deploy
on:
  push:
    branches: [main]
    paths: ["oci/monitoring/**"]
  workflow_dispatch:

concurrency:
  group: monitoring-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        env:
          SSH_KEY: ${{ secrets.MONITORING_SSH_KEY }}
          CF_ACCESS_CLIENT_ID: ${{ secrets.CF_ACCESS_CLIENT_ID }}
          CF_ACCESS_CLIENT_SECRET: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
        run: ./oci/monitoring/ci/deploy.sh
```

`ci/deploy.sh` runs on the GitHub runner, opens the SSH or Cloudflare Tunnel
session, and invokes `/opt/monitoring/deploy.sh` on the VM. The VM script is the
only code that touches Docker:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /opt/monitoring

git fetch --prune origin
git reset --hard origin/main

docker compose pull
docker compose up -d --wait --remove-orphans --force-recreate

docker compose ps
curl -fsS http://127.0.0.1:3000/api/health >/dev/null
```

Notes:

- `docker compose up -d --wait` requires healthchecks on every service.
- `--force-recreate` applies bind-mounted configuration changes at the cost of a
  brief restart. Fluent Bit buffers cover the Loki restart; `vmagent` buffers
  cover the VictoriaMetrics restart. If restart-free reloads are preferred, call
  `POST /api/admin/provisioning/alerting/reload` for Grafana and restart Loki
  and Caddy only when their configuration changed.
- Save the previous SHA and `docker compose config` output under
  `/opt/monitoring/releases/` before deploying.
- On failure, reset to the previous SHA and run `docker compose up -d --wait`.

### Secure deploy path

GitHub-hosted runner IPs are not stable. Do not open TCP 22 to `0.0.0.0/0`.
Choose one:

1. Cloudflare Tunnel SSH with Access service tokens.
2. Tailscale or WireGuard; attach the runner to the tailnet.
3. Self-hosted runner on-premises with a restricted SSH allowlist.

Use a dedicated `deploy` user, key-only authentication, and a forced command or
sudoers rule limited to `deploy.sh`.

### Secrets

- B2 keys, Discord webhook, Grafana admin password, and ingest Basic Auth
  credentials live in `/opt/monitoring/.env` on the VM, mode `0600`.
- Manage that file with SOPS + age or Ansible Vault. Do not commit plaintext.
- GitHub Secrets contain only the SSH key and Cloudflare Access token.
- Rotate the B2 application key and ingest credentials periodically.

### Image updates

Use Renovate's `docker-compose` manager to open PRs for image tag updates. CI
validates the PR; merge triggers deployment. Pin exact tags and optionally
digests. Never use `latest` in production.

## Storage and Cost Estimate

### Metrics

Current empirical anchor: 40 GiB for 180 days. The chart history moved from
20 GiB/90 days to 40 GiB/180 days, so the usage is roughly linear with retention.

| Active series | Est. 180-day size at 1-1.5 bytes/sample | With 20% overhead | Recommendation |
| ---: | ---: | ---: | ---: |
| 50,000 | 13-19 GiB | 16-23 GiB | 50 GiB |
| 100,000 | 26-39 GiB | 31-47 GiB | 60 GiB |
| 150,000 | 39-58 GiB | 47-70 GiB | 100 GiB |
| 200,000 | 52-78 GiB | 62-94 GiB | 100 GiB |
| 300,000 | 78-117 GiB | 94-140 GiB | 150 GiB |

100 GiB covers roughly 200,000 series at 1.5 bytes/sample plus overhead. If the
cluster grows past that, move to 150 GiB or reduce retention.

### Logs

Current empirical anchor: 64 GiB for 6 months after the Loki PVC was raised from
32 GiB. Assume 4-10x compression; use 8x for planning.

| Raw logs/day | 180 days at 8x | With 10% index | Recommendation |
| ---: | ---: | ---: | ---: |
| 0.5 GB | 11.3 GB | 12.4 GB | 20 GB |
| 1 GB | 22.5 GB | 24.8 GB | 30 GB |
| 2 GB | 45.0 GB | 49.5 GB | 60 GB |
| 2.8 GB | 63.0 GB | 69.3 GB | 100 GB |
| 5 GB | 112.5 GB | 123.8 GB | 150 GB |

### Cost

Backblaze B2 pricing used for this plan: $6.95/TB/month, first 10 GB free, free
egress up to 3x average monthly storage, Class A/B/C API calls free.

| Item | Size | Monthly |
| --- | ---: | ---: |
| OCI block (boot + metrics + Loki local) | 200 GiB | $0 within Always Free |
| B2 logs | 70 GB | about $0.42 |
| B2 egress | up to 3x storage | $0 if within allowance |
| **Total** | | **about $0.42/month** |

If block storage exceeds 200 GiB, the overage is about $0.0425/GB/month. If logs
reach 150 GB, B2 is about $0.97/month. Verify current OCI and B2 prices before
committing; both can change.

## Backblaze B2 Versioning and Lifecycle

This is the most important operational detail in the plan.

B2 buckets are versioned by default, and versioning cannot be disabled. When
Loki deletes a chunk with `DeleteObject` and no `versionId`, B2 inserts a delete
marker. The chunk becomes a hidden version and continues to count toward
storage. If lifecycle rules are disabled, storage grows without bound even
though Loki believes retention is working.

### Recommended lifecycle rule

Use a dedicated bucket for Loki and apply one rule that only removes hidden
versions. With a dedicated bucket, an empty `fileNamePrefix` (`""`) is correct.
If the bucket is shared, confirm the actual object key prefix first; Loki's
`index_` value is a filename prefix, not necessarily an S3 key prefix.

```json
[
  {
    "fileNamePrefix": "",
    "daysFromUploadingToHiding": null,
    "daysFromHidingToDeleting": 7,
    "daysFromStartingToCancelingUnfinishedLargeFiles": 7
  }
]
```

| Setting | Meaning |
| --- | --- |
| `daysFromUploadingToHiding: null` | Never hide the current version automatically |
| `daysFromHidingToDeleting: 7` | Physically delete hidden versions 7 days after Loki deletes them |
| `daysFromStartingToCancelingUnfinishedLargeFiles: 7` | Cancel incomplete multipart uploads |

Effective retention becomes about 187 days, so budget 5-10% more than 180 days.
Lifecycle runs once per day and deletion can take up to 72 hours.

Optional safety net for Loki deletion failures:

```json
[
  {
    "fileNamePrefix": "",
    "daysFromUploadingToHiding": 200,
    "daysFromHidingToDeleting": 7,
    "daysFromStartingToCancelingUnfinishedLargeFiles": 7
  }
]
```

This hides current versions at 200 days and deletes them 7 days later. Keep the
value above the Loki retention period; update it if retention changes.

### If lifecycle stays disabled

If lifecycle rules remain disabled, the plan is not bounded. Assuming 64 GB per
6 months (about 10.7 GB/month):

| Elapsed | Stored | Monthly cost |
| --- | ---: | ---: |
| 6 months | 64 GB | $0.38 |
| 1 year | 128 GB | $0.82 |
| 3 years | 384 GB | $2.60 |
| 5 years | 640 GB | $4.38 |

The cost is still small, but object and version counts grow without bound. B2
warns that millions of versions degrade deletion and listing performance, increase
503 responses, and can eventually block uploads. If lifecycle must stay disabled,
run an external job that lists file versions and deletes non-current versions
older than 7 days. That is functionally a reimplementation of the lifecycle rule.

**Recommendation: enable the minimal lifecycle rule.** It does not delete current
logs; it only cleans up versions that Loki has already deleted.

## Backup and Restore

| Data | Backup | Retention | Restore |
| --- | --- | --- | --- |
| VictoriaMetrics | OCI block volume daily backup; optional `vmbackup` to a separate B2 bucket | 7-14 days | `vmrestore` or volume restore |
| Loki chunks/indexes | B2 versioning plus lifecycle; optional bucket replication | Lifecycle | Re-point Loki at the bucket |
| Grafana DB | Daily copy to B2 or a separate backup bucket | 30 days | Restore `grafana.db` |
| Dashboards/alerts | Git | Git history | Re-provision |

Keep backups in a separate B2 bucket or prefix with a different lifecycle policy.
Do not let the Loki lifecycle rule delete backup objects.

Define recovery objectives before cutover:

- Metrics RPO: 24 hours with daily `vmbackup`; lower with more frequent backups.
- Logs RPO: near zero because Loki writes to B2 continuously, subject to B2
  durability.
- RTO: 1-2 hours to rebuild the VM, restore the block volume, and start Compose.
- Test a restore quarterly. A backup that has never been restored is not a backup.

## Security

- Public IP: restrict SSH to a stable CIDR or use Cloudflare Tunnel SSH. Disable
  password authentication. Consider `fail2ban`.
- Do not publish Grafana, VictoriaMetrics, or Loki ports. Use Cloudflare Tunnel
  and Caddy.
- Grafana behind Cloudflare Access; ingest endpoints behind Caddy Basic Auth with
  path restrictions. Cloudflare Access authenticates at the edge, but Grafana
  still presents its own login unless `auth.proxy` is configured to trust
  `Cf-Access-Authenticated-User-Email`. Either keep the double login or set
  `GF_AUTH_PROXY_ENABLED=true`, `GF_AUTH_PROXY_HEADER_NAME`, and
  `GF_AUTH_PROXY_AUTO_SIGN_UP=true`.
- B2 application key scoped to the bucket with only `listFiles`, `readFiles`,
  `writeFiles`, and `deleteFiles`.
- Docker images pinned by tag; optionally scan with Trivy in CI.
- Run containers as non-root where the image supports it; avoid `privileged`.
- Keep `.env` mode `0600` and never commit it.
- Rotate ingest credentials and the Discord webhook periodically.
- Filter logs that contain secrets or personal data before they leave the
  cluster. Fluent Bit can drop or redact fields.

## Migration Plan

No historical data is transferred. The new stack starts empty, and the
on-premises data ages out under the existing retention policy.

### Phase 0: Preflight

- Record current image tags for VictoriaMetrics, Loki, Grafana, Caddy, and
  `cloudflared`.
- Measure metrics series count, Loki bytes received per day, and PVC usage.
- Confirm OCI A1 capacity, public IP, block volume, and NSG.
- Create the B2 bucket, application key, and lifecycle rule.
- Lower the Cloudflare DNS TTL for the Grafana hostname to 60 seconds.
- Take a fresh OCI block volume backup and an on-premises backup.
- Schedule a maintenance window for the Grafana DNS cutover.

### Phase 1: OCI base

1. Create the VCN, public subnet, NSG, VM, boot volume, and block volume.
2. Attach and mount the block volume at `/srv/monitoring` with `nofail`.
3. Install Docker Engine and the Compose plugin.
4. Create `/opt/monitoring` and the directory layout.
5. Create the Cloudflare Tunnel and validation hostnames.
6. Configure the systemd unit.

Validation:

```bash
docker compose version
df -h / /srv/monitoring
systemctl status monitoring
```

### Phase 2: Empty stack

1. Copy the Compose and configuration files.
2. Create `.env` with placeholders, mode `0600`.
3. Start the stack:

   ```bash
   cd /opt/monitoring
   docker compose up -d --wait
   ```

4. Check health:

   ```bash
   docker compose ps
   curl -fsS http://127.0.0.1:3000/api/health
   ```

5. Open `https://grafana-oci.<domain>` through Cloudflare Access.
6. Verify datasources, dashboards, and alert rules loaded.

### Phase 3: Metrics path

1. Create the `vmagent-remote-write` Secret in the on-premises cluster.
2. Add `remoteWrite` to `vmagent`.
3. Apply through Argo CD.
4. Verify samples arrive:

   ```bash
   docker compose exec -T victoriametrics \
     wget -qO- 'http://localhost:8428/api/v1/query?query=up'
   ```

   Alternatively, verify in Grafana Explore with the VictoriaMetrics datasource.

5. Compare series count and sample rate with the on-premises `vmsingle`.
6. Keep the local `vmsingle` as the rollback target.

### Phase 4: Logs path

1. Add the cloud Loki output to the k8s Fluent Bit DaemonSet.
2. Add the same output to the Ansible-managed VM Fluent Bit role.
3. Deploy and verify:

   ```bash
   docker compose exec -T loki wget -qO- http://localhost:3100/ready
   ```

   Alternatively, verify in Grafana Explore with the Loki datasource.

4. Query logs in Grafana and compare labels with the on-premises Loki.
5. Watch buffer usage, ingestion rate, and B2 object growth.

### Phase 5: Grafana cutover

1. Confirm dashboards and alert rules are correct on OCI.
2. During dual-write, keep OCI rules `isPaused: true` and on-premises alerting
   active. At cutover, set OCI rules to `isPaused: false` and disable the
   on-premises Discord contact point. Do not run both notification paths at once.
3. Disable the on-premises Grafana Ingress so the Cloudflare controller stops
   managing the DNS record.
4. Change `grafana-k8s.<domain>` to the OCI tunnel.
5. Keep the on-premises Grafana read-only for rollback.
6. Send a test alert and confirm Discord delivery.

### Phase 6: Decommission

After 2-4 weeks of stable operation:

1. Remove the on-premises Loki output from Fluent Bit.
2. Move `vmagent` to a standalone `victoria-metrics-agent` chart, or keep the
   `victoria-metrics` Application and set `vmsingle.enabled: false`. Do not
   remove the Application until remote write collection is preserved.
3. Remove `grafana` and `loki` from
   `argocd/k3s/apps/infrastructure/kustomization.yaml`.
4. After remote write is stable, remove the `victoria-metrics` Application and
   its `vmsingle` PVC, or reduce it to a 14-30 day local buffer.
5. Delete the Loki LoadBalancer, NodePort, and router `loki_proxy` after
   confirming no other consumer uses them.
6. Delete PVCs and PVs after backup. StorageClasses use `Retain`, so deleting a
   PVC does not delete the PV.
7. Update `docs/repository-guide.md` and this document.

### Cutover and rollback

Rollback path:

1. Revert the DNS record to the on-premises tunnel or Ingress.
2. Remove the OCI `remoteWrite` and Loki outputs.
3. Re-enable the on-premises Discord contact point.
4. Keep the OCI VM for investigation; do not delete it during the rollback window.

Because the on-premises stack keeps writing locally during dual-write, rollback
does not lose data. The only gap is the Loki copy window, and this plan has no
initial copy, so there is no gap at all.

## Operations

- Systemd starts the stack at boot; containers restart with `unless-stopped`.
- Healthchecks gate `docker compose up --wait` and CI smoke tests.
- Renovate opens image update PRs; CI validates; merge deploys.
- Run `docker compose pull && docker compose up -d --wait` monthly, or on demand.
- Monitor disk usage on `/`, `/srv/monitoring`, and B2.
- Monitor B2 egress and 503 rates.
- Rotate Docker container logs; set `max-size` and `max-file` in the Docker
  daemon configuration.
- Use chrony and verify time sync; Loki and VictoriaMetrics are timestamp-sensitive.
- Keep an external uptime check on `https://grafana-k8s.<domain>` and on the
  ingest endpoints. If the OCI VM is down, Grafana cannot alert about itself.
- Add a dead-man's switch: an external service pings a health endpoint and
  notifies Discord if the ping stops.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| B2 lifecycle disabled | Storage grows without bound; B2 performance degrades | Enable the minimal lifecycle rule or run an external cleanup job |
| Public IP exposure | SSH or service compromise | NSG allowlist, key-only SSH, no published service ports, Cloudflare Tunnel |
| Single OCI VM failure | Monitoring unavailable until restore | Daily backups, restore drill, external uptime check, accepted SPOF |
| Loki/B2 query latency | Slow dashboards and investigations | Test before cutover, reduce retention, larger chunks, query limits |
| Loki version incompatibility | Failed startup or unreadable data | Pin the image, run `-verify-config`, test S3 writes |
| Grafana provisioning drift | Alert rules not applied | CI smoke test, reload API, no UI edits |
| Duplicate Discord alerts | Alert fatigue | Pause one side, disable one contact point |
| On-premises outage silences alerts | No alert when the homelab is down | Absent-data rules, heartbeat, external dead-man switch, secondary notification |
| DNS ownership conflict | Cutover fails or flaps | Disable on-premises Ingress before changing DNS, keep old record |
| Egress overage | Unexpected B2 or OCI bill | Monitor egress, set query limits, use 3x free allowance |
| CI/CD compromise | Unauthorized deployment | Environment approval, pinned actions, restricted SSH, no secrets in CI |
| Boot volume fills | Docker or OS failure | Log rotation, monitor `/`, keep images pruned |
| Data loss | Loss of metrics/logs | Backups, B2 versioning, restore drills |

## Plan Review

### Should you move at all?

The migration is justified if the goal is to keep alerting alive when the
homelab fails. Monitoring that runs on the monitored cluster cannot reliably
report the cluster's own outage: if the cluster, network, or storage dies, the
alerting plane dies with it. Moving Grafana and the notification path to OCI
puts them in an independent failure domain. That is a strong reason to do this,
not just a cost optimization.

If the only goal is off-site data durability, a backup-only design is simpler:
keep the current stack and back up VictoriaMetrics, Loki, and Grafana to B2.
That avoids a second Grafana, DNS cutover, dual-write, and CI/CD pipeline.
Choose the hybrid only if independent alerting or offloading is worth the extra
operations.

The hybrid plan adds operational complexity:

- Two monitoring stacks during the validation window.
- A public IP and a second Cloudflare Tunnel.
- A separate Docker Compose deployment and CI/CD path.
- B2 lifecycle and query-latency tuning.

Proceed only if those costs are acceptable. For a homelab, the learning value
and independent alerting can justify it; for a pure data-durability play, a
backup-only design is smaller.

### What is sound

- Keeping collectors on-premises avoids a VPN and preserves Technitium SD and
  node exporter reachability.
- Remote write and Loki push are outbound-only, so the public IP does not need
  inbound service ports.
- B2 is inexpensive for 6 months of logs, and the estimated $0.42/month is well
  within the accepted range.
- The existing Grafana alert rules can be reused almost verbatim.
- The migration is reversible because the on-premises stack keeps running during
  dual-write.
- Grafana and the notification path move to an independent failure domain, which
  is the main operational win.

### What must change before implementation

1. **B2 lifecycle.** If lifecycle is disabled, the plan is not bounded. Enable the
   minimal rule that deletes only hidden versions, or add an external cleanup job.
   This is the single most important correction.
2. **Public IP lockdown.** A public IP is acceptable only with a restrictive NSG,
   key-only SSH, and no published service ports. Do not expose Caddy, Grafana,
   VictoriaMetrics, or Loki directly.
3. **Backup and restore.** Single-VM operation is accepted, but the RTO must be
   explicit and tested. Daily block volume backups plus a quarterly restore drill
   are the minimum.
4. **Secure CI/CD path.** GitHub-hosted runner IPs are not stable. Use Cloudflare
   Tunnel SSH, Tailscale, or a self-hosted runner; do not open SSH to the world.
5. **Loki/B2 validation.** Test query latency, `zstd` CPU cost, and S3 writes with
   the pinned image before cutover. Fall back to `gzip` if CPU is a problem.
6. **Alert duplication.** Pause alerting on one Grafana instance during
   dual-write. Test a synthetic alert end to end.
7. **DNS sequencing.** The on-premises Cloudflare controller owns the current
   Grafana record. Disable that Ingress before changing DNS, and keep the old
   record for rollback.
8. **Absent-data and heartbeat alerting.** Threshold rules alone will not fire
   when the on-premises collector dies. Add the rules and heartbeat described in
   [Alerting during a homelab outage](#alerting-during-a-homelab-outage).

### Residual risks

- A single VM remains a single point of failure. The external uptime check and
  backups reduce the impact but do not eliminate it.
- B2 has no APAC region; if the OCI VM is in Tokyo, query latency will be higher
  than a local disk. Test before committing to 6-month log retention.
- B2 is a cost optimization, not a performance tier. If dashboards frequently
  query 6 months of logs, OCI Object Storage in the same region or a larger
  local block volume may be a better trade-off despite the higher price.
- Docker Compose is not GitOps. Drift is possible if someone edits files on the
  VM. The deploy script resets to `origin/main`, and manual edits are prohibited.
- The Always Free 200 GiB block allowance is exactly consumed. Any growth requires
  a paid volume or a retention reduction.

### Verdict

The plan is **conditionally sound**. It becomes acceptable when the B2 lifecycle
is bounded, the public IP is locked down, backups and restore are tested, and the
CI/CD path is secured. Without those four corrections, the plan has an unbounded
storage cost and an unnecessary Internet exposure.

## Open Questions

- B2 region and endpoint; choose the region closest to the OCI VM.
- OCI region and whether a reserved public IP is available.
- Production Grafana hostname and Cloudflare Access identity provider.
- Whether to keep a 14-30 day local `vmsingle` buffer after cutover.
- Whether 6-month log retention is worth the B2 query latency, or 90 days is
  sufficient.
- Backup retention and the exact RTO target.

## Validation Checklist

### Before deployment

- [ ] Current image tags recorded.
- [ ] Metrics series count and Loki bytes/day measured.
- [ ] B2 bucket, scoped application key, and lifecycle rule verified.
- [ ] OCI VM, public IP, NSG, boot volume, and block volume verified.
- [ ] Cloudflare Tunnel and validation hostnames created.
- [ ] DNS TTL lowered to 60 seconds.
- [ ] Backups taken and restore path documented.

### Deployment

- [ ] `docker compose config -q` passes.
- [ ] Caddy validate passes.
- [ ] Loki `-verify-config` passes.
- [ ] Grafana provisioning smoke test passes.
- [ ] `docker compose up -d --wait` healthy.
- [ ] Grafana datasources and dashboards load.
- [ ] Alert rules and contact points load.
- [ ] Remote write samples arrive.
- [ ] Loki push logs arrive.
- [ ] B2 objects are written and lifecycle rule is active.

### Cutover

- [ ] Test alert reaches Discord.
- [ ] On-premises alerting disabled or OCI rules paused.
- [ ] DNS switched to OCI.
- [ ] On-premises Grafana kept read-only for rollback.
- [ ] Dashboards and queries validated for 24 hours.

### Decommission

- [ ] No on-premises Loki output remains.
- [ ] No on-premises `vmsingle` dependency remains, or buffer retention is set.
- [ ] Argo CD applications removed from `kustomization.yaml`.
- [ ] PVCs and PVs backed up and deleted.
- [ ] Loki LoadBalancer, NodePort, and router proxy removed.
- [ ] Docs updated.

