#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$ROOT_DIR/k8s/bootstrap.yaml" <<'PY'
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = next(
    d for d in docs
    if d.get("kind") == "Job"
    and d["metadata"]["name"] == "wordpress-bootstrap"
)
script = job["spec"]["template"]["spec"]["containers"][0]["command"][-1]

assert "--skip-plugins" in script
assert "--skip-themes" in script
assert "skipping download/reinstall" in script
assert 'wp plugin is-active "$plugin"' in script
assert 'wp plugin install "$plugin"' in script
assert 'echo "$plugin is already pinned at $version."' not in script

print("Pinned-plugin idempotency checks passed.")
PY
