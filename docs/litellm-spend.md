# LiteLLM のコスト計上と確認手順

このドキュメントは、LiteLLM ゲートウェイ (`argocd/k3s/apps/application/litellm/`) が
リクエストごとのコストをどこに記録し、どのモデル単位で確認できるかを説明する。
モデルの登録そのものは [`litellm-iniad.md`](litellm-iniad.md) を参照。

## 1. データの所在

spend ログは `litellm-postgres` の PostgreSQL (`database: litellm`) に保存される
(`general_settings.store_model_in_db: true`, `store_prompts_in_spend_logs: true`)。
保持期間は `maximum_spend_logs_retention_period: "90d"`、毎日 03:00 に削除ジョブが走る。

| テーブル | 粒度 |
| --- | --- |
| `LiteLLM_SpendLogs` | リクエスト 1 行。`request_id` が主キー |
| `LiteLLM_DailyModelUsage` | 日次。主キーは `(date, model_group, model, custom_llm_provider, task_type)` |
| `LiteLLM_DailyGlobalSpend` / `LiteLLM_DailyUserSpend` など | 日次。エンティティ別 |

`LiteLLM_SpendLogs` で意味を取り違えやすい列:

- `model_group` — クライアントが要求した名前 (`routing/glm-5.3-flash`, `autorouter/agent` など)
- `model` — **実際に選択されたデプロイメントのモデル文字列**
  (`openai/responses/glm-5.3-flash`, `openai/mimo-v2.6-pro` など)
- `model_id` — 選択されたデプロイメントの `model_info.id`（`LiteLLM_ProxyModelTable` と対応）
- `api_base` — 実際に呼ばれた上流 (z.ai / OpenCode Go / INIAD)

つまり「モデルグループ × 実際にルーティングされたモデル」の内訳は、最初から
`model_group` と `model` の 2 列で表現されている。

```bash
# 直近 14 日のグループ別・実モデル別コスト
kubectl -n litellm exec litellm-postgres-1 -- psql -U postgres -d litellm -A -F '|' -c "
SELECT model_group, model, api_base,
       count(*) AS requests,
       round(sum(spend)::numeric, 4) AS usd,
       sum(CASE WHEN spend = 0 THEN 1 ELSE 0 END) AS zero_cost_rows
FROM \"LiteLLM_SpendLogs\"
WHERE \"startTime\" > now() - interval '14 days'
GROUP BY 1, 2, 3
ORDER BY usd DESC;
"
```

## 2. コストはどう決まるか

LiteLLM は「選択されたデプロイメント」の per-token レートでコストを計算する。
レートは `model-sync` CronJob が models.dev と `costs.json` / `limits.json`
(`model-sync.yaml`) から `litellm_params` に書き込んだ値が最終権威で、
ビルトインのモデルコストマップ (`zai/glm-5.3-flash` などベンダー名を持つエントリ) は
デプロイメントがレートを一切宣言していない場合の土台にすぎない。

INIAD のモデルは価格を登録していないため、意図的に $0 で計上される
(実際の INIAD 利用料も 0 円)。z.ai GLM Coding Plan は定額サブスクだが、
ここで記録される額は従量課金のリスト価格による参考値である。

## 3. 落とし穴: limits だけの cost map エントリは $0 課金になる

`callbacks.yaml` の `opencode_models` コールバックは、auto-router のコンテキスト圧縮が
参照する `max_input_tokens` を `litellm.model_cost` に登録する。ここで
**価格を含まない（limits だけの）エントリを登録すると、そのキーは「既知だが無料の
モデル」として解決され、コストは $0 で記録される**。ベンダーのビルトインエントリを
持たないゲートウェイモデル (`openai/responses/glm-5.3-flash`, `openai/mimo-v2.6-pro` など)
がこれに該当し、`routing/*` と `autorouter/*` 経由の利用が $0 になっていた。

現在は「デプロイメント自身の `*cost*` フィールドを必ず登録に含める」「価格を持つ既存
エントリを limits だけのエントリで上書きしない」よう修正済み。同種の退行は
LiteLLM 自身の診断ログとメトリクスで検知できる:

```
litellm_zero_cost_requests_total{reason="pricing_not_applied"}
```

「pricing entry は非ゼロのレートを宣言しているのに、コスト計算が $0 を返した」という
意味で、これが出たら §2 の登録経路を疑う。

```bash
# コスト計算の現状確認（任意のモデル名・グループ名で試せる）
kubectl -n litellm exec deploy/litellm -- python -c "
import json, os, urllib.request
h = {'Authorization': 'Bearer ' + os.environ['PROXY_MASTER_KEY'],
     'Content-Type': 'application/json'}
body = {'model': 'openai/responses/glm-5.3-flash',
        'messages': [{'role': 'user', 'content': 'hi'}]}
req = urllib.request.Request('http://localhost:4000/spend/calculate',
                             data=json.dumps(body).encode(), headers=h, method='POST')
print(json.load(urllib.request.urlopen(req)))
"
```

## 4. 表示の確認方法

- **管理 UI の Usage** — モデル別 (`モデル`) とモデルグループ別の内訳を別々に持つ。
  `routing/glm-5.3-flash` はグループ側に、実際のデプロイ (`openai/responses/glm-5.3-flash`
  など) はモデル側に現れる。
- **ログ画面 / API** — 1 リクエスト単位で実モデルとコストを確認する。

```bash
# グループを指定して個別リクエストを見る（model / model_id / model_group は完全一致）
kubectl -n litellm exec deploy/litellm -- python -c "
import json, os, urllib.request
h = {'Authorization': 'Bearer ' + os.environ['PROXY_MASTER_KEY']}
url = ('http://localhost:4000/spend/logs/v2?model_group=routing/glm-5.3-flash'
       '&page=1&page_size=5')
print(json.dumps(json.load(urllib.request.urlopen(urllib.request.Request(url, headers=h))), indent=2)[:2000])
"
```

## 5. 既知の制約

- **過去の $0 行は遡及修正しない**。修正前に記録された spend ログは $0 のまま残る。
  グループ別の累計を正したい場合は、修正以降のデータで判断する。
- `autorouter/agent` には `model` がグループ名のまま (`autorouter/agent`) で
  `model_group` が空の行が混ざる。これはデプロイメント選択前に失敗したリクエストで、
  `spend` は 0 になる。
- コストは上流のリスト価格ベースであり、サブスク契約の実請求額とは一致しない。
