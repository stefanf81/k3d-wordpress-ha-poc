#!/usr/bin/env bash
# Prints the tool, Kubernetes, image and application versions in use,
# including the immutable image IDs behind floating tags.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands docker k3d
require_cluster

echo "=== Local tooling ==="
k3d version
echo
command kubectl version --client
echo

echo "=== Kubernetes / k3s ==="
kubectl version
echo
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.osImage'
echo

echo "=== Traefik ingress ==="
kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=traefik \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image,IMAGE_ID:.status.containerStatuses[0].imageID'
echo

echo "=== Pod images and immutable image IDs ==="
kubectl get pods -n "$NS" \
  -o custom-columns='POD:.metadata.name,CONTAINER:.spec.containers[0].name,IMAGE:.spec.containers[0].image,IMAGE_ID:.status.containerStatuses[0].imageID' \
  --sort-by=.metadata.name
echo

echo "=== WordPress / PHP ==="
kubectl exec -n "$NS" deployment/wordpress -c wordpress -- php -v | head -n 2
kubectl exec -n "$NS" deployment/wordpress -c wordpress -- \
  php -r 'include "/var/www/html/wp-includes/version.php"; echo "WordPress ".$wp_version.PHP_EOL;'
echo

echo "=== MariaDB ==="
kubectl exec -n "$NS" deployment/mariadb -- mariadb --version
echo

echo "=== MariaDB storage ==="
docker volume inspect "$MARIADB_DATA_VOLUME" \
  --format 'Name={{.Name}} Driver={{.Driver}} Mountpoint={{.Mountpoint}}'
echo "lower_case_table_names=$(mariadb_query 'SELECT @@lower_case_table_names;')"
echo

echo "=== WordPress storage ==="
docker volume inspect "$WORDPRESS_SHARED_VOLUME" \
  --format 'Name={{.Name}} Driver={{.Driver}} Mountpoint={{.Mountpoint}}'
echo

echo "=== Managed plugins ==="
kubectl logs -n "$NS" job/wordpress-bootstrap |
  sed -n '/Installed plugins:/,$p'
