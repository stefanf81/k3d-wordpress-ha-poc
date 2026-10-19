#!/usr/bin/env bash
# Shows the architecture the lab runs on. k3d nodes are containers on the
# Docker host, so they use its native architecture: arm64 on Apple Silicon,
# amd64 on most Linux and Intel machines. The images are multi-arch.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cluster

echo "k3d/Kubernetes node architectures:"
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.operatingSystem'

echo
echo "WordPress pod placement and images:"
kubectl get pods \
  -n "$NS" \
  -l app=wordpress \
  -o wide

echo
kubectl get pods \
  -n "$NS" \
  -l app=wordpress \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  image="}{.spec.containers[0].image}{"\n"}{end}'

echo
echo "PHP version from a WordPress replica:"
kubectl exec \
  -n "$NS" \
  deployment/wordpress \
  -c wordpress \
  -- php -v

echo
echo "On Apple Silicon, ARCH arm64 means the lab runs natively (no emulation)."
