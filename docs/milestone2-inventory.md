# Milestone 2, Phase M2.0: MariaDB dependency inventory

**Date:** 2026-10-07 · **Code analysed:** rest-daemon `main` (Milestone 1 complete) ·
**MariaDB side:** server `main` 13.2.0 (`<dev>/mariadb-server`, Connector/C 3.4.10
in `libmariadb/`), MariaDB Shell plugins (`<dev>/mariadb-shell-plugins`, MRS
metadata schema 4.1.6), MariaDB Shell port (`<dev>/shell`, `MARIADB_PORT.md`).

**Verdict: GO, in stages.** The client-library switch is mechanical (8 missing functions,
9 missing options, a handful of enums). The server-side differences are the real work and
fall into five areas: JSON document generation, GTID tracking ("asof"), the `mysql_tasks`
async-task framework, account/role setup, and the test infrastructure. The MRS metadata
schema itself is already ported (schema 4.1.6 in the MariaDB shell plugins).

Four surveys were made (client API, SQL, metadata schema, tests); this file keeps their
results. `file:line` references are relative to `src/` unless noted.

---

## 1. What already exists on the MariaDB side

- **MRS metadata schema 4.1.6** (`mariadb-shell-plugins/mrs_plugin/db_schema`): same schema
  name `mysql_rest_service_metadata`, same tables, views, procedures, triggers, events and
  roles as MySQL's 4.1.5. The 4.1.6 release holds all MariaDB changes: `->`/`->>` rewritten
  as `JSON_EXTRACT`/`JSON_UNQUOTE`, `INVISIBLE` index dropped, `UUID_TO_BIN_SWAP`/
  `BIN_TO_UUID_SWAP` helpers with a fallback in `get_sequence_id()`, a stored
  `JSON_STORAGE_SIZE`, `table_columns_with_references` branching on `@@version LIKE '%MariaDB%'`,
  audit-log triggers writing `BINARY(16)` as hex and booleans as `IF(col,1,0)`. The
  `4.1.5_to_4.1.6` update script is empty; MariaDB deployments are fresh 4.1.6 deployments.
  The daemon's version check is major-only (`kCurrentMrsMetadataVersion{4,0,0}`,
  `mrs/database/query_version.h:88`), so 4.1.6 is accepted.
- **No `mysql_tasks` schema** in the MariaDB plugins; `general.configure()` skips it when
  `server_vendor == "MariaDB"`. A placeholder role `mysql_task_user` is created.
- **MariaDB Shell** links a static `libmariadbclient.a` built from the server tree with
  `-DCONC_WITH_SSL=OPENSSL` (Connector/C defaults to GnuTLS on Linux/macOS); recipe in
  `shell/CMakeLists.txt` and `cmake/bootstrap_mariadb.cmake`. It has no JavaScript (no
  GraalVM), so nothing on the shell side exercises MRS scripts on MariaDB.
- **Plugin ↔ router contract** (`mrs_plugin/lib/routers.py`): the plugin reads `router`
  (`last_check_in`, `attributes`, `options->$.developer`) and `router_services`, deletes
  `router` rows, and never touches `router_status`, `router_general_log`, `router_session`.
  `REQUIRED_ROUTER_VERSION = 8.1.0` is informational only.
- **No MRS documentation for MariaDB** exists yet (`mariadb-docs` has no hits).
- Local resources: MariaDB 13.2.0 Release build in `mariadb-server/light-build`
  (`sql/mariadbd`, `libmariadb/libmariadb/libmariadbclient.a`, `CONC_WITH_SSL=OPENSSL`),
  built shell in `shell/bld/bin/mariadb-shell`.

## 2. Client library: libmysqlclient → MariaDB Connector/C 3.4

Checked against `libmariadb/include/{mysql.h,mariadb_com.h,mariadb_stmt.h,errmsg.h,mysqld_error.h}`
and the export lists in `libmariadb/libmariadb/CMakeLists.txt`.

| Category | Used | Same | Different | Missing |
|---|---|---|---|---|
| `mysql_*` functions | 57 | 47 | 2 (`mysql_library_init/end` are macros) | 8 |
| `mysql_options` enumerators | 46 | 36 | — | 9 in code |
| `enum mysql_ssl_mode` / `SSL_MODE_*` | 1 type, 5 values | — | — | all |
| `MYSQL_TYPE_*` | 35 | 30 | 2 (JSON, VECTOR never sent by the server) | 3 |
| `CLIENT_*` flags | 5 | 4 | — | 1 |
| `CR_*` | 8 | 5 | — | 3 |
| `ER_*` | 20 | 11 | 2 | 7 |
| Client headers | 7 | 3 | 1 | 3 |

### 2a. Missing functions

| Function | Used in | Replacement |
|---|---|---|
| `mysql_real_query_nonblocking`, `mysql_store_result_nonblocking`, `mysql_next_result_nonblocking` | `router/src/common/mysql_session.cc:573-630`; consumer `mrs/.../mysql_task_monitor.cc:116-156` (`execute_nb`, async tasks) | MariaDB `mysql_*_start`/`_cont` coroutine API: `MYSQL_OPT_NONBLOCK` on the handle, keep the `MYSQL_WAIT_*` status between calls |
| `mysql_get_ssl_session_reused`, `mysql_get_ssl_session_data`, `mysql_free_ssl_session_data`, `MYSQL_OPT_SSL_SESSION_DATA` | `mysql_session.cc:75-109,1089` (`SSLSessionsCache`) | No TLS session resumption in C/C 3.4: drop the cache (performance only) |
| `mysql_real_escape_string_quote` | `mysql_session.cc:1066` (`quote()`, all callers use `'`) | `mysql_real_escape_string` |
| `mysql_bind_param` (query attributes) | `jit_executor/src/database/session.cc:186-204` | No server support; `#ifdef` out, JS query attributes become a no-op |

Present but no-ops: `mysql_thread_init/end`. `mysql_library_init/end` are macros for
`mysql_server_init/end`.

### 2b. Options and enums to remove or emulate

- **`MYSQL_OPT_SSL_MODE` and `enum mysql_ssl_mode`**: missing. The type is used in
  `mysqlrouter/mysql_session.h`, `counted_mysql_session.h`, `mrs/interface/ssl_configuration.h:37`,
  `mysql_rest_service_plugin_config.cc:119-178`, `router/src/mrsd_setup.cc:272,593` and the
  mock server (8 sites). Replace with a project enum and emulate with `MYSQL_OPT_SSL_ENFORCE`
  and `MYSQL_OPT_SSL_VERIFY_SERVER_CERT`. Notes: C/C 3.4 verifies the server certificate by
  default; setting a CA or CRL turns verification on; VERIFY_CA without a hostname check
  needs `MARIADB_OPT_TLS_VERIFICATION_CALLBACK`; the mode can't be read back with
  `mysql_get_option`, so store it in `MySQLSession`.
- Aliases in `mysqlrouter/mysql_session.h:197-242` instantiated with missing enumerators
  (compile errors): `MYSQL_OPT_TLS_CIPHERSUITES` (use `MYSQL_OPT_SSL_CIPHER`, which covers
  TLS 1.3 in libmariadb), `MYSQL_OPT_SSL_FIPS_MODE`, `MYSQL_OPT_COMPRESSION_ALGORITHMS`,
  `MYSQL_OPT_GET_SERVER_PUBLIC_KEY`, `MYSQL_OPT_LOAD_DATA_LOCAL_DIR`,
  `MYSQL_OPT_OPTIONAL_RESULTSET_METADATA`, `MYSQL_OPT_RETRY_COUNT`.
- `MYSQL_TYPE_BOOL`, `MYSQL_TYPE_INVALID`, `MYSQL_TYPE_TYPED_ARRAY`
  (`helper/mysql_column_types.cc:40,127-128,203-223`): drop.
- `CLIENT_LONG_PASSWORD` (`mysql_session.cc:399`): bit 0 is `CLIENT_MYSQL` in libmariadb; drop.
- `MYSQL_BIND::is_null` is `my_bool*` (`char*`), not `bool*`: `mysql_session.cc:800-810`,
  `mrs/database/helper/bind.{cc,h}:53,90`, `jit_executor/.../query_attributes.h:83`.
- `CR_ERROR_FIRST`/`CR_ERROR_LAST` (`compat/src/client_errors.cc:141`, `collector/mysql_cache_manager.cc:139`,
  `mysql_fixed_pool_manager.cc`, `mysql_task_monitor.cc:134`): use `CR_MIN_ERROR`/`CR_MAX_ERROR`
  and include MariaDB's own client errors 5000-5027. `CR_NO_RESULT_SET` (`mysql_session.cc:838`): remove.
- `SESSION_TRACK_GTIDS` and `SESSION_TRACK_SYSTEM_VARIABLES` exist, but the server never
  sends GTID tracking (see §3b).

### 2c. Headers, compat/, CMake

- `mysql_com.h`, `field_types.h`, `mysql_time.h`, `mysql_version.h` are not shipped by C/C
  (only used by `jit_executor/.../query_attributes.{h,cc}` and `database/session.cc:29`):
  include `<mysql.h>` instead. `mysqld_error.h` and `errmsg.h` exist with different content.
- `extra/mysql-internals/` (vendored server headers, incl. `dtoa.cc`) has no client
  dependency and stays. Possible typedef clashes (`uint`, `ulong`, `uchar`) to check at build time.
- `compat/src/client_errors.cc` (copy of MySQL's `client_errors[]`): libmariadb exports
  `client_errors[]`, `mariadb_client_errors[]` and `ER()`; replace the copy.
  `compat/src/charset.cc` (collation id → mbmaxlen table from MySQL ids): use
  `mariadb_get_charset_by_nr(nr)->char_maxlen`; MariaDB ids differ above ~247 and UCA-14
  collations use ids ≥ 2048.
- `cmake/compat/mysql_package.cmake` requires `mysql_version.h` and `MYSQL_VERSION_ID ≥ 90000`
  and finds `mysqlclient`; libmariadb is `libmariadb.so.3`/`.dylib`/`.dll` (static `mariadbclient`),
  headers under `include/mariadb/`. Needs a new finder (Connector/C package, `mariadb_config`,
  or the server build tree as the shell does). Consumers: `CMakeLists.txt:74,114,167-168,196`,
  `src/harness/src/CMakeLists.txt:36-37` (`router_mysqlclient` INTERFACE), `compat/CMakeLists.txt:40`,
  `cmake/packaging.cmake:87-90`, `cmake/bundle_runtime_libraries.cmake:114`.
- Packaging: C/C's `caching_sha2_password`, `sha256_password`, `client_ed25519`, `parsec` and
  `dialog` client auth plugins are dynamic by default; bundle the plugin dir and set
  `MYSQL_PLUGIN_DIR`. Only `mysql_native_password` and `mysql_clear_password` are built in.
- `src/mysql_protocol` and `src/mock_server` implement the classic protocol themselves with
  no client-header dependency except `mysql_ssl_mode` (mock) and two `ER_*` codes (same in
  MariaDB). They encode MySQL-only features (query attributes, zstd, optional metadata,
  GTID session-track) and don't decode MariaDB extended capabilities, the `5.5.5-` prefix,
  `COM_STMT_BULK_EXECUTE`, extended metadata, or ed25519/parsec auth. Only relevant if the
  mock should emulate a MariaDB server.

## 3. SQL and server features (production code)

About 150 SQL literal lines in 48 files, ~110 statement templates. No `information_schema`,
`performance_schema` or `mysql.*` queries at all.

### 3a. Missing on MariaDB

| Item | Sites | Replacement |
|---|---|---|
| `->` / `->>` (~40 sites) | `mrs/database/query_entries_object.cc:114,171-179,216-219,404-411,450-464`; `query_entry_fields.cc:75-78,102-105` | `JSON_UNQUOTE(JSON_EXTRACT())` / `JSON_VALUE`; `JSON_EXTRACT` |
| `CAST(? AS JSON)` | `helper/sp_function_query.cc:267`; `include/helper/sqlstring_utils.h:51`; `sp_function_query.h:83`; `endpoint/handler/handler_db_object_table.cc:166`; `query_rest_task.cc:81,185,259,506` | `JSON_COMPACT()`/`JSON_EXTRACT(x,'$')`, or rely on the JSON string passing through |
| `STRING_TO_VECTOR`, `VECTOR_TO_STRING` | `json_mapper/select.cc:85,110,246`; `json_mapper/change.cc:430`; `filter_object_generator.cc:109,111`; `sp_function_query.cc:169,264`; `sqlstring_utils.h:48`; `handler_db_object_table.cc:156`; `query_rest_task.cc:87` | `VEC_FromText` / `VEC_ToText` (MariaDB 11.7+) |
| `UUID_TO_BIN(UUID(),1)` | `json_mapper/insert.cc:43` | own expression (the schema's `UUID_TO_BIN_SWAP` is only defined in the metadata schema) |
| `INSERT ... AS new ON DUPLICATE KEY UPDATE c=new.c` | `json_mapper/insert.cc:145-148` | `VALUES(c)` |
| `SET @@SESSION.session_track_gtids="OWN_GTID"` (every RW pool connection fails) | `collector/mysql_cache_manager.cc:123` | `session_track_system_variables='last_gtid'` |
| `@@GLOBAL.gtid_executed`, `GTID_SUBSET()`, `WAIT_FOR_EXECUTED_GTID_SET()` | `mrs/database/helper/query_gtid_executed.cc:55,72,81`; `filter_object_generator.cc:295` | `@@gtid_binlog_pos`/`@@gtid_current_pos`, `MASTER_GTID_WAIT()`; MariaDB GTIDs are `domain-server-seq`, the parser in `database/helper/gtid.h:375-451` assumes `uuid:range` |
| `SESSION_TRACK_GTIDS` reads | `mrs/monitored/gtid_functions.cc:52`; `jit_executor/src/database/session.cc:291-296` | `last_gtid` via `SESSION_TRACK_SYSTEM_VARIABLES` |
| `SET ROLE ALL` | `collector/mysql_fixed_pool_manager.cc:121` | MariaDB activates one role; use the granted role name |
| `SET DEFAULT ROLE ALL TO u` | `router/src/bootstrap_mysql_account.cc:456` | `SET DEFAULT ROLE r FOR u` (one role) |
| `CREATE USER ... IDENTIFIED WITH caching_sha2_password BY` | `bootstrap_mysql_account.cc:395,413` | `IDENTIFIED VIA <plugin> USING PASSWORD()`; server plugins available: `mysql_native_password`, `ed25519`, `parsec`, `caching_sha2_password` (`plugin/auth_mysql_sha2`, dynamic) |
| "user exists" note 3163 + regex `'u'@'(.*?)'` | `bootstrap_mysql_account.cc:125-196` | MariaDB emits note 1973 `ER_USER_CREATE_EXISTS`; unmatched, pre-existing accounts would be treated as new and **dropped on cleanup** |
| `@@super_read_only` | `monitor/schema_monitor.cc:107` | only `@@read_only` |
| `offline_mode` handling (`ER_SERVER_OFFLINE_MODE[_REASON]`) | `schema_monitor.cc:451-452,502-503` | no such mode; drop |
| `ps_current_thread_id()` | `query_rest_task.cc:417` | `sys.ps_thread_id(NULL)` if `sys` installed (part of `mysql_tasks`, see §3d) |
| Version gate: major ≥ 8 and comment "MySQL"/"Source distribution" | `router/src/common/server_compatibility.cc:34-45`; callers `mysql_rest_service_plugin.cc:138,157`, `mrsd_setup.cc:633` | **rejects MariaDB at startup and in `--setup`**; accept "MariaDB" |
| MySQL-only `ER_*` constants | `ER_ROLE_NOT_GRANTED` (`mysql_rest_service_plugin.cc:81,141,160` → 1959 `ER_INVALID_ROLE`), `ER_CHECK_CONSTRAINT_VIOLATED` (`handler_authorize_user.cc:93` → 4025 `ER_CONSTRAINT_FAILED`), `ER_LOCK_NOWAIT` (`query_rest_table_updater.cc:165` → 1205), `ER_QUERY_TIMEOUT` (`handler_db_object_table.cc:268` → 1969 `ER_STATEMENT_TIMEOUT`), `ER_GTID_MODE_OFF` (`rest/rest_request_handler.cc:645`), `ER_USER_ALREADY_EXISTS` (3163), `ER_SERVER_OFFLINE_MODE_REASON` | map or drop |

### 3b. Differs, needs verification on a server

- **JSON document generation**: the REST read path nests `JSON_OBJECT`/`JSON_ARRAYAGG`/`COALESCE`
  subqueries, `ST_AsGeoJSON` and `x is true` inside `JSON_OBJECT` (`query_rest_table.cc:404-426`,
  `query_rest_table_single_row.cc:110-135`, `json_mapper/select.cc:82,105,183-203,242`,
  `json_mapper/select.h:104`). MariaDB types JSON per item: subquery results and strings may
  come out as escaped strings instead of nested documents. This is the biggest functional risk
  and must be measured first.
- **JSON result columns**: MariaDB sends JSON columns as `LONGTEXT` (`MYSQL_TYPE_BLOB`), never
  `MYSQL_TYPE_JSON`. Detection in `helper/mysql_column_types.cc:40-78,105-240`,
  `helper/mysql_row.h:203`, `mrs/json/json_template_nest.cc:138`,
  `jit_executor/src/database/result.cc:66-120,449-481`. Use Connector/C extended metadata
  (`mariadb_field_attr(MARIADB_FIELD_ATTR_FORMAT_NAME)` = "json", `DATA_TYPE_NAME` = "vector",
  server `field.cc:7531`). `column_datatype_converter.h:45-88` has no `UUID`/`INET4`/`INET6`.
- `ST_GeomFromGeoJSON(?,1,?)` with SRID argument (`filter_object_generator.cc:157`,
  `sp_function_query.cc:162`, `json_mapper/change.cc:427`); SRID 4326 axis order differs.
- `/*+ MAX_EXECUTION_TIME(?) */` (`query_rest_table.cc:404,488,518`, `query_rest_table_single_row.cc:131`):
  supported by MariaDB 13.2 (`sql/opt_hints.cc:44`), check the minimum version; timeout error is 1969.
- `SELECT ... FOR UPDATE NOWAIT`: supported, error code 1205 instead of 3572.
- `SET @@SESSION.sql_mode=DEFAULT` (`mysql_cache_manager.cc:116`): different default; MariaDB
  does not report `sql_mode` through session tracking.
- `mysql_change_user()` for MySQL-account auth (`mrs/authentication/mysql_handler.cc:94-101`):
  accounts with `ed25519`/`parsec` need the C/C client plugins.
- Prepared `CALL` with OUT params (`mysql_session.cc:731-840`, `query_rest_sp.cc:206,228`).
- `compat/src/charset.cc` collation table (see §2c).
- Pre-existing bug independent of the server: `WHERE` + `a.id` concatenated without a space
  in `query_rest_table.cc:199-200,326-327`.

### 3c. Fine as is

`WITH RECURSIVE`, `MATCH ... AGAINST`, `JSON_MERGE_PATCH/PRESERVE`, `JSON_SET/REMOVE/EXTRACT/VALID`,
`JSON_VALUE`, `JSON_CONTAINS`, `GROUP_CONCAT`, `TO_BASE64`, `KILL [QUERY]`, `START TRANSACTION
WITH CONSISTENT SNAPSHOT`, `mysql_reset_connection`, `CLIENT_FOUND_ROWS`, `INSERT ... ON DUPLICATE
KEY UPDATE` (`schema_monitor.cc:344`, `mrsd_setup.cc:815`), `SET ROLE <one role>`, `SHOW WARNINGS`,
`DROP USER IF EXISTS`, `GRANT role TO user`. Dead code: `helper/query_table_columns.cc`
(`SHOW COLUMNS`, `show_gipk_...`), `query_warnings.cc`.

### 3d. `mysql_tasks` (REST async tasks)

`query_rest_task.cc:284-544` and `query_rest_task_status.cc:46` call `mysql_tasks.*` procedures
and functions (`execute_prepared_stmt_from_app_async`, `create_app_task_with_id`,
`start/stop_task_monitor`, `add_task_log`, `kill_app_task`, `app_task_status_brief`,
`extract_username`), rely on server `EVENT`s created by that schema, `ps_current_thread_id()`,
and the non-blocking client API (`mysql_task_monitor.cc`). The MariaDB plugins do not deploy
`mysql_tasks`. Options: port the `mysql_tasks` schema (plugin work) and the daemon side, or
disable REST async tasks on MariaDB.

### 3e. MRS scripts (JIT)

`getSession()` hands scripts the pooled connection, which inherits the initial SQL
(`sql_mode`, `SET ROLE`, `session_track_gtids`). `runSql()` is pass-through
(`objects/polyglot_session.cc:44-117`, `database/session.cc:207`); result typing uses the
`MYSQL_TYPE_JSON` detection above and GTIDs from `SESSION_TRACK_GTIDS`. The MariaDB shell has
no JavaScript, so `CREATE REST CONTENT SET ... LOAD SCRIPTS` on MariaDB is untested.

## 4. Tests and tools

- **`tests/mrs`** (pytest port of the mtr suite, 122 tests): starts `$MYSQL_PACKAGE_DIR/bin/mysqld`
  with `--initialize-insecure`, `--gtid-mode=ON --enforce-gtid-consistency=ON --mysqlx=OFF`, ~30
  `performance_schema` consumer options; `reset()` relies on `gtid_executed`/`server_uuid`,
  MySQL system accounts (`mysql.session`, `mysql.sys`, `mysql.infoschema`) and
  `RESET BINARY LOGS AND GTIDS`. The metadata schema comes from the repo dumps
  `tests/mrs/include/schema/mrs_metadata_schema-version{2,3,4}.sql` (v4 = MySQL 4.0.x, with
  `utf8mb4_0900_ai_ci`, `INVISIBLE`, `JSON_TABLE`, `->>`, `UUID_TO_BIN`, `CREATE EVENT`, roles);
  a MariaDB run needs the 4.1.6 deployment script instead. Fixtures use `GEOMETRY ... SRID`,
  `ST_GeomFromText`, `VECTOR`, `caching_sha2_password`, `CREATE ROLE ... GRANT role TO role`.
  Tests touching MySQL-only features: GIS 5, VECTOR 5, GTID/asof 13, `super_read_only` 2,
  `performance_schema` 2, `mysql_no_login`/`auth_socket` 2.
- **Live-DB unit tests** (`src/mysql_rest_service/tests`, `RUN_WITH_LIVE_MYSQLD`,
  `tests/helpers/shared_server.cc`): `bin/mysqld`, `share/`, `lib/plugin`, GTID options,
  fixtures with `utf8mb4_0900_ai_ci` and `GEOMETRY`; helpers for `caching_sha2_password`/
  `sha256_password` users, `INSTALL PLUGIN`, OpenID Connect config, `performance_schema.processlist`.
- **Component tests** use only `mysql_server_mock`; the MRS-related ones (`test_mrs_config`, 3
  tests) answer `SELECT substring_index(@@version,'.',1), concat(@@version_comment,@@version)`
  with `["9","Source distribution mrs"]` (`tests/component/data/local_modules/common_statements.js`).
- **Smoke test** (`tools/smoke/run_smoke.sh`): `mysqld`, `mysql`, `mysqlsh` with the MRS plugin
  deployment scripts (`mysql_tasks` + `mysql_rest_service_metadata`), MRS DDL through the shell.
  A MariaDB variant needs `mariadbd`, `mariadb`, `mariadb-shell` with `mariadb-shell-plugins`.
- **`--setup`** (`router/src/mrsd_setup.cc`, `bootstrap_mysql_account.cc`) does not create the
  metadata schema (points to `CONFIGURE REST METADATA`); it inserts the `router` row and creates
  the accounts (§3a).
- CMake: `tests/CMakeLists.txt:71` bakes `MRSD_MYSQL_PACKAGE_DIR`; `tests/mrs` and the smoke test
  read `MYSQL_PACKAGE_DIR`; `tests/mrs` is not registered with CTest.
- Noticed in passing: `test_mrs_json_mapper_metadata.cc` is not in
  `src/mysql_rest_service/tests/CMakeLists.txt`; `tests/component/data/metadata_dynamic_nodes.js`
  referenced by `test_master_key_reader_writer.cc` is missing.

## 5. Open questions for the plan

1. **Keep the MySQL build?** Port behind a client/server abstraction so the MySQL build and
   its test suites stay green during the port (the shell's `MARIADB_BUILD` approach), or
   switch outright. Recommendation: keep MySQL buildable until the MariaDB suites are at
   parity, then decide.
2. **Connector/C source**: a Connector/C release package found by `mariadb_config`/pkg-config
   (public API only, matches the Milestone 1 rule), or the server build tree as the shell
   does. Recommendation: Connector/C package (`-DMARIADB_CONNECTOR_DIR`), built with OpenSSL.
3. **Minimum MariaDB server**: `JSON_SCHEMA_VALID` needs 11.1, `VEC_*` 11.7, the
   `MAX_EXECUTION_TIME` hint and `caching_sha2_password` are recent. Recommendation: 11.8 LTS
   minimum for the daemon, develop and test on `main` (13.2).
4. **REST async tasks** (`mysql_tasks`): disable on MariaDB in Milestone 2, port later?
5. **GTID / "asof"**: redesign around `last_gtid` + `MASTER_GTID_WAIT`, or disable in
   Milestone 2 (the RW-pool `SET` must be fixed either way).
6. **MRS scripts**: in scope on MariaDB (needs a shell/plugin that can `LOAD SCRIPTS`)?
7. **Account auth plugin** created by `--setup`: `mysql_native_password`, `ed25519`, `parsec`
   or `caching_sha2_password` (dynamic server plugin)?
