# Harbor Container Registry

Private container registry for the home k3s lab. Deployed via ArgoCD GitOps
from the Harbor Helm chart (`https://helm.goharbor.io`, chart `harbor`
`1.19.1` = Harbor OSS `2.15.1`).

## Overview

- **URL:** https://harbor-k3s.lapis-dev.work (served through the Cloudflare
  Tunnel ingress; Cloudflare terminates TLS at the edge).
- **Scope:** private — only reachable via the tunnel hostname and from inside
  the cluster. No anonymous/public access by default.
- **Storage:** NFS storage class (`nfs`), `filesystem` backend, ~36 GiB total
  across registry (20 GiB), trivy (5 GiB), database (5 GiB), jobservice logs
  (5 GiB) and redis (1 GiB) PVCs. PVCs are kept on uninstall
  (`resourcePolicy: keep`).
- **TLS:** disabled in-chart (`expose.tls.enabled: false`, `internalTLS.enabled:
  false`). Cloudflare terminates TLS externally; containerd pulls from inside
  the cluster use plain HTTP against the in-cluster service (see below).

## Access

Initial admin credentials (rotate immediately after first login):

- **User:** `admin`
- **Password:** `Harbor12345` (the Harbor default)

The password lives in the SealedSecret `harbor-core-secret`
(`harbor-secret.yaml`), key `HARBOR_ADMIN_PASSWORD`. To rotate it:

1. Log in to the UI, open **Administration → Configuration**, or change it via
   the user profile, to a new strong password.
2. Re-seal the new value into `harbor-secret.yaml` (see *How to generate the
   SealedSecret*) and let ArgoCD sync.
3. Update the password in
   `ansible/inventories/k3s/inventory.yml` (`registries_config_yaml`) so
   containerd cluster pulls keep working.

## Post-deploy setup (REQUIRED)

These steps are not automated and must be done once Harbor is healthy:

1. **Create a private project.** UI → **Projects → New Project**, give it a
   name (e.g. `library`), uncheck **Public access** (private).
2. **Create a robot account for cluster pulls.** In the project → **Robot
   Accounts → Add Robot Account**, grant **Pull** permission only. Copy the
   generated secret.
3. **Switch the cluster pull config to the robot account.** Edit
   `ansible/inventories/k3s/inventory.yml` and replace the `admin` /
   `Harbor12345` credentials in `registries_config_yaml` with the robot
   account name and secret, e.g.:

   ```yaml
   configs:
     harbor-k3s.lapis-dev.work:
       auth:
         username: robot$<project>+<name>
         password: <robot-secret>
   ```

   Then re-apply it to every node (see next section) and `systemctl restart
   k3s` (server) / `k3s-agent` (agent). Using a robot account instead of
   `admin` limits blast radius to pull-only.

## How cluster pulls work

containerd on every k3s node reads `/etc/rancher/k3s/registries.yaml`. That
file is written by the `k3s-io/k3s-ansible` collection's `prereq` role from the
`registries_config_yaml` var in `ansible/inventories/k3s/inventory.yml` (see
`ansible/.opencode/exploration` / the collection source for details). The
configured mirror maps the public hostname to the in-cluster service:

```yaml
mirrors:
  harbor-k3s.lapis-dev.work:
    endpoint:
      - "http://harbor-core.harbor.svc.cluster.local"
```

So when a pod references `harbor-k3s.lapis-dev.work/library/nginx:1.27`,
containerd talks **directly** to `http://harbor-core.harbor.svc.cluster.local`
(namespace `harbor`, service `harbor-core`, port 80). The traffic never leaves
the cluster and never traverses the Cloudflare Tunnel, which means:

- **No 100 MiB Cloudflare request limit** on pulls.
- **No TLS round-trip** — internal service has `internalTLS.enabled: false`.

> **Service name note:** the Harbor chart names the core service
> `<release>-core`. With release name `harbor` the service is `harbor-core`
> (confirmed from the chart `harbor.core` helper:
> `printf "%s-core" (include "harbor.fullname" .)`), **not** `harbor`. The
> mirror endpoint must use `harbor-core` or pulls will fail DNS resolution.

The ansible collection only lays `registries.yaml` down during `make
install-k3s`. To apply a change (e.g. rotating to the robot account) without
reinstalling, either re-run the `prereq`/`site` play or copy the file to each
node and restart k3s:

```bash
sudo cp registries.yaml /etc/rancher/k3s/registries.yaml
sudo systemctl restart k3s        # on the server node
sudo systemctl restart k3s-agent  # on agent nodes
```

## How to generate the SealedSecret

`harbor-secret.yaml` already contains a real, cluster-encrypted SealedSecret
generated against this cluster's sealed-secrets controller (`kube-system`). If
you need to regenerate it (e.g. after rotating the admin password or the
secret key), run from the repo root:

```bash
kubectl -n harbor create secret generic harbor-core-secret \
  --from-literal=HARBOR_ADMIN_PASSWORD='Harbor12345' \
  --from-literal=secretKey='<your-16-char-secretKey>' \
  # generate with: openssl rand -hex 8 — store the real value in a password manager, NOT in git
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace=kube-system --format yaml \
  > argocd/k3s/apps/infrastructure/harbor/harbor-secret.yaml
```

Notes:

- `secretKey` **must** be exactly 16 characters; it encrypts credentials at
  rest. Losing it makes existing encrypted data unreadable — back it up.
- The SealedSecret is namespace-scoped to `harbor` and will be unsealed by the
  sealed-secrets controller once ArgoCD creates the namespace.
- The internal PostgreSQL password (`<db-password>`) is set inline in
  `application.yaml` under `database.internal.password`. The Harbor chart has
  no existing-secret option for the **internal** database (it always generates
  the `POSTGRESQL_PASSWORD` from this value), so it cannot be sourced from the
  SealedSecret. If you want it out of git, switch to an external database and
  use `database.external.existingSecret`.

## docker CLI usage

External push/pull goes through the Cloudflare Tunnel hostname (HTTPS):

```bash
docker login harbor-k3s.lapis-dev.work -u admin    # initial; use a robot account for CI
docker pull nginx:1.27
docker tag nginx:1.27 harbor-k3s.lapis-dev.work/library/nginx:1.27
docker push harbor-k3s.lapis-dev.work/library/nginx:1.27
```

Then reference it from a manifest:

```yaml
containers:
  - name: nginx
    image: harbor-k3s.lapis-dev.work/library/nginx:1.27
```

## Known caveats

- **100 MiB limit on external pushes.** Cloudflare's free-tier request size
  cap (~100 MiB) applies to docker pushes that traverse the tunnel from an
  external docker client. Workarounds: push in smaller layers, push from a pod
  inside the cluster (`kubectl run` a builder that targets
  `http://harbor-core.harbor.svc.cluster.local`), or mirror from a registry
  that supports chunked upload. Cluster-side pulls are unaffected.
- **PostgreSQL on NFS.** The internal Postgres PVC is backed by NFS. Under
  heavy concurrent writes NFS file-locking can occasionally corrupt the WAL.
  For a light home lab this is fine; if DB errors appear, move the `database`
  PVC to the `longhorn` storage class, or switch to an external Postgres
  (cloudnative-pg is already installed in the cluster).
- **`updateStrategy: Recreate`.** NFS PVCs are `ReadWriteOnce`; `Recreate`
  avoids two pods fighting over the same mount during a rolling update.
- **Cloudflare Tunnel hostname mapping.** `harbor-k3s.lapis-dev.work` must be
  mapped to the Harbor ingress in the cloudflare-tunnel config (host route →
  service `harbor-core` / the Harbor ingress). This is configured out of band
  and not part of this manifest set.
- **Trivy DB download.** On first start Trivy pulls a large vulnerability DB
  from the public internet. Needs outbound connectivity; on air-gapped clusters
  set `trivy.skipUpdate: true` and provision the DB manually.
