# kube-prometheus-stack — RPi

Mirror of `apps/monitoring/kube-prometheus-stack/` (minipc) with three deltas:

- `storageClassName: local-path` everywhere (k3s default; no Longhorn on RPi)
- Ingress host is `grafana-rpi.lan`
- k3s control-plane scrapers (`kubeControllerManager`, `kubeScheduler`,
  `kubeProxy`, `kubeEtcd`) disabled — those targets don't exist on k3s
- No Loki/Promtail companion Applications on this cluster

## Grafana admin credentials

See `manifests/sealed-secret-grafana-admin.yaml` for inline kubeseal
instructions. Until that file is replaced with a real SealedSecret, the
Grafana pod will not start; everything else in the stack runs fine.
