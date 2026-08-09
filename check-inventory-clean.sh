#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$ROOT_DIR/k8s/wpcli-inventory.yaml" "$ROOT_DIR/k8s/bootstrap.yaml" <<'PY'
import sys, yaml

inv = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ij = next(d for d in inv if d.get("kind") == "Job")
c = ij["spec"]["template"]["spec"]["containers"][0]
s = c["command"][-1]

assert c["securityContext"]["runAsNonRoot"] is True
assert c["securityContext"]["allowPrivilegeEscalation"] is False
assert c["securityContext"]["capabilities"]["drop"] == ["ALL"]
assert s.count("--skip-plugins") >= 2
assert s.count("--skip-themes") >= 2

boot = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d]
bj = next(d for d in boot if d.get("kind") == "Job" and d["metadata"]["name"] == "wordpress-bootstrap")
bs = bj["spec"]["template"]["spec"]["containers"][0]["command"][-1]
tail = bs.split('echo "Installed plugins:"', 1)[1]
assert "--skip-plugins" in tail
assert "--skip-themes" in tail

print("Clean inventory checks passed.")
PY
