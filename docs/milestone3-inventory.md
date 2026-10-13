# Milestone 3 inventory: metadata schema 5.0.0

What the daemon has to change to serve the MariaDB REST Service metadata schema
5.0.0 (`mariadb_rest_service`), collected on 2026-10-13 at commit `d8e3fd2`.

Sources (read from the `main` branches, never from the working trees):
- shell: `.claude/context/rest-daemon-5.0.md` (the daemon spec) and
  `mysqlshdk/libs/mrs/db_schema/mariadb_rest_service.msm.project/releases/deployment/mariadb_rest_service_deployment_5.0.0.sql`
- plugins: `mrs_plugin/.claude/context/metadata-schema-5.0.0.md`

No compatibility with 4.x is needed: nothing of 5.0.0 was released before.

Abbreviations: `MRS` = `src/mysql_rest_service`, `DB` = `MRS/src/mrs/database`,
`INC` = `MRS/include`.

## Headline findings

- **SQL names the schema in string literals.** About 92 SQL lines in 26 files name
  `mysql_rest_service_metadata` (100 lines in 30 files with comments and messages). There
  is no central schema name.
- **Ids are read as 16 raw bytes everywhere.** `UniversalId::from_raw` copies 16 bytes,
  but MariaDB returns `UUID` columns as 36-character text, so every read breaks. Binding
  is central (`to_sqlstring` renders `X'hex'`).
- **User-table owner columns are `BINARY(16)`.** Row-ownership SQL compares them with
  `mrs_user.id`, which becomes `UUID`: the riskiest part.
- **`router_id` is a `uint64_t` end to end:** config, `--setup`, the keyring's `ROUTER_ID`
  variable, the account name, JWT `instance_id`, status and log writes.
- **v2/v3 schema support is still in the tree** and can be deleted first.
- **The client wire format stays `0x…` for vendor ids.** The SDKs and the 5.0 landing
  page compare `vendorId === "0x3000…"`.

## 1. Schema name (spec 1)

### Where the name is hard-coded

| Area | Lines | Notes |
|---|---|---|
| Production code | 100 in 30 files | biggest: `DB/query_rest_table.cc` 16, `query_entries_auth_privileges.cc` 11, `query_entries_object.cc` 10, `query_entry_fields.cc` 6, `src/router/src/mrsd_setup.cc` 5 |
| Unit tests | 16 | |
| Component mocks | 1 | |
| Smoke test | 3 | it looks for the plugins' `mysql_rest_service_metadata.msm.project`, which no longer exists; 5.0.0 is in the shell repo |
| `tests/mrs` | 2324 lines in 255 files | 145 of them are the echoed `DROP SCHEMA` of `include/mrs/cleanup.inc` |

### The new option

- **Plugin option:** `INC/supported_mysql_rest_service_options.h`,
  `MRS/src/mysql_rest_service_plugin_config.cc` (reading, default, prefix/postfix
  validation), `INC/mrs/configuration.h`.
- **`--setup` option:** `mrsd_setup.cc` (`write_config`, `check_mrs_metadata`,
  `create_accounts`). `--conf-set-option mysql_rest_service.*` is refused, so it needs
  its own option.
- **Roles:** derived from the schema name; used in `INC/collector/mysql_cache_manager.h`.
- **Central accessor:** one process-wide accessor, set at plugin start and by `--setup`.
  One daemon serves one schema.
- **Why not `USE <schema>`:** the row-ownership SQL (`query_rest_table.cc`,
  `query_user_groups.h`) runs on userdata connections, so the name must stay qualified.

## 2. Renames (spec 1a, 1b)

Every daemon SQL site:

| Old name | New name | Sites |
|---|---|---|
| `router` | `rest_daemon` (`router_name` → `name`) | `DB/monitor/schema_monitor.cc` (UPDATE `attributes`, self-INSERT … ON DUPLICATE KEY), `metadata_logger.cc:296-303`, `query_router_info.cc`, `query_entries_db_service.cc:68`, `mrsd_setup.cc` (insert, select id, `store_developer`, `store_account_metadata`) |
| `router_status` | `rest_daemon_status` | `query_statistics.cc:43-49`, plus the column renames in section 8 |
| `router_general_log` | `rest_daemon_general_log` | `metadata_logger.cc:51-52` |
| `router_services` | `rest_daemon_services` | `query_entries_db_service.cc:63-70` (`router_id` → `rest_daemon_id`) |
| `db_schema` | `rest_schema` | `query_entries_db_schema.cc` (alias `db_schema_id`), `query_entries_db_object.cc` |
| `db_object` | `rest_object` | `query_entries_db_object.cc` (aliases), `query_entries_object.cc` |
| `object` | `data_mapping` | `query_entries_object.cc`, `query_entry_fields.cc`, `query_changes_db_object.cc` |
| `object_field` | `data_mapping_field` | same three files |
| `object_reference` | `data_mapping_reference` | `query_entries_object.cc`, `query_changes_db_object.cc` (`kObjRefTableName`) |
| `mrs_db_object_row_group_security` | `mrs_rest_object_row_group_security` | `query_entry_group_row_security.cc:38-39` |
| `content_set_has_obj_def` | `content_set_has_rest_object` | `query_entries_db_object.cc:84-86` |

- **Not used by the daemon:** `router_session`.
- **Audit-log dispatch by `table_name`:**
  - `query_changes_db_object.cc` (`db_object`, `object`, `object_reference`, `object_field`)
  - `query_changes_db_schema.cc` (`db_schema`)
  - `INC/mrs/database/query_changes_auth_app.h`
  - the `table_name + "_id"` column aliases (`db_schema_id`, `db_object_id`), which must follow the new names
- **Dead v2/v3 SQL, to delete rather than rename:**
  - the `v2` namespace of `query_entries_object.cc`
  - `v_2_3` of `query_entries_auth_privileges.cc` (columns gone in 5.0)
  - the v2 branches of `query_entries_db_object.cc` and `query_entries_auth_app.cc`
  - the v2/v3 factories in `monitor/schema_monitor_factory.cc` and `query_factory.cc`
  - `INC/mrs/interface/supported_mrs_schema_version.h`

## 3. `rest_daemon` registration; `router_id` as an integer (spec 1a)

### `--setup`

`register_instance` already inserts without an id and reads it back. Only the type has
to change, plus:
- **Account name:** `generate_username(prefix, router_id)` builds
  `mariadb_restd<id>_<random>` within 32 characters. A 36-character UUID overflows it,
  through an unsigned underflow.
- **Signatures:** `store_developer`, `store_account_metadata` and `create_accounts` take
  `uint64_t`.
- **Keyring:** `add_router_id_to_env(uint32_t)`.
- **Config file:** `write_config` writes `router_id=<int>`.

### Runtime

| What | Where |
|---|---|
| Config option, `uint64_t` | `configuration.h:63`, `IntOption<uint64_t>` |
| Keyring master-key reader | `src/router/src/keyring_handler.h` (`uint32_t`), `keyring_info.cc` (`ROUTER_ID` variable) |
| Plugin start | `find_existing_routers`, `QueryRouterInfo` (`stoi`) |
| Schema monitor | `schema_monitor.cc` (UPDATE by concatenated id, self-insert, statistics), `monitor/db_access.h`, `query_monitor_factory.h`, `schema_monitor_factory.cc` |
| Queries | `query_entries_db_service`, `query_changes_db_service`, `query_state` (unused), `query_statistics` |
| Metadata logger | `metadata_logger.cc` |
| JWT | `authorize_manager.cc:482` `instance_id = "router-" + id` |

## 4. Roles (spec 2)

`mysql_rest_service_{meta,data}_provider` appear in:
- `INC/collector/mysql_cache_manager.h` (`SET ROLE` per pool)
- `mysql_rest_service_plugin.cc` (messages)
- `mrsd_setup.cc` and `bootstrap_mysql_account.cc` (grants, default role)
- `README.md`
- component mocks: `common_statements.js`, `metadata_dynamic_nodes_v2_gr_mrs.js`
- `tests/mrs`: `init_authentication_mysql_account.sql`, `user_configure.inc`,
  `cleanup.inc`, `authentication_mysql_accounts.test`, `setup_mrs.inc`

## 5. Version gate (spec 3)

| Where | Today |
|---|---|
| `query_version.cc` | reads `schema_version` first; `msm_schema_version` only on `ER_NO_SUCH_TABLE` |
| `INC/mrs/database/query_version.h` | major-only `is_compatible`; `kCurrentMrsMetadataVersion{4,0,0}`; compatible `{4.0.0, 2.2}` |
| `schema_monitor.cc` | factories for majors 4, 3, 2 |
| `mrsd_setup.cc` | accepts `{4.0.0, 3.0.2, 2.2.0}` |
| `metadata_logger.cc` | refuses `< 4.0.2` |

## 6. Ids are UUIDs (spec 4): the largest change

### Type

`INC/mrs/database/entry/universal_id.h`, 16 bytes:
- `from_raw`, `from_raw_zero_on_null`, `from_raw_optional` and `from_cstr` require 16 bytes
- `to_string()` gives 32 hex digits
- `to_sqlstring` and `operator<<` give `X'hex'`

### Reads: about 45 sites

- **`from_raw`:** about 41 sites in the `query_entries_*`, `query_entry_*` and
  `query_changes_*` files.
- **`from_cstr`:** `query_user_groups.h:59`, `query_entries_object.cc:240`,
  `query_entry_fields.cc:134`.
- **`HEX()` of ids in SQL:** `query_entries_auth_app.cc:45,118`.
- **`QueryUuid`:** `query_uuid.cc` checks a length of 16.

### Binding

About 26 `to_sqlstring(UniversalId)` calls, plus every `<< id`. A 16-byte binary literal
should be accepted by a `UUID` column: verify. Row ownership must keep rendering owner
ids for `BINARY(16)` user columns:
- `helper/object_row_ownership.h`, `json_mapper/{insert,change,common,check}.cc`,
  `query_rest_table_single_row.cc`, `handler_db_object_table.cc`
- `query_rest_table.cc` `build_where`: `owner_col IN (WITH RECURSIVE … mrs_user a WHERE
  a.id = ? …)` compares `BINARY(16)` with `UUID`; verify on MariaDB.
- **Existing bug:** `build_where` emits `WHEREa.id` (missing space) when user and group
  ownership are combined.

### Client-visible ids

| Where | Today | Plan |
|---|---|---|
| `/authentication/status` `id` | 32 hex | Decide |
| Role `id` (`auth_role.h:51`) | raw bytes | Fix (existing bug) |
| `vendorId` | `"0x" + hex` | Keep |
| User id passed to stored procedures (`routine_utilities.h`) | 32 hex | Decide |
| Script API current user (`handler_db_object_script.cc`) | 32 hex | Decide |
| JWT `user_id`, `iss` | hex | Internal |

### Not metadata ids (unchanged)

User-data base64 (`select.cc`, `change.cc`, `filter_object_generator.cc`,
`handler_db_object_table.cc`) and user-table UUID primary keys (`json_mapper/insert.cc`).

### Size

About 400-700 changed lines of production code.

## 7. Vendor and app names (spec 5)

- **Daemon:** vendors are identified by id, the name is only displayed. One message says
  "MySQL Internal" (`handler_db_object_table.cc:836`).
- **Tests:**
  - `--let $mrs_add_auth_vendor=MySQL Internal`: 33 lines in 28 tests, looked up by name
    in `include/mrs/auth_app/add.inc`.
  - The test schema copy must drop the seeded `MariaDB` auth app (4.1.6 copy: `MySQL`).

## 8. Status counters (spec 7)

- **Writes:** `query_statistics.cc` writes `router_status.{mysql_connections,
  mysql_queries, active_mysql_connections}`. They become `rest_daemon_status`
  `mariadb_*`.
- **Counter names:** registered in `MRS/src/mrs/router_observation_entities.cc` as
  `mysqlConnections*`, `mysqlQueries` and the others.
- **`statusVariables`:** the daemon publishes no list.
- **Product name:** "MariaDB REST Service Daemon"; the spec's example is "MariaDB REST
  Daemon".
- **Version:** 26.10.0, which meets the required 26.10.0.

## 9. Audit-log polling (spec 9)

- **Query:** `query_entries_audit_log.cc` runs `WHERE ID > ? AND table_name in (?) ORDER
  BY id`.
  - The id is `uint64_t`, which fits `BIGINT UNSIGNED`.
  - **Existing bug:** a `static` column list.
- **Initial snapshot:** `max(id)` (`helper/query_audit_log_maxid.cc`) plus the load, in
  one transaction (`monitor/db_access.h`).
- **Polling:** each of the 8 change classes keeps its own last id.
  `schema_monitor.cc` throws `AuditLogInconsistency` when `max(id)` goes down.
- **Galera-safe version needed:**
  - re-read an overlap window
  - a per-monitor set of ids already seen, so objects aren't reloaded on every poll
  - best-effort `wsrep_sync_wait` on the polling connection (`get_rw_session`)

## 10. Spec 8 and items not needed

- **Landing page:** `defaultStaticContent` is data; no code change.
- **Not needed:**
  - `rest_daemon_session`: sessions are in memory.
  - Server-side status procedures and events.
  - Trigger and constraint names.
  - `sdk_service_data`, `data_mapping_fields_with_references`,
    `table_columns_with_references`.
  - The audit-log row-data JSON keys.
  - REST SQL syntax.
  - The `in_development` schema id.
  - Async tasks (already removed).
  - Schema auto-discovery (optional).

## 11. Test assets

### Functional suite

- **Schema:** replace `include/schema/mrs_metadata_schema-version4-mariadb.sql` with the
  5.0.0 deployment script (`--` comments converted to `#`, seeded auth app removed).
  Delete the v2, v3 and upgrade scripts.
- **Version includes:**
  - `initialize_schema.inc` and `check_mrs_schema_version.inc`
  - 33 tests that check the version (`is_mrs_schema_v4.inc`)
  - version-specific tests to rewrite or drop: `metadata_schema_version_compat`,
    `metadata_upgrade`, `app_specific_metadata_v_2`,
    `mrs_metadata_logger_unsupported_md_ver`
- **Includes:** 71 files under `include/mrs/` (15 use `get_sequence_id()`; `HEX()` round
  trips in `service/add.inc` and `host/get_host.inc`).
- **Renamed-table references:**
  - `include`: about 80
  - `t`: about 40
  - `r`: about 37
  - renamed columns across all three: `router_id` 134, `db_object_id` 60, `object_id` 34
- **Router id:** `$extra_mrs_router_id=1` appears in 108 tests. It flows through about 6
  includes and `conftest.py:421`, so a fixed UUID goes there.
- **Results:** about 141 files change mechanically. About 30 need re-recording for
  tables, columns or ids.

### Live-DB unit tests

`test_mrs_database_rest_table.cc` `prepare_user_metadata` builds `BINARY(16)` metadata
tables. They become `UUID` tables under the configured name. This is the place to test
`BINARY(16)` owners against `UUID` users.

### Mocked unit tests

- `test_rest_mrs_user_manager.cc`
- `test_mrs_query_entries_db_object.cc`
- `test_database_entries.cc`
- `test_mrs_json_mapper_metadata.cc`
- `mock/mock_endpoint_configuration.h`

### Component tests

- `common_statements.js` (roles, an integer router id)
- `metadata_dynamic_nodes_v2_gr_mrs.js`
- `test_mrs_config.cc`
- if `router_id` is validated: `test_config.cc` and `test_master_key_reader_writer.cc`

## Suggested phases

1. **Delete v2/v3 support, still on 4.1.6.** Fix `WHEREa.id`.
2. **Centralise the schema and role names, still on 4.1.6.** The default stays the old
   name.
3. **Make id reading type-agnostic, still on 4.1.6.** Accept 16 bytes or 36-character
   text. Split metadata binding from owner rendering.
4. **Switch to 5.0.0 in one go.** Renames, audit dispatch, default `mariadb_rest_service`,
   version gate 5, `router_id` as a UUID, status columns, test assets and a full
   re-record, smoke test.
5. **Wire formats and cosmetics.** User ids on the wire, role id bug, counters or
   `statusVariables`, texts, README.
6. **Galera-safe audit polling.**

## Riskiest parts

- Row ownership: `BINARY(16)` owner columns against `UUID` user and group ids.
- How Connector/C reports `UUID` columns (type, length), and `HEX()`/`GROUP_CONCAT` on
  them.
- `router_id` as a UUID: config, keyring, account naming, start-up identity check, JWT,
  test configs.
- Overlap-window polling without deduplication.
- The phase-4 re-record of the functional suite.
