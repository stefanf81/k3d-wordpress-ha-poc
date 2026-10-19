#!/usr/bin/env bash
# Re-runs the WP-CLI bootstrap (core, plugins, content, settings) without
# rebuilding the cluster or restarting the WordPress replicas.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cluster

echo "Re-running WordPress/plugin bootstrap..."
run_bootstrap
