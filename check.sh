#!/usr/bin/env bash
# Runtime checks against a running lab:
#   - re-running the bootstrap changes no content and re-downloads no pinned
#     plugin
#   - Apache can write to files the WP-CLI bootstrap created
#   - WP-Cron runs from the CronJob
#   - the WP-CLI inventory Job runs and its output is free of PHP notices
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cluster

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Pinned "slug version" pairs from plugins.txt (blank lines, comments and
# @latest entries skipped).
pinned_plugins() {
  tr -d '\r' <"$ROOT_DIR/k8s/bootstrap/plugins.txt" |
    awk -F@ 'NF == 2 && $1 !~ /^#/ && $2 != "latest" { print $1, $2 }'
}

content_snapshot() {
  mariadb_query "
    SELECT CONCAT_WS(' ',
      (SELECT COUNT(*) FROM wp_posts WHERE post_type = 'page' AND post_status = 'publish'),
      (SELECT COUNT(*) FROM wp_posts WHERE post_type = 'post' AND post_status = 'publish'),
      (SELECT COUNT(*) FROM wp_posts WHERE post_type = 'attachment'),
      (SELECT COUNT(*) FROM wp_posts WHERE post_type = 'wpcf7_contact_form'),
      (SELECT COUNT(*) FROM wp_users),
      (SELECT COUNT(*) FROM wp_comments WHERE comment_approved = '1'),
      (SELECT COUNT(*) FROM wp_terms t
         JOIN wp_term_taxonomy tt ON tt.term_id = t.term_id
        WHERE tt.taxonomy = 'nav_menu' AND t.name = 'Primary'),
      (SELECT COUNT(*) FROM wp_term_relationships tr
         JOIN wp_term_taxonomy tt ON tt.term_taxonomy_id = tr.term_taxonomy_id
         JOIN wp_terms t ON t.term_id = tt.term_id
        WHERE tt.taxonomy = 'nav_menu' AND t.name = 'Primary')
    );"
}

describe_snapshot() {
  local pages posts media forms users comments menus items
  read -r pages posts media forms users comments menus items <<<"$1"
  echo "pages=$pages posts=$posts media=$media forms=$forms users=$users comments=$comments primary_menus=$menus primary_menu_items=$items"
}

echo "== Bootstrap idempotency"
before="$(content_snapshot)"
echo "Before: $(describe_snapshot "$before")"

read -r _ _ _ _ _ _ menus _ <<<"$before"
[ "$menus" = "1" ] || fail "expected exactly 1 Primary menu, found $menus"

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT
bash "$ROOT_DIR/reconfigure.sh" | tee "$log_file"

after="$(content_snapshot)"
echo
echo "After:  $(describe_snapshot "$after")"
[ "$before" = "$after" ] ||
  fail "a repeated bootstrap changed content counts"

# WP-CLI prints the table tab-separated when stdout isn't a terminal and with
# ASCII borders otherwise; strip the borders so both parse the same way.
plugin_table="$(sed -n '/Installed plugins:/,$p' "$log_file" | tr '|' ' ')"

while read -r slug version; do
  grep -qF "$slug is already pinned at $version; skipping download/reinstall." "$log_file" ||
    fail "$slug@$version was reinstalled on a repeated bootstrap"
  awk -v slug="$slug" -v version="$version" \
    '$1 == slug && $2 == "active" && $3 == version { found = 1 } END { exit !found }' \
    <<<"$plugin_table" ||
    fail "$slug is not active at pinned version $version"
done < <(pinned_plugins)

if grep -q '^ *Deprecated:' <<<"$plugin_table"; then
  fail "the bootstrap plugin table contains PHP deprecation notices"
fi
echo "Pinned plugins were kept without re-downloading."

echo
echo "== Shared file ownership"
# WP-CLI must create files that Apache (www-data, uid 33) can still modify.
for dir in wp-content wp-content/plugins $(pinned_plugins | awk '{ print "wp-content/plugins/" $1 }'); do
  kubectl exec -n "$NS" deployment/wordpress -c wordpress -- \
    su -s /bin/sh -c "test -w /var/www/html/$dir" www-data ||
    fail "Apache's www-data user cannot write to $dir"
done
echo "Apache can write to the plugin directories."

echo
echo "== WP-Cron"
cron_job="wp-cron-check-$(date +%s)"
trap 'rm -f "$log_file"; kubectl delete job "$cron_job" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true' EXIT
kubectl create job "$cron_job" -n "$NS" --from=cronjob/wordpress-cron >/dev/null
wait_for_job "$cron_job" 480 || fail "the WP-Cron Job failed"
kubectl logs -n "$NS" "job/$cron_job" | grep -q "WordPress cron trigger completed." ||
  fail "the WP-Cron Job did not trigger wp-cron.php"
echo "WP-Cron ran successfully."

echo
echo "== Inventory"
report="$(bash "$ROOT_DIR/wordpress-inventory.sh")"
if grep -Eq '^(PHP )?(Deprecated|Warning|Notice|Fatal error):' <<<"$report"; then
  fail "the inventory output contains PHP notices"
fi
while read -r slug _; do
  grep -qF "\"name\":\"$slug\"" <<<"$report" ||
    fail "the inventory does not list $slug"
done < <(pinned_plugins)
echo "Inventory ran cleanly and lists every pinned plugin."

echo
echo "PASS: runtime checks succeeded."
