#!/usr/bin/env bash
# Moves a database created by an older revision (MariaDB datadir bind-mounted
# from ./data/mariadb) onto the Docker named volume with a logical dump and
# restore. The SQL backup is kept under ./backups/.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands docker k3d kubectl curl

cluster_exists || die "No '$CLUSTER_NAME' cluster was found.
This helper migrates an existing bind-mounted MariaDB database."

current_mount="$(
  docker inspect "k3d-${CLUSTER_NAME}-server-0" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mariadb-data"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}'
)"

if [[ "$current_mount" == "volume|${MARIADB_DATA_VOLUME}|"* ]]; then
  echo "MariaDB already uses Docker named volume '$MARIADB_DATA_VOLUME'."
  exit 0
fi

# Check everything that could stop the migration before touching anything.
if docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1; then
  die "Target Docker volume '$MARIADB_DATA_VOLUME' already exists; refusing to overwrite it.
Use a different MARIADB_DATA_VOLUME name or remove the unused volume first."
fi
for script in start.sh reconfigure.sh verify.sh; do
  [ -f "$ROOT_DIR/$script" ] || die "$script is missing; refusing to delete the cluster."
done

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
  ' >"$dump_file"

[ -s "$dump_file" ] || die "MariaDB dump is empty; refusing to continue."
grep -qE '^(CREATE TABLE|INSERT INTO|DROP TABLE)' "$dump_file" ||
  die "MariaDB dump does not look valid; refusing to continue."

echo "Backup complete ($(wc -c <"$dump_file" | tr -d ' ') bytes)."

echo
echo "Deleting old k3d cluster. WordPress host files and SQL backup are preserved..."
k3d cluster delete "$CLUSTER_NAME"

echo "Creating fresh Linux-backed MariaDB Docker volume..."
docker volume create \
  --label "com.k3d-wordpress-ha-poc.role=mariadb-data" \
  "$MARIADB_DATA_VOLUME" >/dev/null

# The old cluster is gone from here on, so any failure must say where the
# backup is.
print_backup_location() {
  local status=$?
  [ "$status" -eq 0 ] || echo "Your SQL backup is preserved at: $dump_file" >&2
}
trap print_backup_location EXIT

echo
echo "Recreating the lab on the named volume..."
bash "$ROOT_DIR/start.sh"

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
  ' <"$dump_file"

echo
echo "Reconciling WordPress core, plugins, settings and seeded content..."
bash "$ROOT_DIR/reconfigure.sh"

echo
echo "Verifying Linux table-name semantics..."
lower_case_table_names="$(mariadb_query 'SELECT @@lower_case_table_names;')"
[ "$lower_case_table_names" = "0" ] ||
  die "expected @@lower_case_table_names=0, got '$lower_case_table_names'."
echo "MariaDB lower_case_table_names: $lower_case_table_names"

echo
bash "$ROOT_DIR/verify.sh"

echo
echo "Migration complete."
echo "SQL backup preserved at:"
echo "  $dump_file"
