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

# Builds a release package (STANDALONE layout: .tar.gz, .zip on Windows),
# used by .github/workflows/rest-daemon-release.yml on macOS, on Windows (Git
# Bash in a vcvars environment) and in the Rocky Linux 9 container.
#
#   TRIPLET=<vcpkg triplet> JIT_CACHE=<dir> OUT_DIR=<dir> \
#   [BUILD_DIR=build] [RESTD_DEPS_DIR=<dir>] tools/release/build_package.sh
#
# Connector/C, OpenSSL and ICU come from vcpkg (the icu feature of
# vcpkg.json). JIT_CACHE is a directory with a JIT executor library built
# earlier (libjitexecutor and its headers): if it has one, it's used as
# MRS_JIT_EXECUTOR_LIB; otherwise the library is built at configure time
# (WITH_JIT_EXECUTOR) and copied there afterwards, for the caller to cache.
# The package is copied into OUT_DIR.
set -euo pipefail

TRIPLET=${TRIPLET:?set TRIPLET}
JIT_CACHE=${JIT_CACHE:?set JIT_CACHE}
OUT_DIR=${OUT_DIR:?set OUT_DIR}
BUILD_DIR=${BUILD_DIR:-build}

# Git Bash: hand CMake Windows paths, not /d/a/... ones
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-2}")
jit_out=ext/polyglot/polyglot-nativeapi-native-library/target

jit_args=()
if [ -f "$JIT_CACHE/polyglot_api.h" ]; then
  echo "==> JIT executor library from the cache: $JIT_CACHE"
  jit_cached=1
  jit_args=(-DMRS_JIT_EXECUTOR_LIB="$(native_path "$JIT_CACHE")")
else
  echo "==> No cached JIT executor library: building it (WITH_JIT_EXECUTOR)"
  jit_cached=0
  jit_args=(-DWITH_JIT_EXECUTOR=ON)
  if [ -n "${RESTD_DEPS_DIR:-}" ]; then
    jit_args+=(-DRESTD_DEPS_DIR="$(native_path "$RESTD_DEPS_DIR")")
  fi
fi

cmake -S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DWITH_VCPKG_TRIPLET="$TRIPLET" -DVCPKG_MANIFEST_FEATURES=icu \
  "${jit_args[@]}"
cmake --build "$BUILD_DIR" --parallel "$jobs"

# the library restd was just linked against, for the next runs; assembled
# aside and moved into place so a half-copied directory is never there
if [ "$jit_cached" = 0 ]; then
  tmp="$JIT_CACHE.tmp"
  rm -rf "$tmp" "$JIT_CACHE"
  mkdir -p "$tmp"
  cp -P "$jit_out"/*jitexecutor* "$jit_out"/*.h "$tmp/"
  rm -f "$tmp"/*.jar
  mv "$tmp" "$JIT_CACHE"
  echo "==> JIT executor library copied to $JIT_CACHE"
fi

# the generator of the layout: TGZ, ZIP on Windows (cmake/packaging.cmake)
rm -f "$BUILD_DIR"/mariadb-restd-*.tar.gz "$BUILD_DIR"/mariadb-restd-*.zip
(cd "$BUILD_DIR" && cpack -C Release)
mkdir -p "$OUT_DIR"
cp "$BUILD_DIR"/mariadb-restd-*.tar.gz "$BUILD_DIR"/mariadb-restd-*.zip "$OUT_DIR/" 2>/dev/null || true
ls -l "$OUT_DIR"
[ -n "$(ls -A "$OUT_DIR")" ] || { echo "No package in $BUILD_DIR" >&2; exit 1; }
