#!/usr/bin/env bash
# Deletes the k3d cluster but keeps the WordPress and MariaDB volumes, so
# ./start.sh recreates the same site.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands k3d

lab_was_current=no
if command -v kubectl >/dev/null 2>&1 && lab_context_is_current; then
  lab_was_current=yes
fi

k3d cluster delete "$CLUSTER_NAME"

# Deleting the cluster removes its kubectl context. Switch back to the one
# that was current before ./start.sh, unless another was chosen since.
restore_previous_context "$lab_was_current"

cat <<EOF

Cluster deleted.
Preserved WordPress Docker volume: $WORDPRESS_SHARED_VOLUME
Preserved MariaDB Docker volume: $MARIADB_DATA_VOLUME
Run ./start.sh to recreate the cluster with the same data.
EOF
