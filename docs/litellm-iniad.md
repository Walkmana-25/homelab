# INIAD Anthropic API を LiteLLM 経由で利用するための運用ガイド

本ドキュメントでは、INIAD が提供する Anthropic 互換 API (`https://api.anthropic.iniad.org`) のモデルを LiteLLM ゲートウェイに登録する仕組み、登録前ヘルスチェック、モデルの追加・削除手順、および検証コマンドについて解説します。

---

## 1. 概要

INIAD の Anthropic API は Anthropic Messages API と互換のエンドポイントを提供しますが、公式 API とはいくつか挙動が異なります。

| 項目 | 公式 Anthropic API | INIAD Anthropic API |
| :--- | :--- | :--- |
| ベース URL | `https://api.anthropic.com/v1` | `https://api.anthropic.iniad.org/api/v1` |
| 認証 | `x-api-key: sk-ant-...` | `x-api-key: <INIAD トークン>` (`sk-ant-` プレフィックスなし) |
| `anthropic-version` ヘッダ | 必須 (日付指定) | 実測では付与しなくても動作する (無視される) |
| `anthropic-beta` ヘッダ | ベータ機能の有効化に使用 | 実測では無視される |
| Models API (`GET /v1/models`) | モデル一覧を返す | 一覧取得は HTTP 400 (`body field required`)、`POST` は 405 を返す |
| `cache_control` (プロンプトキャッシュ) | 対応 | 非対応。付与すると 400 (`extra fields not permitted`) |
| 課金 | 従量課金 | 課金なし |

INIAD のトークンは OpenAI API 用と同じ INIAD トークンで、`litellm-env` SealedSecret の `INIAD_API_KEY` に格納されています。**値そのものは本ドキュメントやリポジトリに記載しません。**

LiteLLM の anthropic アダプタは既定で `x-api-key` を送出するため、認証方式に関する追加設定は不要です。

---

## 2. 利用可能なモデル

ゲートウェイからは以下のモデル名で参照できます。

| LiteLLM モデル名 | 上流モデル ID | コンテキスト | 最大出力 |
| :--- | :--- | ---: | ---: |
| `iniad-claude/claude-haiku-5-5` | `claude-haiku-5-5` | 1,000,000 | 128,000 |
| `iniad-claude/claude-sonnet-5-5` | `claude-sonnet-5-5` | 1,000,000 | 128,000 |

コンテキスト長と最大出力は、同じモデル ID を持つ Anthropic の公開エントリ (models.dev の `anthropic` プロバイダ) から**実行時に**取得して `model_info` に登録されます。models.dev に到達できない run では limits なしで登録されるため、この表の値が一時的に反映されないことがあります (次の run で回復します)。

---

## 3. 登録の仕組み

LiteLLM のモデル一覧は Helm values の `model_list` には書かれておらず、CronJob `litellm-model-sync` が管理 API 経由で実行時に登録します。プロバイダ定義は `argocd/k3s/apps/application/litellm/model-sync.yaml` の ConfigMap キー `sync.py` 内の `PROVIDERS` にあります。

INIAD Claude 用のエントリ (`iniad-claude`) は次の 4 点が他のプロバイダと異なります。

1. **`api_base` は `/api` で止める**
   LiteLLM 1.106.2 の anthropic アダプタは `api_base` に対して `/v1/messages` を無条件に付加します。そのため `https://api.anthropic.iniad.org/api` を指定します。`/api/v1` にすると `/api/v1/v1/messages` となり 404 になります。
2. **モデル ID は固定リスト (`models`)**
   INIAD の Models API はどのリクエストにも 400 を返すため自動検出できません。`models` に列挙した ID がそのまま登録対象になり、`models_url: None` と併用しても `models` が優先されます。
3. **価格は未設定**
   INIAD は課金しないため、`catalog_provider` を指定せず models.dev 由来の価格も使いません。`costs.json` に `iniad-claude/...` のエントリを置かない限り価格は未設定のままです。ゼロ価格を明示すると、LiteLLM が 0 をそのまま返さない場合に毎回「価格が変わった」と判定されて再作成ループになるため、意図的に未設定にしています。
4. **コンテキスト長のみ流用**
   `limits_catalog_provider: anthropic` により、limits だけを Anthropic の公開エントリから取り込みます。

---

## 4. 登録前ヘルスチェック

INIAD のエンドポイントは不安定なため、`iniad-claude` には `probe: True` が設定されています。`probe` を持つプロバイダでは、モデルの新規登録・再作成の直前に次のヘルスチェックを実行します。

| 項目 | 内容 |
| :--- | :--- |
| リクエスト | `POST {api_base}/v1/messages` |
| ボディ | `{"model": "<model_id>", "max_tokens": 8, "messages": [{"role": "user", "content": "ping"}]}` |
| ヘッダ | `x-api-key` (プロバイダのキー)、`anthropic-version: 2023-06-01`、`Content-Type: application/json` |
| 判定 | レスポンスに `content` (Anthropic) または `choices` (OpenAI 互換) が含まれること |
| リトライ | 2 回 (2 秒あけて 1 回だけ再試行) |
| タイムアウト | 60 秒 / 試行 |

チェックに失敗した場合の挙動は次のとおりです。

- 既存のデプロイメントは**そのまま維持**されます (削除・更新しない)。
- モデル名は「登録すべきモデル」の集合に残るため、prune 処理で削除されることもありません。
- ログに `! iniad-claude/<model>: probe failed, not registering this run` が出力されます。
- run の最後に `probe failed for N model(s), left untouched this run: ...` という要約行が 1 行出ます (Job 自体は成功扱いのままです)。
- 次回の CronJob 実行 (6 時間ごと、`0 */6 * * *`) で再試行されます。

このチェックは**上流を直接**叩くため、ゲートウェイ側の変換 (例: LiteLLM が付与する `cache_control`) に起因する失敗は検出できません。登録後の最終確認は 6-3 のゲートウェイ経由のリクエストで行ってください。

---

## 5. モデルの追加・削除

1. `argocd/k3s/apps/application/litellm/model-sync.yaml` の `iniad-claude` エントリの `models` リストを編集します。
2. 変更をコミットして Argo CD で同期します (ConfigMap が更新されます)。モデル追加・削除は ConfigMap のみの変更なので LiteLLM の再起動は不要です (`litellm_settings` を変えた場合のみ、7 章の再起動が必要)。
3. CronJob を手動で 1 回実行し、登録を反映します。

```bash
# 実行中の run がないことを先に確認する。手動 Job は CronJob の管理外で
# concurrencyPolicy: Forbid の対象外のため、定期実行と競合し得る。
kubectl get jobs -n litellm -l job-name=litellm-model-sync

kubectl create job -n litellm --from=cronjob/litellm-model-sync litellm-model-sync-manual
kubectl logs -n litellm -f job/litellm-model-sync-manual
kubectl delete job -n litellm litellm-model-sync-manual
```

`models` から外したモデルは、次回実行時に prune 処理 (`- iniad-claude/<model>` のログ) で削除されます。追加したモデルは登録前ヘルスチェックに成功した場合のみ登録されます。

---

## 6. 検証手順

### 1. CronJob の実行結果を確認する

```bash
kubectl get cronjob -n litellm litellm-model-sync
kubectl get jobs -n litellm -l job-name=litellm-model-sync --sort-by=.metadata.creationTimestamp
kubectl logs -n litellm job/$(kubectl get jobs -n litellm -l job-name=litellm-model-sync \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
```

`+ iniad-claude/claude-haiku-5-5 [chat]` のように登録されたモデルが出力されていれば成功です。手動実行した Job も同じラベルに一致するため、`kubectl get jobs` の一覧で対象を確認してからログを取ると確実です。

### 2. ゲートウェイのモデル一覧を確認する

マスターキーを Pod の spec に載せないよう、port-forward してローカルの `curl` から叩きます。

```bash
kubectl port-forward -n litellm svc/litellm 4000:4000 &
MASTER_KEY=$(kubectl get secret -n litellm litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d)
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  | grep -o '"iniad-claude/[^"]*"'
```

`iniad-claude/claude-haiku-5-5` と `iniad-claude/claude-sonnet-5-5` の両方が出力されれば登録済みです。

### 3. LiteLLM 経由で Messages リクエストを送る

上の port-forward を継続したまま実行します。

```bash
curl -s http://127.0.0.1:4000/v1/messages \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"iniad-claude/claude-haiku-5-5","max_tokens":32,"messages":[{"role":"user","content":"ping"}]}'
```

`content` 配列を含む Anthropic 形式のレスポンスが返れば、ゲートウェイから上流まで疎通しています。

### 4. 上流を直接確認する (切り分け用)

ゲートウェイの応答が 5xx の場合は、上流自体を直接叩いて切り分けます。キーはクラスタの Secret からローカルのシェル変数として読み出します。

```bash
INIAD_API_KEY=$(kubectl get secret -n litellm litellm-env -o jsonpath='{.data.INIAD_API_KEY}' | base64 -d)
curl -s -o /dev/null -w '%{http_code}\n' https://api.anthropic.iniad.org/api/v1/messages \
  -H "x-api-key: ${INIAD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-5-5","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}'
```

キーを `kubectl run` の引数や Pod の `command`/`args` に渡さないでください (Pod spec は誰でも読めます)。また変数展開はローカルのプロセス引数にも現れるため、共用端末では履歴と `ps` に注意します。

`200` 以外が返る場合、上流障害の可能性があるため、次回の CronJob 実行まで待つか、上流の復旧を確認します。

---

## 7. 注意事項

- **設定変更には Pod 再起動が必要**: Helm chart は `config.yaml` を `subPath` でマウントしているため、ConfigMap を更新してもコンテナ内のファイルは自動更新されません。`litellm_settings` などを変更した場合は Argo CD 同期後に `kubectl -n litellm rollout restart deploy/litellm` を実行し、`/etc/litellm/config.yaml` に反映されたことを確認してください。
- **`cache_control` は上流で拒否される**: INIAD のゲートウェイはテキストブロック自体は受理しますが、`cache_control` が付いたブロックを 400 (`extra fields not permitted`) で拒否します。LiteLLM 1.106.x は Anthropic アダプタのリクエストに `cache_control` を自動注入する機能を持ち、**モデル単位の無効化手段が無い**ため、`litellm_settings.enable_anthropic_prompt_caching: false` でグローバルに無効化しています (`argocd/k3s/apps/application/litellm/application.yaml` に明示、実行時設定は `LiteLLM_Config` テーブルにも保存)。この設定を戻すと `iniad-claude/*` は全リクエストが 400 になります。
- **クライアントが自前で付ける `cache_control` も 400 になる**: 上記の設定は「LiteLLM の自動注入」を止めるだけで、INIAD 自体が `cache_control` を受け付けない点は変わりません。Claude Code のように `cache_control` を自分で送るクライアントを `iniad-claude/*` に向ける場合は、キャッシュ指定を無効化してください。
- **コストレポート**: `claude-haiku-5-5` / `claude-sonnet-5-5` という ID は Anthropic の公開 ID と同一のため、LiteLLM の組み込みコストマップに該当エントリがあれば `/spend` や管理 UI のコストは Anthropic のリスト価格で計上され、無ければ $0 になります。実際の INIAD 利用料は 0 円である点に注意してください。
- **LibreChat は別系統**: LibreChat は INIAD Anthropic API を直接参照する設定になっており、LiteLLM のモデル登録とは独立しています。LiteLLM 側の `models` を変更しても LibreChat の設定は変わりません。
- **キーの取り扱い**: `INIAD_API_KEY` は `litellm-env` SealedSecret にのみ存在します。平文の値をコミットしたり、ドキュメント・Issue に貼り付けたりしないでください。
- **モデル ID の追加は上流確認後に行う**: INIAD は Models API で一覧を返さないため、新しい ID を追加する前に、上記 6-4 のコマンドで上流が実際に応答することを確認してください。
