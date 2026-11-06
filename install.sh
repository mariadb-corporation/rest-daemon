#!/bin/sh
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
# mariadb-restd installer, the counterpart of the MariaDB Shell's install.sh.
#
#   curl -fsSL https://github.com/mariadb-corporation/rest-daemon/raw/main/install.sh | bash
#
# Detects the local OS and CPU, picks the matching package from the release,
# verifies its checksum and unpacks it into <prefix>/<version>, linking the
# programs from the bin directory. Two versions are kept.
#
# POSIX sh on purpose -- this runs on whatever the target has, which may be a
# minimal container with dash and no bash. No arrays, no [[ ]], no local.
#
# Environment overrides:
#   MARIADB_RESTD_TAG         install a specific release tag instead of the newest
#   MARIADB_RESTD_PRERELEASE  non-empty: the same as --pre-release
#   MARIADB_RESTD_PREFIX      where to unpack   (default $HOME/.local/share/mariadb-restd)
#   MARIADB_RESTD_BINDIR      where to symlink  (default $HOME/.local/bin)
#   MARIADB_RESTD_REPO        owner/repo to install from; it has to be public
#   MARIADB_RESTD_SHA256SUMS  a local copy of the release's SHA256SUMS, read
#                             instead of the one published with it; needs
#                             MARIADB_RESTD_TAG
#
# Options:
#   --pre-release  install the newest release even if it is a prerelease
#
set -eu

REPO="${MARIADB_RESTD_REPO:-mariadb-corporation/rest-daemon}"
PREFIX="${MARIADB_RESTD_PREFIX:-$HOME/.local/share/mariadb-restd}"
BINDIR="${MARIADB_RESTD_BINDIR:-$HOME/.local/bin}"

# The programs a package has in bin/, linked from $BINDIR. mariadb-restd itself
# has to be there; the others are linked when the package has them.
PROGRAMS="mariadb-restd mariadb-restd-passwd mariadb-restd-keyring mariadb-restd-plugin-info"

# The oldest glibc the Linux packages run on: they are built on Rocky Linux 9
# (.github/workflows/rest-daemon-release.yml).
MIN_GLIBC=2.34

# printf, not echo: these messages carry their own newlines, and echo is free to
# mangle what it is given on some shells.
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
info() { echo "==> $*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---------------------------------------------------------------------------
# Options. Piped into a shell, these arrive via bash's -s:
#   curl -fsSL <url> | bash -s -- --pre-release
# ---------------------------------------------------------------------------
ENABLE_PRERELEASE=0
[ -z "${MARIADB_RESTD_PRERELEASE:-}" ] || ENABLE_PRERELEASE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --pre-release) ENABLE_PRERELEASE=1 ;;
    -h|--help)
      cat <<'USAGE'
mariadb-restd installer.

  install.sh [--pre-release]
  curl -fsSL <url> | bash -s -- [--pre-release]

  --pre-release  install the newest release even if it is a prerelease.
                 Without it, prereleases are skipped, exactly as
                 /releases/latest/ skips them.

Environment: MARIADB_RESTD_TAG, MARIADB_RESTD_PRERELEASE, MARIADB_RESTD_PREFIX,
MARIADB_RESTD_BINDIR, MARIADB_RESTD_REPO, MARIADB_RESTD_SHA256SUMS. A pinned
tag wins over --pre-release, since it already names the release to install.
MARIADB_RESTD_SHA256SUMS names a local copy of that release's SHA256SUMS,
read instead of the published one.
USAGE
      exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [ "$ENABLE_PRERELEASE" = 1 ]; then
  PRERELEASE_HINT="Prereleases are already enabled. Name a release outright if
  the one you want is not the newest:

      export MARIADB_RESTD_TAG=<tag>"
else
  PRERELEASE_HINT="A prerelease is never 'latest'. Reach the newest one with
  --pre-release, or name a release outright:

      export MARIADB_RESTD_TAG=<tag>"
fi

# A pinned tag and the latest stable release are both reachable by a plain
# download URL: /releases/latest/download/ is a permanent URL GitHub redirects to
# the newest non-prerelease release, so nothing here needs to know the version
# and this script never goes stale. Only the newest prerelease has to be looked
# up first, because it is invisible to /releases/latest: the releases are listed
# through the GitHub API and the newest one taken. That needs the listing
# parsed, hence a JSON reader; the other two paths need no such thing.
RESOLVE_PRERELEASE=0
if [ -n "${MARIADB_RESTD_TAG:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/$MARIADB_RESTD_TAG"
  RELEASE_DESC="$MARIADB_RESTD_TAG"
elif [ "$ENABLE_PRERELEASE" = 1 ]; then
  RESOLVE_PRERELEASE=1
  BASE=""   # known once the release is resolved
  RELEASE_DESC="newest, prereleases included"
else
  BASE="https://github.com/$REPO/releases/latest/download"
  RELEASE_DESC="latest"
fi

# A local SHA256SUMS lets whoever runs this decide which checksums the package
# has to match, rather than trusting the file published next to it -- the
# assets of a release can be replaced, a copy kept elsewhere cannot. It lists
# the assets of one release, so the release has to be named too.
SUMS_FILE="${MARIADB_RESTD_SHA256SUMS:-}"
if [ -n "$SUMS_FILE" ]; then
  [ -n "${MARIADB_RESTD_TAG:-}" ] || die "MARIADB_RESTD_SHA256SUMS needs MARIADB_RESTD_TAG.
  A SHA256SUMS lists the packages of one release, so name that release:

      export MARIADB_RESTD_TAG=<tag>"
  [ -f "$SUMS_FILE" ] && [ -r "$SUMS_FILE" ] \
    || die "MARIADB_RESTD_SHA256SUMS is not a readable file: $SUMS_FILE"
fi

need curl
need tar
need awk

# Dotted numeric comparison: is $1 <= $2? Field-by-field so 2.9 < 2.34, which a
# lexical compare gets backwards -- exactly the case that matters for glibc.
ver_le() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      na = split(a, x, "."); nb = split(b, y, ".");
      n = (na > nb ? na : nb);
      for (i = 1; i <= n; i++) {
        xi = (i <= na ? x[i] + 0 : 0);
        yi = (i <= nb ? y[i] + 0 : 0);
        if (xi < yi) { exit 0 }
        if (xi > yi) { exit 1 }
      }
      exit 0
    }'
}

# ---------------------------------------------------------------------------
# Platform tokens, matching cmake/packaging.cmake:
#   mariadb-restd-<version>-linux-<x86_64|aarch64>.tar.gz
#   mariadb-restd-<version>-macos-<x86_64|arm64>.tar.gz
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Linux)
    OS="linux"
    case "$(uname -m)" in
      x86_64|amd64)          ARCH="x86_64" ;;
      aarch64|arm64|armv8*)  ARCH="aarch64" ;;
      *) die "unsupported CPU architecture: $(uname -m)" ;;
    esac
    # getconf first; ldd is the fallback for images where getconf is absent.
    GLIBC=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -z "${GLIBC:-}" ]; then
      GLIBC=$(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')
    fi
    [ -n "${GLIBC:-}" ] || die "could not determine the glibc version (musl is not supported)"
    ver_le "$MIN_GLIBC" "$GLIBC" \
      || die "glibc $GLIBC is too old: the Linux packages need glibc $MIN_GLIBC or later"
    PLATFORM_DESC="linux (glibc $GLIBC), $ARCH"
    ;;
  Darwin)
    OS="macos"
    # A shell running under Rosetta reports x86_64 on Apple silicon; the
    # machine's own architecture is what the native package is for.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
      ARCH="arm64"
    else
      case "$(uname -m)" in
        x86_64)  ARCH="x86_64" ;;
        arm64)   ARCH="arm64" ;;
        *) die "unsupported CPU architecture: $(uname -m)" ;;
      esac
    fi
    PLATFORM_DESC="macos $(sw_vers -productVersion 2>/dev/null || echo '?'), $ARCH"
    ;;
  *)
    die "unsupported operating system: $(uname -s) (Windows: use install.ps1)"
    ;;
esac
info "Detected: $PLATFORM_DESC"

# ---------------------------------------------------------------------------
# SHA256SUMS is the manifest. Reading the asset list from the same file that
# carries the checksums means there is no separate index to drift out of sync.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
UNPACK=""     # this run's private unpack folder inside $PREFIX, once made
HAVE_LOCK=0   # 1 while this run holds $LOCK
cleanup() {
  [ -z "$UNPACK" ] || rm -rf "$UNPACK"
  release_lock
  rm -rf "$TMP"
}
# EXIT alone runs the cleanup. A signal ends the run through exit, which then
# runs it too: a signal trap that only cleaned up would let the script carry on
# afterwards, without its lock.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# The install lock. Several installers can run into one prefix at once (several
# agent sessions each install what they need), so every step that changes what
# they share -- the version folders, the links in $BINDIR, the prune -- runs
# under a lock. Everything before it (download, checksum, unpack into a private
# folder) runs in parallel.
#
# mkdir is the lock because it is atomic everywhere and needs nothing macOS
# lacks (there is no flock(1) there). The holder's PID goes into it, so a lock
# whose holder was killed can be cleared rather than waited out. Clearing is
# itself serialised by a second, short-lived mkdir lock: two waiters that both
# find the holder gone must not both remove the lock, or the second would
# remove the one the first has just taken.
# ---------------------------------------------------------------------------
LOCK="$PREFIX/.install.lock"
LOCK_TIMEOUT=300   # seconds to wait for another installer before giving up

pid_alive() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null
}

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }

# Removes $LOCK if its holder, PID $1 (empty: none was recorded), is still the
# holder and still gone.
clear_stale_lock() {
  mkdir "$LOCK.break" 2>/dev/null || return 0
  if [ -d "$LOCK" ] && [ "$(lock_pid)" = "$1" ] && ! pid_alive "$1"; then
    printf 'install.sh: clearing the lock of an install that is gone: %s\n' "$LOCK" >&2
    rm -rf "$LOCK"
  fi
  rmdir "$LOCK.break" 2>/dev/null || true
}

acquire_lock() {
  _waited=0
  _said=0
  _nopid=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    [ -d "$LOCK" ] || die "could not create the lock $LOCK"
    _holder=$(lock_pid)
    if [ -n "$_holder" ]; then
      _nopid=0
      if ! pid_alive "$_holder"; then
        clear_stale_lock "$_holder"
        continue
      fi
    else
      # The holder writes its PID right after its mkdir, so a lock without one
      # for several seconds belongs to an installer killed in between.
      _nopid=$((_nopid + 1))
      if [ "$_nopid" -ge 5 ]; then
        clear_stale_lock ""
        _nopid=0
        continue
      fi
    fi
    # A breaker holds $LOCK.break for an instant; one still there this long was
    # killed while holding it.
    if [ -d "$LOCK.break" ] && [ "$_waited" -ge 10 ]; then
      rmdir "$LOCK.break" 2>/dev/null || true
    fi
    if [ "$_said" = 0 ]; then
      printf 'install.sh: waiting for another install into %s to finish (pid %s)\n' \
        "$PREFIX" "${_holder:-unknown}" >&2
      _said=1
    fi
    [ "$_waited" -lt "$LOCK_TIMEOUT" ] || die "gave up after ${LOCK_TIMEOUT}s waiting for another install into $PREFIX.
  If no other install is running, remove the lock and try again:

      rm -rf '$LOCK'"
    sleep 1
    _waited=$((_waited + 1))
  done
  HAVE_LOCK=1
  echo "$$" > "$LOCK/pid"
}

release_lock() {
  [ "$HAVE_LOCK" = 1 ] || return 0
  HAVE_LOCK=0
  [ "$(lock_pid)" != "$$" ] || rm -rf "$LOCK"
}

# Reduces the release listing, newest first, to the tag of the newest release
# that is not a draft.
newest_tag() {
  if command -v jq >/dev/null 2>&1; then
    jq -er '[.[] | select(.draft == false)][0].tag_name'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
print(next(r for r in json.load(sys.stdin) if not r["draft"])["tag_name"])'
  else
    die "this install needs jq or python3 to read the release listing"
  fi
}

# Every release is public, so once the tag is known the assets are downloaded by
# name like on the other paths -- the GitHub API is only asked for the listing.
# Its anonymous requests are limited to 60 an hour per address, so the API is
# never asked for anything the plain download URLs can provide.
resolve_prerelease() {
  _url="https://api.github.com/repos/$REPO/releases?per_page=20"
  if ! curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" \
            -o "$TMP/releases.json" "$_url" 2>"$TMP/api.err"; then
    # What the transport actually said, kept above the advice and set apart
    # from it.
    if [ -s "$TMP/api.err" ]; then
      sed 's/^/  /' "$TMP/api.err" >&2
      echo "" >&2
    fi
    die "could not list the releases of $REPO.

  The GitHub API limits anonymous requests to 60 an hour per address, so a
  shared address may have used them up. Naming a release avoids the API:

      export MARIADB_RESTD_TAG=<tag>
"
  fi

  RELEASE_DESC=$(newest_tag < "$TMP/releases.json") \
    || die "could not find a published release in $REPO -- is every release a
  draft?"
  BASE="https://github.com/$REPO/releases/download/$RELEASE_DESC"
}

fetch() {
  curl -fL --retry 3 ${3:-} -o "$2" "$BASE/$1"
}

[ "$RESOLVE_PRERELEASE" = 0 ] || resolve_prerelease

if [ -n "$SUMS_FILE" ]; then
  info "Reading package list for the $RELEASE_DESC release from $SUMS_FILE"
  cp "$SUMS_FILE" "$TMP/SHA256SUMS" || die "could not read $SUMS_FILE"
else
  info "Fetching package list from the $RELEASE_DESC release"
fi
# Silent, and its stderr kept aside, so that what curl said is printed above the
# advice rather than mixed with its progress output.
if [ -z "$SUMS_FILE" ] && ! fetch SHA256SUMS "$TMP/SHA256SUMS" -sS 2>"$TMP/fetch.err"; then
  if [ -s "$TMP/fetch.err" ]; then
    sed 's/^/  /' "$TMP/fetch.err" >&2
    echo "" >&2
  fi
  # A release that was just found in the listing exists; one that was named or
  # implied may not.
  if [ "$RESOLVE_PRERELEASE" = 1 ]; then
    die "could not download SHA256SUMS from release $RELEASE_DESC of $REPO.

  The release exists but has no SHA256SUMS file. A release that is still being
  published does not have its files yet; try again in a few minutes."
  fi
  die "could not download SHA256SUMS from the $RELEASE_DESC release
  of $REPO.

  That release may not exist.

  $PRERELEASE_HINT
"
fi

# Select. One package per OS and CPU, with no platform version in its name, so
# the suffix identifies it.
PKG=$(awk -v s="-$OS-$ARCH.tar.gz" '
  substr($2, 1, 14) == "mariadb-restd-" && length($2) > length(s) &&
  substr($2, length($2) - length(s) + 1) == s { print $2; exit }' "$TMP/SHA256SUMS")

if [ -z "$PKG" ]; then
  echo "install.sh: no package for $OS / $ARCH in the $RELEASE_DESC release." >&2
  echo "Available packages:" >&2
  awk '{print "  " $2}' "$TMP/SHA256SUMS" >&2
  exit 1
fi

info "Selected $PKG"

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------
info "Downloading"
fetch "$PKG" "$TMP/$PKG" --progress-bar \
  || die "could not download $PKG from release $RELEASE_DESC of $REPO"

info "Verifying checksum"
EXPECTED=$(awk -v f="$PKG" '$2 == f {print $1}' "$TMP/SHA256SUMS")
[ -n "$EXPECTED" ] || die "no checksum for $PKG in SHA256SUMS"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$TMP/$PKG" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "$TMP/$PKG" | awk '{print $1}')
else
  die "neither sha256sum nor shasum available; cannot verify the download"
fi

[ "$ACTUAL" = "$EXPECTED" ] || die "checksum mismatch for $PKG
  expected: $EXPECTED
  actual:   $ACTUAL"

# ---------------------------------------------------------------------------
# Unpack. The tarball holds a single top-level mariadb-restd-<ver>-<platform>
# directory, which is renamed to just the version: the platform is a property of
# the machine that unpacked it, not something worth repeating in every path a
# user types. Versions sit side by side, so an install can be undone by
# re-pointing the links below -- but only two are kept, see the prune at the end.
#
# Each run unpacks into a private folder of its own: two runs unpacking the
# same tarball into one place trip over each other's files and both fail. The
# folder is inside $PREFIX so the move into place is a rename on one
# filesystem, and carries the PID so a later run can tell when it is stale.
# ---------------------------------------------------------------------------
info "Unpacking into $PREFIX"
mkdir -p "$PREFIX"
UNPACK=$(mktemp -d "$PREFIX/.unpack.$$.XXXXXX")
tar -xzf "$TMP/$PKG" -C "$UNPACK"

TOPDIR=$(tar -tzf "$TMP/$PKG" | awk -F/ 'NF>1 {print $1; exit}')
[ -n "${TOPDIR:-}" ] || die "unexpected tarball layout in $PKG"
[ -d "$UNPACK/$TOPDIR" ] || die "expected $TOPDIR in the tarball after unpacking"

# Falls back to the directory the tarball actually carried, so an unrecognised
# name costs the tidy layout rather than the install.
VERSION=$(echo "$TOPDIR" | sed -n 's/^mariadb-restd-\([0-9][0-9.]*\)-.*/\1/p')
[ -n "${VERSION:-}" ] || VERSION="$TOPDIR"

# From here on, everything changes what other installers share.
acquire_lock

# Unpack folders of runs that were killed, which no trap removed.
for d in "$PREFIX"/.unpack.*; do
  [ -d "$d" ] || continue
  _pid=${d##*/.unpack.}
  _pid=${_pid%%.*}
  [ "$d" = "$UNPACK" ] || pid_alive "$_pid" || rm -rf "$d"
done

# A version folder whose mariadb-restd is byte for byte the one just unpacked
# holds the same build -- typically because another installer finished it a
# moment ago -- and is kept: replacing it would pull files (its libraries and
# plugins) from under any daemon already running from it, for no change at all.
# Any other folder of that name is replaced as before.
if [ -x "$PREFIX/$VERSION/bin/mariadb-restd" ] \
   && cmp -s "$PREFIX/$VERSION/bin/mariadb-restd" "$UNPACK/$TOPDIR/bin/mariadb-restd"; then
  info "Keeping $PREFIX/$VERSION, already installed from this build"
else
  rm -rf "$PREFIX/$VERSION"
  mv "$UNPACK/$TOPDIR" "$PREFIX/$VERSION"
fi

RESTD_BIN="$PREFIX/$VERSION/bin/mariadb-restd"
[ -x "$RESTD_BIN" ] || die "no executable at $RESTD_BIN after unpacking"

# ---------------------------------------------------------------------------
# Links. mariadb-restd finds its libraries and plugins from its real path, so a
# symlink in $BINDIR runs it as well as the binary itself. A program this
# package lacks loses the link an earlier install left (only a link into
# $PREFIX, so one made by hand stays): it would run that version, or dangle once
# the prune below removes it.
# ---------------------------------------------------------------------------
mkdir -p "$BINDIR"
LINKED=""
for prog in $PROGRAMS; do
  if [ -x "$PREFIX/$VERSION/bin/$prog" ]; then
    ln -sfn "$PREFIX/$VERSION/bin/$prog" "$BINDIR/$prog"
    LINKED="$LINKED $prog"
  elif [ -L "$BINDIR/$prog" ]; then
    case "$(readlink "$BINDIR/$prog")" in
      "$PREFIX"/*) rm -f "$BINDIR/$prog" ;;
    esac
  fi
done

# Only a nicety: a binary that does not start here (a system older than the
# package needs) is reported by its own error when it is run.
REPORTED=$("$RESTD_BIN" --version 2>/dev/null | head -n 1) || true
info "Installed ${REPORTED:-$VERSION}"
_label="Binary:"
for prog in $LINKED; do
  info "$_label $BINDIR/$prog -> $PREFIX/$VERSION/bin/$prog"
  _label="       "
done

# ---------------------------------------------------------------------------
# Prune. Only the version just installed and the highest of the rest survive:
# one way back is worth keeping, a museum is not. Deliberately narrow about what
# it will delete -- a name has to be purely digits and dots to be considered
# ours, so anything else under PREFIX is left alone rather than guessed at.
# That covers this script's own dot folders too: the glob below skips them, and
# is_version_dir would refuse them anyway.
# ---------------------------------------------------------------------------
is_version_dir() {
  [ -d "$1" ] || return 1
  [ -L "$1" ] && return 1
  case "${1##*/}" in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  case "${1##*/}" in
    *[!0-9.]*) return 1 ;;
  esac
  return 0
}

KEEP_OTHER=""
for d in "$PREFIX"/*; do
  is_version_dir "$d" || continue
  name=${d##*/}
  [ "$name" = "$VERSION" ] && continue
  if [ -z "$KEEP_OTHER" ] || ver_le "$KEEP_OTHER" "$name"; then
    KEEP_OTHER="$name"
  fi
done

for d in "$PREFIX"/*; do
  is_version_dir "$d" || continue
  name=${d##*/}
  [ "$name" = "$VERSION" ] && continue
  [ "$name" = "$KEEP_OTHER" ] && continue
  info "Removing superseded version $name"
  rm -rf "$PREFIX/$name"
done

[ -z "$KEEP_OTHER" ] || info "Kept previous version $KEEP_OTHER"

release_lock

# Only a hint, never an edit: rewriting a user's shell rc from a piped installer
# is not this script's call to make.
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *)
    echo ""
    echo "$BINDIR is not on your PATH. Add it with:"
    echo ""
    echo "    export PATH=\"$BINDIR:\$PATH\""
    echo ""
    ;;
esac
