#!/usr/bin/env bash
set -euo pipefail

echo "Latest bootstrap plugin inventory:"
kubectl logs -n wordpress-poc job/wordpress-bootstrap | \
  grep -v '^Deprecated:' | \
  sed -n '/Installed plugins:/,$p'
