#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl config use-context k3d-wordpress-ha-poc >/dev/null

echo "Re-running WordPress/plugin bootstrap..."
kubectl delete job wordpress-bootstrap \
  -n wordpress-poc \
  --ignore-not-found=true >/dev/null

kubectl apply -f "$ROOT_DIR/k8s/bootstrap.yaml"

kubectl wait \
  --for=condition=complete \
  job/wordpress-bootstrap \
  -n wordpress-poc \
  --timeout=600s

kubectl logs -n wordpress-poc job/wordpress-bootstrap
