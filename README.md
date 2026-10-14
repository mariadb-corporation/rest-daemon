# mariadb-restd: MariaDB REST Service Daemon

mariadb-restd ("restd" for short) is the **MariaDB REST Service** daemon: it
serves REST endpoints for MariaDB tables, views, stored procedures, functions
and JavaScript/TypeScript scripts, as defined in the REST service metadata
schema (`mariadb_rest_service`, version 5.0, deployed by MariaDB Shell's
`CONFIGURE REST METADATA`) of a MariaDB server.

It is a fork of the MySQL REST Service (MRS) plugin of MySQL Router (`router/`
in mysql-server), without the router's connection routing, InnoDB
Cluster/ClusterSet support, bootstrap and X protocol, ported to MariaDB: it is
built against MariaDB Connector/C and runs against a MariaDB server, 11.7 or
later (the metadata schema's ids are `UUID`s with `UUID_v7()` defaults). It
serves metadata schema 5.0.x only and refuses to start on another version.
What it does differently from the MySQL REST Service is listed in
[docs/mariadb-differences.md](docs/mariadb-differences.md).

> **Status:** work in progress. restd builds and passes its tests on Linux,
> macOS and Windows against MariaDB 11.8 and 13.2; see [docs/PLAN.md](docs/PLAN.md)
> and [docs/PROGRESS.md](docs/PROGRESS.md). There are no packages yet.

## Building

### Requirements

- CMake 3.24 or later and a C++23 compiler (tested: GCC 15, AppleClang 21,
  MSVC 2022 17.14)
- **MariaDB Connector/C** 3.4 or later, built with OpenSSL, and OpenSSL 3:
  by default, configure gets both from [vcpkg](https://vcpkg.io), as MariaDB
  Shell does (below). Alternatively, pass a Connector/C installation with
  `MARIADB_CONNECTOR_DIR` (a release package, Homebrew's
  `mariadb-connector-c`, Debian's `libmariadb-dev`, ...); OpenSSL is then
  taken from the system or `OPENSSL_ROOT_DIR`
- ICU (system packages on Linux/macOS; on Windows, e.g. the official ICU zip)
- optional: the **JIT executor library** (`libjitexecutor` and its headers),
  needed for MRS scripts; built from `ext/polyglot` (below)

### CMake options

| Option | |
|---|---|
| `MARIADB_CONNECTOR_DIR` | prefix of a MariaDB Connector/C installation; without it, Connector/C and OpenSSL come from vcpkg |
| `WITH_VCPKG_TRIPLET` | vcpkg triplet to get the dependencies with (default: the dynamic triplet of the host, if `MARIADB_CONNECTOR_DIR` is not set; `OFF`: no vcpkg) |
| `VCPKG_ROOT` | the vcpkg checkout (default: `$VCPKG_ROOT`, else `../vcpkg`, cloned if missing) |
| `MRS_JIT_EXECUTOR_LIB` | directory with `libjitexecutor` and its headers; without it (and without `WITH_JIT_EXECUTOR`), restd is built without MRS script support |
| `WITH_JIT_EXECUTOR` | build `libjitexecutor` from `ext/polyglot` at configure time, downloading GraalVM and Maven (`OFF`) |
| `RESTD_DEPS_DIR` | where `WITH_JIT_EXECUTOR` puts GraalVM, Maven and the Graal sources (`../restd-deps`) |
| `WITH_UNIT_TESTS` | build the unit tests and the test tools (`OFF`) |
| `WITH_COMPONENT_TESTS` | build the component tests, needs `WITH_UNIT_TESTS` (`OFF`) |
| `OPENSSL_ROOT_DIR`, `ICU_ROOT` | where to find OpenSSL / ICU, if not in a default location |
| `INSTALL_GIT_HOOKS` | link the hooks in `.githooks/` into the clone at configure time (`ON`) |

### Dependencies from vcpkg

Without `MARIADB_CONNECTOR_DIR`, configure installs the dependencies listed in
`vcpkg.json` (Connector/C and OpenSSL) into `<build>/vcpkg_installed/<triplet>`
and builds against them, the way MariaDB Shell's `-DWITH_VCPKG_TRIPLET` works
(`cmake/bootstrap_vcpkg.cmake`):

- vcpkg is taken from `-DVCPKG_ROOT`, the `VCPKG_ROOT` environment variable
  or `../vcpkg` (next to the source tree, where MariaDB Shell's build puts it
  too), in that order. If there is no checkout there, configure clones vcpkg
  at the `builtin-baseline` commit of `vcpkg.json` and bootstraps it.
- The triplet is the host's dynamic one (`arm64-osx-dynamic`,
  `x64-linux-dynamic`, `x64-windows`, ...), as restd links the shared
  `libmariadb`; choose another with `-DWITH_VCPKG_TRIPLET=<triplet>`.
- A vcpkg toolchain file passed with `-DCMAKE_TOOLCHAIN_FILE` is used as is.

### JIT executor library

`ext/polyglot` builds `libjitexecutor` (the GraalVM Polyglot Native API with
the patch in `polyglot-nativeapi/patches`) into
`ext/polyglot/polyglot-nativeapi-native-library/target`, the directory to pass
as `MRS_JIT_EXECUTOR_LIB`. It needs GraalVM 23.0.1, its source code and Maven.

`-DWITH_JIT_EXECUTOR=ON` does all of it at configure time
(`cmake/bootstrap_jit_executor.cmake`): it downloads GraalVM CE for JDK
23.0.1 and Maven (checksums pinned), sparse-clones the Graal sources at
`jdk-23.0.1`, all into `RESTD_DEPS_DIR` (`../restd-deps`), runs `mvn package`
and uses its output. The first configure takes a few minutes (about 3 on an
M-series Mac); later ones reuse the library until the versions, the poms or
the patch change. `native-image` asks for a 20 GB heap.

By hand:

```sh
cd ext/polyglot
JAVA_HOME=/path/to/graalvm-community-openjdk-23.0.1/Home \
GRAALJDK_ROOT=/path/to/graal-jdk-23.0.1 \
PATH=$JAVA_HOME/bin:$PATH mvn package
```

On Windows, run it from a `vcvars64.bat` environment; see `ext/polyglot/README.txt`.

### Linux / macOS

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DMRS_JIT_EXECUTOR_LIB=$PWD/ext/polyglot/polyglot-nativeapi-native-library/target
cmake --build build
```

With an installed Connector/C instead of vcpkg's, add e.g.
`-DMARIADB_CONNECTOR_DIR=/opt/homebrew/opt/mariadb-connector-c`.

On macOS, OpenSSL and ICU are found in Homebrew's default locations.

### Windows

restd is built for x64 (the JIT executor library is x64 only on Windows). From
a Visual Studio 2022 developer environment (`vcvarsall.bat amd64`, or
`arm64_amd64` on Windows on ARM), with Connector/C and OpenSSL from vcpkg
(triplet `x64-windows`):

```bat
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DICU_ROOT=C:\path\to\icu ^
  -DMRS_JIT_EXECUTOR_LIB=%CD%\ext\polyglot\polyglot-nativeapi-native-library\target
cmake --build build
```

At run time, the DLLs of Connector/C (`libmariadb.dll`), OpenSSL (in
`build\vcpkg_installed\x64-windows\bin`) and ICU must be on `PATH`.

### Build output

In the build directory:

- `runtime_output_directory/`: `mariadb-restd` (the daemon), `mariadb-restd-keyring`
  (keyring tool), `mariadb-restd-passwd` (password file tool for HTTP basic
  auth), `mariadb-restd-plugin-info` and, with the tests, `mysql_server_mock` and
  `mysqlrouter_mrs_client`
- `plugin_output_directory/`: the plugins (`mysql_rest_service`,
  `http_server`, `jit_executor`, ...)

The program name (`mariadb-restd`), the product name and the package metadata
are set in `cmake/settings.cmake`, the version in `VERSION`.

### Packages

`cmake --build build --target package` (CPack) builds the packages of the
configured layout. Build them without `WITH_UNIT_TESTS`.

| `INSTALL_LAYOUT` | Packages | Layout |
|---|---|---|
| `STANDALONE` (default) | `.tar.gz` (Linux, macOS), `.zip` (Windows) | relocatable: `bin/`, `lib/` (plugins in `lib/mariadb-restd/`), `docs/`; the defaults are relative to the executable |
| `SYSTEM` (with `-DCMAKE_INSTALL_PREFIX=/usr`) | `.deb`, `.rpm` | `/usr/bin`, `/usr/lib/mariadb-restd/` (plugins), `/usr/lib/mariadb-restd/private/` (libraries), `/etc/mariadb-restd`, `/var/lib/mariadb-restd`, `/var/log/mariadb-restd` |

The packages bundle Connector/C (`libmariadb`) and the JIT executor library; the `STANDALONE` packages also bundle OpenSSL and ICU, which
deb/rpm take from the system. The deb/rpm packages add a systemd unit, a
`mariadb-restd` service account (sysusers.d) and its folders (tmpfiles.d); the
service is enabled after `--setup`. Building packages needs `patchelf` on
Linux, `dpkg-shlibdeps` for deb and `rpmbuild` for rpm. The Windows packages
include the MSVC runtime.

## Setting up a deployment

`mariadb-restd --setup` prepares a self-contained deployment directory for a
MariaDB server that has the REST service metadata schema (created with the
MariaDB shell's `CONFIGURE REST METADATA`):

```sh
mariadb-restd --setup admin@db1.example.com:3306 -d /srv/restd
/srv/restd/start.sh          # start.ps1 on Windows; stop.sh / stop.ps1 to stop
```

It registers the instance in the REST metadata (table `rest_daemon`; the
server generates the instance's UUID, written to the configuration as
`rest_daemon_id`), creates a server account `mariadb_restd_<random>` with the
`mariadb_rest_service_meta_provider` and `mariadb_rest_service_data_provider`
roles (the first is its default role; MariaDB activates one role at a time), stores its password and the JWT secret in a keyring, creates a
self-signed TLS certificate and writes `mariadb-restd.conf` (HTTPS on port
8443). The account in the URI needs to create accounts, grant those roles and
write the MRS metadata; passwords that aren't given are prompted for. If
anything fails, what was created is removed again.

| Option | |
|---|---|
| `-d`, `--directory` | the deployment directory (created if needed); without it, the default folders (`mariadb-restd --help` lists them; `/etc/mariadb-restd`, `/var/lib/mariadb-restd`, ... for deb/rpm) |
| `-u`, `--user` | the system account that runs restd, owner of the created files (needed when running as root without `-d`) |
| `--name` | name of the instance in the REST metadata (default: `<hostname>:<HTTP port>`) |
| `--report-host` | host name stored in the REST metadata (default: the local host name) |
| `--metadata-schema` | the REST metadata schema to serve, `<prefix>mariadb_rest_service<postfix>` (default: `mariadb_rest_service`); the roles follow it |
| `--metadata-account`, `--data-account` | use these server accounts (passwords prompted for) instead of a generated one |
| `--jwt-secret` | secret for signing JSON Web Tokens; the same for all instances of the same MRS metadata |
| `--developer`, `--developer-debug-port` | also serve the services in development by this developer |
| `--socket` | connect through a Unix socket (URI host `localhost`); the deployment uses it too |
| `--ssl-mode`, `--ssl-ca`, `--ssl-capath`, `--ssl-crl`, `--ssl-crlpath`, `--ssl-cipher`, `--tls-version` | TLS to the MariaDB server, for the setup and the deployment |
| `--conf-set-option=<section>.<option>=<value>` | set or add an option of the generated configuration, e.g. `http_server.port=8080` |
| `--master-key-reader`, `--master-key-writer` | commands that read/store the keyring's master key, instead of a key file |
| `--force` | overwrite an existing deployment, keeping its accounts and JWT secret |

`mariadb-restd --setup --help` describes all options.

With the deb/rpm packages, which create the `mariadb-restd` service account and
a systemd unit:

```sh
sudo mariadb-restd --setup admin@db1.example.com:3306 --user mariadb-restd
sudo systemctl enable --now mariadb-restd
```

## Configuration

`--setup` writes the configuration; it can also be written by hand. restd reads
a router-style configuration file. A minimal one:

```ini
[DEFAULT]
plugin_folder=/path/to/build/plugin_output_directory
logging_folder=/var/log/mariadb-restd
runtime_folder=/var/run/mariadb-restd
data_folder=/var/lib/mariadb-restd
keyring_path=/var/lib/mariadb-restd/keyring
master_key_path=/etc/mariadb-restd/mariadb-restd.key

[http_server]
port=8443
ssl=1
ssl_cert=/etc/mariadb-restd/server-cert.pem
ssl_key=/etc/mariadb-restd/server-key.pem

[mysql_rest_service]
mysql_user=mrs_user
mysql_read_write_destinations=db1.example.com:3306
rest_daemon_id=0199a1b2-6c3e-7d41-9a0f-2b8c4d5e6f70
```

`rest_daemon_id` is the UUID of the instance's row in the metadata table
`rest_daemon` (`--setup` registers it); at start-up restd refuses to run when
the metadata holds the same name and address under another id.

The account in `mysql_user` needs the `mariadb_rest_service_meta_provider` and
`mariadb_rest_service_data_provider` roles; its password, and the secret used
to sign JWTs, are read from the keyring:

```sh
mariadb-restd-keyring init /var/lib/mariadb-restd/keyring --master-key-file=/etc/mariadb-restd/mariadb-restd.key
mariadb-restd-keyring set  /var/lib/mariadb-restd/keyring mrs_user password '<password>' \
  --master-key-file=/etc/mariadb-restd/mariadb-restd.key
mariadb-restd-keyring set  /var/lib/mariadb-restd/keyring rest-user jwt_secret '<secret>' \
  --master-key-file=/etc/mariadb-restd/mariadb-restd.key
```

Start it with `mariadb-restd -c <config file>`. Without `-c`, it reads
`mariadb-restd.conf` from its configuration folder (`mariadb-restd --help` lists
the locations). It logs to `mariadb-restd.log` in `logging_folder`.

### Differences from MySQL Router's MRS configuration

MySQL Router points MRS at routing plugins (`mysql_read_write_route`,
`mysql_read_only_route`). restd has no routing plugin; the MariaDB servers are
configured in `[mysql_rest_service]` directly:

| Option | |
|---|---|
| `mysql_read_write_destinations` | **required**, comma-separated `host[:port]`, `[ipv6]:port` or `local:/path/to/mysql.sock`; port 3306 if omitted |
| `mysql_read_only_destinations` | same format; defaults to the read-write destinations |
| `metadata_schema` | the REST metadata schema this instance serves, `<prefix>mariadb_rest_service<postfix>` (default: `mariadb_rest_service`); the role names (`<prefix>mariadb_rest_service_meta_provider<postfix>`, ...) follow it |
| `rest_daemon_id` | **required**, the instance's UUID in the metadata (MySQL Router: `router_id`, an integer); a master key reader gets it as `REST_DAEMON_ID` (MySQL Router: `ROUTER_ID`) |
| `mysql_ssl_mode` | TLS to the servers: `DISABLED`, `PREFERRED` (default), `REQUIRED`, `VERIFY_CA`, `VERIFY_IDENTITY` |
| `mysql_ssl_ca`, `mysql_ssl_capath`, `mysql_ssl_crl`, `mysql_ssl_crlpath` | CA and CRL files/directories for verifying the servers |
| `mysql_ssl_cipher`, `mysql_ssl_curves`, `mysql_tls_version` | TLS ciphers, curves and versions |

The other `[mysql_rest_service]` options (`mysql_user`,
`mysql_user_data_access`, `metadata_refresh_interval`,
`wait_for_metadata_schema_access`, `developer`, ...) are the same as in MySQL
Router.

REST services, schemas and objects are defined in the REST metadata schema with
the MariaDB shell's REST SQL (`CREATE REST SERVICE ...`) or its VS Code
extension. REST scripts: see [MRS_README.router](MRS_README.router) (upstream's
description, which still applies).

## Testing

Configure with `-DWITH_UNIT_TESTS=ON -DWITH_COMPONENT_TESTS=ON`.

**Unit and component tests** (GoogleTest, run with CTest):

```sh
ctest --test-dir build -j8
```

The component tests start `mariadb-restd` and `mysql_server_mock` processes;
cases that exercise features restd doesn't have are excluded in
[tests/component/excluded_cases.cmake](tests/component/excluded_cases.cmake).

**REST functional tests** (`tests/mrs`): the MRS tests of mysql-server's
`mysql-test/suite/router`, kept as `.test` scripts with golden `.result`
files and run by pytest against a real `mariadbd`, from a server package
(`MARIADB_PACKAGE_DIR`) or a server build tree (`MARIADB_BUILD_DIR` and
`MARIADB_SOURCE_DIR`):

```sh
python3 -m venv venv && venv/bin/pip install -r tests/mrs/requirements.txt
MRSD_BUILD=$PWD/build MARIADB_PACKAGE_DIR=/path/to/mariadb-<version>-<platform> \
  venv/bin/python -m pytest tests/mrs -q
```

The scripts carry MariaDB's SQL (upstream's MySQL-only constructs were rewritten
in the files) and the results are recorded on MariaDB. `-k <test>` runs single
tests and `--record` rewrites the `.result` files. Disabled tests are listed in
`tests/mrs/disabled.def`, expected failures in `tests/mrs/known_failures.def`.
On Windows, use `venv\Scripts\python`, put the DLL directories and a `perl` on
`PATH` (Git for Windows' `usr\bin` has one), and expect the tests' `exec`
commands to run through `cmd.exe`, as they do under mtr.

**Smoke test** (`tools/smoke/run_smoke.sh`): starts `mariadbd`, deploys the
metadata schema with MariaDB Shell's `CONFIGURE REST METADATA` (shell 26.10.2
or later; through the mariadb-shell-plugins' msm plugin when `SHELL_PLUGINS`
is given), configures restd with `--setup`, starts it, creates a REST view
with REST SQL and checks that it is served; optionally uploads and calls an
MRS script (`MRS_SCRIPTS_DIR`, needs `SHELL_PLUGINS`). See the script for its
parameters.

## Repository layout

| | |
|---|---|
| `src/` | the router modules restd uses (harness, http, mysql_rest_service, jit_executor, ...) |
| `compat/` | replacements for the client-library internals the router code used, and what Connector/C lacks |
| `cmake/compat/` | the parts of the MySQL server's build system the router CMake files expect, the Connector/C finder |
| `extra/` | vendored code: rapidjson, libcno, googletest, duktape, MySQL server headers |
| `ext/polyglot/` | Maven build of the JIT executor library (from the MySQL Shell sources) |
| `tests/` | component tests, test helpers, REST functional tests (`tests/mrs`), test data |
| `tools/` | smoke test, analysis scripts (dependency closure, the suite's schema generator and converter) |
| `docs/` | plan, progress log, inventories, differences from the MySQL REST Service |

[README.router](README.router) and [MRS_README.router](MRS_README.router) are
MySQL Router's documentation, kept from upstream.

## License

GPLv2, see [LICENSE.router](LICENSE.router).
