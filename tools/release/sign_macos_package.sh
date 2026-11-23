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
# Sign, and optionally notarize, a mariadb-restd macOS package tarball.
#
#   tools/release/sign_macos_package.sh <package.tar.gz> <out-dir>
#
# Unpacks the tarball, signs every Mach-O file in it with the hardened runtime
# and a secure timestamp, submits the signed tree to Apple's notary service and
# writes a tarball of the same name and layout to <out-dir>. Used by
# .github/workflows/sign-macos.yml; the same script as MariaDB Shell's
# scripts/sign_macos_package.sh, with the daemon's entitlements.
#
# Environment:
#   SIGN_IDENTITY     codesign identity, e.g. "Developer ID Application: ... (TEAMID)".
#                     "-" signs ad hoc: no timestamp, no Team ID, no notarization,
#                     for trying the script out on a machine without the certificate.
#   SIGN_KEYCHAIN     keychain holding the identity (default: the search list)
#   EXPECT_TEAM_ID    every signature must carry this Team ID
#   ENTITLEMENTS      entitlements for the binaries ENTITLED_RE matches
#                     (default: packaging/macos/entitlements.plist)
#   ENTITLED_RE       extended regex matched against a binary's file name
#                     (default: mariadb-restd)
#   NOTARY_KEY_FILE   App Store Connect API key (.p8)
#   NOTARY_KEY_ID     its key ID
#   NOTARY_ISSUER     its issuer ID
#                     Give all three to notarize, or none to skip notarization.
#   NOTARY_RECORD_WAIT  seconds to wait, after notarization, for Gatekeeper to
#                     see the record (default: 600)
#
# Why each piece is the way it is:
#
# - Signing happens on the finished package, not in the build: bundling the
#   runtime libraries (cmake/bundle_runtime_libraries.cmake) rewrites load
#   commands with install_name_tool, which invalidates any signature made
#   before it.
# - Each file is signed on its own (no --deep). Everything here is a standalone
#   Mach-O file rather than nested code, so the order does not matter, and the
#   signature lives inside the file: the tree gains no files and repacking is a
#   plain tar.
# - Object files cannot be signed and are not checked by the notary service.
#   The daemon packages have none today; they are skipped should one appear.
# - mariadb-restd gets com.apple.security.cs.allow-jit. The JIT executor library
#   (GraalVM native image) compiles hot MRS scripts into executable memory at
#   run time, which the hardened runtime refuses without it. Truffle does not
#   report the refusal: the scripts keep running, interpreted only. Nothing
#   else needs an entitlement: every library the daemon loads is in the package
#   and signed by the same team, so library validation stays on.
# - notarytool takes a zip, pkg or dmg, not a tarball. The zip only carries the
#   files to Apple, which records their hashes; it is then thrown away. A ticket
#   cannot be stapled to a bare binary, so Gatekeeper looks it up online the
#   first time a downloaded binary runs.

set -euo pipefail

PKG="${1:-}"
OUT_DIR="${2:-}"
if [ -z "$PKG" ] || [ -z "$OUT_DIR" ]; then
  echo "usage: $0 <package.tar.gz> <out-dir>" >&2
  exit 2
fi
[ -f "$PKG" ] || { echo "not a file: $PKG" >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "$0 runs on macOS only" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:?SIGN_IDENTITY is required (\"-\" signs ad hoc)}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
EXPECT_TEAM_ID="${EXPECT_TEAM_ID:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$SCRIPT_DIR/../../packaging/macos/entitlements.plist}"
ENTITLED_RE="${ENTITLED_RE:-^mariadb-restd$}"
NOTARY_KEY_FILE="${NOTARY_KEY_FILE:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

[ -f "$ENTITLEMENTS" ] || { echo "entitlements file not found: $ENTITLEMENTS" >&2; exit 2; }

NOTARIZE=0
if [ -n "$NOTARY_KEY_FILE$NOTARY_KEY_ID$NOTARY_ISSUER" ]; then
  if [ -z "$NOTARY_KEY_FILE" ] || [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER" ]; then
    echo "NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER go together: give all three or none" >&2
    exit 2
  fi
  [ -f "$NOTARY_KEY_FILE" ] || { echo "NOTARY_KEY_FILE not found: $NOTARY_KEY_FILE" >&2; exit 2; }
  NOTARIZE=1
fi
if [ "$SIGN_IDENTITY" = "-" ] && [ "$NOTARIZE" -eq 1 ]; then
  echo "an ad hoc signature cannot be notarized: give a Developer ID identity" >&2
  exit 2
fi

NAME="$(basename "$PKG")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
[ "$(cd "$(dirname "$PKG")" && pwd)/$NAME" != "$OUT_DIR/$NAME" ] \
  || { echo "<out-dir> must differ from the package's directory" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
echo "==> Unpacking $NAME"
mkdir "$WORK/tree"
tar -xzf "$PKG" -C "$WORK/tree"
TOPS=()
while IFS= read -r d; do TOPS+=("$d"); done < <(find "$WORK/tree" -mindepth 1 -maxdepth 1)
if [ "${#TOPS[@]}" -ne 1 ] || [ ! -d "${TOPS[0]}" ]; then
  echo "expected a single top-level directory in $NAME, found ${#TOPS[@]} entries" >&2
  exit 1
fi
ROOT="${TOPS[0]}"
TOP="$(basename "$ROOT")"

# Regular files only: a symlink (libssl.dylib -> libssl.3.dylib) is signed
# through its target. One `file` pass over the tree rather than one per file.
SIGNABLE="$WORK/signable"
SKIPPED="$WORK/skipped"
find "$ROOT" -type f -print0 | xargs -0 file 2>/dev/null | grep 'Mach-O' > "$WORK/macho" || true
grep -v 'Mach-O[^:]* object' "$WORK/macho" | sed 's/:[[:space:]].*//' | sort > "$SIGNABLE" || true
grep    'Mach-O[^:]* object' "$WORK/macho" | sed 's/:[[:space:]].*//' | sort > "$SKIPPED"  || true
COUNT="$(grep -c . "$SIGNABLE" || true)"
[ "$COUNT" -gt 0 ] || { echo "no Mach-O files to sign in $NAME" >&2; exit 1; }

# ---------------------------------------------------------------------------
echo "==> Signing $COUNT Mach-O files as: $SIGN_IDENTITY"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
# Apple's timestamp service refuses ad hoc signatures.
[ "$SIGN_IDENTITY" = "-" ] || SIGN_ARGS+=(--timestamp)
[ -z "$SIGN_KEYCHAIN" ] || SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")

ENTITLED=0
while IFS= read -r f; do
  extra=()
  if basename "$f" | grep -Eq "$ENTITLED_RE"; then
    extra=(--entitlements "$ENTITLEMENTS")
    echo "    ${f#$ROOT/} (with entitlements)"
    ENTITLED=$((ENTITLED + 1))
  fi
  # codesign reports "replacing existing signature" for every file (the linker
  # signed them all ad hoc), so its output is shown only when it fails.
  if ! codesign "${SIGN_ARGS[@]}" ${extra[@]+"${extra[@]}"} "$f" 2>"$WORK/sign.err"; then
    echo "codesign failed on ${f#$ROOT/}:" >&2
    cat "$WORK/sign.err" >&2
    exit 1
  fi
done < "$SIGNABLE"
while IFS= read -r f; do
  [ -n "$f" ] && echo "    skipped object file ${f#$ROOT/}"
done < "$SKIPPED"
echo "    signed $COUNT files, $ENTITLED with entitlements"

# ---------------------------------------------------------------------------
echo "==> Checking the signatures"
BAD=0
while IFS= read -r f; do
  rel="${f#$ROOT/}"
  if ! codesign --verify --strict "$f" 2>"$WORK/verify.err"; then
    echo "    FAIL $rel: $(tr '\n' ' ' < "$WORK/verify.err")" >&2
    BAD=$((BAD + 1)); continue
  fi
  info="$(codesign -dv "$f" 2>&1)"
  # flags=0x10000(runtime), or a combination such as 0x10002(adhoc,runtime).
  if ! printf '%s' "$info" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime'; then
    echo "    FAIL $rel: hardened runtime not set" >&2
    BAD=$((BAD + 1)); continue
  fi
  if [ -n "$EXPECT_TEAM_ID" ] && ! printf '%s' "$info" | grep -qx "TeamIdentifier=$EXPECT_TEAM_ID"; then
    echo "    FAIL $rel: $(printf '%s' "$info" | grep '^TeamIdentifier=' || echo 'no TeamIdentifier'), expected $EXPECT_TEAM_ID" >&2
    BAD=$((BAD + 1)); continue
  fi
done < "$SIGNABLE"
[ "$BAD" -eq 0 ] || { echo "$BAD of $COUNT signatures failed the checks" >&2; exit 1; }
echo "    all $COUNT valid, hardened runtime${EXPECT_TEAM_ID:+, Team ID $EXPECT_TEAM_ID}"

# ---------------------------------------------------------------------------
if [ "$NOTARIZE" -eq 1 ]; then
  echo "==> Notarizing"
  ZIP="$WORK/${TOP}.zip"
  ditto -c -k --keepParent "$ROOT" "$ZIP"
  NOTARY_AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  # notarytool exits 0 for a submission Apple rejected: the verdict is the
  # status field, so read that rather than the exit code.
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait --timeout 1h \
    --output-format json > "$WORK/notary.json" || true
  cat "$WORK/notary.json"; echo
  SUB_ID="$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || true)"
  STATUS="$(plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null || true)"
  if [ "$STATUS" != "Accepted" ]; then
    echo "notarization of $TOP ended with status '${STATUS:-unknown}'" >&2
    if [ -n "$SUB_ID" ]; then
      echo "--- notary log for submission $SUB_ID ---" >&2
      xcrun notarytool log "$SUB_ID" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    exit 1
  fi
  echo "    accepted (submission $SUB_ID)"

  # Proves the chain end to end, for every signed file: Gatekeeper, asked about
  # a binary that has no stapled ticket, fetches the notarization record
  # online.
  #
  # Not `--type execute`: that assesses app bundles only, and rejects every
  # command-line binary, notarized or not, with "the code is valid but does
  # not seem to be an app". `--type open` with the primary-signature context
  # assesses the file's own signature, executable or library, and names the
  # notarization in `source=`, which is what is required here.
  notarized() {
    spctl --assess --type open --context context:primary-signature -vv "$1" \
      > "$WORK/spctl.out" 2>&1 || true
    grep -q ': accepted' "$WORK/spctl.out" \
      && grep -qx 'source=Notarized Developer ID' "$WORK/spctl.out"
  }

  # The record is normally live as soon as the submission is accepted, but can
  # take a while to reach Apple's servers: wait for it on the daemon, then check
  # the rest once. The wait ends at the first success, so the long limit only
  # delays reporting a real failure.
  MAIN="$(grep -m1 -E '/bin/mariadb-restd$' "$SIGNABLE" || head -n1 "$SIGNABLE")"
  WAIT_LIMIT="${NOTARY_RECORD_WAIT:-600}"
  start=$SECONDS
  until notarized "$MAIN"; do
    if [ $((SECONDS - start)) -ge "$WAIT_LIMIT" ]; then
      cat "$WORK/spctl.out" >&2
      echo "Gatekeeper does not accept ${MAIN#$ROOT/} as notarized after ${WAIT_LIMIT}s" >&2
      exit 1
    fi
    sleep 15
  done
  echo "    notarization record live after $((SECONDS - start))s"

  BAD=0
  while IFS= read -r f; do
    if ! notarized "$f"; then
      echo "    FAIL ${f#$ROOT/}: $(tr '\n' ' ' < "$WORK/spctl.out")" >&2
      BAD=$((BAD + 1))
    fi
  done < "$SIGNABLE"
  [ "$BAD" -eq 0 ] || { echo "Gatekeeper does not accept $BAD of $COUNT files as notarized" >&2; exit 1; }
  echo "    Gatekeeper accepts all $COUNT as notarized"
else
  echo "==> Not notarizing (no NOTARY_KEY_FILE/NOTARY_KEY_ID/NOTARY_ISSUER)"
fi

# ---------------------------------------------------------------------------
echo "==> Repacking $OUT_DIR/$NAME"
# COPYFILE_DISABLE and the two options keep macOS tar from adding ._* files and
# extended attributes (quarantine, provenance) to the archive.
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$OUT_DIR/$NAME" -C "$WORK/tree" "$TOP"
echo "==> Done: $OUT_DIR/$NAME"
