#!/usr/bin/env bash
set -euo pipefail

NS="wordpress-poc"
MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"

echo "=== Local tooling ==="
k3d version
echo
kubectl version --client
echo

echo "=== Kubernetes / k3s ==="
kubectl version
echo
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.osImage'
echo

echo "=== Traefik ingress ==="
kubectl get pods   -n kube-system   -l app.kubernetes.io/name=traefik   -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image,IMAGE_ID:.status.containerStatuses[0].imageID'
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
kubectl exec -n "$NS" deployment/mariadb -- \
  /bin/sh -ec '
    mariadb \
      --protocol=tcp \
      --host=127.0.0.1 \
      --user="$MARIADB_USER" \
      --password="$MARIADB_PASSWORD" \
      "$MARIADB_DATABASE" \
      --batch \
      --skip-column-names \
      --execute="SELECT CONCAT(\"lower_case_table_names=\", @@lower_case_table_names);"
  '
echo

echo "=== Managed plugins ==="
kubectl logs -n "$NS" job/wordpress-bootstrap | \
  sed -n '/Installed plugins:/,$p'
