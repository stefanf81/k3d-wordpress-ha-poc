#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"

echo "Deleting the k3d cluster..."
k3d cluster delete wordpress-ha-poc >/dev/null 2>&1 || true

echo "Deleting WordPress shared files..."
rm -rf "$ROOT_DIR/data/wordpress"
mkdir -p "$ROOT_DIR/data/wordpress"

# Remove data left by revisions that used a macOS bind mount for MariaDB.
rm -rf "$ROOT_DIR/data/mariadb"

echo "Deleting MariaDB Docker named volume..."
docker volume rm -f "$MARIADB_DATA_VOLUME" >/dev/null 2>&1 || true

echo "Starting a completely fresh lab..."
exec "$ROOT_DIR/start.sh"
