# restd: standalone MySQL REST Service daemon (plan)

This is the plan of record. Progress is tracked in [PROGRESS.md](PROGRESS.md) and
findings in [phase0-inventory.md](phase0-inventory.md). If the plan changes, update this
file and add a line to the "Decision log" at the end.

## Goal

Fork MySQL Router's **MySQL REST Service (MRS)** out of the MySQL server
repository into a standalone project that builds a single-purpose MRS daemon, `mrsd`.

**Milestone 1 ✅ done (2026-10-07):** `mariadb-restd` builds against a stock
**MySQL 9.x client library**, runs in the **MySQL ecosystem** (MySQL Server 9.x,
MySQL Shell `mrs` plugin, MySQL Shell for VS Code), and serves the same REST
endpoints as `mysqlrouter` with MRS enabled. Verified on Linux, macOS and Windows
(unit + component tests, MRS functional suite, smoke test incl. MRS scripts).

**Milestone 2 ✅ done (2026-10-13):** migrate to MariaDB (Connector/C,
MRS metadata schema and queries, MariaDB-aware destination providers).
Phases are listed under "Milestone 2" below.

**Milestone 3 (current):** the MariaDB metadata schema 5.0.0 (`mariadb_rest_service`,
with an optional name prefix/postfix; tables renamed, e.g. `db_object` →
`rest_object`, `router` → `rest_daemon`; roles `mariadb_rest_service_*`), as it
lands on the main branches of the MariaDB shell and plugins. Milestone 2 stays
on the schema of their main branches today (4.1.6).

**Milestone 4:** GTID read-your-writes (`asof`, `_metadata.gtid`) on MariaDB GTIDs, done
together with the MariaDB shell and plugins (it touches the three repositories). Until
then the daemon refuses `asof` with a clear error and the MySQL implementation stays
parked in the tree (see the open point below).

**Milestone 5 (final):** packaging and CI (the former Phase 4, see below). The
packaging done so far (tar.gz, deb, rpm, Windows ZIP) stays in the tree; the
remaining items (real deb/rpm installs, MSI, GitHub Actions) are finished last.

## Scope decisions

| Topic | Decision |
|---|---|
| Source origin | `mysql-server` repo, `router/` tree (trunk, forked 2026-09-30 at `06a5c1c99c3`) |
| Git history | **Not preserved.** Plain copy |
| Client library | Milestone 1: stock **MySQL 9.x** libmysqlclient (public API only) from a MySQL server package (`-DMYSQL_PACKAGE_DIR`). Since 2026-10-13: **MariaDB Connector/C only** (`-DMARIADB_CONNECTOR_DIR`) |
| JIT executor (JavaScript endpoints) | **Included**; `-DMRS_JIT_EXECUTOR_LIB=<dir>` points to a directory with the prebuilt `libjitexecutor` **and** its headers (`polyglot_api.h`, `graal_isolate.h`, …). Local: `<dev>/workflow-test/ext/polyglot/polyglot-nativeapi-native-library/target` |
| InnoDB Cluster / ClusterSet / ReplicaSet | **Out of scope.** No `metadata_cache`, no cluster bootstrap |
| X Protocol | **Out of scope.** No mysqlxclient, mysqlxmessages or protobuf |
| Platforms | **Linux, Windows, macOS** |
| Upstream sync | **None.** Directory layout may be changed freely |
| Tests | Keep the GoogleTest/CTest suites; port the MRS-relevant mtr tests to gtest; no mtr |
| Source repo location | `https://github.com/mariadb-corporation/rest-daemon` (private), local clone `<dev>/rest-daemon` |

## Guiding principles

1. **Copy first, prune second.** Get a green build and tests with minimal code
   changes, then remove parts with the tests as a safety net. The one exception
   is `routing`/`metadata_cache`, which are cut up front (see Phase 1).
2. **Only the public client API.** Anything Router takes from libmysqlclient
   internals (mysys/strings) gets a small in-tree replacement in `compat/`.
3. **Stay compatible with the MySQL ecosystem.** The MRS metadata schema, router
   registration and config semantics stay compatible, so MySQL Shell tooling keeps working.
4. **Each phase ends with explicit exit criteria**, recorded in PROGRESS.md.

## Target module set

**Copy (from `router/src/`):** `harness`, `router` (only `router_utils`,
`router_mysql`, `router_lib` minus cluster parts; a new `mrsd` front end),
`http` (minus `http_auth_backend_metadata_cache.cc`), `rest_api`, `io`,
`mysql_protocol`, `mysql_rest_service`, `jit_executor`, `json_schema_embedder`,
`openssl`, `plugin_info`, `destination_status`, `keepalive`, `rest_router`
(optional status endpoints), `mock_server` (minus X), plus `router/tests/helpers`
and the relevant test suites.

**Leave out:** `routing`, `routing_guidelines`, `metadata_cache`,
`connection_pool` (it includes routing headers; MRS has its own pool in
`mrs/collector`), `rest_routing`, `rest_metadata_cache`,
`rest_connection_pool`, `host_cache`, `rest_host_cache`, `mysqlxmessages`,
`protobuf`, `bootstrap`, `router_cluster`, `routing_guidelines`.

## Phases

### Phase 0: dependency inventory ✅ done (2026-09-30)
See [phase0-inventory.md](phase0-inventory.md). **Verdict: GO.** The kept code uses
46 public client API functions plus 10 internal symbols, all with simple replacements.

### Phase 1: new repo that builds ✅ done (2026-09-30: macOS, Linux, Windows x64, with JIT)
- **1.1 Skeleton:** repo layout (below), top-level CMake, `cmake/` helpers
  replacing the server macros (`ADD_HARNESS_PLUGIN`, `ADD_STATIC_LIBRARY`,
  `ROUTER_ADD_SHARED_LIBRARY`, `MYSQL_ADD_EXECUTABLE`, `ADD_SCHEMA_COMMAND`,
  `ROUTER_COPY_CUSTOM_*`), and `GenerateExportHeader` for the export headers.
- **1.2 Third-party libraries:**
  - OpenSSL: system on Linux/macOS; a custom location on Windows.
  - rapidjson: vendor MySQL's copy from `extra/rapidjson`, keeping the `my_rapidjson_size_t.h` semantics.
  - ICU: **keep** (used by `harness/regex_matcher.cc` for the HTTP request router, MRS auth handler and log filter; chosen upstream for speed, see Bug#36797250). System ICU on Linux/macOS; vendored `extra/icu` or vcpkg on Windows.
  - libcno: vendor `extra/libcno` with its huffman generator.
  - GTest: FetchContent or vendored.
  - MySQL client: required `-DMYSQL_PACKAGE_DIR=<server package>`; find `mysql.h` in `<pkg>/include` and libmysqlclient in `<pkg>/lib`; check `mysql_version.h` ≥ 9.0.
- **1.3 Copy the code:** the module set above, the vendored header-only server
  headers in `extra/mysql-internals/`, and a slim generated `my_config.h`
  (`extra/mysql-internals/my_config.h.in`, only the macros that are used).
- **1.4 `compat/` library** replacing the 10 internal symbols (see inventory §3).
- **1.5 Cut `routing`:** MRS static destination provider. New `[mysql_rest_service]`
  options replace `mysql_read_write_route`/`mysql_read_only_route`:
  `mysql_read_write_destinations` (required), `mysql_read_only_destinations`
  (comma-separated `host[:port]`, `[ipv6]:port` or `local:/path.sock`; port
  defaults to 3306), and backend TLS options `mysql_ssl_mode`
  (DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY, default PREFERRED),
  `mysql_ssl_ca`, `mysql_ssl_capath`, `mysql_ssl_crl`, `mysql_ssl_crlpath`,
  `mysql_ssl_curves`, `mysql_ssl_cipher`, `mysql_tls_version`.
- **1.6 Split `router_lib`:** drop the link to `router_cluster`/`routing_guidelines`;
  the new `mrsd` front end (main, config, Windows service) replaces
  `router_app.cc`/`config_generator.cc`.
- **1.7 `mock_server` without X:** moved to Phase 2. The mock server needs
  duktape, which upstream removed from `extra/` (Bug#37009228), so it isn't
  built and the change can't be validated yet.
- **1.8 Build JIT on:** `-DMRS_JIT_EXECUTOR_LIB=<dir with lib + headers>`,
  same semantics as upstream (`FIND_LIBRARY(jitexecutor HINTS <dir> NO_DEFAULT_PATH)` + include dir).
- **Exit criteria:** `mrsd` and all plugins build on Linux, macOS and Windows,
  with and without JIT, and `tools/smoke/run_smoke.sh` passes (`mysql_server_mock`
  moved to Phase 2).

### Phase 2: tests and validation in the MySQL ecosystem ✅ done (2026-10-05)
- ✅ duktape 2.7.0 restored from git history (`214f378700f^:extra/duktape`) into
  `extra/duktape`; mock server without X (step 1.7).
- **MRS functional suite (mysql-test/suite/router, ~115 tests after dropping
  bootstrap) → pytest + golden files** (decided 2026-09-30): a small Python
  interpreter for the mysqltest subset these tests use (let, echo, source, exec,
  eval, if/while, replace_regex, query/result log switches, error, assert,
  sleep, remove_file; ~10 perl blocks need porting), run by pytest one item per
  `.test`, comparing against the existing `.result` files. Needs upstream's
  `router/tests/mrs_client` (C++ REST client) and an mrsd-based replacement for
  the bootstrap step in `predefined_setup/configure_router_mrs_root.inc`.
- Move the TLS fixtures (`mysql-test/std_data` → `tests/data/ssl`) and repoint
  `SSL_TEST_DATA_DIR`. Copy the `unittest/gunit/benchmark.h` helper.
- Get the unit suites green: MRS, HTTP, harness, router_lib, jit_executor.
- Get the component tests green against `mysql_server_mock`.
- ~~Get the integration tests green against a real MySQL 9.x `mysqld`.~~ Dropped:
  they all test routing (see the decision log).
- Triage `mysql-test/suite/router` (137 tests) and port the MRS-related ones.
- Manual end-to-end check: MySQL Shell `mrs` plugin creates the metadata schema and a
  service; configure `mrsd` by hand (config plus keyring); verify CRUD, auth apps,
  and JavaScript endpoints.
- **Exit criteria:** unit, component and MRS functional tests pass on 3 OSes (run
  on the local machine and VMs; CI moved to the end, see Phase 4); end-to-end checked
  by the smoke test (REST view and MRS scripts) and the MRS functional suite (CRUD,
  auth apps, scripts).

### Phase 3: MRS-specific setup and cleanup ✅ done (2026-10-05)
- ✅ Branding (2026-10-05): program `mariadb-restd` (+ `-keyring`, `-passwd`,
  `-plugin-info`), product name "MariaDB REST Service Daemon" (version line, logs,
  Windows service/event log, REST API title, MRS metadata `product_name`), default
  `mariadb-restd.conf` / `mariadb-restd.log`. Both names are set only in
  `cmake/settings.cmake`. Config section names and log domains are kept (router-style
  configs stay valid). Install layout (`lib/mysqlrouter`, `/var/lib/mysqlrouter`,
  `C:\ProgramData\MySQL\MySQL Router`) is renamed with packaging (Phase 4).
- ✅ `mariadb-restd --setup <server URI> -d <dir>` (2026-10-05): from `BootstrapConfigurator::configure_mrs()`
  (check_mrs_metadata, register_mrs_router_instance, create_mrs_users, keyring,
  config writing) against a single standalone server; no router account and no routing
  sections. Options without the `mrs-` prefix: `--metadata-account`, `--data-account`,
  `--jwt-secret`, `--developer`, `--developer-debug-port`. Directory deployment only;
  system-wide deployment comes with packaging.
- ✅ Remove leftover routing and cluster code and options from harness/router_lib
  (destination_status, metadata_cache/bootstrap paths, DynamicState, config exposure).
- **Exit criteria:** a fresh install works via `mrsd --setup` alone on each OS.

### Phase 4: packaging and CI (moved to Milestone 5)
Decided 2026-10-05: CPack for all formats (not upstream's deb-in/rpm/WiX trees);
formats deb + rpm, Linux tar.gz, Windows MSI + ZIP, macOS tar.gz; libmysqlclient and
libjitexecutor always bundled, OpenSSL/ICU from the OS in deb/rpm and bundled in the
other packages; vendor MariaDB plc; `VERSION` file with `VERSION = x.y.z` entries.
1. Version + CPack metadata.
2. Install layout: STANDALONE (tarballs, ZIP, MSI) and system (deb/rpm) layouts, names
   derived from the program name (no `mysqlrouter` paths left).
3. Bundled runtime libraries, rpath/install-name fixups.
4. Linux and macOS tarballs, verified with `--setup` + smoke test from the unpacked tree.
5. deb/rpm: systemd unit, service user, system-wide `--setup`.
6. Windows ZIP + MSI (service installation option). MSI deferred (2026-10-05): the
   Windows VM has no WiX/.NET and little disk; the ZIP ships for now.
- CI matrix: 3 OSes × JIT on/off × MySQL 9.x server: unit + component tests, MRS
  functional suite, smoke test. Last step of the whole work, once the final remote
  repository exists (it decides the CI system).

## Milestone 2: MariaDB

Goal: `mariadb-restd` builds against **MariaDB Connector/C**, runs against a
**MariaDB server** with the MRS metadata schema deployed by the MariaDB Shell
plugins (schema 4.1.6+), and serves the same REST endpoints. Findings:
[milestone2-inventory.md](milestone2-inventory.md). Same recipe as Milestone 1:
inventory, build, tests, cleanup.

Scope decisions (2026-10-08, see the decision log):

| Topic | Decision |
|---|---|
| MySQL build | Kept during the port as the safety net; **dropped on 2026-10-13** (M2.4) together with MySQL server support, once the MariaDB suites were at parity on the three platforms |
| Client library | **MariaDB Connector/C package** (release build with OpenSSL), found through `-DMARIADB_CONNECTOR_DIR` / `mariadb_config`; public API only, as in Milestone 1 |
| Minimum MariaDB server | **10.11 (oldest supported LTS)**; develop and test on `main` (13.2). Caveat: the MRS metadata schema 4.1.6 uses `JSON_SCHEMA_VALID` (11.1+) and `JSON_OVERLAPS` (10.9+); deploying on 10.11 needs a schema change on the plugin side. `sqlQuery.timeout` uses `SET STATEMENT max_statement_time` (done 2026-10-13: the `MAX_EXECUTION_TIME` hint only exists from 12.0 and was silently ignored on 11.8), `VECTOR` only where the server has it (11.7+) |
| REST async tasks (`mysql_tasks`) | **Removed** (2026-10-12, a product decision: MariaDB REST routines are always called directly, as in the MariaDB shell plugins); code removed in M2.4 (2026-10-13) |
| GTID / "asof" | **Out of Milestone 2**: `asof` is refused with a clear error; the MySQL implementation stays parked in the tree for **Milestone 4** (see the open point below) |
| `--setup` accounts | MariaDB's **default auth plugin** (`CREATE USER ... IDENTIFIED BY`) |
| MRS scripts (JIT) | **In scope**: the smoke test's script step (example scripts deployed with `LOAD SCRIPTS` through the MariaDB Shell plugins) must pass on MariaDB; plugin-side problems go to the plugin team |

### Phase M2.0: MariaDB dependency inventory ✅ done (2026-10-07)
Verdict GO, in stages. Client switch is mechanical; server-side work is JSON
document generation, GTID tracking, `mysql_tasks`, account setup, tests.

### Phase M2.1: build against MariaDB Connector/C
- CMake: `-DMARIADB_CONNECTOR_DIR` (or `mariadb_config`) finder replacing
  `cmake/compat/mysql_package.cmake`; `MySQL::client` → `MariaDB::client`; bundling of
  `libmariadb` and its dynamic client auth plugins (`MYSQL_PLUGIN_DIR`).
- Client-API gaps (inventory §2): nonblocking API → `_start/_cont` (since removed with
  the async tasks); project `SslMode`
  enum emulated with `SSL_ENFORCE`/`SSL_VERIFY_SERVER_CERT`; drop the TLS session cache,
  query attributes, missing option aliases and type enums; `MYSQL_BIND::is_null` as
  `my_bool`; `CR_*`/`ER_*` constants; headers; `compat/` client errors and charset table.
- Exit: all three platforms build with JIT; unit and component tests (mock server) pass.

### Phase M2.2: run against a MariaDB server
- Server gating (`server_compatibility.cc`), `@@super_read_only`, offline mode, error-code
  mapping, `SET ROLE`, `sql_mode` default; `--setup` account creation with MariaDB syntax
  and the 1973 "already exists" note.
- Metadata loaders: `->>` → `JSON_EXTRACT`; `UUID_TO_BIN`; `INSERT ... AS new`.
- JSON document generation (`JSON_OBJECT`/`JSON_ARRAYAGG` nesting, `CAST AS JSON`,
  `ST_AsGeoJSON`) measured against MariaDB and fixed; JSON/VECTOR column detection through
  Connector/C extended metadata; `VEC_FromText`/`VEC_ToText`; GIS SRID handling.
- GTID / "asof": disabled on MariaDB with a clear error (open point, see below). REST async tasks: removed.
- Smoke test variant for MariaDB (`mariadbd`, `mariadb-shell` + plugins, schema 4.1.6).
- Behaviour differences for users: [mariadb-differences.md](mariadb-differences.md).
- Exit: smoke test (REST view GET, and MRS scripts if in scope) passes on MariaDB on all
  three platforms.

### Phase M2.3: test suites on MariaDB ✅ done (2026-10-13)
- `tests/mrs` harness: `mariadbd` start/reset, 4.1.6 deployment script instead of the v4
  dump, MariaDB-specific expectations (result files, GTID format, error codes), disabled
  tests with reasons (`disabled.def`).
- Live-DB unit tests (`shared_server.cc`) and fixtures on MariaDB.
- Exit: unit + component + MRS suite pass on Linux, macOS, Windows against MariaDB, with a
  recorded list of disabled tests and why.

### Phase M2.4: cleanup ✅ done (2026-10-13)
- ✅ 2026-10-13: REST async tasks removed: `mysql_tasks` calls, the task monitor, the
  task-status endpoints, the `mysqlTask` options (still tolerated in metadata), the async
  OpenAPI variant, and the nonblocking query path of `MySQLSession` (only the task
  monitor used it). `DELETE` on a routine keeps answering 403.
- ✅ 2026-10-13: the MySQL build and MySQL server support dropped (decision: MariaDB
  only): Connector/C is the only client (`cmake/compat/mysql_package.cmake` and the
  `MRSD_CLIENT_MARIADB` ifdefs gone), a MariaDB server 10.11+ the only one accepted, the
  `is_mariadb()` runtime branches collapsed to the MariaDB code, the MySQL modes of the
  functional suite, the live-DB tests and the smoke test gone; README/docs for MariaDB.
- ✅ 2026-10-13 follow-ups: the pass-through pool activates an account's single role
  (`passthrough_db_user` passes); `sqlQuery.timeout` through `SET STATEMENT` (`timeout`
  passes; the hint was inert below 12.0); the minimum stays 10.11 for the daemon, with the
  schema's 11.1 and VECTOR's 11.7 stated in the README.
- ✅ 2026-10-13: VECTOR coverage: the 7 vector tests ported to fixed dimensions and
  re-enabled, which found two daemon bugs (INOUT `VECTOR` parameters failed with 1292,
  OUT ones rendered as base64) and the malformed-base64 500.
- ✅ 2026-10-13: the `restd:` markers reworded for the MariaDB-only tree.

## Milestone 3: metadata schema 5.0.0

Goal: `mariadb-restd` serves the MariaDB REST Service metadata schema 5.0.0
(`mariadb_rest_service`, with a prefix/postfix per deployment), as deployed by the
MariaDB shell's `CONFIGURE REST METADATA`. No 4.x compatibility: nothing of 5.0.0 was
released before. Spec: the shell repo's `.claude/context/rest-daemon-5.0.md`; findings:
[milestone3-inventory.md](milestone3-inventory.md).

Decisions (2026-10-13, see the decision log):

| Topic | Decision |
|---|---|
| Minimum server | **MariaDB 11.7+**: the 5.0.0 schema uses `UUID_v7()` defaults (11.7). Tested on 11.8 LTS and 13.2; the gate says so |
| Version gate | **5.0.x only**; a newer minor is refused with a message naming the daemon version it needs (the shell's `required_rest_daemon_version` is 26.10.0) |
| Daemon id | `router_id` becomes **`rest_daemon_id`, a UUID** (config, `--setup`, the keyring's reader variable, JWT `instance_id`); `--setup` account names drop the id (`mariadb_restd_<random>`, 32-character limit) |
| Ids on the wire | user ids as **canonical UUID text** (`/authentication/status`, the script API, routine ownership parameters); `vendorId` keeps `0x…` (the SDKs and the landing page compare it) |
| Status counters | renamed to the spec's `mariadb…` names **and** `statusVariables` published in `rest_daemon.attributes` |
| Schema name | a plugin option and a `--setup` option, default `mariadb_rest_service`, prefix/postfix validated; roles derived from it; no auto-discovery |

### Phase M3.0: delete v2/v3 schema support (still on 4.1.6) ✅ done (2026-10-13)
- The v2/v3 query variants, factories and `SupportedMrsMetadataVersion` 2/3; the
  `schema_version` fallback; the version-specific tests. Fix `WHEREa.id` in the
  row-ownership SQL on the way.

### Phase M3.1: bake the suite's SQL rewrites into the tests (still on 4.1.6) ✅ done (2026-10-13)
- The MySQL-only SQL of the upstream scripts and fixtures rewritten in the files
  (`mrstest/mariadb_sql.py`'s rules), results re-recorded on MariaDB, the rewrite and
  most of the normaliser retired. A clean baseline for the 5.0.0 diff.

### Phase M3.2: central schema and role names (still on 4.1.6) ✅ done (2026-10-13)
- The options, the validation, one accessor used by every statement; default still the
  old name.

### Phase M3.3: UUID spike, then type-driven id reading (still on 4.1.6) ✅ done (2026-10-13)
- Spike on MariaDB 11.8.9 (Ubuntu and macOS packages) and 13.2 (macOS build):
  - A `UUID` column arrives as 36-character text (`MYSQL_TYPE_STRING`, length 144, the
    connection charset, `BINARY_FLAG` set); `BINARY(16)` is `MYSQL_TYPE_STRING`, length
    16, charset 63. **The charset number tells them apart, not the flag.**
  - `HEX(id)` and `CAST(id AS BINARY(16))` give the canonical byte order; a 16-byte
    literal `X'…'` in canonical order matches a `UUID` column (the swapped order does
    not), as do the dashed text, the undashed hex text and `UNHEX()`.
  - `BINARY(16)` owner columns compare, join and `IN` against `UUID` ids in both
    directions without a cast; `GROUP_CONCAT(HEX(id))` is unchanged; `UUID_v7()` works;
    a `?` bound as text matches a `UUID` column.
  - `LAST_INSERT_ID()` is 0 for a `UUID DEFAULT UUID_v7()` key (not relied on).
- Decision: **binding stays `X'…'` everywhere** (metadata ids and owner columns alike), so
  the planned split between metadata binding and owner rendering is not needed.
- Reading: `UniversalId::from_cstr()` accepts 16 raw bytes, 36-character dashed text or
  32 hex digits; `helper::MySQLRow` converts a `UniversalId` by the field's charset
  (text charset → parsed text, charset 63 or no field metadata → raw bytes), so the 32
  `unserialize_with_converter(…, from_raw)` sites became `unserialize(&id)`. The readers
  without field metadata (`query_one` in the object loader, the user-group set, the
  sequence id) go by the data size. Unit tests for both paths.

### Phase M3.4: switch to 5.0.0 (atomic)
- Renames, audit dispatch, default name, gate, `rest_daemon_id`, status columns; the
  test assets (schema script, includes, conftest, mocks, live-test fixtures) and a full
  re-record; smoke test on the shell repo's deployment script.

### Phase M3.5: wire formats and texts
- User ids on the wire, the raw-bytes role id bug, counters + `statusVariables`,
  messages, README.

### Phase M3.6: Galera-safe audit polling
- An overlap window by id and `changed_at` (clock-skew margin), a set of processed ids,
  best-effort `wsrep_sync_wait`.

## Open point: GTID read-your-writes on MariaDB (Milestone 4)

`readOwnWrites`, `_metadata.gtid` and the `$asof` filter are built on MySQL's GTIDs
(`session_track_gtids`, `gtid_executed`, `WAIT_FOR_EXECUTED_GTID_SET`); MariaDB's differ
(`domain-server-sequence`, `last_gtid`, `MASTER_GTID_WAIT`). On MariaDB the daemon refuses
`asof` with a clear error. The MariaDB shell and plugins carry the same open point
("unverified on MariaDB"); it is solved, if needed, in the three repositories together.
It only matters for deployments with read-only replicas.

## Open point: JSON columns on MariaDB (review after Milestone 3)

MariaDB's `JSON` is a `longtext` with a column-level `json_valid` check, and the 4.1.6
metadata schema records it as `longtext` (`COLUMN_TYPE`). The daemon then writes a JSON
*string* value unquoted and the check rejects it (arrays, objects, numbers, `null` and
reads work; see docs/mariadb-differences.md; the live tests `DatabaseQueryPut/Post.special_types`
fail on it). Candidate fixes:
- metadata schema (preferred): `table_columns_with_references` reports `json` when the
  column has `CHECK_CONSTRAINTS` `LEVEL='Column'`, `CONSTRAINT_NAME=<column>`,
  `CHECK_CLAUSE='json_valid(`<column>`)'`; plus the shell's fallback `query_plain_columns()`.
  Done in the shell and plugins together; view columns and objects created earlier
  (datatype stored in `db_column`) aren't covered;
- daemon: detect the same constraint when an object loads.
Review once the 5.0.0 schema (Milestone 3) is in, against that schema.

## Target repository layout

```
mrsd/
  CMakeLists.txt            top-level build
  cmake/                    build helpers (replacements for server macros)
  compat/                   replacements for client-library internals, Connector/C gaps
  extra/
    mysql-internals/        vendored header-only server headers
    rapidjson/  libcno/     vendored third-party
  src/                      router/src modules (same names as upstream)
    mrsd/                   new front end (main, config, Windows service)
  tests/                    helpers, component, mrs, mrs_client, data/ssl
  packaging/
  docs/                     PLAN.md, PROGRESS.md, inventories
  tools/analysis/           dependency analysis scripts
```

## Risks

| Risk | Status / mitigation |
|---|---|
| Stock client library lacks symbols Router needs | **Resolved in Phase 0:** 10 internal symbols, replaced by `compat/` |
| JIT library per platform | **Resolved:** the builder provides it through `MRS_JIT_EXECUTOR_LIB` (lib + headers); each platform's CI needs its own build of it |
| Windows build infrastructure (MSVC flags, DLL exports, OpenSSL/ICU) | Budget time in Phase 1. Resolved: builds and tests pass on the Windows VM; CI comes at the end |
| Hidden dependencies in test code (mock_server, test helpers) | Re-run `tools/analysis/include_closure.py --tests` after copying |
| Behaviour differences from replacing `my_gcvt` (JIT number formatting) | **Done:** vendored `strings/dtoa.cc` in `mrsd_compat` |
| Two OpenSSL copies in one process (Milestone 1: libmysqlclient's bundled OpenSSL vs the system's) | **Moot since 2026-10-13:** Connector/C is built against the same OpenSSL the daemon links |
| `mrsd_compat` is a static library linked into several shared libraries (harness, router_mysql, jit plugin) | Stateless code, so harmless; could become a shared library later |
| Component tests need `mysql_server_mock`, which needs duktape (removed upstream; public upstream builds skip the mock and all component tests, `IF(NOT TARGET duktape) RETURN()`) | Open, Phase 2 |

## Decision log

- 2026-09-30: fork MRS only; no history; MySQL 9.x client; JIT in; InnoDB Cluster
  out; X protocol out; platforms Linux/Windows/macOS; tests move to gtest.
- 2026-09-30: cut `routing`/`metadata_cache` in Phase 1 (not Phase 3), because with
  InnoDB Cluster out of scope, MRS needs only a static destination list.
- 2026-09-30: drop `connection_pool` (it depends on routing headers and isn't used by MRS).
- 2026-09-30: JIT via `-DMRS_JIT_EXECUTOR_LIB=<dir>` (lib + headers); client library from `-DMYSQL_PACKAGE_DIR=<server package>`.
- 2026-09-30: keep ICU. Upstream replaced std::regex with ICU for URL-matching speed (Bug#36797250: 330 → 173 ns/iter).
- 2026-09-30: MRS backend destinations via `mysql_read_write_destinations` /
  `mysql_read_only_destinations` plus `mysql_ssl_*` options (Phase 1.5).
- 2026-09-30: the upstream CMake files are kept almost unchanged; `cmake/compat/`
  supplies the server macros. The CMake project name stays `MySQLRouter` until
  the Phase 3 rename.
- 2026-09-30: version starts at the fork point, 26.10.0 (`VERSION` file).
- 2026-09-30: copyright notices follow the mariadb-shell recipe: `.githooks/pre-commit`
  (copied from the shell project) adds or refreshes a `MariaDB plc.` notice on every
  committed file (below the Oracle notice, or a full GPLv2 block for new files).
  `cmake/git_hooks.cmake` links the hook at configure time. Vendored third-party
  code is excluded in `.githooks/copyright-exceptions`.
- 2026-09-30: work is committed to the local repository in
  `<dev>/mysql/mrsd` until the final remote repository exists.
- 2026-09-30: `vio_io_wait()` (internal struct Vio) replaced by `poll()` on the
  public `NET::fd` in `MySQLSession::has_data_on_socket()`.
- 2026-09-30: step 1.7 (mock server) moved to Phase 2 because of the duktape dependency.
- 2026-09-30: component tests keep 17 suites; cases exercising removed features
  are excluded by name via GTEST_FILTER (`tests/component/excluded_cases.cmake`)
  so the upstream test sources stay unchanged. `rest_api_enable`, `user_option`
  and `test_mock_server` dropped.
- 2026-09-30: MTR suite → pytest harness interpreting the mysqltest subset,
  golden `.result` files kept.
- 2026-10-05: `tests/integration` removed. All 11 files (`test_routing_*`) test
  the routing plugin and connection pool (`[routing:...]`, `[connection_pool]`,
  `rest_routing`) and link the X protocol client; none touch MRS. Testing mrsd
  against a real `mysqld` is the MRS functional suite (`tests/mrs`).
- 2026-10-05: CI waits for the final remote repository and is the last step of the
  work (Phase 4). Phase 2 closed with the test suites passing on the three platforms
  in local runs.
- 2026-10-05: names: program `mariadb-mrsd`, product "MariaDB REST Service Daemon"
  (the final name may still change, hence one place in `cmake/settings.cmake`; tests,
  the pytest harness and the smoke test derive the names from the build). CMake
  target names stay the router's (internal). Config sections and log domains kept.
- 2026-10-05: `--setup` design: options without the `mrs-` prefix; directory
  deployment only for now; MRS metadata registration as upstream except
  `product_name`/`version` (MySQL Shell doesn't read them).
- 2026-10-05: `--setup` is handled in `main.cc` (first argument) by `MrsdSetup`
  (`src/router/src/mrsd_setup.cc`), not by the router app; upstream's
  `bootstrap_mysql_account.cc` is reused as is. `--force` re-runs reuse the accounts
  and JWT secret of the existing deployment (from its keyring) so no accounts are
  orphaned; upstream instead skipped the MRS configuration when the section existed.
  The generated account is `<program name with _>_<router id>_<random>`. The tests
  `bootstrap_mrs_*` are replaced by `setup_mrs_name`, `setup_mrs_default_name` and
  `setup_mrs_errors`; the smoke test configures mrsd with `--setup`.
- 2026-10-05: Windows MSI deferred (no WiX on the build VM); ZIP only for now. rpm
  packages are built and tested on a Fedora VM (<fedora-vm-ip>).
- 2026-10-07: program renamed `mariadb-mrsd` -> `mariadb-restd` (executables, config/log/key
  file names, service and service account, package names, generated MRS account prefix
  `mariadb_restd`). Product name unchanged. Internal identifiers (`MRSD_*` CMake variables,
  `MrsdSetup`, the repository name) are unchanged.
- 2026-10-07: final repository: `github.com/mariadb-corporation/rest-daemon` (private);
  the local history (all commits of `<dev>/mysql/mrsd`) moved to the clone
  in `<dev>/rest-daemon`. The VM clones (`<dev>/mrsd` on the Ubuntu and
  Fedora VMs, `<win-home>\mrsd` on Windows) stay as build/test clones.
- 2026-10-07: the JIT executor library build (`ext/polyglot` of the MySQL Shell sources)
  is part of this repository, same path, copied verbatim; `MRS_JIT_EXECUTOR_LIB` stays the
  way to point the build at its output.
- 2026-10-07: Milestone 1 (standalone daemon) declared complete: the daemon is
  verified on all three platforms. Phase 4 (packaging and CI) moves to a final
  Milestone 3; Milestone 2 (MariaDB) starts now.
- 2026-10-07: Phase M2.0 (MariaDB inventory) done, verdict GO in stages; phases M2.1-M2.4
  defined. Open decisions (inventory §5): dual MySQL/MariaDB build, Connector/C source,
  minimum MariaDB version, async tasks, GTID/asof, MRS scripts, setup auth plugin.
- 2026-10-08: Milestone 2 decisions: keep the MySQL build during the port; MariaDB
  Connector/C from a package; minimum server MariaDB 10.11 (develop on 13.2); REST async
  tasks and GTID/"asof" disabled on MariaDB and moved to a new Milestone 3; `--setup`
  creates accounts with MariaDB's default auth plugin. Packaging and CI become Milestone 4.
- 2026-10-08: MRS scripts stay in Milestone 2 (smoke test incl. scripts on MariaDB); the
  shell-side `LOAD SCRIPTS` is pure Python and unchanged in the MariaDB plugin port.
- 2026-10-12: Milestone 2 targets the metadata schema on the main branches of the MariaDB
  shell and plugins (4.1.6). The renamed schema 5.0.0 (`mariadb_rest_service`, work in
  progress on their branches) becomes Milestone 3; async tasks and GTID/"asof" move to
  Milestone 4, packaging and CI to Milestone 5.
- 2026-10-12: REST async tasks (`mysql_tasks`) are removed from the product, matching the
  MariaDB shell plugins (routines are always called directly); the code goes in Phase M2.4.
  Milestone 4 keeps GTID/"asof" only.
- 2026-10-12: GTID/"asof" on MariaDB is an open point, not a milestone, like in the
  MariaDB shell and plugins; solved in the three repositories together if needed.
  Packaging and CI are Milestone 4 again.
- 2026-10-12: JSON-string writes to MariaDB JSON columns (datatype `longtext` in the
  metadata) are an open point, reviewed after Milestone 3 (schema 5.0.0).
- 2026-10-13: the REST async-task code is removed from both builds (M2.4); the
  `mysqlTask` options in existing metadata are ignored, not rejected.
- 2026-10-13: the MySQL build and MySQL server support are dropped. MariaDB Connector/C
  becomes the only client library and a MariaDB server the only supported server; the
  libmysqlclient build, the `is_mariadb()` runtime branches and the MySQL modes of the
  test suites and smoke test go. Restore point: tag `m2-pre-build-decision` and the
  bundle `<dev>/rest-daemon-backups/rest-daemon-2026-10-13-m2-pre-build-decision.bundle`.
- 2026-10-13: GTID/"asof" becomes Milestone 4, after the schema upgrade, shared with the
  shell and plugins; its code is left in place (not deleted with the MySQL support).
  Packaging and CI are Milestone 5.
- 2026-10-13: Milestone 2 closed. The final smoke-test rerun was skipped by decision (the
  Mac's shell build already targets 5.0.0; Ubuntu passed after the MySQL removal).
  Milestone 3 (schema 5.0.0) starts: 5.0.0 is on the main branches of the MariaDB shell
  (deployment script `mariadb_rest_service_deployment_5.0.0.sql`) and plugins.
- 2026-10-13: Milestone 3 plan reviewed and approved: a UUID spike before the id work; the
  suite's SQL rewrites baked in before the schema switch; `rest_daemon_id` (UUID), user
  ids on the wire as UUID text, `vendorId` as `0x…`, counters renamed + `statusVariables`,
  gate 5.0.x only. Minimum server for 5.0.0 is MariaDB 11.7 (`UUID_v7()`).
