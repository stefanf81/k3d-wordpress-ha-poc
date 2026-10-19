#!/bin/sh
# Prints the installed core, plugin and theme versions. --skip-plugins and
# --skip-themes keep plugin runtime notices (e.g. PHP 8.5 deprecations) out
# of the JSON while still reporting versions, status and update metadata.
set -eu

cd /var/www/html

echo "=== WordPress core ==="
wp core version

echo
echo "=== Plugins JSON ==="
wp plugin list \
  --skip-plugins \
  --skip-themes \
  --fields=name,status,version,update,update_version \
  --format=json

echo
echo "=== Themes JSON ==="
wp theme list \
  --skip-plugins \
  --skip-themes \
  --fields=name,status,version,update,update_version \
  --format=json
