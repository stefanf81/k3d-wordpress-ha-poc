#!/bin/sh
# Makes the accounts in an existing datadir match the Secrets. The MariaDB
# image applies MARIADB_ROOT_PASSWORD, MARIADB_USER, MARIADB_PASSWORD and
# MARIADB_DATABASE only when it initializes an empty datadir, so without this
# a changed password would leave MariaDB NotReady (its probes log in with the
# new value) and WordPress unable to connect.
#
# Runs as an init container before MariaDB starts: it starts a private server
# with --skip-grant-tables and no network, sets the passwords from the
# environment and shuts the server down again. No old password is needed, so
# this also works after the cluster was recreated around an existing volume.
set -eu

DATADIR=/var/lib/mysql
SOCKET=/tmp/reconcile.sock

if [ ! -d "$DATADIR/mysql" ]; then
  echo "Empty datadir: the MariaDB entrypoint will create the accounts."
  exit 0
fi

# SQL string literal and identifier quoting.
sql_string() {
  printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"
}
sql_ident() {
  printf '`%s`' "$(printf '%s' "$1" | sed 's/`/``/g')"
}

# The entrypoint does the same before starting the server.
find "$DATADIR" \! -user mysql -exec chown mysql: '{}' +

mariadbd \
  --user=mysql \
  --datadir="$DATADIR" \
  --skip-grant-tables \
  --skip-networking \
  --socket="$SOCKET" \
  --pid-file=/tmp/reconcile.pid &
server_pid=$!

i=0
until mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "ERROR: the temporary MariaDB server exited during startup." >&2
    exit 1
  fi
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "ERROR: the temporary MariaDB server did not start within 120s." >&2
    kill "$server_pid" 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

root_password="$(sql_string "$MARIADB_ROOT_PASSWORD")"
user="$(sql_string "$MARIADB_USER")"
password="$(sql_string "$MARIADB_PASSWORD")"
database="$(sql_ident "$MARIADB_DATABASE")"

# FLUSH PRIVILEGES loads the grant tables, which account statements need.
# It also turns authentication back on for new connections, so the server is
# shut down from this same session.
# A renamed database or user is created rather than renamed, so changing
# WORDPRESS_DB_NAME starts an empty site (the old database is kept).
mariadb --socket="$SOCKET" <<SQL
FLUSH PRIVILEGES;
ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY $root_password;
ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY $root_password;
CREATE DATABASE IF NOT EXISTS $database;
CREATE USER IF NOT EXISTS $user@'%' IDENTIFIED BY $password;
ALTER USER $user@'%' IDENTIFIED BY $password;
GRANT ALL PRIVILEGES ON $database.* TO $user@'%';
SHUTDOWN;
SQL

wait "$server_pid"
echo "MariaDB accounts match the Secrets."
