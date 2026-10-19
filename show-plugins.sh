#!/usr/bin/env bash
# Shows the plugin table printed by the most recent bootstrap run.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cluster

echo "Latest bootstrap plugin inventory:"
# The table is produced with --skip-plugins, so it has no plugin notices;
# the filter only hides Deprecated: lines from older bootstrap revisions.
kubectl logs -n "$NS" job/wordpress-bootstrap |
  grep -v '^Deprecated:' |
  sed -n '/Installed plugins:/,$p'
