# mrsd: MySQL REST Service daemon

mrsd is a standalone daemon for the **MySQL REST Service (MRS)**: it serves
REST endpoints for MySQL tables, views, stored procedures, functions and
JavaScript/TypeScript scripts, as defined in the MRS metadata schema
(`mysql_rest_service_metadata`) of a MySQL server.

It is a fork of the MRS plugin of MySQL Router (`router/` in mysql-server),
without the router's connection routing, InnoDB Cluster/ClusterSet support,
bootstrap and X protocol. It is built against a stock MySQL client library.

> **Status:** work in progress. mrsd builds and passes its tests on Linux,
> macOS and Windows against MySQL 26.7, but the executable is still called
> `mysqlrouter`, and `mrsd --setup` (replacing the router's `--bootstrap`) and
> packaging don't exist yet. See [docs/PLAN.md](docs/PLAN.md) and
> [docs/PROGRESS.md](docs/PROGRESS.md).

## Building

### Requirements

- CMake 3.24 or later and a C++23 compiler (tested: GCC 15, AppleClang 21,
  MSVC 2022 17.14)
- an extracted **MySQL server binary package**, 9.0 or later: mrsd uses its
  client library (`lib/`) and headers (`include/`), and the tests use its
  `mysqld`
- OpenSSL 3 and ICU (system packages on Linux/macOS; on Windows, e.g. OpenSSL
  from vcpkg and the official ICU zip)
- optional: a **JIT executor library** (`libjitexecutor` built from the
  GraalVM polyglot sources, plus its headers), needed for MRS scripts

### CMake options

| Option | |
|---|---|
| `MYSQL_PACKAGE_DIR` | **required**, path of the MySQL server package |
| `MRS_JIT_EXECUTOR_LIB` | directory with `libjitexecutor` and its headers; without it, mrsd is built without MRS script support |
| `WITH_UNIT_TESTS` | build the unit tests and the test tools (`OFF`) |
| `WITH_COMPONENT_TESTS` | build the component tests, needs `WITH_UNIT_TESTS` (`OFF`) |
| `OPENSSL_ROOT_DIR`, `ICU_ROOT` | where to find OpenSSL / ICU, if not in a default location |
| `INSTALL_GIT_HOOKS` | link the hooks in `.githooks/` into the clone at configure time (`ON`) |

### Linux / macOS

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DMYSQL_PACKAGE_DIR=/path/to/mysql-<version>-<platform> \
  -DMRS_JIT_EXECUTOR_LIB=/path/to/polyglot-nativeapi-native-library/target
cmake --build build
```

On macOS, OpenSSL and ICU are found in Homebrew's default locations.

### Windows

mrsd is built for x64 (MySQL publishes Windows packages for x64 only). From a
Visual Studio 2022 developer environment (`vcvarsall.bat amd64`, or
`arm64_amd64` on Windows on ARM):

```bat
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DMYSQL_PACKAGE_DIR=C:\path\to\mysql-<version>-winx64 ^
  -DOPENSSL_ROOT_DIR=C:\path\to\vcpkg\installed\x64-windows ^
  -DICU_ROOT=C:\path\to\icu ^
  -DMRS_JIT_EXECUTOR_LIB=C:\path\to\polyglot-nativeapi-native-library\target
cmake --build build
```

At run time, the DLLs of the MySQL client library, OpenSSL and ICU must be on
`PATH`.

### Build output

In the build directory:

- `runtime_output_directory/`: `mysqlrouter` (the daemon), `mysqlrouter_keyring`,
  `mysqlrouter_passwd` and, with the tests, `mysql_server_mock` and
  `mysqlrouter_mrs_client`
- `plugin_output_directory/`: the plugins (`mysql_rest_service`,
  `http_server`, `jit_executor`, ...)

## Configuration

mrsd reads a router-style configuration file. A minimal one:

```ini
[DEFAULT]
plugin_folder=/path/to/build/plugin_output_directory
logging_folder=/var/log/mrsd
runtime_folder=/var/run/mrsd
data_folder=/var/lib/mrsd
keyring_path=/var/lib/mrsd/keyring
master_key_path=/etc/mrsd/mrsd.key

[http_server]
port=8443
ssl=1
ssl_cert=/etc/mrsd/server-cert.pem
ssl_key=/etc/mrsd/server-key.pem

[mysql_rest_service]
mysql_user=mrs_user
mysql_read_write_destinations=db1.example.com:3306
router_id=1
```

The account in `mysql_user` needs the `mysql_rest_service_meta_provider` and
`mysql_rest_service_data_provider` roles; its password, and the secret used
to sign JWTs, are read from the keyring:

```sh
mysqlrouter_keyring init /var/lib/mrsd/keyring --master-key-file=/etc/mrsd/mrsd.key
mysqlrouter_keyring set  /var/lib/mrsd/keyring mrs_user password '<password>' \
  --master-key-file=/etc/mrsd/mrsd.key
mysqlrouter_keyring set  /var/lib/mrsd/keyring rest-user jwt_secret '<secret>' \
  --master-key-file=/etc/mrsd/mrsd.key
```

Start it with `mysqlrouter -c <config file>`.

### Differences from MySQL Router's MRS configuration

MySQL Router points MRS at routing plugins (`mysql_read_write_route`,
`mysql_read_only_route`). mrsd has no routing plugin; the MySQL servers are
configured in `[mysql_rest_service]` directly:

| Option | |
|---|---|
| `mysql_read_write_destinations` | **required**, comma-separated `host[:port]`, `[ipv6]:port` or `local:/path/to/mysql.sock`; port 3306 if omitted |
| `mysql_read_only_destinations` | same format; defaults to the read-write destinations |
| `mysql_ssl_mode` | TLS to the servers: `DISABLED`, `PREFERRED` (default), `REQUIRED`, `VERIFY_CA`, `VERIFY_IDENTITY` |
| `mysql_ssl_ca`, `mysql_ssl_capath`, `mysql_ssl_crl`, `mysql_ssl_crlpath` | CA and CRL files/directories for verifying the servers |
| `mysql_ssl_cipher`, `mysql_ssl_curves`, `mysql_tls_version` | TLS ciphers, curves and versions |

The other `[mysql_rest_service]` options (`mysql_user`,
`mysql_user_data_access`, `router_id`, `metadata_refresh_interval`,
`wait_for_metadata_schema_access`, `developer`, ...) are the same as in MySQL
Router.

REST services, schemas and objects are defined in the MRS metadata schema, for
example with MySQL Shell's MRS SQL (`CREATE REST SERVICE ...`) or the MySQL
Shell for VS Code extension. MRS scripts: see
[MRS_README.router](MRS_README.router).

## Testing

Configure with `-DWITH_UNIT_TESTS=ON -DWITH_COMPONENT_TESTS=ON`.

**Unit and component tests** (GoogleTest, run with CTest):

```sh
ctest --test-dir build -j8
```

The component tests start `mysqlrouter` and `mysql_server_mock` processes;
cases that exercise features mrsd doesn't have are excluded in
[tests/component/excluded_cases.cmake](tests/component/excluded_cases.cmake).

**MRS functional tests** (`tests/mrs`): the MRS tests of mysql-server's
`mysql-test/suite/router`, kept as `.test` scripts with golden `.result`
files and run by pytest against a real `mysqld` from the MySQL package:

```sh
python3 -m venv venv && venv/bin/pip install -r tests/mrs/requirements.txt
MRSD_BUILD=$PWD/build MYSQL_PACKAGE_DIR=/path/to/mysql-<version>-<platform> \
  venv/bin/python -m pytest tests/mrs -q
```

`-k <test>` runs single tests and `--record` rewrites the `.result` files.
Disabled tests are listed in `tests/mrs/disabled.def`, expected failures in
`tests/mrs/known_failures.def`. On Linux (Ubuntu 24.04 and later), the
package's `mysqld` needs `libaio.so.1`: point `LD_LIBRARY_PATH` at a directory
with a `libaio.so.1 -> libaio.so.1t64` link.

**Smoke test** (`tools/smoke/run_smoke.sh`): starts `mysqld` and mrsd, creates
a REST view with MySQL Shell and checks that it is served; see the script for
its parameters.

## Repository layout

| | |
|---|---|
| `src/` | the router modules mrsd uses (harness, http, mysql_rest_service, jit_executor, ...) |
| `compat/` | replacements for MySQL client library internals the router code used |
| `cmake/compat/` | the parts of the MySQL server's build system the router CMake files expect |
| `extra/` | vendored code: rapidjson, libcno, googletest, duktape, MySQL server headers |
| `tests/` | component tests, test helpers, MRS functional tests (`tests/mrs`), test data |
| `tools/` | smoke test, dependency analysis scripts |
| `docs/` | plan, progress log, dependency inventory |

[README.router](README.router) and [MRS_README.router](MRS_README.router) are
MySQL Router's documentation, kept from upstream.

## License

GPLv2, see [LICENSE.router](LICENSE.router).
