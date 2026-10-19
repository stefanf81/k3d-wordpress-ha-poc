# shellcheck shell=bash
# Shared settings and helpers for the lab scripts. Source it; don't run it.
#
# Every kubectl call made through this file targets the lab cluster, whatever
# the current kubectl context is, so a script can never act on another
# cluster.

# Constants are used by the scripts that source this file.
# shellcheck disable=SC2034
{
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CLUSTER_NAME="wordpress-ha-poc"
  KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
  NS="wordpress-poc"
  SITE_URL="http://localhost:8080"

  # Pin the node runtime so k3s doesn't change underneath the lab. Override,
  # e.g.: K3S_IMAGE=rancher/k3s:<version> ./start.sh
  K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1}"
  MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"
  WORDPRESS_SHARED_DIR="$ROOT_DIR/data/wordpress"

  # Waits are a little longer than each Job's activeDeadlineSeconds, so the
  # Job's own deadline is what reports a hang.
  BOOTSTRAP_TIMEOUT=960
  INVENTORY_TIMEOUT=360
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

kubectl() {
  command kubectl --context "$KUBE_CONTEXT" "$@"
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 ||
      die "'$cmd' is required but was not found in PATH."
  done
}

cluster_exists() {
  k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1
}

require_cluster() {
  require_commands kubectl
  command kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT" ||
    die "kubectl context '$KUBE_CONTEXT' not found. Run ./start.sh first."
}

# Runs one SQL statement inside the MariaDB pod as the WordPress user and
# prints the result without column names.
mariadb_query() {
  kubectl exec -n "$NS" deployment/mariadb -- /bin/sh -ec '
    mariadb \
      --protocol=tcp \
      --host=127.0.0.1 \
      --user="$MARIADB_USER" \
      --password="$MARIADB_PASSWORD" \
      "$MARIADB_DATABASE" \
      --batch \
      --skip-column-names \
      --execute="$1"
  ' sh "$1"
}

print_job_logs() {
  kubectl logs -n "$NS" "job/$1" --all-containers=true --tail=200 >&2 || true
}

# Waits until a Job completes. On failure or timeout, prints the latest
# pod's logs and returns non-zero.
wait_for_job() {
  local job="$1" timeout="$2" conditions
  local deadline=$((SECONDS + timeout))

  while ((SECONDS < deadline)); do
    conditions="$(
      kubectl get job "$job" -n "$NS" \
        -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' \
        2>/dev/null || true
    )"
    case " $conditions " in
      *" Complete "*)
        return 0
        ;;
      *" Failed "*)
        echo "ERROR: Job $job failed. Latest pod logs:" >&2
        print_job_logs "$job"
        return 1
        ;;
    esac
    sleep 3
  done

  echo "ERROR: Job $job did not finish within ${timeout}s. Latest pod logs:" >&2
  print_job_logs "$job"
  return 1
}

# Replaces the WP-CLI bootstrap Job and waits for it. A finished Job never
# runs again, so it is recreated on every reconcile. Foreground deletion
# makes sure an older bootstrap pod is gone before the new one starts.
run_bootstrap() {
  kubectl delete job wordpress-bootstrap \
    -n "$NS" \
    --ignore-not-found=true \
    --cascade=foreground >/dev/null
  kubectl apply -k "$ROOT_DIR/k8s/bootstrap"
  wait_for_job wordpress-bootstrap "$BOOTSTRAP_TIMEOUT"
  echo
  echo "Bootstrap result:"
  kubectl logs -n "$NS" job/wordpress-bootstrap
}

# Requests the site once a second while a failure is in progress. Prints each
# status code and fails if more than MAX_FAILED_REQUESTS (default 0) requests
# don't get a 2xx/3xx answer.
probe_site_during_failure() {
  local requests="$1" max_failed="${MAX_FAILED_REQUESTS:-0}"
  local failed=0 code i

  for ((i = 1; i <= requests; i++)); do
    code="$(
      curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 5 "$SITE_URL/" || true
    )"
    printf 'request %02d -> HTTP %s\n' "$i" "$code"
    case "$code" in
      2?? | 3??) ;;
      *) failed=$((failed + 1)) ;;
    esac
    sleep 1
  done

  echo
  if ((failed > max_failed)); then
    echo "FAIL: $failed of $requests requests failed during the disruption (allowed: $max_failed)." >&2
    return 1
  fi
  echo "PASS: $((requests - failed)) of $requests requests succeeded during the disruption."
}
