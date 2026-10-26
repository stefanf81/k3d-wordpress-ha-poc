#!/usr/bin/env bash
# Deletes the cluster and the WordPress and MariaDB volumes, then starts a
# completely fresh lab. Files under ./backups/ are kept.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands docker k3d

# Older revisions kept their data in ./data as host bind mounts. Those files
# are owned by uid 33 and root. On Docker Desktop for macOS the host user can
# delete them anyway; on native Linux it can't, so delete them as root from a
# throwaway container using the (already pulled) k3s image, which ships
# /bin/rm. They must go, or ./start.sh would import ./data/wordpress into the
# fresh volume.
remove_data_dir() {
  local name="$1"

  [ -e "$ROOT_DIR/data/$name" ] || return 0
  rm -rf "${ROOT_DIR:?}/data/$name" 2>/dev/null && return 0

  echo "Removing root-owned files in ./data/$name via a container..."
  docker run --rm \
    --entrypoint /bin/rm \
    -v "$ROOT_DIR/data:/data" \
    "$K3S_IMAGE" -rf "/data/$name" ||
    die "could not delete ./data/$name; remove it manually (e.g. with sudo)."
}

echo "Deleting the k3d cluster..."
if cluster_exists; then
  k3d cluster delete "$CLUSTER_NAME"
fi

echo "Deleting WordPress shared files..."
if docker volume inspect "$WORDPRESS_SHARED_VOLUME" >/dev/null 2>&1; then
  docker volume rm "$WORDPRESS_SHARED_VOLUME" >/dev/null
fi
remove_data_dir wordpress

# Remove data left by revisions that used a host bind mount for MariaDB.
remove_data_dir mariadb

echo "Deleting MariaDB Docker named volume..."
if docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1; then
  docker volume rm "$MARIADB_DATA_VOLUME" >/dev/null
fi

echo "Starting a completely fresh lab..."
exec bash "$ROOT_DIR/start.sh"
