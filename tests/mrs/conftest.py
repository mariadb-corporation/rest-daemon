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

"""pytest harness for the MRS functional tests (tests/mrs/t/*.test).

Starts one mysqld from a MySQL server package per session and one mrsd per
test, provides the environment mtr provided (MRS_CLIENT, HTTP_SERVER_PORT,
MYSQLROUTER_LOGFILE, ...) and runs the .test scripts with the mysqltest
interpreter in mrstest/mysqltest.py.

Options (or environment variables):
  --mrsd-build       MRSD_BUILD         mrsd build directory (built with
                                        -DWITH_UNIT_TESTS=ON for mrs_client)
  --mysql-package    MYSQL_PACKAGE_DIR  extracted MySQL server package
  --record                              write the output as the new .result
"""

from __future__ import annotations

import configparser
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import pymysql
import pytest

SUITE_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SUITE_DIR.parent.parent
IS_WINDOWS = sys.platform == "win32"
EXE = ".exe" if IS_WINDOWS else ""


def pytest_addoption(parser):
    parser.addoption("--mrsd-build", default=os.environ.get("MRSD_BUILD"))
    parser.addoption("--mysql-package", default=os.environ.get("MYSQL_PACKAGE_DIR"))
    parser.addoption("--record", action="store_true",
                     help="write the test output as the new .result file")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port: int, timeout: float, proc: subprocess.Popen | None = None) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if proc is not None and proc.poll() is not None:
            return False
        with socket.socket() as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.1)
    return False


class Paths:
    def __init__(self, config):
        build = config.getoption("--mrsd-build")
        pkg = config.getoption("--mysql-package")
        if not build or not pkg:
            pytest.exit("need --mrsd-build and --mysql-package "
                        "(or MRSD_BUILD / MYSQL_PACKAGE_DIR)", returncode=4)
        self.build = Path(build).resolve()
        self.package = Path(pkg).resolve()
        self.bin = self.build / "runtime_output_directory"
        self.plugins = self.build / "plugin_output_directory"
        self.mrsd = self.bin / f"mysqlrouter{EXE}"
        self.keyring = self.bin / f"mysqlrouter_keyring{EXE}"
        self.mrs_client = self.bin / f"mysqlrouter_mrs_client{EXE}"
        self.mysqld = self.package / "bin" / f"mysqld{EXE}"
        for p in (self.mrsd, self.keyring, self.mrs_client, self.mysqld):
            if not p.exists():
                pytest.exit(f"missing {p}", returncode=4)

    @property
    def has_jit(self) -> bool:
        return any(self.plugins.glob("jit_executor.*"))


@pytest.fixture(scope="session")
def paths(pytestconfig) -> Paths:
    return Paths(pytestconfig)


# ---------------------------------------------------------------------------
# mysqld (one per session)
# ---------------------------------------------------------------------------

class Mysqld:
    def __init__(self, paths: Paths, base: Path):
        self.paths = paths
        self.base = base
        self.datadir = base / "data"
        self.socket = self.datadir / "m.sock"
        self.port = free_port()
        self.proc: subprocess.Popen | None = None
        self.extra: list[str] = []

    def ensure_options(self, extra: list[str]) -> None:
        """(re)start with a test's extra options (t/<name>.cnf, like mtr)"""
        if extra != self.extra:
            self.stop()
            self.start(extra)

    def start(self, extra: list[str] | None = None) -> None:
        if not self.datadir.exists():
            subprocess.run([str(self.paths.mysqld), "--no-defaults",
                            "--initialize-insecure", f"--datadir={self.datadir}",
                            f"--basedir={self.paths.package}"],
                           check=True, capture_output=True)
        args = [str(self.paths.mysqld),
                f"--defaults-file={SUITE_DIR / 'mysqld.cnf'}",
                f"--datadir={self.datadir}", f"--basedir={self.paths.package}",
                f"--port={self.port}", "--bind-address=127.0.0.1",
                # relative: the absolute path may exceed the socket path limit
                "--socket=m.sock", "--mysqlx=OFF",
                f"--log-error={self.base / 'mysqld.err'}",
                "--gtid-mode=ON", "--enforce-gtid-consistency=ON",
                "--secure-file-priv="] + (extra or [])
        self.extra = list(extra or [])
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        end = time.monotonic() + 120
        while time.monotonic() < end:
            try:
                c = pymysql.connect(host="127.0.0.1", port=self.port, user="root")
                with c.cursor() as cur:
                    cur.execute("CREATE DATABASE IF NOT EXISTS test")
                c.close()
                if not hasattr(self, "baseline"):
                    self.baseline = self.global_variables()
                return
            except pymysql.err.OperationalError:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"mysqld exited, see {self.base / 'mysqld.err'}")
                time.sleep(0.3)
        raise RuntimeError("mysqld didn't start")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(60)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    # globals that change on their own; everything else must be as at startup
    VOLATILE_GLOBALS = {"gtid_executed", "gtid_purged", "gtid_owned",
                        "innodb_buffer_pool_size", "server_uuid"}

    def global_variables(self) -> dict[str, str]:
        c = pymysql.connect(host="127.0.0.1", port=self.port, user="root")
        with c.cursor() as cur:
            cur.execute("SHOW GLOBAL VARIABLES")
            result = {k: v for k, v in cur.fetchall() if k not in self.VOLATILE_GLOBALS}
        c.close()
        return result

    SYSTEM_SCHEMAS = {"mysql", "sys", "information_schema", "performance_schema"}
    SYSTEM_ACCOUNTS = {("root", "localhost"), ("mysql.session", "localhost"),
                       ("mysql.sys", "localhost"), ("mysql.infoschema", "localhost")}

    def reset(self) -> None:
        """undo what a test (especially a failed one) left behind.

        Like mtr's check-testcase: if global variables differ from startup
        (e.g. a test turned gtid_mode OFF), restart the server."""
        if self.global_variables() != self.baseline:
            changed = {k for k, v in self.global_variables().items()
                       if self.baseline.get(k) != v}
            print(f"mysqld globals changed ({', '.join(sorted(changed))}), restarting")
            self.stop()
            self.start(self.extra)
        c = pymysql.connect(host="127.0.0.1", port=self.port, user="root",
                            autocommit=True)
        with c.cursor() as cur:
            cur.execute("SELECT schema_name FROM information_schema.schemata")
            for (name,) in cur.fetchall():
                if name.lower() not in self.SYSTEM_SCHEMAS:
                    cur.execute(f"DROP DATABASE IF EXISTS `{name}`")
            cur.execute("CREATE DATABASE test")
            cur.execute("SELECT user, host FROM mysql.user")
            for user, host in cur.fetchall():
                if (user, host) not in self.SYSTEM_ACCOUNTS:
                    cur.execute("DROP USER IF EXISTS %s@%s", (user, host))
            cur.execute("RESET BINARY LOGS AND GTIDS")
        c.close()


@pytest.fixture(scope="session")
def mysqld(paths, tmp_path_factory):
    if sys.platform == "darwin":
        # the socket path must fit into 104 bytes; pytest's tmp dir is long
        import tempfile
        base = Path(tempfile.mkdtemp(prefix="mrsd-", dir="/tmp"))
    else:
        base = tmp_path_factory.mktemp("mysqld")
    m = Mysqld(paths, base)
    m.start()
    yield m
    m.stop()
    if sys.platform == "darwin":
        shutil.rmtree(base, ignore_errors=True)


def server_options_for(cnf: Path) -> list[str]:
    """mysqld options from a test's t/<name>.cnf ([mysqld.1] and [mysqld])"""
    if not cnf.exists():
        return []
    opts = []
    section = None
    for line in cnf.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith(("#", "!")):
            continue
        if line.startswith("["):
            section = line.strip("[]")
            continue
        if section in ("mysqld", "mysqld.1"):
            opts.append("--" + line.replace(" ", ""))
    return opts


# ---------------------------------------------------------------------------
# mrsd (one per test)
# ---------------------------------------------------------------------------

class Mrsd:
    """mrsd configured like mtr configures the router for the MRS suite"""

    def __init__(self, paths: Paths, mysqld: Mysqld, base: Path, test_cnf: Path | None):
        self.paths = paths
        self.mysqld = mysqld
        self.base = base
        for d in ("log", "run", "data", "tmp"):
            (base / d).mkdir(parents=True, exist_ok=True)
        self.http_port = free_port()
        self.logfile = base / "log" / "mysqlrouter.log"
        self.pidfile = base / "run" / "mysqlrouter.pid"
        self.conf = base / "mysqlrouter.conf"
        self.expect_file = base / "tmp" / "mysqlrouter.expect"
        self.proc: subprocess.Popen | None = None
        self._init_keyring()
        self._write_config(test_cnf)

    def _init_keyring(self) -> None:
        kr = str(self.base / "data" / "keyring")
        mk = f"--master-key-file={self.base / 'mysqlrouter.key'}"
        run = lambda *a: subprocess.run([str(self.paths.keyring), *a],
                                        check=True, capture_output=True)
        run("init", kr, mk)
        # the same entries mtr creates (mysql-test-run.pl, router_create_keyring)
        for user, attr, value in (("mysqlrouter", "password", "mysqlrouter"),
                                  ("root", "password", ""),
                                  ("mrs_user", "password", ""),
                                  ("rest-user", "jwt_secret", "secret12345"),
                                  ("account_with_auth_socket", "password", ""),
                                  ("account1", "password", "pwd1"),
                                  ("account2", "password", "pwd2")):
            run("set", kr, user, attr, value, mk)

    def _write_config(self, test_cnf: Path | None) -> None:
        cfg = configparser.ConfigParser(interpolation=None, strict=False,
                                        default_section="__none__")
        cfg.optionxform = str
        ssl = PROJECT_DIR / "tests" / "data" / "ssl"
        cfg["DEFAULT"] = {
            "logging_folder": str(self.base / "log"),
            "plugin_folder": str(self.paths.plugins),
            "runtime_folder": str(self.base / "run"),
            "data_folder": str(self.base / "data"),
            "keyring_path": str(self.base / "data" / "keyring"),
            "master_key_path": str(self.base / "mysqlrouter.key"),
            "pid_file": str(self.pidfile),
        }
        cfg["logger"] = {"level": "DEBUG"}
        cfg["http_server"] = {
            "port": str(self.http_port),
            "ssl": "1",
            "ssl_cert": str(ssl / "server-cert.pem"),
            "ssl_key": str(ssl / "server-key.pem"),
        }
        cfg["mysql_rest_service"] = {
            "mysql_user": "root",
            "mysql_user_data_access": "root",
            "router_id": "1",
            "mysql_read_write_destinations": f"127.0.0.1:{self.mysqld.port}",
            "metadata_refresh_interval": "1",
            # from mtr's include/default_my-router.cnf
            "wait_for_metadata_schema_access": "320",
        }
        if test_cnf is not None:
            extra = configparser.ConfigParser(interpolation=None, strict=False,
                                              default_section="__none__")
            extra.optionxform = str
            extra.read(test_cnf)
            extra.remove_option("mysql_rest_service", "mysql_read_write_route") \
                if extra.has_section("mysql_rest_service") else None
            extra.remove_option("mysql_rest_service", "mysql_read_only_route") \
                if extra.has_section("mysql_rest_service") else None
            for section in extra.sections():
                if section.startswith("routing"):
                    # mrsd: no routing plugin; a route to the server's socket
                    # becomes a local: destination
                    if extra[section].get("use_socket_as_destination") == "1":
                        cfg["mysql_rest_service"]["mysql_read_write_destinations"] = \
                            f"local:{self.mysqld.socket}"
                    continue
                if section not in cfg or section == "logger":
                    # mtr uses the test's file instead of the default router
                    # config: its [logger] replaces ours (e.g. no level=DEBUG)
                    cfg[section] = {}
                for k, v in extra[section].items():
                    cfg[section][k] = v
        # like mtr: tests read HTTP_SERVER_SSL to pick http:// or https://
        ssl_value = cfg["http_server"].get("ssl", "0").strip()
        self.http_ssl = "1" if ssl_value in ("1", "true", "yes", "on") else "0"
        with open(self.conf, "w", encoding="utf-8") as f:
            cfg.write(f)

    def start(self, extra_args: list[str] | None = None) -> None:
        env = dict(os.environ)
        env["_MRS_CONTROL_START"] = "1"   # tests start MRS via /debug?do=start
        self.proc = subprocess.Popen(
            [str(self.paths.mrsd), "-c", str(self.conf)] + (extra_args or []),
            stdout=open(self.base / "log" / "mrsd.stdout", "ab"),
            stderr=subprocess.STDOUT, env=env)
        if not wait_port(self.http_port, 60, self.proc):
            raise RuntimeError(f"mrsd didn't start, see {self.logfile}")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            if IS_WINDOWS:
                self.proc.terminate()
            else:
                self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(60)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            if IS_WINDOWS:
                # TerminateProcess() gives mrsd no chance to remove it, and
                # the next start would refuse to run
                self.pidfile.unlink(missing_ok=True)

    # hooks for the harness' versions of mtr's restart includes
    def hook_stop(self, _arg: str) -> None:
        self.stop()

    def hook_wait_stopped(self, _arg: str) -> None:
        if self.proc:
            self.proc.wait(60)

    def hook_restart(self, _arg: str) -> None:
        req = self.expect_file.read_text(encoding="utf-8").strip() if self.expect_file.exists() else ""
        if not req.startswith("restart"):
            raise RuntimeError(f"expected 'restart' in {self.expect_file}, got {req!r}")
        extra = req.split(":", 1)[1].split() if ":" in req else []
        self.start(extra)
