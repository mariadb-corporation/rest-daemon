#!/usr/bin/env python3
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

"""Usage: MYSQL_SRC=<server src> MYSQL_BLD=<configured build> include_closure.py [--tests]

Transitive #include closure of the MRS module set, reporting what lands
outside the set (other router modules, server tree, generated, unresolved)."""
import os, re, sys, collections

SRC = os.environ.get("MYSQL_SRC", "<dev>/mysql/mysql-server")
BLD = os.environ.get("MYSQL_BLD", SRC + "/build")
R = SRC + "/router/src"

KEEP = ["harness", "router", "http", "rest_api", "io", "mysql_protocol",
        "mysql_rest_service", "jit_executor", "json_schema_embedder", "openssl",
        "plugin_info", "connection_pool", "destination_status", "keepalive",
        "rest_router", "rest_connection_pool"]
# directories to scan as roots (production code only unless --tests)
with_tests = "--tests" in sys.argv

def is_test(p):
    return "/tests/" in p or "/test/" in p or os.path.basename(p).startswith("test_")

roots = []
for m in KEEP:
    for d, _, fs in os.walk(os.path.join(R, m)):
        for f in fs:
            if f.endswith((".cc", ".h", ".c", ".hpp", ".cpp")):
                p = os.path.join(d, f)
                if not with_tests and is_test(p):
                    continue
                roots.append(p)

inc_dirs = []
for m in os.listdir(R):
    for sub in ("include", "src", "src/include"):
        p = os.path.join(R, m, sub)
        if os.path.isdir(p):
            inc_dirs.append(p)
inc_dirs += [SRC + "/router/src/mysql_rest_service/src",
             SRC + "/router/src/jit_executor/src",
             SRC + "/include", SRC, SRC + "/libs",
             SRC + "/extra/rapidjson/include",
             BLD + "/include", BLD + "/router/include",
             BLD + "/router/src/harness/include", BLD + "/router/src/router/include"]
# generated router headers
for d, _, fs in os.walk(BLD + "/router"):
    if d.endswith("include"):
        inc_dirs.append(d)

INC = re.compile(r'^\s*#\s*include\s*([<"])([^>"]+)[>"]', re.M)
SYSTEM_HINT = re.compile(r'^[a-z_0-9]+(\.h)?$|^(sys|arpa|netinet|net|linux|mach|openssl|google|gtest|gmock|rapidjson|unicode|zlib|zstd|lz4|windows|winsock2|ws2tcpip)/')

def in_keep(p):
    return any(p.startswith(os.path.join(R, m) + "/") for m in KEEP)

def classify(p):
    if in_keep(p): return None
    if p.startswith(BLD): return "generated"
    if p.startswith(R + "/"): return "router:" + p[len(R)+1:].split("/")[0]
    if p.startswith(SRC + "/extra/"): return "extra:" + p[len(SRC)+7:].split("/")[0]
    return "server"

seen, outside, unresolved = set(), collections.defaultdict(set), collections.defaultdict(set)
stack = list(roots)
while stack:
    f = stack.pop()
    if f in seen: continue
    seen.add(f)
    try:
        txt = open(f, errors="ignore").read()
    except OSError:
        continue
    for kind, name in INC.findall(txt):
        cands = ([os.path.join(os.path.dirname(f), name)] if kind == '"' else []) + \
                [os.path.join(d, name) for d in inc_dirs]
        hit = next((os.path.normpath(c) for c in cands if os.path.isfile(c)), None)
        if hit is None:
            if not SYSTEM_HINT.search(name) or kind == '"':
                unresolved[name].add(os.path.relpath(f, SRC))
            continue
        c = classify(hit)
        if c:
            outside[(c, os.path.relpath(hit, SRC))].add(os.path.relpath(f, SRC))
        stack.append(hit)

by_cat = collections.defaultdict(list)
for (c, p), users in outside.items():
    by_cat[c.split(":")[0] if c.startswith("router") is False else c].append((p, users))

print(f"# roots scanned: {len(roots)}  files reached: {len(seen)}  tests={'yes' if with_tests else 'no'}\n")
for cat in sorted(by_cat):
    items = sorted(by_cat[cat])
    print(f"## {cat}  ({len(items)} files)")
    for p, users in items:
        direct = sorted(u for u in users if in_keep(os.path.join(SRC, u)))
        ex = direct[0] if direct else sorted(users)[0]
        print(f"  {p}   <- {ex}{' (+%d)' % (len(users)-1) if len(users) > 1 else ''}")
    print()
print(f"## unresolved quoted/unknown includes ({len(unresolved)})")
for n in sorted(unresolved):
    print(f"  {n}   <- {sorted(unresolved[n])[0]}")
