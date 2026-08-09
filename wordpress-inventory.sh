#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="wordpress-poc"

kubectl apply -f "$ROOT_DIR/k8s/security.yaml" >/dev/null
kubectl delete job wordpress-inventory \
  -n "$NS" \
  --ignore-not-found=true >/dev/null
kubectl apply -f "$ROOT_DIR/k8s/wpcli-inventory.yaml"

kubectl wait \
  --for=condition=complete \
  job/wordpress-inventory \
  -n "$NS" \
  --timeout=300s

mkdir -p "$ROOT_DIR/reports/inventory"
REPORT="$ROOT_DIR/reports/inventory/wordpress-inventory-$(date +%Y%m%d%H%M%S).txt"

kubectl logs \
  -n "$NS" \
  job/wordpress-inventory | tee "$REPORT"

echo
echo "Inventory saved:"
echo "  $REPORT"
