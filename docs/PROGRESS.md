# Progress log

Plan: [PLAN.md](PLAN.md). Update this file at the end of every work session:
tick tasks, add a session entry, and rewrite "Next steps".

## Status

| Phase | Status |
|---|---|
| 0: dependency inventory | ✅ done 2026-09-30, verdict GO ([phase0-inventory.md](phase0-inventory.md)) |
| 1: new repo that builds | 🟡 macOS done 2026-09-30 (build + end-to-end smoke test); Linux and Windows not started |
| 2: tests and ecosystem validation | ⏳ not started |
| 3: MRS setup and cleanup | ⏳ not started |
| 4: packaging and CI | ⏳ not started |

## How to build and test (macOS)

```sh
cd <dev>/mysql/mrsd
cmake -S . -B build-jit -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DMYSQL_PACKAGE_DIR=<dev>/mysql/mysql-26.7.0-macos15-arm64 \
  -DMRS_JIT_EXECUTOR_LIB=<dev>/workflow-test/ext/polyglot/polyglot-nativeapi-native-library/target
ninja -C build-jit

MRSD_BUILD=$PWD/build-jit \
MYSQL_PACKAGE_DIR=<dev>/mysql/mysql-26.7.0-macos15-arm64 \
MYSQLSH=<dev>/mysql/mysql-shell-26.7.0-macos15-arm64/bin/mysqlsh \
SHELL_PLUGINS=<dev>/mysql/mysql-shell-plugins \
  tools/smoke/run_smoke.sh      # prints "OK: {...}" on success
```
`build/` is the same build without JIT (leave out `-DMRS_JIT_EXECUTOR_LIB`).
The binary is still called `mysqlrouter` (renamed in Phase 3); in the build tree
the config must set `plugin_folder=<build>/plugin_output_directory`.

## Phase 1 checklist
- [x] 1.1 skeleton: layout, top-level CMake, `cmake/compat/` macro replacements
- [x] 1.2 third-party: OpenSSL (system), rapidjson + libcno (vendored), ICU (system); MYSQL_PACKAGE_DIR client finder. GTest is deferred to Phase 2 (WITH_UNIT_TESTS=OFF for now)
- [x] 1.3 copy module set; vendor `extra/mysql-internals`; slim `my_config.h`
- [x] 1.4 `compat/` library (10 symbols + `build_version` + dtoa)
- [x] 1.5 MRS static destination provider, routing dependency removed
- [x] 1.6 `router_lib` split from `router_cluster`; bootstrap removed from the front end (still `router_app.cc`, trimmed)
- [ ] 1.7 mock_server without X, **moved to Phase 2** (needs duktape)
- [x] 1.8 JIT build on (macOS)
- [x] macOS: Debug build with and without JIT; `tools/smoke/run_smoke.sh` passes (MySQL 26.7.0 server and client, MRS metadata 4.1.5, REST view GET)
- [ ] Linux build + smoke test
- [ ] Windows build + smoke test (expect work on MSVC flags, ICU, OpenSSL, DLL exports)

## Open questions
1. **duktape** for `mysql_server_mock` (component tests): restore duktape 2.7.0
   from upstream history (`git show 214f378700f^:extra/duktape/...`), use a
   system package, or replace the mock's JavaScript engine? Blocks Phase 2's
   component tests. Public upstream builds skip them too
   (`IF(NOT TARGET duktape) RETURN()`); Oracle presumably provides duktape
   through its internal build files.

## Resolved questions
- JIT: `-DMRS_JIT_EXECUTOR_LIB=<dir>` (lib + headers). Local: `<dev>/workflow-test/ext/polyglot/polyglot-nativeapi-native-library/target`.
- Client library: from a MySQL server package, `-DMYSQL_PACKAGE_DIR=<path>`. Local: `<dev>/mysql/mysql-26.7.0-macos15-arm64`.
- ICU: keep it (performance, Bug#36797250).
- Copyright notices: mariadb-shell recipe, `.githooks/pre-commit` linked by the configure step.
- Repository: local git repo in `<dev>/mysql/mrsd`, moved to the final remote later.

## Next steps
1. Linux build (container or VM with a MySQL 9.x/26.x Linux server package), then the smoke test.
2. Windows build (MSVC); expect `cmake/compat/build_env.cmake` and `third_party.cmake` changes.
3. Decide on duktape (open question 1), then start Phase 2 with the unit tests (GTest setup, `tests/data/ssl`, `benchmark.h`).

## Session log

### 2026-09-30: session 1 (planning + Phase 0)
- Agreed scope and plan (see PLAN.md decision log).
- Created the repo skeleton `<dev>/mysql/mrsd` (git init, docs, tools).
- Built router in the server tree (`build/`, Debug) for symbol analysis.
- Phase 0 done: 46 public API + 10 internal client symbols; header, generated and
  third-party inventory; routing/metadata_cache/connection_pool cut points identified;
  JIT library sourcing is the main open item.
- Follow-up: resolved the JIT SDK path, client library source (server package) and ICU (keep).

### 2026-09-30: session 1, continued (Phase 1 on macOS)
- Copied the module set (15 modules + tests) and vendored rapidjson, libcno and the
  header-only server headers; generated a slim `my_config.h`.
- `cmake/compat/`: build_env (server macros, layout), mysql_package (MySQL::client
  from MYSQL_PACKAGE_DIR), third_party, configure_checks; `fileutils.cmake` copied from the server.
- `compat/`: thread names, aligned malloc, crash stack traces, client error texts
  (copied from libmysql/errmsg.cc), collation → mbmaxlen table (generated from
  MySQL 26.7.0 information_schema), `build_version`, vendored dtoa.
- Source changes (behaviour changes marked `mrsd:` in comments; mechanical ones not):
  - `mysql_session.cc`: `my_get_err_msg` → `mrsd::client_error_message`;
    `vio_io_wait` → `poll()` on `NET::fd`; no more `violite.h`/`my_sys.h`
  - MRS `mysql_column_types.cc`: `get_charset()` → `mrsd::charset_mbmaxlen()`
  - MRS plugin: `my_init()` → `mysql_library_init()`; routing wait removed
  - MRS plugin config: static destinations + `mysql_ssl_*` options; supported-options list updated
  - http: `metadata_cache` auth backend removed; `router_protobuf` requirement removed from http plugins
  - router: `router_cluster`, `router_conf`, `config_generator` and routing-guidelines
    code deleted; bootstrap stripped from `router_app`; `silent_exception` handlers removed
  - jit_executor: `include/my_thread.h` → `my_thread.h`; `mysql.h` before `mysql_com.h`
  - includes relative to the server root (`router/src/...`) rewritten
- Results: full Debug build with and without JIT. MRS plugin links nothing from
  routing, metadata_cache, X protocol or protobuf. End-to-end: MySQL Shell 26.7
  created and published a REST view and `mrsd` served
  `GET /smoke/smoke/city` → 200 with the rows. Captured in `tools/smoke/run_smoke.sh`.
- Pitfalls found: putting the project root on the include path makes `<version>`
  resolve to `VERSION` (case-insensitive filesystem), so don't; the macOS
  socket path limit (104 bytes) needs a relative `--socket` for mysqld in the
  scratchpad; MRS services created by Shell are unpublished by default.

### 2026-09-30: session 1, continued (repository + copyright hook)
- Copied `.githooks/` (MariaDB copyright pre-commit hook) and `cmake/git_hooks.cmake`
  from the mariadb-shell project; configure links the hook into `.git/hooks`.
  Exceptions: `extra/rapidjson/`, `extra/libcno/`.
- Initial commit `79dd52f` in the local repo; the hook added the MariaDB notice
  to ~1,425 files. Rebuilt with JIT and reran the smoke test afterwards: OK.
- Pitfall: the hook treats every `*.cmake` file as `#`-commented, so C header
  templates must not end in `.cmake`. `my_config.h.cmake` was renamed to
  `my_config.h.in` (the hook leaves `.in` files alone; notice added by hand).
