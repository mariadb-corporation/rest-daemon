# Differences from the MySQL REST Service

`mariadb-restd` is a port of MySQL Router's MySQL REST Service (MRS) to MariaDB.
It serves the same endpoints from the MariaDB REST Service metadata schema 5.0
(MRS's metadata, renamed and with UUID ids); this is what behaves
differently, for people and tools coming from MRS. Found while porting the MRS
test suite (Milestone 2, see [PROGRESS.md](PROGRESS.md)); the test-suite
entries are in `tests/mrs/disabled.def` and `tests/mrs/known_failures.def`.

## Not available

- **GTID based `asof` requests** (read-your-writes): MRS builds them on MySQL's
  GTIDs (`session_track_gtids`, `gtid_executed`, `WAIT_FOR_EXECUTED_GTID_SET`),
  which MariaDB doesn't have. Such requests fail with a clear 400; responses
  carry no `_metadata.gtid`. A MariaDB implementation is Milestone 4, together
  with the MariaDB shell and plugins.
- **REST async tasks** (`mysql_tasks`) are not part of `mariadb-restd`:
  routines are always called directly, `POST` answers with the result, and
  there is no `{taskId}` status endpoint. The `mysqlTask` options in existing
  metadata are ignored.
- **MySQL servers**: `mariadb-restd` refuses to start against anything but a
  MariaDB server, 11.7 or later (the metadata schema's `UUID_v7()` defaults).
- **MRS metadata 4.x** (`mysql_rest_service_metadata`): only the MariaDB REST
  Service metadata schema 5.0.x is served, see below.

## Metadata schema and configuration

- **Schema 5.0**, deployed by MariaDB Shell's `CONFIGURE REST METADATA`:
  `mariadb_rest_service` (option `metadata_schema` / `--metadata-schema` for a
  `<prefix>mariadb_rest_service<postfix>` deployment), with MRS's tables
  renamed (`router` → `rest_daemon`, `db_schema` → `rest_schema`, `db_object`
  → `rest_object`, `object*` → `data_mapping*`, ...) and `UUID` ids. A 4.x
  schema, or a newer 5.x minor, is refused with a message naming the
  supported version.
- **Roles** carry the schema's prefix and postfix:
  `<prefix>mariadb_rest_service_meta_provider<postfix>`,
  `..._data_provider` (MRS: `mysql_rest_service_*`).
- **Instance id**: `rest_daemon_id`, the UUID of the instance's `rest_daemon`
  row (MRS: `router_id`, an integer). A master key reader gets it in
  `REST_DAEMON_ID` (MRS: `ROUTER_ID`); JWTs carry it as `instance_id` (MRS:
  `router-<id>`). `--setup` names the accounts it creates
  `mariadb_restd_<random>` (MRS: `mysql_router<id>_<random>`).
- **Configuration**: the daemon's section is `[mariadb_rest_service]` (MRS:
  `[mysql_rest_service]`) and its options carry no `mysql_` prefix:
  `metadata_user`, `data_user`, `read_write_destinations`,
  `read_only_destinations`, `ssl_mode`, `ssl_ca`, ..., `tls_version` (MRS:
  `mysql_user`, `mysql_user_data_access`, `mysql_read_write_route`,
  `mysql_ssl_mode`, ...). The pid file's environment variable is
  `MARIADB_RESTD_PID` (MRS: `ROUTER_PID`); `--setup` writes `restd-key.pem`
  and `restd-cert.pem` (MRS: `router-*.pem`). The old section, option and
  variable names are still read, with a deprecation warning. The optional
  status plugin is `[rest_daemon]` at `/api/20190715/daemon/status` (MRS:
  `[rest_router]`, `/router/status`).
- **Status counters** are written to `rest_daemon_status` as
  `mariadb_connections`, `mariadb_queries` and `active_mariadb_connections`;
  the counter names are `mariadbConnectionsCreated`, `mariadbQueries`, ...
  (MRS: `mysql...`), and the daemon publishes the list (`statusVariables`:
  name, column, nonResettable) in `rest_daemon.attributes`, which the
  metadata's status downsampling reads.
- **Ids on the wire** are UUID text, like everywhere in the 5.0 metadata: the
  user's `id` and the role ids in `/authentication/status` (MRS: 32 hex
  digits; role ids were raw bytes), and `getCurrentMrsUserId()` in MRS scripts
  (MRS: 32 hex digits, so scripts that looked users up with `UNHEX(?)` use
  `WHERE id = ?`). `vendorId` in `/authApps` stays `0x…`, as the client SDKs
  compare it. A routine's ownership parameter gets the user id as a 16-byte
  value, which fills a `BINARY(16)` or a `UUID` parameter (MRS bound the 32 hex
  digits as text, too long for `BINARY(16)`).
- The built-in authentication vendor is **MariaDB Internal** (MRS: MySQL
  Internal), identified by its id, as before.

## Server behaviour

- **JSON routine results and parameters** are LONGTEXT to MariaDB everywhere
  (`information_schema`, result metadata): a function `RETURNS JSON` delivers
  its value as a JSON *string*, not as a nested document. JSON *columns* are
  recognised in results (extended column metadata). But the metadata schema
  records a JSON column's datatype as `longtext` (MariaDB's `COLUMN_TYPE`),
  so on writes the service treats it as text: arrays, objects, numbers and
  `null` are stored correctly, while a JSON *string* value (`"hello"`, `""`)
  is written unquoted and rejected by the column's `json_valid` check. Fixing
  this needs the metadata schema (shell and plugins) to report `json`.
- **Roles**: MariaDB activates one role at a time and no role by default
  (MRS runs `SET ROLE ALL` on its connections). The service accounts created
  by `--setup` get a default role. For pass-through authentication
  (`data_user`, MariaDB Internal auth) the service activates the
  account's role when it has exactly one and no default; with several roles
  it logs a warning and the DBA sets one with `SET DEFAULT ROLE`. The account running
  `--setup` must hold the REST service roles `WITH ADMIN OPTION` to grant
  them (`GRANT ALL ... WITH GRANT OPTION` is not enough on MariaDB).
- **Read-only destinations**: there is no `super_read_only`; `read_only` does
  not apply to accounts with SUPER privilege, so the service only notices a
  read-only server when its own writes fail (an unprivileged service account).
- **Offline mode** does not exist on MariaDB.
- **Geometry**: MariaDB has no SRID attribute on columns and no geographic
  axis order; coordinates are returned as stored (MRS swaps them to
  latitude-longitude for SRID 4326). Equality filters use the column's SRID.
- **VECTOR** columns have a fixed dimension on MariaDB (`VECTOR(n)`); MySQL's
  accept up to a maximum. A `VECTOR` value in a *routine's result set* is
  indistinguishable from binary data to a client (MariaDB sends no type
  attribute for it, unlike for JSON), so it renders as base64 unless the
  REST object defines the result's fields with their types; OUT/INOUT
  `VECTOR` parameters render as arrays.
- **Malformed base64** for a BINARY field is stored as NULL, as in MRS
  (MySQL's `FROM_BASE64` yields NULL; the service checks the value itself).
- **Metadata changes are polled Galera-safe**: audit-log ids are taken at insert,
  not at commit, so with concurrent writers (on Galera: several write nodes) a change
  can become visible after one with a higher id. MRS reads only the ids after the last
  one it saw and misses such a change until a full reload; restd also re-reads the
  last 60 seconds of the audit log (by `changed_at`) and skips what it already
  applied, and on a Galera node sets `wsrep_sync_wait` on its polling connection.
- **Statement timeouts** (`sqlQuery.timeout`) are applied with
  `SET STATEMENT max_statement_time=... FOR ...` (MRS uses the
  `MAX_EXECUTION_TIME` optimizer hint, which MariaDB only knows from 12.0 and
  ignores as a comment before that).
- **Invalid date/time literals** in filters compare as NULL (no match) instead
  of failing with 400.
- **Floats** are rendered with the server's precision (`-1000` where MRS
  prints the double `-999.9998779296876`).
- **Integer display widths** (`int(11)`) appear in MariaDB's metadata; the
  OpenAPI output strips them. Computed integer columns (`SELECT 1`,
  `MIN(id)`) are typed `INTEGER` in result metadata where MySQL says `BIGINT`.
- **JSON text** in JSON columns is returned and stored as given (MySQL
  normalizes to `{"a": 1}` with a space and sorts the keys), so document
  lengths differ. The objects the service builds itself (rows, nested
  references) are emitted in MRS's member order, so their documents and etags
  are the same as MRS's.
- **Accounts** created by `--setup` use the server's default authentication
  plugin (MRS names `caching_sha2_password`).
- `DROP USER` of an account with open connections emits a Note.
- Error texts differ (e.g. "Table doesn't exist" where MySQL says "Unknown
  database"; "for key 'PRIMARY'" without the table name), and so do declared
  lengths in result metadata (`CURRENT_USER()` is `VARCHAR(384)`, MySQL's
  `VARCHAR(288)`).

## REST service behaviour

- **A REST role of a service applies to that service only.** A role created
  for a service (`CREATE REST ROLE ... ON SERVICE /a`, `specific_to_service_id`)
  grants access to requests on that service alone, whatever paths its
  privileges name; a global role (`ON ANY SERVICE`) applies wherever its
  privilege paths match. MRS matched every privilege of every role of the
  user by path alone, so a service role with a privilege on `*` or on another
  service's path reached that service, and a clone of a service (MariaDB
  Shell's `CLONE REST SERVICE` copies the roles) widened access outside the
  clone. Suite test `role_service_scope`.

## Test-suite only

- The upstream test fixtures declared `VECTOR` columns and routine parameters
  without a dimension and stored vectors of different lengths; the suite's
  copies declare `VECTOR(2)`/`VECTOR(3)` with consistent values (and
  `set_vector` returns a different 3-element vector instead of appending),
  with results recorded on MariaDB.
- `mariadb-install-db` creates anonymous accounts that shadow every `'%'`
  account for local connections; the harness and the smoke test drop them.
