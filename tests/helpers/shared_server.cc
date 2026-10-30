/*
  Copyright (c) 2022, 2026, Oracle and/or its affiliates.
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License, version 2.0,
  as published by the Free Software Foundation.

  This program is designed to work with certain software (including
  but not limited to OpenSSL) that is licensed under separate terms,
  as designated in a particular file or component or in included license
  documentation.  The authors of MySQL and, with respect to its
  modifications and additions, MariaDB plc hereby grant you an additional
  permission to link the program and your derivative works with the
  separately licensed software that they have either included with
  the program or referenced in the documentation.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*/

#include "shared_server.h"

#include <cstdlib>
#include <optional>

#include <gtest/gtest.h>

#include <iomanip>

#define RAPIDJSON_HAS_STDSTRING 1

#include "my_rapidjson_size_t.h"

#include <rapidjson/document.h>
#include <rapidjson/rapidjson.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>

#include "mysql/harness/stdx/expected.h"
#include "mysql/harness/stdx/expected_ostream.h"
#include "mysqlrouter/utils.h"  // copy_file
#include "stdx_expected_no_error.h"

using namespace std::chrono_literals;

static std::ostream &operator<<(std::ostream &os, MysqlError e) {
  os << e.sql_state() << " (" << e.value() << ") " << e.message();
  return os;
}

static void copy_tree(const mysql_harness::Directory &from_dir,
                      const mysql_harness::Directory &to_dir) {
  for (const auto &path : from_dir) {
    auto from = path;
    auto to = to_dir.join(path.basename());

    if (path.is_directory()) {
      mysql_harness::mkdir(to.str(), mysql_harness::kStrictDirectoryPerm);
      copy_tree(from, to);
    } else {
      mysql_harness::copy_file(from.str(), to.str());
    }
  }
}

SharedServer::~SharedServer() {
  // shutdown via API to get a clean exit-code on windows.
  if (starts_) {
    shutdown();
    process_manager().wait_for_exit();
  }
}

stdx::expected<void, MysqlError> SharedServer::shutdown() {
  auto cli_res = admin_cli();
  if (!cli_res) return stdx::unexpected(cli_res.error());

  return shutdown(*cli_res);
}

stdx::expected<void, MysqlError> SharedServer::shutdown(MysqlClient &cli) {
  auto shutdown_res = cli.shutdown();
  if (!shutdown_res) return stdx::unexpected(shutdown_res.error());

  return {};
}

[[nodiscard]] std::string SharedServer::mysqld_init_once_dir_name() const {
  return mysqld_init_once_dir_->name();
}

[[nodiscard]] std::string SharedServer::mysqld_dir_name() const {
  return mysqld_dir_.name();
}

#ifdef _WIN32
#define EXE_EXTENSION ".exe"
#define SO_EXTENSION ".dll"
#else
#define EXE_EXTENSION ""
#define SO_EXTENSION ".so"
#endif

namespace {
// restd: a MariaDB server (upstream: mysqld from the server build tree), from
// the environment variables the MRS functional suite uses: MARIADB_BUILD_DIR (+ MARIADB_SOURCE_DIR, for
// mariadb-install-db) for a server build tree, or MARIADB_PACKAGE_DIR for a
// server package.
struct MariadbServer {
  mysql_harness::Path mariadbd;
  std::vector<std::string> install_db;  // the command, without the datadir
  std::vector<std::string> server_args;
};

std::string env_or_empty(const char *name) {
  const char *v = std::getenv(name);
  return v ? v : "";
}

std::optional<MariadbServer> mariadb_server() {
  using mysql_harness::Path;
  if (auto build = env_or_empty("MARIADB_BUILD_DIR"); !build.empty()) {
    Path b(build);
    return MariadbServer{
        b.join("sql").join("mariadbd" EXE_EXTENSION),
        {b.join("scripts").join("mariadb-install-db").str(), "--no-defaults",
         "--srcdir=" + env_or_empty("MARIADB_SOURCE_DIR"),
         "--builddir=" + build},
        {"--lc-messages-dir=" + b.join("sql").join("share").str()}};
  }
  if (auto pkg = env_or_empty("MARIADB_PACKAGE_DIR"); !pkg.empty()) {
    Path p(pkg);
#ifdef _WIN32
    std::vector<std::string> install{
        p.join("bin").join("mariadb-install-db.exe").str()};
#else
    std::vector<std::string> install{
        p.join("scripts").join("mariadb-install-db").str(), "--no-defaults",
        "--basedir=" + pkg};
#endif
    return MariadbServer{p.join("bin").join("mariadbd" EXE_EXTENSION),
                         install,
                         {"--basedir=" + pkg}};
  }
  return std::nullopt;
}
}  // namespace

// initialize the server
//
// initializes the server once into mysqld_init_once_dir_ and creates copies
// from that into mysqld_dir_
void SharedServer::initialize_server(const std::string &datadir) {
  auto mariadb = mariadb_server();
  if (!mariadb || !mariadb->mariadbd.exists()) {
    mysqld_failed_to_start_ = true;
    return;
  }
  std::vector<std::string> args(mariadb->install_db.begin() + 1,
                                mariadb->install_db.end());
#ifdef _WIN32
  args.push_back("-d");
  args.push_back(datadir);  // no -R: root@localhost, no anonymous accounts
#else
  args.push_back("--datadir=" + datadir);
  args.push_back("--auth-root-authentication-method=normal");
  // no test database and, with it, no anonymous accounts (they would
  // shadow '%' accounts for local connections)
  args.push_back("--skip-test-db");
#endif
  auto &proc = process_manager()
                   .spawner(mariadb->install_db.front())
                   .wait_for_sync_point(ProcessManager::Spawner::SyncPoint::NONE)
                   .spawn(args);
  try {
    proc.wait_for_exit(120s);
  } catch (const std::exception &e) {
    process_manager().dump_logs();
    FAIL() << e.what();
  }
  if (proc.exit_code() != 0) {
    mysqld_failed_to_start_ = true;
    process_manager().dump_logs();
  }
}

void SharedServer::prepare_datadir() {
  if (mysqld_init_once_dir_ == nullptr) {
    mysqld_init_once_dir_ = new TempDirectory("mysqld-init-once");

    ASSERT_NO_FATAL_FAILURE(initialize_server(mysqld_init_once_dir_name()));
  }

  // copy the init-once dir to the datadir.
  copy_tree(mysqld_init_once_dir_name(), mysqld_dir_name());

  // remove the auto.cnf to get a unique server-uuid
  unlink(mysqld_dir_.file("auto.cnf").c_str());
  unlink(mysqld_dir_.file("error.log").c_str());
}

void SharedServer::spawn_server_with_datadir(
    const std::string &datadir, const std::vector<std::string> &extra_args) {
  SCOPED_TRACE("// start server");

  std::string log_file_name = "mysqld-" + std::to_string(starts_) + ".err";

  // set the socket-path's in the datadir.
  classic_socket_dest_ = {Path(datadir).join("mysql.sock").str()};

  auto mariadb = mariadb_server();
  if (!mariadb) {
    mysqld_failed_to_start_ = true;
    return;
  }
  // restd: no X protocol, GTID or redo-log options on MariaDB, and no
  // systemd notification (a build without systemd sends none): wait for
  // the port instead
  std::vector<std::string> margs{
      "--no-defaults",
      "--datadir=" + datadir,
      "--log-error=" + datadir + mysql_harness::Path::directory_separator +
          log_file_name,
      "--port=" + std::to_string(classic_tcp_destination().port()),
      "--bind-address=127.0.0.1",
#ifndef _WIN32
      "--socket=" + classic_socket_destination().path(),
#endif
      "--innodb_buffer_pool_size=16M",
      // the tests compare binary-log positions to see whether a request
      // wrote; MySQL logs by default, MariaDB does not
      "--log-bin=binlog",
  };
  for (const auto &a : mariadb->server_args) margs.push_back(a);
  for (const auto &arg : extra_args) margs.push_back(arg);

  auto &proc = process_manager()
                   .spawner(mariadb->mariadbd.str())
                   .wait_for_sync_point(ProcessManager::Spawner::SyncPoint::NONE)
                   .spawn(margs);
  proc.set_logging_path(datadir, log_file_name);
  if (!wait_for_port_ready(classic_tcp_destination().port(), 60s)) {
    mysqld_failed_to_start_ = true;
    process_manager().dump_logs();
  }
  ++starts_;
}

void SharedServer::spawn_server(const std::vector<std::string> &extra_args) {
  spawn_server_with_datadir(mysqld_dir_name(), extra_args);
}

struct Account {
  std::string username;
  std::string password;
  std::string auth_method;
};

stdx::expected<MysqlClient, MysqlError> SharedServer::admin_cli() {
  MysqlClient cli;

  auto account = admin_account();

  cli.username(account.username);
  cli.password(account.password);

  auto tcp_dest = classic_tcp_destination();

  auto connect_res = cli.connect(tcp_dest.hostname(), tcp_dest.port());
  if (!connect_res) return stdx::unexpected(connect_res.error());

  return cli;
}

void SharedServer::create_schema(MysqlClient &cli, const std::string &schema) {
  std::ostringstream oss;
  oss << "CREATE SCHEMA " << std::quoted(schema, '`');

  auto q = oss.str();

  SCOPED_TRACE("// " + q);
  ASSERT_NO_ERROR(cli.query(q)) << q;
}

void SharedServer::grant_access(MysqlClient &cli, const Account &account,
                                const std::string &rights) {
  std::ostringstream oss;
  oss << "GRANT " << rights << " ON *.* TO "
      << std::quoted(account.username, '`');

  auto q = oss.str();

  SCOPED_TRACE("// " + q);
  ASSERT_NO_ERROR(cli.query(q)) << q;
}

void SharedServer::grant_access(MysqlClient &cli, const Account &account,
                                const std::string &rights,
                                const std::string &schema) {
  std::ostringstream oss;
  oss << "GRANT " << rights << "  ON " << std::quoted(schema, '`') << ".* TO "
      << std::quoted(account.username, '`');

  auto q = oss.str();

  SCOPED_TRACE("// " + q);
  ASSERT_NO_ERROR(cli.query(q)) << q;
}

void SharedServer::flush_privileges() {
  SCOPED_TRACE("// flushing privileges");
  auto cli_res = admin_cli();
  ASSERT_NO_ERROR(cli_res);

  flush_privileges(*cli_res);
}

void SharedServer::flush_privileges(MysqlClient &cli) {
  ASSERT_NO_ERROR(cli.query("FLUSH PRIVILEGES"));
}

// set global settings to default values.
void SharedServer::reset_to_defaults() {
  auto cli_res = admin_cli();
  ASSERT_NO_ERROR(cli_res);

  reset_to_defaults(*cli_res);
}

// set global settings to default values.
void SharedServer::reset_to_defaults(MysqlClient &cli) {
  ASSERT_NO_ERROR(cli.query("SET GLOBAL max_connections = DEFAULT"));
}

void SharedServer::destroy_statics() {
  if (mysqld_init_once_dir_) {
    delete mysqld_init_once_dir_;
    mysqld_init_once_dir_ = nullptr;
  }
}

TempDirectory *SharedServer::mysqld_init_once_dir_ = nullptr;
