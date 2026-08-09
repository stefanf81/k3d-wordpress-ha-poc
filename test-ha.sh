#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="wordpress-poc"

echo "Current WordPress replicas:"
kubectl get pods -n "$NAMESPACE" -l app=wordpress -o wide

echo
echo "HTTP check before failure:"
curl --fail --silent --show-error -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://localhost:8080/

POD="$(
  kubectl get pods -n "$NAMESPACE" -l app=wordpress \
    -o jsonpath='{.items[0].metadata.name}'
)"

echo
echo "Deleting WordPress pod: $POD"
kubectl delete pod -n "$NAMESPACE" "$POD" --wait=false

echo
echo "Checking the site while Kubernetes replaces the pod:"
for i in $(seq 1 10); do
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    http://localhost:8080/ || true)"
  printf "request %02d -> HTTP %s\n" "$i" "$code"
  sleep 1
done

echo
echo "Waiting for the Deployment to return to 3 ready replicas..."
kubectl rollout status deployment/wordpress \
  -n "$NAMESPACE" \
  --timeout=240s

echo
echo "New placement:"
kubectl get pods -n "$NAMESPACE" -l app=wordpress -o wide
