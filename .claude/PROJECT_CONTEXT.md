# Project Context

## Project

`mariadb-restd` (MariaDB REST Service Daemon) is the REST service daemon for MariaDB, forked from MySQL Router's MySQL REST Service (MRS) plugin (`mysql-server/router`, trunk `06a5c1c99c3`, no history, no upstream sync). It serves REST endpoints for tables, views, procedures, functions and JS/TS scripts defined in the REST metadata schema. Milestone 1 (standalone daemon on MySQL 9.x / 26.7) is done; **Milestone 2 (MariaDB) is done (2026-10-13); the project is MariaDB-only; Milestone 3 (schema 5.0.0) is current** (MySQL build and server support dropped; restore point: tag `m2-pre-build-decision`, bundle in `<dev>/rest-daemon-backups/`). Plan of record: `docs/PLAN.md`; build/test how-to and the session history: `docs/PROGRESS.md`; user-visible MariaDB differences: `docs/mariadb-differences.md`.

## Milestones

| # | What | State |
|---|---|---|
| 1 | Standalone daemon on MySQL (Linux, macOS, Windows) | done 2026-10-07 |
| 2 | MariaDB: Connector/C, MariaDB server, metadata schema **4.1.6** | done 2026-10-13 |
| 3 | Metadata schema **5.0.0** (`mariadb_rest_service`, prefix/postfix, renamed tables, `mariadb_rest_service_*` roles), now on the `main` branches of the shell and plugins. Spec: the shell repo's `.claude/context/rest-daemon-5.0.md` (read with `git show main:...`) | current |
| 4 | GTID read-your-writes (`asof`, `_metadata.gtid`) on MariaDB GTIDs, together with the shell and plugins; the MySQL implementation is parked in the tree, `asof` is refused with a clear 400 | after 3 |
| 5 | Packaging (real deb/rpm installs, MSI) and GitHub Actions CI | last |

## Architecture / key decisions

- One client: MariaDB Connector/C 3.4+ (`-DMARIADB_CONNECTOR_DIR`); what it lacks is in `compat/include/mrsd/compat_client.h`. One server: MariaDB 10.11+, checked at startup (`server_compatibility.cc`, `MySQLSession::is_mariadb()` from the handshake); the SQL generators emit MariaDB SQL only (no runtime flavor switch any more).
- The functional suite still runs upstream's `.test` scripts through a run-time SQL rewrite + output normalisation (`tests/mrs/mrstest/mariadb_sql.py`); 12 results are recorded on MariaDB, the rest compare against upstream's. Re-record everything in Milestone 3 (the schema rename touches every test anyway).
- Minimum MariaDB server 10.11 (oldest LTS); developed on 13.2 (macOS), Windows tested on 11.8.9 LTS. Schema 4.1.6 itself needs 11.1 (`JSON_SCHEMA_VALID`): plugin-side issue.
- **Removed from the product:** REST async tasks (`mysql_tasks`), a MariaDB REST Service decision (routines are always called directly); code gone 2026-10-13.
- **GTID read-your-writes** (`readOwnWrites`, `_metadata.gtid`, `$asof`): Milestone 4, shared with the shell and plugins. Parked, not deleted; `$asof` → 400.
- `--setup` accounts on MariaDB: default auth plugin (`IDENTIFIED BY`), one best-effort default role.
- Behaviour changes relative to upstream are marked `restd:` in comments.

## Current state

- **M2.1 (build on Connector/C): done** on macOS (3.4.11 Homebrew), Ubuntu (3.4.9, `libmariadb-dev` unpacked), Windows (3.4.8 vcpkg): ctest 113/113 each; MySQL build 113/113.
- **M2.2 (run against MariaDB): done.** Smoke test incl. MRS scripts passes on macOS (13.2 build tree), Windows and Ubuntu (11.8.9 LTS ARM64 sandbox packages); ad-hoc CRUD with JSON/GEOMETRY/VECTOR on macOS.
- **M2.3 (suites on MariaDB):** MRS suite MariaDB mode on macOS: 97 passed, 0 failed, 14 skipped, 10 xfailed, 1 xpassed; MySQL mode unchanged (116/5/1). **Windows vs 11.8.9 LTS: 97 passed, 0 failed, 14 skipped, 10 xfailed, 1 xpassed**, the same as macOS vs 13.2. **Ubuntu vs 11.8.9 LTS: 98 passed, 0 failed, 13 skipped** (+ `destination_socket`, which macOS and Windows skip), 10 xfailed, 1 xpassed (2026-10-12). Live-DB unit tests on MariaDB not done.
- macOS after the normaliser fix (2026-10-12): 99 passed, 0 failed, 14 skipped, 8 xfailed, 1 xpassed. `json_view` and `json_view_access` were no daemon issue: the tests' `replace_regex` placeholders (`"etag":ETAG`, eaten commas, `GTID`) made their output unparsable, so the key-order normalisation never ran.
- `role_privileges`: a cycle in a role/user/group hierarchy made MySQL's recursive CTEs fail (cte_max_recursion_depth, the login is refused) but MariaDB's stop with warning 1931 and a truncated result (the login went on). Decision (user, 2026-10-12): keep "a cycle refuses the login" on both servers; `QueryRaw::query()` raises warning 1931 as an error on MariaDB. (Switching to `UNION` would have let such users in: rejected.)
- **2026-10-13:** M2.3 closed (every suite on the three platforms against MariaDB). M2.4: async tasks removed and verified everywhere; then the MySQL build and server support dropped in 7 commits (build system, client ifdefs, server flavor, offline mode, tests/smoke/asof, docs). On the Mac after the removal: unit 389/389, ctest 113/113, live 102/104, MRS suite unchanged; Ubuntu and Windows verified too (same numbers as before the removal). The MySQL-side VM scripts (`mrsd-win.cmd`, `mrsd-pytest.ps1`, `mrsd-smoke.sh`) and the Ubuntu `<dev>/mysql` MySQL assets are obsolete, not deleted.

## Next steps

1. Milestone 3 (schema 5.0.0): inventory of every daemon touch-point (schema name option + prefix/postfix, table/column/role renames, UUID ids, `rest_daemon` registration, version gate 5.0.x, vendor/app names, status counters, audit-log polling with an overlap window), then the phases in PLAN.md. Test fixtures: the 5.0.0 deployment script from the shell's `main`; re-record the suite and retire the rewrite layer where possible.
2. After Milestone 3: the JSON-columns open point; then Milestone 4 (GTID), 5 (packaging, CI).
3. M2 final state verified: Ubuntu 110 passed / 0 failed / 6 skipped / 5 xfailed / 1 xpassed; Windows 109 / 0 / 7 / 5 / 1 (it skips `destination_socket`); ctest 113/113, live 102/104 on both.

## Files that matter

- `cmake/compat/mariadb_connector.cmake` → Connector/C finder (package, Homebrew, Debian tree, vcpkg).
- `compat/include/mrsd/compat_client.h` → what Connector/C lacks (ssl-mode enum, type codes, `bind_bool_t`, `effective_field_type()`, `is_client_error()`).
- `src/router/src/common/mysql_session.cc` → ssl-mode emulation, prepared CALL fixes, `is_mariadb()`; `src/router/src/common/server_compatibility.cc` → the MariaDB-only gate.
- `tools/smoke/run_smoke.sh` → smoke test; MariaDB build tree (`MARIADB_BUILD_DIR`+`MARIADB_SOURCE_DIR`) or package (`MARIADB_PACKAGE_DIR`; SQL via `mariadb-shell --sql` without a client).
- `tests/mrs/conftest.py`, `tests/mrs/test_mrs_suite.py` → functional suite harness (`--mariadb-build`, `--mariadb-package`, `--record` → `.mariadb.result`, `MRS_TEST_GENERAL_LOG`).
- `tests/mrs/mrstest/mariadb_sql.py` → the run-time SQL rewrite and output normalisation of upstream's scripts.
- `tests/mrs/{disabled,known_failures}.def`, `tests/mrs/r/*.mariadb.result` → disabled/xfail lists, results recorded on MariaDB.
- `tests/mrs/include/schema/mrs_metadata_schema-version4-mariadb.sql` → 4.1.6 deployment script (comments as `#`, no seeded `MySQL` auth app).
- VM scripts: `tools/vm/win.sh`, `win_sync.sh`, `win_wip.sh`; on the Windows VM `<win-home>\mrsd-win-mariadb.cmd`, `mrsd-smoke-mariadb.sh`, `mrsd-pytest-mariadb.ps1`; on the Ubuntu VM (`git push vm main`) `<dev>/mrsd-smoke-mariadb.sh`, `<dev>/mrsd-pytest-mariadb.sh` (MariaDB 11.8.9 and mariadb-shell 26.10.1 packages in `<downloads>`).

## Gotchas / things not to repeat

- **Do not touch the local checkouts** of `<dev>/shell` and `<dev>/mariadb-shell-plugins`: the user works on them (WIP branches with schema 5.0.0). Read only. On the Mac, `SHELL_PLUGINS=<dev>/mariadb-shell-plugins` now points at the 5.0.0 work; use a shell package's `lib/mariadb-shell/plugins` instead (has 4.1.6).
- **No `Co-Authored-By` (or any Claude) trailer in commits** (`~/.claude/CLAUDE.md`).
- MariaDB 13 accepts `->`/`->>`, 11.8 does not: arrow-free SQL only passes for real on 11.8.
- `mariadb-install-db` (Unix) creates anonymous accounts that shadow every `'%'` account for local connections: drop them. The Windows `mariadb-install-db.exe` (use `-d <datadir> -R`) creates none.
- Windows sandbox server package: no `mariadb.exe` client; `mariadbd.exe` needs `libssl-3-arm64.dll`/`libcrypto-3-arm64.dll` (take the shell package's `bin` on PATH, after the x64 dirs); its tools print nothing through the PowerShell pipe (redirect inside `cmd /c` to a file).
- Windows VM: little space on C: (build on `<win-dev>\mrsd-build-mariadb`); after a crash its clock was 8 h behind and ninja looped on "still dirty" (`Set-Date`); `win_sync.sh` leaves `.git\rebase-apply` after a failed `git am` and still moves `refs/win/synced` (abort on the VM, reset the ref to the Mac commit of the clone's HEAD).
- `win_wip.sh` resets the Windows clone to its own HEAD and applies only the uncommitted diff: run `win_sync.sh` first when there are new commits, or committed work silently disappears from the VM.
- MariaDB's system tables are Aria: a killed server (Windows `TerminateProcess`) corrupts the grant and role tables and every later test fails with 1959/126. The harness stops MariaDB with SQL `SHUTDOWN`.
- Unix socket paths must stay under 104 bytes (macOS): use `/tmp/...`.
- The Ubuntu VM's disk is small (12 GB free after removing the old MySQL build trees on 2026-10-12; only `build-mariadb` and `build-test-venv` are left, recreate others from the how-to in `docs/PROGRESS.md`).
- Windows ctest: `routertest_component_http_server` (`GET__empty_static_folder_with_trailing_spaces_404`) sometimes hits its 30 s timeout under load and passes alone; not a regression.
- This Mac's `grep` is ugrep: patterns starting with `-` or `--include` before the pattern misparse; scan with Python when in doubt.
- MariaDB renders booleans of system variables as ON/OFF, has no `super_read_only`/`offline_mode`, reports JSON routine results as LONGTEXT, compares geometry SRIDs, activates one role at a time.

## Git state

- Branch `main`. Remotes `vm` (Ubuntu), `fedora` (VM clones); `origin` (GitHub) is reachable but **empty**: nothing has ever been pushed there (the user has not asked to). Tag `m2-pre-build-decision` = the state before the MySQL removal, also on `vm`.
