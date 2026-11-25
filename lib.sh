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

# Fails on a cgroup v1 Docker host when the k3s image is 1.35 or newer: its
# kubelet refuses cgroup v1, and k3d only reports that as a node that "failed
# to get ready" after its timeout, on every create or start attempt.
require_cgroup_v2_for_k3s() {
  [ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" = "1" ] || return 0
  case "${K3S_IMAGE#*:}" in
    v1.3[5-9].* | v1.[4-9][0-9].* | v[2-9].*) ;;
    *) return 0 ;;
  esac
  cat >&2 <<EOF
ERROR: Docker runs on a cgroup v1 host. The k3s release in K3S_IMAGE refuses
cgroup v1, so the cluster nodes would never become ready:
  $K3S_IMAGE
Use a host or Docker VM with cgroup v2: current Docker Desktop, Rancher
Desktop, colima and Linux distributions from the last few years all use it.
EOF
  exit 1
}

# The distinct error lines of a k3s node log (read on stdin), oldest first,
# with a repeat count; lines that differ only in numbers (timestamps, ports,
# PIDs) count as the same. A failing node usually retries the same request
# every two seconds, so the end of its log is one repeated line and the cause,
# logged once at start-up, is far above it. Without error lines, the distinct
# lines of the last 40 are shown instead.
summarize_node_log() {
  awk '
    function add(line, kind,   key) {
      sub(/^time="[^"]*" /, "", line)
      sub(/^[EFW][0-9][0-9][0-9][0-9] [0-9:.]+ +[0-9]+ /, "", line)
      line = substr(line, 1, 300)
      key = line
      gsub(/[0-9]+/, "#", key)
      if (!((kind, key) in count)) { n[kind]++; order[kind, n[kind]] = key; text[kind, key] = line }
      count[kind, key]++
    }
    { last[NR % 40] = $0 }
    /level=(error|fatal)|^[EF][0-9][0-9][0-9][0-9] |^Error|panic:/ { add($0, "err") }
    END {
      kind = "err"
      if (!n["err"]) { kind = "tail"; for (i = (NR > 40 ? NR - 39 : 1); i <= NR; i++) add(last[i % 40], kind) }
      first = n[kind] > 15 ? n[kind] - 14 : 1
      if (first > 1) print "(" first - 1 " earlier distinct lines omitted)"
      for (i = first; i <= n[kind]; i++) {
        key = order[kind, i]
        print text[kind, key] (count[kind, key] > 1 ? "   [x" count[kind, key] "]" : "")
      }
    }'
}

# Prints the distinct errors of each k3d container's log. k3d's own error
# only says a node "failed to get ready"; the reason (a crash-looping k3s
# agent, a resource limit) is in the container log.
dump_node_logs() {
  local node
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    echo "----- $node ($(docker inspect -f '{{.State.Status}}, restarts={{.RestartCount}}' "$node" 2>/dev/null || echo unknown)) -----" >&2
    docker logs "$node" 2>&1 | summarize_node_log | sed 's/^/    /' >&2 || true
  done <<<"$(docker ps -a --filter "label=k3d.cluster=$CLUSTER_NAME" --format '{{.Names}}' 2>/dev/null | sort)"
}

# The cluster's server, agent and load balancer containers as "<name> <role>
# <status>" lines. Other k3d containers (a tools container left behind by an
# interrupted k3d command) are not restarted by "k3d cluster start" and don't
# count.
cluster_node_states() {
  docker ps -a --filter "label=k3d.cluster=$CLUSTER_NAME" \
    --format '{{.Names}} {{.Label "k3d.role"}} {{.State}}' 2>/dev/null |
    awk '$2 == "server" || $2 == "agent" || $2 == "loadbalancer"' | sort
}

# Waits until every node container is running and stays up. "k3d cluster
# start --wait" can return while a container is still in Docker's restart
# loop (a k3s agent or the load balancer that started before its peers were
# reachable). A node counts as up when it is running, its restart count did
# not change between two checks 3s apart and, for servers and agents,
# containerd's socket exists.
wait_nodes_stable() {
  local deadline=$((SECONDS + ${1:-120})) snapshot previous="" node role ok
  while ((SECONDS < deadline)); do
    ok=1
    snapshot=""
    while read -r node role _; do
      [ -n "$node" ] || continue
      snapshot+="$node $(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$node" 2>/dev/null) "
      if [ "$(docker inspect -f '{{.State.Status}}' "$node" 2>/dev/null)" != running ]; then
        ok=0
      elif [ "$role" != loadbalancer ] &&
        ! docker exec "$node" test -S /run/k3s/containerd/containerd.sock >/dev/null 2>&1; then
        ok=0
      fi
    done <<<"$(cluster_node_states)"
    if ((ok)) && [ "$snapshot" = "$previous" ]; then
      return 0
    fi
    previous=""
    ((!ok)) || previous="$snapshot"
    sleep 3
  done
  return 1
}

# Creates the cluster from k3d.yaml, retrying when a node fails to come up.
# --no-rollback keeps the failed containers so their logs can be printed
# before the cluster is deleted; k3d would otherwise delete them first and the
# cause would be lost. One retry covers a node that fails once at start-up
# (a k3s agent crash-looping on a busy CI runner). Deleting the cluster keeps
# the WordPress and MariaDB Docker volumes.
create_cluster() {
  local attempt=1 attempts="${CLUSTER_CREATE_ATTEMPTS:-2}"
  while :; do
    k3d cluster create --config "$ROOT_DIR/k3d.yaml" --no-rollback && return 0
    echo "ERROR: cluster creation failed (attempt $attempt of $attempts). Node container logs:" >&2
    dump_node_logs
    k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
    ((attempt < attempts)) || die "could not create k3d cluster '$CLUSTER_NAME'."
    attempt=$((attempt + 1))
    sleep 5
    echo "Creating the k3d cluster again (attempt $attempt of $attempts)..."
  done
}

# Starts the cluster if any of its containers is stopped (after a Docker
# restart or "k3d cluster stop"), retrying once from a clean stop when a node
# fails to come back, then merges its kubeconfig and waits for the API. After a restart k3d sometimes reports the load balancer
# as restarting and never ready, or returns while k3s agents still
# crash-loop; the same cluster starts fine a moment later. A cluster whose
# containers all run is left alone.
start_existing_cluster() {
  local attempt=1 attempts="${CLUSTER_START_ATTEMPTS:-2}" _
  if awk '$3 != "running" { found = 1 } END { exit !found }' <<<"$(cluster_node_states)"; then
    until k3d cluster start "$CLUSTER_NAME" --wait --timeout "${CLUSTER_START_TIMEOUT:-300}s" >/dev/null &&
      wait_nodes_stable "${CLUSTER_STABLE_TIMEOUT:-120}"; do
      echo "ERROR: cluster start failed (attempt $attempt of $attempts). Node container logs:" >&2
      dump_node_logs
      ((attempt < attempts)) || die "could not start k3d cluster '$CLUSTER_NAME'."
      attempt=$((attempt + 1))
      k3d cluster stop "$CLUSTER_NAME" >/dev/null 2>&1 || true
      sleep 5
      echo "Starting the k3d cluster again (attempt $attempt of $attempts)..."
    done
  fi
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

# --- kubectl context handover ------------------------------------------------
# k3d.yaml switches the current kubectl context to the lab, so plain kubectl
# commands reach it. start.sh saves the context that was current before, and
# stop.sh switches back to it. The state file is keyed by cluster name. These
# helpers read and change the kubeconfig itself, so they call the real kubectl,
# not the --context wrapper above.
context_state_file() {
  printf '%s/k3d-wordpress-ha-poc/%s.previous-context\n' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "$CLUSTER_NAME"
}

context_exists() {
  command kubectl config get-contexts "$1" >/dev/null 2>&1
}

# Saves the current context unless it is the lab's own (a re-run of
# start.sh must not overwrite the context saved the first time) or empty.
remember_previous_context() {
  local current file
  current="$(command kubectl config current-context 2>/dev/null || true)"
  [ -n "$current" ] && [ "$current" != "$KUBE_CONTEXT" ] || return 0
  file="$(context_state_file)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '%s\n' "$current" >"$file" 2>/dev/null || true
}

# Succeeds if the lab's context is the current kubectl context, or none is
# (the cluster was deleted some other way). Check it before deleting the
# cluster: when k3d deletes the current context, it makes some other
# remaining context current, not necessarily the one from before.
lab_context_is_current() {
  local current
  current="$(command kubectl config current-context 2>/dev/null || true)"
  [ -z "$current" ] || [ "$current" = "$KUBE_CONTEXT" ]
}

# Switches back to the saved context if $1 is "yes", i.e. the lab's context
# was still current before the cluster was deleted. Otherwise another context
# was chosen after start.sh, and it is left alone.
restore_previous_context() {
  local file previous
  command -v kubectl >/dev/null 2>&1 || return 0
  file="$(context_state_file)"
  [ -f "$file" ] || return 0
  previous="$(head -n 1 "$file" 2>/dev/null || true)"
  if [ -z "$previous" ] || [ "${1:-}" != yes ]; then
    rm -f "$file"
    return 0
  fi
  if ! context_exists "$previous"; then
    echo "Previous kubectl context '$previous' no longer exists; leaving the current context unchanged." >&2
    rm -f "$file"
    return 0
  fi
  # The state is kept until the switch has worked, so a failure can be retried.
  if command kubectl config use-context "$previous" >/dev/null; then
    rm -f "$file"
    echo "Restored kubectl context: $previous"
  else
    echo "Could not switch back to '$previous'; run: kubectl config use-context $previous" >&2
  fi
}
