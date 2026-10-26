#!/usr/bin/env bash
# Static checks that need no cluster: git file modes, shell scripts, PHP
# syntax and the rendered Kubernetes manifests. A missing tool is skipped
# with a warning, unless LINT_STRICT=1 (as in CI).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

failed=0

section() {
  printf '\n== %s\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "${LINT_STRICT:-0}" = "1" ]; then
    echo "ERROR: $1 is required (LINT_STRICT=1)." >&2
    failed=1
  else
    echo "SKIP: $1 is not installed."
  fi
  return 1
}

section "Executable scripts"
# GitHub's web upload drops the executable bit, which breaks ./start.sh and
# every script that calls a sibling script.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while read -r mode _ _ path; do
    if [ "$mode" != "100755" ]; then
      echo "not executable in git: $path (fix: git update-index --chmod=+x $path)"
      failed=1
    fi
  done < <(git ls-files -s -- '*.sh' ':!:k8s/' ':!:lib.sh')
  echo "checked"
else
  echo "SKIP: not a git checkout."
fi

section "shellcheck"
if have shellcheck; then
  shellcheck -x ./*.sh k8s/*/*.sh && echo "clean" || failed=1
fi

section "Timeouts"
# The Deployment's progress deadline must outlast the bootstrap wait, or the
# rollout is marked failed while the bootstrap is still creating the schema.
bootstrap_timeout="$(sed -n 's/^ *BOOTSTRAP_TIMEOUT=\([0-9]*\).*/\1/p' lib.sh)"
progress_deadline="$(sed -n 's/^ *progressDeadlineSeconds: *\([0-9]*\).*/\1/p' k8s/wordpress/wordpress.yaml)"
if [ -z "$bootstrap_timeout" ] || [ -z "$progress_deadline" ]; then
  echo "could not read BOOTSTRAP_TIMEOUT (lib.sh) or progressDeadlineSeconds (wordpress.yaml)"
  failed=1
elif [ "$progress_deadline" -le "$bootstrap_timeout" ]; then
  echo "progressDeadlineSeconds ($progress_deadline) must exceed BOOTSTRAP_TIMEOUT ($bootstrap_timeout)"
  failed=1
else
  echo "progressDeadlineSeconds $progress_deadline > BOOTSTRAP_TIMEOUT $bootstrap_timeout"
fi

section "PHP syntax"
if have php; then
  for file in k8s/*/*.php; do
    php -l "$file" || failed=1
  done
fi

section "Kubernetes manifests"
if have kubectl; then
  # kubeconform only reads files with a .yaml/.json extension.
  render_dir="$(mktemp -d)"
  trap 'rm -rf "$render_dir"' EXIT
  rendered="$render_dir/manifests.yaml"

  for file in k8s/*.yaml; do
    cat "$file"
    printf '\n---\n'
  done >"$rendered"

  for dir in k8s/*/; do
    if ! kubectl kustomize "$dir" >>"$rendered"; then
      echo "kustomize build failed: $dir"
      failed=1
    fi
    printf '\n---\n' >>"$rendered"
  done
  echo "rendered $(grep -c '^kind:' "$rendered") objects"

  if have kubeconform; then
    # HelmChartConfig is a k3s CRD with no published schema.
    kubeconform -strict -summary -skip HelmChartConfig "$rendered" || failed=1
  fi
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAIL: lint found problems." >&2
  exit 1
fi
echo "PASS: lint checks succeeded."
