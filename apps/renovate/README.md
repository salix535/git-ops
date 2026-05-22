# Renovate

Self-hosted [Renovate](https://docs.renovatebot.com/) that scans this repository
once a week and opens pull requests when dependency updates are available
(Helm charts and container images), including major versions.

## How it works

Renovate runs as a Kubernetes `CronJob` on the **minipc** cluster (in its own
`renovate` namespace). Each run spins up a short-lived pod that:

1. Clones `salix535/git-ops`.
2. Reads the rules from `renovate.json` at the repo root.
3. Compares every detected dependency against its upstream source.
4. Opens / updates GitHub pull requests for available updates.
5. Maintains the **Dependency Dashboard** issue on GitHub.
6. Exits.

It does **not** run continuously and needs no Kubernetes API access — it only
talks to GitHub and to upstream registries / Helm repos.

## Schedule

`0 13 * * 0` — every **Sunday at 13:00 Europe/Belgrade**.

The CronJob is the only thing controlling cadence; `renovate.json` has no
`schedule` of its own, so whenever the job fires Renovate is free to act.

## Files

| File | Purpose |
|------|---------|
| `Application.yaml` | ArgoCD Application (project `minipcs`) — deploys `manifests/` to the minipc `renovate` namespace |
| `manifests/cronjob.yaml` | The weekly CronJob (image, schedule, resources) |
| `manifests/configmap.yaml` | Global / self-hosted config as env vars (platform, repo, git author) |
| `manifests/sealed-secret.yaml` | Encrypted GitHub token (`renovate-github-token`) |
| `/renovate.json` (repo root) | The actual update **rules** — managers, package rules, version policy |

### Config split

- **`renovate.json`** (repo root) holds *what to update and how*. It is
  version-controlled and diffable, and Renovate auto-discovers it on clone.
- **`configmap.yaml`** holds *self-hosted* settings only — which repo, which
  platform, the git author. No update rules here.

## GitHub token

The CronJob mounts a secret `renovate-github-token` (key `GITHUB_TOKEN`) as the
`RENOVATE_TOKEN` env var. It is stored encrypted as a `SealedSecret`.

To (re)create it — PAT needs `repo` scope (classic) or Contents + Pull requests
write (fine-grained) on `salix535/git-ops`:

```
kubectl create secret generic renovate-github-token --namespace renovate \
  --from-literal=GITHUB_TOKEN=<YOUR_PAT> --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets --controller-namespace kube-system \
  > apps/renovate/manifests/sealed-secret.yaml
```

`--dry-run=client` means nothing is sent to the cluster — it only renders YAML
that `kubeseal` then encrypts. Run it with the kubectl context on the minipc.

## What Renovate manages

Three managers are enabled (`enabledManagers` in `renovate.json`):

- **`argocd`** — Helm chart versions (`targetRevision`) in every
  `apps/**/Application.yaml`: wordpress, open-webui, loki, promtail,
  pihole (rpi2/rpi3), sealed-secrets.
- **`kubernetes`** — container images in `apps/**/manifests/*.yaml`
  (n8n, searxng, openclaw, busybox). `pinDigests` is on, so images are pinned
  to a digest and the digest is refreshed weekly.
- **`custom.regex`** — the pihole image tag in `apps/pihole/rpi{2,3}/values.yaml`.

### Not managed (intentionally)

Anything under `ghcr.io/salix535/**` is disabled — the list-service chart/image
and the claude-agent image are your own artifacts, released manually.

### Version notes

- **SearXNG** uses `YYYY.M.D-githash` tags; a regex `versioning` rule lets
  Renovate sort them.
- **openclaw** uses a rolling `:slim` tag with no versioned variant — tracked
  via digest only.
- Major-version updates are raised as PRs (not auto-merged); nothing is
  auto-merged.

## Operations

**Trigger a run manually** (don't wait for Sunday):

```
kubectl create job --from=cronjob/renovate renovate-manual -n renovate
kubectl logs -n renovate job/renovate-manual -f
```

**Dependency Dashboard** — Renovate maintains a single GitHub issue listing
every detected update, including ones not yet PR'd. Watch that issue to get
notified when something can be updated.

**Renovate updates itself** — the `renovate/renovate` image in `cronjob.yaml`
is picked up by the `kubernetes` manager, so Renovate bumps its own version.

## Phase 2 (not implemented)

Planned follow-up: a local model that summarizes the diff between the current
and proposed versions and injects that into the PR description.
