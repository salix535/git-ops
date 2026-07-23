# mongo-db

MongoDB Controllers for Kubernetes (MCK) operator and the `mongodb-rs` 3-member replica set. Cluster-internal MongoDB 8.0 on the minipc cluster.

## Layout

```
operator/
  Application.yaml      # Argo App — installs the MCK Helm chart
  values.yaml           # Helm values for the operator
cluster/
  Application.yaml      # Argo App — applies the manifests below
  manifests/
    replicaset.yaml                 # the MongoDBCommunity CR (mongodb-rs)
    sealedsecret-mongodb-admin.yaml # → Secret mongodb-admin-password
```

## How it's managed

- **GitOps via ArgoCD.** The root app-of-apps discovers both `Application.yaml` files; `automated / prune / selfHeal` is on.
- **AppProject:** `minipcs`. Permits the MCK chart repo and the `mongodb-operator` + `mongodb` namespaces. Cluster-scoped resources the chart ships (CRDs, ClusterRoles, admission webhooks) are already in the project's `clusterResourceWhitelist`.
- **Sync order:** sync-wave `0` (operator + CRDs) before wave `1` (the replica set). Argo waits for the operator Application to be Healthy before syncing the cluster, so CRDs always exist when the `MongoDBCommunity` CR is applied.
- **Server-side apply** is on for both Apps — MCK CRDs exceed the client-side last-applied annotation limit.

## What lives where

| Resource | Namespace | Managed by |
|---|---|---|
| MCK operator (Deployment, webhooks, RBAC, CRDs) | `mongodb-operator` | `mongodb-operator` Application |
| `MongoDBCommunity mongodb-rs` (CR) | `mongodb` | `mongodb-cluster` Application |
| `mongodb-rs-*` Pods, PVCs, Services, generated agent config | `mongodb` | the operator (not in git) |
| `mongodb-admin-password` Secret | `mongodb` | sealed-secrets controller (decrypted from git) |
| `mongodb-admin-scram` Secret | `mongodb` | the operator (not in git) |

Operator-created pods/PVCs/services/generated secrets are deliberately not in git — Argo never sees them, so `prune` can't touch them.

## Secrets

The admin password lives in git as a `SealedSecret`, decrypted in-cluster by the `sealed-secrets` controller in `kube-system`. To create or rotate it (kubectl context = minipc):

```bash
ADMIN_PW="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

kubectl create secret generic mongodb-admin-password \
  --namespace mongodb \
  --from-literal=password="$ADMIN_PW" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace kube-system \
    --controller-name sealed-secrets \
    --format yaml \
> cluster/manifests/sealedsecret-mongodb-admin.yaml

echo "Admin password: $ADMIN_PW"
unset ADMIN_PW
```

Commit and push — `selfHeal` rolls the SealedSecret and the controller re-decrypts. Rotating after the fact also requires updating the SCRAM credentials in MongoDB itself (`db.changeUserPassword('admin', '…')` against the admin DB), since MCK only reads the secret on initial bootstrap of the user.

## Storage

`mongodb-rs` uses the pre-existing `longhorn-strict-local` StorageClass (Longhorn, `numberOfReplicas: 1`, `strict-local`, `reclaimPolicy: Retain`). That StorageClass is **shared with CNPG** and is intentionally not declared by this app — it is an external prerequisite. Do not bring it under this app's prune scope.

## Day-2

- **Operator / chart upgrade:** Renovate bumps `targetRevision` in `operator/Application.yaml`; merge and Argo rolls.
- **MongoDB minor / patch upgrade:** bump `version:` in `cluster/manifests/replicaset.yaml`; MCK performs a rolling restart of the replica set.
- **Add a database / user:** create additional entries under `spec.users` in `replicaset.yaml` (each with its own `passwordSecretRef` SealedSecret), or use `mongosh` against the admin user.
- **Backups:** out of scope for this migration. MCK supports backups via Ops Manager / Cloud Manager — wire that up separately when needed.

## Connecting

In-cluster mongosh one-liner:

```bash
kubectl -n mongodb run mongosh --rm -it --restart=Never \
  --image=mongo:8.0 \
  --env=PW="$(kubectl -n mongodb get secret mongodb-admin-password -o jsonpath='{.data.password}' | base64 -d)" \
  -- mongosh "mongodb://admin:$PW@mongodb-rs-svc.mongodb.svc.cluster.local:27017/admin?replicaSet=mongodb-rs"
```

Apps inside the cluster connect via the same DNS: `mongodb-rs-svc.mongodb.svc.cluster.local:27017`.

## Why the `ignoreDifferences` block exists

The `mongodb-cluster` Application sets:

```yaml
ignoreDifferences:
  - group: mongodbcommunity.mongodb.com
    kind: MongoDBCommunity
    managedFieldsManagers: [mongodb-kubernetes-operator]
```

MCK writes its own defaults back into `MongoDBCommunity.spec` after we apply (agent config, status-derived fields, …). Without this, Argo flags those as drift and `selfHeal` fights the operator. Same pattern as the CNPG Cluster ignoreDifferences. Verify the manager string after the first apply:

```bash
kubectl get mongodbcommunity mongodb-rs -n mongodb -o json \
  | jq '.metadata.managedFields[].manager'
```

If it differs from `mongodb-kubernetes-operator`, update `cluster/Application.yaml`.

## Why no LoadBalancer

The rpi deployment exposed three MetalLB LB IPs (`192.168.1.201/202/203`) for LAN clients. The minipc deployment is intentionally cluster-internal, matching the CNPG/Authentik pattern. If LAN exposure is ever needed, add LB services in a separate sync wave and document the IP allocation.

## Operator HA caveat

The MCK chart's `operator.replicas` field only accepts `0` or `1` (verified against chart 1.8.1). We run a single operator pod. MongoDB itself stays up if the operator restarts — only reconciliation pauses until Argo reschedules it.
