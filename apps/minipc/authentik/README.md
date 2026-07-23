# authentik

[authentik](https://goauthentik.io/) IdP on the minipc cluster. Uses the shared CNPG `shared-pg` cluster in the `postgres` namespace (DB and role are provisioned by [cloud-native-postgres](../cloud-native-postgres/README.md), not by this app).

## Layout

```
Application.yaml                       # Argo App — multi-source: chart + values + sealed-secrets
values.yaml                            # Helm values
sealed-secret-secret-key.yaml          # → Secret authentik-secret-key
sealed-secret-pg-credentials.yaml      # → Secret authentik-pg-credentials
```

## How it's managed

- **GitOps via ArgoCD.** Root app-of-apps discovers `Application.yaml`; `automated / prune / selfHeal` is on.
- **AppProject:** `minipcs`. Permits `https://charts.goauthentik.io` and the `authentik` namespace.
- **Sync wave:** `2` — runs after `cnpg-cluster` (wave 1) so `shared-pg-rw.postgres.svc.cluster.local` is reachable.
- **Server-side apply** is on (consistent with other Helm-based apps that ship many resources).

## Ingress

Exposed at `http://authentik.lan` via Traefik ingress class `traefik-public`. Add an A record `authentik.lan → 10.0.5.150` in pihole. HTTP only — TLS is not configured.

## Secrets

Both secrets live in git as `SealedSecret` resources, decrypted in-cluster by the `sealed-secrets` controller in `kube-system`.

| Secret | Key | Source of truth |
|---|---|---|
| `authentik-secret-key` | `secret-key` | random 60 bytes — **permanent, never rotate** (rotating invalidates sessions and breaks on-disk encrypted blobs) |
| `authentik-pg-credentials` | `password` | the password of the `authentik` role in `shared-pg` (same value sealed in `apps/cloud-native-postgres/cluster/manifests/sealedsecret-authentik-pg-app.yaml`, re-sealed for this namespace) |

To (re-)seal:

```bash
# secret-key — generate once, seal, never regenerate
kubectl create secret generic authentik-secret-key -n authentik \
  --from-literal=secret-key="$(openssl rand 60 | base64 -w 0)" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml \
> sealed-secret-secret-key.yaml

# pg-credentials — must match the existing password of the authentik PG role
kubectl create secret generic authentik-pg-credentials -n authentik \
  --from-literal=password='THE_AUTHENTIK_PG_PASSWORD' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml \
> sealed-secret-pg-credentials.yaml
```

Rotating `authentik-pg-credentials` also requires `ALTER USER authentik WITH PASSWORD …` inside Postgres (and updating the CNPG bootstrap secret in `apps/cloud-native-postgres/cluster/manifests/` for consistency).

## Day-2

- **Chart upgrade:** Renovate bumps `targetRevision` in `Application.yaml`; merge and Argo rolls.
- **First-time setup:** open `http://authentik.lan/if/flow/initial-setup/` to create the bootstrap admin. OAuth provider/application/group config is UI-driven.
- **No bundled Redis:** chart `2026.5.0` dropped the Redis dependency — Authentik uses Postgres for cache/broker. If a future major version reintroduces it, declare it disabled here so the bundled Bitnami subchart doesn't get pulled in.
