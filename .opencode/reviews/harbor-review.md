# Harbor Deployment Review

**Subject:** Harbor container registry implementation (ArgoCD + Ansible inventory)
**Date:** 2026-06-27
**Scope:** `argocd/k3s/apps/infrastructure/harbor/*`, `ansible/inventories/k3s/inventory.yml`, `argocd/k3s/apps/infrastructure/kustomization.yaml`

## Summary

The implementation is technically correct and well-documented. Helm values were
verified live against chart `goharbor/harbor` v1.19.1: the global
`updateStrategy.type: Recreate` IS consumed (applies to the 2 PVC-backed
deployments — registry + jobservice — exactly as the chart intends), notary is
not enabled by default in this chart version (no concern), and the registries.yaml
mirror+auth block is syntactically valid k3s spec. Sync-wave placement (3) is
correct relative to dependencies (sealed-secrets -1, nfs-provisioner 1,
cloudflare-tunnel-ingress-controller 1).

**However, two real secrets are committed in plaintext and should be addressed
before commit.** Neither blocks functional correctness, but both weaken the
secret posture that the SealedSecret pattern was specifically introduced to
provide.

## Severity Definitions
- **CRITICAL** — blocks commit (correctness/security bug)
- **HIGH** — should fix before commit (real risk to posture/maintainability)
- **MEDIUM** — should fix soon (caveat, weak mitigation)
- **LOW** — informational, polish

---

## CRITICAL ISSUES

None. The implementation deploys and functions correctly.

---

## HIGH ISSUES (should fix before commit)

### H1. `secretKey` value leaked in plaintext in README
**File:** `argocd/k3s/apps/infrastructure/harbor/README.md:115`

The kubeseal regeneration example contains the *actual* secretKey value:

```bash
--from-literal=secretKey='harborSecretKey!'
```

The same value is encrypted into `harbor-secret.yaml`. The README itself states
(line 123-124):

> `secretKey` **must** be exactly 16 characters; it encrypts credentials at
> rest. Losing it makes existing encrypted data unreadable — back it up.

Committing the plaintext secretKey next to its SealedSecret defeats the purpose
of sealing it. Anyone with read access to the repo can decrypt every credential
Harbor has ever encrypted with this key. The "back it up" advice is undermined
because the value is now permanently in git history.

**Fix:** Replace the literal with a placeholder and add a note to store the real
value in a password manager:

```bash
--from-literal=secretKey='<your-16-char-secretKey>'   # generate with: openssl rand -hex 8
# Store the real value in your password manager — it is NOT recoverable from git.
```

Since the SealedSecret was already generated with the real value, you must also
**rotate the secretKey** (re-seal with a fresh random 16-char key, and accept
that any data already encrypted with the old key becomes unreadable — fine here
since Harbor has not been deployed yet).

### H2. Internal PostgreSQL password committed in plaintext
**File:** `argocd/k3s/apps/infrastructure/harbor/application.yaml:44`

```yaml
database:
  internal:
    password: harborDbPass123   # plaintext, real value, in git
```

Also leaked in `README.md:127`. The README acknowledges the limitation (lines
127-132) and suggests switching to `database.external.existingSecret` or
cloudnative-pg (which is already installed at sync-wave -2). The
acknowledgement is good, but the actual secret is still in git, including in
README.

For a home lab this is borderline acceptable, but two cheap improvements exist:

1. **Rotate the value** to a high-entropy string (e.g. `openssl rand -base64 24`)
   so it is not a guessable dictionary word, AND
2. **Remove it from the README** (line 127 references `harborDbPass123`
   literally — replace with `<db-password>`).

A more thorough fix is to switch the `database` block to external via
cloudnative-pg, but that is a larger change and not required for initial commit.

---

## MEDIUM ISSUES (should fix soon)

### M1. Default admin password `Harbor12345` is publicly documented and the tunnel is internet-reachable
**Files:** `harbor-secret.yaml` (encrypted `Harbor12345`),
`README.md:26,114`, `inventory.yml:78`

The README says "Initial admin credentials (rotate immediately after first
login)" and notes the registry is "only reachable via the tunnel hostname" — but
Cloudflare Tunnel IS reachable from the public internet (otherwise external
`docker login` would not work, per README line 137-142). Until rotation happens,
anyone who can DNS-resolve `harbor-k3s.lapis-dev.work` AND reads the Harbor
public docs (which state the default password is `Harbor12345`) can log in as
admin.

Mitigations in place: rotation is documented; README recommends switching to a
pull-only robot account. Weakness: rotation is purely manual with no verification
step, and the kubeseal regen example hard-codes `Harbor12345` so re-running it
preserves the default.

**Recommendation:** Add a one-line post-deploy checklist item that the operator
must confirm completion of before considering the deployment "done" (e.g. a
checkbox in the README post-deploy section). For stronger posture, generate a
random initial password in the SealedSecret and put the actual value only in a
password manager.

### M2. No resource requests/limits on Harbor components
**File:** `argocd/k3s/apps/infrastructure/harbor/application.yaml`

The sibling `grafana/application.yaml` sets CPU/memory requests and limits
(lines 63-69). The Harbor Application sets none. Harbor runs 6+ components
(core, portal, registry, jobservice, trivy, postgres, redis) and can consume
significant memory — especially Trivy during DB refresh. On a 3-node home lab
this risks node pressure or eviction.

**Recommendation:** Add at least requests (cpu/memory) for the heavier
components, matching the pattern grafana established. Even rough values help the
scheduler. Example:

```yaml
core:      { resources: { requests: { cpu: 50m,  memory: 128Mi } } }
registry:  { resources: { requests: { cpu: 50m,  memory: 128Mi } } }
trivy:     { resources: { requests: { cpu: 100m, memory: 256Mi } } }
```

---

## LOW ISSUES / INFORMATIONAL

### L1. Plaintext `admin/Harbor12345` in `inventory.yml:77-78`
Matches the repo's existing "no vault" convention (AGENTS.md confirms this is
intentional for the home lab). Documented to be replaced with a robot account.
Acceptable as-is. ✓

### L2. Broken path reference in README
**File:** `README.md:70` — references `ansible/.opencode/exploration` which does
not exist in the repo. Either remove the reference or create the directory.

### L3. `kustomization.yaml` ordering is cosmetic
Harbor is inserted at line 16 between grafana (wave 2) and argocd-ingress (wave
3). Order within `resources:` does not affect ArgoCD sync order (the
`sync-wave` annotation does), but grouping wave-3 apps together would be tidier.
Purely cosmetic.

### L4. HTTP inside the cluster (no internalTLS)
Documented (README lines 17-19, 65-86). Any pod in the cluster can MITM registry
pulls. Acceptable for a single-tenant home lab; worth a one-line caveat in the
README security section if you ever expand users.

### L5. `registries_config_yaml` block is syntactically correct
Verified: `mirrors.<host>.endpoint` (list) and `configs.<host>.auth.{username,
password}` match the k3s spec. Auth is keyed by the image hostname
(`harbor-k3s.lapis-dev.work`), which is correct — containerd matches auth by
original image hostname, not by mirror endpoint. ✓

---

## Verified Correct (positive findings)

| Concern | Result |
|---|---|
| `updateStrategy: Recreate` (global) is consumed by chart | ✅ Verified via `helm template` — applies to the 2 PVC-backed deployments (registry, jobservice) |
| Notary enabled-by-default concern | ✅ Moot — v1.19.1 does not enable notary by default |
| `existingSecretSecretKey` + key `secretKey` | ✅ Matches SealedSecret keys |
| `existingSecretAdminPassword` + key `HARBOR_ADMIN_PASSWORD` | ✅ Matches SealedSecret keys |
| SealedSecret name `harbor-core-secret` | ✅ Matches all refs in application.yaml |
| Admin password consistency: README ↔ inventory | ✅ Both `Harbor12345` |
| sync-wave ordering vs dependencies | ✅ Harbor(3) > sealed-secrets(-1), nfs-provisioner(1), cloudflare-tunnel(1) |
| Finalizer, syncPolicy, retry, ServerSideApply | ✅ Matches grafana pattern exactly |
| `kustomization.yaml` harbor entry | ✅ Added at line 16 |
| NFS + PostgreSQL caveat documented | ✅ README lines 161-165 |
| 100 MiB external push limit documented | ✅ README lines 153-160 |
| In-cluster service bypasses Cloudflare 100 MiB limit | ✅ Documented README lines 65-92 |
| Service name `harbor-core` (not `harbor`) | ✅ Verified, documented with chart helper source |
| SealedSecret namespace creation ordering | ✅ CreateNamespace=true on Application handles it |
| `ingress.className: cloudflare-tunnel` (Harbor-specific key) | ✅ Correct for Harbor chart (vs grafana's `ingressClassName`) |

---

## Verdict: REQUEST CHANGES

Two HIGH issues (H1, H2) should be resolved before commit. Both are about
secrets committed in plaintext — H1 (secretKey) is the more important one
because the README explicitly tells the reader to back up that key, yet it is
committed alongside the encrypted form. Neither blocks functional correctness;
both are 5-minute fixes (rotate value + replace literal with placeholder).

If the operator accepts the home-lab trade-off and explicitly waives H2 (DB
password inline), H1 should still be fixed because it directly contradicts the
README's own security guidance.

After H1 (and ideally H2) are fixed, the implementation is ready to commit.
M1/M2 can be follow-ups.
