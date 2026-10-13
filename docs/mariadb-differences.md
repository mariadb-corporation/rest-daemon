# Running against MariaDB: differences and limitations

What behaves differently when `mariadb-restd` serves a MariaDB server, compared
with MySQL. Found while porting the MRS functional suite (Milestone 2, see
[PROGRESS.md](PROGRESS.md)); the test-suite entries are in
`tests/mrs/disabled.mariadb.def` and `tests/mrs/known_failures.mariadb.def`.

## Not available

- **GTID based `asof` requests** (read-your-writes; an open point): MariaDB has no
  `session_track_gtids`, `gtid_executed` or `WAIT_FOR_EXECUTED_GTID_SET`. Such
  requests fail with a clear error; responses carry no `_metadata.gtid`.
- **REST async tasks** (`mysql_tasks`) are not part of the MariaDB REST Service;
  routines are always called directly.

## Server behaviour

- **JSON routine results and parameters** are LONGTEXT to MariaDB everywhere
  (`information_schema`, result metadata): a function `RETURNS JSON` delivers
  its value as a JSON *string*, not as a nested document. JSON *columns* are
  recognised (extended column metadata) and work as on MySQL.
- **Roles**: MariaDB activates one role at a time and no role by default.
  The service accounts created by `--setup` get a default role; an account
  used for pass-through authentication (`mysql_user_data_access` or MySQL
  Internal auth) needs `SET DEFAULT ROLE` by the DBA. The account running
  `--setup` must hold the MRS roles `WITH ADMIN OPTION` to grant them
  (`GRANT ALL ... WITH GRANT OPTION` is not enough on MariaDB).
- **Read-only destinations**: there is no `super_read_only`; `read_only` does
  not apply to accounts with SUPER privilege, so the service only notices a
  read-only server when its own writes fail (an unprivileged service account).
- **Offline mode** does not exist on MariaDB.
- **Geometry**: MariaDB has no SRID attribute on columns and no geographic
  axis order; coordinates are returned as stored (MySQL swaps them to
  latitude-longitude for SRID 4326). Equality filters use the column's SRID.
- **VECTOR** columns have a fixed dimension on MariaDB (`VECTOR(n)`); MySQL's
  accept up to a maximum.
- **Statement timeouts** (`sqlQuery.timeout`, `MAX_EXECUTION_TIME`) do not
  interrupt a statement waiting for a table lock (`LOCK TABLES`); such a
  request runs into the read timeout instead.
- **Invalid date/time literals** in filters compare as NULL (no match) instead
  of failing with 400.
- **Floats** are rendered with the server's precision (`-1000` where MySQL
  prints the double `-999.9998779296876`).
- **Integer display widths** (`int(11)`) appear in MariaDB's metadata; the
  OpenAPI output strips them.
- **JSON text** is returned as stored (MySQL normalizes to `{"a": 1}` with a
  space), so document lengths differ; member order follows the insertion
  order (MySQL sorts keys).
- `DROP USER` of an account with open connections emits a Note.
- Error texts differ (e.g. "Table doesn't exist" where MySQL says "Unknown
  database").

## Test-suite only

- The upstream test fixtures declare `VECTOR` columns without a dimension and
  store vectors of different lengths; the MariaDB mode of the suite maps them
  to `BLOB` and disables the vector tests.
- `mariadb-install-db` creates anonymous accounts that shadow every `'%'`
  account for local connections; the harness and the smoke test drop them.
