#!/bin/bash
set -euo pipefail

export KUBECONFIG="$HOME/.kube/config-rpi-cluster"

POD=$(kubectl get pods -n wordpress -l app.kubernetes.io/name=wordpress -o jsonpath='{.items[0].metadata.name}')

echo "Copying wp-content to pod $POD..."
cd ~/Downloads/wp-content && tar cf - . | kubectl exec -i -n wordpress "$POD" -- tar xf - -C /bitnami/wordpress/wp-content/

echo "Fixing permissions..."
kubectl exec -n wordpress "$POD" -- find /bitnami/wordpress/wp-content -not -user 1001 -exec chown 1001:1001 {} +

echo "Verifying themes..."
kubectl exec -n wordpress "$POD" -- ls /bitnami/wordpress/wp-content/themes/

echo "Done."
