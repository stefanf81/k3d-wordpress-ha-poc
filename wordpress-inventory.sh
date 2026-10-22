#!/usr/bin/env bash
# Runs the on-demand WP-CLI inventory Job and saves its report under
# ./reports/inventory/.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cluster

kubectl apply -f "$ROOT_DIR/k8s/security.yaml" >/dev/null
apply_wp_config_configmap
kubectl delete job wordpress-inventory \
  -n "$NS" \
  --ignore-not-found=true \
  --cascade=foreground >/dev/null
kubectl apply -k "$ROOT_DIR/k8s/inventory"

wait_for_job wordpress-inventory "$INVENTORY_TIMEOUT"

mkdir -p "$ROOT_DIR/reports/inventory"
REPORT="$ROOT_DIR/reports/inventory/wordpress-inventory-$(date +%Y%m%d%H%M%S).txt"

kubectl logs \
  -n "$NS" \
  job/wordpress-inventory | tee "$REPORT"

echo
echo "Inventory saved:"
echo "  $REPORT"
