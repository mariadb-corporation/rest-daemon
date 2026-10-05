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

"""Interpreter for the subset of the mysqltest language used by the MRS tests.

The MRS functional tests come from mysql-server's mysql-test/suite/router
(mtr). They are kept as they are, .test scripts plus golden .result files;
this module runs a .test script and produces the output mysqltest would, so
it can be compared against the .result file.

Supported: let, echo, eval, source, exec, exec_in_background, if/while
blocks, error, replace_regex, disable/enable_query_log, disable/enable_result_log,
disable/enable_warnings, sleep, remove_file, write_file, cat_file, die, skip,
connect, connection, disconnect, delimiter, perl (a few scripts, see
PERL_HANDLERS) and SQL statements.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import pymysql
import pymysql.constants.CLIENT as CLIENT


class ScriptSkipped(Exception):
    pass


class ScriptFailed(Exception):
    pass


# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------

# mysqltest commands that may appear without the leading "--"
KNOWN_COMMANDS = {
    "let", "echo", "eval", "source", "exec", "exec_in_background", "if",
    "while", "end", "error", "replace_regex", "disable_query_log",
    "enable_query_log", "disable_result_log", "enable_result_log",
    "disable_warnings", "enable_warnings", "sleep", "remove_file",
    "write_file", "append_file", "cat_file", "die", "skip", "connect",
    "connection", "disconnect", "delimiter", "perl", "assert", "file_exists",
    "remove_files_wildcard", "mkdir", "rmdir", "force-rmdir", "inc", "dec",
    "real_sleep", "expr", "disable_abort_on_error", "enable_abort_on_error",
}


@dataclass
class Command:
    name: str                 # command name, or "sql"
    arg: str                  # argument text (raw, unexpanded)
    file: Path
    line: int
    body: list["Command"] = field(default_factory=list)  # if/while blocks
    heredoc: str | None = None                           # perl/write_file
    delimiter: str = ";"                                 # when it was parsed


class Parser:
    def __init__(self, text: str, file: Path):
        self.lines = text.split("\n")
        self.file = file
        self.pos = 0
        self.delimiter = ";"

    def parse(self) -> list[Command]:
        cmds, _ = self._parse_block(top=True)
        return cmds

    def _heredoc(self, terminator: str) -> str:
        body = []
        while self.pos < len(self.lines):
            line = self.lines[self.pos]
            self.pos += 1
            if line.strip() == terminator:
                return "\n".join(body) + ("\n" if body else "")
            body.append(line)
        raise ScriptFailed(f"{self.file}: unterminated block, expected {terminator}")

    def _parse_block(self, top: bool) -> tuple[list[Command], bool]:
        cmds: list[Command] = []
        stmt: list[str] = []
        stmt_line = 0
        while self.pos < len(self.lines):
            raw = self.lines[self.pos]
            lineno = self.pos + 1
            self.pos += 1
            line = raw.strip()

            if not stmt:
                if line == "" or line.startswith("#"):
                    continue
                if line.startswith("--"):
                    rest = line[2:].strip()
                    # echo keeps trailing white space, like mysqltest
                    raw_rest = raw.lstrip()[2:].lstrip()
                    if rest == "" or rest.startswith("-"):  # "-- comment"
                        continue
                    name, _, arg = rest.partition(" ")
                    if "(" in name:   # "--assert(...)" without a space
                        name, paren, tail = name.partition("(")
                        arg = paren + tail + ((" " + arg) if arg else "")
                    name = name.strip()
                    arg = arg.strip()
                    if name == "echo":
                        arg = raw_rest[len("echo"):].lstrip(" \t").rstrip("\r")
                    if name == "delimiter":
                        if arg.endswith(self.delimiter) and len(arg) > len(self.delimiter):
                            arg = arg[: -len(self.delimiter)]
                        self.delimiter = arg
                        continue
                    cmd = Command(name, arg, self.file, lineno)
                    if name in ("perl", "write_file", "append_file"):
                        term = "EOF"
                        if name == "perl" and arg:
                            term = arg.rstrip(";").strip() or "EOF"
                        elif name != "perl":
                            parts = arg.split()
                            if len(parts) > 1:
                                term = parts[1].rstrip(";")
                        cmd.heredoc = self._heredoc(term)
                    elif name in ("if", "while"):
                        cmd.body = self._block_after_condition()
                    cmds.append(cmd)
                    continue
                if line == "}":
                    if top:
                        raise ScriptFailed(f"{self.file}:{lineno}: unexpected '}}'")
                    return cmds, True
                stmt_line = lineno

            # a statement or command terminated by the delimiter, maybe
            # spanning lines. "if (...)" / "while (...)" are followed by a
            # block instead.
            # mysqltest drops the leading white space of every line of a
            # statement (it shows in the echoed query), except inside quotes
            # and right after a line that ends with a closing quote (verified
            # against mysqltest; a side effect of its read_line() states)
            prev = "\n".join(stmt)
            if stmt and (self._open_quote(prev) or
                         (prev.endswith(("'", '"', "`")) and
                          not self._open_quote(prev))):
                stmt.append(raw)
            else:
                stmt.append(raw.lstrip())
            joined = "\n".join(stmt).strip()
            first = re.split(r"[\s(]", joined, maxsplit=1)[0].lower()
            if first in ("if", "while"):
                cond = self._complete_condition(joined[len(first):])
                if cond is None:
                    continue  # condition continues on the next line
                cond_text, brace = cond
                cmd = Command(first, cond_text, self.file, stmt_line)
                cmd.body = self._block_after_condition(brace_seen=brace)
                cmds.append(cmd)
                stmt = []
                continue
            if first in ("perl",) and joined.endswith(";"):
                arg = joined[len("perl"):].rstrip(";").strip()
                cmd = Command("perl", arg, self.file, stmt_line)
                cmd.heredoc = self._heredoc(arg or "EOF")
                cmds.append(cmd)
                stmt = []
                continue
            if first == "delimiter":
                # "DELIMITER %%;" - the command is terminated by the current
                # delimiter, the rest is the new one
                arg = joined.split(None, 1)[1].strip()
                if arg.endswith(self.delimiter) and len(arg) > len(self.delimiter):
                    arg = arg[: -len(self.delimiter)]
                self.delimiter = arg
                stmt = []
                continue
            if self._ends_with_delimiter(joined):
                text = joined[: -len(self.delimiter)].strip()
                word = re.split(r"[\s(]", text, maxsplit=1)[0]
                if word.lower() in KNOWN_COMMANDS and word.lower() not in ("end",):
                    name, _, arg = text.partition(" ")
                    cmd = Command(name.lower(), arg.strip(), self.file, stmt_line)
                    if cmd.name in ("write_file", "append_file"):
                        parts = cmd.arg.split()
                        term = parts[1] if len(parts) > 1 else "EOF"
                        cmd.heredoc = self._heredoc(term)
                    cmds.append(cmd)
                else:
                    cmds.append(Command("sql", text, self.file, stmt_line,
                                        delimiter=self.delimiter))
                stmt = []
                continue
        if stmt:
            raise ScriptFailed(f"{self.file}: unterminated statement at line {stmt_line}")
        if not top:
            raise ScriptFailed(f"{self.file}: missing '}}'")
        return cmds, False

    @staticmethod
    def _open_quote(text: str):
        """the quote character still open at the end of text, or None"""
        quote = None
        i = 0
        while i < len(text):
            ch = text[i]
            if quote:
                if ch == "\\":
                    i += 2
                    continue
                if ch == quote:
                    quote = None
            elif ch in "'\"`":
                quote = ch
            i += 1
        return quote

    def _ends_with_delimiter(self, text: str) -> bool:
        """text ends with the delimiter, outside of quotes (like mysqltest's
        read_line(), which ignores the delimiter within '...', "..." and `...`)"""
        if not text.endswith(self.delimiter):
            return False
        quote = None
        i, end = 0, len(text) - len(self.delimiter)
        while i < end:
            ch = text[i]
            if quote:
                if ch == "\\":
                    i += 2
                    continue
                if ch == quote:
                    quote = None
            elif ch in "'\"`":
                quote = ch
            i += 1
        return quote is None

    @staticmethod
    def _complete_condition(rest: str):
        """'(cond) [{]' once the parentheses are balanced, else None.

        Parentheses inside `...` and quotes don't count."""
        i = 0
        while i < len(rest) and rest[i].isspace():
            i += 1
        if i >= len(rest) or rest[i] != "(":
            return None
        depth, quote, start = 0, None, i
        while i < len(rest):
            ch = rest[i]
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "`\"'":
                quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    tail = rest[i + 1:].strip()
                    if tail not in ("", "{"):
                        return None
                    return rest[start:i + 1], tail == "{"
            i += 1
        return None

    def _block_after_condition(self, brace_seen: bool = False) -> list[Command]:
        if not brace_seen:
            # the "{" is on one of the next lines
            while self.pos < len(self.lines):
                line = self.lines[self.pos].strip()
                self.pos += 1
                if line == "" or line.startswith("#"):
                    continue
                if line == "{":
                    break
                raise ScriptFailed(f"{self.file}:{self.pos}: expected '{{'")
        body, closed = self._parse_block(top=False)
        return body


# ---------------------------------------------------------------------------
# execution
# ---------------------------------------------------------------------------

@dataclass
class Connection:
    name: str
    conn: pymysql.connections.Connection


@dataclass
class Environment:
    """what the interpreter needs from the harness"""
    mysql_host: str
    mysql_port: int
    mysql_user: str
    mysql_password: str
    env: dict[str, str]              # exported to exec'd commands, readable as $VAR
    source_roots: list[Path]         # where "include/..." is looked up
    shell: list[str]                 # e.g. ["bash", "-c"]
    tmp_dir: Path
    # internal commands (--mrsd_stop, --mrsd_restart, ...) used by the
    # harness' versions of mtr's router restart includes
    hooks: dict[str, Callable[[str], None]] = field(default_factory=dict)


class Interpreter:
    def __init__(self, envn: Environment):
        self.envn = envn
        self.vars: dict[str, str] = {}
        self.out: list[str] = []
        self.query_log = True
        self.result_log = True
        self.abort_on_error = True
        self.warnings = True
        self.pending_replace: list[tuple[re.Pattern, str]] | None = None
        self.pending_error: list[str] | None = None
        self.connections: dict[str, Connection] = {}
        self.current: Connection | None = None
        self.background: list[subprocess.Popen] = []
        self.file_stack: list[Path] = []
        self.connect("default", envn.mysql_host, envn.mysql_user,
                     envn.mysql_password, "test", envn.mysql_port)

    # --- variables --------------------------------------------------------

    def get_var(self, name: str) -> str:
        if name in self.vars:
            return self.vars[name]
        if name in self.envn.env:
            return self.envn.env[name]
        return os.environ.get(name, "")

    def expand(self, text: str, pass_through_escapes: bool = False) -> str:
        """variable expansion like mysqltest's do_eval()"""
        out = []
        escaped = False
        i, n = 0, len(text)
        while i < n:
            c = text[i]
            nxt = text[i + 1] if i + 1 < n else ""
            if c == "$":
                if escaped or nxt in (".", "[", "'", '"'):
                    # an escaped \$ or a JSON path expression
                    escaped = False
                    out.append(c)
                    i += 1
                    continue
                m = re.match(r"[A-Za-z0-9_]+", text[i + 1:])
                if not m:
                    out.append(c)
                    i += 1
                    continue
                out.append(self.get_var(m.group(0)))
                i += 1 + len(m.group(0))
                continue
            if c == "\\":
                if escaped:
                    escaped = False
                    out.append(c)
                elif nxt in ("\\", "$", '"'):
                    escaped = True
                    if pass_through_escapes:
                        out.append(c)
                else:
                    out.append(c)
                i += 1
                continue
            escaped = False
            out.append(c)
            i += 1
        return "".join(out)

    # --- output -------------------------------------------------------------

    def replace(self, text: str) -> str:
        for rx, sub in self.pending_replace or []:
            text = rx.sub(sub, text)
        return text

    def emit(self, text: str, per_line: bool = False) -> None:
        """append output; replace_regex applies to the whole text, or (exec
        output, like mysqltest reading it with fgets) to every line"""
        if self.pending_replace:
            if per_line:
                text = "".join(self.replace(l) for l in text.splitlines(True))
            else:
                text = self.replace(text)
        self.out.append(text)

    def output(self) -> str:
        return "".join(self.out)

    # --- connections --------------------------------------------------------

    def connect(self, name, host, user, password, db, port, socket=None):
        kwargs = dict(host=host or self.envn.mysql_host, user=user or "root",
                      password=password or "", port=int(port or self.envn.mysql_port),
                      autocommit=True, client_flag=CLIENT.MULTI_STATEMENTS,
                      charset="utf8mb4")
        if db:
            kwargs["database"] = db
        try:
            conn = pymysql.connect(**kwargs)
        except pymysql.err.OperationalError:
            if db == "test":  # mtr creates "test"; don't depend on it
                kwargs.pop("database")
                conn = pymysql.connect(**kwargs)
                with conn.cursor() as c:
                    c.execute("CREATE DATABASE IF NOT EXISTS test")
                    c.execute("USE test")
            else:
                raise
        self.connections[name] = Connection(name, conn)
        self.current = self.connections[name]
        self.vars["CURRENT_CONNECTION"] = name

    # --- running ------------------------------------------------------------

    def run_file(self, path: Path) -> None:
        if not self.file_stack:
            # mysqltest exports the path of the test it runs
            self.envn.env["MYSQLTEST_FILE"] = str(path)
        cmds = Parser(path.read_text(errors="replace"), path).parse()
        self.file_stack.append(path)
        try:
            self.run_block(cmds)
        finally:
            self.file_stack.pop()

    def run_block(self, cmds: list[Command]) -> None:
        for cmd in cmds:
            self.run(cmd)

    def run(self, cmd: Command) -> None:
        handler = getattr(self, "cmd_" + cmd.name.replace("-", "_"), None)
        if cmd.name == "sql":
            return self.run_sql(cmd.arg, cmd)
        if cmd.name in self.envn.hooks:
            return self.envn.hooks[cmd.name](self.expand(cmd.arg))
        if handler is None:
            raise ScriptFailed(f"{cmd.file}:{cmd.line}: unsupported command '{cmd.name}'")
        handler(cmd)

    def fail(self, cmd: Command, msg: str) -> None:
        raise ScriptFailed(f"{cmd.file.name}:{cmd.line}: {msg}")

    # --- conditions ---------------------------------------------------------

    # semantics follow client/mysqltest.cc: do_block(), var_check_int()

    @staticmethod
    def as_int(v: str):
        """int value if mysqltest considers v an int (strtol up to end/space/tab)"""
        m = re.match(r"^\s*([-+]?\d+)(?=$|[ \t])", v)
        return int(m.group(1)) if m else None

    def eval_condition(self, cond: str) -> bool:
        c = cond.strip()
        assert c.startswith("(") and c.endswith(")"), cond
        c = c[1:-1].strip()
        neg = False
        if c.startswith("!"):
            neg = True
            c = c[1:].strip()
        if c.startswith("$"):
            m = re.match(r"^(\$[A-Za-z_][A-Za-z0-9_]*)\s*(==|!=|<=|>=|<|>)\s*(.*)$", c, re.S)
            if m:
                left = self.expand(m.group(1))
                right = m.group(3).strip()
                if len(right) >= 2 and right[0] in "'\"" and right[-1] == right[0]:
                    right = right[1:-1]
                right = self.expand(right)
                op = m.group(2)
                li, ri = self.as_int(left), self.as_int(right)
                if op == "==":
                    res = (ri is not None and li == ri) if li is not None else left == right
                elif op == "!=":
                    res = (ri is None or li != ri) if li is not None else left != right
                else:
                    li, ri = li or 0, ri or 0
                    res = {"<": li < ri, ">": li > ri, "<=": li <= ri, ">=": li >= ri}[op]
                return (not res) if neg else res
            v = self.expand(c)
        elif c.startswith("`"):
            v = self.query_value(self.expand(c[1:-1]))
        else:
            v = self.expand(c)
        res = self.truthy(v)
        return (not res) if neg else res

    def value_of(self, expr: str) -> str:
        if expr.startswith("`") and expr.endswith("`"):
            return self.query_value(self.expand(expr[1:-1]))
        return self.expand(expr)

    @classmethod
    def truthy(cls, v: str) -> bool:
        i = cls.as_int(v)
        if i is not None:
            return i != 0
        p = v.lstrip(" \t\n+-")
        return p != "" and p[0] != "0"

    def cmd_if(self, cmd: Command) -> None:
        if self.eval_condition(cmd.arg):
            self.run_block(cmd.body)

    def cmd_while(self, cmd: Command) -> None:
        guard = 0
        while self.eval_condition(cmd.arg):
            self.run_block(cmd.body)
            guard += 1
            if guard > 100000:
                self.fail(cmd, "while loop did not terminate")

    # --- simple commands ----------------------------------------------------

    def cmd_echo(self, cmd: Command) -> None:
        self.emit(self.expand(cmd.arg) + "\n")
        self.pending_replace = None

    def cmd_let(self, cmd: Command) -> None:
        m = re.match(r"^\s*(\$?\$?)([A-Za-z_][A-Za-z0-9_]*)\s*=\s?(.*)$", cmd.arg, re.S)
        if not m:
            self.fail(cmd, f"bad let: {cmd.arg}")
        is_var, name, value = m.group(1), m.group(2), m.group(3)
        if is_var == "$$":
            # mysqltest's var_set() strips one '$' and stores a variable
            # literally named "$name", which is never read back: a no-op.
            # (The suite has a few "--let $$x=" typos meant to clear $x.)
            return
        value = value.strip()   # mysqltest skips the white space after '='
        qgv = re.match(r"^query_get_value\((.*),\s*([^,]+?)\s*,\s*(\d+)\s*\)$", value, re.S)
        if qgv:
            value = self.query_get_value(self.expand(qgv.group(1)),
                                         qgv.group(2).strip(), int(qgv.group(3)))
        elif value.startswith("`") and value.endswith("`") and len(value) > 1:
            value = self.query_value(self.expand(value[1:-1]))
        else:
            value = self.expand(value)
        if is_var:
            self.vars[name] = value
        else:
            self.envn.env[name] = value   # "let VAR=..." sets an environment var
            self.vars[name] = value

    def cmd_expr(self, cmd: Command) -> None:
        m = re.match(r"^\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\S+)\s*([-+*/%])\s*(\S+)\s*$",
                     self.expand_rhs_only(cmd.arg))
        if not m:
            self.fail(cmd, f"unsupported expr: {cmd.arg}")
        a, op, b = float(m.group(2)), m.group(3), float(m.group(4))
        v = {"+": a + b, "-": a - b, "*": a * b, "/": a / b, "%": a % b}[op]
        self.vars[m.group(1)] = str(int(v)) if v == int(v) else str(v)

    def expand_rhs_only(self, arg: str) -> str:
        name, eq, rhs = arg.partition("=")
        return name + eq + self.expand(rhs)

    def cmd_eval(self, cmd: Command) -> None:
        self.run_sql(self.expand(cmd.arg), cmd)

    def cmd_source(self, cmd: Command) -> None:
        # the file name ends at the first white space (a comment may follow)
        name = self.expand(cmd.arg).rstrip(";").strip().split()[0]
        self.run_file(self.resolve(name, cmd))

    def resolve(self, name: str, cmd: Command) -> Path:
        cur_dir = self.file_stack[-1].parent if self.file_stack else Path.cwd()
        candidates = [cur_dir / name]
        for root in self.envn.source_roots:
            candidates.append(root / name)
            if name.startswith("include/"):
                candidates.append(root / name[len("include/"):])
        for c in candidates:
            if c.is_file():
                return c
        self.fail(cmd, f"can't find sourced file '{name}'")

    def cmd_error(self, cmd: Command) -> None:
        self.pending_error = [e.strip() for e in self.expand(cmd.arg).split(",")]

    def cmd_replace_regex(self, cmd: Command) -> None:
        # like do_get_replace_regex(): a variable may hold the *entire* list;
        # no expansion inside the patterns ('$USER' stays literal)
        arg = cmd.arg.strip()
        if arg.startswith("$"):
            m = re.match(r"^\$([A-Za-z0-9_]+)", arg)
            arg = self.get_var(m.group(1)) if m else arg
        pats = []
        # /from/to/[flags] ...; any delimiter char after a space
        i = 0
        while i < len(arg):
            if arg[i].isspace():
                i += 1
                continue
            d = arg[i]
            parts = []
            j = i + 1
            cur = ""
            while j < len(arg) and len(parts) < 2:
                if arg[j] == "\\" and j + 1 < len(arg) and arg[j + 1] == d:
                    cur += d
                    j += 2
                    continue
                if arg[j] == d:
                    parts.append(cur)
                    cur = ""
                    j += 1
                    continue
                cur += arg[j]
                j += 1
            flags = 0
            while j < len(arg) and not arg[j].isspace():
                if arg[j] == "i":
                    flags |= re.I
                j += 1
            if len(parts) == 2:
                # mysqltest uses \N back-references like Python
                pats.append((re.compile(parts[0], flags), parts[1]))
            i = j
        self.pending_replace = pats

    def cmd_disable_abort_on_error(self, cmd): self.abort_on_error = False
    def cmd_enable_abort_on_error(self, cmd): self.abort_on_error = True
    def cmd_disable_query_log(self, cmd): self.query_log = False
    def cmd_enable_query_log(self, cmd): self.query_log = True
    def cmd_disable_result_log(self, cmd): self.result_log = False
    def cmd_enable_result_log(self, cmd): self.result_log = True
    def cmd_disable_warnings(self, cmd): self.warnings = False
    def cmd_enable_warnings(self, cmd): self.warnings = True

    def _var_name(self, cmd: Command) -> str:
        m = re.match(r"^\s*\$([A-Za-z_][A-Za-z0-9_]*)", cmd.arg)
        if not m:
            self.fail(cmd, f"expected a variable: {cmd.arg}")
        return m.group(1)

    def cmd_inc(self, cmd: Command) -> None:
        n = self._var_name(cmd)
        self.vars[n] = str(int(self.vars.get(n, "0") or 0) + 1)

    def cmd_dec(self, cmd: Command) -> None:
        n = self._var_name(cmd)
        self.vars[n] = str(int(self.vars.get(n, "0") or 0) - 1)

    def cmd_sleep(self, cmd: Command) -> None:
        time.sleep(float(self.expand(cmd.arg).rstrip(";") or 0))

    cmd_real_sleep = cmd_sleep

    def cmd_die(self, cmd: Command) -> None:
        self.fail(cmd, "die: " + self.expand(cmd.arg))

    def cmd_skip(self, cmd: Command) -> None:
        raise ScriptSkipped(self.expand(cmd.arg))

    def cmd_remove_file(self, cmd: Command) -> None:
        p = Path(self.expand(cmd.arg).rstrip(";").strip())
        if not p.exists() and self.pending_error is None:
            self.fail(cmd, f"remove_file: {p} doesn't exist")
        self.pending_error = None
        p.unlink(missing_ok=True)

    def cmd_remove_files_wildcard(self, cmd: Command) -> None:
        d, _, pattern = self.expand(cmd.arg).rstrip(";").strip().partition(" ")
        for p in Path(d).glob(pattern or "*"):
            if p.is_file():
                p.unlink()

    def cmd_file_exists(self, cmd: Command) -> None:
        p = Path(self.expand(cmd.arg).rstrip(";").strip())
        exists = p.exists()
        expected_fail = self.pending_error is not None
        self.pending_error = None
        if exists == expected_fail:
            self.fail(cmd, f"file_exists {p}: {exists}")

    def cmd_mkdir(self, cmd: Command) -> None:
        Path(self.expand(cmd.arg).rstrip(";").strip()).mkdir(parents=True, exist_ok=True)

    def cmd_rmdir(self, cmd: Command) -> None:
        import shutil
        shutil.rmtree(self.expand(cmd.arg).rstrip(";").strip(), ignore_errors=True)

    cmd_force_rmdir = cmd_rmdir

    def cmd_write_file(self, cmd: Command, mode: str = "w") -> None:
        name = self.expand(cmd.arg.split()[0]).rstrip(";")
        p = Path(name)
        if mode == "w" and p.exists() and self.pending_error is None:
            self.fail(cmd, f"write_file: {p} already exists")
        self.pending_error = None
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, mode) as f:
            f.write(self.expand(cmd.heredoc or ""))

    def cmd_append_file(self, cmd: Command) -> None:
        self.cmd_write_file(cmd, "a")

    def cmd_cat_file(self, cmd: Command) -> None:
        p = Path(self.expand(cmd.arg).rstrip(";").strip())
        self.emit(p.read_text(errors="surrogateescape"))
        self.pending_replace = None

    def cmd_assert(self, cmd: Command) -> None:
        if not self.eval_condition(cmd.arg if cmd.arg.startswith("(") else f"({cmd.arg})"):
            self.fail(cmd, f"assert failed: {cmd.arg}")

    # --- connections ----------------------------------------------------------

    def cmd_connect(self, cmd: Command) -> None:
        arg = self.expand(cmd.arg).strip().rstrip(";")
        if arg.startswith("(") and arg.endswith(")"):
            arg = arg[1:-1]
        parts = [p.strip() for p in arg.split(",")]
        parts += [""] * (7 - len(parts))
        name, host, user, pw, db, port, sock = parts[:7]
        expected = self.pending_error
        self.pending_error = None
        try:
            self.connect(name, host, user, pw, db, port, sock)
        except pymysql.err.MySQLError as e:
            if not expected:
                self.fail(cmd, f"connect failed: {e}")

    def cmd_connection(self, cmd: Command) -> None:
        name = self.expand(cmd.arg).strip().rstrip(";")
        if name not in self.connections:
            self.fail(cmd, f"unknown connection {name}")
        self.current = self.connections[name]
        self.vars["CURRENT_CONNECTION"] = name

    def cmd_disconnect(self, cmd: Command) -> None:
        name = self.expand(cmd.arg).strip().rstrip(";")
        c = self.connections.pop(name, None)
        if c:
            c.conn.close()

    # --- SQL ------------------------------------------------------------------

    def query_value(self, sql: str) -> str:
        """value of `...` in let/if: the first row's non-NULL columns joined by
        tabs; "" if there is no row or its first column is NULL"""
        with self.current.conn.cursor() as cur:
            cur.execute(sql)
            row = cur.fetchone()
            while cur.nextset():
                pass
        if row is None or row[0] is None:
            return ""
        return "\t".join(self.format_value(v) if v is not None else "" for v in row)

    def query_get_value(self, sql: str, column: str, row: int) -> str:
        """mysqltest's query_get_value(query, column, row): row is 1-based;
        "No such row" when there are fewer rows"""
        with self.current.conn.cursor() as cur:
            cur.execute(sql)
            names = [d[0] for d in cur.description or []]
            rows = cur.fetchall()
            while cur.nextset():
                pass
        if column not in names:
            raise ScriptFailed(f"query_get_value: no column '{column}' in {names}")
        if row > len(rows):
            return "No such row"
        return self.format_value(rows[row - 1][names.index(column)])

    @staticmethod
    def format_value(v) -> str:
        if v is None:
            return "NULL"
        if isinstance(v, (bytes, bytearray)):
            return v.decode("utf-8", errors="surrogateescape")
        return str(v)

    def run_sql(self, sql: str, cmd: Command) -> None:
        expected = self.pending_error
        self.pending_error = None
        if self.query_log:
            # a pending replace_regex applies to the echoed statement too
            self.out.append(self.replace(sql) + cmd.delimiter + "\n")
        buf: list[str] = []
        try:
            with self.current.conn.cursor() as cur:
                cur.execute(sql)
                while True:
                    if cur.description is not None:
                        rows = cur.fetchall()
                        if True:
                            buf.append("\t".join(d[0] for d in cur.description) + "\n")
                            for r in rows:
                                # replace_regex applies to each value
                                buf.append("\t".join(self.replace(self.format_value(v))
                                                      for v in r) + "\n")
                    if not cur.nextset():
                        break
                warnings = []
                # PyMySQL keeps the warning count of the last result
                result = getattr(cur, "_result", None)
                if self.warnings and result is not None and result.warning_count:
                    cur.execute("SHOW WARNINGS")
                    warnings = cur.fetchall()
        except pymysql.err.MySQLError as e:
            code = e.args[0] if e.args else 0
            msg = e.args[1] if len(e.args) > 1 else str(e)
            if expected and self.error_matches(code, expected):
                sqlstate = self.sqlstate_of(e)
                if self.result_log:
                    self.emit(f"ERROR {sqlstate}: {msg}\n")
                self.pending_replace = None
                return
            self.fail(cmd, f"query failed: {sql[:200]}: {code} {msg}")
        if expected and expected != ["0"]:
            self.fail(cmd, f"query succeeded but error {expected} was expected: {sql[:200]}")
        if self.result_log:
            self.out.append("".join(buf))
            if warnings:
                self.emit("Warnings:\n")
                for w in warnings:
                    self.emit("\t".join(self.format_value(v) for v in w) + "\n")
        self.pending_replace = None

    @staticmethod
    def error_matches(code: int, expected: list[str]) -> bool:
        for e in expected:
            if e.isdigit() and int(e) == code:
                return True
            if not e.isdigit() and e:   # symbolic names: accept any error
                return True
        return False

    @staticmethod
    def sqlstate_of(e) -> str:
        return getattr(e, "sqlstate", None) or "HY000"

    # --- exec -----------------------------------------------------------------

    def cmd_exec(self, cmd: Command) -> None:
        # like do_exec(): escapes pass through to the shell (not on Windows)
        # and newlines become spaces
        command = self.expand(cmd.arg, pass_through_escapes=sys.platform != "win32")
        command = command.replace("\n", " ")
        expected = self.pending_error
        self.pending_error = None
        env = dict(os.environ)
        env.update(self.envn.env)
        env.update({k: v for k, v in self.vars.items() if k.isupper()})
        env = {k: v for k, v in env.items() if "\0" not in v and "\0" not in k}
        p = subprocess.run(self.envn.shell + [command], capture_output=True,
                           env=env, cwd=self.envn.tmp_dir)
        out = p.stdout.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n")
        if p.returncode != 0:
            if not expected or not (str(p.returncode) in expected or
                                    any(not e.isdigit() for e in expected) or
                                    "1" in expected):
                self.fail(cmd, f"exec failed ({p.returncode}): {command}\n"
                               f"stdout: {out[-2000:]}\nstderr: "
                               f"{p.stderr.decode(errors='replace')[-2000:]}")
        elif expected and "0" not in expected:
            self.fail(cmd, f"exec succeeded but error {expected} expected: {command}")
        if self.result_log:
            self.emit(out, per_line=True)
        self.pending_replace = None

    def cmd_exec_in_background(self, cmd: Command) -> None:
        env = dict(os.environ)
        env.update(self.envn.env)
        command = self.expand(cmd.arg, pass_through_escapes=sys.platform != "win32")
        self.background.append(subprocess.Popen(
            self.envn.shell + [command.replace("\n", " ")], env=env,
            cwd=self.envn.tmp_dir, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL))

    # --- perl -----------------------------------------------------------------

    def cmd_perl(self, cmd: Command) -> None:
        env = dict(os.environ)
        env.update(self.envn.env)
        env.update(self.vars)
        env = {k: v for k, v in env.items() if "\0" not in v and "\0" not in k}
        p = subprocess.run(["perl"], input=(cmd.heredoc or "").encode(),
                           capture_output=True, env=env, cwd=self.envn.tmp_dir)
        if p.returncode != 0:
            self.fail(cmd, "perl failed: " + p.stderr.decode(errors="replace")[-2000:])
        if self.result_log:
            self.emit(p.stdout.decode(errors="surrogateescape"))
        self.pending_replace = None

    # --- cleanup ----------------------------------------------------------------

    def close(self) -> None:
        for p in self.background:
            if p.poll() is None:
                p.terminate()
        for c in self.connections.values():
            try:
                c.conn.close()
            except Exception:
                pass
