#!/usr/bin/env bash
# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA

# End-to-end smoke test for mrsd (macOS/Linux).
#
# 1. starts a throwaway mysqld from a MySQL server package
# 2. deploys the MRS metadata schema (from mysql-shell-plugins)
# 3. creates an MRS account, keyring and mrsd config
# 4. starts mrsd, creates + publishes a REST view with MySQL Shell
# 5. checks that GET /smoke/smoke/city returns the rows
#
# Usage:
#   MRSD_BUILD=<mrsd build dir> MYSQL_PACKAGE_DIR=<server package> \
#   MYSQLSH=<path to mysqlsh> SHELL_PLUGINS=<mysql-shell-plugins checkout> \
#   tools/smoke/run_smoke.sh [workdir]
#
# SHELL_PLUGINS can also be a MySQL Shell package's lib/mysqlsh/plugins
# (it bundles mrs_plugin/db_schema).
#
# Windows: run from Git Bash with the DLL directories (MySQL lib/, OpenSSL and
# ICU bin/) on PATH.
#
# Ubuntu 24.04+: the package's mysqld needs libaio.so.1, which is now
# libaio.so.1t64. Point LD_LIBRARY_PATH at a directory with a
# libaio.so.1 -> /usr/lib/<arch>/libaio.so.1t64 symlink.
set -euo pipefail

MRSD_BUILD=${MRSD_BUILD:?set MRSD_BUILD}
MYSQL_PACKAGE_DIR=${MYSQL_PACKAGE_DIR:?set MYSQL_PACKAGE_DIR}
MYSQLSH=${MYSQLSH:?set MYSQLSH}
SHELL_PLUGINS=${SHELL_PLUGINS:?set SHELL_PLUGINS}
WORK=${1:-$(mktemp -d)}
PORT=${MYSQL_PORT:-13306}
HTTP_PORT=${HTTP_PORT:-18080}

# Windows (Git Bash): mysqld, mrsd and mysqlsh are native programs, so hand
# them C:/... paths; Git Bash itself accepts those too.
if command -v cygpath >/dev/null 2>&1; then
  mkdir -p "$WORK"
  WORK=$(cygpath -m "$WORK")
  MRSD_BUILD=$(cygpath -m "$MRSD_BUILD")
  MYSQL_PACKAGE_DIR=$(cygpath -m "$MYSQL_PACKAGE_DIR")
  SHELL_PLUGINS=$(cygpath -m "$SHELL_PLUGINS")
  [ -n "${MRS_SCRIPTS_DIR:-}" ] && MRS_SCRIPTS_DIR=$(cygpath -m "$MRS_SCRIPTS_DIR")
fi

SCHEMA_DIR=$SHELL_PLUGINS/mrs_plugin/db_schema
TASKS_SQL=$(ls "$SCHEMA_DIR"/mysql_tasks.msm.project/releases/deployment/*.sql | sort -V | tail -1)
MRS_SQL=$(ls "$SCHEMA_DIR"/mysql_rest_service_metadata.msm.project/releases/deployment/*.sql | sort -V | tail -1)

mkdir -p "$WORK"/{data,run,log,shellhome}
echo "workdir: $WORK"

mysql_cli() { "$MYSQL_PACKAGE_DIR/bin/mysql" -uroot -h127.0.0.1 -P"$PORT" "$@"; }
cleanup() {
  [ -n "${MRSD_PID:-}" ] && kill "$MRSD_PID" 2>/dev/null || true
  [ -n "${MYSQLD_PID:-}" ] && kill "$MYSQLD_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

# --- mysqld ------------------------------------------------------------------
"$MYSQL_PACKAGE_DIR/bin/mysqld" --no-defaults --initialize-insecure \
  --datadir="$WORK/mysqld" --basedir="$MYSQL_PACKAGE_DIR" > "$WORK/log/init.log" 2>&1
# relative socket name: the absolute path may exceed the 104-byte limit
"$MYSQL_PACKAGE_DIR/bin/mysqld" --no-defaults --datadir="$WORK/mysqld" \
  --basedir="$MYSQL_PACKAGE_DIR" --port="$PORT" --bind-address=127.0.0.1 \
  --socket=m.sock --mysqlx=OFF > "$WORK/log/mysqld.log" 2>&1 &
MYSQLD_PID=$!
for _ in $(seq 1 60); do
  grep -q 'ready for connections' "$WORK/log/mysqld.log" && break
  sleep 0.5
done

mysql_cli < "$TASKS_SQL"
mysql_cli < "$MRS_SQL"
mysql_cli -e "
  CREATE USER 'mrs_user'@'%' IDENTIFIED BY 'mrs-pass-1';
  GRANT 'mysql_rest_service_meta_provider','mysql_rest_service_data_provider'
    TO 'mrs_user'@'%';
  SET DEFAULT ROLE ALL TO 'mrs_user'@'%';
  CREATE SCHEMA smoke;
  CREATE TABLE smoke.city (id INT PRIMARY KEY, name VARCHAR(64));
  INSERT INTO smoke.city VALUES (1,'Lisbon'),(2,'Helsinki');"

# --- keyring + config --------------------------------------------------------
# the program name is set in cmake/settings.cmake
PROG=$(sed -n 's/^#define MRSD_PROGRAM_NAME "\(.*\)"$/\1/p' "$MRSD_BUILD/router_config.h")
BIN="$MRSD_BUILD/runtime_output_directory"
K="$BIN/$PROG-keyring"
KEY="--master-key-file=$WORK/$PROG.key"
"$K" init "$WORK/data/keyring" "$KEY"
"$K" set "$WORK/data/keyring" mrs_user password mrs-pass-1 "$KEY"
"$K" set "$WORK/data/keyring" rest-user jwt_secret 0123456789abcdef0123456789abcdef "$KEY"

cat > "$WORK/mrsd.conf" <<EOF
[DEFAULT]
logging_folder=$WORK/log
plugin_folder=$MRSD_BUILD/plugin_output_directory
runtime_folder=$WORK/run
data_folder=$WORK/data
keyring_path=$WORK/data/keyring
master_key_path=$WORK/$PROG.key

[logger]
level=debug

[http_server]
port=$HTTP_PORT
ssl=0

[mysql_rest_service]
mysql_user=mrs_user
mysql_read_write_destinations=127.0.0.1:$PORT
router_id=1
EOF

"$BIN/$PROG" -c "$WORK/mrsd.conf" \
  > "$WORK/log/mrsd.stdout" 2>&1 &
MRSD_PID=$!
sleep 3

# --- REST service ------------------------------------------------------------
cat > "$WORK/rest.sql" <<'EOF'
CREATE OR REPLACE REST SERVICE /smoke PUBLISHED;
CREATE OR REPLACE REST SCHEMA /smoke ON SERVICE /smoke FROM `smoke` AUTHENTICATION NOT REQUIRED;
CREATE OR REPLACE REST VIEW /city ON SERVICE /smoke SCHEMA /smoke AS `smoke`.`city` { id: id @KEY, name: name } AUTHENTICATION NOT REQUIRED;
EOF
MYSQLSH_USER_CONFIG_HOME="$WORK/shellhome" "$MYSQLSH" --no-wizard --sql \
  -uroot -h127.0.0.1 -P"$PORT" --file "$WORK/rest.sql"

fail() {
  echo "FAILED: $1" >&2
  grep -E ' (ERROR|WARNING) ' "$WORK/log/$PROG.log" >&2 || true
  exit 1
}

# wait for the metadata refresh (default: 5s)
ok=
for _ in $(seq 1 20); do
  body=$(curl -s "http://127.0.0.1:$HTTP_PORT/smoke/smoke/city" || true)
  if [[ "$body" == *Helsinki* ]]; then
    echo "OK (REST view): $body"
    ok=1
    break
  fi
  sleep 1
done
[ -n "$ok" ] || fail "REST view, last response: $body"

# --- optional: MRS scripts (JIT executor) ------------------------------------
# MRS_SCRIPTS_DIR: a built copy of mysql-shell-plugins'
# mrs_plugin/examples/mrs_scripts (npm install && npm run build).
if [ -n "${MRS_SCRIPTS_DIR:-}" ]; then
  echo "CREATE OR REPLACE REST CONTENT SET /scripts ON SERVICE /smoke FROM \"$MRS_SCRIPTS_DIR\" LOAD SCRIPTS;" \
    > "$WORK/scripts.sql"
  MYSQLSH_USER_CONFIG_HOME="$WORK/shellhome" "$MYSQLSH" --no-wizard --sql \
    -uroot -h127.0.0.1 -P"$PORT" --file "$WORK/scripts.sql"

  ok=
  for _ in $(seq 1 20); do
    body=$(curl -s "http://127.0.0.1:$HTTP_PORT/smoke/testScripts/helloWorld" || true)
    if [[ "$body" == *"Hello world!"* ]]; then
      echo "OK (MRS script): $body"
      ok=1
      break
    fi
    sleep 1
  done
  [ -n "$ok" ] || fail "MRS script, last response: $body"
fi
