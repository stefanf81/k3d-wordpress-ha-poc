#!/usr/bin/env bash
# Moves a database created by an older revision (MariaDB datadir bind-mounted
# from ./data/mariadb) onto the Docker named volume with a logical dump and
# restore. The SQL backup is kept under ./backups/, and so is ./data/mariadb.
#
# Works in either state:
#   - the old cluster still exists: the dump is taken from its MariaDB pod
#   - the old cluster is gone (e.g. after ./stop.sh): the dump is taken from a
#     temporary MariaDB container started on ./data/mariadb
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands docker k3d kubectl curl
docker info >/dev/null 2>&1 || die "Docker is not running."
require_cgroup_v2_for_k3s

DB_NAME="$(sed -n 's/^WORDPRESS_DB_NAME=//p' "$ROOT_DIR/k8s/secrets/database.env" | tr -d '\r')"
MARIADB_IMAGE="$(sed -n 's/^ *image: *\(mariadb:.*\)$/\1/p' "$ROOT_DIR/k8s/mariadb/mariadb.yaml" | head -n 1)"
[ -n "$DB_NAME" ] || die "WORDPRESS_DB_NAME is missing from k8s/secrets/database.env."
[ -n "$MARIADB_IMAGE" ] || die "could not read the MariaDB image from k8s/mariadb/mariadb.yaml."
TEMP_CONTAINER="${CLUSTER_NAME}-mariadb-migrate"

# Decide where the dump comes from before touching anything.
if cluster_exists; then
  source_kind=cluster
  current_mount="$(mariadb_mount_on_server)"
  # An empty result would otherwise look like "not migrated yet" and lead to a
  # cluster delete.
  if [ -z "$current_mount" ]; then
    docker inspect "k3d-${CLUSTER_NAME}-server-0" >/dev/null 2>&1 ||
      die "k3d server node container not found; refusing to continue."
    die "the k3d server node has no /var/lib/mariadb-data mount; refusing to continue."
  fi
  if [[ "$current_mount" == "volume|${MARIADB_DATA_VOLUME}|"* ]]; then
    echo "MariaDB already uses Docker named volume '$MARIADB_DATA_VOLUME'."
    exit 0
  fi
  echo "Current MariaDB node mount: $current_mount"
elif dir_has_entries "$LEGACY_MARIADB_DIR"; then
  source_kind=directory
  echo "No '$CLUSTER_NAME' cluster; reading ./data/mariadb with $MARIADB_IMAGE."
else
  die "No '$CLUSTER_NAME' cluster and no database in ./data/mariadb were found.
This helper migrates a database from an older, bind-mounted revision."
fi

if docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1; then
  die "Target Docker volume '$MARIADB_DATA_VOLUME' already exists; refusing to overwrite it.
Use a different MARIADB_DATA_VOLUME name or remove the unused volume first."
fi
for script in start.sh reconfigure.sh verify.sh; do
  [ -f "$ROOT_DIR/$script" ] || die "$script is missing; refusing to continue."
done
echo "Target Docker volume:       $MARIADB_DATA_VOLUME"

mkdir -p "$ROOT_DIR/backups"
timestamp="$(date '+%Y%m%d-%H%M%S')"
dump_file="$ROOT_DIR/backups/mariadb-before-named-volume-${timestamp}.sql"

# Every failure from here on must say where the backup is, and must not
# leave the temporary container behind.
cleanup() {
  local status=$?
  docker rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  if [ "$status" -ne 0 ] && [ -s "$dump_file" ]; then
    echo "Your SQL backup is preserved at: $dump_file" >&2
  fi
}
trap cleanup EXIT

dump_from_cluster() {
  echo "Starting the old cluster if its nodes are stopped..."
  start_existing_cluster

  echo "Waiting for MariaDB to be ready..."
  kubectl rollout status deployment/mariadb \
    -n "$NS" \
    --timeout=300s

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
}

# The old passwords may be unknown, so the temporary server skips grant
# checks. It has no network, so only docker exec can reach it.
dump_from_directory() {
  local i databases

  docker rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$TEMP_CONTAINER" \
    -v "$LEGACY_MARIADB_DIR:/var/lib/mysql" \
    "$MARIADB_IMAGE" \
    --skip-grant-tables \
    --skip-networking >/dev/null

  echo "Waiting for the temporary MariaDB server..."
  for i in $(seq 1 60); do
    docker exec "$TEMP_CONTAINER" mariadb-admin ping >/dev/null 2>&1 && break
    if [ "$(docker inspect "$TEMP_CONTAINER" --format '{{.State.Running}}')" != "true" ] ||
      [ "$i" -eq 60 ]; then
      docker logs --tail 40 "$TEMP_CONTAINER" >&2 || true
      die "the temporary MariaDB server on ./data/mariadb did not start."
    fi
    sleep 2
  done

  databases="$(docker exec "$TEMP_CONTAINER" mariadb --batch --skip-column-names -e 'SHOW DATABASES')"
  grep -qxF "$DB_NAME" <<<"$databases" ||
    die "database '$DB_NAME' not found in ./data/mariadb. It contains: $(tr '\n' ' ' <<<"$databases")"

  docker exec "$TEMP_CONTAINER" \
    mariadb-dump \
    --single-transaction \
    --quick \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --add-drop-table \
    "$DB_NAME" >"$dump_file"

  docker stop --time 60 "$TEMP_CONTAINER" >/dev/null
  docker rm "$TEMP_CONTAINER" >/dev/null
}

echo
echo "Creating logical MariaDB backup:"
echo "  $dump_file"
"dump_from_$source_kind"

[ -s "$dump_file" ] || die "MariaDB dump is empty; refusing to continue."
grep -qE '^(CREATE TABLE|INSERT INTO|DROP TABLE)' "$dump_file" ||
  die "MariaDB dump does not look valid; refusing to continue."

echo "Backup complete ($(wc -c <"$dump_file" | tr -d ' ') bytes)."

if [ "$source_kind" = cluster ]; then
  echo
  echo "Deleting old k3d cluster. ./data and the SQL backup are preserved..."
  k3d cluster delete "$CLUSTER_NAME"
fi

# start.sh refuses to create a cluster while ./data/mariadb holds a database
# and this volume doesn't exist, so it is created first.
echo "Creating fresh Linux-backed MariaDB Docker volume..."
docker volume create \
  --label "com.k3d-wordpress-ha-poc.role=mariadb-data" \
  "$MARIADB_DATA_VOLUME" >/dev/null

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
echo "./data/mariadb is no longer used and can be deleted (./reset.sh does that)."
