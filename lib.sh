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

  # The site address comes from the same file WordPress reads, so the lab
  # scripts and the installed site cannot disagree. SITE_PORT feeds the k3d
  # port mapping in k3d.yaml.
  # tr drops the carriage return of a CRLF file. The trailing slash goes too,
  # so "$SITE_URL/" is always a valid URL. wp-cli.sh normalizes it the same
  # way.
  SITE_URL="$(sed -n 's/^SITE_URL=//p' "$ROOT_DIR/k8s/bootstrap/site.env" | tr -d '\r')"
  SITE_URL="${SITE_URL%/}"
  [ -n "$SITE_URL" ] || {
    echo "ERROR: SITE_URL is missing from k8s/bootstrap/site.env" >&2
    exit 1
  }
  # The port is optional in a URL: fall back to the scheme's default.
  SITE_HOSTPORT="${SITE_URL#*://}"
  SITE_HOSTPORT="${SITE_HOSTPORT%%/*}"
  case "$SITE_HOSTPORT" in
    *:*) SITE_PORT="${SITE_HOSTPORT##*:}" ;;
    *) case "$SITE_URL" in https://*) SITE_PORT=443 ;; *) SITE_PORT=80 ;; esac ;;
  esac
  case "$SITE_PORT" in
    '' | *[!0-9]*)
      echo "ERROR: SITE_URL in k8s/bootstrap/site.env has no valid port: $SITE_URL" >&2
      echo "       Use the form http://localhost:8080" >&2
      exit 1
      ;;
  esac

  # Pin the node runtime by digest so k3s doesn't change underneath the lab.
  # Like every image in k8s/, it carries tag and digest; lint.sh checks both.
  # Override, e.g.: K3S_IMAGE=rancher/k3s:<version> ./start.sh
  K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1@sha256:6a47cea22c4b834d4ba72c89d291696b79ebe406251f90b446e4dff03513dd87}"
  MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"
  WORDPRESS_SHARED_VOLUME="${WORDPRESS_SHARED_VOLUME:-wordpress-ha-poc-wordpress-shared}"
  # Where older revisions kept the shared tree and the MariaDB datadir as
  # host bind mounts.
  LEGACY_WORDPRESS_DIR="$ROOT_DIR/data/wordpress"
  LEGACY_MARIADB_DIR="$ROOT_DIR/data/mariadb"

  # Waits are a little longer than each Job's activeDeadlineSeconds, so the
  # Job's own deadline is what reports a hang. The WordPress Deployment's
  # progressDeadlineSeconds must outlast BOOTSTRAP_TIMEOUT; lint.sh checks it.
  BOOTSTRAP_TIMEOUT=960
  INVENTORY_TIMEOUT=360
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

fail() {
  echo "FAIL: $*" >&2
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

# Succeeds if directory $1 exists and has entries. A directory that can't be
# listed (root-owned files from an older revision) counts as having entries,
# so it is never mistaken for an empty one.
dir_has_entries() {
  local entries
  [ -e "$1" ] || return 1
  entries="$(ls -A "$1" 2>/dev/null)" || return 0
  [ -n "$entries" ]
}

# Starts the cluster if its nodes are stopped (after a Docker restart, say),
# merges its kubeconfig and waits for the API.
start_existing_cluster() {
  local _
  k3d cluster start "$CLUSTER_NAME" >/dev/null
  k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-merge-default >/dev/null
  echo "Waiting for the Kubernetes API..."
  for _ in $(seq 1 60); do
    kubectl get --raw=/readyz >/dev/null 2>&1 && return 0
    sleep 3
  done
  die "the Kubernetes API of '$CLUSTER_NAME' did not become ready."
}

require_cluster() {
  require_commands kubectl
  command kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT" ||
    die "kubectl context '$KUBE_CONTEXT' not found. Run ./start.sh first."
}

# Prints "<type>|<volume>|<source>" for the mount at path $2 of container $1,
# or nothing if the container or mount is missing.
container_mount() {
  docker inspect "$1" \
    --format '{{range .Mounts}}{{if eq .Destination "'"$2"'"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}' \
    2>/dev/null || true
}

# The MariaDB mount on the k3d server node.
mariadb_mount_on_server() {
  container_mount "k3d-${CLUSTER_NAME}-server-0" /var/lib/mariadb-data
}

# The shared WordPress mount on k3d worker node $1 (0-2).
wordpress_mount_on_agent() {
  container_mount "k3d-${CLUSTER_NAME}-agent-$1" /var/lib/wordpress-shared
}

# The load balancer's published site bindings, e.g. 127.0.0.1:8080.
published_site_bindings() {
  docker port "k3d-${CLUSTER_NAME}-serverlb" 80/tcp 2>/dev/null || true
}

# Prints the load balancer's published site and Kubernetes API bindings that
# are not on 127.0.0.1. The lab must never be reachable from the network.
published_beyond_localhost() {
  local port
  for port in 80/tcp 6443/tcp; do
    docker port "k3d-${CLUSTER_NAME}-serverlb" "$port" 2>/dev/null |
      grep -v '^127\.0\.0\.1:' |
      sed "s|^|$port -> |" || true
  done
}

# Fails unless the load balancer publishes the site on SITE_PORT. After a
# change to the SITE_URL port, WordPress would otherwise redirect every
# request to a port that isn't published.
require_site_port_published() {
  local bindings
  bindings="$(published_site_bindings)"
  grep -q ":${SITE_PORT}\$" <<<"$bindings" && return 0
  cat >&2 <<EOF
ERROR: SITE_URL in k8s/bootstrap/site.env uses port $SITE_PORT, but the
cluster publishes the site on: ${bindings:-<nothing>}
A cluster's published ports can't change in place. Recreate it (data is
kept):
  ./stop.sh && ./start.sh
EOF
  exit 1
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

# Prints the logs of Job $1's successful pod. "kubectl logs job/NAME" picks a
# pod itself, which can be an earlier failed attempt of a retried Job.
job_logs() {
  local pod
  pod="$(
    kubectl get pods -n "$NS" \
      -l "batch.kubernetes.io/job-name=$1" \
      --field-selector=status.phase=Succeeded \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"
  if [ -n "$pod" ]; then
    kubectl logs -n "$NS" "$pod"
  else
    kubectl logs -n "$NS" "job/$1"
  fi
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

# Fails if k8s/secrets/ changed since the last ./start.sh. The WP-CLI Jobs
# would otherwise create the new Secrets and use, say, a new database
# password before MariaDB has been restarted with it.
require_secrets_applied() {
  local secret
  for secret in $(kubectl apply -k "$ROOT_DIR/k8s/secrets" --dry-run=client -o name); do
    kubectl get -n "$NS" "$secret" >/dev/null 2>&1 ||
      die "k8s/secrets/ changed since the last ./start.sh. Run ./start.sh to apply it."
  done
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
  job_logs wordpress-bootstrap
}

# Deletes ConfigMaps and Secrets that the manifests used to generate but no
# longer do: superseded hash-named copies (same generator name, another
# content hash), including those of older revisions, plus the fixed-name
# Secrets that revisions before k8s/secrets/ applied. Run it after the
# rollouts, when no pod uses them any more.
prune_generated_objects() {
  local current bases object base dir
  current="$(
    for dir in mariadb wordpress bootstrap inventory; do
      kubectl apply -k "$ROOT_DIR/k8s/$dir" --dry-run=client -o name
    done | sort -u
  )"
  [ -n "$current" ] || die "could not list the generated objects to keep."
  # Kustomize appends "-" and a 10-character hash to a generated name.
  bases="$(sed -nE 's#^((configmap|secret)/.+)-[a-z0-9]{10}$#\1#p' <<<"$current" | sort -u)"

  for object in $(kubectl get configmaps,secrets -n "$NS" -o name); do
    grep -qxF "$object" <<<"$current" && continue
    base="$(sed -nE 's#^(.+)-[a-z0-9]{10}$#\1#p' <<<"$object")"
    if [ -n "$base" ] && grep -qxF "$base" <<<"$bases"; then
      kubectl delete -n "$NS" "$object" --ignore-not-found=true >/dev/null
    fi
  done

  kubectl delete secret -n "$NS" --ignore-not-found=true \
    wordpress-database wordpress-keys wordpress-admin mariadb-root >/dev/null
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
