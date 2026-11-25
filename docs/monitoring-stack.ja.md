# 監視スタックの OCI 移行計画

最終確認: 2026-11-25

ステータス: 提案中の計画です。クラスタ、OCI、DNS、デプロイ状態は変更していません。ドキュメント変更のみです。

English version: [monitoring-stack.md](monitoring-stack.md)

## スコープ

ホームラボの監視スタックのうち、保存・可視化層をオンプレミスの k3s クラスタから、Docker Compose を実行する単一の Oracle Cloud Infrastructure (OCI) 仮想マシンへ移行します。

- メトリクス: VictoriaMetrics（シングルノード）
- ログ: Loki（モノリシック）。チャンクとインデックスは Backblaze B2
- ダッシュボードとアラート: Grafana
- エッジ: Caddy と `cloudflared`

収集層はオンプレミスに残します。

- `vmagent` はクラスタと VM の node exporter をスクレイプし続けます。
- Fluent Bit はコンテナログと journald ログを収集し続けます。
- `technitium-sd` は HTTP サービスディスカバリを提供し続けます。

この分離は意図的なものです。収集系はプライベートネットワーク `10.2.0.0/24`、Technitium DNS、NFS/LINSTOR の PVC に依存しています。収集系まで OCI に移すと、サイト間 VPN の新設が必要になり、収集が不安定になります。リモートライトと Loki push はアウトバウンドのみで済むため、既存の Cloudflare Tunnel モデルと整合します。

### 目標外

- 高可用性 (HA)。OCI VM は単一障害点です。これは受け入れます。
- 過去のメトリクス・ログの移行。新しいスタックは空の状態で始め、オンプレミスの履歴は既存の保持期間で失効させます。
- OCI 上での Kubernetes 実行。対象は Docker Compose です。
- Grafana アラートの `vmalert` / Alertmanager への置き換え。トレードオフは[アラートルール戦略](#アラートルール戦略)を参照してください。

## 現状

監視スタックは Argo CD の `infrastructure` ルート Application から `monitoring` ネームスペースへデプロイされています。

| コンポーネント | 現在の構成 | 根拠 |
| --- | --- | --- |
| メトリクス保存 | VictoriaMetrics `vmsingle`、180日保持、40Gi NFS PVC | `argocd/k3s/apps/infrastructure/victoria-metrics/application.yaml` |
| メトリクス収集 | `vmagent`、60秒スクレイプ、VM は Technitium HTTP SD | 同上、`technitium-sd/` |
| 可視化 | Grafana chart 10.5.15、1Gi `ssd` PVC、Cloudflare Tunnel | `argocd/k3s/apps/infrastructure/grafana/application.yaml` |
| データソース | クラスタ内の `vmsingle` / `loki` Service | 同上 |
| アラート | Grafana アラート、Discord コンタクトポイント、ConfigMap から provisioning | 同上、`grafana/alert-rules/` |
| ログ保存 | Loki モノリシック、filesystem、6ヶ月保持、64Gi NFS PVC | `argocd/k3s/apps/infrastructure/loki/application.yaml` |
| ログ収集 | Fluent Bit DaemonSet と Ansible 管理の VM エージェント | `fluent-bit/application.yaml`、`ansible/roles/fluent_bit/` |
| 公開経路 | Cloudflare Tunnel。VPN、Gateway API、NetworkPolicy はなし | `cloudflare-tunnel-ingress-controller/application.yaml` |
| シークレット | SealedSecrets。鍵ローテーションは無効 | `sealed-secrets/application.yaml` |

スタンドアロンの Prometheus、Alertmanager、Tempo、Mimir、Thanos、Promtail はありません。可観測性データの流れは次のとおりです。

```text
VM メトリクス: node_exporter -> Technitium DNS SD -> vmagent -> VictoriaMetrics
VM ログ:       Fluent Bit -> router nginx -> Loki
Pod ログ:      Fluent Bit DaemonSet -> Loki
```

## 目標アーキテクチャ

```text
オンプレミス k3s
  vmagent ---- remote_write (HTTPS + Basic Auth) ----+
  Fluent Bit -- Loki push (HTTPS + Basic Auth) ------+
  node_exporter / technitium-sd（変更なし）           |
                                                      |
                                                      v
OCI VM（Docker Compose）
  cloudflared -> Caddy -> Grafana:3000
                      -> VictoriaMetrics:8428  (/api/v1/write のみ)
                      -> Loki:3100             (/loki/api/v1/push のみ)

  ブロックボリューム: /srv/monitoring/vmdata, /srv/monitoring/lokidata
  Backblaze B2: Loki チャンクと TSDB インデックス
```

設計上の特性:

- Cloudflare Tunnel を使う場合、Grafana と取り込みにインバウンドポートは不要です。パブリック IP は SSH（制限付き）とアウトバウンド通信に使います。
- Caddy が唯一のオリジンです。Cloudflare Tunnel を使う場合、Caddy は TLS を終端せず、Cloudflare がエッジで TLS を終端します。
- Grafana は Cloudflare Access で保護します。取り込みエンドポイントは Caddy の Basic Auth とパス制限で保護します。Fluent Bit と `vmagent` は単純な HTTP 認証しか使えないためです。
- VictoriaMetrics と Loki は Compose のプライベートネットワークからのみ到達可能です。
- アラートプレーン（Grafana と外部通知経路）はホームラボの外で動くため、ホームラボ障害時にアラートが止まりません。これにはデータ欠損アラートとハートビートが必要です。[ホームラボ障害時のアラート](#ホームラボ障害時のアラート)を参照してください。

## OCI リソース設計

| リソース | 計画 |
| --- | --- |
| シェイプ | `VM.Standard.A1.Flex`、4 OCPU、24 GB RAM |
| OS | Ubuntu 24.04 LTS |
| パブリック IP | 可能なら予約済み。それ以外は一時 IP を記録し、DNS を慎重に扱う |
| ブートボリューム | 50 GiB |
| ブロックボリューム | 150 GiB、`/srv/monitoring` にマウント |
| VCN | パブリックサブネット。オンプレミスネットワークとのピアリングはなし |
| NSG ingress | TCP 22 は管理者 CIDR のみ。Cloudflare Tunnel 使用時は 80/443 を開けない |
| NSG egress | 全宛先 |
| バックアップ | OCI ブロックボリュームの日次バックアップ、7〜14日保持 |
| 時刻同期 | chrony。Loki と VictoriaMetrics の起動前に確認 |

予約済みパブリック IP は OCI テナンシによっては課金される場合があります。予約前に現在の価格を確認してください。

OCI から B2 と Cloudflare へのアウトバウンド転送は OCI の egress に計上されます。Always Free の上限は 10 TB/月です。現在の上限を確認してから依存してください。

Always Free の 200 GiB ブロックストレージ枠は次のように消費します。

```text
ブート       50 GiB
メトリクス   100 GiB  /srv/monitoring/vmdata
Loki ローカル 50 GiB  /srv/monitoring/lokidata
合計        200 GiB
```

メトリクスが 100 GiB を超える場合は、Loki のローカルディレクトリをブートボリュームへ移してメトリクスに 150 GiB を割り当てるか、50 GiB のブロックボリュームを有償で追加します。ブートボリュームを Docker イメージやコンテナログで埋めないでください。Docker のログローテーションを設定し、`/` を別途監視します。

単一の 150 GiB ファイルシステムでは、Loki のローカルディレクトリがメトリクス用の領域を圧迫する可能性があります。100 GiB のメトリクスと 50 GiB の Loki ローカルを厳密に分けたい場合は、ボリュームをパーティション分割するか、別ボリュームを使用してください。そうしない場合は、両ディレクトリを監視し、どちらかが共有ボリュームを埋める前にアラートを出します。

### パブリック IP と SSH

VM はパブリック IP を持ちます。インターネットに面したホストとして扱ってください。

- SSH は鍵認証のみ。パスワード認証を無効化します。
- NSG の TCP 22 は安定した管理者 CIDR のみに制限します。管理者 IP が動的な場合は、22 を全開にせず Cloudflare Tunnel SSH、Tailscale、OCI Bastion を使います。
- Caddy、Grafana、VictoriaMetrics、Loki のポートをホストに公開しません。
- Cloudflare Tunnel の代わりに直接 HTTPS を選ぶ場合は、443 を Cloudflare の IP レンジのみに許可し、Caddy に DNS-01 または HTTP-01 証明書を使います。Tunnel より構成要素が増えるため、既定の推奨ではありません。
- OCI テナンシが対応しているなら予約済みパブリック IP を使います。停止/起動で DNS や SSH の許可リストが壊れないようにするためです。

## Docker Compose 構成

```text
/opt/monitoring/
├── compose.yaml
├── .env                      # chmod 600、コミットしない
├── .env.example              # プレースホルダー入りテンプレート（コミットする）
├── secrets/
│   └── grafana_admin_password  # chmod 600、コミットしない
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

サービス:

| サービス | イメージ | 目的 | 永続化 |
| --- | --- | --- | --- |
| `cloudflared` | `cloudflare/cloudflared:<pin>` | アウトバウンドトンネルコネクタ | なし |
| `caddy` | `caddy:2.9` | リバースプロキシ、Basic Auth、パス制限 | `caddy_data` |
| `grafana` | `grafana/grafana:<pin>` | UI とアラート | `/srv/monitoring/grafanadata` |
| `victoriametrics` | `victoriametrics/victoria-metrics:<pin>` | メトリクス保存 | `/srv/monitoring/vmdata` |
| `loki` | `grafana/loki:<pin>` | ログ保存 | `/srv/monitoring/lokidata` |
| `node-exporter` | `prom/node-exporter:<pin>` | OCI VM 自身の監視 | なし |

イメージタグは固定します。`latest` は使いません。対象バージョンを選ぶ前に、クラスタから現在デプロイされているイメージタグを記録します。

```bash
kubectl -n monitoring get deploy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
```

Compose の骨子:

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

公開ポートはありません。Grafana は `127.0.0.1:3000` のみにバインドし、ローカルヘルスチェックとデプロイスクリプトから到達できるようにします。外部トラフィックは引き続き `cloudflared` と Caddy を経由します。`cloudflared` は Compose ネットワーク経由で `caddy:8080` に接続します。Grafana はサービス名で VictoriaMetrics と Loki に接続します。

検証中は `GRAFANA_ROOT_URL` を `https://grafana-oci.<domain>` に設定し、切り替え時に本番ホスト名へ変更します。同時に Caddyfile に本番ホストのルートを追加します。

スタックを起動時に立ち上げる systemd ユニットを作成します。

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

## Caddy と Cloudflare Tunnel

OCI スタック専用の Cloudflare Tunnel を作成します。オンプレミスのトンネルトークンを再利用しないでください。別トンネルにすることで、ロールバックと DNS の所有権が明確になります。

推奨ホスト名:

| ホスト名 | オリジン | 保護 |
| --- | --- | --- |
| `grafana-oci.<domain>` | `http://caddy:8080` | Cloudflare Access |
| `vm-ingest.<domain>` | `http://caddy:8080` | Caddy Basic Auth、パス制限 |
| `loki-ingest.<domain>` | `http://caddy:8080` | Caddy Basic Auth、パス制限 |

`grafana-oci` は検証用ホスト名です。本番の `grafana-k8s` レコードを切り替えるのはカットオーバー時のみです。

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

bcrypt ハッシュの生成:

```bash
docker run --rm caddy:2.9 caddy hash-password --plaintext '<secret>'
```

ハッシュは Caddyfile に保存するか、`{$INGEST_PASSWORD_HASH}` で注入します。平文パスワードはコミットしません。Cloudflare Zero Trust のダッシュボードで、`grafana-oci`、`vm-ingest`、`loki-ingest` の公開ホスト名を `http://caddy:8080` に向けてください。

上の Caddyfile は次の制限を実装しています。

- `vm-ingest` は `/api/v1/write` のみ許可。クエリエンドポイントは内部に留めます。
- `loki-ingest` は `/loki/api/v1/push` のみ許可。`/ready` と `/metrics` は内部に留め、Compose のヘルスチェックを使います。
- それ以外は 404 を返し、管理 API へ到達させません。
- `/healthz` は Compose ヘルスチェック用のローカルエンドポイントです。

カットオーバー時には、同じ Grafana アップストリームへ向ける `grafana-k8s.<domain>` のホストルートを追加します。ロールバックが不要になるまで `grafana-oci` ルートは残します。

## VictoriaMetrics

現状の chart と同じ保持セマンティクスで、シングルノードの VictoriaMetrics を実行します。chart のコメントでは Helm キー `retentionPeriod: 180d` が `-retentionPeriod=6` に対応するとあります。デプロイ前に固定イメージで正確なフラグを確認してください。

```text
-storageDataPath=/victoria-metrics-data
-retentionPeriod=6
-httpListenAddr=:8428
-dedup.minScrapeInterval=60s
```

`dedup.minScrapeInterval=60s` は 60秒スクレイプ間隔に一致し、リモートライトの再送で重複したサンプルを除去します。

### オンプレミス側のリモートライト

`argocd/k3s/apps/infrastructure/victoria-metrics/application.yaml` の `vmagent` に `remoteWrite` を追加します。

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

検証期間中はオンプレミスの `vmsingle` を動かし続けます。ロールバック先であり、短期的なローカルバッファでもあります。OCI の短い障害で収集が止まらないよう、`vmagent` のリモートライトにディスクバッファを設定します。

```text
-remoteWrite.tmpDataPath=/tmp/vmagent-remotewrite
```

このパスに `emptyDir` または PVC をマウントします。コンテナ内の `/tmp` は一時的です。バッファは想定する OCI 障害の継続時間に合わせてサイズ設定します。

## Loki と Backblaze B2

Loki 3.x は `zstd` チャンクエンコーディング、TSDB インデックス、S3 互換オブジェクトストレージに対応しています。有効化する前に、固定イメージが両方に対応していることを確認してください。

### ストレージレイアウト

| パス | 目的 | サイズ |
| --- | --- | --- |
| `/var/loki/chunks` | チャンクキャッシュと WAL 隣接データ | 50 GiB の一部 |
| `/var/loki/wal` | 取り込み WAL | 10〜20 GiB |
| `/var/loki/compactor` | コンパクターの作業ディレクトリ | 10〜20 GiB |
| `/var/loki/index` | TSDB shipper のアクティブインデックス/キャッシュ | 5〜10 GiB |

チャンクとインデックスは B2 に置きます。ローカルの 50 GiB は WAL、コンパクター作業、キャッシュ用であり、主要なログストアではありません。

### Loki 設定

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

注意:

- `schema_config` で `object_store: s3` を設定する必要があります。設定しないと Loki はチャンクをファイルシステムに書き続けます。
- オブジェクトストアが S3 の場合、コンパクターの削除リクエストに `delete_request_store: s3` が必要です。
- `s3forcepathstyle: true` はカスタムエンドポイントでは安全側の出発点です。Backblaze は path-style と virtual-hosted-style の両方に対応しています。
- `-config.expand-env=true` により `.env` の `${B2_...}` を展開できます。
- `max_chunk_age: 336h` は現在のバックログ drain 挙動を維持します。バックログ問題が解決したら、メモリを抑えるために 2〜6時間へ減らします。
- `zstd` は圧縮率を上げ、egress を減らしますが、CPU を消費します。バックログ drain 中に CPU がボトルネックになるなら `gzip` に戻します。
- `reject_old_samples_max_age: 168h` は、長期障害後に7日より古いバッファ済みログを捨てます。より長いバッファが必要なら値を増やします。

デプロイ前の検証:

```bash
docker run --rm \
  -v "$PWD/oci/monitoring/loki:/etc/loki:ro" \
  grafana/loki:<pin> \
  -config.file=/etc/loki/loki-config.yaml -verify-config
```

### Fluent Bit の変更

クラウドエンドポイント向けの2つ目の Loki 出力を追加します。二重書き込み中はローカル出力も残します。

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

VM 側の Ansible ロール (`ansible/roles/fluent_bit/`) にも同じ2つ目の出力が必要です。OCI の短い障害でログを落とさないよう、ファイルシステムバッファを使います。バッファは想定する障害継続時間に合わせてサイズ設定します。2G は出発点であり、保証ではありません。

## Grafana プロビジョニング

Grafana はファイルベースの provisioning で動かします。ダッシュボード、データソース、コンタクトポイント、アラートルールを UI で編集しないでください。

### データソース

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

UID は `victoriametrics` と `loki` のままにしてください。既存のアラートルールが `datasourceUid: victoriametrics` を参照しています。

### ダッシュボード

既存の ConfigMap からダッシュボード JSON を抽出し、`grafana/dashboards/` に置きます。ファイルプロバイダーを設定します。

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

### アラートルール

既存のアラートルールは、ConfigMap の中に Grafana provisioning YAML として既に入っています。各ファイルの内部ドキュメントを抽出します。

```bash
mkdir -p oci/monitoring/grafana/provisioning/alerting
for f in argocd/k3s/apps/infrastructure/grafana/alert-rules/*.yaml; do
  name=$(basename "$f")
  yq ".data[\"${name%.yaml}.yaml\"]" "$f" \
    > "oci/monitoring/grafana/provisioning/alerting/rules-${name}"
done
```

アラートファイルは `provisioning/alerting/` 直下にフラットに置きます。Grafana の再帰読み込み挙動はバージョン依存です。

コンタクトポイント:

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

通知ポリシー:

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

provisioning のシークレットには `$VAR` ではなく `$__env{...}` を使います。こちらがドキュメント化された補間形式です。

`Homelab` フォルダが存在することを確認してください。最近の Grafana は provisioning されたフォルダを自動作成しますが、CI スモークテストで確認してから依存してください。

### アラートルール戦略

Grafana アラートを既定にする理由:

- 既存ルールが既に Grafana provisioning 形式です。
- コンタクトポイントと通知ポリシーが同じ Git ツリーにあります。
- Alertmanager や `vmalert` のコンテナが追加で不要です。

トレードオフはテスト容易性です。Grafana アラートルールは素の Prometheus ルールではないため、`promtool` や `vmalert-tool` で直接ユニットテストできません。CI では代わりに、使い捨ての Grafana を起動し、provisioning ディレクトリをマウントして、ルールとコンタクトポイントが読み込まれることを確認します。

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

ルール単位のユニットテストが重要になったら、評価を `vmalert` の Prometheus 形式ルールへ移行し、Grafana は可視化に専念させます。これは大きな変更であり、初回移行には必須ではありません。

### ホームラボ障害時のアラート

Grafana を OCI に置く主な理由は、ホームラボ障害時にアラートを生かし続けるためです。`up == 0` のような閾値ルールだけでは不十分です。オンプレミスのネットワークや `vmagent` が死ぬと、系列は 0 にならず消えます。次を追加してください。

- 重要ジョブに対する `noDataState: Alerting` のデータ欠損ルール:
  - `absent(up{job="node-exporter-vms"})`
  - `absent(up{job="kube-state-metrics"})`
  - kubelet をスクレイプしているなら `absent(up{job="kubelet"})`
- オンプレミスのルーターまたは小さな VM から OCI への、k3s に依存しないハートビート:
  - systemd タイマーが毎分、合成メトリクスまたはログを push します。
  - ハートビートが5〜10分欠けたらアラートを出します。
- 重要ルールに `noDataState: Alerting` と `execErrState: Alerting` を設定します。
- Grafana と取り込みエンドポイントの外部 uptime check、および OCI スタック自体が止まったら Discord に通知する dead-man's switch。
- Discord や Cloudflare が利用できない場合に備えた、メールや SMS の二次通知経路。

これらがないと、Grafana を OCI に移しても、障害中にダッシュボードは上がっていても「ホームラーブが down している」と伝えられない可能性があります。

## CI/CD

### 方式の比較

| 方式 | 長所 | 短所 | 評価 |
| --- | --- | --- | --- |
| GitHub Actions + SSH デプロイ | 明示的、ロールバックしやすい、GitHub と相性が良い | 安全な SSH 経路が必要 | 推奨 |
| Pull 型 systemd タイマー | インバウンド SSH 不要、単純 | 反映が遅い、VM に Git 資格情報が必要 | 代替案として許容 |
| CI から Ansible 実行 | 既存 `ansible/` を再利用、冪等 | playbook の保守が必要 | 代替案として許容 |
| Watchtower | イメージ自動更新 | 設定を管理できない、勝手に再起動 | 推奨しない |
| Portainer/Coolify/Dockge | UI で操作できる | 新たな攻撃面、Git から逸脱 | 推奨しない |

### CI 検証

`oci/monitoring/**` が変更された PR と `main` への push で実行します。

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

ダッシュボード JSON は `jq empty` で、アラートルールファイルは `yq` で検証します。CI の環境ファイルには Compose が参照する全変数のダミー値を入れ、マージ前に補間エラーを検出できるようにします。

### CD デプロイ

必須レビュワー付きの GitHub Environment を使います。すべての push でデプロイせず、`production` は承認必須にします。

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

`ci/deploy.sh` は GitHub ランナー上で動き、SSH または Cloudflare Tunnel のセッションを開いて、VM 上の `/opt/monitoring/deploy.sh` を呼び出します。Docker に触るのは VM 側スクリプトだけです。

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

注意:

- `docker compose up -d --wait` は全サービスに healthcheck が必要です。
- `--force-recreate` はバインドマウントされた設定変更を適用しますが、短い再起動を伴います。Fluent Bit のバッファが Loki の再起動を吸収し、`vmagent` のバッファが VictoriaMetrics の再起動を吸収します。再起動なしの reload を選ぶなら、Grafana は `POST /api/admin/provisioning/alerting/reload`、Loki と Caddy は設定変更時のみ再起動します。
- デプロイ前に現在の SHA と `docker compose config` の出力を `/opt/monitoring/releases/` に保存します。
- 失敗時は前の SHA へ戻して `docker compose up -d --wait` を実行します。

### 安全なデプロイ経路

GitHub ホスト型ランナーの IP は固定ではありません。TCP 22 を `0.0.0.0/0` に開けないでください。次から選びます。

1. Cloudflare Tunnel SSH と Access サービストークン
2. Tailscale または WireGuard。ランナーを tailnet に参加させる
3. オンプレミスの self-hosted ランナーと制限付き SSH 許可リスト

`deploy` ユーザーを専用に作り、鍵認証のみ、`command=` または sudoers で `deploy.sh` に限定します。

### シークレット

- B2 キー、Discord webhook、Grafana 管理者パスワード、取り込み Basic Auth 資格情報は VM 上の `/opt/monitoring/.env` に置き、モード `0600` にします。
- このファイルは SOPS + age または Ansible Vault で管理します。平文をコミットしません。
- GitHub Secrets には SSH 鍵と Cloudflare Access トークンのみを入れます。
- B2 アプリケーションキーと取り込み資格情報は定期的にローテーションします。

### イメージ更新

Renovate の `docker-compose` マネージャーでイメージタグ更新の PR を作ります。CI が PR を検証し、マージがデプロイをトリガーします。本番ではタグを固定し、可能なら digest も固定します。`latest` は使いません。

## ストレージとコスト見積もり

### メトリクス

現在の実測アンカーは 180日で 40 GiB です。chart の履歴は 90日/20 GiB から 180日/40 GiB へ移っており、使用量は保持期間に対してほぼ線形と考えられます。

| アクティブ系列数 | 180日あたりの推定（1〜1.5 B/サンプル） | オーバーヘッド20%込み | 推奨 |
| ---: | ---: | ---: | ---: |
| 50,000 | 13〜19 GiB | 16〜23 GiB | 50 GiB |
| 100,000 | 26〜39 GiB | 31〜47 GiB | 60 GiB |
| 150,000 | 39〜58 GiB | 47〜70 GiB | 100 GiB |
| 200,000 | 52〜78 GiB | 62〜94 GiB | 100 GiB |
| 300,000 | 78〜117 GiB | 94〜140 GiB | 150 GiB |

100 GiB は、1.5 B/サンプルとして約20万系列＋オーバーヘッドをカバーします。それ以上に増えるなら 150 GiB へ移すか保持期間を短縮します。

### ログ

現在の実測アンカーは、Loki の PVC が 32 GiB から 64 GiB に増やされた後の6ヶ月で 64 GiB です。圧縮率は 4〜10倍と仮定し、計画には 8倍を使います。

| 生ログ/日 | 180日・8倍圧縮 | インデックス10%込み | 推奨 |
| ---: | ---: | ---: | ---: |
| 0.5 GB | 11.3 GB | 12.4 GB | 20 GB |
| 1 GB | 22.5 GB | 24.8 GB | 30 GB |
| 2 GB | 45.0 GB | 49.5 GB | 60 GB |
| 2.8 GB | 63.0 GB | 69.3 GB | 100 GB |
| 5 GB | 112.5 GB | 123.8 GB | 150 GB |

### コスト

この計画で使う Backblaze B2 の価格: $6.95/TB/月、最初の10 GB 無料、平均月間保存量の3倍まで egress 無料、Class A/B/C API 呼び出し無料。

| 項目 | サイズ | 月額 |
| --- | ---: | ---: |
| OCI ブロック（ブート＋メトリクス＋Loki ローカル） | 200 GiB | Always Free 内で $0 |
| B2 ログ | 70 GB | 約 $0.42 |
| B2 egress | 保存量の3倍まで | 上限内なら $0 |
| **合計** | | **約 $0.42/月** |

ブロックストレージが 200 GiB を超えると超過分は約 $0.0425/GB/月です。ログが 150 GB に達すると B2 は約 $0.97/月 です。コミット前に OCI と B2 の現在価格を確認してください。価格は変わり得ます。

## Backblaze B2 のバージョニングと Lifecycle

これはこの計画で最も重要な運用詳細です。

B2 バケットは既定でバージョニングされており、バージョニングは無効化できません。Loki が `versionId` なしで `DeleteObject` を呼ぶと、B2 は delete marker を挿入します。チャンクは非表示バージョンとなり、ストレージ課金対象として残り続けます。Lifecycle ルールが無効のままだと、Loki が保持期間を効かせているように見えても、ストレージは際限なく増えます。

### 推奨 Lifecycle ルール

Loki 専用バケットを使い、非表示バージョンだけを削除するルールを1つだけ適用します。専用バケットなら `fileNamePrefix` は空文字列（`""`）で正しいです。共有バケットなら、実際のオブジェクトキーのプレフィックスを先に確認してください。Loki の `index_` はファイル名プレフィックスであり、S3 キーのプレフィックスとは限りません。

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

| 設定 | 意味 |
| --- | --- |
| `daysFromUploadingToHiding: null` | 現在のバージョンを自動で非表示にしない |
| `daysFromHidingToDeleting: 7` | Loki が削除した非表示バージョンを7日後に物理削除 |
| `daysFromStartingToCancelingUnfinishedLargeFiles: 7` | 未完了マルチパートアップロードをキャンセル |

実効保持は約187日になるため、180日より5〜10%多めに見積もります。Lifecycle は1日1回実行され、削除完了まで最大72時間かかることがあります。

Loki の削除漏れ対策として任意の安全網:

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

これは現在のバージョンを200日で非表示にし、7日後に削除します。値は Loki の保持期間より大きくしてください。保持期間を変えたら更新します。

### Lifecycle を無効のままにする場合

Lifecycle ルールが無効のままだと、この計画は上限を持ちません。6ヶ月で 64 GB（約10.7 GB/月）と仮定すると:

| 経過 | 保存量 | 月額 |
| --- | ---: | ---: |
| 6ヶ月 | 64 GB | $0.38 |
| 1年 | 128 GB | $0.82 |
| 3年 | 384 GB | $2.60 |
| 5年 | 640 GB | $4.38 |

金額は小さいですが、オブジェクト数とバージョン数は際限なく増えます。B2 は、数百万のバージョンが削除・リスト性能を劣化させ、503 を増やし、最終的にアップロードをブロックし得ると警告しています。Lifecycle を無効のままにするなら、7日より古い非現行バージョンを削除する外部ジョブを回してください。機能的には Lifecycle ルールの再実装です。

**推奨: 最小 Lifecycle ルールを有効にする。** 現在のログは消さず、Loki が既に削除したバージョンだけを掃除します。

## バックアップとリストア

| データ | バックアップ | 保持 | リストア |
| --- | --- | --- | --- |
| VictoriaMetrics | OCI ブロックボリューム日次バックアップ。別 B2 バケットへの `vmbackup` は任意 | 7〜14日 | `vmrestore` またはボリュームリストア |
| Loki チャンク/インデックス | B2 バージョニング＋Lifecycle。任意でバケットレプリケーション | Lifecycle | Loki をバケットへ再接続 |
| Grafana DB | 日次コピーを B2 または別バックアップバケットへ | 30日 | `grafana.db` をリストア |
| ダッシュボード/アラート | Git | Git 履歴 | 再 provisioning |

バックアップは別 B2 バケットまたは別プレフィックスに置き、別の Lifecycle ポリシーを適用します。Loki の Lifecycle ルールでバックアップオブジェクトを削除しないでください。

カットオーバー前に回復目標を定義します。

- メトリクス RPO: 日次 `vmbackup` で 24時間。頻度を上げれば短縮できます。
- ログ RPO: Loki は B2 へ継続的に書くためほぼゼロ。B2 の耐久性に依存します。
- RTO: VM 再構築、ブロックボリュームリストア、Compose 起動まで 1〜2時間。
- リストアは四半期に1回テストします。リストア経験のないバックアップはバックアップではありません。

## セキュリティ

- パブリック IP: SSH を安定した CIDR に制限するか Cloudflare Tunnel SSH を使います。パスワード認証を無効化します。`fail2ban` も検討します。
- Grafana、VictoriaMetrics、Loki のポートを公開しません。Cloudflare Tunnel と Caddy を使います。
- Grafana は Cloudflare Access の内側。取り込みエンドポイントは Caddy Basic Auth とパス制限の内側です。Cloudflare Access はエッジで認証しますが、Grafana 自体は `auth.proxy` で `Cf-Access-Authenticated-User-Email` を信頼するよう設定しない限り独自ログインを表示します。二重ログインでよいか、`GF_AUTH_PROXY_ENABLED=true`、`GF_AUTH_PROXY_HEADER_NAME`、`GF_AUTH_PROXY_AUTO_SIGN_UP=true` を設定してください。
- B2 アプリケーションキーはバケットスコープにし、`listFiles`、`readFiles`、`writeFiles`、`deleteFiles` のみ付与します。
- Docker イメージはタグ固定。任意で CI に Trivy を入れます。
- できるだけ非 root でコンテナを動かし、`privileged` は避けます。
- `.env` は `0600` のままコミットしません。
- 取り込み資格情報と Discord webhook を定期的にローテーションします。
- シークレットや個人情報を含むログはクラスタを出る前にフィルタします。Fluent Bit でフィールドを落としたりマスクできます。

## 移行計画

過去データは転送しません。新しいスタックは空で始め、オンプレミスのデータは既存の保持期間で失効します。

### Phase 0: 事前確認

- VictoriaMetrics、Loki、Grafana、Caddy、`cloudflared` の現在のイメージタグを記録します。
- メトリクス系列数、Loki の1日あたり受信バイト数、PVC 使用量を計測します。
- OCI A1 のキャパシティ、パブリック IP、ブロックボリューム、NSG を確認します。
- B2 バケット、アプリケーションキー、Lifecycle ルールを作成します。
- Grafana ホスト名の Cloudflare DNS TTL を 60秒に下げます。
- OCI ブロックボリュームの新規バックアップとオンプレミスのバックアップを取得します。
- Grafana DNS 切り替えのメンテナンスウィンドウを確保します。

### Phase 1: OCI 基盤

1. VCN、パブリックサブネット、NSG、VM、ブートボリューム、ブロックボリュームを作成します。
2. ブロックボリュームを `/srv/monitoring` にアタッチし、`nofail` でマウントします。
3. Docker Engine と Compose プラグインをインストールします。
4. `/opt/monitoring` とディレクトリ構成を作成します。
5. Cloudflare Tunnel と検証用ホスト名を作成します。
6. systemd ユニットを設定します。

検証:

```bash
docker compose version
df -h / /srv/monitoring
systemctl status monitoring
```

### Phase 2: 空スタック

1. Compose と設定ファイルをコピーします。
2. プレースホルダー入りの `.env` を作成し、モード `0600` にします。
3. スタックを起動します。

   ```bash
   cd /opt/monitoring
   docker compose up -d --wait
   ```

4. ヘルスを確認します。

   ```bash
   docker compose ps
   curl -fsS http://127.0.0.1:3000/api/health
   ```

5. Cloudflare Access 経由で `https://grafana-oci.<domain>` を開きます。
6. データソース、ダッシュボード、アラートルールが読み込まれたか確認します。

### Phase 3: メトリクス経路

1. オンプレミスのクラスタに `vmagent-remote-write` Secret を作成します。
2. `vmagent` に `remoteWrite` を追加します。
3. Argo CD 経由で適用します。
4. サンプルが届くか確認します。

   ```bash
   docker compose exec -T victoriametrics \
     wget -qO- 'http://localhost:8428/api/v1/query?query=up'
   ```

   または Grafana Explore で VictoriaMetrics データソースを使って確認します。

5. 系列数とサンプルレートをオンプレミスの `vmsingle` と比較します。
6. ローカル `vmsingle` はロールバック先として残します。

### Phase 4: ログ経路

1. k8s Fluent Bit DaemonSet にクラウド Loki 出力を追加します。
2. Ansible 管理の VM Fluent Bit ロールにも同じ出力を追加します。
3. デプロイして検証します。

   ```bash
   docker compose exec -T loki wget -qO- http://localhost:3100/ready
   ```

   または Grafana Explore で Loki データソースを使って確認します。

4. Grafana でログをクエリし、オンプレミス Loki とラベルを比較します。
5. バッファ使用量、取り込みレート、B2 オブジェクト増加を監視します。

### Phase 5: Grafana 切り替え

1. OCI 側でダッシュボードとアラートルールが正しいか確認します。
2. 二重書き込み中は OCI ルールを `isPaused: true` のままにし、オンプレミスのアラートを有効にします。カットオーバー時に OCI ルールを `isPaused: false` にし、オンプレミスの Discord コンタクトポイントを無効化します。両方の通知経路を同時に動かさないでください。
3. オンプレミス Grafana Ingress を無効化し、Cloudflare コントローラが DNS レコードを管理しなくなるようにします。
4. `grafana-k8s.<domain>` を OCI トンネルへ変更します。
5. ロールバック用にオンプレミス Grafana を読み取り専用で残します。
6. テストアラートを送信し、Discord へ届くか確認します。

### Phase 6: 撤去

2〜4週間安定稼働した後:

1. Fluent Bit からオンプレミス Loki 出力を削除します。
2. `vmagent` をスタンドアロンの `victoria-metrics-agent` chart へ移すか、`victoria-metrics` Application を残して `vmsingle.enabled: false` にします。リモートライト収集が保たれるまでは Application を削除しないでください。
3. `grafana` と `loki` を `argocd/k3s/apps/infrastructure/kustomization.yaml` から削除します。
4. リモートライトが安定したら `victoria-metrics` Application と `vmsingle` PVC を削除するか、14〜30日のローカルバッファに縮小します。
5. 他に利用者がいないことを確認してから、Loki LoadBalancer、NodePort、ルーターの `loki_proxy` を削除します。
6. バックアップ後に PVC と PV を削除します。StorageClass は `Retain` なので、PVC を消しても PV は残ります。
7. `docs/repository-guide.md` とこのドキュメントを更新します。

### 切り替えとロールバック

ロールバック手順:

1. DNS レコードをオンプレミスのトンネルまたは Ingress へ戻します。
2. OCI の `remoteWrite` と Loki 出力を削除します。
3. オンプレミスの Discord コンタクトポイントを再有効化します。
4. 調査のため OCI VM を残します。ロールバック期間中は削除しないでください。

二重書き込み中はオンプレミス側もローカルに書き続けているため、ロールバックでデータを失いません。Loki のコピー窓だけがギャップでしたが、この計画は初回コピーを行わないため、ギャップはありません。

## 運用

- systemd が起動時にスタックを立ち上げます。コンテナは `unless-stopped` で再起動します。
- healthcheck が `docker compose up --wait` と CI スモークテストをゲートします。
- Renovate がイメージ更新 PR を作り、CI が検証し、マージがデプロイします。
- 月次または必要時に `docker compose pull && docker compose up -d --wait` を実行します。
- `/`、`/srv/monitoring`、B2 のディスク使用量を監視します。
- B2 の egress と 503 率を監視します。
- Docker コンテナログをローテーションします。Docker デーモン設定で `max-size` と `max-file` を設定します。
- chrony を使い時刻同期を確認します。Loki と VictoriaMetrics はタイムスタンプに敏感です。
- `https://grafana-k8s.<domain>` と取り込みエンドポイントに外部 uptime check を入れます。OCI VM が落ちると Grafana は自分自身の停止を通知できません。
- dead-man's switch を入れます。外部サービスがヘルスエンドポイントに ping し、止まったら Discord に通知します。

## リスクと対策

| リスク | 影響 | 対策 |
| --- | --- | --- |
| B2 lifecycle が無効 | ストレージが際限なく増え、B2 性能が劣化 | 最小 Lifecycle ルールを有効化するか外部クリーンアップジョブを回す |
| パブリック IP 露出 | SSH やサービスへの侵害 | NSG 許可リスト、鍵のみ SSH、サービスポートを公開しない、Cloudflare Tunnel |
| 単一 OCI VM の障害 | リストアまで監視が停止 | 日次バックアップ、リストア訓練、外部 uptime check、SPOF は受け入れ |
| Loki/B2 クエリ遅延 | ダッシュボードと調査が遅い | 切り替え前にテスト、保持短縮、チャンク拡大、クエリ制限 |
| Loki バージョン不整合 | 起動失敗やデータ読めない | イメージ固定、`-verify-config`、S3 書き込みテスト |
| Grafana provisioning の逸脱 | アラートルールが適用されない | CI スモークテスト、reload API、UI 編集禁止 |
| Discord 二重通知 | アラート疲労 | 片側を pause するかコンタクトポイントを片方無効化 |
| オンプレミス障害でアラートが止まる | ホームラボが down でも通知なし | 欠損データルール、ハートビート、外部 dead-man's switch、二次通知 |
| DNS 所有権の競合 | 切り替えが失敗・フラップ | DNS 変更前にオンプレ Ingress を無効化し、旧レコードを保持 |
| egress 超過 | B2 や OCI の予期せぬ課金 | egress 監視、クエリ制限、3倍無料枠の活用 |
| CI/CD侵害 | 不正デプロイ | Environment 承認、action 固定、SSH 制限、CI にシークレットを置かない |
| ブートボリューム枯渇 | Docker または OS 障害 | ログローテーション、`/` 監視、イメージ prune |
| データ損失 | メトリクス/ログ喪失 | バックアップ、B2 バージョニング、リストア訓練 |

## 計画レビュー

### そもそも移行すべきか

移行が正当化されるのは、**ホームラボ障害時にアラートを生かし続けたい場合**です。監視対象クラスタ上で動く監視は、クラスタ自身の障害を信頼して報告できません。クラスタ、ネットワーク、ストレージが死ぬと、アラートプレーンも一緒に死にます。Grafana と通知経路を OCI へ移すと、それらは独立した障害ドメインに置かれます。これは単なるコスト最適化ではなく、強い理由です。

データ耐久性だけが目的なら、バックアップのみの設計の方が小さいです。現状スタックを維持し、VictoriaMetrics、Loki、Grafana を B2 へバックアップすればよく、2つ目の Grafana、DNS 切り替え、二重書き込み、CI/CD は不要です。独立アラートやオフロードが余分な運用に見合う場合にのみ、ハイブリッドを選んでください。

ハイブリッド計画が追加する運用複雑さ:

- 検証期間中は2つの監視スタックが並走します。
- パブリック IP と2つ目の Cloudflare Tunnel が増えます。
- Docker Compose のデプロイと CI/CD パイプラインが別に必要です。
- B2 の Lifecycle とクエリ遅延の調整が必要です。

それらのコストが受け入れられる場合に進めてください。ホームラボでは学習価値と独立アラートが正当化できます。純粋なデータ耐久性目的なら、バックアップのみの設計の方が小さくて済みます。

### 妥当な点

- 収集系をオンプレミスに残すことで、VPN 新設を避け、Technitium SD と node exporter の到達性を維持できます。
- リモートライトと Loki push はアウトバウンドのみなので、パブリック IP にインバウンドのサービスポートは不要です。
- B2 は6ヶ月ログに対して安価で、見積もり $0.42/月 は受け入れ範囲内です。
- 既存の Grafana アラートルールをほぼそのまま再利用できます。
- 二重書き込み中もオンプレミス側が動き続けるため、移行は可逆です。
- Grafana と通知経路が独立した障害ドメインへ移ることが、主な運用上の利点です。

### 実装前に変えるべき点

1. **B2 Lifecycle。** 無効のままだと計画に上限がありません。非表示バージョンだけを削除する最小ルールを有効化するか、外部クリーンアップジョブを追加してください。これが最重要の修正です。
2. **パブリック IP のロックダウン。** パブリック IP が許容されるのは、NSG が厳しく、SSH が鍵のみで、サービスポートを公開していない場合に限ります。Caddy、Grafana、VictoriaMetrics、Loki を直接公開しないでください。
3. **バックアップとリストア。** 単一 VM 運用は受け入れますが、RTO は明示してテストする必要があります。最低限、ブロックボリュームの日次バックアップと四半期リストア訓練を行ってください。
4. **安全な CI/CD 経路。** GitHub ホスト型ランナーの IP は固定ではありません。Cloudflare Tunnel SSH、Tailscale、self-hosted ランナーのいずれかを使い、SSH を世界に開けないでください。
5. **Loki/B2 検証。** 切り替え前に、固定イメージでクエリ遅延、`zstd` の CPU コスト、S3 書き込みをテストしてください。CPU が問題なら `gzip` に戻します。
6. **アラート二重化。** 二重書き込み中は片方の Grafana のアラートを pause します。合成アラートで end-to-end にテストしてください。
7. **DNS 手順。** 現在の Grafana レコードはオンプレミスの Cloudflare コントローラが所有しています。DNS を変える前にその Ingress を無効化し、旧レコードをロールバック用に保持してください。
8. **欠損データとハートビートのアラート。** オンプレミス収集が死んだとき、閾値ルールだけでは発火しません。[ホームラボ障害時のアラート](#ホームラボ障害時のアラート)にあるルールとハートビートを追加してください。

### 残存リスク

- 単一 VM は依然として単一障害点です。外部 uptime check とバックアップは影響を減らしますが、排除はできません。
- B2 には APAC リージョンがありません。OCI VM が東京なら、ローカルディスクよりクエリ遅延が大きくなります。6ヶ月ログ保持にコミットする前にテストしてください。
- B2 はコスト最適化であり、性能層ではありません。6ヶ月ログを頻繁にクエリするなら、同一リージョンの OCI Object Storage や大きなローカルブロックボリュームの方が、高価でも良いトレードオフになり得ます。
- Docker Compose は GitOps ではありません。VM 上でファイルを直接編集すると逸脱が起き得ます。デプロイスクリプトは `origin/main` へリセットする運用にし、手動編集は禁止します。
- Always Free の 200 GiB ブロック枠をちょうど消費しています。増やすには有償ボリュームか保持短縮が必要です。

### 結論

この計画は**条件付きで妥当**です。B2 Lifecycle に上限を付け、パブリック IP をロックダウンし、バックアップとリストアをテストし、CI/CD 経路を安全にし、**ホームラボ障害を検知するための欠損データ/ハートビートアラートを入れれば**受け入れられます。それらがないと、ストレージコストが無制限に増え、不要なインターネット露出があり、肝心の障害時に通知できない計画になります。

## 未決定事項

- B2 のリージョンとエンドポイント。OCI VM に最も近いリージョンを選びます。
- OCI リージョンと予約済みパブリック IP が利用可能か。
- 本番 Grafana ホスト名と Cloudflare Access の IdP。
- カットオーバー後に 14〜30日のローカル `vmsingle` バッファを残すか。
- 6ヶ月ログ保持が B2 のクエリ遅延に見合うか、90日で十分か。
- バックアップ保持と正確な RTO 目標。

## 検証チェックリスト

### デプロイ前

- [ ] 現在のイメージタグを記録した
- [ ] メトリクス系列数と Loki バイト/日を計測した
- [ ] B2 バケット、スコープ付きアプリケーションキー、Lifecycle ルールを確認した
- [ ] OCI VM、パブリック IP、NSG、ブートボリューム、ブロックボリュームを確認した
- [ ] Cloudflare Tunnel と検証用ホスト名を作成した
- [ ] DNS TTL を 60秒に下げた
- [ ] バックアップを取得し、リストア手順を文書化した

### デプロイ

- [ ] `docker compose config -q` が通る
- [ ] Caddy validate が通る
- [ ] Loki `-verify-config` が通る
- [ ] Grafana provisioning スモークテストが通る
- [ ] `docker compose up -d --wait` が健全
- [ ] Grafana のデータソースとダッシュボードが読み込まれる
- [ ] アラートルールとコンタクトポイントが読み込まれる
- [ ] リモートライトのサンプルが届く
- [ ] Loki push のログが届く
- [ ] B2 にオブジェクトが書かれ、Lifecycle ルールが有効

### 切り替え

- [ ] テストアラートが Discord に届く
- [ ] オンプレミスのアラートを無効化するか OCI ルールを pause した
- [ ] DNS を OCI へ切り替えた
- [ ] ロールバック用にオンプレミス Grafana を読み取り専用で残した
- [ ] ダッシュボードとクエリを24時間検証した

### 撤去

- [ ] オンプレミス Loki 出力が残っていない
- [ ] オンプレミス `vmsingle` 依存が残っていない、またはバッファ保持を設定した
- [ ] Argo CD Application を `kustomization.yaml` から削除した
- [ ] PVC と PV をバックアップ後に削除した
- [ ] Loki LoadBalancer、NodePort、ルータープロキシを削除した
- [ ] ドキュメントを更新した
