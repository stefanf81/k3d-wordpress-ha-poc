#!/usr/bin/env bash
# Deletes one Traefik pod and checks that the site keeps answering through
# the other two ingress replicas. Fails if more than MAX_FAILED_REQUESTS
# (default 0) requests fail during the disruption.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands curl
require_cluster

echo "Current Traefik replicas:"
kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=traefik \
  -o wide

echo
echo "HTTP check before failure:"
curl --fail --silent --show-error --output /dev/null --max-time 10 \
  --write-out "HTTP %{http_code}\n" \
  "$SITE_URL/"

POD="$(
  kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=traefik \
    -o jsonpath='{.items[0].metadata.name}'
)"

echo
echo "Deleting Traefik pod: $POD"
kubectl delete pod -n kube-system "$POD" --wait=false

echo
echo "Checking the site while ingress continues on the other replicas:"
result=0
probe_site_during_failure 10 || result=$?

echo
echo "Waiting for Traefik to return to 3 ready replicas..."
kubectl rollout status deployment/traefik \
  -n kube-system \
  --timeout=240s

echo
echo "New placement:"
kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=traefik \
  -o wide

exit "$result"
