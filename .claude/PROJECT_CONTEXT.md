# Project Context

## Project

`mariadb-restd` (MariaDB REST Daemon) is the REST service daemon for MariaDB, forked from MySQL Router's MySQL REST Service (MRS) plugin (`mysql-server/router`, trunk `06a5c1c99c3`, no history, no upstream sync). It serves REST endpoints for tables, views, procedures, functions and JS/TS scripts defined in the REST metadata schema. The project is MariaDB-only (MySQL build and server support were dropped in Milestone 2). Plan of record: `docs/PLAN.md`; build/test how-to and the session history: `docs/PROGRESS.md`; user-visible MariaDB differences: `docs/mariadb-differences.md`. Published releases: `gh release list`.

## Milestones

| # | What | State |
|---|---|---|
| 1 | Standalone daemon on MySQL (Linux, macOS, Windows) | done |
| 2 | MariaDB: Connector/C, MariaDB server, metadata schema 4.1.6 | done |
| 3 | Metadata schema **5.0.0** (`mariadb_rest_service`, prefix/postfix, renamed tables, `mariadb_rest_service_*` roles). Spec: `.claude/context/rest-daemon-5.0.md` on the shell repo's `main` | done (M3.0–M3.6) |
| 4 | GTID read-your-writes (`asof`, `_metadata.gtid`) on MariaDB GTIDs, together with the shell and plugins; the MySQL implementation is parked in the tree, `asof` is refused with a clear 400 | to do |
| 5 | Packaging and CI | release builds, verification and publishing in place; self-hosted CI, real deb/rpm installs and MSI to do |

## Architecture / key decisions

- One client: MariaDB Connector/C 3.4+, by default from vcpkg (`vcpkg.json`, `cmake/bootstrap_vcpkg.cmake`, as MariaDB Shell; configure needs no options), or `-DMARIADB_CONNECTOR_DIR`; what it lacks is in `compat/include/mrsd/compat_client.h`. vcpkg comes from `VCPKG_ROOT` only when that is a vcpkg git checkout, else `../vcpkg` (cloned at the baseline if missing); a directory that isn't a checkout is never replaced.
- One server: MariaDB **11.7+** (`UUID_v7()`), checked at startup (`server_compatibility.cc`, `MySQLSession::is_mariadb()` from the handshake); the SQL generators emit MariaDB SQL only. Tested against 11.8 LTS and 13.2.
- **Metadata 5.0.x only**: gate on major+minor, `unsupported_metadata_version_message()` (`query_version.cc`) for the monitor, `--setup` and the metadata logger. Schema name from the `metadata_schema` option / `--metadata-schema` (`mrs/database/metadata_schema.{h,cc}`; statements through `metadata_sql()`/`metadata_query()`, roles via `metadata_role()`). Daemon id `rest_daemon_id` = UUID text (`std::string`, bound as text); `--setup` accounts `mariadb_restd_<random>`; keyring `REST_DAEMON_ID`; JWT `instance_id` = the UUID.
- Ids: `UniversalId::from_cstr()` reads raw/dashed/hex; `helper::MySQLRow` converts ids by the field charset (63 or no metadata = raw bytes, else text); `X'…'` binding. `UUID` columns are text in the connection charset, `BINARY(16)` is charset 63; `X'…'` in canonical order matches `UUID`; `LAST_INSERT_ID()` is 0 for UUID keys.
- Audit-log polling is Galera-safe: each poll also re-reads a 60 s window by `changed_at` (server clock) and skips ids already returned (`QueryAuditLogEntries`, one per change monitor); `wsrep_sync_wait = 1` on Galera nodes. Suite test `audit_log_late_commit`.
- A cycle in a role/user/group hierarchy refuses the login (decision): MariaDB's recursive CTEs stop with warning 1931 and a truncated result, so `QueryRaw::query()` raises 1931 as an error. `UNION` would have let such users in.
- `--setup` accounts on MariaDB: default auth plugin (`IDENTIFIED BY`), one best-effort default role.
- **Removed from the product:** REST async tasks (`mysql_tasks`); routines are always called directly.
- The functional suite's scripts carry MariaDB's SQL and its results are recorded on MariaDB; no run-time rewrite or normalisation.
- Packages (`cmake --build <build> --target package`, STANDALONE layout): relocatable tarball, plugins in `lib/mariadb-restd/`, bundles Connector/C, its client auth plugins (`mariadb-client-plugins/`), zlib, OpenSSL, ICU, and libjitexecutor when built with `-DWITH_JIT_EXECUTOR=ON` (~90 MB with, ~20 MB without).
- Release pipeline: `rest-daemon-release.yml` (push to `release/candidate`) runs `tools/release/build_package.sh` on GitHub-hosted runners, ICU from vcpkg (`-DVCPKG_MANIFEST_FEATURES=icu`; Rocky 9 has ICU 67, restd needs 69), JIT executor cached per platform with `actions/cache`, Linux in a Rocky 9 container (glibc 2.34 floor). Windows is x64 only: GraalVM CE has no Windows ARM64 build, so the `windows-arm64` leg builds the same x64 package on an ARM64 runner (`vcvarsall arm64_amd64`, the image's default toolset) and only the x64 leg's copy is published. `verify-packages.yml` (pristine runners, `tools/release/verify_package.sh`) leaves `verified-build-<run id>`; `publish-release.yml` refuses a run without it. Both trigger only from the default branch (`workflow_run`/`workflow_dispatch`).
- Configuration: `[mariadb_rest_service]` (`metadata_user`, `data_user`, `read_write_destinations`, `read_only_destinations`, `ssl_*`, `tls_version`, `rest_daemon_id`, `metadata_schema`, ...); `MARIADB_RESTD_PID`; `--setup` writes `restd-key.pem`/`restd-cert.pem`. The old names (`[mysql_rest_service]`, `mysql_*`, `ROUTER_PID`) are read with a deprecation warning: `MySQLRouter::rename_deprecated_sections` (section, `library` default, `[logger] sinks`), `PluginConfig` (keys). Shared libraries `librestd_*`, plugins `mariadb_rest_service`, `rest_daemon` (`/api/20190715/daemon/status`), `restd_openssl`; the plugins' CMake targets keep upstream's names.
- Behaviour changes relative to upstream are marked `restd:` in comments.

## Next steps

1. Release `v26.10.0`'s notes say MariaDB Server 10.11: run Publish Release again for release run `38669748749` (the workflow's text says 11.7 now).
2. Per PLAN.md: the JSON-columns open point, then Milestone 4 (GTID read-your-writes, with the shell and plugins), then the rest of Milestone 5.
3. Self-hosted CI (all suites, ccache + JIT cache), waiting for IT-23080: GCP workload-identity access for this repository, the two GCP secrets, the org runner group.
4. Review later (PLAN.md open point "ids and names shared with the shell and plugins"): `vendorId` stays `0x…` until the SDKs switch (coordinate); the `mrs_notes`/`mrs_scripts` examples are 4.x leftovers (UUID owners, `UNHEX(?)`, old schema name, a 4.0 dump nothing loads, `mrs_notes.sql`'s MySQL-only `REGEXP_REPLACE` in `notes_all`; user to confirm), then a `UUID`-owner live test; custom auth procedure id type (daemon never calls it); the `kEntityCounterHttpRequestOptions` name (daemon + schema fallback); stale `0x` vendor ids in the shell docs.
5. Remove the deprecated configuration names (`[mysql_rest_service]`, the `mysql_*` keys, `ROUTER_PID`) in the next major release (PLAN.md "Rebranding round"). The plugins' `restd.py` reads both name sets (mariadb-shell-plugins commit `c74cbdfc`), so it needs no change for that.
6. Small items: the daemon logs an ERROR ("object_field ... Unknown datatype") for a *disabled* data-mapping field without a column, e.g. a reference the shell stores unselected (`filmActor` of a `sakila.actor` view): skip such fields, or align with the shell; `--setup` run from a build tree should write `plugin_folder` (else the daemon exits: plugins expected in `../lib/mariadb-restd`); optionally accept `--bootstrap` as an alias of `--setup` (the shell's schema comments/docs still say "bootstrapped").
7. Proposed, declined for now by the user: drop the `windows-arm64` build leg (it duplicates the x64 package, and its verification checks the unpublished copy) and verify `pkg-windows-x64` on `windows-11-arm`. MariaDB Shell's `cmake/bootstrap_vcpkg.cmake` has the same `VCPKG_ROOT` delete bug.

## Files that matter

- `cmake/compat/mariadb_connector.cmake` → Connector/C finder (package, Homebrew, Debian tree, vcpkg).
- `compat/include/mrsd/compat_client.h` → what Connector/C lacks (ssl-mode enum, type codes, `bind_bool_t`, `effective_field_type()`, `is_client_error()`).
- `src/router/src/common/mysql_session.cc` → ssl-mode emulation, prepared CALL fixes, `is_mariadb()`; `src/router/src/common/server_compatibility.cc` → the MariaDB-only gate.
- `.github/workflows/{rest-daemon-release,verify-packages,publish-release}.yml`, `tools/release/{build_package.sh,verify_package.sh,pe_imports.py}`, `docker/linux-rocky9.Dockerfile`, `.github/vcpkg-triplets/{vs2022,default}/` → release pipeline.
- `tools/smoke/run_smoke.sh` → smoke test; MariaDB build tree (`MARIADB_BUILD_DIR`+`MARIADB_SOURCE_DIR`) or package (`MARIADB_PACKAGE_DIR`; SQL via `mariadb-shell --sql` without a client), or an installed restd (`MRSD_INSTALL`). Schema via the shell's `CONFIGURE REST METADATA` (shell ≥ 26.10.2), `SHELL_PLUGINS` optional (msm deploySchema; needed for `MRS_SCRIPTS_DIR`, uploaded with `mrs.load.content_set()`).
- `tests/mrs/conftest.py`, `tests/mrs/test_mrs_suite.py` → functional suite harness (`--mariadb-build`, `--mariadb-package`, `--record` → `.mariadb.result`, `MRS_TEST_GENERAL_LOG`).
- `tests/mrs/{disabled,known_failures}.def` → disabled/xfail lists; `tests/mrs/r/*.result` → results recorded on MariaDB.
- `tests/mrs/include/schema/mariadb_rest_service-5.0.0.sql` → 5.0.0 deployment script for the suite, generated by `tools/analysis/make_test_schema.py` from the shell's `main` (markers removed, `#` comments, no seeded `MariaDB` auth app).
- `tools/analysis/convert_suite_5.py` → the one-off 4.x → 5.0.0 suite converter (kept for review).
- `LICENSE` → the licensing manual in MariaDB Shell's form: one section per third-party component that is compiled in or bundled (Connector/C, the GraalVM-based JIT executor library, ICU, libcno/picohttpparser, OpenSSL, RapidJSON, zlib) and the standard licenses they reference (Apache 2.0, GPLv2 with the Classpath Exception, LGPL 2.1, UPL 1.0); update it when a dependency is added or dropped. Test-only code (googletest, the mock server's Duktape) is not listed.

## Gotchas / things not to repeat

- **Commits:** only after the user has reviewed and approved the changes (also amends, history rewrites, pushes); a "yes" to a fix approves the edit, not a commit. Check the current branch first: the user switches the working tree. No `Co-Authored-By` (or any Claude) trailer. Messages describe the change only: no test counts, VM names or other details of the dev environment.
- **The repository is published** (GitHub): tracked files write machine paths as placeholders (`<dev>`, `<home>`, `<win-home>`, `<windows-vm>`, ...; values in the local `CLAUDE.local.md`, which also holds the facts about the local machines and clones); `CLAUDE.md`, `CLAUDE.local.md` and `tools/vm/` are local only (`.git/info/exclude`).
- **Auth in tests:** MRS-vendor auth apps log in with SCRAM (curl Basic fails with "Initial response required"); MariaDB Internal (the seeded `MariaDB` app) accepts Basic: login answers 307 to `/authentication/completed` with a cookie, or the token in the `Location` with `sessionType=bearer`.
- **mysqltest `if` and UUIDs**: a value starting with `0` reads as false, and every UUID v7 starts with `0`. The suite's fixed daemon id is `10000000-0000-7000-8000-000000000001`; test id variables with `== ''` / `` `SELECT $v IS NOT NULL` ``. `HEX()` of a UUID is the hex of its 36 characters (don't round-trip ids through `HEX`/`UNHEX`).
- **GitHub-hosted runners:** a Visual Studio developer environment sets `VCPKG_ROOT` to VS's bundled vcpkg under "Program Files" (autotools ports such as ICU fail on the space); `windows-2022` has a CMake 3.x (policies not set in `cmake_install.cmake` scripts, `REGEX REPLACE` empty-match errors) while `windows-11-arm` and macOS have CMake 4; the `windows-11-arm` image's side-by-side MSVC 14.44 has no x64 libraries; a 16 GB swap file filled the Ubuntu x64 runner's disk (free disk first, size swap to it); native-image on Rocky needs `zlib-static` and `patch`. Job logs of a running workflow: `gh api --allow-escape-sequences repos/<repo>/actions/jobs/<id>/logs` (`gh run view --log` waits for the run).
- MariaDB 13 accepts `->`/`->>`, 11.8 does not: arrow-free SQL only passes for real on 11.8.
- `mariadb-install-db` (Unix) creates anonymous accounts that shadow every `'%'` account for local connections: drop them. The Windows `mariadb-install-db.exe` (use `-d <datadir> -R`) creates none. From a build tree it needs `--srcdir` and `--builddir`.
- Windows MariaDB server package: no `mariadb.exe` client; `mariadbd.exe` needs `libssl-3-arm64.dll`/`libcrypto-3-arm64.dll` (take the shell package's `bin` on PATH, after the x64 dirs); its tools print nothing through the PowerShell pipe (redirect inside `cmd /c` to a file).
- MariaDB's system tables are Aria: a killed server (Windows `TerminateProcess`) corrupts the grant and role tables and every later test fails with 1959/126. The harness stops MariaDB with SQL `SHUTDOWN`.
- Unix socket paths must stay under 104 bytes (macOS): use `/tmp/...` or `$TMPDIR` (a scratchpad path is too long).
- Do not run two suite/live-test runs at once on one machine: they collide on ports (`OperationalError` failures, none of them real). Do not rebuild the test tree while the MRS suite runs either: the binaries are replaced under the tests (a spurious result diff).
- `tools/release/verify_package.sh` names the plugins a package must contain: a plugin rename must change that list too, or every verification leg fails on that one check.
- GraalVM's `LICENSE` ends with Oracle's written offer for source code; the manual takes only the Classpath Exception text from it.
- Mixed working trees: split the commits with a `git diff -U0` hunk classifier + `git apply --cached --unidiff-zero`; better, finish verification before starting the next phase's edits.
- Windows ctest: `routertest_component_http_server` (`GET__empty_static_folder_with_trailing_spaces_404`) sometimes hits its 30 s timeout under load and passes alone; not a regression.
- MariaDB renders booleans of system variables as ON/OFF, has no `super_read_only`/`offline_mode`, reports JSON routine results as LONGTEXT, compares geometry SRIDs, activates one role at a time.
