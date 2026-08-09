#!/usr/bin/env bash
set -euo pipefail

NS="wordpress-poc"
MARIADB_DATA_VOLUME="${MARIADB_DATA_VOLUME:-wordpress-ha-poc-mariadb-data}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "Checking Kubernetes nodes..."
workers="$(kubectl get nodes -l workload=wordpress --no-headers | wc -l | tr -d ' ')"
[ "$workers" = "3" ] || fail "expected 3 WordPress workers, found $workers"

echo "Checking Traefik HA..."
traefik_available="$(
  kubectl get deployment traefik     -n kube-system     -o jsonpath='{.status.availableReplicas}'
)"
[ "${traefik_available:-0}" = "3" ] ||   fail "expected 3 available Traefik replicas, found ${traefik_available:-0}"

traefik_nodes="$(
  kubectl get pods     -n kube-system     -l app.kubernetes.io/name=traefik     -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    sort -u | wc -l | tr -d ' '
)"
[ "$traefik_nodes" = "3" ] ||   fail "Traefik replicas are not spread across 3 nodes"

echo "Checking WordPress replicas..."
available="$(kubectl get deployment wordpress -n "$NS" -o jsonpath='{.status.availableReplicas}')"
[ "${available:-0}" = "3" ] || fail "expected 3 available WordPress replicas, found ${available:-0}"

distinct_nodes="$(
  kubectl get pods -n "$NS" -l app=wordpress \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    sort -u | wc -l | tr -d ' '
)"
[ "$distinct_nodes" = "3" ] || fail "WordPress replicas are not spread across 3 nodes"

echo "Checking MariaDB Docker named volume..."
docker volume inspect "$MARIADB_DATA_VOLUME" >/dev/null 2>&1 || \
  fail "Docker volume $MARIADB_DATA_VOLUME does not exist"

server_mount="$(
  docker inspect k3d-wordpress-ha-poc-server-0 \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mariadb-data"}}{{.Type}}|{{.Name}}{{end}}{{end}}'
)"
[ "$server_mount" = "volume|$MARIADB_DATA_VOLUME" ] || \
  fail "server node MariaDB mount is '$server_mount', expected volume|$MARIADB_DATA_VOLUME"

lower_case_table_names="$(
  kubectl exec -n "$NS" deployment/mariadb -- \
    /bin/sh -ec '
      mariadb \
        --protocol=tcp \
        --host=127.0.0.1 \
        --user="$MARIADB_USER" \
        --password="$MARIADB_PASSWORD" \
        "$MARIADB_DATABASE" \
        --batch \
        --skip-column-names \
        --execute="SELECT @@lower_case_table_names;"
    '
)"
[ "$lower_case_table_names" = "0" ] || \
  fail "MariaDB lower_case_table_names=$lower_case_table_names; expected 0"

echo "Checking PVCs..."
for pvc in wordpress-shared mariadb-data; do
  phase="$(kubectl get pvc "$pvc" -n "$NS" -o jsonpath='{.status.phase}')"
  [ "$phase" = "Bound" ] || fail "PVC $pvc is $phase"
done

echo "Checking network policies and service accounts..."
kubectl get networkpolicy default-deny-ingress -n "$NS" >/dev/null
kubectl get networkpolicy allow-wordpress-http -n "$NS" >/dev/null
kubectl get networkpolicy allow-mariadb-from-wordpress -n "$NS" >/dev/null
kubectl get serviceaccount wordpress-runtime -n "$NS" >/dev/null

echo "Checking PodDisruptionBudget..."
desired="$(kubectl get pdb wordpress -n "$NS" -o jsonpath='{.status.desiredHealthy}')"
[ "${desired:-0}" -ge 2 ] || fail "PDB desiredHealthy is ${desired:-0}"

echo "Checking dedicated WordPress readiness endpoint..."
for pod in $(kubectl get pods -n "$NS" -l app=wordpress -o name); do
  kubectl exec -n "$NS" -c wordpress "${pod#pod/}" -- \
    php -r '
      $url = "http://127.0.0.1/healthz.php";
      $body = @file_get_contents($url);
      if (trim((string)$body) !== "ok") { exit(1); }
    '
done

echo "Checking WordPress HTTP..."
code="$(curl --silent --location --output /dev/null --write-out '%{http_code}' \
  --max-time 15 http://localhost:8080/ || true)"
case "$code" in
  200|301|302|307|308) ;;
  *) fail "WordPress returned HTTP $code" ;;
esac

echo "Checking WordPress database connectivity..."
kubectl exec -n "$NS" deployment/wordpress -c wordpress -- \
  php -r '
    require "/var/www/html/wp-load.php";
    global $wpdb;
    $value = $wpdb->get_var("SELECT 1");
    if ((string)$value !== "1") { exit(1); }
    echo "database OK\n";
  '

echo "Checking bootstrap completion..."
condition="$(
  kubectl get job wordpress-bootstrap -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}'
)"
[ "$condition" = "True" ] || fail "bootstrap Job is not complete"

echo
echo "PASS: k3d WordPress HA PoC checks succeeded."
