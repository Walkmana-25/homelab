# Harbor Helm Chart Deployment Research — k3s / ArgoCD

> Researched for: k3s cluster, NFS storage class, cert-manager TLS (Let's Encrypt), Traefik ingress, host `harbor-k3s.lapis-dev.work`.

## Summary

- **Official chart**: `https://helm.goharbor.io` → chart name `harbor`.
- **Latest stable chart**: **v1.19.1** → **Harbor OSS v2.15.1** (released ~May 2026). Safe pin for production.
- **Modern Harbor (2.x) ships NO notary and NO chartmuseum** — these were removed in Harbor 2.0+ / chart 1.6+.
  Modern components: `core`, `jobservice`, `registry`, `portal`, `trivy`, `database` (PostgreSQL/PG14), `redis` (Valkey), `exporter`.
- Chart supports **three TLS cert sources**: `auto` (chart self-signs), `secret` (read existing TLS secret — **use this with cert-manager**), `none` (ingress controller default cert).
- This repo already uses the `cloudflare-tunnel` ingress class for web UIs (headlamp, grafana). For Harbor (a docker **registry**), prefer the **Traefik** ingress class (k3s default) + cert-manager, because Cloudflare Tunnel is not designed for large container-layer uploads and docker registry streaming traffic.

---

## 1. Chart Repository & Version

| Item | Value |
|------|-------|
| Helm repo URL | `https://helm.goharbor.io` |
| Chart name | `harbor` |
| Recommended `targetRevision` | `1.19.1` (Harbor OSS `2.15.1`) |
| Fallback (if 2.15 proxy-cache bug matters) | `1.18.4` (Harbor `2.14.4`) |
| GitHub | https://github.com/goharbor/harbor-helm |

```bash
helm repo add harbor https://helm.goharbor.io
helm repo update
helm search repo harbor/harbor --versions | head
```

> Note: v1.19.0 had a known proxy-cache-from-Docker-Hub bug (goharbor/harbor#23025), fixed in **v1.19.1**. Pin `1.19.1`, not `1.19.0`.

---

## 2. Cluster Context (from this repo)

Verified from existing manifests:

- **Storage class `nfs`** exists (nfs-subdir-external-provisioner), `defaultClass: true`, `reclaimPolicy: Retain`. NFS server: `k3s-nfs.k8s.cloud-milky.solufit.net`, export `/srv/nfs/k3s`.
- **cert-manager** deployed (chart `cert-manager` v1.20.2, CRDs enabled, sync-wave 0). **No ClusterIssuer manifest is committed in git** — it is applied out-of-band. ⚠️ **Verify the exact name** before deploying Harbor:
  ```bash
  kubectl get clusterissuer -A
  # Common names: letsencrypt-prod, letsencrypt-staging, letsencrypt
  ```
- **cloudnative-pg** is installed in the cluster (optional external Postgres for Harbor).
- **longhorn** is installed (block storage, `defaultClass: false`) — better-than-NFS option for the database.
- Existing ArgoCD apps use `ingressClassName: cloudflare-tunnel` for web UIs; **Harbor should use `traefik`** (k3s default IngressClass) instead.
- Repo convention for Helm apps: `spec.source.helm.values: |` (string block) — used by grafana, loki, headlamp, cert-manager, nfs-provisioner. `valuesObject` (object form) used by longhorn. Both work; the string form is the dominant pattern here.

---

## 3. Components That Need Persistent Storage

Each gets its own PVC (→ its own NFS subdir). All support `storageClass` override:

| Component | values path | Default size | Notes |
|-----------|-------------|-------------|-------|
| Registry (image/chart storage) | `persistence.persistentVolumeClaim.registry` | 5Gi → recommend **20Gi+** | Main image storage (filesystem backend) |
| Jobservice logs | `persistence.persistentVolumeClaim.jobservice.jobLog` | 1Gi | Job logs |
| Harbor DB (PostgreSQL) | `persistence.persistentVolumeClaim.database` | 1Gi → recommend **5Gi** | ⚠️ Postgres-on-NFS caveat (see §7) |
| Redis (Valkey) | `persistence.persistentVolumeClaim.redis` | 1Gi | Session/cache |
| Trivy | `persistence.persistentVolumeClaim.trivy` | 5Gi | Vulnerability DB cache |

Image storage backend (`persistence.imageChartStorage.type`): `filesystem` (uses registry PVC) is simplest for NFS home lab. S3/MinIO/Azure/GCS/OSS/Swift are alternatives for larger deployments.

---

## 4. cert-manager Integration

The **correct, documented pattern** for Harbor + cert-manager:

1. `expose.tls.enabled: true`
2. `expose.tls.certSource: secret`
3. `expose.tls.secret.secretName: harbor-k3s-tls` — this secret name is referenced in the Harbor Ingress TLS block. cert-manager will **create & populate** this secret.
4. Add the issuer annotation to `expose.ingress.annotations`:
   ```yaml
   cert-manager.io/cluster-issuer: letsencrypt-prod   # <- your real ClusterIssuer name
   ```
   - For HTTP-01 challenges you also want the ingress to be reachable on :80 → ensure Traefik exposes port 80. cert-manager will add its own solver ingress/solver.
   - Alternatively use DNS-01 (set in the ClusterIssuer) if port 80 is not exposed.

> Harbor does **not** need `core.secretName` for the external ingress TLS — `expose.tls.secret.secretName` is the one that matters. (`internalTLS` is a separate, optional internal mTLS feature — leave `internalTLS.enabled: false` unless hardening internal traffic.)

---

## 5. Ready-to-Use `values.yaml`

Replace `letsencrypt-prod` with your actual ClusterIssuer name, and **change the three `CHANGE-ME` secrets** before applying.

```yaml
# =====================================================================
# Harbor values.yaml — k3s / NFS / Traefik / cert-manager
# Chart: harbor 1.19.1 (Harbor OSS 2.15.1)
# =====================================================================

expose:
  type: ingress
  tls:
    enabled: true
    # "secret" = read TLS cert from a Secret. cert-manager will populate it.
    certSource: secret
    secret:
      # MUST match the cert-manager Certificate/secret; cert-manager writes here.
      secretName: harbor-k3s-tls
    auto:
      commonName: ""
  ingress:
    hosts:
      core: harbor-k3s.lapis-dev.work
    # "default" works for Traefik, nginx, and most controllers.
    controller: default
    # k3s ships Traefik as IngressClass "traefik". Verify: kubectl get ingressclass
    className: traefik
    annotations:
      # --- cert-manager (Let's Encrypt) ---
      cert-manager.io/cluster-issuer: letsencrypt-prod
      # --- TLS redirect + large body (image pushes can be big) ---
      ingress.kubernetes.io/ssl-redirect: "true"
      ingress.kubernetes.io/proxy-body-size: "0"
      # Traefik-specific (harmless if using nginx; kept for parity)
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/proxy-body-size: "0"

# The URL docker/helm clients use. MUST match expose.ingress.hosts.core.
externalURL: https://harbor-k3s.lapis-dev.work

# ---- Persistence: use the cluster's NFS storage class for every PVC ----
persistence:
  enabled: true
  # "keep" preserves PVCs on `helm uninstall` (safe for data).
  resourcePolicy: keep
  persistentVolumeClaim:
    registry:
      storageClass: nfs
      accessMode: ReadWriteOnce
      size: 20Gi
    jobservice:
      jobLog:
        storageClass: nfs
        accessMode: ReadWriteOnce
        size: 5Gi
    database:
      storageClass: nfs
      accessMode: ReadWriteOnce
      size: 5Gi
    redis:
      storageClass: nfs
      accessMode: ReadWriteOnce
      size: 1Gi
    trivy:
      storageClass: nfs
      accessMode: ReadWriteOnce
      size: 5Gi
  imageChartStorage:
    # filesystem = store images in the registry PVC above (simplest on NFS).
    type: filesystem
    filesystem:
      rootdirectory: /storage
    # Set true ONLY if backend can't do redirects (e.g. MinIO). NFS = leave false.
    disableredirect: false

# ---- Security: change these! ----
# Initial admin password (login as admin). Rotate via UI after first login.
harborAdminPassword: "CHANGE-ME-Str0ngP@ss"
# Alternatively reference a pre-existing secret (key: HARBOR_ADMIN_PASSWORD):
# existingSecretAdminPassword: "harbor-admin-secret"
# existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD

# 16-char secret key for encrypting credentials at rest.
secretKey: "CHANGE-ME-16char"

# ---- Update strategy ----
# Recreate is safer on NFS (NFS-backed PVCs are RWO; avoids two pods fighting
# for the same mount during RollingUpdate). Set RollingUpdate only if using RWM.
updateStrategy:
  type: Recreate

logLevel: info

# ---- Component toggles ----
# Trivy: image vulnerability scanner. Needs internet to fetch its DB
# (uses mirror.gcr.io then ghcr.io). Keep enabled unless air-gapped.
trivy:
  enabled: true
  # For air-gapped, set: skipUpdate: true  and provide the DB manually.

# ---- Database (internal PostgreSQL) ----
# For a "production-ish" home lab, internal Postgres on NFS is acceptable.
# If you hit DB corruption (NFS locking), switch to:
#   type: external  + point at cloudnative-pg (already in this cluster),
#   OR move just this PVC to the longhorn storage class.
database:
  type: internal
  internal:
    password: "CHANGE-ME-DB-P@ss"
    shmSizeLimit: 512Mi

# ---- Redis (internal Valkey) ----
redis:
  type: internal

# ---- Internal component TLS (pod-to-pod) — leave off for simplicity ----
internalTLS:
  enabled: false

# ---- Optional: Prometheus metrics / ServiceMonitor ----
metrics:
  enabled: false
# serviceMonitor:
#   enabled: true
#   additionalLabels:
#     release: kube-prometheus-stack   # match your Prometheus operator

# NOTE: Notary and ChartMuseum are NOT in modern Harbor.
# Harbor 2.x uses Cosign/Notary v2 signing and the native OCI/Helm chart store.

# NOTE: nginx component is auto-disabled when expose.type == ingress.
```

---

## 6. ArgoCD Application Manifest (matches this repo's conventions)

Place as `argocd/k3s/apps/application/harbor/application.yaml`, then add `- harbor` to `argocd/k3s/apps/application/kustomization.yaml`.

Uses the repo-dominant `helm.values: |` (string block) style and **sync-wave 3** (runs after cert-manager@0 and nfs-provisioner@1).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: harbor
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/part-of: application
  annotations:
    argocd.argoproj.io/sync-wave: "3"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://helm.goharbor.io
    chart: harbor
    targetRevision: 1.19.1
    helm:
      values: |
        expose:
          type: ingress
          tls:
            enabled: true
            certSource: secret
            secret:
              secretName: harbor-k3s-tls
          ingress:
            hosts:
              core: harbor-k3s.lapis-dev.work
            controller: default
            className: traefik
            annotations:
              cert-manager.io/cluster-issuer: letsencrypt-prod
              ingress.kubernetes.io/ssl-redirect: "true"
              ingress.kubernetes.io/proxy-body-size: "0"
              nginx.ingress.kubernetes.io/ssl-redirect: "true"
              nginx.ingress.kubernetes.io/proxy-body-size: "0"
        externalURL: https://harbor-k3s.lapis-dev.work
        persistence:
          enabled: true
          resourcePolicy: keep
          persistentVolumeClaim:
            registry:
              storageClass: nfs
              accessMode: ReadWriteOnce
              size: 20Gi
            jobservice:
              jobLog:
                storageClass: nfs
                accessMode: ReadWriteOnce
                size: 5Gi
            database:
              storageClass: nfs
              accessMode: ReadWriteOnce
              size: 5Gi
            redis:
              storageClass: nfs
              accessMode: ReadWriteOnce
              size: 1Gi
            trivy:
              storageClass: nfs
              accessMode: ReadWriteOnce
              size: 5Gi
          imageChartStorage:
            type: filesystem
            filesystem:
              rootdirectory: /storage
        harborAdminPassword: "CHANGE-ME-Str0ngP@ss"
        secretKey: "CHANGE-ME-16char"
        updateStrategy:
          type: Recreate
        logLevel: info
        trivy:
          enabled: true
        database:
          type: internal
          internal:
            password: "CHANGE-ME-DB-P@ss"
            shmSizeLimit: 512Mi
        redis:
          type: internal
        internalTLS:
          enabled: false
        metrics:
          enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: harbor
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

> **Secrets in GitOps**: The three `CHANGE-ME` values above are plaintext for a home lab. For better hygiene, replace them with SealedSecrets (already in cluster) or an ExternalSecret, then reference via `existingSecretAdminPassword` etc.

### `helm.values` string vs `helm.valuesObject`

- `helm.values: |` (string) — dominant in this repo (grafana, loki, headlamp, cert-manager, nfs-provisioner). Recommended for Harbor.
- `helm.valuesObject:` (object/JSON) — used by longhorn. Works too, but harder to diff and Renovate handles string `values` more predictably for chart bumps.

---

## 7. Gotchas & NFS Considerations

1. **PostgreSQL on NFS** — the #1 real-world Harbor+NFS pain point. NFS file-locking semantics can occasionally corrupt Postgres WAL under heavy concurrent writes. For a home lab with light load it is fine; if you see DB errors, move the `database` PVC to the **longhorn** storage class (block storage, already installed) or use **cloudnative-pg** (external Postgres) — also already installed.

2. **Registry storage performance** — NFS is slower than block storage. Image push/pull throughput will be limited by NFS bandwidth. Acceptable for home lab; switch `imageChartStorage` to S3/MinIO for serious throughput.

3. **`updateStrategy: Recreate`** — recommended on NFS. NFS-backed PVCs are `ReadWriteOnce`; a `RollingUpdate` can briefly mount the same PVC to two pods → corruption risk. `Recreate` ensures the old pod is gone before the new one starts.

4. **`resourcePolicy: keep`** — keeps PVCs after `helm uninstall` / ArgoCD app deletion. Without it, deleting the app destroys all images. Strongly recommended.

5. **Notary / ChartMuseum** — **removed** in modern Harbor (2.x). Don't look for those values. Harbor now uses Cosign/Notary-v2 signing and serves Helm charts via the native OCI registry (the `chartmuseum` field does not exist).

6. **Initial admin login** — username `admin`, password = `harborAdminPassword`. Change immediately in the UI, or (better) pre-create a secret and use `existingSecretAdminPassword`.

7. **`secretKey`** — exactly 16 characters; used for at-rest encryption. If you lose it after initial deploy, encrypted data (credentials) becomes unreadable. Back it up.

8. **Ingress class routing** — ensure DNS for `harbor-k3s.lapis-dev.work` resolves to the **Traefik** ingress (k3s service `traefik` LoadBalancer/NodePort), NOT to a Cloudflare tunnel. HTTP-01 cert challenges need port 80 reachable through Traefik. Verify with:
   ```bash
   kubectl get ingressclass
   kubectl get svc -n kube-system traefik
   kubectl get certificate -n harbor   # after deploy — should reach Ready=True
   ```

9. **`proxy-body-size: "0"`** is essential — docker layer uploads can be large; without it the ingress rejects big pushes.

10. **Trivy DB download** — on first start Trivy pulls a ~hundreds-of-MB vulnerability DB from `mirror.gcr.io`/`ghcr.io`. Needs outbound internet. If air-gapped: `trivy.skipUpdate: true` + manually provision the DB.

11. **PVC sizing (home-lab recommendations)**: registry 20Gi (main cost), trivy 5Gi, database 5Gi, jobservice 5Gi, redis 1Gi. Total ≈ 36Gi on NFS. Adjust registry up as your image count grows.

12. **Harbor image sources** — the chart defaults all images to `docker.io/goharbor/*` with tag `dev` (resolved by chart to a real version). On offline/restricted clusters you may need to pre-pull and override `*.image.repository`/`tag`. For internet-connected home lab, defaults are fine.

---

## 8. Post-Deploy Verification

```bash
# Pods all Running
kubectl get pods -n harbor
# PVCs bound (5 of them on nfs)
kubectl get pvc -n harbor
# Certificate issued by cert-manager
kubectl get certificate -n harbor
# Ingress created with correct class + host
kubectl get ingress -n harbor
# Login
docker login harbor-k3s.lapis-dev.work -u admin
# Push a test image
docker pull busybox:latest
docker tag busybox:latest harbor-k3s.lapis-dev.work/library/busybox:latest
docker push harbor-k3s.lapis-dev.work/library/busybox:latest
```

---

## 9. Sources

- Harbor Helm chart repo & values.yaml — https://github.com/goharbor/harbor-helm (master `values.yaml` fetched; v1.19.1 = Harbor 2.15.1)
- Chart releases — https://github.com/goharbor/harbor-helm/releases (v1.19.1 Latest, 2026-05)
- Helm repo URL — `https://helm.goharbor.io`
- This repo's existing patterns — `argocd/k3s/apps/infrastructure/{cert-manager,nfs-provisioner,grafana,loki,headlamp,longhorn,cloudnative-pg}/application.yaml`
- cert-manager ClusterIssuer — **not committed in git**; verify name with `kubectl get clusterissuer` (placeholder `letsencrypt-prod` used above)
