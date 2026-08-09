#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$ROOT_DIR/k8s/bootstrap.yaml" <<'PY'
import sys, yaml

path = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
cfg = next(d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "wordpress-bootstrap")
seed = cfg["data"]["seed-site.sh"]

assert "wp menu list --field=name" not in seed
assert "PRIMARY_MENU_ID" in seed
assert 'wp menu create "Primary" --porcelain' in seed
assert "AND tt.term_id = ${PRIMARY_MENU_ID}" in seed

print("Bootstrap idempotency checks passed.")
PY
