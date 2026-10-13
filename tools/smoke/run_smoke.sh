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
# 1. starts a throwaway mariadbd from a MariaDB server build tree or package
# 2. deploys the MRS metadata schema (from the MariaDB shell plugins)
# 3. configures mrsd with --setup (MRS account, keyring, config)
# 4. starts mrsd, creates + publishes a REST view with the MariaDB shell
# 5. checks that GET /smoke/smoke/city returns the rows and that the
#    running instance uses the registration of --setup
#
# Usage:
#   MRSD_BUILD=<mrsd build dir> MARIADB_PACKAGE_DIR=<server package> \
#   MYSQLSH=<path to mariadb-shell> SHELL_PLUGINS=<plugins, see below> \
#   tools/smoke/run_smoke.sh [workdir]
#
# MRSD_INSTALL=<installed or unpacked package> instead of MRSD_BUILD tests a
# package (its bundled libraries and default plugin folder).
#
# Windows: run from Git Bash with the DLL directories (Connector/C, OpenSSL
# and ICU bin/) on PATH, plus the OpenSSL DLLs the server needs (the Windows
# sandbox package has none: the shell's bin/).
set -euo pipefail

# MRSD_BUILD: a build directory, or MRSD_INSTALL: an installed/unpacked package
if [ -z "${MRSD_INSTALL:-}" ]; then
  MRSD_BUILD=${MRSD_BUILD:?set MRSD_BUILD or MRSD_INSTALL}
fi
# The server, one of:
#   MARIADB_BUILD_DIR    a MariaDB server build tree (sql/mariadbd,
#                        client/mariadb, scripts/mariadb-install-db, which
#                        needs MARIADB_SOURCE_DIR)
#   MARIADB_PACKAGE_DIR  a MariaDB server package (bin/mariadbd,
#                        bin/mariadb-install-db[.exe] or
#                        scripts/mariadb-install-db, share/); without a
#                        bin/mariadb client (e.g. the Windows sandbox
#                        package) the SQL goes through $MYSQLSH --sql
# MYSQLSH is the mariadb-shell and SHELL_PLUGINS the mariadb-shell-plugins
# checkout, linked into the shell's user plugins, or the shell package's own
# lib/mariadb-shell/plugins (used as is).
if [ -n "${MARIADB_BUILD_DIR:-}" ]; then
  MARIADB_SOURCE_DIR=${MARIADB_SOURCE_DIR:?set MARIADB_SOURCE_DIR}
else
  MARIADB_PACKAGE_DIR=${MARIADB_PACKAGE_DIR:?set MARIADB_BUILD_DIR or MARIADB_PACKAGE_DIR}
fi
MYSQLSH=${MYSQLSH:?set MYSQLSH}
SHELL_PLUGINS=${SHELL_PLUGINS:?set SHELL_PLUGINS}
WORK=${1:-$(mktemp -d)}
PORT=${MYSQL_PORT:-13306}
HTTP_PORT=${HTTP_PORT:-18080}

# Windows (Git Bash): mariadbd, mrsd and the shell are native programs, so hand
# them C:/... paths; Git Bash itself accepts those too.
if command -v cygpath >/dev/null 2>&1; then
  mkdir -p "$WORK"
  WORK=$(cygpath -m "$WORK")
  [ -n "${MRSD_BUILD:-}" ] && MRSD_BUILD=$(cygpath -m "$MRSD_BUILD")
  [ -n "${MRSD_INSTALL:-}" ] && MRSD_INSTALL=$(cygpath -m "$MRSD_INSTALL")
  [ -n "${MARIADB_PACKAGE_DIR:-}" ] && MARIADB_PACKAGE_DIR=$(cygpath -m "$MARIADB_PACKAGE_DIR")
  SHELL_PLUGINS=$(cygpath -m "$SHELL_PLUGINS")
  [ -n "${MRS_SCRIPTS_DIR:-}" ] && MRS_SCRIPTS_DIR=$(cygpath -m "$MRS_SCRIPTS_DIR")
fi

SCHEMA_DIR=$SHELL_PLUGINS/mrs_plugin/db_schema
MRS_SQL=$(ls "$SCHEMA_DIR"/mysql_rest_service_metadata.msm.project/releases/deployment/*.sql | sort -V | tail -1)

mkdir -p "$WORK"/{log,shellhome}
echo "workdir: $WORK"

# sql_file <file>, sql_exec <statements>, sql_value <query>: run SQL as root
MARIADB_CLIENT=
if [ -n "${MARIADB_BUILD_DIR:-}" ]; then
  MARIADB_CLIENT=$MARIADB_BUILD_DIR/client/mariadb
elif [ -n "${MARIADB_PACKAGE_DIR:-}" ]; then
  for c in "$MARIADB_PACKAGE_DIR/bin/mariadb" "$MARIADB_PACKAGE_DIR/bin/mariadb.exe"; do
    [ -x "$c" ] && MARIADB_CLIENT=$c && break
  done
fi
if [[ "$SHELL_PLUGINS" != */lib/mariadb-shell/plugins ]]; then
  # a plugins checkout: the shell's own plugin directory is
  # <MARIADB_SHELL_USER_CONFIG_HOME>/plugins
  mkdir -p "$WORK/shellhome/plugins"
  ln -sfn "$SHELL_PLUGINS/mrs_plugin" "$WORK/shellhome/plugins/mrs_plugin"
  ln -sfn "$SHELL_PLUGINS/msm_plugin" "$WORK/shellhome/plugins/msm_plugin"  # used by mrs
fi
export MARIADB_SHELL_USER_CONFIG_HOME="$WORK/shellhome"
if [ -z "$MARIADB_CLIENT" ]; then
  shell_sql() { "$MYSQLSH" --no-wizard --sql -uroot -h127.0.0.1 -P"$PORT" "$@"; }
  sql_file() { shell_sql --file "$1"; }
  sql_exec() { shell_sql -e "$1"; }
  # tab-separated output with a header line
  sql_value() { shell_sql --result-format=tabbed -e "$1" | tail -1 | tr -d '\r'; }
else
  mysql_cli() { "$MARIADB_CLIENT" -uroot -h127.0.0.1 -P"$PORT" "$@"; }
  sql_file() { mysql_cli < "$1"; }
  sql_exec() { mysql_cli -e "$1"; }
  sql_value() { mysql_cli -N -e "$1" | tr -d '\r'; }
fi
cleanup() {
  [ -n "${MRSD_PID:-}" ] && kill "$MRSD_PID" 2>/dev/null || true
  [ -n "${MYSQLD_PID:-}" ] && kill "$MYSQLD_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

# --- mariadbd ----------------------------------------------------------------
if [ -n "${MARIADB_BUILD_DIR:-}" ]; then
  # absolute socket path: may exceed the 104-byte limit under $WORK
  SOCK=/tmp/mrsd-smoke-$PORT.sock
  "$MARIADB_BUILD_DIR/scripts/mariadb-install-db" --no-defaults \
    --srcdir="$MARIADB_SOURCE_DIR" --builddir="$MARIADB_BUILD_DIR" \
    --datadir="$WORK/mysqld" --auth-root-authentication-method=normal \
    > "$WORK/log/init.log" 2>&1
  "$MARIADB_BUILD_DIR/sql/mariadbd" --no-defaults --datadir="$WORK/mysqld" \
    --lc-messages-dir="$MARIADB_BUILD_DIR/sql/share" --port="$PORT" \
    --bind-address=127.0.0.1 --socket="$SOCK" > "$WORK/log/mysqld.log" 2>&1 &
  MYSQLD_PID=$!
  for _ in $(seq 1 60); do
    grep -q 'ready for connections' "$WORK/log/mysqld.log" && break
    sleep 0.5
  done
  # mariadb-install-db creates root@localhost only, plus anonymous accounts
  # (''@localhost, ''@<host>) that shadow every '%' account for local
  # connections, the daemon's included
  "$MARIADB_BUILD_DIR/client/mariadb" -uroot -S "$SOCK" -e "
    CREATE USER IF NOT EXISTS root@'127.0.0.1'; GRANT ALL ON *.* TO root@'127.0.0.1' WITH GRANT OPTION;
    DELETE FROM mysql.global_priv WHERE user=''; FLUSH PRIVILEGES;"
else
  P=$MARIADB_PACKAGE_DIR
  if [ -e "$P/bin/mariadb-install-db.exe" ]; then
    # Windows' installer: root reachable over TCP (-R), no anonymous accounts
    "$P/bin/mariadb-install-db.exe" -d "$WORK/mysqld" -R > "$WORK/log/init.log" 2>&1
  else
    "$P/scripts/mariadb-install-db" --no-defaults --basedir="$P" \
      --datadir="$WORK/mysqld" --auth-root-authentication-method=normal \
      > "$WORK/log/init.log" 2>&1
  fi
  SOCK_OPT=()
  if ! command -v cygpath >/dev/null 2>&1; then
    SOCK_OPT=(--socket=/tmp/mrsd-smoke-$PORT.sock)  # no unix sockets on Windows
  fi
  # the error log explicitly: on Windows it would go to <datadir>/<host>.err
  "$P/bin/mariadbd" --no-defaults --basedir="$P" --datadir="$WORK/mysqld" \
    --port="$PORT" --bind-address=127.0.0.1 ${SOCK_OPT[@]+"${SOCK_OPT[@]}"} \
    --log-error="$WORK/log/mysqld.log" > "$WORK/log/mysqld.out" 2>&1 &
  MYSQLD_PID=$!
  for _ in $(seq 1 120); do
    grep -q 'ready for connections' "$WORK/log/mysqld.log" 2>/dev/null && break
    sleep 0.5
  done
  # Unix' mariadb-install-db: root@localhost only, plus anonymous accounts
  # that shadow every '%' account for local connections
  sql_exec "CREATE USER IF NOT EXISTS root@'127.0.0.1'; GRANT ALL ON *.* TO root@'127.0.0.1' WITH GRANT OPTION; DELETE FROM mysql.global_priv WHERE user=''; FLUSH PRIVILEGES;"
fi

sql_file "$MRS_SQL"
sql_exec "
  CREATE SCHEMA smoke;
  CREATE TABLE smoke.city (id INT PRIMARY KEY, name VARCHAR(64));
  INSERT INTO smoke.city VALUES (1,'Lisbon'),(2,'Helsinki');"

# --- mrsd --setup ------------------------------------------------------------
# the program name is set in cmake/settings.cmake
if [ -n "${MRSD_INSTALL:-}" ]; then
  BIN="$MRSD_INSTALL/bin"
  # <program>-keyring is the keyring tool
  PROG=$(cd "$BIN" && ls | sed -n 's/-keyring\(\.exe\)\{0,1\}$//p' | head -1)
  # the installed default, unless the package is unpacked elsewhere than its
  # absolute defaults (deb/rpm contents): MRSD_PLUGIN_FOLDER
  PLUGIN_OPTION=${MRSD_PLUGIN_FOLDER:+--conf-set-option=DEFAULT.plugin_folder=$MRSD_PLUGIN_FOLDER}
else
  PROG=$(sed -n 's/^#define MRSD_PROGRAM_NAME "\(.*\)"$/\1/p' "$MRSD_BUILD/router_config.h")
  BIN="$MRSD_BUILD/runtime_output_directory"
  PLUGIN_OPTION=--conf-set-option=DEFAULT.plugin_folder="$MRSD_BUILD/plugin_output_directory"
fi
DEPLOY="$WORK/mrsd"
# MRSD_SETUP_DEFAULT_FOLDERS=1 (with MRSD_INSTALL): --setup without -d writes
# to the package's default folders, and mrsd starts without -c
DEPLOY_ARGS=(-d "$DEPLOY")
START_ARGS=(-c "$DEPLOY/$PROG.conf")
if [ "${MRSD_SETUP_DEFAULT_FOLDERS:-}" = 1 ]; then
  DEPLOY_ARGS=()
  START_ARGS=()
fi
# root has no password: the prompt reads an empty line
echo | "$BIN/$PROG" --setup "root@127.0.0.1:$PORT" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"} \
  --jwt-secret 0123456789abcdef0123456789abcdef \
  ${PLUGIN_OPTION:+"$PLUGIN_OPTION"} \
  --conf-set-option=http_server.port="$HTTP_PORT" \
  --conf-set-option=http_server.ssl=0 \
  --conf-set-option=logger.level=debug

"$BIN/$PROG" ${START_ARGS[@]+"${START_ARGS[@]}"} > "$WORK/log/mrsd.stdout" 2>&1 &
MRSD_PID=$!
sleep 3

# --- REST service ------------------------------------------------------------
cat > "$WORK/rest.sql" <<'EOF'
CREATE OR REPLACE REST SERVICE /smoke PUBLISHED;
CREATE OR REPLACE REST SCHEMA /smoke ON SERVICE /smoke FROM `smoke` AUTHENTICATION NOT REQUIRED;
CREATE OR REPLACE REST VIEW /city ON SERVICE /smoke SCHEMA /smoke AS `smoke`.`city` { id: id @KEY, name: name } AUTHENTICATION NOT REQUIRED;
EOF
MARIADB_SHELL_USER_CONFIG_HOME="$WORK/shellhome" "$MYSQLSH" --no-wizard --sql \
  -uroot -h127.0.0.1 -P"$PORT" --file "$WORK/rest.sql"

fail() {
  echo "FAILED: $1" >&2
  grep -E ' (ERROR|WARNING) ' "$DEPLOY/log/$PROG.log" >&2 || true
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

# the running instance uses the registration of --setup: still one row
routers=$(sql_value "SELECT COUNT(*) FROM mysql_rest_service_metadata.router")
[ "$routers" = 1 ] || fail "expected 1 registered instance, found $routers"
echo "OK (one registered instance)"

# --- optional: MRS scripts (JIT executor) ------------------------------------
# MRS_SCRIPTS_DIR: a built copy of mysql-shell-plugins'
# mrs_plugin/examples/mrs_scripts (npm install && npm run build).
if [ -n "${MRS_SCRIPTS_DIR:-}" ]; then
  echo "CREATE OR REPLACE REST CONTENT SET /scripts ON SERVICE /smoke FROM \"$MRS_SCRIPTS_DIR\" LOAD SCRIPTS;" \
    > "$WORK/scripts.sql"
  MARIADB_SHELL_USER_CONFIG_HOME="$WORK/shellhome" "$MYSQLSH" --no-wizard --sql \
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
