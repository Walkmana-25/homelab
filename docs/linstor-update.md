# LINSTOR 安全なアップデート手順と運用ガイド

本ドキュメントでは、LINSTOR および Piraeus Operator の安全かつ再現可能なアップデート手順、互換性確認、検証手順、およびロールバック手順について解説します。

---

## 1. 概要と基本方針

### バージョン管理の単一基準値 (Single Source of Truth)
LINSTOR の対象バージョンは `ansible/roles/linstor/defaults/main.yml` の `linstor_target_version` で一元管理されます。

### パッケージ固定方針 (`apt-mark hold`)
`linstor-common`, `linstor-controller`, `linstor-satellite` の 3 パッケージは `apt-mark hold` により固定されます。これにより、通常の `apt upgrade` や `unattended-upgrades` による予期しない自動更新を防ぎます。

### 明示的更新操作
アップデートは `ansible/` ディレクトリ配下で dedicated コマンド `make update-linstor` を明示的に実行して行います。既存の `make deploy-linstor` および通常の再実行では、すでに指定バージョンが導入されている場合に不要な変更を行わない冪等性が維持されます。

---

## 2. 互換性マトリクスと前提条件

| コンポーネント | 対応バージョン / コードネーム | 補足事項 |
| :--- | :--- | :--- |
| OS / Codename | Ubuntu 24.04 LTS (`noble`) | LINBIT PPA `ppa:linbit/linbit-drbd9-stack` |
| LINSTOR Controller | 1.34.2 (`1.34.2-1ppa1~noble1`) | Ansible でピン留め・ローカル deb キャッシュから取得 |
| LINSTOR Satellite | 1.34.2 (`1.34.2-1ppa1~noble1`) | Controller と同一バージョンを維持必須 |
| LINSTOR Common | 1.34.2 (`1.34.2-1ppa1~noble1`) | Controller / Satellite 共通依存ライブラリ |
| DRBD Kernel Module | DRBD 9.x (`drbd-dkms`) | ホスト上で DKMS によりビルド・ロード |
| Piraeus Operator | v2.11.0 | Argo CD 管理 (`argocd/k3s/apps/infrastructure/piraeus/`) |

### 互換性確認ルール
1. **LINSTOR パッケージ整合性**: `linstor-common`, `linstor-controller`, `linstor-satellite` の 3 パッケージは必ず同一の対象バージョンに揃える必要があります。
2. **Piraeus Operator との互換性**: Piraeus Operator の対応 LINSTOR Controller API バージョンを確認の上、アップデート対象バージョンを決定します。
3. **Renovate 自動更新の抑制**: Piraeus Operator が独立して自動更新され互換性問題を起こすリスクを防ぐため、`.github/renovate.json` において `piraeus` / `piraeus-operator.git` の自動更新は `enabled: false` に設定されています。Piraeus Operator の更新は必ず互換性確認の上、手動 PR で実施します。

---

## 3. アップデート手順 (Step-by-Step)

### 事前準備
1. 対象バージョン (`linstor-common`, `linstor-controller`, `linstor-satellite`) の `.deb` ファイルを取得し、ターゲットノードの `linstor_deb_sources` (例: `/tmp/linstor-1342`) に配置するか、`linstor_deb_urls` に取得元 URL を記述します。
2. 必要に応じて `ansible/roles/linstor/defaults/main.yml` の `linstor_deb_checksums` に各 `.deb` の SHA256 ハッシュを指定します。

```yaml
linstor_target_version: "1.34.2-1ppa1~noble1"
linstor_deb_sources:
  - "/tmp/linstor-1342"
linstor_deb_checksums:
  linstor-common: "<SHA256_CHECKSUM>"
  linstor-controller: "<SHA256_CHECKSUM>"
  linstor-satellite: "<SHA256_CHECKSUM>"
```

### 実行コマンド

```bash
cd ansible
make update-linstor
```

### 自動実行される事前検証と更新フロー
1. **バージョンチェック**: インストール済みの 3 パッケージのバージョンを確認。
2. **事前状態ログ出力**: 更新前の `linstor node list`, `linstor storage-pool list`, `linstor resource list` の状態をログに記録。
3. **deb パッケージメタデータ検証**: キャッシュされた `.deb` ファイルに対して `dpkg-deb -W` を実行し、パッケージ名とバージョンが `linstor_target_version` と一致することを検証。不足・混在・checksum 不一致がある場合は更新処理前に即座にエラー停止 (fail) します。
4. **安全な更新処理**:
   - `apt-mark unhold linstor-common linstor-controller linstor-satellite`
   - `ansible.builtin.apt` でローカル deb 群を一括インストール (`allow_downgrade: true`)
   - `apt-mark hold linstor-common linstor-controller linstor-satellite`
5. **サービス検証**:
   - LINSTOR Controller REST API (port 3370) の応答確認
   - ノードの `ONLINE` 状態の確認 (`linstor --machine-readable node list`)
   - ストレージプールおよびリソースの状態表示

---

## 4. 検証手順 (Verification Procedures)

### 1. ホスト側 LINSTOR CLI 検証
更新完了後、ターゲットノードで以下を実行し、ノードが `ONLINE` でストレージプールが正常に認識されていることを確認します。

```bash
linstor node list
linstor storage-pool list
linstor resource list
```

### 2. Kubernetes / CSI 連携検証
k3s クラスター側で Pod および CRD の状態を確認します。

```bash
# Piraeus Operator / Satellite Pod の確認
kubectl get pods -n piraeus-datastore

# LinstorCluster Custom Resource の確認
kubectl get linstorclusters -n piraeus-datastore

# StorageClass の確認
kubectl get storageclass ssd
```

### 3. テスト PVC / Pod による読み書きテスト
検証用 PVC と Pod を作成し、CSI プロビジョニングとデータの読み書きを確認します。

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: linstor-test-pvc
  namespace: default
spec:
  storageClassName: ssd
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: linstor-test-pod
  namespace: default
spec:
  containers:
  - name: test-container
    image: busybox
    command: ["/bin/sh", "-c", "echo 'linstor-update-test' > /mnt/test.txt && cat /mnt/test.txt && sleep 3600"]
    volumeMounts:
    - mountPath: "/mnt"
      name: test-volume
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: linstor-test-pvc
```

```bash
# PVC が Bound になることを確認
kubectl get pvc linstor-test-pvc

# Pod 内で書き込みデータが読み出せることを確認
kubectl exec linstor-test-pod -- cat /mnt/test.txt

# テスト完了後にリソースを削除
kubectl delete pod linstor-test-pod
kubectl delete pvc linstor-test-pvc
```

---

## 5. ロールバック手順とデータ保全原則

### 更新停止条件 (Failure Stopping Criteria)
以下のいずれかの条件が発生した場合、更新作業を直ちに中断し、ロールバックを実施します。
- 必須 3 deb パッケージの不足、バージョン不一致、ハッシュ不一致が検出された場合。
- パッケージインストール後、LINSTOR Controller サービスが起動しない、または API (port 3370) が応答しない場合。
- LINSTOR ノードが `ONLINE` に復帰しない場合。
- Piraeus Satellite または CSI が Controller REST API に接続できない場合。

### ロールバック手順
1. `ansible/roles/linstor/defaults/main.yml` の `linstor_target_version` を変更前の正常な旧バージョンに戻します。
2. 旧バージョンの `.deb` ファイルを `linstor_deb_sources` に配置します。
3. `cd ansible && make update-linstor` を実行し、旧パッケージセットへダウングレード・ホールドします。
4. Piraeus Operator 側のマニフェストを変更していた場合は、`argocd/k3s/apps/infrastructure/piraeus/application.yaml` の `targetRevision` を旧バージョンに戻し、Argo CD で同期します。
5. 上記の検証手順を実行し、旧バージョンでの正常稼働を確認します。

### データ保全原則 (必須条件)
ロールバックおよびアップデート処理において、既存の LVM Volume Group (`linstor_thinpool`)、Thin Pool (`thinpool`)、物理ディスク (`/dev/sdb`)、および DRBD ボリュームの**削除・初期化・フォーマットは厳禁**であり、プレイブックは既存データを保護する設計となっています。
