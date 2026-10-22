#!/bin/sh
# Central WP-CLI reconciler: installs WordPress, pins core and plugins, seeds
# the demo content and applies plugin settings. Safe to run repeatedly.
set -eu

cd /var/www/html

echo "Waiting for the shared WordPress files..."
i=0
# The WordPress init container writes the marker after its copy completes.
# wp-config.php is mounted one level above the root.
until [ -f .wordpress-files-ready ] && [ -f /var/www/wp-config.php ]; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "Timed out waiting for WordPress files." >&2
    exit 1
  fi
  sleep 2
done

if wp core is-installed >/dev/null 2>&1; then
  echo "WordPress is already installed."
else
  echo "Installing WordPress..."
  wp core install \
    --url="$SITE_URL" \
    --title="$SITE_TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$ADMIN_PASSWORD" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email
fi

echo "Reconciling WordPress core..."
if [ "$WORDPRESS_CORE_VERSION" = "latest" ]; then
  wp core update
else
  current_core="$(wp core version)"
  if [ "$current_core" != "$WORDPRESS_CORE_VERSION" ]; then
    wp core update \
      --version="$WORDPRESS_CORE_VERSION" \
      --force
  else
    echo "WordPress core is already pinned at $WORDPRESS_CORE_VERSION."
  fi
fi
wp core update-db

echo "Applying site settings..."
wp option update home "$SITE_URL"
wp option update siteurl "$SITE_URL"
wp option update timezone_string "$TIMEZONE"
wp rewrite structure '/%postname%/' --hard

echo "Reconciling plugins..."
while IFS= read -r spec || [ -n "$spec" ]; do
  # Trim CR and ignore blanks/comments.
  spec="$(printf '%s' "$spec" | tr -d '\r')"
  case "$spec" in
    ""|\#*) continue ;;
  esac

  case "$spec" in
    *@*)
      plugin="${spec%@*}"
      version="${spec##*@}"
      ;;
    *)
      plugin="$spec"
      version="latest"
      ;;
  esac

  if [ -z "$plugin" ] || [ -z "$version" ]; then
    echo "ERROR: invalid plugin specification: $spec" >&2
    exit 1
  fi

  if [ "$version" = "latest" ]; then
    if wp plugin is-installed "$plugin"; then
      echo "Updating $plugin to latest stable..."
      wp plugin update "$plugin" || true
      wp plugin activate "$plugin"
    else
      echo "Installing latest $plugin..."
      wp plugin install "$plugin" --activate
    fi
  else
    # Read the installed version without loading site plugins/themes.
    # PHP 8.5 deprecation notices from active plugins can otherwise pollute
    # command substitution and make a correct version look different.
    installed_version="$(
      wp plugin get "$plugin" \
        --field=version \
        --skip-plugins \
        --skip-themes \
        2>/dev/null \
        | awk 'NF { value=$0 } END { print value }' \
        || true
    )"

    if [ "$installed_version" = "$version" ]; then
      echo "$plugin is already pinned at $version; skipping download/reinstall."

      if wp plugin is-active "$plugin" >/dev/null 2>&1; then
        echo "$plugin is already active."
      else
        echo "Activating $plugin..."
        wp plugin activate "$plugin"
      fi
    else
      if [ -n "$installed_version" ]; then
        echo "Reconciling $plugin: $installed_version -> $version"
      else
        echo "Installing $plugin at pinned version $version..."
      fi

      wp plugin install "$plugin" \
        --version="$version" \
        --force \
        --activate
    fi
  fi

  # Keep explicit PoC pins under bootstrap control rather than
  # allowing WordPress core's plugin auto-update mechanism to
  # silently change them between test runs.
  wp plugin auto-updates disable "$plugin" >/dev/null 2>&1 || true
done < /bootstrap/plugins.txt

echo "Seeding realistic Northstar Digital content..."
/bin/sh /bootstrap/seed-site.sh

echo "Applying common plugin configuration..."
wp eval-file /bootstrap/configure-plugins.php

if wp plugin is-active redirection >/dev/null 2>&1; then
  echo "Initializing/upgrading Redirection database..."
  wp redirection database install >/dev/null 2>&1 || \
    wp redirection database upgrade >/dev/null 2>&1 || true
fi

echo "Running plugin/site configuration hook..."
/bin/sh /bootstrap/after-install.sh

echo
echo "Installed plugins:"
wp plugin list \
  --skip-plugins \
  --skip-themes \
  --fields=name,status,version,update \
  --format=table

echo
echo "WordPress bootstrap complete."
