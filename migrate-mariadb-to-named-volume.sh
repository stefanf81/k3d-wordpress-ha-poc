#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="wordpress-ha-poc"
NS="wordpress-poc"
MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"

for cmd in docker k3d kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but was not found in PATH." >&2
    exit 1
  fi
done

if ! k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER_NAME"; then
  echo "ERROR: No running '$CLUSTER_NAME' cluster was found." >&2
  echo "This helper is for migrating an existing bind-mounted MariaDB database." >&2
  exit 1
fi

kubectl config use-context "k3d-$CLUSTER_NAME" >/dev/null

current_mount="$(
  docker inspect "k3d-${CLUSTER_NAME}-server-0" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mariadb-data"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}'
)"

if [[ "$current_mount" == "volume|${MARIADB_DATA_VOLUME}|"* ]]; then
  echo "MariaDB already uses Docker named volume '$MARIADB_DATA_VOLUME'."
  exit 0
fi

echo "Current MariaDB node mount: $current_mount"
echo "Target Docker volume:       $MARIADB_DATA_VOLUME"

echo
echo "Waiting for MariaDB to be ready..."
kubectl rollout status deployment/mariadb \
  -n "$NS" \
  --timeout=300s

mkdir -p "$ROOT_DIR/backups"
timestamp="$(date '+%Y%m%d-%H%M%S')"
dump_file="$ROOT_DIR/backups/mariadb-before-named-volume-${timestamp}.sql"

echo
echo "Creating logical MariaDB backup:"
echo "  $dump_file"

kubectl exec -n "$NS" deployment/mariadb -- \
  /bin/sh -ec '
    exec mariadb-dump \
      --protocol=tcp \
      --host=127.0.0.1 \
      --user=root \
      --password="$MARIADB_ROOT_PASSWORD" \
      --single-transaction \
      --quick \
      --routines \
      --triggers \
      --events \
      --hex-blob \
      --add-drop-table \
      "$MARIADB_DATABASE"
  ' > "$dump_file"

if [ ! -s "$dump_file" ]; then
  echo "ERROR: MariaDB dump is empty; refusing to continue." >&2
  exit 1
fi

if ! grep -qE '^(CREATE TABLE|INSERT INTO|DROP TABLE)' "$dump_file"; then
  echo "ERROR: MariaDB dump does not look valid; refusing to continue." >&2
  exit 1
fi

echo "Backup complete ($(wc -c < "$dump_file" | tr -d ' ') bytes)."

if docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1; then
  echo
  echo "ERROR: Target Docker volume '$MARIADB_DATA_VOLUME' already exists." >&2
  echo "Refusing to overwrite it automatically." >&2
  echo "Use a different MARIADB_DATA_VOLUME name or remove the unused volume first." >&2
  exit 1
fi

echo
echo "Deleting old k3d cluster. WordPress host files and SQL backup are preserved..."
k3d cluster delete "$CLUSTER_NAME"

echo "Creating fresh Linux-backed MariaDB Docker volume..."
docker volume create \
  --label "com.k3d-wordpress-ha-poc.role=mariadb-data" \
  "$MARIADB_DATA_VOLUME" >/dev/null

echo
echo "Recreating the lab on the named volume..."
MARIADB_DATA_VOLUME="$MARIADB_DATA_VOLUME" "$ROOT_DIR/start.sh"

echo
echo "Restoring previous MariaDB database into the new volume..."
kubectl exec -i -n "$NS" deployment/mariadb -- \
  /bin/sh -ec '
    exec mariadb \
      --protocol=tcp \
      --host=127.0.0.1 \
      --user=root \
      --password="$MARIADB_ROOT_PASSWORD" \
      "$MARIADB_DATABASE"
  ' < "$dump_file"

echo
echo "Reconciling WordPress core, plugins, settings and seeded content..."
"$ROOT_DIR/reconfigure.sh"

echo
echo "Verifying Linux table-name semantics..."
lower_case_table_names="$(
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
        --execute="SELECT @@lower_case_table_names;"
    '
)"

if [ "$lower_case_table_names" != "0" ]; then
  echo "ERROR: expected @@lower_case_table_names=0, got '$lower_case_table_names'." >&2
  echo "Your SQL backup is preserved at: $dump_file" >&2
  exit 1
fi

echo "MariaDB lower_case_table_names: $lower_case_table_names"

echo
"$ROOT_DIR/verify.sh"

echo
echo "Migration complete."
echo "SQL backup preserved at:"
echo "  $dump_file"
