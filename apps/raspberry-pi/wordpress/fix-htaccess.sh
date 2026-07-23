#!/bin/bash
set -euo pipefail

export KUBECONFIG="$HOME/.kube/config-rpi-cluster"

POD=$(kubectl get pods -n wordpress -l app.kubernetes.io/name=wordpress -o jsonpath='{.items[0].metadata.name}')

echo "Creating .htaccess on pod $POD..."
kubectl exec -n wordpress "$POD" -- bash -c "cat > /bitnami/wordpress/.htaccess << 'EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF"

echo "Done."
