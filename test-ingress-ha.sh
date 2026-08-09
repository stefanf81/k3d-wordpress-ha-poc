#!/usr/bin/env bash
set -euo pipefail

echo "Current Traefik replicas:"
kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=traefik \
  -o wide

echo
echo "HTTP check before failure:"
curl --fail --silent --show-error -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://localhost:8080/

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
for i in $(seq 1 10); do
  code="$(
    curl --silent --location \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time 5 \
      http://localhost:8080/ || true
  )"
  printf "request %02d -> HTTP %s\n" "$i" "$code"
  sleep 1
done

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
