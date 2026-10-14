# Project Context

## Project

`mariadb-restd` (MariaDB REST Service Daemon) is the REST service daemon for MariaDB, forked from MySQL Router's MySQL REST Service (MRS) plugin (`mysql-server/router`, trunk `06a5c1c99c3`, no history, no upstream sync). It serves REST endpoints for tables, views, procedures, functions and JS/TS scripts defined in the REST metadata schema. Milestone 1 (standalone daemon on MySQL 9.x / 26.7) is done; **Milestone 2 (MariaDB) is done (2026-10-13); the project is MariaDB-only; Milestone 3 (schema 5.0.0) is current** (MySQL build and server support dropped; restore point: tag `m2-pre-build-decision`, bundle in `<dev>/rest-daemon-backups/`). Plan of record: `docs/PLAN.md`; build/test how-to and the session history: `docs/PROGRESS.md`; user-visible MariaDB differences: `docs/mariadb-differences.md`.

## Milestones

| # | What | State |
|---|---|---|
| 1 | Standalone daemon on MySQL (Linux, macOS, Windows) | done 2026-10-07 |
| 2 | MariaDB: Connector/C, MariaDB server, metadata schema **4.1.6** | done 2026-10-13 |
| 3 | Metadata schema **5.0.0** (`mariadb_rest_service`, prefix/postfix, renamed tables, `mariadb_rest_service_*` roles), now on the `main` branches of the shell and plugins. Spec: the shell repo's `.claude/context/rest-daemon-5.0.md` (read with `git show main:...`) | current: M3.0–M3.4 done (5.0.0 served, verified on all three platforms); M3.5 next |
| 4 | GTID read-your-writes (`asof`, `_metadata.gtid`) on MariaDB GTIDs, together with the shell and plugins; the MySQL implementation is parked in the tree, `asof` is refused with a clear 400 | after 3 |
| 5 | Packaging (real deb/rpm installs, MSI) and GitHub Actions CI | last |

## Architecture / key decisions

- One client: MariaDB Connector/C 3.4+ (`-DMARIADB_CONNECTOR_DIR`); what it lacks is in `compat/include/mrsd/compat_client.h`. One server: MariaDB **11.7+** (since M3.4; `UUID_v7()`), checked at startup (`server_compatibility.cc`, `MySQLSession::is_mariadb()` from the handshake); the SQL generators emit MariaDB SQL only (no runtime flavor switch any more).
- The functional suite's scripts carry MariaDB's SQL (the MySQL-only constructs were rewritten in the files, M3.1) and its results are recorded on MariaDB; no run-time rewrite or normalisation is left.
- Minimum MariaDB server 11.7 (metadata 5.0.0); developed on 13.2 (macOS), Ubuntu/Windows tested on 11.8.9 LTS.
- **Metadata 5.0.x only** (since M3.4): gate on major+minor, `unsupported_metadata_version_message()` (`query_version.cc`) for the monitor, `--setup` and the metadata logger. Daemon id `rest_daemon_id` = UUID text (`std::string`, bound as text); `--setup` accounts `mariadb_restd_<random>`; keyring `REST_DAEMON_ID`; JWT `instance_id` = the UUID.
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
- **Milestone 3 (2026-10-13):** inventory `docs/milestone3-inventory.md`; plan in PLAN.md (decisions table + phases M3.0–M3.6). Done: **M3.0** (schema-2/3 support gone, one `QueryFactory`, gate 4.0.0 only), **M3.1** (the suite's MySQL-only SQL rewritten in the files, results re-recorded on 13.2, `mariadb_sql.py` gone), **M3.2** (`metadata_schema` option / `--metadata-schema`, `mrs/database/metadata_schema.{h,cc}`, 54 statements through `metadata_sql()`/`metadata_query()`, roles via `metadata_role()`), **M3.3** (UUID spike, findings in PLAN.md; `UniversalId::from_cstr()` reads raw/dashed/hex, `helper::MySQLRow` converts ids by the field charset — 63 or no metadata = raw bytes, else text; `X'…'` binding kept). Mac after M3.3: unit 395/395, ctest 113/113, live 102/104, suite 108/0/4/5/1. Still on 4.1.6; the text-id path is only unit-tested until M3.4.
- **M3.4 (2026-10-13), branch `m3.4`, 7 commits (steps 1–5, 6a smoke, 6 docs):** daemon SQL on 5.0.0, `rest_daemon_id` UUID, suite asset + conversion + re-record, unit/component/live tests, smoke test on shell 26.10.2, README/differences/PLAN/PROGRESS. Mac (13.2): unit 395/395, ctest 113/113, live 102/104, suite 108/0/4/5/1, smoke incl. MRS script OK. Ubuntu (11.8.9): ctest 113/113, live 102/104, suite 109/0/3/5/1, smoke OK; Windows (11.8.9): 113/113, 102/104, 108/0/4/5/1, smoke OK (shell 26.10.2 packages on both). Fast-forwarded to `main`.
- **2026-10-13:** M2.3 closed (every suite on the three platforms against MariaDB). M2.4: async tasks removed and verified everywhere; then the MySQL build and server support dropped in 7 commits (build system, client ifdefs, server flavor, offline mode, tests/smoke/asof, docs). On the Mac after the removal: unit 389/389, ctest 113/113, live 102/104, MRS suite unchanged; Ubuntu and Windows verified too (same numbers as before the removal). The MySQL-side VM scripts (`mrsd-win.cmd`, `mrsd-pytest.ps1`, `mrsd-smoke.sh`) and the Ubuntu `<dev>/mysql` MySQL assets are obsolete, not deleted.

## Next steps

1. M3.5 (wire formats/texts: user ids as UUID text, the raw-bytes role id bug, counter names + `statusVariables`, remaining "MySQL"/"Router" texts such as "Monitoring MySQL REST metadata", "configured for the MySQL server") and M3.6 (Galera-safe audit polling).
   Spike facts to lean on (PLAN.md M3.3): `UUID` columns = text with the connection charset, `BINARY(16)` = charset 63; `X'…'` in canonical order matches `UUID`; `LAST_INSERT_ID()` is 0 for UUID keys.
2. Open point (PLAN.md): owner columns with UUID user ids. The plugins' `mrs_notes` (`BINARY(16)` owners) and `mrs_scripts` (grants on `mysql_rest_service_metadata`, `UNHEX(?)` user lookup) look like 4.x leftovers; the user will confirm on the plugins' side, then: a `UUID`-owner live test, the script API's user id (M3.5).
3. After Milestone 3: the JSON-columns open point; then Milestone 4 (GTID), 5 (packaging, CI).
4. M2 final state verified: Ubuntu 110 passed / 0 failed / 6 skipped / 5 xfailed / 1 xpassed; Windows 109 / 0 / 7 / 5 / 1 (it skips `destination_socket`); ctest 113/113, live 102/104 on both.

## Files that matter

- `cmake/compat/mariadb_connector.cmake` → Connector/C finder (package, Homebrew, Debian tree, vcpkg).
- `compat/include/mrsd/compat_client.h` → what Connector/C lacks (ssl-mode enum, type codes, `bind_bool_t`, `effective_field_type()`, `is_client_error()`).
- `src/router/src/common/mysql_session.cc` → ssl-mode emulation, prepared CALL fixes, `is_mariadb()`; `src/router/src/common/server_compatibility.cc` → the MariaDB-only gate.
- `tools/smoke/run_smoke.sh` → smoke test; MariaDB build tree (`MARIADB_BUILD_DIR`+`MARIADB_SOURCE_DIR`) or package (`MARIADB_PACKAGE_DIR`; SQL via `mariadb-shell --sql` without a client). Schema via the shell's `CONFIGURE REST METADATA` (shell ≥ 26.10.2), `SHELL_PLUGINS` optional (msm deploySchema; needed for `MRS_SCRIPTS_DIR`, uploaded with `mrs.load.content_set()`).
- `tests/mrs/conftest.py`, `tests/mrs/test_mrs_suite.py` → functional suite harness (`--mariadb-build`, `--mariadb-package`, `--record` → `.mariadb.result`, `MRS_TEST_GENERAL_LOG`).
- `tests/mrs/{disabled,known_failures}.def` → disabled/xfail lists; `tests/mrs/r/*.result` → results recorded on MariaDB.
- `tests/mrs/include/schema/mariadb_rest_service-5.0.0.sql` → 5.0.0 deployment script for the suite, generated by `tools/analysis/make_test_schema.py` from the shell's `main` (markers removed, `#` comments, no seeded `MariaDB` auth app).
- `tools/analysis/convert_suite_5.py` → the one-off 4.x → 5.0.0 suite converter (kept for review).
- VM scripts: `tools/vm/win.sh`, `win_sync.sh`, `win_wip.sh`; on the Windows VM `<win-home>\mrsd-win-mariadb.cmd`, `mrsd-smoke-mariadb.sh`, `mrsd-pytest-mariadb.ps1`; on the Ubuntu VM (`git push vm main`) `<dev>/mrsd-smoke-mariadb.sh`, `<dev>/mrsd-pytest-mariadb.sh` (MariaDB 11.8.9 and mariadb-shell 26.10.1 packages in `<downloads>`).

## Gotchas / things not to repeat

- `<dev>/shell` and `<dev>/mariadb-shell-plugins` may be used and built again (2026-10-13: their 5.0.0 work is merged, the checkouts are up to date and built; `<dev>/shell` was on branch `docker/mcp-image`, which contains `main` and has no REST-module changes). Don't commit there; patch copies (e.g. the `mrs_scripts` example) in a scratch dir.
- **mysqltest `if` and UUIDs**: a value starting with `0` reads as false, and every UUID v7 starts with `0`. The suite's fixed daemon id is `10000000-0000-7000-8000-000000000001`; test id variables with `== ''` / `` `SELECT $v IS NOT NULL` ``. `HEX()` of a UUID is the hex of its 36 characters (don't round-trip ids through `HEX`/`UNHEX`).
- **No `Co-Authored-By` (or any Claude) trailer in commits** (`~/.claude/CLAUDE.md`).
- MariaDB 13 accepts `->`/`->>`, 11.8 does not: arrow-free SQL only passes for real on 11.8.
- `mariadb-install-db` (Unix) creates anonymous accounts that shadow every `'%'` account for local connections: drop them. The Windows `mariadb-install-db.exe` (use `-d <datadir> -R`) creates none.
- Windows sandbox server package: no `mariadb.exe` client; `mariadbd.exe` needs `libssl-3-arm64.dll`/`libcrypto-3-arm64.dll` (take the shell package's `bin` on PATH, after the x64 dirs); its tools print nothing through the PowerShell pipe (redirect inside `cmd /c` to a file).
- Windows VM: little space on C: (build on `<win-dev>\mrsd-build-mariadb`); after a crash its clock was 8 h behind and ninja looped on "still dirty" (`Set-Date`); `win_sync.sh` leaves `.git\rebase-apply` after a failed `git am` and still moves `refs/win/synced` (abort on the VM, reset the ref to the Mac commit of the clone's HEAD).
- `win_wip.sh` resets the Windows clone to its own HEAD and applies only the uncommitted diff: run `win_sync.sh` first when there are new commits, or committed work silently disappears from the VM.
- MariaDB's system tables are Aria: a killed server (Windows `TerminateProcess`) corrupts the grant and role tables and every later test fails with 1959/126. The harness stops MariaDB with SQL `SHUTDOWN`.
- Unix socket paths must stay under 104 bytes (macOS): use `/tmp/...` or `$TMPDIR` (the scratchpad path is too long). `mariadb-install-db` from a build tree needs `--srcdir` and `--builddir`.
- Do not run two suite/live-test runs at once on the Mac: a concurrent run produced 50 `OperationalError` failures (ports), none of them real.
- Mixed working trees: split the commits with a `git diff -U0` hunk classifier + `git apply --cached --unidiff-zero` (done for M3.2/M3.3); better, finish verification before starting the next phase's edits.
- The Ubuntu VM's disk is small (12 GB free after removing the old MySQL build trees on 2026-10-12; only `build-mariadb` and `build-test-venv` are left, recreate others from the how-to in `docs/PROGRESS.md`).
- Windows ctest: `routertest_component_http_server` (`GET__empty_static_folder_with_trailing_spaces_404`) sometimes hits its 30 s timeout under load and passes alone; not a regression.
- This Mac's `grep` is ugrep: patterns starting with `-` or `--include` before the pattern misparse; scan with Python when in doubt.
- MariaDB renders booleans of system variables as ON/OFF, has no `super_read_only`/`offline_mode`, reports JSON routine results as LONGTEXT, compares geometry SRIDs, activates one role at a time.

## Git state

- Branch `main` (fast-forwarded from `m3.4` after M3.4 passed everywhere; `m3.4` can be deleted). Ubuntu clone `<dev>/mrsd` on `main` (`28bd930`); Windows clone on the same commits through `win_sync.sh` (`BRANCH=` for a branch), `refs/win/synced` = `139f8c5`. Remotes `vm` (Ubuntu), `fedora` (VM clones); `origin` (GitHub) is reachable but **empty**: nothing has ever been pushed there (the user has not asked to). Tag `m2-pre-build-decision` = the state before the MySQL removal, also on `vm`.
