#!/usr/bin/env python3
# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2.0,
# as published by the Free Software Foundation.
"""Convert the functional suite (tests/mrs) from metadata schema 4.x to 5.0.0.

One-off, kept for review (Milestone 3.4). Rewrites only SQL identifiers and
the few literals 5.0.0 changed; the suite's own vocabulary (`$mrs_add_db_object`,
`include/mrs/db_object/...`, `@db_object_id`, `--echo` texts) stays:

- `mysql_rest_service_metadata[.table]` -> `mariadb_rest_service[.new table]`
- the roles `mysql_rest_service_<role>` -> `mariadb_rest_service_<role>`
- in SQL text: the renamed tables (in table positions: after FROM, JOIN,
  INTO, UPDATE, TABLE, or as a column qualifier) and the renamed columns
- the vendor name `MySQL Internal` -> `MariaDB Internal`
- the daemon id: `--let $extra_mrs_router_id=1` -> a fixed UUID, quoted where
  SQL compares with it
- the vendor ids `0x30...`/`0x31...` in SQL -> UUID text (not the `vendorId`
  of the JSON responses, which keeps its `0x` form)

Known over-reach: in r/ an `--echo` line that does not start with `#` is taken
for SQL output (4 lines in 2 files); the re-record restored them.

SQL text: in t/ and include/ every line that is not a comment, `echo`,
`source`, `die`, `skip`, or a `let` without SQL; in r/ every line not starting
with `#` (the echoed comments). Prints a per-rule count; `--dry-run` writes
nothing.

Usage: tools/analysis/convert_suite_5.py [--dry-run] [files...]
"""

import argparse
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
SUITE = os.path.join(ROOT, "tests", "mrs")

# the fixed id of the daemon the suite starts (conftest.py has the same); it
# must not start with "0": the tests use it as a flag (`if ($extra_mrs_router_id)`)
# and mysqltest reads a value starting with "0" as false
DAEMON_UUID = "10000000-0000-7000-8000-000000000001"

TABLES = {
    "router": "rest_daemon",
    "router_status": "rest_daemon_status",
    "router_general_log": "rest_daemon_general_log",
    "router_services": "rest_daemon_services",
    "router_session": "rest_daemon_session",
    "db_schema": "rest_schema",
    "db_object": "rest_object",
    "object": "data_mapping",
    "object_field": "data_mapping_field",
    "object_reference": "data_mapping_reference",
    "mrs_db_object_row_group_security": "mrs_rest_object_row_group_security",
    "content_set_has_obj_def": "content_set_has_rest_object",
    "object_fields_with_references": "data_mapping_fields_with_references",
}
# unique names: renamed wherever they occur in SQL text
COLUMNS = {
    "db_schema_id": "rest_schema_id",
    "db_object_id": "rest_object_id",
    "object_id": "data_mapping_id",
    "router_id": "rest_daemon_id",
    "router_session_id": "rest_daemon_session_id",
    "router_name": "name",
    "mysql_connections": "mariadb_connections",
    "mysql_queries": "mariadb_queries",
    "active_mysql_connections": "active_mariadb_connections",
}
ROLES = ("meta_provider", "data_provider", "admin", "schema_admin", "dev",
         "user")
VENDOR_IDS = {
    "0x30000000000000000000000000000000": "'30000000-0000-0000-0000-000000000000'",
    "0x31000000000000000000000000000000": "'31000000-0000-0000-0000-000000000000'",
}

counts = collections.Counter()


def sub(pattern, repl, text, rule, flags=0):
    new, n = re.subn(pattern, repl, text, flags=flags)
    counts[rule] += n
    return new


def table_name(name):
    return TABLES.get(name, name)


def convert_everywhere(line):
    line = sub(r"(`?)mysql_rest_service_metadata(`?)\.(`?)(\w+)",
               lambda m: "%smariadb_rest_service%s.%s%s" % (
                   m.group(1), m.group(2), m.group(3), table_name(m.group(4))),
               line, "qualified table")
    line = sub(r"\bmysql_rest_service_metadata\b", "mariadb_rest_service", line,
               "schema name")
    line = sub(r"\bmysql_rest_service_(%s)\b" % "|".join(ROLES),
               r"mariadb_rest_service_\1", line, "role")
    line = sub(r"\bMySQL Internal\b", "MariaDB Internal", line, "vendor name")
    return line


TABLE_ALT = "|".join(sorted(TABLES, key=len, reverse=True))
COLUMN_ALT = "|".join(sorted(COLUMNS, key=len, reverse=True))


def convert_sql(text):
    # a table after a keyword that names one
    text = sub(r"(?i)\b(FROM|JOIN|INTO|UPDATE|TABLE|EXISTS)(\s+)(`?)(%s)(`?)(?![\w.])"
               % TABLE_ALT,
               lambda m: m.group(1) + m.group(2) + m.group(3) +
               table_name(m.group(4)) + m.group(5),
               text, "table after keyword")
    # a table as a column qualifier: `object.db_object_id`, `router.id`
    text = sub(r"(?<![\w@$.`])(`?)(%s)(`?)\.(?=`?\w)" % TABLE_ALT,
               lambda m: m.group(1) + table_name(m.group(2)) + m.group(3) + ".",
               text, "table qualifier")
    # also behind an alias (`o.db_schema_id`), not in a JSON path (`$.x`)
    text = sub(r"(?<![\w@$])(?<!\$\.)(`?)(%s)(?!\w)" % COLUMN_ALT,
               lambda m: m.group(1) + COLUMNS[m.group(2)], text, "column")
    # SQL literals only: `"vendorId": "0x31..."` is wire output and stays
    for old, new in VENDOR_IDS.items():
        text = sub(r'(?<!")%s(?!")' % re.escape(old), new, text,
                   "vendor id literal")
    # the daemon id compared in SQL: quote it (it is a UUID now)
    # (not the option written into a generated configuration file)
    text = sub(r"(=\s*)\$extra_mrs_router_id\b(?!\\n)",
               r"\1'$extra_mrs_router_id'", text, "daemon id quoted")
    return text


NOT_SQL = re.compile(
    r"^\s*(#|--echo\b|echo\b|--source\b|source\b|--die\b|die\b|--skip\b|"
    r"skip\b|--exec\b|exec\b|--replace_regex\b|replace_regex\b|"
    r"--replace_result\b|replace_result\b|--error\b|--let\s+\$\w+\s*=\s*[^`]*$)",
    re.I)
SQL_WORDS = re.compile(r"(?i)\b(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE)\b")
LET_DAEMON_ID = re.compile(r"^(\s*--let\s+\$extra_mrs_router_id\s*=\s*)1\s*$")


def is_sql_line(line, is_result):
    if is_result:
        return not line.startswith("#")
    if NOT_SQL.match(line):
        # a `let` whose value is SQL (wait conditions, statements to eval)
        m = re.match(r"^\s*--let\s+\$\w+\s*=(.*)$", line)
        return bool(m and SQL_WORDS.search(m.group(1)))
    return True


def convert_file(path, dry_run):
    is_result = path.endswith(".result")
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.readlines()
    out = []
    for line in lines:
        new = convert_everywhere(line)
        m = LET_DAEMON_ID.match(new)
        if m:
            counts["daemon id let"] += 1
            new = m.group(1) + DAEMON_UUID + "\n"
        elif is_sql_line(new, is_result):
            new = convert_sql(new)
        out.append(new)
    if out != lines:
        counts["files changed"] += 1
        if not dry_run:
            with open(path, "w", encoding="utf-8", errors="surrogateescape",
                      newline="") as f:
                f.writelines(out)


def suite_files():
    for sub_dir in ("include", "t", "r", "mtr_include"):
        for root, _, files in os.walk(os.path.join(SUITE, sub_dir)):
            if os.path.basename(root) == "schema":
                continue  # the generated schema and the user-data schemas
            for name in files:
                if name.endswith((".inc", ".test", ".result", ".sql", ".cnf")):
                    yield os.path.join(root, name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()
    for path in args.files or sorted(suite_files()):
        convert_file(path, args.dry_run)
    for rule, n in sorted(counts.items()):
        print("%6d  %s" % (n, rule))


if __name__ == "__main__":
    main()
