#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$ROOT_DIR/k8s/wordpress.yaml" <<'PY'
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cron = next(d for d in docs if d.get("kind") == "CronJob" and d["metadata"]["name"] == "wordpress-cron")
container = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
script = container["command"][-1]

assert "http://wordpress/healthz.php" in script
assert "max_attempts=60" in script
assert "http://wordpress/wp-cron.php?doing_wp_cron" in script
assert "--retry-all-errors" in script
assert cron["spec"]["jobTemplate"]["spec"]["activeDeadlineSeconds"] == 420

print("WP-Cron readiness-gate checks passed.")
PY
