#!/usr/bin/env bash
set -euo pipefail

echo "k3d/Kubernetes node architectures:"
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.operatingSystem'

echo
echo "WordPress pod placement and images:"
kubectl get pods \
  -n wordpress-poc \
  -l app=wordpress \
  -o wide

echo
kubectl get pods \
  -n wordpress-poc \
  -l app=wordpress \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  image="}{.spec.containers[0].image}{"\n"}{end}'

echo
echo "PHP version from a WordPress replica:"
kubectl exec \
  -n wordpress-poc \
  deployment/wordpress \
  -- php -v

echo
echo "If ARCH is arm64, the PoC is running natively on Apple Silicon."
