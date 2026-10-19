#!/usr/bin/env bash
# Checks that the running lab matches its intended shape. Prints FAIL and
# exits non-zero on the first problem.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_commands docker curl
require_cluster

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "Checking Kubernetes nodes..."
workers="$(kubectl get nodes -l workload=wordpress --no-headers | wc -l | tr -d ' ')"
[ "$workers" = "3" ] || fail "expected 3 WordPress workers, found $workers"

echo "Checking that the site is published on localhost only..."
lb_bindings="$(docker port "k3d-${CLUSTER_NAME}-serverlb" 80/tcp 2>/dev/null || true)"
[ -n "$lb_bindings" ] || fail "k3d load balancer does not publish port 80"
if grep -qv '^127\.0\.0\.1:' <<<"$lb_bindings"; then
  fail "site is published beyond localhost ($(tr '\n' ' ' <<<"$lb_bindings")); recreate with ./stop.sh && ./start.sh"
fi

echo "Checking Traefik HA..."
traefik_available="$(
  kubectl get deployment traefik \
    -n kube-system \
    -o jsonpath='{.status.availableReplicas}'
)" || fail "Traefik deployment not found"
[ "${traefik_available:-0}" = "3" ] ||
  fail "expected 3 available Traefik replicas, found ${traefik_available:-0}"

traefik_nodes="$(
  kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=traefik \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    sort -u | wc -l | tr -d ' '
)"
[ "$traefik_nodes" = "3" ] || fail "Traefik replicas are not spread across 3 nodes"

echo "Checking WordPress replicas..."
available="$(
  kubectl get deployment wordpress -n "$NS" -o jsonpath='{.status.availableReplicas}'
)" || fail "WordPress deployment not found"
[ "${available:-0}" = "3" ] || fail "expected 3 available WordPress replicas, found ${available:-0}"

distinct_nodes="$(
  kubectl get pods -n "$NS" -l app=wordpress \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    sort -u | wc -l | tr -d ' '
)"
[ "$distinct_nodes" = "3" ] || fail "WordPress replicas are not spread across 3 nodes"

echo "Checking MariaDB Docker named volume..."
docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1 ||
  fail "Docker volume $MARIADB_DATA_VOLUME does not exist"

server_mount="$(
  docker inspect "k3d-${CLUSTER_NAME}-server-0" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mariadb-data"}}{{.Type}}|{{.Name}}{{end}}{{end}}'
)" || fail "k3d server node container not found"
[ "$server_mount" = "volume|$MARIADB_DATA_VOLUME" ] ||
  fail "server node MariaDB mount is '$server_mount', expected volume|$MARIADB_DATA_VOLUME"

lower_case_table_names="$(mariadb_query 'SELECT @@lower_case_table_names;')" ||
  fail "could not query MariaDB"
[ "$lower_case_table_names" = "0" ] ||
  fail "MariaDB lower_case_table_names=$lower_case_table_names; expected 0"

echo "Checking PVCs..."
for pvc in wordpress-shared mariadb-data; do
  phase="$(kubectl get pvc "$pvc" -n "$NS" -o jsonpath='{.status.phase}')" ||
    fail "PVC $pvc not found"
  [ "$phase" = "Bound" ] || fail "PVC $pvc is $phase"
done

echo "Checking network policies and service accounts..."
for policy in default-deny-ingress allow-wordpress-http allow-mariadb-from-wordpress; do
  kubectl get networkpolicy "$policy" -n "$NS" >/dev/null ||
    fail "NetworkPolicy $policy not found"
done
for account in wordpress-runtime mariadb-runtime wordpress-bootstrap wordpress-cron wordpress-inventory; do
  kubectl get serviceaccount "$account" -n "$NS" >/dev/null ||
    fail "ServiceAccount $account not found"
done

echo "Checking PodDisruptionBudget..."
desired="$(kubectl get pdb wordpress -n "$NS" -o jsonpath='{.status.desiredHealthy}')" ||
  fail "PodDisruptionBudget wordpress not found"
[ "${desired:-0}" -ge 2 ] || fail "PDB desiredHealthy is ${desired:-0}"

echo "Checking dedicated WordPress readiness endpoint..."
for pod in $(kubectl get pods -n "$NS" -l app=wordpress -o name); do
  kubectl exec -n "$NS" -c wordpress "${pod#pod/}" -- \
    php -r '
      $body = @file_get_contents("http://127.0.0.1/healthz.php");
      if (trim((string) $body) !== "ok") { exit(1); }
    ' || fail "healthz.php is not healthy in ${pod#pod/}"
done

echo "Checking WordPress HTTP..."
code="$(
  curl --silent --location --output /dev/null --write-out '%{http_code}' \
    --max-time 15 "$SITE_URL/" || true
)"
case "$code" in
  200 | 301 | 302 | 307 | 308) ;;
  *) fail "WordPress returned HTTP $code" ;;
esac

echo "Checking WordPress database connectivity..."
kubectl exec -n "$NS" deployment/wordpress -c wordpress -- \
  php -r '
    require "/var/www/html/wp-load.php";
    global $wpdb;
    $value = $wpdb->get_var("SELECT 1");
    if ((string) $value !== "1") { exit(1); }
    echo "database OK\n";
  ' || fail "WordPress cannot query its database"

echo "Checking bootstrap completion..."
condition="$(
  kubectl get job wordpress-bootstrap -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}'
)" || fail "bootstrap Job not found"
[ "$condition" = "True" ] || fail "bootstrap Job is not complete"

echo
echo "PASS: k3d WordPress HA PoC checks succeeded."
