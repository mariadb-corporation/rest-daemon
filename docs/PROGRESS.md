# Progress log

Plan: [PLAN.md](PLAN.md). Update this file at the end of every work session:
tick tasks, add a session entry, and rewrite "Next steps".

## Status

| Phase | Status |
|---|---|
| 0: dependency inventory | ✅ done 2026-09-30, verdict GO ([phase0-inventory.md](phase0-inventory.md)) |
| 1: new repo that builds | ✅ done 2026-09-30: macOS, Linux, Windows (x64), with JIT; smoke test incl. MRS scripts passes on all three |
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

### MRS scripts (JIT) step of the smoke test

Set `MRS_SCRIPTS_DIR` to a built copy of `mysql-shell-plugins/mrs_plugin/examples/mrs_scripts`
(built on the Mac, since the VM has no Node.js):
```sh
rsync -a --exclude node_modules --exclude build \
  <dev>/mysql/mysql-shell-plugins/mrs_plugin/examples/mrs_scripts/ <dir>/
cd <dir> && npm install && npm install --save-dev typescript@5 && npm run build
```
The example's `package.json` lacks the `typescript` peer dependency of
`@rollup/plugin-typescript`, hence the extra install. A built copy is on the
VM at `<dev>/mysql/mrs_scripts` (no `node_modules`; the upload doesn't need it).

### Windows (VM `ssh <windows-vm>`, Windows 11 **ARM64**, VS 2022 Professional 17.14)

x64 binaries run under Windows' built-in emulation. The GraalVM CE 23.0.1 on the VM is the
**x64** Windows build (GraalVM has no Windows ARM64 release), so `libjitexecutor.dll` is x64,
which fits an x64 `mrsd` linked against the x64 MySQL package.

JIT library build (~25 min under emulation), `<win-home>\mrsd-polyglot-build.cmd`:
```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
set JAVA_HOME=<win-dev>\graalvm-community-openjdk-23.0.1+11.1
set GRAALJDK_ROOT=<win-dev>\graal-jdk-23.0.1
set PATH=%JAVA_HOME%\bin;<win-dev>\apache-maven-3.9.16\bin;%PATH%;C:\Program Files\Git\usr\bin
cd /d <win-dev>\shell\ext\polyglot
mvn -B package
```
`vcvars64.bat` is required. Without it native-image sets up MSVC itself, and the
environment it passes to its build process has both `PATH` (with MSVC) and `Path`
(without). Only one takes effect on Windows, and the build fails at step 1/8 with
"Default native-compiler executable 'cl.exe' not found".

Two things are required, and the first failure hides the second:
- Git's `usr\bin` on PATH: `maven-patch-plugin` runs GNU `patch`. Without it,
  `enhancements.patch` isn't applied, and because the `prepare-sources` profile only runs
  while `polyglot-nativeapi/src/main/java/org` doesn't exist, **later runs silently build
  the unpatched API**. The result is missing `poly_value_is_exception`, `poly_context_eval_source`
  and others, and `jit_executor` doesn't compile. Check that `polyglot-nativeapi/target/patches-applied.txt`
  lists `enhancements.patch`. To recover, delete `polyglot-nativeapi/src/main/java/org`,
  `polyglot-nativeapi/src/main/resources` and both `target` dirs (or `mvn -Ddev clean`).
- `vcvars64.bat` (MSVC PATH/Path clash, see below).

mrsd build (`<win-home>\mrsd-win.cmd configure|build`; source `<win-home>\mrsd`):
```bat
call "...\VC\Auxiliary\Build\vcvarsall.bat" arm64_amd64   & rem native ARM64-hosted compiler, x64 target
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DMYSQL_PACKAGE_DIR=<win-home>\Downloads\mysql-26.7.0-winx64 ^
  -DOPENSSL_ROOT_DIR=<win-home>\mrsd-deps\vcpkg\installed\x64-windows ^
  -DICU_ROOT=<win-home>\mrsd-deps\icu ^
  -DMRS_JIT_EXECUTOR_LIB=<win-dev>\shell\ext\polyglot\polyglot-nativeapi-native-library\target
ninja -C build
```
- OpenSSL 3.6.3 x64: `<win-dev>\vcpkg\vcpkg.exe install openssl:x64-windows --classic` with
  `--x-install-root/--x-buildtrees-root/--x-packages-root/--downloads-root` under `<win-home>\mrsd-deps\vcpkg` (F: is full)
- ICU 78.3 x64: official `icu4c-78.3-Win64-MSVC2022.zip` in `<win-home>\mrsd-deps\icu`
- RelWithDebInfo so everything uses the release C runtime, like the prebuilt deps
- Smoke test: Git Bash script `<win-home>\mrsd-smoke.sh` (DLL dirs on PATH; MySQL Shell
  26.7.0 Windows zip in Downloads, whose bundled `lib/mysqlsh/plugins` serves as SHELL_PLUGINS;
  built mrs_scripts in `<win-home>\mrsd-deps\mrs_scripts`)
- Source sync from the Mac: commits exported with `git format-patch` from `refs/win/synced..main`,
  served briefly over HTTP on <host-ip>, applied with `git am` (the VM's sshd has no SFTP
  and stdin streaming to PowerShell never sees EOF)

Notes for driving the VM over SSH:
- Processes started with `Start-Process` die when the SSH session ends; run long builds in the foreground.
- Send PowerShell as `-EncodedCommand` from a quoted heredoc (zsh's `echo` mangles `\U`, `\e` in paths).
- Drive F: is nearly full (0.55 GB free after the JIT build); C: has ~12 GB.

### Linux (Ubuntu VM `<ubuntu-vm>`, `ssh <ubuntu-vm>`, aarch64)

Source: `<dev>/mrsd`, a git repo that accepts pushes (`receive.denyCurrentBranch=updateInstead`).
On the Mac: `git push vm main` (remote `vm`). Assets live in `<dev>/mysql/`:
- `mysql-26.7.0-linux-glibc2.28-aarch64/` (server package)
- `mysql-shell-26.7.0-linux-glibc2.28-arm-64bit/`
- `mysql-shell-plugins/mrs_plugin/db_schema` (copied from the Mac)
- `deps/`: no-root workarounds (see below)

```sh
cd <dev>/mrsd; L=/usr/lib/aarch64-linux-gnu; D=<dev>/mysql
cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Debug \
  -DMYSQL_PACKAGE_DIR=$D/mysql-26.7.0-linux-glibc2.28-aarch64 \
  -DICU_INCLUDE_DIR=$D/deps/icu/usr/include \
  -DICU_UC_LIBRARY_RELEASE=$L/libicuuc.so.78 \
  -DICU_I18N_LIBRARY_RELEASE=$L/libicui18n.so.78 \
  -DICU_DATA_LIBRARY_RELEASE=$L/libicudata.so.78
make -C build -j8
LD_LIBRARY_PATH=$D/deps/lib MRSD_BUILD=$PWD/build \
  MYSQL_PACKAGE_DIR=$D/mysql-26.7.0-linux-glibc2.28-aarch64 \
  MYSQLSH=$D/mysql-shell-26.7.0-linux-glibc2.28-arm-64bit/bin/mysqlsh \
  SHELL_PLUGINS=$D/mysql-shell-plugins tools/smoke/run_smoke.sh /tmp/mrsd-smoke
```
The VM has no passwordless sudo, so there are three workarounds, none of them needed if
`sudo apt install libicu-dev ninja-build` is run once:
- ICU headers: `apt-get download libicu-dev` unpacked into `deps/icu` (78.2, matches the installed runtime)
- no ninja: Makefiles generator
- `deps/lib/libaio.so.1 -> libaio.so.1t64` for the package's mysqld (Ubuntu 24.04+ renamed it)
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
- [x] Linux build + smoke test (Ubuntu 26.04 aarch64, GCC 15.2, Debug, no JIT; `ldd -r` finds no unresolved symbols)
- [x] Linux with JIT (`-DMRS_JIT_EXECUTOR_LIB=<dev>/mariadb-shell/ext/polyglot/polyglot-nativeapi-native-library/target`, build dir `build-jit`)
- [x] JIT exercised end to end on macOS and Linux: smoke test with `MRS_SCRIPTS_DIR` deploys the
  mrs_scripts example with `LOAD SCRIPTS`; `GET /smoke/testScripts/helloWorld` →
  `{"status":"ok","result":"Hello world!"}`
- [x] Windows build + smoke test (x64, RelWithDebInfo, JIT; REST view + MRS script OK)

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
1. Decide on duktape (open question 1), then start Phase 2 with the unit tests
   (GTest setup, `tests/data/ssl`, `benchmark.h`) on all three platforms.


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

### 2026-09-30: session 1, continued (Linux)
- Ubuntu 26.04 aarch64 VM (UTM, <ubuntu-vm-ip>). Downloaded MySQL 26.7.0 server
  and Shell for Linux arm64; copied the MRS schema scripts from the Mac.
- The build succeeded without source changes. `ldd -r` then showed
  `mysql_rest_service.so` missing `MySQLSession` symbols: upstream got
  `router_mysql` through the routing plugin. Fixed in `f23c35e` (on macOS it only
  worked because the JIT plugin, or flat symbol lookup, pulled the library in).
- Smoke test passes on Linux.

### 2026-09-30: session 1, continued (JIT on Linux, JIT end to end)
- Linux JIT build against the VM's polyglot build: clean, no unresolved symbols.
- The smoke test got an optional MRS scripts step (`MRS_SCRIPTS_DIR`); it passes on
  macOS and Linux, so the JIT executor runs TypeScript MRS scripts on both.

### 2026-09-30: session 1, continued (Windows JIT library)
- The Windows polyglot build failure was the MSVC PATH/Path clash described in the
  Windows section, not the source (`ext/polyglot` is identical across the three checkouts).
  Built with `vcvars64.bat`: `libjitexecutor.dll` (x64, 176 MB) + `.lib` + headers.

### 2026-09-30: session 1, continued (Windows, Phase 1 complete)
- Found why the shell project's Windows polyglot build failed: (1) MSVC PATH/Path clash
  → fixed with `vcvars64.bat`; (2) GNU `patch` not on PATH, so `enhancements.patch` was
  never applied and later runs built the unpatched API → Git's `usr\bin` on PATH plus a
  source reset. The rebuilt `libjitexecutor.dll` has the patched API.
- mrsd on Windows (x64, cross-compiled by the ARM64-hosted MSVC): fixes were
  the server's Windows compile definitions (`NOGDI` etc.), a Windows-only
  `using` guard in `router_app.cc`, the target architecture in `--version`, and
  the stale-DLL copy in `ROUTER_COPY_CUSTOM_DLL`.
- Smoke test (REST view + MRS script) passes on Windows under Git Bash.
