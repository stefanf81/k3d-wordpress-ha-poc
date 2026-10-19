#!/bin/sh
# Triggers WP-Cron once WordPress has a Ready endpoint. During a rollout or
# the initial bootstrap the Service can briefly have none, so wait (up to
# about 5 minutes) instead of failing on "Failed to connect". If WordPress
# stays unavailable the Job fails so the outage stays visible.
set -eu

echo "Waiting for a ready WordPress Service endpoint..."

attempt=0
max_attempts=60

until curl \
  --fail \
  --silent \
  --show-error \
  --connect-timeout 2 \
  --max-time 5 \
  http://wordpress/healthz.php >/dev/null 2>&1
do
  attempt=$((attempt + 1))

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "ERROR: WordPress did not become ready within 5 minutes." >&2
    exit 1
  fi

  sleep 5
done

echo "WordPress is ready; triggering wp-cron.php..."

curl \
  --fail \
  --silent \
  --show-error \
  --retry 3 \
  --retry-all-errors \
  --retry-delay 2 \
  --connect-timeout 5 \
  --max-time 30 \
  "http://wordpress/wp-cron.php?doing_wp_cron"

echo
echo "WordPress cron trigger completed."
