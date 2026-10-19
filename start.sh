#!/usr/bin/env bash
# Creates the k3d cluster (or reuses it) and reconciles every lab component.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands docker k3d kubectl curl
docker info >/dev/null 2>&1 || die "Docker is not running."

mkdir -p "$WORDPRESS_SHARED_DIR"

# k3d expands these inside k3d.yaml.
export K3S_IMAGE MARIADB_DATA_VOLUME WORDPRESS_SHARED_DIR

echo "Using k3s image: $K3S_IMAGE"
echo "Using MariaDB Docker volume: $MARIADB_DATA_VOLUME"

if cluster_exists; then
  # A k3d node's Docker mounts and published ports cannot be changed in
  # place. Detect an older project revision that still mounted
  # ./data/mariadb from the host.
  mariadb_mount="$(
    docker inspect "k3d-${CLUSTER_NAME}-server-0" \
      --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mariadb-data"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}' \
      2>/dev/null || true
  )"

  if [[ "$mariadb_mount" != "volume|${MARIADB_DATA_VOLUME}|"* ]]; then
    cat >&2 <<EOF
ERROR: Existing cluster does not use the expected MariaDB Docker named volume.
Current server-node mount: ${mariadb_mount:-<not found>}
Expected Docker volume: $MARIADB_DATA_VOLUME

If this cluster was created by an older revision using ./data/mariadb,
preserve its database with:
  ./migrate-mariadb-to-named-volume.sh

For a disposable clean rebuild instead, use:
  ./reset.sh
EOF
    exit 1
  fi

  lb_bindings="$(docker port "k3d-${CLUSTER_NAME}-serverlb" 80/tcp 2>/dev/null || true)"
  if [ -n "$lb_bindings" ] && grep -qv '^127\.0\.0\.1:' <<<"$lb_bindings"; then
    echo "WARNING: this cluster publishes the site beyond localhost:" >&2
    while IFS= read -r binding; do
      echo "  $binding" >&2
    done <<<"$lb_bindings"
    echo "Recreate it with ./stop.sh && ./start.sh (data is preserved)." >&2
  fi

  echo "Reusing existing k3d cluster '$CLUSTER_NAME'."
  command kubectl config use-context "$KUBE_CONTEXT" >/dev/null
else
  if docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1; then
    echo "Reusing MariaDB Docker named volume '$MARIADB_DATA_VOLUME'."
  else
    echo "Creating MariaDB Docker named volume..."
    docker volume create \
      --label "com.k3d-wordpress-ha-poc.role=mariadb-data" \
      "$MARIADB_DATA_VOLUME" >/dev/null
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
    kubectl get deployment traefik \
      -n kube-system \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"
  if [ "$traefik_replicas" = "3" ]; then
    break
  fi
  sleep 2
done

[ "$traefik_replicas" = "3" ] || die "Traefik was not reconciled to 3 replicas."

kubectl rollout status deployment/traefik \
  -n kube-system \
  --timeout=300s

echo
echo "Traefik placement:"
kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=traefik \
  -o wide

echo
echo "Creating namespace and storage..."
kubectl apply -f "$ROOT_DIR/k8s/storage.yaml"

echo
echo "Applying secrets, service accounts and network policy..."
kubectl apply -f "$ROOT_DIR/k8s/secrets.yaml"
kubectl apply -f "$ROOT_DIR/k8s/security.yaml"

echo
echo "Starting MariaDB..."
kubectl apply -f "$ROOT_DIR/k8s/mariadb.yaml"
kubectl rollout status deployment/mariadb \
  -n "$NS" \
  --timeout=300s

lower_case_table_names="$(mariadb_query 'SELECT @@lower_case_table_names;')"
echo "MariaDB lower_case_table_names: $lower_case_table_names"
if [ "$lower_case_table_names" != "0" ]; then
  cat >&2 <<EOF
ERROR: MariaDB is not using normal Linux case-sensitive table-name semantics.
Expected @@lower_case_table_names=0, got '$lower_case_table_names'.
Use ./reset.sh for a fresh named volume, or migrate logically with
./migrate-mariadb-to-named-volume.sh.
EOF
  exit 1
fi

echo
echo "Starting 3 WordPress replicas..."
kubectl apply -k "$ROOT_DIR/k8s/wordpress"

# On a fresh database the readiness endpoint returns 503 until WP-CLI creates
# the WordPress schema, so bootstrap must run before waiting for the
# Deployment to become Ready.
echo
echo "Installing/configuring WordPress and plugins..."
run_bootstrap

echo
echo "Waiting for all 3 WordPress replicas to become ready..."
kubectl rollout status deployment/wordpress \
  -n "$NS" \
  --timeout=420s

echo
echo "WordPress pod placement:"
kubectl get pods -n "$NS" -l app=wordpress -o wide

echo
echo "PVCs:"
kubectl get pvc -n "$NS"

cat <<EOF

Ready.
Open:  $SITE_URL
Admin: $SITE_URL/wp-admin/
Default PoC login: admin / admin-poc-change-me
  (k8s/bootstrap/site.env and k8s/secrets.yaml)

Verify the lab:
  ./verify.sh

Test a WordPress pod failure:
  ./test-ha.sh
EOF
