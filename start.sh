#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="wordpress-ha-poc"

# Keep the local control-plane/node runtime reproducible by default.
# Override, e.g.:
#   K3S_IMAGE=rancher/k3s:<version> ./start.sh
export K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1}"
export MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"

for cmd in docker k3d kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but was not found in PATH." >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is not running." >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/data/wordpress"

echo "Using k3s image: $K3S_IMAGE"
echo "Using MariaDB Docker volume: $MARIADB_DATA_VOLUME"

# k3d expands environment variables inside k3d.yaml.
export WORDPRESS_SHARED_DIR="$ROOT_DIR/data/wordpress"

if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER_NAME"; then
  # A k3d node's Docker mounts cannot be changed in-place. Detect an older
  # project revision that still mounted ./data/mariadb from macOS.
  mariadb_mount="$(
    docker inspect "k3d-${CLUSTER_NAME}-server-0"       --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mariadb-data"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}'       2>/dev/null || true
  )"

  expected_prefix="volume|${MARIADB_DATA_VOLUME}|"

  if [[ "$mariadb_mount" != "$expected_prefix"* ]]; then
    echo "ERROR: Existing cluster does not use the expected MariaDB Docker named volume." >&2
    echo "Current server-node mount: ${mariadb_mount:-<not found>}" >&2
    echo "Expected Docker volume: $MARIADB_DATA_VOLUME" >&2
    echo >&2
    echo "If this cluster was created by an older revision using ./data/mariadb," >&2
    echo "preserve its database with:" >&2
    echo "  ./migrate-mariadb-to-named-volume.sh" >&2
    echo >&2
    echo "For a disposable clean rebuild instead, use:" >&2
    echo "  ./reset.sh" >&2
    exit 1
  fi

  echo "Reusing existing k3d cluster '$CLUSTER_NAME'."
  kubectl config use-context "k3d-$CLUSTER_NAME" >/dev/null
else
  if ! docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1; then
    echo "Creating MariaDB Docker named volume..."
    docker volume create       --label "com.k3d-wordpress-ha-poc.role=mariadb-data"       "$MARIADB_DATA_VOLUME" >/dev/null
  else
    echo "Reusing MariaDB Docker named volume '$MARIADB_DATA_VOLUME'."
  fi

  echo "Creating k3d cluster with 3 worker nodes..."
  k3d cluster create --config "$ROOT_DIR/k3d.yaml"
fi

echo
echo "Nodes:"
kubectl get nodes -L workload

echo
echo "Configuring HA Traefik ingress..."
kubectl apply -f "$ROOT_DIR/k8s/traefik-config.yaml"

traefik_replicas=""
for _ in $(seq 1 90); do
  traefik_replicas="$(
    kubectl get deployment traefik       -n kube-system       -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"
  if [ "$traefik_replicas" = "3" ]; then
    break
  fi
  sleep 2
done

if [ "$traefik_replicas" != "3" ]; then
  echo "ERROR: Traefik was not reconciled to 3 replicas." >&2
  exit 1
fi

kubectl rollout status deployment/traefik   -n kube-system   --timeout=300s

echo
echo "Traefik placement:"
kubectl get pods   -n kube-system   -l app.kubernetes.io/name=traefik   -o wide

echo
echo "Creating storage..."
kubectl apply -f "$ROOT_DIR/k8s/storage.yaml"

echo
echo "Applying service accounts and network policy..."
kubectl apply -f "$ROOT_DIR/k8s/security.yaml"

echo
echo "Starting MariaDB..."
kubectl apply -f "$ROOT_DIR/k8s/mariadb.yaml"
kubectl rollout status deployment/mariadb \
  -n wordpress-poc \
  --timeout=300s

lower_case_table_names="$(
  kubectl exec -n wordpress-poc deployment/mariadb --     /bin/sh -ec '
      mariadb         --protocol=tcp         --host=127.0.0.1         --user="$MARIADB_USER"         --password="$MARIADB_PASSWORD"         "$MARIADB_DATABASE"         --batch         --skip-column-names         --execute="SELECT @@lower_case_table_names;"
    '
)"

echo "MariaDB lower_case_table_names: $lower_case_table_names"
if [ "$lower_case_table_names" != "0" ]; then
  echo "ERROR: MariaDB is not using normal Linux case-sensitive table-name semantics." >&2
  echo "Expected @@lower_case_table_names=0, got '$lower_case_table_names'." >&2
  echo "Use ./reset.sh for a fresh named volume, or migrate logically with" >&2
  echo "./migrate-mariadb-to-named-volume.sh." >&2
  exit 1
fi

echo
echo "Starting 3 WordPress replicas..."
kubectl apply -f "$ROOT_DIR/k8s/wordpress.yaml"

# On a completely fresh database the readiness endpoint intentionally returns
# 503 until WP-CLI creates the WordPress schema, so bootstrap must run before
# waiting for the Deployment to become Ready.
echo
echo "Installing/configuring WordPress and plugins..."
# A completed Job is immutable and does not run again, so recreate it every time.
kubectl delete job wordpress-bootstrap \
  -n wordpress-poc \
  --ignore-not-found=true >/dev/null

kubectl apply -f "$ROOT_DIR/k8s/bootstrap.yaml"

kubectl wait \
  --for=condition=complete \
  job/wordpress-bootstrap \
  -n wordpress-poc \
  --timeout=600s

echo
echo "Bootstrap result:"
kubectl logs -n wordpress-poc job/wordpress-bootstrap

echo
echo "Waiting for all 3 WordPress replicas to become ready..."
kubectl rollout status deployment/wordpress \
  -n wordpress-poc \
  --timeout=420s

echo
echo "WordPress pod placement:"
kubectl get pods -n wordpress-poc -l app=wordpress -o wide

echo
echo "PVCs:"
kubectl get pvc -n wordpress-poc

echo
echo "Ready."
echo "Open: http://localhost:8080"
echo "Admin: http://localhost:8080/wp-admin/"
echo "Default PoC login: admin / admin-poc-change-me"
echo
echo "Verify HA placement:"
echo "  kubectl get pods -n wordpress-poc -l app=wordpress -o wide"
echo
echo "Test a WordPress pod failure:"
echo "  ./test-ha.sh"
