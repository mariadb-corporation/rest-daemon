# Phase 0: dependency inventory

**Date:** 2026-09-30 · **Source:** `mysql-server` trunk `06a5c1c99c3` · **Platform analysed:** macOS arm64
**Reproduce:** `tools/analysis/include_closure.py [--tests]` (headers) and
`tools/analysis/check_client_symbols.sh` (symbols; needs router built in the server
build tree with `ninja mysql_rest_service mysqlrouter router_mysqlclient`).

**Verdict: GO.** A stock MySQL 9.x client library is enough, provided a small
`compat/` library replaces 10 internal symbols.

---

## 1. How Router links the client library today

Router does **not** link the normal libmysqlclient. `router/src/harness/src/CMakeLists.txt`
builds a private `libmysqlrouter_mysqlclient` with `MERGE_LIBRARIES_SHARED`,
merging `clientlib` + `vio` + `mysys` + a shim (`router_mysqlclient_exports.cc`), and
exports the public client API plus a list of internal mysys/strings/vio/dbug symbols
(on Windows, partly listed explicitly). This whole mechanism is dropped. `mrsd`
links the stock libmysqlclient and provides its own replacements for the internals.

## 2. Symbols the kept code imports from the client library

Measured with `nm` on the kept libraries (harness, harness_stdx, harness_tls,
router_mysql, router_utils, router_lib, http*, io_component,
destination_status, rest_api.so, http_server.so, mysql_rest_service.so).

- **46 public API functions**, all in libmysqlclient's `CLIENT_API_FUNCTIONS` /
  `CLIENT_API_NONBLOCKING_FUNCTIONS`: `mysql_real_connect`, `mysql_stmt_*`,
  `*_nonblocking`, `mysql_get_ssl_session_data`, `mysql_session_track_*`, and others.
- **10 internal symbols** (not exported by the stock libmysqlclient on Linux/Windows).

## 3. Internal symbols and their replacements (`compat/`)

| Symbol | Used by | Replacement |
|---|---|---|
| `my_thread_self_setname` | harness, http_server, io, MRS, jit (≈12 call sites) | `pthread_setname_np` (Linux: 15-character limit; macOS: current thread only) / `SetThreadDescription` (Windows) |
| `my_aligned_malloc`, `my_aligned_free` | harness `secure_memory_pool.cc` | `posix_memalign`/`free`, `_aligned_malloc`/`_aligned_free` |
| `my_init_stacktrace`, `my_print_stacktrace`, `my_write_core`, `my_safe_printf_stderr` | harness `signal_handler.cc` (crash reporting) | Small crash handler: `backtrace_symbols_fd` (POSIX), DbgHelp `StackWalk64`/`MiniDumpWriteDump` (Windows), `write(2)`-based safe printf |
| `my_get_err_msg(CR_*)` | router_mysql `mysql_session.cc:515,524` | Client error text: use `mysql_error()` on a handle where one exists, otherwise a small table of the `CR_*` messages used |
| `my_init()` | MRS `mysql_rest_service_plugin.cc:129` (marked TODO/ODR workaround) | `mysql_library_init()` (public API) |
| `get_charset(id)->mbmaxlen` | MRS `helper/mysql_column_types.cc:91` (column length in type text) | Small collation-id → mbmaxlen table, or query `information_schema.COLLATIONS` once at startup |

Found later, in Phase 1 (not covered by the library-only symbol scan):
- `build_version` (mysys `print_version.cc`, used by the executables' `--version`) → `compat/src/print_version.cc`.
- `vio_io_wait()`, a macro reaching into the client's internal `struct Vio`, in
  `MySQLSession::has_data_on_socket()` (used by MRS's connection pool) →
  `poll()` on the public `NET::fd`.

Not measured, because jit_executor wasn't built (no JIT library in the analysis build):
- `my_gcvt` (strings/dtoa) in `jit_executor_value.cc` and `utils/utils_json.cc`.
  **Plan:** vendor `strings/dtoa.cc` to keep the exact number formatting.
- Re-run `check_client_symbols.sh` once jit_executor builds; it includes
  `jit_executor.so` automatically when present.

## 4. Header dependencies outside the module set (production code)

Include closure over 938 production source files (1,098 files reached).

### 4a. Public client headers (from the MySQL 9.x dev package, no action)
`mysql.h`, `mysql_com.h`, `errmsg.h`, `mysqld_error.h`, `field_types.h`,
`mysql_time.h`, `my_command.h`, `my_compress.h`, `my_list.h`, `mysql_version.h`,
`mysql/client_plugin.h`, `mysql/plugin_auth_common.h`,
`mysql/udf_registration_types.h`.
Verified present in `mysql-26.7.0-macos15-arm64/include`.

### 4b. Server headers to vendor into `extra/mysql-internals/` (header-only use)
`my_rapidjson_size_t.h` (47 users), `my_compiler.h` (+`mysql/attribute.h`),
`my_inttypes.h`, `my_macros.h`, `scope_guard.h`, `template_utils.h`,
`m_string.h` (+`lex_string.h`, `mysql/mysql_lex_string.h`, `string_with_len.h`),
`dh_ecdh_config.h` (harness TLS DH parameters; drop its `my_dbug.h` include),
`my_cleanse.h`, `mysql/strings/dtoa.h` (+ `strings/dtoa.cc`, see §3).

### 4c. Server headers to remove or replace (pull in mysys/PSI, about 40 headers)
| Header | Where | Action |
|---|---|---|
| `my_sys.h`, `mysql/strings/m_ctype.h` | MRS `mysql_column_types.cc`, 3 others | Remove; use `compat/` (§3) |
| `my_thread.h` | harness `loader.cc`, `signal_handler.cc`, http, io (+11) | `compat/thread_name.h` |
| `my_stacktrace.h` | harness `signal_handler.cc` | `compat/stacktrace.h` |
| `my_aligned_malloc.h` | harness `secure_memory_pool.cc` | `compat/aligned_malloc.h` |
| `violite.h` | router `mysql_session.cc` (only `SSL_MODE_*`) | Use the public `enum mysql_ssl_mode` from `mysql.h` |
| `mysql/psi/mysql_file.h` | `router_mysqlclient_exports.cc` | File dropped (§1) |
| `print_version.h`, `welcome_copyright_notice.h` | http `passwd.cc` (+3) | Own version/copyright banner |

### 4d. Generated headers
- `my_config.h` → own `mrsd_config.h` from CMake checks.
- `mysql_version.h`, `mysqld_error.h` → from the client package.
- `mysql/harness/plugin.h` (from `plugin.h.in`), JSON schema headers
  (`configuration_update_schema.h`, `dynamic_state_schema.h`), `router_config.h`
  → keep their generators.
- ~25 `*_export.h` → `GenerateExportHeader` in the new CMake.

### 4e. Router modules reached that are being cut
| Module | Reached from | Action |
|---|---|---|
| `routing` (22 headers) | `mysql_rest_service_plugin_config.h` (`routing_component.h`); `connection_pool.h`; `router/config_generator.cc` | MRS static destination provider (Phase 1.5); drop connection_pool and config_generator |
| `metadata_cache` (4) | `http/src/http_auth_backend_metadata_cache.cc`; `router/config_generator.cc` | Drop those sources |
| `routing_guidelines` (1) | `router/src/cluster_metadata.cc` (+6) | Drop `router_cluster` |

`mysql_rest_service.so` today links routing, metadata_cache, mysqlxclient,
mysqlxmessages, protobuf, connection_pool and routing_connections (checked with `otool -L`).
All of these go away with the Phase 1.5/1.6 cuts.

### 4f. Third-party libraries
| Library | Used by | Plan |
|---|---|---|
| OpenSSL | harness_tls, http, router_lib, MRS | System (Linux/macOS); Windows: custom path |
| rapidjson | everywhere (via `my_rapidjson_size_t.h`) | Vendor MySQL's `extra/rapidjson` |
| ICU | `harness/src/regex_matcher.cc` (used by the HTTP request router, MRS `handler_authorize_login.cc`, router `log_filter.cc`) | **Keep.** System on Linux/macOS, vendored/vcpkg on Windows. Upstream switched from std::regex for speed (Bug#36797250) |
| libcno (HTTP/1 and HTTP/2) | http | Vendor `extra/libcno` (+ `cno_huffman_generator.cc`) |
| GoogleTest | tests | FetchContent / vendored |
| libjitexecutor (GraalVM polyglot) | jit_executor | External prebuilt SDK (see §6) |

### 4g. Test-only additions (`--tests`)
Router test helpers (`router/tests/helpers/*`, `test_tls/*`) and one server file:
`unittest/gunit/benchmark.h`. The component tests under `router/tests/component` were
not part of this scan; re-run after copying (Phase 2).

## 5. Dead code found
- `jit_executor/src/native_wrappers/polyglot_function_wrapper.{h,cc}` includes
  MySQL Shell headers (`mysqlshdk/...`), but it **isn't in the CMake source list**. Don't copy it.

## 6. JIT executor library
- `MRS_JIT_EXECUTOR_LIB` is a directory with the prebuilt `libjitexecutor`
  (GraalVM native image) and its headers (`polyglot_api.h`, …). Neither the server nor
  the Shell repo builds it; both consume it prebuilt.
- MySQL Shell 26.7.0 for macOS ships `lib/mysqlsh/libjitexecutor.dylib` (no headers).
- Router packaging includes it only on Linux (deb/rpm: `private/libjitexecutor.so`).
- **Resolved:** the builder passes `-DMRS_JIT_EXECUTOR_LIB=<dir>` (lib + headers). Local macOS build:
  `<dev>/workflow-test/ext/polyglot/polyglot-nativeapi-native-library/target`
  (`libjitexecutor.dylib`, `polyglot_api.h`, `polyglot_types.h`, `polyglot_isolate.h`, `graal_isolate.h`, `*_dynamic.h`).

## 7. Local assets
- Server source and build tree (Debug, Ninja, router built): `<dev>/mysql/mysql-server`, `…/build`
- MySQL 26.7.0 macOS binary distribution (client lib, headers, mysqld): `<dev>/mysql/mysql-26.7.0-macos15-arm64`
- MySQL Shell 26.7.0 macOS (has libjitexecutor.dylib): `<dev>/mysql/mysql-shell-26.7.0-macos15-arm64`
- MySQL Shell source: `<dev>/mysql/mysql-shell`; Shell plugins (MRS plugin): `<dev>/mysql/mysql-shell-plugins`
