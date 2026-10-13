/*
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License, version 2.0,
  as published by the Free Software Foundation.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*/

#ifndef ROUTER_SRC_ROUTER_SRC_MRSD_SETUP_H_
#define ROUTER_SRC_ROUTER_SRC_MRSD_SETUP_H_

#include <cstdint>
#include <map>
#include <memory>
#include <ostream>
#include <string>
#include <vector>

#include "mysql/harness/arg_handler.h"
#include "mysql/harness/auto_cleaner.h"
#include "mysqlrouter/accounts_cleaner.h"
#include "mysqlrouter/keyring_info.h"
#include "mysqlrouter/mysql_session.h"
#include "mysqlrouter/uri.h"

/**
 * `mariadb-restd --setup`: prepares a self-contained deployment directory for
 * MRS against a single MySQL server.
 *
 * Follows the MRS part of MySQL Router's bootstrap
 * (BootstrapConfigurator::configure_mrs() and the directory deployment of
 * ConfigGenerator): checks the MRS metadata, registers the instance in
 * `mariadb_rest_service.rest_daemon`, creates the MRS accounts, stores their
 * passwords and the JWT secret in the keyring, creates TLS certificates for
 * the HTTPS server and writes the configuration file and start/stop scripts.
 * There is no router account and there are no routing sections: the server is
 * the configuration's `mysql_read_write_destinations`.
 *
 * Everything created is removed again if the setup fails.
 */
class MrsdSetup {
 public:
  MrsdSetup(std::ostream &out_stream, std::ostream &err_stream);

  /**
   * @param program_name argv[0]
   * @param arguments the arguments after `--setup`
   *
   * @throws std::runtime_error on invalid arguments
   */
  void init(const std::string &program_name,
            const std::vector<std::string> &arguments);

  /**
   * @throws std::runtime_error, std::system_error, MySQLSession::Error
   */
  void run();

 private:
  struct Credentials {
    std::string user;
    std::string pass;
  };

  void prepare_command_options();
  void show_help();
  std::string get_version_line() const;

  void parse_server_uri(const std::string &server_uri);
  std::map<std::string, std::string> get_config_cmdln_options() const;
  std::string get_cmdln_option(const std::string &key,
                               const std::string &default_value = "") const;

  void connect();
  void check_mrs_metadata();
  void prepare_directory();
  void prepare_system_paths();
  void check_files_exist();
  void set_owner();
  void load_existing_deployment();
  std::string register_instance();
  void store_developer(const std::string &rest_daemon_id);
  void create_accounts(const std::string &rest_daemon_id);
  void store_account_metadata(const std::string &rest_daemon_id, const std::string &key,
                              const std::string &user);
  bool prepare_tls_certificates();
  void store_secrets_in_keyring(const std::string &rest_daemon_id);
  void write_config(const std::string &rest_daemon_id);
  void write_scripts();
  void print_report() const;

  std::string router_name() const;
  std::string mysql_destination() const;
  uint16_t http_port() const;
  bool http_ssl() const;

  std::ostream &out_stream_;

  std::string program_path_;
  CmdArgHandler arg_handler_;
  bool showing_info_{false};

  // command line
  std::string server_uri_;
  std::string directory_;  // empty: system deployment (default folders)
  std::string user_;       // --user: owner of the created files (not Windows)
  std::string name_;
  std::string report_host_;
  std::string socket_;
  int connect_timeout_{mysqlrouter::MySQLSession::kDefaultConnectTimeout};
  int read_timeout_{mysqlrouter::MySQLSession::kDefaultReadTimeout};
  std::map<std::string, std::string> ssl_options_;  // config option -> value
  Credentials metadata_account_;
  Credentials data_account_;
  std::string jwt_secret_;
  std::string developer_;
  std::string developer_debug_port_;
  std::vector<std::string> conf_set_options_;
  bool force_{false};

  // derived
  mysqlrouter::URI target_uri_;
  std::map<std::string, std::string> config_cmdln_options_;
  std::string config_path_;
  std::string logdir_;
  std::string rundir_;
  std::string datadir_;
  KeyringInfo keyring_info_{false};
  std::vector<std::string> created_paths_;  // chowned with --user
  // accounts of an existing deployment (--force), passwords from its keyring
  bool reuse_metadata_account_{false};
  bool reuse_data_account_{false};

  std::unique_ptr<mysqlrouter::MySQLSession> mysql_;

  // undo on failure; declared last so that they run first on destruction
  mysqlrouter::MySQLAccountsCleaner accounts_cleaner_;
  mysql_harness::AutoCleaner auto_cleaner_;
};

#endif  // ROUTER_SRC_ROUTER_SRC_MRSD_SETUP_H_
