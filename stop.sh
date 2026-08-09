#!/usr/bin/env bash
set -euo pipefail

MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"

k3d cluster delete wordpress-ha-poc

echo
echo "Cluster deleted."
echo "Preserved WordPress files: ./data/wordpress"
echo "Preserved MariaDB Docker volume: $MARIADB_DATA_VOLUME"
echo "Run ./start.sh to recreate the cluster with the same data."
