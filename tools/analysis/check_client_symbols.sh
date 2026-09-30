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

# Which symbols do the kept router libraries import from Router's private
# libmysqlrouter_mysqlclient that are NOT part of the public libmysqlclient API?
#
# Usage: MYSQL_SRC=<server src> MYSQL_BLD=<build with router built> \
#        STOCK_LIB=<dir with stock libmysqlclient> check_client_symbols.sh
# Requires in MYSQL_BLD: ninja mysql_rest_service mysqlrouter router_mysqlclient
# (macOS naming; adjust .dylib -> .so on Linux)
set -euo pipefail
SRC=${MYSQL_SRC:-<dev>/mysql/mysql-server}
BLD=${MYSQL_BLD:-$SRC/build}
STOCK=${STOCK_LIB:-<dev>/mysql/mysql-26.7.0-macos15-arm64/lib}
T=$(mktemp -d); L=$BLD/library_output_directory; P=$BLD/plugin_output_directory

nm -gU "$L"/libmysqlrouter_mysqlclient.1.dylib | awk '{print $3}' | sort -u > "$T/shim"
sed -n '/^SET(CLIENT_API_FUNCTIONS/,/^  )/p;/^SET(CLIENT_API_NONBLOCKING_FUNCTIONS/,/^  )/p' \
  "$SRC/libmysql/CMakeLists.txt" | grep -oE '^\s+[a-z_0-9]+' | tr -d ' ' | sort -u > "$T/api"
for f in "$L"/libmysqlharness{,_stdx,_tls}.1.dylib "$L"/libmysqlrouter{_mysql,_utils,}.1.dylib \
         "$L"/libmysqlrouter_http*.1.dylib "$L"/libmysqlrouter_io_component.1.dylib \
         "$L"/libmysqlrouter_destination_status.1.dylib \
         "$P"/rest_api.so "$P"/http_server.so "$P"/mysql_rest_service.so \
         $( [ -f "$P/jit_executor.so" ] && echo "$P/jit_executor.so" ); do
  nm -u "$f" | sed "s|^|$(basename "$f") |"
done | sort -u > "$T/undef"
awk '{print $2}' "$T/undef" | sort -u | comm -12 - "$T/shim" | sed 's/^_//' | while read -r s; do
  if grep -qx "$s" "$T/api"; then echo "API      $s"
  else echo "INTERNAL $s  [$(grep " _$s\$" "$T/undef" | awk '{print $1}' | tr '\n' ' ')]"; fi
done | sort
echo "--- stock lib: $STOCK"
rm -rf "$T"
