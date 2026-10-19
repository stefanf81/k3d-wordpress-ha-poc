#!/bin/sh
# Prepares the shared WordPress tree before Apache starts. Every replica runs
# this, so the one-time copy is serialised with a lock directory on the
# shared volume.
set -eu

SHARED=/shared
# Written only after the copy and chown finish, so an interrupted copy is
# retried instead of being mistaken for a complete tree.
MARKER="$SHARED/.wordpress-files-ready"
LOCK="$SHARED/.bootstrap-lock"
# A lock older than this was left behind by a pod killed mid-copy.
LOCK_STALE_MINUTES=10

# As PID 1 the shell ignores stop signals unless it installs a handler. The
# image's STOPSIGNAL is SIGWINCH (graceful Apache stop), so trap that as well
# as TERM: exiting runs the EXIT trap, so deleting the pod mid-copy releases
# the lock.
trap 'exit 143' TERM INT WINCH

copy_wordpress_files() {
  if [ -f "$SHARED/wp-includes/version.php" ]; then
    # A tree from an earlier revision, or an interrupted copy: add only the
    # missing files so core and plugin updates made by WP-CLI are kept.
    echo "Completing the existing shared WordPress files..."
    cp -a --update=none /usr/src/wordpress/. "$SHARED/"
  else
    echo "Bootstrapping shared WordPress files..."
    cp -a /usr/src/wordpress/. "$SHARED/"
  fi
  mkdir -p "$SHARED/wp-content/mu-plugins"
  # Apache and the WP-CLI Jobs both run as uid/gid 33.
  chown -R 33:33 "$SHARED"
  touch "$MARKER"
}

until [ -f "$MARKER" ]; do
  if mkdir "$LOCK" 2>/dev/null; then
    trap 'rm -rf "$LOCK"' EXIT
    [ -f "$MARKER" ] || copy_wordpress_files
    rm -rf "$LOCK"
    trap - EXIT
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
    echo "Removing a stale lock left by an interrupted pod..."
    rm -rf "$LOCK"
  else
    echo "Another pod is preparing the shared WordPress files; waiting..."
    sleep 2
  fi
done

test -f "$SHARED/wp-includes/version.php"
mkdir -p "$SHARED/wp-content/mu-plugins"

# Avoid nested ConfigMap subPath bind mounts inside the RWX /var/www/html
# mount: copy the read-only config files into the shared tree instead.
install_config() {
  src="$1"
  dst="$2"
  tmp="${dst}.tmp.$$"
  cp "$src" "$tmp"
  chmod 0444 "$tmp"
  chown 0:0 "$tmp"
  mv -f "$tmp" "$dst"
}

install_config /config/wp-config.php "$SHARED/wp-config.php"
install_config /config/healthz.php "$SHARED/healthz.php"
