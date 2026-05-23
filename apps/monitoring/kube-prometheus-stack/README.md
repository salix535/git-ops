# kube-prometheus-stack

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) — Grafana, Prometheus, Alertmanager, the Prometheus Operator, node-exporter, and kube-state-metrics — on the minipc cluster. Shares the `monitoring` namespace with the already-GitOps-managed `loki` and `promtail` Applications. Replaces a prior manual `helm install` from the LocalInfra repo (see [`MIGRATION_PLAN.md`](./MIGRATION_PLAN.md) for the full migration history).

## Layout

```
MIGRATION_PLAN.md                          # one-time migration record, leave in place
Application.yaml                           # Argo App — multi-source: chart + values + manifests
values.yaml                                # Helm values
manifests/
  sealed-secret-grafana-admin.yaml         # → Secret grafana-admin (admin-user, admin-password)
```

## How it's managed

- **GitOps via ArgoCD.** Root app-of-apps discovers `Application.yaml`; `automated / prune / selfHeal` is on.
- **AppProject:** `minipcs`. Permits `https://prometheus-community.github.io/helm-charts` and the `monitoring` namespace. The existing `clusterResourceWhitelist` (Namespace, CRD, ClusterRole/Binding, Mutating/ValidatingWebhookConfiguration) already covers everything this chart ships.
- **Multi-source pattern.** Source 1 is the upstream Helm chart, source 2 is this repo at `ref: values` so the chart can pull `values.yaml` via `$values/…`, source 3 is the `manifests/` directory so Argo applies the SealedSecret alongside the chart. Same shape as `apps/authentik/`.
- **Server-side apply** is on — kube-prometheus-stack CRDs exceed the client-side `last-applied-configuration` annotation limit.
- **No sync wave.** Loki and Promtail (`project: default`) and this app have no hard ordering constraint; the Grafana sidecar tolerates the Loki datasource ConfigMap appearing later.

## What lives where

| Resource | Namespace | Managed by |
|---|---|---|
| `kube-prometheus-stack` Helm release — Grafana, Prometheus, Alertmanager, operator, node-exporter, kube-state-metrics, ServiceMonitors, CRDs, RBAC, admission webhooks | `monitoring` / cluster-scoped | `kube-prometheus-stack` Application |
| `grafana-admin` Secret | `monitoring` | sealed-secrets controller (decrypted from `manifests/sealed-secret-grafana-admin.yaml`) |
| Operator-created Prometheus / Alertmanager StatefulSets, their PVCs, generated Services and tokens | `monitoring` | the Prometheus Operator (not in git) |
| Loki SingleBinary, `loki-datasource` ConfigMap, `longhorn-single-replica` StorageClass | `monitoring` / cluster-scoped | `loki` Application — **external prerequisite from this app's POV** |
| Promtail DaemonSet | `monitoring` | `promtail` Application — external prerequisite |
| The `monitoring` Namespace itself | cluster-scoped | first Application to sync (`CreateNamespace=true` on all three) — not owned exclusively by any one app |

Operator-created pods/PVCs/services are deliberately not in git — Argo never sees them, so `prune` can't touch them.

## Ingress

Grafana is exposed at `http://grafana.lan` via Traefik ingress class `traefik`. Add an A record `grafana.lan → 10.0.5.150` in pihole (same Traefik LB IP used by `authentik.lan`). HTTP only — TLS is not configured.

The old LocalInfra setup served Grafana under `/monitoring/` (with `grafana.ini.server.{root_url,serve_from_sub_path}` overrides). This setup drops that and serves at `/` — no `grafana.ini` overrides needed.

Prometheus and Alertmanager are **cluster-internal only** — no `Ingress`, no `LoadBalancer`. In-cluster consumers reach them at the operator-generated `ClusterIP` services. If external access is ever needed, add it in a separate change.

## Secrets

| Secret | Keys | Source of truth |
|---|---|---|
| `grafana-admin` | `admin-user`, `admin-password` | random 24-byte password generated locally at seal time |

To (re-)seal — run on your workstation with kubectl pointed at the minipc cluster:

```bash
ADMIN_PW="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

kubectl create secret generic grafana-admin \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$ADMIN_PW" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace kube-system \
    --controller-name sealed-secrets \
    --format yaml \
> apps/monitoring/kube-prometheus-stack/manifests/sealed-secret-grafana-admin.yaml

echo "Grafana admin user:     admin"
echo "Grafana admin password: $ADMIN_PW"
unset ADMIN_PW
```

Commit and push — `selfHeal` rolls the SealedSecret, the controller decrypts it, and Grafana picks up the new password on its next pod restart (`kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana`).

## Storage

All three components use the `longhorn-single-replica` StorageClass:

| PVC | Size | Component |
|---|---|---|
| `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` | 10Gi | Prometheus TSDB (retention `30d` / `5GB`) |
| Grafana PVC | 5Gi | Grafana SQLite DB — users, API keys, alerting state |
| `alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0` | 2Gi | Alertmanager silences and notification state |

`longhorn-single-replica` is declared once on the cluster in `apps/monitoring/loki/manifests/longhorn-sc.yaml` and is **owned by the `loki` Application**. It is an external prerequisite from this app's point of view — this app's `manifests/` deliberately does not declare it, so Argo's prune scope on this app can never touch it.

## Datasources

Two datasources show up in Grafana automatically; no manual setup after first login.

- **Prometheus** — provisioned by the kube-prometheus-stack chart itself.
- **Loki** — auto-provisioned via the `loki-datasource` ConfigMap (label `grafana_datasource: "1"`) that already lives in the `monitoring` namespace and is owned by the `loki` Application. The Grafana sidecar runs with `searchNamespace: ALL`, finds it, and provisions it on Grafana startup.

Do not duplicate the Loki datasource in `values.yaml`.

## Day-2

- **Chart upgrade:** Renovate bumps `targetRevision` in `Application.yaml` (the `argocd` manager matches `^apps/.+/Application\.yaml$`). Merge and Argo rolls. CRD changes go through server-side apply.
- **Add a dashboard:** create a ConfigMap in any namespace with label `grafana_dashboard: "1"` and a single key whose value is the dashboard JSON. The Grafana sidecar discovers it and provisions it; no Grafana restart needed.
- **Rotate the admin password:** re-seal per the *Secrets* section, then `kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana`.
- **Add a scrape target:** create a `ServiceMonitor` or `PodMonitor` in the target app's namespace — the Prometheus Operator picks it up automatically (default `serviceMonitorSelector` / `podMonitorSelector` is empty, meaning select-all).

## Why no `ignoreDifferences` block

Unlike CNPG, the Prometheus Operator does not write back into the `Prometheus` / `Alertmanager` `.spec` objects in a way that diverges from `values.yaml`. If Argo starts flagging drift on these resources after the first sync and `selfHeal` keeps re-syncing the same handful of fields, add the block then — with `group: monitoring.coreos.com`, `kind: Prometheus` / `Alertmanager`, and `managedFieldsManagers: [prometheus-operator]`. Do not pre-emptively add one.

## Why no LoadBalancer / external ingress for Prometheus and Alertmanager

Cluster-internal access is sufficient: Grafana reaches Prometheus via the in-cluster Service, and Alertmanager is consumed by Prometheus. Exposing them externally adds attack surface for no gain today. If external access is ever needed, add it in a separate change.
