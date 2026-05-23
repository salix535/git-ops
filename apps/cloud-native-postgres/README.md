# cloud-native-postgres

[CloudNativePG](https://cloudnative-pg.io/) operator and the `shared-pg` PostgreSQL cluster. Hosts the `authentik` database (and any future databases) on the minipc cluster.

## Layout

```
operator/
  Application.yaml      # Argo App — installs the CNPG operator Helm chart
  values.yaml           # Helm values for the operator
cluster/
  Application.yaml      # Argo App — applies the manifests below
  manifests/
    cluster.yaml                       # the Cluster CR (shared-pg)
    sealedsecret-pg-superuser.yaml     # → Secret pg-superuser
    sealedsecret-authentik-pg-app.yaml # → Secret authentik-pg-app
```

## How it's managed

- **GitOps via ArgoCD.** The root app-of-apps discovers both `Application.yaml` files; `automated / prune / selfHeal` is on.
- **AppProject:** `minipcs`. Permits the chart repo + the `cnpg-system` and `postgres` namespaces, and whitelists the cluster-scoped resources CNPG ships (CRDs, ClusterRoles, admission webhooks).
- **Sync order:** sync-wave `0` (operator + CRDs) before wave `1` (the cluster). Argo waits for the operator Application to be Healthy before syncing the cluster, so CRDs always exist when the `Cluster` CR is applied.
- **Server-side apply** is on for both Apps — CNPG CRDs exceed the client-side last-applied annotation limit.

## What lives where

| Resource | Namespace | Managed by |
|---|---|---|
| CNPG operator (Deployment, webhooks, RBAC, CRDs) | `cnpg-system` | `cnpg-operator` Application |
| `Cluster shared-pg` (CR) | `postgres` | `cnpg-cluster` Application |
| `shared-pg-*` Pods, PVCs, Services, generated certs | `postgres` | the operator (not in git) |
| `pg-superuser`, `authentik-pg-app` Secrets | `postgres` | sealed-secrets controller (decrypted from git) |

Operator-created pods/PVCs/services/generated secrets are deliberately not in git — Argo never sees them, so `prune` can't touch them.

## Secrets

Credentials live in git as `SealedSecret` resources, decrypted in-cluster by the `sealed-secrets` controller in `kube-system`. To rotate a password:

```bash
kubectl create secret generic pg-superuser -n postgres \
  --type kubernetes.io/basic-auth \
  --from-literal=username=postgres \
  --from-literal=password='NEW_PASSWORD' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml \
> cluster/manifests/sealedsecret-pg-superuser.yaml
```

Same pattern for `authentik-pg-app` (with `username=authentik`). Commit and push — `selfHeal` rolls the SealedSecret and the controller re-decrypts.

Note: CNPG reads `authentik-pg-app` only at initial bootstrap; rotating it after the fact also requires `ALTER USER authentik WITH PASSWORD …` inside Postgres.

## Storage

`shared-pg` uses the pre-existing `longhorn-strict-local` StorageClass (Longhorn, `numberOfReplicas: 1`, `strict-local`, `reclaimPolicy: Retain`). That StorageClass is **shared with MongoDB** and is intentionally not declared by this app — it is an external prerequisite. Do not bring it under this app's prune scope.

## Day-2

- **Operator / chart upgrade:** Renovate bumps `targetRevision` in `operator/Application.yaml`; merge and Argo rolls.
- **PostgreSQL minor / major upgrade:** bump the tag on `imageName` in `cluster/manifests/cluster.yaml`; CNPG performs a rolling update.
- **Add a database:** add a `Database` CR (`databases.postgresql.cnpg.io`), not by editing `bootstrap.initdb` — `initdb` only runs on first install.
- **Backups:** the `backup:` block in `cluster.yaml` is intentionally commented out. Add an S3/MinIO destination and uncomment when PITR is needed.

## Connecting

In-cluster psql (the `pg_hba` allows `10.0.0.0/8`):

```bash
kubectl -n postgres run psql --rm -it --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:18.4 \
  --env=PGPASSWORD="$(kubectl -n postgres get secret pg-superuser -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h shared-pg-rw -U postgres
```

The CNPG `kubectl cnpg` plugin is also handy: `kubectl cnpg status shared-pg`.

## Why the `ignoreDifferences` block exists

The `cnpg-cluster` Application sets:

```yaml
ignoreDifferences:
  - group: postgresql.cnpg.io
    kind: Cluster
    managedFieldsManagers: [cloudnative-pg]
```

CNPG writes its own defaults back into the `Cluster` `.spec` (encoding, logLevel, archive parameters, extra `postgresql.parameters`, …). Without this, Argo flags those as drift and `selfHeal` fights the operator. Required on every CNPG + Argo deployment, not specific to this setup.
