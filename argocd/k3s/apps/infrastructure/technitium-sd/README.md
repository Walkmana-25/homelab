# technitium-sd — Technitium DNS → Prometheus HTTP SD bridge

Tiny Python bridge that lets [vmagent](../victoria-metrics/) auto-discover and
scrape node_exporter on **every Proxmox VM** (including non-k8s systems)
registered in Technitium DNS — no manually maintained static target list.

```
Technitium DNS API ──(poll every 30s)──> technitium-sd ──/sd──> vmagent http_sd_configs
                                                      └─/healthz──> k8s probes
```

## How it works

- Polls the Technitium DNS API (`GET /api/zones/records/get?listZone=true`,
  Bearer token auth) for A records in zones `k8s.cloud-milky.solufit.net` and
  `vm.cloud-milky.solufit.net`.
- Keeps **enabled** A records only; drops wildcard records (`*.` prefix) and
  the k8s nodes (`k3s-controller-a`, `k3s-worker-a`, `k3s-worker-b` — they run
  the node-exporter DaemonSet already; exclusion matches both short name and
  FQDN, so double-collection is avoided).
- Serves one Prometheus HTTP SD group per host on `GET /sd:8080/sd`:

  ```json
  [
    {
      "targets": ["10.2.0.20:9100"],
      "labels": {"vm_name": "foo.vm.cloud-milky.solufit.net", "cluster": "k3s", "node_type": "vm"}
    }
  ]
  ```

- vmagent job `node-exporter-vms` (in the victoria-metrics app) consumes it
  via `http_sd_configs` (SD endpoints are re-checked every 1m by default).
- On API failure the last-good target cache is kept and the error is logged.

## Configuration (env vars)

| Variable            | Default                                                        |
| ------------------- | -------------------------------------------------------------- |
| `TECHNITIUM_TOKEN`  | **required** (from Secret `technitium-sd-token`, key `token`)  |
| `TECHNITIUM_URL`    | `http://10.2.0.1:5380`                                         |
| `TECHNITIUM_ZONES`  | `k8s.cloud-milky.solufit.net,vm.cloud-milky.solufit.net`       |
| `TECHNITIUM_EXCLUDE`| `k3s-controller-a,k3s-worker-a,k3s-worker-b`                   |
| `POLL_INTERVAL`     | `30` (seconds)                                                 |
| `LISTEN_PORT`       | `8080`                                                         |
| `SD_EXTRA_LABELS`   | `cluster=k3s,node_type=vm` (`k=v` comma list, merged per group)|

## Required secret (one-time setup)

The Deployment reads the Technitium API token from Secret
`technitium-sd-token` (key `token`) in namespace `monitoring`. Until that
secret exists the pod will fail to start (`CreateContainerConfigError`).

Generate the SealedSecret with kubeseal (controller runs in `kube-system`,
same as the other SealedSecrets in this repo; default namespaced scope):

```bash
kubectl create secret generic technitium-sd-token \
  --from-literal=token=<API_TOKEN> \
  -n monitoring \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system -o yaml \
  > argocd/k3s/apps/infrastructure/technitium-sd/technitium-token-sealed-secret.yaml
```

Then:

1. Add `- technitium-token-sealed-secret.yaml` to the `resources:` list in
   `kustomization.yaml` (the placeholder file in git is comment-only and NOT
   referenced, so builds keep working).
2. Commit and let ArgoCD sync. The sealed-secrets controller unseals it into
   namespace `monitoring` and the Deployment rolls.

Get `<API_TOKEN>` from the Technitium UI: **Administration → API Tokens**.

## Image

The image is built **only** by GitHub Actions
(`.github/workflows/technitium-sd-image.yml`) and pushed to
`ghcr.io/walkmana-25/homelab`-adjacent package
`ghcr.io/walkmana-25/technitium-sd` (tags: `latest` + `main-<sha>`).
No local build, no Harbor, no imagePullSecrets needed.

## Adding a new VM

1. Create an A record for the VM in one of the polled zones (Technitium UI).
2. Install node_exporter on the VM (port 9100) — out of scope for this repo.
3. Within `POLL_INTERVAL` (30s) + vmagent's SD check interval (≤1m) the new
   target appears under job `node-exporter-vms` automatically.
