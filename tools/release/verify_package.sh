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

#
# Verify an unpacked mariadb-restd package (STANDALONE layout).
#
#   tools/release/verify_package.sh <unpacked-package-root>
#
# Run against a package on a machine that has never built it (see
# .github/workflows/verify-packages.yml): the point is to catch what only works
# on a build host -- a library resolved from the build tree or a package
# manager prefix, a plugin that doesn't load from the package's plugin folder,
# defaults that point at the build directory. Follows MariaDB Shell's
# scripts/verify_package.sh.
#
# Environment:
#   EXPECT_VERSION     assert `--version` reports exactly this version
#   ALLOW_SYSTEM_LIBS  extended regex of further dependencies allowed from the
#                      system (matched against the whole dependency string)
#
# Every check runs even after one fails, so a single run reports the full
# picture rather than only the first problem. Exits non-zero if any check
# failed.

set -uo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  echo "usage: $0 <unpacked-package-root>" >&2
  exit 2
fi
[ -d "$ROOT" ] || { echo "not a directory: $ROOT" >&2; exit 2; }
# Absolute, no trailing slash: the dependency audit decides whether a library
# is bundled by asking whether the loader resolved it to a path under $ROOT.
ROOT="$(cd "$ROOT" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECT_VERSION="${EXPECT_VERSION:-}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s (%s)\n' "$1" "$2"; SKIP=$((SKIP + 1)); }
fail() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
}

section() { printf '\n== %s\n' "$1"; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WINDOWS=1; EXE=.exe ;;
  *) WINDOWS=0; EXE= ;;
esac

# Native Windows programs can't read the MSYS paths this script works in.
native_path() {
  if [ "$WINDOWS" = 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

WORK="$(mktemp -d)"
DAEMON_PID=""
cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# Run a program and capture stdout/stderr separately.
OUT=""
ERR=""
RC=0
run() {
  "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
  return $RC
}

# ---------------------------------------------------------------------------
section "Package layout"
# ---------------------------------------------------------------------------
# The executables first: nothing below can run without the daemon.
RESTD="$ROOT/bin/mariadb-restd$EXE"
if [ -f "$RESTD" ]; then
  pass "bin/mariadb-restd$EXE present"
else
  fail "bin/mariadb-restd$EXE present" "not under $ROOT"
  echo ""
  echo "Cannot continue without the daemon binary." >&2
  exit 1
fi
for tool in mariadb-restd-keyring mariadb-restd-passwd mariadb-restd-plugin-info; do
  if [ -f "$ROOT/bin/$tool$EXE" ]; then
    pass "bin/$tool$EXE present"
  else
    fail "bin/$tool$EXE present" "not under $ROOT/bin"
  fi
done

# The plugin folder of the STANDALONE layout (cmake/install_layout.cmake):
# lib/ on Windows, lib/mariadb-restd/ elsewhere. Its plugins are .dll on
# Windows and .so elsewhere; on Linux the JIT executor library is a .so in
# there too, hence the lib* exclusion.
if [ "$WINDOWS" = 1 ]; then
  PLUGIN_DIR="$ROOT/lib"
  PLUGIN_EXT=dll
  JIT_LIB="$PLUGIN_DIR/jitexecutor.dll"
  CLIENT_PLUGIN_DIR="$ROOT/bin/mariadb-client-plugins"
  CLIENT_PLUGIN_EXT=dll
else
  PLUGIN_DIR="$ROOT/lib/mariadb-restd"
  PLUGIN_EXT=so
  JIT_LIB="$(find "$PLUGIN_DIR" -maxdepth 1 -name 'libjitexecutor.*' 2>/dev/null | head -n 1)"
  # next to the bundled libmariadb: lib/ (macOS), lib/mariadb-restd/private/
  # (Linux)
  CLIENT_PLUGIN_DIR="$(find "$ROOT/lib" -type d -name mariadb-client-plugins 2>/dev/null | head -n 1)"
  CLIENT_PLUGIN_EXT=so
fi

PLUGINS=()
if [ -d "$PLUGIN_DIR" ]; then
  for f in "$PLUGIN_DIR"/*."$PLUGIN_EXT"; do
    [ -f "$f" ] || continue
    name="$(basename "$f" ."$PLUGIN_EXT")"
    case "$name" in lib*|jitexecutor) continue ;; esac
    PLUGINS+=("$name")
  done
fi
if [ ${#PLUGINS[@]} -gt 0 ]; then
  pass "plugin folder ${PLUGIN_DIR#"$ROOT"/} has ${#PLUGINS[@]} plugins"
else
  fail "plugin folder ${PLUGIN_DIR#"$ROOT"/} has plugins" "no *.$PLUGIN_EXT in $PLUGIN_DIR"
fi
for want in http_server mysql_rest_service rest_router jit_executor; do
  case " ${PLUGINS[*]-} " in
    *" $want "*) pass "plugin $want bundled" ;;
    *) fail "plugin $want bundled" "no $want.$PLUGIN_EXT in $PLUGIN_DIR" ;;
  esac
done

if [ -n "$JIT_LIB" ] && [ -f "$JIT_LIB" ]; then
  pass "JIT executor library bundled (${JIT_LIB#"$ROOT"/})"
else
  fail "JIT executor library bundled" "no (lib)jitexecutor in $PLUGIN_DIR"
fi

# Connector/C's client auth plugins: without them, accounts using
# caching_sha2_password or ed25519 can't log in
for p in caching_sha2_password client_ed25519; do
  if [ -n "$CLIENT_PLUGIN_DIR" ] && [ -f "$CLIENT_PLUGIN_DIR/$p.$CLIENT_PLUGIN_EXT" ]; then
    pass "client auth plugin $p bundled"
  else
    fail "client auth plugin $p bundled" "no $p.$CLIENT_PLUGIN_EXT in ${CLIENT_PLUGIN_DIR:-a mariadb-client-plugins folder}"
  fi
done

# ---------------------------------------------------------------------------
section "Startup"
# ---------------------------------------------------------------------------
if run "$RESTD" --version; then
  if [ -n "$EXPECT_VERSION" ]; then
    if printf '%s' "$OUT" | grep -qF "Ver $EXPECT_VERSION "; then
      pass "--version reports $EXPECT_VERSION"
    else
      fail "--version reports $EXPECT_VERSION" "got: $OUT"
    fi
  else
    pass "--version runs ($OUT)"
  fi
else
  fail "--version runs" "exit $RC; stderr: $ERR"
fi

if run "$RESTD" --help; then
  pass "--help runs"
else
  fail "--help runs" "exit $RC; stderr: $ERR"
fi

# ---------------------------------------------------------------------------
section "Plugins load"
# ---------------------------------------------------------------------------
# mariadb-restd-plugin-info loads the plugin (dlopen/LoadLibrary), with every
# library it links: jit_executor brings in the JIT executor library, the
# others the harness, Connector/C, OpenSSL and ICU.
PLUGIN_INFO="$ROOT/bin/mariadb-restd-plugin-info$EXE"
for name in ${PLUGINS[@]+"${PLUGINS[@]}"}; do
  if run "$PLUGIN_INFO" "$(native_path "$PLUGIN_DIR/$name.$PLUGIN_EXT")" "$name" \
     && printf '%s' "$OUT" | grep -q '"abi-version"'; then
    pass "plugin $name loads"
  else
    fail "plugin $name loads" "exit $RC; stdout: $OUT; stderr: $ERR"
  fi
done

# ---------------------------------------------------------------------------
section "Tools"
# ---------------------------------------------------------------------------
# a keyring and its master key: OpenSSL's ciphers from the bundled libcrypto
if run "$ROOT/bin/mariadb-restd-keyring$EXE" init "$(native_path "$WORK/keyring")" \
     --master-key-file "$(native_path "$WORK/mk")" \
   && [ -s "$WORK/keyring" ] && [ -s "$WORK/mk" ]; then
  pass "mariadb-restd-keyring init"
else
  fail "mariadb-restd-keyring init" "exit $RC; stdout: $OUT; stderr: $ERR"
fi

# ---------------------------------------------------------------------------
section "Daemon"
# ---------------------------------------------------------------------------
# Starts the daemon with the HTTP server and the REST API only (no database
# needed), from the package's own default plugin folder, and checks that it
# serves requests: routing goes through ICU's regex engine.
PORT=$((20000 + RANDOM % 20000))
cat > "$WORK/restd.conf" <<EOF
[DEFAULT]
logging_folder=
runtime_folder=$(native_path "$WORK")
data_folder=$(native_path "$WORK")
keyring_path=$(native_path "$WORK/keyring")
master_key_path=$(native_path "$WORK/mk")

[logger]
level=INFO

[http_server]
port=$PORT
bind_address=127.0.0.1

[rest_api]
EOF
"$RESTD" -c "$(native_path "$WORK/restd.conf")" >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!

code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/20190715/swagger.json" 2>/dev/null)"
  [ "$code" = 200 ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 1
done
if [ "$code" = 200 ]; then
  pass "daemon serves the REST API (port $PORT)"
else
  fail "daemon serves the REST API" "last HTTP status '${code}'; log: $(tr '\n' ' ' < "$WORK/daemon.log")"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/no/such/path" 2>/dev/null)"
if [ "$code" = 404 ]; then
  pass "daemon answers 404 for an unknown path"
else
  fail "daemon answers 404 for an unknown path" "HTTP status '$code'"
fi

# Stopped with SIGTERM, which it handles as a requested shutdown. On Windows
# the MSYS kill terminates the process instead, so only the stop is checked.
kill "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null
rc=$?
DAEMON_PID=""
if [ "$WINDOWS" = 1 ] || [ "$rc" = 0 ]; then
  pass "daemon stops"
else
  fail "daemon stops cleanly on SIGTERM" "exit $rc; log: $(tr '\n' ' ' < "$WORK/daemon.log")"
fi

# ---------------------------------------------------------------------------
section "Self-contained (no external dependencies)"
# ---------------------------------------------------------------------------
# The package must run on a minimal install of a supported OS: everything it
# links, apart from what such an install is guaranteed to have, is shipped
# inside it. A dependency is acceptable only if it is resolved inside the
# package (a relative reference, or a path under the package root) or is part
# of the OS baseline below. Anything else -- a build-tree path, a package
# manager prefix, an unresolved SONAME -- is a dependency that left the
# package. Add to the baseline with ALLOW_SYSTEM_LIBS only for something a
# minimal install genuinely always has.
EXTRA_ALLOW="${ALLOW_SYSTEM_LIBS:-}"
AUDIT_BROKEN=""

DANGLING=0
while IFS= read -r link; do
  [ -e "$link" ] && continue
  fail "symlink '${link#"$ROOT"/}' resolves" "dangling, target: $(readlink "$link")"
  DANGLING=$((DANGLING + 1))
done < <(find "$ROOT" -type l 2>/dev/null)
if [ "$DANGLING" -eq 0 ]; then
  pass "no dangling symlinks"
fi

case "$(uname -s)" in
  Darwin)
    BIN_RE='Mach-O'
    list_binaries() {
      find "$ROOT" -type f -print0 | xargs -0 file 2>/dev/null \
        | grep -E "$BIN_RE" | sed 's/:[[:space:]].*//'
    }
    list_deps() { otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'; }
    # /usr/lib and /System/Library are the dyld shared cache: part of macOS
    dep_allowed() {
      case "$1" in
        @rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
        /usr/lib/*|/System/Library/*)               return 0 ;;
      esac
      return 1
    }
    ;;
  Linux)
    BIN_RE='ELF'
    list_binaries() {
      find "$ROOT" -type f -print0 | xargs -0 file 2>/dev/null \
        | grep -E "$BIN_RE" | sed 's/:[[:space:]].*//'
    }
    # the path ldd resolved a dependency to, or <name> [UNRESOLVED]
    list_deps() {
      ldd "$1" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *"not found"*) printf '%s [UNRESOLVED]\n' "$(printf '%s' "$line" | awk '{print $1}')" ;;
          *"=>"*)        printf '%s\n' "$(printf '%s' "$line" | sed 's/.*=>[[:space:]]*//; s/[[:space:]]*(0x[0-9a-f]*)$//')" ;;
          *)             printf '%s\n' "$(printf '%s' "$line" | sed 's/[[:space:]]*(0x[0-9a-f]*)$//; s/^[[:space:]]*//')" ;;
        esac
      done
    }
    # glibc and the compiler runtime, matched on the SONAME
    dep_allowed() {
      case "$1" in *"[UNRESOLVED]") return 1 ;; esac
      printf '%s' "${1##*/}" | grep -Eq \
        '^(linux-vdso|ld-linux[^/]*|libc|libm|libdl|libpthread|librt|libresolv|libutil|libnsl|libgcc_s|libstdc\+\+)\.so(\.[0-9.]+)?$'
    }
    ;;
  MINGW*|MSYS*|CYGWIN*)
    BIN_RE='PE'
    list_binaries() {
      find "$ROOT" -type f \( -iname '*.exe' -o -iname '*.dll' \) 2>/dev/null
    }
    PY=""
    for p in python3 python py; do
      command -v "$p" >/dev/null 2>&1 && { PY="$p"; break; }
    done
    PE_DEPS="$WORK/pe-deps"
    if [ -n "$PY" ]; then
      "$PY" "$(native_path "$SCRIPT_DIR/pe_imports.py")" "$(native_path "$ROOT")" \
        > "$PE_DEPS" 2>/dev/null
    fi
    # no output at all means the reader didn't run: an audit without data
    # would otherwise report a clean package
    if [ ! -s "$PE_DEPS" ]; then
      AUDIT_BROKEN="$SCRIPT_DIR/pe_imports.py produced no output (python: ${PY:-none})"
    fi
    list_deps() { awk -F'\t' -v f="${1#"$ROOT"/}" '$1 == f { print $2 }' "$PE_DEPS"; }

    # a PE names its imports without a path, and the loader looks beside the
    # importing binary first: "shipped anywhere in the package" is the test
    PKG_DLLS="$(list_binaries | sed 's|.*/||' | tr '[:upper:]' '[:lower:]' | sort -u)"
    # the MSVC runtime the packages bundle (InstallRequiredSystemLibraries),
    # allowed from the system too
    VCRUNTIME_RE='^(vcruntime140|vcruntime140_1|vcruntime140_threads|msvcp140|msvcp140_1|msvcp140_2|msvcp140_atomic_wait|msvcp140_codecvt_ids|concrt140|vcomp140|vcamp140)\.dll$'
    # DLLs Windows itself provides: the API sets and the Win32 surface
    dep_allowed() {
      local d
      d="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
      printf '%s\n' "$PKG_DLLS" | grep -qxF "$d" && return 0
      printf '%s' "$d" | grep -Eq "$VCRUNTIME_RE" && return 0
      printf '%s' "$d" | grep -Eq \
        '^(api-ms-win-|ext-ms-win-)|^(aclui|activeds|advapi32|bcrypt|bcryptprimitives|cabinet|cfgmgr32|combase|comctl32|comdlg32|credui|crypt32|cryptbase|d3d9|dbghelp|dnsapi|dsound|dwmapi|gdi32|gdiplus|imagehlp|imm32|iphlpapi|kernel32|kernelbase|ktmw32|loadperf|lz32|mpr|msi|msimg32|msvcrt|mswsock|ncrypt|netapi32|normaliz|ntdll|ntdsapi|odbc32|ole32|oleacc|oleaut32|pdh|powrprof|profapi|propsys|psapi|query|rasapi32|rpcrt4|sechost|secur32|setupapi|sfc|shell32|shlwapi|urlmon|user32|userenv|usp10|uxtheme|version|win32u|winhttp|wininet|winmm|wintrust|wldap32|wsock32|wtsapi32|ws2_32)\.dll$|^winspool\.drv$'
    }
    ;;
  *)
    BIN_RE=''
    ;;
esac

if [ -n "$AUDIT_BROKEN" ]; then
  fail "dependency audit can run" "$AUDIT_BROKEN"
elif [ -z "$BIN_RE" ]; then
  skip "no dependency escapes the package" "no dependency lister for $(uname -s)"
else
  VIOLATIONS="$WORK/violations"
  : > "$VIOLATIONS"
  SCANNED=0
  while IFS= read -r bin; do
    [ -n "$bin" ] || continue
    SCANNED=$((SCANNED + 1))
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        '!'*) fail "dependencies of '${bin#"$ROOT"/}' are readable" "${dep#!}"; continue ;;
      esac
      case "$dep" in "$ROOT"/*) continue ;; esac
      dep_allowed "$dep" && continue
      if [ -n "$EXTRA_ALLOW" ] && printf '%s' "$dep" | grep -Eq "$EXTRA_ALLOW"; then
        continue
      fi
      printf '%s\t%s\n' "$dep" "${bin#"$ROOT"/}" >> "$VIOLATIONS"
    done < <(list_deps "$bin")
  done < <(list_binaries)

  if [ "$SCANNED" -eq 0 ]; then
    fail "package contains binaries to check" "found no $BIN_RE files under $ROOT"
  elif [ ! -s "$VIOLATIONS" ]; then
    pass "all $SCANNED binaries resolve within the package or the OS baseline"
  else
    # per dependency, not per binary: the library is the thing to fix
    while IFS='|' read -r dep count examples; do
      fail "'$dep' is bundled or provided by the OS" "$count: $examples"
    done < <(sort "$VIOLATIONS" | awk -F'\t' '
      { n[$1]++; if (n[$1] <= 3) ex[$1] = ex[$1] (ex[$1] == "" ? "" : ", ") $2 }
      END {
        for (d in n) {
          more = (n[d] > 3) ? sprintf(", +%d more", n[d] - 3) : ""
          label = (n[d] == 1) ? "1 binary" : sprintf("%d binaries", n[d])
          printf "%s|%s|%s%s\n", d, label, ex[d], more
        }
      }' | sort)
  fi
fi

# ---------------------------------------------------------------------------
printf '\n== Summary\n'
printf '  %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailed checks:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
echo "  package OK"
