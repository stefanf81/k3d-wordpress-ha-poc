#!/usr/bin/env bash
# Deletes one WordPress pod and checks that the site keeps answering while
# Kubernetes replaces it. Fails if more than MAX_FAILED_REQUESTS (default 0)
# requests fail during the disruption.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands curl
require_cluster

echo "Current WordPress replicas:"
kubectl get pods -n "$NS" -l app=wordpress -o wide

echo
echo "HTTP check before failure:"
curl --fail --silent --show-error --output /dev/null --max-time 10 \
  --write-out "HTTP %{http_code}\n" \
  "$SITE_URL/"

POD="$(
  kubectl get pods -n "$NS" -l app=wordpress \
    -o jsonpath='{.items[0].metadata.name}'
)"

echo
echo "Deleting WordPress pod: $POD"
kubectl delete pod -n "$NS" "$POD" --wait=false

echo
echo "Checking the site while Kubernetes replaces the pod:"
result=0
probe_site_during_failure 10 || result=$?

echo
echo "Waiting for the Deployment to return to 3 ready replicas..."
kubectl rollout status deployment/wordpress \
  -n "$NS" \
  --timeout=240s

echo
echo "New placement:"
kubectl get pods -n "$NS" -l app=wordpress -o wide

exit "$result"
