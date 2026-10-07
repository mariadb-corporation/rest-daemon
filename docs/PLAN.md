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

### Phase 4: packaging and CI
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
