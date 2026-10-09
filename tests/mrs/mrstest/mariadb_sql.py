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


def rewrite(sql: str) -> str:
    sql = _SRID_ATTR.sub("", sql)
    if "information_schema.columns" in sql.lower():
        sql = _SRS_ID.sub("NULL", sql)
    sql = _VECTOR_NO_DIM.sub("BLOB", sql)
    for pattern, repl in _FUNCS:
        sql = pattern.sub(repl, sql)
    if "JSON" in sql.upper():
        sql = _rewrite_cast_as_json(sql)
    return sql
