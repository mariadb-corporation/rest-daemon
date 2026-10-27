# Progress log

Plan: [PLAN.md](PLAN.md). Current state and next steps: `.claude/PROJECT_CONTEXT.md`
(`/checkpoint`). This file keeps the build/test how-to and a session log entry per session.

Paths of the development machines are written with placeholders: `<dev>` (the development
directory of the machine at hand), `<home>`, `<downloads>`; on the Windows VM `<win-home>`
(the user profile) and `<win-dev>` (the build drive); the VMs as `<windows-vm>`,
`<ubuntu-vm>`, `<fedora-vm>` (ssh targets), the Mac as `<host-ip>` / `<hostname>`. Their
values are kept outside the repository (a local `CLAUDE.local.md`). The Windows VM helper
scripts (`tools/vm/win.sh`, `win_sync.sh`, `win_wip.sh`) are local tooling, not in the
repository.

## Status

| Phase | Status |
|---|---|
| 0: dependency inventory | ✅ done 2026-09-30, verdict GO ([phase0-inventory.md](phase0-inventory.md)) |
| 1: new repo that builds | ✅ done 2026-09-30: macOS, Linux, Windows (x64), with JIT; smoke test incl. MRS scripts passes on all three |
| 2: tests and ecosystem validation | ✅ done 2026-10-05: unit + component tests (116/116) and MRS functional suite pass on Linux, macOS, Windows; CI moved to the end (Phase 4) |
| 3: MRS setup and cleanup | ✅ done 2026-10-05: branding (`mariadb-restd`), `--setup`, routing/cluster cleanup; tests pass on all three platforms |
| 4: packaging and CI | ⏸ moved to Milestone 4 (2026-10-07): tar.gz (Linux, macOS), deb, rpm, Windows ZIP done and verified (unpacked); real deb/rpm installs need root; MSI deferred; CI last |

**Milestone 1 (standalone daemon) is complete (2026-10-07). Milestone 2 (MariaDB) is complete (2026-10-13).** **Milestone 3 (schema 5.0.0) is complete (2026-10-14).** Milestone 5's release pipeline (builds, verification, publishing) is in place (2026-10-15). Next: the JSON-columns open point, then Milestone 4.

| Milestone 2 phase | Status |
|---|---|
| M2.0: MariaDB dependency inventory | ✅ done 2026-10-07, verdict GO in stages ([milestone2-inventory.md](milestone2-inventory.md)) |
| M2.1: build against MariaDB Connector/C | ✅ done 2026-10-09: build + ctest 113/113 on macOS (3.4.11), Linux (3.4.9) and Windows (3.4.8, vcpkg); the MySQL build was kept as the safety net until 2026-10-13 |
| M2.2: run against a MariaDB server | ✅ done 2026-10-12: smoke test incl. MRS scripts passes on macOS (MariaDB 13.2), Windows and Ubuntu (11.8.9 LTS) |
| M2.3: test suites on MariaDB | ✅ done 2026-10-13: MRS suite on macOS (13.2) and Windows (11.8.9) 100 passed, 0 failed, 14 skipped, 7 xfailed (known differences), 1 xpassed; Ubuntu (11.8.9) 101 passed, 0 failed (2026-10-12); unit + component 113/113 on all three; MySQL mode unchanged (116/5/1). Live-DB unit tests: MySQL 104/104 (macOS); MariaDB 102/104 on macOS, Ubuntu and Windows (the JSON-columns open point). M2.3 exit criteria met |
| M2.4: cleanup | ✅ done 2026-10-13: async tasks removed; MySQL build and server support dropped; follow-ups (pass-through role, SET STATEMENT timeouts, VECTOR coverage + 3 daemon fixes, 2026 kill mapping); `restd:` markers. Suite on Ubuntu 110 passed, 0 failed, 6 skipped, 5 xfailed, 1 xpassed |

## How to build and test (macOS)

Since 2026-10-13 the project is MariaDB-only: one build (`build-mariadb`, MariaDB
Connector/C), one server flavor. The MySQL build (`build-test`/`build-jit`,
`-DMYSQL_PACKAGE_DIR`) and the MySQL modes of the suites are gone; the state before that
is tag `m2-pre-build-decision`.

### Build (`build-mariadb`)

```sh
brew install mariadb-connector-c   # 3.4.x, OpenSSL; keg-only
cmake -S . -B build-mariadb -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DMARIADB_CONNECTOR_DIR=/opt/homebrew/opt/mariadb-connector-c \
  -DMRS_JIT_EXECUTOR_LIB=$PWD/ext/polyglot/polyglot-nativeapi-native-library/target \
  -DWITH_UNIT_TESTS=ON -DWITH_COMPONENT_TESTS=ON
ninja -C build-mariadb
```
What Connector/C lacks of the client API the code was written for is evened out in
`compat/include/mrsd/compat_client.h` (ssl-mode enum, type codes, `effective_field_type()`).

Connector/C on the VMs (the finder accepts a Connector/C package, Homebrew, a Debian
`libmariadb-dev` tree and vcpkg's layout):
- Ubuntu (no root): `apt-get download libmariadb-dev libmariadb3 libmariadb-dev-compat`
  unpacked with `dpkg -x` into `<dev>/mysql/deps/mariadb-connector/root`, then
  `-DMARIADB_CONNECTOR_DIR=$D/deps/mariadb-connector/root/usr` (Connector/C 3.4.9 from
  the 11.8.6 packages; multiarch `lib/aarch64-linux-gnu`, plugins in `libmariadb3/plugin`).
  Build dir `build-mariadb`, JIT from `<dev>/mariadb-shell/ext/polyglot/.../target`.
- Windows: vcpkg port `libmariadb[openssl]:x64-windows` (3.4.8) into the existing
  `<win-home>\mrsd-deps\vcpkg` roots; headers in `include/mysql`, plugins in
  `plugins/libmariadb`. `<win-home>\mrsd-win-mariadb.cmd configure|build|ctest`
  (build dir `<win-dev>\mrsd-build-mariadb`, tests on; C: is nearly full, F: was enlarged to
  40 GB with `Resize-Partition`. C: can't grow past the recovery partition behind it).
- Older Connector/C headers (3.4.8, 3.4.9) lack `MYSQL_TYPE_VECTOR`; `compat_client.h`
  supplies it. The Linux `libmariadb.so.3` doesn't export the `client_errors` tables, so
  `client_error_message()` keeps its own table.

### MRS functional suite (pytest, `tests/mrs`)

See the docstring of `tests/mrs/conftest.py`.
```sh
python3 -m venv build-mariadb/mrs-venv && build-mariadb/mrs-venv/bin/pip install -r tests/mrs/requirements.txt pytest-xdist
MRSD_BUILD=$PWD/build-mariadb MARIADB_BUILD_DIR=<dev>/mariadb-server/light-build \
MARIADB_SOURCE_DIR=<dev>/mariadb-server \
  build-mariadb/mrs-venv/bin/python -m pytest tests/mrs -q -n 4 [-k <test>] [--record]
```
- `include/schema/mariadb_rest_service-5.0.0.sql` is MariaDB Shell's 5.0.0 deployment
  script, generated by `tools/analysis/make_test_schema.py` from the shell repo's `main`
  (`git show`; markers removed, `--` comments turned into `#`, the seeded `MariaDB` auth
  app left out). Regenerate it when the shell's script changes.
- The daemon the suite starts has the fixed id `10000000-0000-7000-8000-000000000001`
  (`$extra_mrs_router_id`, `conftest.py`). A value starting with `0` reads as false in
  mysqltest's `if`, and every UUID v7 does: test id-valued variables with `== ''` or
  `` `SELECT $v IS NOT NULL` ``.
- The scripts and fixtures carry MariaDB's SQL: upstream's MySQL-only constructs (JSON
  arrows, SRID attributes, `VECTOR` without a dimension, `FROM_BASE64` of placeholders,
  `super_read_only`, `role_edges`, `performance_schema.processlist`, `auth_socket`, `SET
  PASSWORD`, `RESET BINARY LOGS AND GTIDS`, `CAST AS JSON`) were rewritten in the files
  (M3.1, 2026-10-13, statement-aware through the suite's own parser); the results are
  recorded on MariaDB and compared as they are. The interpreter keeps two MariaDB-isms:
  `DROP USER` of a role is retried as `DROP ROLE`, and MariaDB's timing-dependent note
  4227 on `DROP USER` is not printed.
- Smoke test: `MARIADB_BUILD_DIR=... MARIADB_SOURCE_DIR=... (or MARIADB_PACKAGE_DIR=...)
  MYSQLSH=<dev>/shell/bld/bin/mariadb-shell SHELL_PLUGINS=<dev>/mariadb-shell-plugins
  tools/smoke/run_smoke.sh` (plus `MRS_SCRIPTS_DIR` for the scripts step). The shell must be
  26.10.2 or later (built-in REST SQL, `CONFIGURE REST METADATA` with the bundled 5.0.0);
  `SHELL_PLUGINS` is optional (msm `deploySchema`; needed for the scripts step).
- needs a build with `-DWITH_UNIT_TESTS=ON` (for `mysqlrouter_mrs_client`)
- `t/*.test` + `r/*.result` are upstream's `mysql-test/suite/router`, unchanged except
  `include/mysqlrouter_shutdown.inc` (router stop via harness hook) and the copyright lines
- `mrstest/mysqltest.py`: interpreter for the mysqltest subset (follows client/mysqltest.cc);
  `mtr_include/`: the mtr-level includes the suite sources, some replaced by harness hooks
- `disabled.def`: disabled tests with reasons; bootstrap/InnoDB Cluster tests weren't copied
- a failing test leaves `<name>.reject` in its pytest tmp dir (path in the failure message)
- `known_failures.def`: expected failures (xfail) with reasons
- `mysqltest` from the server build (`ninja mysqltest` in mysql-server/build) is useful to
  check what the real interpreter does with a construct

### Live-DB unit tests (`routertest_mrs_plugin`)
`DatabaseQuery*` and `JsonMapping*` start their own server when `RUN_WITH_LIVE_MYSQLD=1`
(`tests/helpers/shared_server.cc`); otherwise they are skipped.
```sh
# MARIADB_BUILD_DIR + MARIADB_SOURCE_DIR, or MARIADB_PACKAGE_DIR=<package>
RUN_WITH_LIVE_MYSQLD=1 MARIADB_BUILD_DIR=<dev>/mariadb-server/light-build \
MARIADB_SOURCE_DIR=<dev>/mariadb-server \
  build-mariadb/runtime_output_directory/routertest_mrs_plugin \
  --gtest_filter='DatabaseQuery*.*:JsonMapping*.*'
```
- 102/104; the 2 `special_types` failures are the JSON-string write limitation
  (docs/mariadb-differences.md, the JSON-columns open point)
- Ubuntu: same command in `<dev>/mrsd/build-mariadb` with
  `MARIADB_PACKAGE_DIR=<downloads>/mariadb-11.8.9-linux-glibc2.34-arm-64bit-sandbox`.
  Windows: `<win-home>\mrsd-live-mariadb.cmd [gtest args]` (vcvars, the build's
  `runtime_output_directory` and `plugin_output_directory` on PATH, the shell's `bin` last
  for the ARM64 server's OpenSSL DLLs; without them: exit 0xC0000135, DLL not found)

### MRS scripts (JIT) step of the smoke test

Set `MRS_SCRIPTS_DIR` to a built copy of `mariadb-shell-plugins/mrs_plugin/examples/mrs_scripts`
(built on the Mac, since the VM has no Node.js); it is uploaded with the plugin's
`mrs.load.content_set()`:
```sh
rsync -a --exclude node_modules --exclude build \
  <dev>/mariadb-shell-plugins/mrs_plugin/examples/mrs_scripts/ <dir>/
# the example still grants on the 4.x schema (2026-10-13): fix the copy
sed -i '' 's/mysql_rest_service_metadata/mariadb_rest_service/g' <dir>/src/MrsScriptModule.ts
cd <dir> && npm install && npm install --save-dev typescript@5 && npm run build
```
The example's `package.json` lacks the `typescript` peer dependency of
`@rollup/plugin-typescript`, hence the extra install. A built copy is on the
VM at `<dev>/mysql/mrs_scripts` (no `node_modules`; the upload doesn't need it).

### Windows (VM `ssh <windows-vm>`, Windows 11 **ARM64**, VS 2022 Professional 17.14)

x64 binaries run under Windows' built-in emulation. The GraalVM CE 23.0.1 on the VM is the
**x64** Windows build (GraalVM has no Windows ARM64 release), so `libjitexecutor.dll` is x64,
which fits an x64 `mrsd` linked against the x64 Connector/C (vcpkg).

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

mrsd build (`<win-home>\mrsd-win-mariadb.cmd configure|build|ctest`; source
`<win-home>\mrsd`, build dir `<win-dev>\mrsd-build-mariadb`; the old `mrsd-win.cmd` built
against the MySQL package and is obsolete):
```bat
call "...\VC\Auxiliary\Build\vcvarsall.bat" arm64_amd64   & rem native ARM64-hosted compiler, x64 target
cmake -S . -B <win-dev>\mrsd-build-mariadb -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DMARIADB_CONNECTOR_DIR=<win-home>\mrsd-deps\vcpkg\installed\x64-windows ^
  -DOPENSSL_ROOT_DIR=<win-home>\mrsd-deps\vcpkg\installed\x64-windows ^
  -DICU_ROOT=<win-home>\mrsd-deps\icu ^
  -DMRS_JIT_EXECUTOR_LIB=<win-dev>\shell\ext\polyglot\polyglot-nativeapi-native-library\target
ninja -C <win-dev>\mrsd-build-mariadb
```
- OpenSSL 3.6.3 x64: `<win-dev>\vcpkg\vcpkg.exe install openssl:x64-windows --classic` with
  `--x-install-root/--x-buildtrees-root/--x-packages-root/--downloads-root` under `<win-home>\mrsd-deps\vcpkg` (F: is full)
- ICU 78.3 x64: official `icu4c-78.3-Win64-MSVC2022.zip` in `<win-home>\mrsd-deps\icu`
- RelWithDebInfo so everything uses the release C runtime, like the prebuilt deps
- Smoke test: Git Bash script `<win-home>\mrsd-smoke-mariadb.sh` (DLL dirs on PATH; the
  MariaDB 11.8.9 sandbox server and mariadb-shell 26.10.2 packages in Downloads, the shell's
  `lib/mariadb-shell/plugins` as SHELL_PLUGINS; built mrs_scripts (5.0 copy) in
  `<win-home>\mrsd-deps\mrs_scripts-5`). `mrsd-smoke.sh` (MySQL) is obsolete.
- Source sync from the Mac: `tools/vm/win_sync.sh` (`BRANCH=<branch>` to sync another branch than `main`; commits since `refs/win/synced`, via
  `git format-patch`, served briefly over HTTP on <host-ip>, applied with `git am`: the
  VM's sshd has no SFTP and stdin streaming to PowerShell never sees EOF);
  `tools/vm/win_wip.sh` copies uncommitted changes. `refs/win/synced` is local to the Mac
  clone: if it's missing, set it to the commit the Windows clone has (`git log -1` there).
  If `win_sync.sh` reports the old commit with `dirty: 0`, an earlier run's `git am`
  failed (dirty clone) and left `.git\rebase-apply` behind: `git am --abort` on the VM,
  `git update-ref refs/win/synced <Mac commit matching the clone's HEAD>`, run it again.
- Run PowerShell on the VM: `tools/vm/win.sh <<'PS' ... PS` (quoted heredoc).

- MRS functional suite: `powershell -File <win-home>\mrsd-pytest-mariadb.ps1 -q -n 4 [-k <test>]`
  (venv `<win-home>\mrsd-venv` from the ARM64 Python 3.14; puts the DLL dirs and Git's
  `usr\bin` on PATH, for the perl the tests' `--perl` blocks need; ~11 min with 4 workers;
  `mrsd-pytest.ps1` (MySQL) is obsolete). Like mysqltest
  on Windows, `exec` runs through `cmd.exe /c`, with `echo` replaced by a quote-stripping
  echo (`mrstest/echo.py` in place of mysqltest's `echo.exe`) and `/dev/null` by `NUL`.
  Redirect pytest's output to a file on the VM and read it back: long runs over SSH lose the
  end of the output.

Notes for driving the VM over SSH:
- Processes started with `Start-Process` die when the SSH session ends; run long builds in the foreground.
- Send PowerShell as `-EncodedCommand` from a quoted heredoc (zsh's `echo` mangles `\U`, `\e` in paths).
- Drive F: is nearly full (0.55 GB free after the JIT build); C: has ~12 GB.

### Linux (Ubuntu VM `<ubuntu-vm>`, `ssh <ubuntu-vm>`, aarch64)

Source: `<dev>/mrsd`, a git repo that accepts pushes (`receive.denyCurrentBranch=updateInstead`).
On the Mac: `git push vm main` (remote `vm`). Assets: the MariaDB 11.8.9 sandbox server
and mariadb-shell 26.10.2 packages in `<downloads>` (the smoke wrapper uses 26.10.2 and
`<dev>/mrs_scripts-5`), Connector/C in
`<dev>/mysql/deps/mariadb-connector/root/usr` (see "Connector/C on the VMs" above),
`<dev>/mysql/deps/`: no-root workarounds (see below). The old MySQL assets in `<dev>/mysql/`
(server package, MySQL Shell, mysql-shell-plugins) are unused now.

```sh
cd <dev>/mrsd; L=/usr/lib/aarch64-linux-gnu; D=<dev>/mysql
cmake -S . -B build-mariadb -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Debug \
  -DMARIADB_CONNECTOR_DIR=$D/deps/mariadb-connector/root/usr \
  -DMRS_JIT_EXECUTOR_LIB=<dev>/mariadb-shell/ext/polyglot/polyglot-nativeapi-native-library/target \
  -DWITH_UNIT_TESTS=ON -DWITH_COMPONENT_TESTS=ON \
  -DICU_INCLUDE_DIR=$D/deps/icu/usr/include \
  -DICU_UC_LIBRARY_RELEASE=$L/libicuuc.so.78 \
  -DICU_I18N_LIBRARY_RELEASE=$L/libicui18n.so.78 \
  -DICU_DATA_LIBRARY_RELEASE=$L/libicudata.so.78
make -C build-mariadb -j8
<dev>/mrsd-smoke-mariadb.sh      # wrappers: smoke test and <dev>/mrsd-pytest-mariadb.sh
```
The VM has no passwordless sudo, so there are two workarounds, neither needed if
`sudo apt install libicu-dev ninja-build` is run once:
- ICU headers: `apt-get download libicu-dev` unpacked into `deps/icu` (78.2, matches the installed runtime)
- no ninja: Makefiles generator
From the build tree, restd finds `<build>/plugin_output_directory` without a `plugin_folder` option.

### Fedora (VM `ssh <fedora-vm>`, Fedora 44, aarch64): rpm packages

Source: `<dev>/mrsd`, accepts pushes (`git push fedora main`, remote `fedora`). The JIT
library + headers are in `<dev>/jit/target` (built on Ubuntu, same glibc 2.43). GCC 16,
CMake 4.3, openssl-devel and libicu-devel are installed; no ninja. Not rebuilt since the
switch to Connector/C (2026-10-13): it needs a Connector/C (`mariadb-connector-c-devel`
or an unpacked package) and `-DMARIADB_CONNECTOR_DIR` in place of the MySQL package:
```sh
cd <dev>/mrsd
cmake -S . -B build-sys -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DINSTALL_LAYOUT=SYSTEM -DCMAKE_INSTALL_PREFIX=/usr \
  -DMARIADB_CONNECTOR_DIR=<connector prefix> -DMRS_JIT_EXECUTOR_LIB=<dev>/jit/target
make -C build-sys -j8 && (cd build-sys && cpack -G RPM)
```
`rpm-build` is installed (a user-local copy doesn't work, its macros hard-code
`/usr/lib/rpm` helpers). No passwordless sudo, so no real `dnf install` test yet.

### Packages (Phase 4)
- STANDALONE: `cpack -G TGZ` (Linux, macOS), `cpack -G ZIP` (Windows, `<win-home>\mrsd-cpack.cmd`
  in the `build` dir). SYSTEM (`-DINSTALL_LAYOUT=SYSTEM -DCMAKE_INSTALL_PREFIX=/usr`):
  `cpack -G DEB` (Ubuntu VM, `build-sys`), `cpack -G RPM` (Fedora VM).
- Verify an unpacked package with the smoke test: `MRSD_INSTALL=<unpacked prefix>`
  (`MRSD_PLUGIN_FOLDER=<prefix>/lib/mariadb-restd` for deb/rpm contents, whose defaults are
  absolute; `MRSD_SETUP_DEFAULT_FOLDERS=1` for `--setup` without `-d`). Windows ZIP:
  `<win-home>\mrsd-smoke-zip.sh` (no build-time DLL dirs on PATH).

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

## Phase 2 checklist
- [x] GoogleTest 1.17.0 + duktape 2.7.0 vendored; TLS test data; benchmark helper
- [x] mock server without X (step 1.7)
- [x] unit tests (99 executables) pass on macOS; MRS DB tests run against package mysqld
- [x] component tests: 17 suites pass on macOS (`-DWITH_COMPONENT_TESTS=ON`), 105 cases excluded
- [x] Windows: 116/116 (duktape shared, plugin dir on test PATH, ws2_32, signal_me→compat,
      crash-handler symbols, eventlog routing case excluded, id_mismatch waits for exit)
- [x] Linux: unit + component tests (116/116)
- [x] MTR suite → pytest harness (`tests/mrs`) on macOS: 113 passed, 1 known failure, 7 skipped
      (2 disabled bootstrap tests, 3 for metadata schema v2/v3, 1 needs mysql_no_login, 1 not on macOS)
- [x] MRS functional suite on Linux: 114 passed, 6 skipped, 1 xpassed
- [x] MRS functional suite on Windows: 113 passed, 7 skipped, 1 xpassed
- [x] integration tests (tests/integration): triaged, all routing tests, removed
- [x] CI: moved to the end of the work (Phase 4), waits for the final remote

## Phase 3 checklist
- [x] branding: `mariadb-restd`, "MariaDB REST Service Daemon" (names in `cmake/settings.cmake`)
- [x] `--setup` (directory deployment), tests `setup_mrs_*`, smoke test uses it
- [x] `--setup` verified on all three platforms (MRS suite, smoke test incl. MRS scripts):
      macOS 116 passed/5 skipped, Linux 117/4, Windows 116/5 (each + 1 xpassed); unit +
      component 116/116 everywhere
- [x] cleanup of routing/cluster leftovers (stages 1, 2a, 2b)

## Open questions
See `.claude/PROJECT_CONTEXT.md` (`/read-checkpoint`).

## Resolved questions
- JIT: `-DMRS_JIT_EXECUTOR_LIB=<dir>` (lib + headers), built from `ext/polyglot` in this repo
  (copied from the MySQL Shell sources 2026-10-07; GraalVM 23.0.1 in `<dev>/graalvm-community-openjdk-23.0.1+11.1`,
  sources in `<dev>/graal-jdk-23.0.1`). The VMs still build it in their shell checkouts.
- Client library: from a MySQL server package, `-DMYSQL_PACKAGE_DIR=<path>`. Local: `<dev>/mysql/mysql-26.7.0-macos15-arm64`.
- ICU: keep it (performance, Bug#36797250).
- Copyright notices: mariadb-shell recipe, `.githooks/pre-commit` linked by the configure step.
- Repository: `github.com/mariadb-corporation/rest-daemon` (private), local clone
  `<dev>/rest-daemon` (moved there 2026-10-07 from `<dev>/mysql/mrsd`).

## Next steps
See `.claude/PROJECT_CONTEXT.md` (`/read-checkpoint`), kept up to date by `/checkpoint`.

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
- Source changes (behaviour changes marked `restd:` in comments; mechanical ones not):
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

### 2026-09-30: session 1, continued (Phase 2: unit + component tests)
- Test build: `-DWITH_UNIT_TESTS=ON [-DWITH_COMPONENT_TESTS=ON]`, build dir `build-test`.
- Fixes: `WITH_ROUTER` set in build_env (gates harness tests), harness
  `get_tests_data_dir()` path, `shared_server` uses the package mysqld
  (`MRSD_MYSQL_PACKAGE_DIR`), helpers split, `cluster_metadata_types.h` for the
  component helpers, `test_mrs_config` rewritten for `mysql_read_write_destinations`.
- macOS: 116/116 test executables pass (99 unit, 17 component).
- Windows (unit): 98/99; fixes for the mock server (duktape → shared lib) and
  `routertest_mrs_plugin` (plugin dir on test PATH) pending verification.
- Decided: MTR suite → pytest + golden files.

### 2026-09-30: session 1, continued (MRS functional suite → pytest)
- Unit + component tests pass on Windows too (116/116).
- `tests/mrs`: pytest harness + mysqltest-subset interpreter; mrs_client copied from
  upstream. First full run on macOS: 25 passed, 89 failed, 7 skipped (7 min).
- Next: work through the failure groups (REST calls failing, `$$` usage in
  add_named_resultset.inc/modify_fields.inc, result mismatches).

### 2026-09-30: session 1, continued (MRS functional suite passing on macOS)
- Interpreter matched to mysqltest in detail (checked against the real binary for
  statement echo/indentation), harness matched to mtr (server options, reset/restart,
  keyring, router config replacement semantics).
- Result: 113 passed, 1 known failure, 7 skipped (~18 min).
- Known issue: `scripting_base_tests` is intermittent (see `tests/mrs/known_failures.def`):
  after the `defaultTimeOut` request times out while its script keeps running, a later
  request can get the previous endpoint's result. Most likely a race in reusing
  JavaScript contexts after a timeout (upstream MRS code); not the JIT library build
  (macOS and Linux builds come from the same sources). Not being handled now.

### 2026-10-05: session 2 (Linux tests, README)
- Linux VM back: unit + component tests 116/116; MRS functional suite 114 passed,
  6 skipped, 1 xpassed. Fixes on the way: per-test server options (`t/<name>.cnf`),
  replace_regex semantics (echoed statement; variable only for the whole argument),
  `__pycache__` no longer tracked. Linux venv: `python3 -m venv --without-pip` +
  get-pip.py (no python3-venv package on the VM).
- macOS rerun: 113 passed, 7 skipped, 1 xpassed.
- `scripting_base_tests` re-diagnosed as an intermittent race after a request
  timeout, not a JIT library difference.
- README.md for mrsd (build, configuration, tests, layout); README.router and
  MRS_README.router marked as upstream docs.

### 2026-10-05: session 2, continued (MRS functional suite on Windows)
- MRS functional suite on Windows: 113 passed, 7 skipped (the macOS set: `destination_socket`
  is not_windows), 1 xpassed. Harness fixes: `exec` through `cmd.exe` with mysqltest's
  Windows replacements (builtin echo, `/dev/null`, `>&-`); `MYSQLTEST_FILE` with forward
  slashes (MSYS perl's `dirname`); stale pid file removed after TerminateProcess; all harness
  file I/O as UTF-8 with LF (the locale code page broke binary results on Windows).
- macOS rerun with these changes: 113 passed, 7 skipped, 1 xpassed.

### 2026-10-05: session 2, continued (integration tests triage)
- `tests/integration` removed: all 11 suites test routing/connection pooling over
  `[routing:...]` sections (plus X protocol client libraries); no MRS coverage.
  `WITH_INTEGRATION_TESTS` option dropped. See the PLAN decision log.
- CI deferred to the end of the work (waits for the final remote). Phase 2 closed.

### 2026-10-05: session 2, continued (Phase 3: branding)
- Program `mariadb-mrsd` (`-keyring`, `-passwd`, `-plugin-info`), product name
  "MariaDB REST Service Daemon", default `mariadb-mrsd.conf`/`.log`, Windows service
  `mariadb-mrsd`; set in `cmake/settings.cmake` (`MRSD_PROGRAM_NAME`,
  `MYSQL_ROUTER_NAME`), exported as `MRSD_PROGRAM_NAME` / `MYSQL_ROUTER_PACKAGE_NAME`
  in `router_config.h`. Tests use the macros; `tests/mrs` and the smoke test read
  the name from `router_config.h`. `--help` examples no longer show `--bootstrap`.
- Stale `mysqlrouter*` binaries in old build trees must be deleted by hand (ninja
  doesn't remove them).

### 2026-10-05: session 2, continued (Phase 3: --setup)
- `mariadb-mrsd --setup <uri> -d <dir>`: `MrsdSetup` in `src/router/src/mrsd_setup.cc`,
  dispatched from `main.cc`; upstream `bootstrap_mysql_account.cc` copied unchanged.
  Writes config (HTTPS 8443, self-signed cert in `data/`), keyring + master key,
  start/stop scripts; registers the instance with the name the MRS plugin computes at
  runtime (verified by the smoke test: one `router` row after start). Rollback via
  AutoCleaner/MySQLAccountsCleaner; `--force` reuses accounts and JWT secret.
- `Vt100Filter::sync()` forwards flushes (std::flush on the filtered stdout was a no-op).
- `tests/mrs`: `exec` gets an empty stdin; bootstrap tests replaced by `setup_mrs_*`.
- Verified on Linux (117 passed, 4 skipped, 1 xpassed; smoke incl. MRS scripts) and
  Windows (116 passed, 5 skipped, 1 xpassed; smoke incl. MRS scripts); unit + component
  116/116 on both. Phase 3 exit criterion (fresh install via `--setup`) met; cleanup remains.

### 2026-10-05: session 2, continued (Phase 3 cleanup, stage 1)
- Removed: `src/destination_status` (routing quarantine plugin, no users); the
  metadata_cache/bootstrap/dynamic_state paths of `router_app.cc` (router id from
  `[metadata_cache]`, single-metadata_cache check, `--bootstrap` usage section, bootstrap
  overwrite rules); 77 component test data files only used by the removed cluster and
  bootstrap tests. "bootstrap" in user messages now says `--setup`.
- `KeyringHandler` takes ROUTER_ID for a master key reader from `[mysql_rest_service]`.
- Tests: `metadata_cache_must_be_single` excluded; `test_bug24909259` uses
  `[mysql_rest_service] mysql_user` to check when the keyring is opened.
- Stage 2 (next): the config-exposure machinery (DynamicConfig, SectionConfigExposer,
  plugins' `expose_configuration`, dynamic_state, configuration schemas): only consumed
  by the router's cluster metadata code, dead in mrsd.
- Stage 2a: removed `DynamicState` (the router's cluster state file, `dynamic_state=`
  option, DIM accessor), the JSON schemas `dynamic_state_schema`,
  `configuration_update_schema` and the unused `configuration_schema.json`, and their
  harness tests (114 unit + component test executables now). `test_mrs_config` no longer
  writes a state file.
- Stage 2b: removed the config-exposure machinery (`DynamicConfig`,
  `SectionConfigExposer`, `Loader::expose_config_all()`, the app-level exposure
  callback, the plugins' `expose_configuration` hook and the last `Plugin` field): it
  published the configuration for the router's cluster metadata and nothing in mrsd read
  it. 113 unit + component test executables.
- After the cleanup: macOS 116 passed/5 skipped, Linux 117/4, Windows 116/5 (each + 1
  xpassed); unit + component 113/113 and smoke test (incl. MRS scripts) on all three.
  Phase 3 done.

### 2026-10-05: session 2, continued (Phase 4: layouts, bundling, macOS tarball)
- Decisions: CPack for all formats; deb + rpm, Linux tar.gz, Windows MSI + ZIP, macOS
  tar.gz; libmysqlclient + JIT always bundled, OpenSSL/ICU bundled except in deb/rpm;
  vendor MariaDB plc (maintainer address still a placeholder, `MRSD_PACKAGE_CONTACT`);
  `VERSION` file with `VERSION = 26.10.0`.
- `cmake/install_layout.cmake`: STANDALONE and SYSTEM layouts from the program name;
  `cmake/paths.cmake` defaults are plain variables (no stale cache), no `mysqlrouter`.
- `cmake/bundle_runtime_libraries.cmake` (last install rule): copies the bundled libs
  (found with file(GET_RUNTIME_DEPENDENCIES); the MySQL package's private OpenSSL loses
  to the build's), on macOS rewrites references to @rpath, drops absolute rpaths and
  re-signs. `CMAKE_INSTALL_RPATH_USE_LINK_PATH` off.
- Docs installed to the doc dir (README.md, MRS_README.router, LICENSE, sample config).
- macOS tar.gz verified: unpacked elsewhere, the smoke test (`MRSD_INSTALL=`) passes and
  the process loads only the bundled OpenSSL/ICU/libmysqlclient.

### 2026-10-05: session 2, continued (Phase 4: Linux and Windows packages)
- Linux tar.gz: bundled ELF libs get RUNPATH `$ORIGIN` (patchelf), otherwise their own
  dependencies came from the system; smoke test incl. MRS scripts passes unpacked.
- deb (SYSTEM layout): systemd unit, sysusers.d/tmpfiles.d, postinst/prerm/postrm;
  Depends from dpkg-shlibdeps (libssl3t64, libicu78, ...); unpacked contents pass the smoke
  test incl. MRS scripts. Not installed for real yet (no root on the VM).
- `--setup` without `-d` (default folders) + `--user`; tested in an unpacked tarball.
- Windows ZIP (with MSVC runtime, libmysql, OpenSSL, ICU): smoke test incl. MRS scripts
  passes with no build-time DLL directories on PATH. MSI deferred.
- Fedora VM added for rpm; build works, `cpack -G RPM` waits for `rpm-build`.
- rpm (Fedora 44): Requires only system libraries (bundled ones excluded), rpm turns the
  sysusers.d file into user()/group() provides; unpacked contents pass the smoke test incl.
  MRS scripts.

### 2026-10-07: session 3 (rename to mariadb-restd)
- `MRSD_PROGRAM_NAME` = `mariadb-restd` (cmake/settings.cmake); tests, README, sample config
  and docs updated; entries above dated before 2026-10-07 keep the old name.
- Code moved to the final repository: `github.com/mariadb-corporation/rest-daemon`
  (private, was empty), clone `<dev>/rest-daemon` with the full local
  history; remotes `vm`/`fedora` for the VM clones, copyright hook linked.
- `ext/polyglot` (JIT executor library build) copied verbatim from the MySQL Shell
  sources (7 files, unchanged since 2025-03); build outputs ignored, excluded from the
  copyright hook. The macOS library is rebuilt from it (the old build dir was removed).
- macOS: rest-daemon built against it (`build-test`), smoke test incl. MRS scripts passes
  (first macOS run with scripts; mrs_scripts copied from the Ubuntu VM to
  `<dev>/mysql/mrs_scripts`).

### 2026-10-07: session 4 (Milestone 1 closed, Milestone 2 inventory)
- Milestone 1 declared complete; Phase 4 (packaging, CI) moved to a final Milestone 3.
- Phase M2.0: four surveys (client API vs Connector/C 3.4.10, SQL emitted by the daemon,
  MRS metadata schema on MariaDB, tests/tools) written up in `docs/milestone2-inventory.md`;
  phases M2.1-M2.4 added to PLAN.md. Key findings: schema 4.1.6 in the MariaDB shell plugins
  already runs on MariaDB (same name and objects, accepted by the daemon's major-only check);
  8 client functions and 9 option enumerators missing in Connector/C; the server-side work is
  JSON document generation, GTID tracking (`session_track_gtids` SET fails on every RW pool
  connection), `mysql_tasks` (not deployed on MariaDB), account setup syntax, and the version
  gate that rejects MariaDB outright.
- 2026-10-08: Milestone 2 decisions recorded (PLAN.md decision log); async tasks and
  GTID/"asof" moved to a new Milestone 3, packaging and CI to Milestone 4.

### 2026-10-08: session 4, continued (Phase M2.1 on macOS)
- `cmake/compat/mariadb_connector.cmake`: `-DMARIADB_CONNECTOR_DIR` (Homebrew
  `mariadb-connector-c` 3.4.11, OpenSSL) defines the same `MySQL::client` target and
  `MYSQL_CLIENT_*` names as the MySQL finder, plus the global `MRSD_CLIENT_MARIADB`.
  The MySQL build is unchanged (decision: keep it).
- `compat/include/mrsd/compat_client.h` carries the differences: `mysql_ssl_mode` enum,
  MySQL-only `MYSQL_TYPE_*` codes, MySQL-only `ER_*` codes mapped to MariaDB's,
  `bind_bool_t` (`MYSQL_BIND::is_null` is `my_bool*` in libmariadb), `is_client_error()`
  (libmariadb has a second client error range, 5000+). `client_errors.cc` uses libmariadb's
  exported tables, `charset.cc` its `mariadb_get_charset_by_nr()`.
- `MySQLSession`: ssl modes emulated with `MYSQL_OPT_SSL_ENFORCE` +
  `MYSQL_OPT_SSL_VERIFY_SERVER_CERT` (VERIFY_CA = VERIFY_IDENTITY; REQUIRED checked after
  connect, since libmariadb silently drops TLS when verification is off and the server has
  none; libmariadb 3.4 defaults to TLS + verification, so the constructor applies
  PREFERRED); nonblocking API on `mysql_*_start()/_cont()` with `MYSQL_OPT_NONBLOCK` set
  lazily and a zero-timeout poll between calls (removed with the async tasks on
  2026-10-13); TLS session cache, `mysql_real_escape_string_quote`, query attributes
  (`mysql_bind_param`), `CR_NO_RESULT_SET`, `CLIENT_LONG_PASSWORD` and the missing option
  aliases behind `#ifdef`.
- Tests: `tests/helpers/mysql_client.h` and `test_mysql_session.cc` adapted (options
  libmariadb can't read back, or reads back differently; `InitCommand` is in no get list,
  its libmariadb get writes to a second out-parameter). macOS: ctest 113/113 on the
  Connector/C build and on the MySQL build from the same sources.
- Linux (Ubuntu VM, Connector/C 3.4.9 from the `libmariadb-dev` packages, unpacked):
  build and ctest 113/113. Needed: `MYSQL_TYPE_VECTOR`/`ER_QUERY_TIMEOUT` for older
  headers, own client error texts (the .so doesn't export the tables), explicit
  `<cstdint>`, and the client plugin directory: libmariadb's auth plugins are dynamic
  and its compiled-in directory is the installed package's, so `MySQLSession` sets
  `MYSQL_PLUGIN_DIR` to the Connector/C's plugin dir recorded at configure time
  (`MRSD_CLIENT_PLUGIN_DIR` in `router_config.h`; `MARIADB_PLUGIN_DIR` in the
  environment wins). Packaging (Milestone 4) must bundle the plugins and point there.
- Windows: Connector/C from vcpkg (`libmariadb[openssl]:x64-windows`, 3.4.8); the first
  build attempt took the VM down (C: and F: had 1.7 GB free). After the user enlarged the
  disks, F: was extended (`Resize-Partition`; C: is blocked by the recovery partition) and
  the build moved to `<win-dev>\mrsd-build-mariadb`. The VM came back with its clock 8 hours
  behind, which makes ninja loop on a "still dirty" manifest: fixed with `Set-Date`.
  Build and ctest 113/113 (2026-10-09; `sd_notify` flaked once, passed on retry);
  `MYSQL_SHARED_MEMORY_BASE_NAME` left out of the option get test on libmariadb.
  **Phase M2.1 done on all three platforms.**

### 2026-10-09: session 5 (Phase M2.2 and M2.3 on macOS)
- `MySQLSession::is_mariadb()` (handshake version string) and
  `helper::is_mariadb_server()` (set at plugin start, for the SQL generators without a
  session) drive the server-specific SQL. Ported: version gate (MariaDB 10.11+), `--setup`
  accounts (`IDENTIFIED BY`, one default role), RW pools without `session_track_gtids`,
  no `SET ROLE ALL`, `read_only` (ON/OFF), `->`/`->>` → `JSON_EXTRACT` (both servers),
  UUID generation, `VALUES()` upserts, no JSON cast, `VEC_FromText`/`VEC_ToText`,
  `ST_GeomFromGeoJSON` without SRID, `JSON_EXTRACT(...,'$')` around `ST_AsGeoJSON`/
  `VEC_ToText` so they nest as JSON. Measured on 13.2: JSON columns, subqueries,
  `COALESCE` and booleans nest correctly in `JSON_OBJECT`; only those two functions needed
  the wrapper. The GTID helpers of `asof` refuse MariaDB (Milestone 3).
- Prepared `CALL`s on libmariadb: no metadata/bind/fetch on a result without fields,
  `-1` from `mysql_stmt_next_result()` is the end.
- Smoke test in MariaDB mode (mariadbd from the server build, mariadb-shell with the
  MariaDB plugins; `mariadb-install-db`'s anonymous accounts shadow every `'%'` account
  for local connections and are dropped) passes incl. MRS scripts; the MySQL mode still
  passes. Ad-hoc CRUD on a table with JSON, GEOMETRY, VECTOR, BOOLEAN columns OK.
- `tests/mrs` MariaDB mode (above). First full run in progress.
- The upstream-change comment marker is `restd:` now (was `mrsd:`).

### 2026-10-09: session 5, continued (Phase M2.3: the MRS suite on MariaDB)
- Full MariaDB-mode runs went 55 → 80 → 94 → 97 passed (0 failed in the end) with:
  - daemon: JSON/VECTOR from Connector/C's extended column metadata
    (`mrsd::effective_field_type()`), DATETIME/TIMESTAMP/TIME with microseconds like
    MySQL's JSON_OBJECT, integer display widths stripped from the OpenAPI output,
    geometry equality filters with the column's SRID (`ST_GeomFromWKB(ST_AsBinary(v),
    ST_SRID(col))`: MariaDB compares SRIDs and has no column SRID attribute), prepared
    CALLs without metadata/bind/fetch on field-less results, best-effort default role.
  - harness: `mrstest/mariadb_sql.py` rewrites (SRID attribute, VECTOR→BLOB in DDL only,
    vector functions, CAST AS JSON, SRS_ID, JSON arrows, FROM_BASE64 guard with
    whitespace, RESET BINARY LOGS AND GTIDS, super_read_only, role_edges→roles_mapping,
    performance_schema.processlist, mysql.user column aliases) and output normalisation
    (sorted keys, etags, lengths, integral floats, gtid lines); MariaDB result files for
    13 tests; failure messages made printable (binary responses crashed xdist workers).
  - `docs/mariadb-differences.md`: what behaves differently on MariaDB, for users.
- MariaDB reports `RETURNS JSON` routine results and JSON parameters as LONGTEXT
  everywhere: JSON function results stay strings (documented).
- MySQL mode of the suite after the harness changes: 116 passed, 5 skipped, 1 xpassed.

### 2026-10-12: session 6 (Windows against MariaDB 11.8.9 LTS; plan changes; checkpoint)
- Windows VM: MariaDB 11.8.9 ARM64 "sandbox" server package and mariadb-shell 26.10.1 ARM64
  (`<win-home>\Downloads\...`). The server package has no `mariadb.exe` and needs the
  ARM64 OpenSSL DLLs from the shell's `bin`. Smoke test and suite got a MariaDB package mode
  (`MARIADB_PACKAGE_DIR`, SQL through `mariadb-shell --sql`, Windows `mariadb-install-db.exe
  -d <dir> -R`). Smoke test incl. MRS scripts passes; MRS suite 97 passed, 0 failed, the
  same as macOS, after two fixes: MariaDB test servers are stopped with SQL `SHUTDOWN` (a
  killed server corrupts the Aria grant/role tables: 54 failures in a cascade), and the
  timing-dependent "Dropped users ... have active connections" note is ignored.
- MariaDB 13 accepts `->`/`->>`, 11.8 does not: the suite's arrow rewrite covers
  double-quoted paths now; the daemon's own SQL has no arrows left.
- Plan: Milestone 2 stays on schema 4.1.6 (main branches of the MariaDB shell and plugins);
  schema 5.0.0 is Milestone 3; REST async tasks are removed from the product (code removal
  in M2.4); GTID asof is an open point shared with the shell and plugins; packaging and CI
  are Milestone 4.
- `/checkpoint` and `/read-checkpoint` brought over from the shell repo;
  `.claude/PROJECT_CONTEXT.md` holds the state and next steps now.
- Ubuntu VM: MariaDB 11.8.9 and mariadb-shell 26.10.1 ARM64 packages in `<downloads>`
  (wrappers `<dev>/mrsd-smoke-mariadb.sh`, `<dev>/mrsd-pytest-mariadb.sh`). Smoke test incl.
  MRS scripts passes; MRS suite 98 passed, 0 failed, 13 skipped, 10 xfailed, 1 xpassed:
  `destination_socket` (skipped on macOS and Windows) runs with MySQL's `auth_socket`
  accounts mapped to MariaDB's built-in `unix_socket`. Phase M2.2 done.
- `json_view`, `json_view_access` pass on MariaDB: same data as MySQL in another member order;
  the normaliser now parses output with the tests' bare placeholders (`"etag":ETAG`,
  `TIMESTAMP`, `GTID` lines, eaten commas) and drops the empty `_metadata` MySQL leaves once
  its gtid is filtered. macOS: 99 passed, 0 failed, 14 skipped, 8 xfailed, 1 xpassed.
- `role_privileges` on MariaDB: a cycle in the role/user/group hierarchy is refused as on
  MySQL. MySQL aborts the recursive CTEs (cte_max_recursion_depth); MariaDB truncates them
  with warning 1931, which `QueryRaw::query()` now raises as an error (checked only when a
  query ends with warnings; `is_mariadb()` first, for the strict unit-test mocks).
- Harness: a MariaDB datadir bootstrap is retried once and reports its output (one of three
  workers' `mariadb-install-db` stopped half-way on Ubuntu once).
- Results: macOS MariaDB mode 100 passed, 0 failed, 7 xfailed; Ubuntu 101 passed, 0 failed,
  7 xfailed; MySQL mode 116/5/1; ctest 113/113 on both builds.

### 2026-10-13: session 7 (M2.3 closed, M2.4 started)
- Windows against 11.8.9 rerun at the latest commit: MRS suite 100 passed, 0 failed, 14
  skipped, 7 xfailed, 1 xpassed (same as macOS); ctest 113/113.
- Live-DB unit tests on Ubuntu and Windows: 102/104 like macOS (the 2 `special_types`
  failures are the JSON-columns open point). Windows needs the build's output dirs on PATH
  (`<win-home>\mrsd-live-mariadb.cmd`).
- Running them on Ubuntu (GCC 15) exposed an upstream bug: `ObjectRowOwnership` kept its
  row groups and user groups as references to the constructors' default temporaries;
  `build_where()` then read garbage and grew the WHERE clause until the OOM killer hit.
  Both members are values now. The `fetch_any_owner` path builds such an object in
  production too.
- M2.3 closed: every suite passes on the three platforms against MariaDB.
- M2.4: REST async tasks removed (`mysql_task_monitor`, `query_rest_task*`, the handlers'
  202/`{taskId}` paths, `mysqlTask.*` options, the async OpenAPI variant, the
  `mysqlTask.userVariables` field flag, `MySQLSession::execute_nb()` and the `*_nb`
  functions in both client variants); the smoke test no longer loads `mysql_tasks`.
- Open point recorded: JSON columns on MariaDB (metadata says `longtext`; JSON-string
  writes fail), to review after Milestone 3.
- Decision: MariaDB only. The MySQL build (libmysqlclient, `-DMYSQL_PACKAGE_DIR`) and MySQL
  server support are gone: `cmake/compat/mysql_package.cmake`, the `MRSD_CLIENT_MARIADB`
  ifdefs (TLS session cache, `SslMode`, query attributes, ...), `helper/server_flavor`
  and the MySQL branch at every `is_mariadb()` site (SQL generation, roles, read-only,
  offline mode, `--setup`), the `ER_*` maps (call sites use MariaDB's codes), the gate
  accepts MariaDB 10.11+ only (the component tests' mock greets as MariaDB), the MySQL
  modes of `tests/mrs`, `shared_server.cc` and the smoke test. `$asof` is refused at parse
  time on every path. GTID/`asof` is parked as Milestone 4 (shared with the shell and
  plugins); packaging and CI are Milestone 5. Restore point: tag `m2-pre-build-decision`
  + a bundle in `<dev>/rest-daemon-backups/`. The GitHub `origin` is still empty.
- The mock-based unit tests had only ever run the MySQL SQL text (the flavor defaulted to
  MySQL); their expectations are MariaDB's now.
- Verified after the removal on the three platforms, all unchanged from before it: ctest
  113/113, unit 389/389, live-DB 102/104; MRS suite macOS and Windows 100 passed, 0 failed,
  14 skipped, 7 xfailed, 1 xpassed, Ubuntu 101/0/13/7/1. (Windows ctest: one 30 s timeout
  in `routertest_component_http_server`, `GET__empty_static_folder_with_trailing_spaces_404`,
  passes when rerun; seen twice now under load, unrelated to MariaDB.)
- Follow-ups: the pass-through pool activates an account's single role
  (`passthrough_db_user` passes); `sqlQuery.timeout` through `SET STATEMENT
  max_statement_time` (the `MAX_EXECUTION_TIME` hint only exists from MariaDB 12.0, so the
  timeout did nothing on 11.8); a killed session reported as 2026 (TLS, 11.8) maps to 504
  (`timeout` passes); the VECTOR tests ported to fixed dimensions and re-enabled, which
  found INOUT VECTOR parameters failing (1292, now bound as BLOB), OUT ones rendered as
  base64 and malformed base64 giving 500 (now NULL, as MRS); upstream's `" INTEGER"` typo.
  Suite on Ubuntu: 110 passed, 0 failed, 6 skipped, 5 xfailed, 1 xpassed.
- `restd:` marker pass; Milestone 2 closed. The final smoke tests were skipped by decision.

### 2026-10-13: session 7, continued (Milestone 3 starts)
- Inventory for schema 5.0.0 in `docs/milestone3-inventory.md`; plan reviewed: UUID spike
  before the id work, the suite's SQL rewrites baked in before the switch, `rest_daemon_id`
  (UUID), user ids on the wire as UUID text, gate 5.0.x only; the 5.0.0 schema needs
  MariaDB 11.7 (`UUID_v7()`).
- M3.0: the v2/v3 schema support deleted (query variants, factories,
  `SupportedMrsMetadataVersion`, the `schema_version` fallback, `ApplyToV3` privileges,
  the version-specific tests and schema dumps); `WHEREa.id` fixed in the row-ownership
  SQL. Unit 389/389, ctest 113/113, live 102/104, suite 107 passed (one transient failure
  of `openapi_db_object_basic` under `-n 4`, passes alone).
- A MariaDB 11.8.9 macOS server package is available on the Mac:
  `MARIADB_PACKAGE_DIR=<downloads>/mariadb-11.8.9-macos26-arm-64bit-sandbox` (the
  5.0.0 floor; the live tests and the suite can run against it with that variable).
- M3.1: the suite's MySQL-only SQL rewritten in the files (29 statements + 18 commands in
  36 files, statement-aware), `mariadb_sql.py` and the output normaliser gone, all results
  recorded on MariaDB (36 of 118 differ from upstream's: float rendering, etags, gtid
  placeholders), the 22 `.mariadb.result` overlays gone.
- M3.2: the metadata schema name is configured (`metadata_schema` option, `--metadata-schema`
  in `--setup`; `<prefix>mysql_rest_service_metadata<postfix>`, validated) and the role
  names derive from it (`mrs/database/metadata_schema.{h,cc}`: `metadata_schema()`,
  `metadata_role()`, `metadata_sql()`/`metadata_query()`); the 54 statement literals go
  through `metadata_sql()`. Default unchanged (4.1.6). End-to-end with a prefixed name
  comes with the 5.0.0 script (M3.4), which supports it.
- M3.3: UUID spike on 11.8.9 (Ubuntu, macOS package) and 13.2 (findings in PLAN.md,
  phase M3.3; `X'…'` literals keep working against `UUID` columns, so binding is
  unchanged). Ids are now read by type: `UniversalId::from_cstr()` takes 16 raw bytes,
  dashed text or 32 hex digits, `helper::MySQLRow::convert(UniversalId*)` picks by the
  field's charset (63 = raw; no metadata = raw, which keeps the mocks), the 32 converter
  sites are plain `unserialize(&id)`; `QueryUuid`, `QueryUserGroups` and the object
  loader's `query_one` row go by the data size. 2 unit tests (`UniversalID.from_text`,
  `UniversalID.mysql_row_by_field_charset`). Still on 4.1.6, so the suite exercises the
  raw path only; the text path is covered by the unit tests until M3.4.
- Verification after M3.3: macOS (13.2) unit 395/395, ctest 113/113, live 102/104, suite
  108 passed / 0 failed / 4 skipped / 5 xfailed / 1 xpassed; Ubuntu (11.8.9) ctest
  113/113, live 102/104, suite 109 / 0 / 3 / 5 / 1. Windows not run for M3.2/M3.3.

### 2026-10-13: session 8 (M3.4: the switch to metadata 5.0.0)
- Branch `m3.4`, one commit per step:
  1. Daemon SQL on 5.0.0 (renamed tables/columns, audit dispatch, default schema and role
     base `mariadb_rest_service`); gate 5.0.x only (major and minor; one message naming the
     daemon version for the monitor, `--setup` and the metadata logger); MariaDB 11.7+.
     `--setup`'s `rest_daemon` statements now go through `metadata_sql()` (missed in M3.2).
  2. `rest_daemon_id` (UUID text, validated and normalised, `UniversalId::to_uuid_string()`):
     config, startup identity check, monitor, statistics, JWT `instance_id`; `--setup`
     reads back the generated UUID, accounts `mariadb_restd_<random>`; keyring
     `REST_DAEMON_ID`.
  3. The suite's schema asset `mariadb_rest_service-5.0.0.sql` (`make_test_schema.py`),
     `is_mrs_schema_v5.inc` (the v3_or_v4 guard would have skipped ten tests).
  4. The suite converted (`tools/analysis/convert_suite_5.py`, one-off) and re-recorded on
     13.2. Traps: the fixed daemon UUID must not start with `0` (mysqltest `if`); the host
     id's `HEX`/`UNHEX` round trip gives a 36-byte binary string a `UUID` column rejects;
     `test_table_note.inc` inserted integer ids. The passthroughDbUser message says
     "MariaDB Internal" (planned for M3.5).
  5. Unit/component/live tests: mocks and expected SQL, `test_mrs_config` with UUIDs, the
     master-key helpers with `REST_DAEMON_ID`; `prepare_user_metadata` builds `UUID`
     metadata, so `row_owner_root` checks `BINARY(16)` owners against `UUID` users.
  6. Smoke test on shell 26.10.2 (`CONFIGURE REST METADATA`, msm `deploySchema`, scripts
     via `mrs.load.content_set()`); README and mariadb-differences.md.
- macOS, 13.2: unit 395/395, ctest 113/113, live 102/104, suite 108 passed / 0 failed /
  4 skipped / 5 xfailed / 1 xpassed (as before the switch); smoke test incl. MRS script
  with the local shell build (main `b32550232`) and plugins `main` (`424a768f`).
- The shell and plugins checkouts may be used again (their 5.0.0 work is merged).
  Plugins-side leftovers found: `mrs_notes` keeps `BINARY(16)` owner columns, the
  `mrs_scripts` example grants on `mysql_rest_service_metadata` and looks users up with
  `UNHEX(?)` (open point in PLAN.md; the user will confirm on the plugins' side).
- Ubuntu (11.8.9): ctest 113/113, live 102/104, suite 109 / 0 / 3 / 5 / 1, smoke test incl.
  MRS script OK. Windows (11.8.9): ctest 113/113, live 102/104, suite 108 / 0 / 4 / 5 / 1,
  smoke test incl. MRS script OK. Both with the mariadb-shell 26.10.2 packages (their
  bundled 5.0.0 script is identical to the shell's `main`) and a 5.0 copy of `mrs_scripts`
  (`<dev>/mrs_scripts-5`, `<win-home>\mrsd-deps\mrs_scripts-5`); the smoke wrappers on
  both VMs point at them (the 26.10.1 versions kept as `*.26101`). `win_sync.sh` takes
  `BRANCH=`. `m3.4` fast-forwarded to `main`.

### 2026-10-13: session 8, continued (M3.5: wire formats, status variables, texts)
- Surveyed the shell's and plugins' `main` first (ids in JSON are UUID text there; the SDKs
  read only `status`/`user.name`/`user.email` from `/authentication/status` and compare
  `vendorId` with `0x3000…`; the schema's `rest_daemon_status_do_cleanup()` reads
  `statusVariables` `{name, column, nonResettable}` per daemon version, fallback names
  `mariadb…`). Decisions (user): UUID text for the user id, role ids and the script user
  id; `vendorId` stays `0x…`; routine ownership binds `X'…'` (tested: the 32-hex text fails
  with 1406 on `BINARY(16)` parameters, `X'…'` fills both types); product name later.
- Done on branch `m3.5`: the formats above; counters `mariadb…`; `statusVariables`
  published at start and with the self-insert (`Entity::is_resettable()`,
  `EntitiesManager::describe()`, `QueryStatistics::status_variables()`, one column table);
  texts. Tests: unit test for the list; `authentication_session` shows the status document
  (user UUID masked, Full Access role `31000000-…`), `mrs_schema_monitor` checks the
  published list and runs `rest_daemon_status_do_cleanup()`; `scripting_base_tests`'
  `helloUser` uses `WHERE id = ?` (its `UNHEX(?)` failure had been hidden by the xfail).
- Verified: Mac 13.2 unit 396/396, ctest 113/113, live 102/104, suite 108/0/4/5/1, smoke incl.
  MRS script; Ubuntu 113/113, 102/104, 109/0/3/5/1, smoke; Windows 113/113, 102/104,
  108/0/4/5/1, smoke. `m3.5` fast-forwarded to `main`.
- MRS Notes example: `mrs_notes.sql` fails on MariaDB at the view `notes_all` (MySQL's
  six-argument `REGEXP_REPLACE`, ICU's nested set); the MariaDB form deploys on 13.2 and
  was applied, uncommitted, to the user's plugins clone at their request. The example's
  4.0 REST schema dump can't be loaded in 5.0 (the shell's docs say so): its objects have
  to be created with REST SQL. Review-later list in PLAN.md.

### 2026-10-14: session 8, continued (publication, M3.6)
- History rewritten for publication and `main` pushed to GitHub: status-only commits folded
  into the change they record, chains squashed; `CLAUDE.md` and the Windows VM helpers
  removed from the history (local only), machine paths replaced by placeholders (see the
  top of this file).
- Live tests: the shared server's once-initialized data directory is removed at the end of
  a run (a global test environment calls `SharedServer::destroy_statics()`).
- M3.6: Galera-safe audit-log polling (overlap window by `changed_at`, ids already returned
  skipped, `wsrep_sync_wait` on Galera nodes); unit tests and the suite test
  `audit_log_late_commit`. Milestone 3 complete.

### 2026-10-14: session 9 (configure without options: dependencies from vcpkg)

- Configure failed on a Mac without Homebrew's `mariadb-connector-c`. Aligned with MariaDB
  Shell's `-DWITH_VCPKG_TRIPLET`: `vcpkg.json` (`libmariadb[openssl]`, `openssl` 3.6.3, the
  shell's `builtin-baseline`) and `cmake/bootstrap_vcpkg.cmake`, which takes vcpkg from
  `VCPKG_ROOT` or `../vcpkg` (cloned at the baseline if missing) and sets the toolchain.
  Without `MARIADB_CONNECTOR_DIR`, the host's dynamic triplet is chosen (restd links the
  shared `libmariadb`), so `cmake -S . -B build` needs no options; with it, nothing changes.
- The default build type is now set before `PROJECT()`: with none set there, the vcpkg
  toolchain links its `debug/lib` OpenSSL, next to the release `libmariadb`.
- Verified on macOS: configure without options, build, `mariadb-restd --version`; explicit
  `MARIADB_CONNECTOR_DIR` configures without vcpkg; `WITH_VCPKG_TRIPLET=OFF` without a
  connector stops with a message. Linux and Windows not yet run.

### 2026-10-14: session 9, continued (the JIT executor library, opt-in at configure time)

- Built `ext/polyglot` by hand on the Mac (GraalVM CE 23.0.1 macos-aarch64, Maven 3.9.9,
  a sparse clone of `oracle/graal` at `jdk-23.0.1` with only
  `substratevm/src/org.graalvm.polyglot.nativeapi`): `mvn package` 1:15 min, patch applied.
  Maven tried the poms' Oracle-internal repository (`artifactory.oci.oraclecorp.com`) first
  and fell back to Maven Central; the `<repositories>`/`<pluginRepositories>` entries are
  removed from the three poms, and a build with an empty local Maven repository resolves
  everything (450 artifacts) from Maven Central.
- `cmake/bootstrap_jit_executor.cmake`, `-DWITH_JIT_EXECUTOR=ON` (off by default): downloads
  GraalVM (SHA-256 per platform pinned) and Maven (SHA-512) and clones the Graal sources into
  `RESTD_DEPS_DIR` (`../restd-deps`), checks the clone's commit, builds from scratch (removing
  the copied sources, so the patch can't be skipped), checks `patches-applied.txt` and writes
  a stamp of the inputs; sets `MRS_JIT_EXECUTOR_LIB` as a normal variable.
- Verified on macOS: from an empty deps dir, configure 3:07 min; reconfigure 1.3 s (stamp);
  build; smoke test with MRS script against Homebrew MariaDB 12.3.2. With the hand-built
  library also ctest 96/96 (unit tests) and the same smoke test. Linux and Windows not yet
  run.

### 2026-10-14: session 9, continued (the macOS package with vcpkg's Connector/C)

- The tarball of a vcpkg build failed to start: `libmariadb.3.dylib` needs
  `@rpath/libz.1.3.2.dylib` (vcpkg's zlib), which wasn't bundled. Fixed in three places:
  - `CMakeLists.txt`: with Connector/C from vcpkg (`MARIADB_CONNECTOR_FROM_VCPKG`), zlib and
    OpenSSL are bundled in every layout.
  - `cmake/bundle_runtime_libraries.cmake`: the dependency scan is repeated over the libraries
    found in the previous pass; a library looked up by name (macOS `@rpath`) wasn't scanned
    for its own dependencies. Executables are recognised by the file name, not the path: the
    CPack staging prefix (`…/mariadb-restd-26.10.0-macos-arm64`) has dots, so no executable
    had been rewritten, and their ICU references still pointed at `/opt/homebrew` (the
    earlier macOS tarballs only worked on machines with Homebrew's ICU).
  - `cmake/compat/mariadb_connector.cmake`: vcpkg's release OpenSSL (`lib/`) also in a Debug
    build, where the toolchain picked `debug/lib` next to the release `libmariadb`.
- Verified: Debug build with `WITH_JIT_EXECUTOR`, `--target package`; no absolute references
  in the unpacked tarball; smoke test with `MRSD_INSTALL` incl. MRS script.
- Connector/C's client auth plugins are now in the packages: installed into
  `mariadb-client-plugins/` next to the bundled `libmariadb` (every layout), with the
  bundled OpenSSL (`@loader_path/..`, `$ORIGIN/..`). restd looks there first (the directory
  of the loaded `libmariadb`, `dladdr`/`GetModuleHandleEx`) and falls back to the build's
  `MRSD_CLIENT_PLUGIN_DIR` (the build tree). Before, the packages used the build machine's
  plugin directory, so an account with `ed25519`/`caching_sha2_password` couldn't log in
  from a package elsewhere. Verified: `--setup` as an `ed25519` account from the unpacked
  Release tarball, with the build's plugin directory hidden, loads the package's
  `client_ed25519.so`; from the build tree, the vcpkg one; ctest 96/96; smoke test with
  `MRSD_INSTALL`.

### 2026-10-15: session 10 (release packages on GitHub-hosted runners, verification, publishing)

- Build fixes for the hosted runners (`27aebcc`): ICU from vcpkg (`vcpkg.json` feature
  `icu`; Rocky 9 has ICU 67, restd needs 69); `cmake/bootstrap_vcpkg.cmake` takes
  `VCPKG_ROOT` only when it is a vcpkg git checkout and never replaces a directory that
  isn't one (a Visual Studio developer environment points it at VS's bundled vcpkg under
  "Program Files"); plugin PDBs installed `OPTIONAL`; the bundler sets
  `CMAKE_POLICY(VERSION 3.24)` (CMake 3.x on `windows-2022`); the `-W` prefix regex; vcpkg's
  `z.dll` bundled; RUNPATH `$ORIGIN` for `libjitexecutor.so`.
- `rest-daemon-release.yml` (`866ae32`): STANDALONE packages for macOS, Windows and Linux
  (Rocky 9 container), x64 and arm64, on a push to `release/candidate`; the JIT executor
  library is cached per platform. GraalVM CE has no Windows ARM64 build (checked up to
  `graal-25.4.4.1.1` and the 25.5 dev builds), so the `windows-arm64` leg builds the x64
  package on an ARM64 runner and only the x64 leg's copy is published.
  `verify-packages.yml` checks each package on a pristine runner
  (`tools/release/verify_package.sh`) and leaves `verified-build-<run id>`.
- `publish-release.yml` (`fbb5913`): creates the GitHub release from a verified run.
  Release run `38669748749` and its verification `38671210624` passed on all six legs;
  published `v26.10.0` as a pre-release (5 packages + `SHA256SUMS`). Its notes said MariaDB
  Server 10.11 or later; corrected to 11.7 in the workflow (`2b4c73c`), the release itself
  is fixed by running Publish Release for the same run again.
- The self-hosted CI workflow (all suites) is drafted but parked until IT-23080 (GCP
  workload-identity access, the GCP secrets, the org runner group).
- `/checkpoint` and `/read-checkpoint` follow MariaDB Shell's: the context keeps only what
  stays true (no git state, session history or machine details); `/read-checkpoint` reads
  open PRs and dangling branches live.

### 2026-10-15: session 10, continued (rebranding round, PLAN.md "Rebranding round")

- Decisions (user): product name **MariaDB REST Daemon** (as the shell, the schema
  comments and the landing page); help banner as the shell's welcome banner; the
  configuration section and its `mysql_*` keys renamed; package vendor/contact as the
  shell's; no "Router" term in anything user-visible, internals (namespaces, directories,
  include paths, CMake target names) untouched; changes touching the shell or the plugins
  made in sync with those repositories.
- R1 (`43e89ce`): product name, banner (`compat/include/mrsd/copyright_notice.h`),
  `--help` wording, the client session's and other messages, certificate CNs, the HTTP
  client's User-Agent, `LICENSE` (was `LICENSE.router`), upstream READMEs dropped.
- R2 (`8d9a490`): `[mariadb_rest_service]` with `metadata_user`, `data_user`,
  `read_write_destinations`, `read_only_destinations`, `ssl_*`, `tls_version`;
  `MARIADB_RESTD_PID`; `restd-key.pem`/`restd-cert.pem`; `[rest_daemon]` /
  `/daemon/status`. The old section, keys and variable are read with deprecation
  warnings (`MySQLRouter::rename_deprecated_sections`, `PluginConfig`); `--setup --force`
  reads an old deployment. Plugins (`restd.py`, its unit test, `rest.md`) read both
  names and set both variables (uncommitted in that clone).
- R3: shared libraries `librestd_*` (`librestd`, `_harness`, `_harness_stdx`,
  `_harness_tls`, `_http*`, `_io_component`, `_client`, `_utils`), plugin `restd_openssl`,
  the suite's client `mariadb-restd-mrs-client` (no longer installed: it was in the
  package's component). Verified with ctest, the suite, an old-style configuration
  (four deprecation warnings), the package and the smoke test on the unpacked package.
- Kept on purpose: "MRS scripts", the `mrs_*` log domains, the OpenAPI scheme
  `mrs_login`, the `rest_daemon.attributes` keys (the shell's own terms).

### 2026-10-15: session 10, continued (verification fix, LICENSE)

- The first verification of the rebranded packages failed on every platform on one check:
  `tools/release/verify_package.sh` still required a plugin `mysql_rest_service`
  (`29f96a9`); the other 29 checks passed. The verification job checks out the release
  run's commit, so a fix needs a new push to `release/candidate`.
- `LICENSE` reviewed against what the product contains and ships, and rewritten in
  MariaDB Shell's form (`c58e3a9`): MySQL Router's manual listed Duktape, Google Test
  (test-only here), Protocol Buffers (gone with the X protocol), Kerberos5, libevent and
  LZ4 (not linked), and nothing of what the packages bundle. Sections now: MariaDB
  Connector/C (LGPL 2.1), GraalVM Community Edition for the JIT executor library (GPLv2
  with the Classpath Exception; SDK, Polyglot API and GraalJS under the UPL 1.0), ICU,
  libcno and picohttpparser (MIT), OpenSSL 3.6, RapidJSON, zlib; the standard licenses
  they reference; MariaDB's "Availability of Source Code". Judgment calls to confirm
  with licensing: the GraalVM section's wording, "MariaDB plc gratefully acknowledges"
  in the zlib section, no section for the MSVC runtime (as the shell's manual).
- The plugins' matching change (`restd.py` reads both name sets, sets both pid-file
  variables) is mariadb-shell-plugins commit `c74cbdfc`.

### 2026-10-16: session 11 (a REST role of a service applies to that service only)

- Decision (user, from the review of the shell's PR #85, `CLONE REST SERVICE` copying the
  roles): a clone must have no relation with its source, so the root cause is fixed here
  rather than worked around in the shell. `do_privilege_check()` matched every privilege
  of every role of the user by path alone, so a service role with a privilege on `*` or on
  another service's path reached that service, and a cloned role widened access outside
  the clone.
- `AuthPrivilege::service_id` (the role's `specific_to_service_id`, read by
  `QueryEntriesAuthPrivilegesImpl` with a join on `mrs_role`, part of the `GROUP BY`);
  `do_privilege_check()` skips a privilege whose role belongs to another service than the
  request's. No schema change. Suite test `role_service_scope` (service role on `*`, on
  another service's path, a derived role, a global role); `docs/mariadb-differences.md`
  "REST service behaviour"; the shell's `rest-daemon-5.0.md` §2a records the dependency.

### 2026-10-27: session 12 (restd runs from the build tree)

- A build-tree `mariadb-restd` exited for lack of plugins: the default plugin folder is
  the package's `{origin}/../lib/mariadb-restd` (Windows `{origin}/../lib`). Switching the
  build tree to the package layout was considered and declined: about 15 files hard-code
  upstream's `*_output_directory` names (CMake, the C++ test helpers, the MRS suite and
  its recorded results, the smoke test), the test executables would land next to the
  daemon, and multi-config generators would still miss `../lib`. The release workflows
  would not have been affected (they only run `cmake --build` and `cpack`).
- `get_default_paths()` (`default_paths.cc`) falls back to the build's
  `plugin_output_directory` when the package's plugin folder does not exist and the
  binary sits in `runtime_output_directory` (or a configuration folder below it); the
  lookup is the harness's `get_plugin_dir()`. `--setup` writes no `plugin_folder`, so its
  configurations work from the build tree too. Verified on macOS: `--help` shows the build
  tree's folder, a daemon without `plugin_folder` serves `rest_api`, ctest passes.
