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

"""MariaDB mode of the MRS functional suite: rewrites of the MySQL-only SQL
in the upstream test scripts and fixtures, applied to every statement the
interpreter sends to the server (the echoed statement in the output stays
the original, so the .result files are shared with MySQL where possible).

Keep this list short and mechanical; a test that needs more than this gets
a MariaDB-specific result or goes to disabled.mariadb.def."""

from __future__ import annotations

import re

# column attribute: `g` GEOMETRY NOT NULL SRID 4326 (no SRID attribute on MariaDB)
_SRID_ATTR = re.compile(r"\s+SRID\s+\d+(?=\s*(?:,|\)|NOT\s+NULL|NULL|DEFAULT|COMMENT))", re.I)
# VECTOR without a dimension: MySQL's VECTOR holds up to 2048 values and the
# tests store rows of different lengths; MariaDB's VECTOR(n) is a fixed n. A
# BLOB holds the same bytes (VEC_FromText/VEC_ToText work on any binary) and
# MRS knows the column as VECTOR from the metadata, not from the table.
_VECTOR_NO_DIM = re.compile(r"\bVECTOR\b(?!\s*\()", re.I)
_DDL = re.compile(r"\s*(CREATE|ALTER)\b", re.I)
_FUNCS = [(re.compile(r"\bSTRING_TO_VECTOR\s*\(", re.I), "VEC_FromText("),
          (re.compile(r"\bVECTOR_TO_STRING\s*\(", re.I), "VEC_ToText(")]
_CAST_OPEN = re.compile(r"\bCAST\s*\(", re.I)
_AS_JSON_TAIL = re.compile(r"\s+AS\s+JSON\s*$", re.I)


def _rewrite_cast_as_json(sql: str) -> str:
    """CAST(x AS JSON) -> JSON_COMPACT(x): MariaDB has no JSON cast target"""
    out = []
    pos = 0
    while True:
        m = _CAST_OPEN.search(sql, pos)
        if not m:
            out.append(sql[pos:])
            return "".join(out)
        # find the matching parenthesis
        depth = 1
        i = m.end()
        while i < len(sql) and depth:
            if sql[i] == "(":
                depth += 1
            elif sql[i] == ")":
                depth -= 1
            i += 1
        inner = sql[m.end():i - 1]
        tail = _AS_JSON_TAIL.search(inner)
        out.append(sql[pos:m.start()])
        if tail:
            out.append("JSON_COMPACT(" + _rewrite_cast_as_json(inner[:tail.start()]) + ")")
        else:
            out.append("CAST(" + _rewrite_cast_as_json(inner) + ")")
        pos = i


# the tests derive column metadata from information_schema.columns, whose
# SRS_ID column (the column's SRID) doesn't exist on MariaDB
_SRS_ID = re.compile(r"\bSRS_ID\b")


# JSON path operators (MySQL only; MariaDB 13 has them, 11.8 not), with a
# single- or double-quoted path
_ARROW2 = re.compile(r"""([A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*|\))->>('\$[^']*'|"\$[^"]*")""")
_ARROW1 = re.compile(r"""([A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*|\))->('\$[^']*'|"\$[^"]*")""")
# statements of the GTID machinery and MySQL-only variables
_RESET_GTIDS = re.compile(r"^\s*RESET\s+BINARY\s+LOGS\s+AND\s+GTIDS\s*$", re.I)
_SUPER_READ_ONLY = re.compile(r"\bsuper_read_only\b", re.I)
# MySQL's FROM_BASE64() returns NULL for invalid input, MariaDB's raises an
# error (strict mode); the tests pass placeholders like 'ignore'
_FROM_BASE64 = re.compile(r"\bFROM_BASE64\s*\(", re.I)


def _rewrite_arrows(sql: str) -> str:
    # a ')' before the arrow means a function result: not handled here
    sql = _ARROW2.sub(lambda m: f"JSON_UNQUOTE(JSON_EXTRACT({m.group(1)},{m.group(2)}))"
                      if m.group(1) != ")" else m.group(0), sql)
    sql = _ARROW1.sub(lambda m: f"JSON_EXTRACT({m.group(1)},{m.group(2)})"
                      if m.group(1) != ")" else m.group(0), sql)
    return sql


def _rewrite_from_base64(sql: str) -> str:
    out = []
    pos = 0
    while True:
        m = _FROM_BASE64.search(sql, pos)
        if not m:
            out.append(sql[pos:])
            return "".join(out)
        depth = 1
        i = m.end()
        while i < len(sql) and depth:
            if sql[i] == "(":
                depth += 1
            elif sql[i] == ")":
                depth -= 1
            i += 1
        arg = sql[m.end():i - 1]
        out.append(sql[pos:m.start()])
        # MySQL ignores whitespace (the tests' values contain newlines)
        compact = f"REGEXP_REPLACE({arg}, '[[:space:]]', '')"
        out.append(f"IF({compact} REGEXP '^[A-Za-z0-9+/]*={{0,2}}$' AND LENGTH({compact}) % 4 = 0, "
                   f"FROM_BASE64({arg}), NULL)")
        pos = i


# MySQL system tables the tests read: the role grants and the process list
_ROLE_EDGES = re.compile(r"select\s+from_user,\s*to_user\s+from\s+mysql\.role_edges\s+where\s+to_user\s+like\s+('[^']*')\s+order\s+by\s+from_user", re.I)
_PS_PROCESSLIST = re.compile(r"\bperformance_schema\.processlist\b", re.I)
# MariaDB's mysql.user is a view with capitalised column names (User, Host)
_MYSQL_USER_COLS = re.compile(r"\bselect\s+user,\s*host\s+from\s+mysql\.user\b", re.I)


def rewrite(sql: str) -> str:
    if _RESET_GTIDS.match(sql):
        return "DO 0"  # no GTIDs to reset, nothing to do
    sql = _ROLE_EDGES.sub(r"SELECT Role AS from_user, User AS to_user FROM mysql.roles_mapping WHERE User LIKE \1 ORDER BY Role", sql)
    sql = _PS_PROCESSLIST.sub("information_schema.processlist", sql)
    sql = _MYSQL_USER_COLS.sub("select user AS user, host AS host from mysql.user", sql)
    sql = _SRID_ATTR.sub("", sql)
    sql = _SUPER_READ_ONLY.sub("read_only", sql)
    if "information_schema.columns" in sql.lower():
        sql = _SRS_ID.sub("NULL", sql)
    if "->" in sql:
        sql = _rewrite_arrows(sql)
    if "FROM_BASE64" in sql.upper():
        sql = _rewrite_from_base64(sql)
    if _DDL.match(sql):  # not in string literals of INSERTs (a "/VECTOR" path)
        sql = _VECTOR_NO_DIM.sub("BLOB", sql)
    for pattern, repl in _FUNCS:
        sql = pattern.sub(repl, sql)
    if "JSON" in sql.upper():
        sql = _rewrite_cast_as_json(sql)
    return sql


# ---------------------------------------------------------------------------
# output comparison in MariaDB mode
# ---------------------------------------------------------------------------
import json

_CONTENT_LENGTH = re.compile(r"(Content-Length  ->  )\d+")
_DROPPED_USERS_NOTE = re.compile(r"^Warnings:\nNote\t4227\tDropped users .*\n", re.M)
_ETAG = re.compile(r'("etag": ")[0-9A-F]{64}(")')
# the GTID of a write (session_track_gtids), not available on MariaDB until
# an open point, see PLAN.md; the tests print it as "GTID" (a replace_regex)
_GTID_LINE = re.compile(r'^\s*"gtid": "[^"]*",?\n', re.M)


def _canonical_json(text: str):
    """re-dump a JSON document with sorted keys; integral floats as ints"""
    def fix(v):
        if isinstance(v, dict):
            return {k: fix(x) for k, x in v.items()}
        if isinstance(v, list):
            return [fix(x) for x in v]
        if isinstance(v, float) and v.is_integer():
            return int(v)
        return v
    return json.dumps(fix(json.loads(text)), sort_keys=True, indent=4,
                      ensure_ascii=False)


def normalize_output(text: str) -> str:
    """What legitimately differs between the servers and is not what the
    tests check: the length of documents with JSON values (MariaDB returns
    JSON text as stored, MySQL normalized), the member order of objects
    (MySQL sorts keys by length, MariaDB keeps the insertion order), the
    etags that hash those documents, integral floats (ST_AsGeoJSON prints
    20 vs 20.0). The pretty-printed documents of the mrs_client are re-dumped
    with sorted keys; other lines stay as they are."""
    # DROP USER of an account with open connections: a Note whose presence
    # depends on timing (MySQL never emits it)
    text = _DROPPED_USERS_NOTE.sub("", text)
    text = _CONTENT_LENGTH.sub(r"\1<n>", text)
    text = _ETAG.sub(r"\1<etag>\2", text)
    text = _GTID_LINE.sub("", text)
    text = re.sub(r',(\n\s*[}\]])', r'\1', text)  # a comma the removal left behind
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line in ("{", "[") or (line.startswith(("{", "[")) and line.rstrip().endswith(("}", "]"))):
            # a pretty-printed document ends with its closer in column 0, a
            # one-line document is a line of its own
            j = i
            if line in ("{", "["):
                closer = "}" if line == "{" else "]"
                while j < len(lines) and lines[j] != closer:
                    j += 1
            block = "\n".join(lines[i:j + 1])
            try:
                out.append(_canonical_json(block))
                i = j + 1
                continue
            except (ValueError, IndexError):
                pass
        out.append(line)
        i += 1
    return "\n".join(out)
