#!/usr/bin/env bash
# Deletes the k3d cluster but keeps the WordPress files and the MariaDB
# volume, so ./start.sh recreates the same site.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands k3d

k3d cluster delete "$CLUSTER_NAME"

cat <<EOF

Cluster deleted.
Preserved WordPress files: ./data/wordpress
Preserved MariaDB Docker volume: $MARIADB_DATA_VOLUME
Run ./start.sh to recreate the cluster with the same data.
EOF
