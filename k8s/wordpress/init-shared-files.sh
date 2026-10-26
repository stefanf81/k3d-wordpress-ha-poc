#!/bin/sh
# Prepares the shared WordPress tree before Apache starts. Every replica runs
# this. The one-time copy runs under an flock(1) lock on the shared volume.
# The kernel releases the lock when its holder exits or is killed, so there is
# no stale-lock state to detect or race over.
set -eu

SHARED=/shared
# Written only after the copy and chown finish, so an interrupted copy is
# retried instead of being mistaken for a complete tree.
MARKER="$SHARED/.wordpress-files-ready"
LOCK="$SHARED/.wordpress-files.lock"

# As PID 1 the shell ignores stop signals unless it installs a handler. The
# image's STOPSIGNAL is SIGWINCH (graceful Apache stop), so trap that as well
# as TERM. A trap runs only after the foreground command finishes, so the copy
# runs in the background and is waited for; a stop signal then exits at once.
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

# Fails, rather than waiting forever, when the shared volume is read-only or full.
exec 9>"$LOCK" || {
  echo "ERROR: cannot open $LOCK" >&2
  exit 1
}

# Poll instead of blocking in flock: a blocked foreground command would delay
# a stop signal until the lock is free.
until flock -n 9; do
  echo "Another pod is preparing the shared WordPress files; waiting..."
  sleep 2
done

if [ ! -f "$MARKER" ]; then
  # The copy's subshell closes the lock descriptor first. Otherwise it would
  # keep the lock after this script exits. The container's PID 1 ends the
  # copy with it, so no copy outlives the lock.
  (
    exec 9>&-
    copy_wordpress_files
  ) &
  copy_pid=$!
  wait "$copy_pid"
fi
exec 9>&-

# Older revisions copied wp-config.php and healthz.php into the shared tree. A
# copy there shadows the per-pod mounts, so config edits would never reach the
# replicas. Every replica mounts its own config now, and the move to the Docker
# volume recreates the cluster, so no old pod still reads them. Removing a
# missing file is a no-op, and concurrent replicas can do it safely.
rm -f "$SHARED/wp-config.php" "$SHARED/healthz.php"

test -f "$SHARED/wp-includes/version.php"
mkdir -p "$SHARED/wp-content/mu-plugins"
