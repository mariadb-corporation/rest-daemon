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

"""Runs each tests/mrs/t/<name>.test and compares the output with
tests/mrs/r/<name>.result (see conftest.py and mrstest/mysqltest.py)."""

from __future__ import annotations

import difflib
import re
import os
import sys
from pathlib import Path

import pytest

from conftest import IS_WINDOWS, SUITE_DIR, Mrsd, server_options_for
from mrstest import mariadb_sql
from mrstest.mysqltest import Environment, Interpreter, ScriptFailed, ScriptSkipped


def read_def(filename: str) -> dict[str, str]:
    result = {}
    f = SUITE_DIR / filename
    for line in f.read_text(encoding="utf-8").splitlines() if f.exists() else []:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition(":")
        result[name.strip()] = reason.strip()
    return result


TESTS = sorted(p.stem for p in (SUITE_DIR / "t").glob("*.test"))
DISABLED = read_def("disabled.def")
KNOWN_FAILURES = read_def("known_failures.def")
# MariaDB mode: more disabled tests and known failures (reasons in the files)
MARIADB_DISABLED = read_def("disabled.mariadb.def")
MARIADB_KNOWN_FAILURES = read_def("known_failures.mariadb.def")


def printable(text: str) -> str:
    """binary response data (surrogateescape) in a failure message can't be
    serialized by the pytest-xdist workers: replace it"""
    return text.encode("utf-8", "replace").decode("utf-8")


def shell() -> list[str]:
    # the shell mysqltest's exec uses: popen() runs cmd.exe on Windows
    if IS_WINDOWS:
        return ["cmd.exe", "/d", "/s", "/c"]
    return ["bash", "-c"]


@pytest.mark.parametrize("name", TESTS)
def test_mrs(name, paths, mysqld, tmp_path, request):
    disabled = {**DISABLED, **MARIADB_DISABLED} if paths.is_mariadb else DISABLED
    known = {**KNOWN_FAILURES, **MARIADB_KNOWN_FAILURES} if paths.is_mariadb else KNOWN_FAILURES
    if name in disabled:
        pytest.skip(disabled[name])
    if name in known:
        request.applymarker(pytest.mark.xfail(reason=known[name], strict=False))

    test_file = SUITE_DIR / "t" / f"{name}.test"
    result_file = SUITE_DIR / "r" / f"{name}.result"
    if paths.is_mariadb:
        # a MariaDB-specific expected result, where the output legitimately
        # differs (error texts, server-specific values)
        mariadb_result = SUITE_DIR / "r" / f"{name}.mariadb.result"
        if mariadb_result.exists() or request.config.getoption("--record-mariadb"):
            result_file = mariadb_result
    router_cnf = SUITE_DIR / "t" / f"{name}-router.cnf"

    mysqld.ensure_options(server_options_for(SUITE_DIR / "t" / f"{name}.cnf"))
    mrsd = Mrsd(paths, mysqld, tmp_path / "router",
                router_cnf if router_cnf.exists() else None)
    mrsd.start()

    tmp = tmp_path / "tmp"
    tmp.mkdir()
    env = {
        "MRS_CLIENT": str(paths.mrs_client),
        "HTTP_SERVER_PORT": str(mrsd.http_port),
        "HTTP_SERVER_SSL": mrsd.http_ssl,
        "MYSQL_TMP_DIR": str(tmp),
        "MYSQLTEST_VARDIR": str(mrsd.base),
        "MYSQL_TEST_DIR": str(SUITE_DIR),
        "STD_DATA_DIR": str(SUITE_DIR.parent / "data" / "ssl"),
        "MASTER_MYPORT": str(mysqld.port),
        "MASTER_MYSOCK": str(mysqld.datadir / "m.sock"),
        "MYSQLROUTER": str(paths.mrsd),
        "MYSQLROUTER_KEYRING": str(paths.keyring),
        "MYSQLROUTER_LOGFILE": str(mrsd.logfile),
        "MYSQLROUTER_PIDFILE": str(mrsd.pidfile),
        "ROUTER_PLUGIN_DIRECTORY": str(paths.plugins),
        "_MRS_CONTROL_START": "1",
        "USER": os.environ.get("USER", os.environ.get("USERNAME", "")),
    }
    if paths.is_mariadb:
        env["MARIADB"] = "1"  # for the .inc files

    def require_jit(_arg):
        if not paths.has_jit:
            raise ScriptSkipped("mrsd built without the JIT executor")

    envn = Environment(
        mysql_host="127.0.0.1", mysql_port=mysqld.port, mysql_user="root",
        mysql_password="", env=env,
        source_roots=[SUITE_DIR / "mtr_include", SUITE_DIR],
        shell=shell(), tmp_dir=tmp,
        hooks={"mrsd_stop": mrsd.hook_stop,
               "mrsd_wait_stopped": mrsd.hook_wait_stopped,
               "mrsd_restart": mrsd.hook_restart,
               "mrsd_require_jit": require_jit},
        sql_rewrite=mariadb_sql.rewrite if paths.is_mariadb else None)

    interp = Interpreter(envn)
    try:
        interp.run_file(test_file)
    except ScriptSkipped as e:
        pytest.skip(str(e))
    except ScriptFailed as e:
        pytest.fail(printable(f"{e}\n\n--- output so far (last 60 lines) ---\n" +
                              "\n".join(interp.output().splitlines()[-60:]) +
                              f"\n\nrouter log: {mrsd.logfile}"))
    finally:
        interp.close()
        mrsd.stop()
        mysqld.reset()

    actual = interp.output()
    if request.config.getoption("--record") or request.config.getoption("--record-mariadb"):
        result_file.write_text(actual, encoding="utf-8",
                               errors="surrogateescape", newline="")
        return
    # binary data in responses: compare the bytes (surrogateescape round-trips)
    expected = (result_file.read_text(encoding="utf-8", errors="surrogateescape")
                if result_file.exists() else "")
    if paths.is_mariadb:
        expected, actual = mariadb_sql.normalize_output(expected), mariadb_sql.normalize_output(actual)
    if actual != expected:
        reject = tmp_path / f"{name}.reject"
        reject.write_text(actual, encoding="utf-8", errors="surrogateescape",
                          newline="")
        diff = "".join(difflib.unified_diff(
            expected.splitlines(True), actual.splitlines(True),
            fromfile=f"r/{name}.result", tofile=f"{name}.reject", n=2))
        lines = diff.splitlines()
        if len(lines) > 80:
            diff = "\n".join(lines[:80]) + f"\n... ({len(lines) - 80} more lines)"
        pytest.fail(printable(f"result mismatch, reject file: {reject}\n{diff}"))
