# mrsd: standalone MySQL REST Service daemon (plan)

This is the plan of record. Progress is tracked in [PROGRESS.md](PROGRESS.md) and
findings in [phase0-inventory.md](phase0-inventory.md). If the plan changes, update this
file and add a line to the "Decision log" at the end.

## Goal

Fork MySQL Router's **MySQL REST Service (MRS)** out of the MySQL server
repository into a standalone project that builds a single-purpose MRS daemon, `mrsd`.

**Milestone 1 (this plan):** `mrsd` builds against a stock **MySQL 9.x client
library**, runs in the **MySQL ecosystem** (MySQL Server 9.x, MySQL Shell `mrs`
plugin, MySQL Shell for VS Code), and serves the same REST endpoints as
`mysqlrouter` with MRS enabled.

**Milestone 2 (later, out of scope here):** migrate to MariaDB (Connector/C,
MRS metadata schema and queries, MariaDB-aware destination providers).

## Scope decisions

| Topic | Decision |
|---|---|
| Source origin | `mysql-server` repo, `router/` tree (trunk, forked 2026-09-30 at `06a5c1c99c3`) |
| Git history | **Not preserved.** Plain copy |
| Client library | Stock **MySQL 9.x** libmysqlclient (public API only), taken from a MySQL server binary package given by `-DMYSQL_PACKAGE_DIR=<path>` (uses its `include/` and `lib/`) |
| JIT executor (JavaScript endpoints) | **Included**; `-DMRS_JIT_EXECUTOR_LIB=<dir>` points to a directory with the prebuilt `libjitexecutor` **and** its headers (`polyglot_api.h`, `graal_isolate.h`, …). Local: `<dev>/workflow-test/ext/polyglot/polyglot-nativeapi-native-library/target` |
| InnoDB Cluster / ClusterSet / ReplicaSet | **Out of scope.** No `metadata_cache`, no cluster bootstrap |
| X Protocol | **Out of scope.** No mysqlxclient, mysqlxmessages or protobuf |
| Platforms | **Linux, Windows, macOS** |
| Upstream sync | **None.** Directory layout may be changed freely |
| Tests | Keep the GoogleTest/CTest suites; port the MRS-relevant mtr tests to gtest; no mtr |
| Source repo location | `<dev>/mysql/mrsd` |

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

### Phase 1: new repo that builds (🟡 macOS done 2026-09-30; Linux/Windows pending)
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

### Phase 2: tests and validation in the MySQL ecosystem
- Decide on duktape for `mysql_server_mock` (restore 2.7.0 from git history
  `214f378700f^:extra/duktape`, or an alternative), then do 1.7 (remove X
  from the mock server, and its `router_protobuf` plugin requirement).
- Move the TLS fixtures (`mysql-test/std_data` → `tests/data/ssl`) and repoint
  `SSL_TEST_DATA_DIR`. Copy the `unittest/gunit/benchmark.h` helper.
- Get the unit suites green: MRS, HTTP, harness, router_lib, jit_executor.
- Get the component tests green against `mysql_server_mock`.
- Get the integration tests green against a real MySQL 9.x `mysqld`.
- Triage `mysql-test/suite/router` (137 tests) and port the MRS-related ones.
- Manual end-to-end check: MySQL Shell `mrs` plugin creates the metadata schema and a
  service; configure `mrsd` by hand (config plus keyring); verify CRUD, auth apps,
  and JavaScript endpoints.
- **Exit criteria:** CI green on 3 OSes; end-to-end checklist passes.

### Phase 3: MRS-specific setup and cleanup
- `mrsd --setup`: reuse `BootstrapConfigurator::configure_mrs()` logic
  (check_mrs_metadata, register_mrs_router_instance, create_mrs_users, keyring,
  config writing) against a single standalone server.
- Remove leftover routing and cluster code and options from harness/router_lib.
- Branding: binary, config section names, log domains, Windows service and
  event log names. The MRS router registration stays compatible.
- **Exit criteria:** a fresh install works via `mrsd --setup` alone on each OS.

### Phase 4: packaging and CI
- Linux: deb/rpm (from `packaging/deb-in/deb_router.cmake` and the rpm specs), a systemd unit, a container image.
- Windows: MSI (from `packaging/WiX/router`, new upgrade codes) and service installation.
- macOS: pkg/tarball, dylib handling.
- Ship the JIT library in `private/`.
- CI matrix: 3 OSes × JIT on/off × MySQL 9.x server.

## Target repository layout

```
mrsd/
  CMakeLists.txt            top-level build
  cmake/                    build helpers (replacements for server macros)
  compat/                   replacements for libmysqlclient internal symbols
  extra/
    mysql-internals/        vendored header-only server headers
    rapidjson/  libcno/     vendored third-party
  src/                      router/src modules (same names as upstream)
    mrsd/                   new front end (main, config, Windows service)
  tests/                    helpers, component, integration, data/ssl
  packaging/
  docs/                     PLAN.md, PROGRESS.md, inventories
  tools/analysis/           dependency analysis scripts
```

## Risks

| Risk | Status / mitigation |
|---|---|
| Stock client library lacks symbols Router needs | **Resolved in Phase 0:** 10 internal symbols, replaced by `compat/` |
| JIT library per platform | **Resolved:** the builder provides it through `MRS_JIT_EXECUTOR_LIB` (lib + headers); each platform's CI needs its own build of it |
| Windows build infrastructure (MSVC flags, DLL exports, OpenSSL/ICU) | Budget time in Phase 1; get Windows CI running early |
| Hidden dependencies in test code (mock_server, test helpers) | Re-run `tools/analysis/include_closure.py --tests` after copying |
| Behaviour differences from replacing `my_gcvt` (JIT number formatting) | **Done:** vendored `strings/dtoa.cc` in `mrsd_compat` |
| Two OpenSSL copies in one process: libmysqlclient uses the package's bundled OpenSSL (3.5.7 in 26.7.0), mrsd code uses the system's (3.6.3 on the dev Mac) | Works on macOS (two-level namespace). On Linux/Windows the shared soname/DLL name means only one gets loaded. Revisit if TLS problems appear; option: link mrsd against the package's OpenSSL |
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
