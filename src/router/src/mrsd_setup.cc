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

#include "mrsd_setup.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <system_error>

#ifndef _WIN32
#include <sys/stat.h>  // chmod
#endif

#include "bootstrap_mysql_account.h"
#include "certificate_handler.h"
#include "config_section_printer.h"
#include "keyring/keyring_manager.h"
#include "mrs/database/query_version.h"
#include "my_macros.h"  // IF_WIN
#include "mysql/harness/config_option.h"
#include "mysql/harness/config_parser.h"
#include "mysql/harness/filesystem.h"
#include "mysql/harness/vt100.h"
#include "mysqld_error.h"
#include "mysqlrouter/default_paths.h"
#include "mysqlrouter/http_constants.h"
#include "mysqlrouter/router_config_utils.h"
#include "mysqlrouter/server_compatibility.h"
#include "mysqlrouter/utils.h"
#include "print_version.h"
#include "random_generator.h"
#include "router_config.h"  // MRSD_PROGRAM_NAME, MYSQL_ROUTER_PACKAGE_NAME
#include "socket_operations.h"
#include "welcome_copyright_notice.h"

using mysql_harness::Path;
using mysqlrouter::MySQLSession;
using namespace std::string_literals;

namespace {

constexpr const char kConfigMrsSection[] = "mysql_rest_service";
constexpr const char kKeyringAttributePassword[] = "password";
constexpr const char kHostOnResolveFailed[] = "unknown";
constexpr uint16_t kDefaultSetupHttpPort = 8443;
constexpr size_t kMaxRouterNameLength = 255;  // metadata router.router_name
constexpr size_t kHelpScreenWidth = 72;
constexpr size_t kHelpScreenIndent = 8;

// file names in the deployment directory
const std::string kConfigFileName = MRSD_PROGRAM_NAME ".conf";
const std::string kMasterKeyFileName = MRSD_PROGRAM_NAME ".key";
const std::string kPidFileName = MRSD_PROGRAM_NAME ".pid";
constexpr const char kKeyringFileName[] = "keyring";
constexpr const char kCaKeyFileName[] = "ca-key.pem";
constexpr const char kCaCertFileName[] = "ca.pem";
constexpr const char kRouterKeyFileName[] = "router-key.pem";
constexpr const char kRouterCertFileName[] = "router-cert.pem";

std::string generate_username(const std::string &prefix, uint64_t router_id) {
  constexpr unsigned kNumRandomChars = 12;
  constexpr unsigned kMaxUsernameChars = 32;

  using RandomGen = mysql_harness::RandomGeneratorInterface;
  const std::string username_prefix =
      prefix + std::to_string(router_id) + "_";

  return username_prefix +
         mysql_harness::RandomGenerator().generate_identifier(
             std::min<unsigned>(kMaxUsernameChars - username_prefix.length(),
                                kNumRandomChars),
             RandomGen::AlphabetDigits | RandomGen::AlphabetLowercase);
}

bool is_valid_conf_ident(const std::string &name) {
  if (name.empty()) return false;

  return std::all_of(name.begin(), name.end(),
                     mysql_harness::is_valid_conf_ident_char);
}

bool is_false(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), ::tolower);
  return value == "0" || value == "false" || value == "no" || value == "off";
}

void make_directory(const std::string &dir, mysql_harness::AutoCleaner &cleaner,
                    bool remove_on_failure) {
  const int err = mysql_harness::mkdir(dir, mysql_harness::kStrictDirectoryPerm);
  if (err == 0) {
    if (remove_on_failure) cleaner.add_directory_delete(dir, true);
    return;
  }
  if (err == EEXIST && Path(dir).is_directory()) return;

  throw std::system_error(std::error_code{err, std::generic_category()},
                          "Could not create directory '" + dir + "'");
}

void make_private(const std::string &file, bool read_only_for_local_service) {
  try {
    mysql_harness::make_file_private(file, read_only_for_local_service);
  } catch (const std::system_error &e) {
#ifdef _WIN32
    // filesystems that can't set permissions (FAT, network shares)
    if (e.code() !=
        std::error_code(ERROR_INVALID_FUNCTION, std::system_category()))
#endif
      throw;
  }
}

std::ofstream open_for_writing(const std::string &file) {
  std::ofstream os(file, std::ios::out | std::ios::trunc);
  if (!os) {
    throw std::system_error(std::error_code{errno, std::generic_category()},
                            "Could not open '" + file + "' for writing");
  }
  return os;
}

}  // namespace

MrsdSetup::MrsdSetup(std::ostream &out_stream, std::ostream &err_stream)
    : out_stream_(out_stream), accounts_cleaner_(err_stream) {}

std::string MrsdSetup::get_version_line() const {
  std::string version_string;
  build_version(std::string(MYSQL_ROUTER_PACKAGE_NAME), &version_string);
  return version_string;
}

void MrsdSetup::prepare_command_options() {
  using OptionNames = CmdOption::OptionNames;

  arg_handler_.clear_options();

  arg_handler_.add_option(
      OptionNames({"-d", "--directory"}),
      "Directory of the deployment: configuration, keyring, TLS "
      "certificates, logs and start/stop scripts. Created if it doesn't "
      "exist.",
      CmdOptionValueReq::required, "directory",
      [this](const std::string &value) {
        if (value.empty()) {
          throw std::runtime_error("Value for --directory can't be empty");
        }
        directory_ = value;
      });
  arg_handler_.add_option(
      OptionNames({"--force"}),
      "Overwrite an existing configuration in the directory (it is backed "
      "up to " +
          kConfigFileName + ".bak).",
      CmdOptionValueReq::none, "", [this](const std::string &) {
        force_ = true;
      });
  arg_handler_.add_option(
      OptionNames({"--name"}),
      "Name of this instance in the MRS metadata (default: "
      "<hostname>:<HTTP port>).",
      CmdOptionValueReq::required, "name", [this](const std::string &value) {
        if (value.find_first_of("\r\n") != std::string::npos) {
          throw std::runtime_error("Value for --name contains a line break");
        }
        if (value.length() > kMaxRouterNameLength) {
          throw std::runtime_error("Value for --name is too long (max " +
                                   std::to_string(kMaxRouterNameLength) + ")");
        }
        name_ = value;
      });
  arg_handler_.add_option(
      OptionNames({"--report-host"}),
      "Host name of this instance to store in the MRS metadata (default: the "
      "local host name).",
      CmdOptionValueReq::required, "host", [this](const std::string &value) {
        if (value.empty()) {
          throw std::runtime_error("Value for --report-host can't be empty");
        }
        report_host_ = value;
      });
  arg_handler_.add_option(
      OptionNames({"--socket"}),
      "Connect to the MySQL server through this Unix socket (the server URI "
      "must use 'localhost'); also used by the configured instance.",
      CmdOptionValueReq::required, "path",
      [this](const std::string &value) { socket_ = value; });
  arg_handler_.add_option(
      OptionNames({"--connect-timeout"}),
      "Timeout in seconds for connecting to the MySQL server (default: " +
          std::to_string(MySQLSession::kDefaultConnectTimeout) + ").",
      CmdOptionValueReq::required, "seconds",
      [this](const std::string &value) {
        connect_timeout_ = mysql_harness::option_as_uint<uint16_t>(
            value, "--connect-timeout", 1);
      });
  arg_handler_.add_option(
      OptionNames({"--read-timeout"}),
      "Timeout in seconds for reading from the MySQL server (default: " +
          std::to_string(MySQLSession::kDefaultReadTimeout) + ").",
      CmdOptionValueReq::required, "seconds",
      [this](const std::string &value) {
        read_timeout_ = mysql_harness::option_as_uint<uint16_t>(
            value, "--read-timeout", 1);
      });

  // TLS to the MySQL server: used for the setup connection and written to
  // the configuration as the mysql_ssl_* options of [mysql_rest_service]
  const std::vector<std::tuple<std::string, std::string, std::string>>
      ssl_options{
          {"--ssl-mode", "mode",
           "TLS mode: DISABLED, PREFERRED (default), REQUIRED, VERIFY_CA, "
           "VERIFY_IDENTITY."},
          {"--ssl-ca", "path", "CA certificate file to verify the server."},
          {"--ssl-capath", "path",
           "Directory of CA certificates to verify the server."},
          {"--ssl-crl", "path", "Certificate revocation list file."},
          {"--ssl-crlpath", "path",
           "Directory of certificate revocation lists."},
          {"--ssl-cipher", "ciphers", "TLS ciphers (TLSv1.2 and earlier)."},
          {"--tls-version", "versions",
           "Comma-separated TLS versions, e.g. TLSv1.2,TLSv1.3."},
      };
  for (const auto &[option, metavar, description] : ssl_options) {
    // --ssl-mode -> mysql_ssl_mode, --tls-version -> mysql_tls_version
    std::string config_option = "mysql_" + option.substr(2);
    std::replace(config_option.begin(), config_option.end(), '-', '_');
    arg_handler_.add_option(
        OptionNames({option}), description, CmdOptionValueReq::required,
        metavar, [this, option, config_option](const std::string &value) {
          if (value.empty()) {
            throw std::runtime_error("Value for " + option +
                                     " can't be empty");
          }
          if (option == "--ssl-mode") {
            // throws std::logic_error on invalid value
            try {
              MySQLSession::parse_ssl_mode(value);
            } catch (const std::logic_error &) {
              throw std::runtime_error(
                  "Invalid value for --ssl-mode: '" + value +
                  "', expected DISABLED, PREFERRED, REQUIRED, VERIFY_CA or "
                  "VERIFY_IDENTITY");
            }
          }
          ssl_options_[config_option] = value;
        });
  }

  arg_handler_.add_option(
      OptionNames({"--metadata-account"}),
      "MySQL account (user name) MRS uses to read its metadata; the password "
      "is prompted for. Created if it doesn't exist. Default: a generated "
      "account.",
      CmdOptionValueReq::required, "username",
      [this](const std::string &value) {
        if (value.empty()) {
          throw std::runtime_error(
              "Value for --metadata-account can't be empty");
        }
        metadata_account_.user = value;
      });
  arg_handler_.add_option(
      OptionNames({"--data-account"}),
      "MySQL account (user name) MRS uses to access the data it serves; the "
      "password is prompted for. Created if it doesn't exist. Default: the "
      "metadata account.",
      CmdOptionValueReq::required, "username",
      [this](const std::string &value) {
        if (value.empty()) {
          throw std::runtime_error("Value for --data-account can't be empty");
        }
        data_account_.user = value;
      });
  arg_handler_.add_option(
      OptionNames({"--jwt-secret"}),
      "Secret for signing JSON Web Tokens; must be the same for all instances "
      "serving the same MRS metadata. Prompted for if not given.",
      CmdOptionValueReq::required, "secret", [this](const std::string &value) {
        if (value.empty()) {
          throw std::runtime_error("Value for --jwt-secret can't be empty");
        }
        jwt_secret_ = value;
      });
  arg_handler_.add_option(
      OptionNames({"--developer"}),
      "Also serve the services in development by this developer.",
      CmdOptionValueReq::required, "developer",
      [this](const std::string &value) {
        if (value.empty()) {
          throw std::runtime_error("Value for --developer can't be empty");
        }
        developer_ = value;
      });
  arg_handler_.add_option(
      OptionNames({"--developer-debug-port"}),
      "TCP port of a debug server for JavaScript MRS endpoints (needs "
      "--developer).",
      CmdOptionValueReq::required, "port", [this](const std::string &value) {
        mysql_harness::option_as_uint<uint16_t>(value, "--developer-debug-port",
                                                1);
        developer_debug_port_ = value;
      });
  arg_handler_.add_option(
      OptionNames({"--conf-set-option"}),
      "Set an option in the generated configuration, e.g. "
      "--conf-set-option=http_server.port=8080. Can be repeated.",
      CmdOptionValueReq::required, "section.option=value",
      [this](const std::string &value) { conf_set_options_.push_back(value); });
  arg_handler_.add_option(
      OptionNames({"--master-key-reader"}),
      "Command that prints the keyring's master key, instead of a master key "
      "file in the directory.",
      CmdOptionValueReq::required, "command",
      [this](const std::string &value) {
        keyring_info_.set_master_key_reader(value);
      });
  arg_handler_.add_option(
      OptionNames({"--master-key-writer"}),
      "Command that stores the keyring's master key (read from stdin); "
      "used with --master-key-reader.",
      CmdOptionValueReq::required, "command",
      [this](const std::string &value) {
        keyring_info_.set_master_key_writer(value);
      });

  arg_handler_.add_option(
      OptionNames({"-V", "--version"}), "Display version information and exit.",
      CmdOptionValueReq::none, "", [this](const std::string &) {
        out_stream_ << get_version_line() << "\n";
        showing_info_ = true;
      });
  arg_handler_.add_option(OptionNames({"-?", "--help"}),
                          "Display this help and exit.",
                          CmdOptionValueReq::none, "",
                          [this](const std::string &) {
                            show_help();
                            showing_info_ = true;
                          });
}

void MrsdSetup::show_help() {
  out_stream_ << get_version_line() << "\n"
              << ORACLE_WELCOME_COPYRIGHT_NOTICE("2015") << "\n\n";

  out_stream_ << Vt100::render(Vt100::Render::Bold) << "# Usage"
              << Vt100::render(Vt100::Render::Normal) << "\n\n";
  out_stream_ << MRSD_PROGRAM_NAME
      " --setup [<user>[:<password>]@]<host>[:<port>] -d <directory> "
      "[options]\n\n"
      "Prepares a deployment directory for the MySQL REST Service of the "
      "given\nMySQL server, which must have the MRS metadata schema. The "
      "account in the\nURI (default: root) needs to create accounts, grant "
      "the MRS roles and\nwrite the MRS metadata. Its password is prompted "
      "for if not in the URI.\n\n";

  out_stream_ << Vt100::render(Vt100::Render::Bold) << "# Options"
              << Vt100::render(Vt100::Render::Normal) << "\n\n";
  for (const auto &line :
       arg_handler_.option_descriptions(kHelpScreenWidth, kHelpScreenIndent)) {
    out_stream_ << line << "\n";
  }

  out_stream_ << "\n"
              << Vt100::render(Vt100::Render::Bold) << "# Examples"
              << Vt100::render(Vt100::Render::Normal) << "\n\n"
              << "    " MRSD_PROGRAM_NAME
                 " --setup admin@db1.example.com:3306 -d /srv/mrsd\n"
              << "    /srv/mrsd/" << IF_WIN("start.ps1", "start.sh") << "\n";
}

void MrsdSetup::init(const std::string &program_name,
                     const std::vector<std::string> &arguments) {
  program_path_ = mysqlrouter::find_full_executable_path(program_name);

  std::vector<std::string> args = arguments;
  if (!args.empty() && !args[0].empty() && args[0][0] != '-') {
    server_uri_ = args[0];
    args.erase(args.begin());
  }

  prepare_command_options();
  try {
    arg_handler_.process(args);
  } catch (const std::invalid_argument &e) {
    throw std::runtime_error(e.what());
  }
  if (showing_info_) return;

  if (server_uri_.empty()) {
    throw std::runtime_error(
        "--setup needs the URI of the MySQL server as its first argument: "
        "--setup [<user>[:<password>]@]<host>[:<port>]");
  }
  if (directory_.empty()) {
    throw std::runtime_error(
        "--setup needs the deployment directory: -d <directory>");
  }
  if (!developer_debug_port_.empty() && developer_.empty()) {
    throw std::runtime_error("--developer-debug-port needs --developer");
  }
  if (keyring_info_.get_master_key_reader().empty() !=
      keyring_info_.get_master_key_writer().empty()) {
    throw std::runtime_error(
        "--master-key-reader and --master-key-writer must be used together");
  }

  config_cmdln_options_ = get_config_cmdln_options();
  parse_server_uri(server_uri_);
}

void MrsdSetup::parse_server_uri(const std::string &server_uri) {
  const std::string default_scheme = "mysql://";
  const std::string uri =
      server_uri.starts_with(default_scheme) ? server_uri
                                             : default_scheme + server_uri;
  try {
    // no rootless URIs: they collide with the scheme-less user:pw@host form
    target_uri_ = mysqlrouter::URIParser::parse(uri, false);
  } catch (const mysqlrouter::URIError &e) {
    throw std::runtime_error("Invalid server URI '" + server_uri +
                             "': " + e.what());
  }

  if (!target_uri_.fragment.empty() || !target_uri_.query.empty() ||
      !target_uri_.path.empty()) {
    throw std::runtime_error("Invalid server URI '" + server_uri +
                             "': expected [<user>[:<password>]@]<host>[:<port>]");
  }
  if (!socket_.empty() && target_uri_.host != "localhost") {
    throw std::runtime_error(
        "--socket needs 'localhost' as the host of the server URI, not '" +
        target_uri_.host + "'");
  }
  if (target_uri_.username.empty()) target_uri_.username = "root";
  if (target_uri_.port == 0) target_uri_.port = 3306;
}

std::map<std::string, std::string> MrsdSetup::get_config_cmdln_options()
    const {
  std::map<std::string, std::string> result;

  for (const auto &option : conf_set_options_) {
    const auto invalid = [&option](const std::string &why) {
      return std::runtime_error("--conf-set-option: invalid option '" +
                                option + "': " + why);
    };

    const auto eq_pos = option.find('=');
    if (eq_pos == std::string::npos) {
      throw invalid("expected section.option_name=value");
    }
    std::string option_id = option.substr(0, eq_pos);
    const std::string option_value = option.substr(eq_pos + 1);

    const auto dot = option_id.find('.');
    if (dot == std::string::npos) {
      throw invalid("expected section.option_name=value");
    }

    const std::string section_name = option_id.substr(0, dot);
    const auto colon = section_name.find(':');
    bool section_name_valid;
    if (colon != std::string::npos) {
      std::string section = section_name.substr(0, colon);
      section_name_valid = is_valid_conf_ident(section) &&
                           is_valid_conf_ident(section_name.substr(colon + 1));
      std::transform(section.begin(), section.end(), section.begin(),
                     ::tolower);
      if (section == "default") {
        throw invalid("the DEFAULT section can't have a key");
      }
    } else {
      section_name_valid = is_valid_conf_ident(section_name);
    }
    if (!section_name_valid) throw invalid("invalid section name");

    if (!is_valid_conf_ident(option_id.substr(dot + 1))) {
      throw invalid("invalid option name");
    }

    std::transform(option_id.begin(), option_id.end(), option_id.begin(),
                   ::tolower);
    if (option_id.starts_with(kConfigMrsSection + "."s)) {
      throw invalid("[mysql_rest_service] is configured by --setup's own "
                    "options");
    }
    if (!result.emplace(option_id, option_value).second) {
      throw invalid("duplicate value for '" + option_id + "'");
    }
  }

  return result;
}

std::string MrsdSetup::get_cmdln_option(
    const std::string &key, const std::string &default_value) const {
  const auto it = config_cmdln_options_.find(key);
  return it == config_cmdln_options_.end() ? default_value : it->second;
}

uint16_t MrsdSetup::http_port() const {
  const auto port = get_cmdln_option("http_server.port");
  if (port.empty()) return kDefaultSetupHttpPort;

  return mysql_harness::option_as_uint<uint16_t>(port, "http_server.port", 1);
}

bool MrsdSetup::http_ssl() const {
  return !is_false(get_cmdln_option("http_server.ssl", "1"));
}

std::string MrsdSetup::router_name() const {
  // the name the MRS plugin computes at runtime from the configuration
  std::stringstream ss;
  ss << "[DEFAULT]\n";
  if (!name_.empty()) ss << "name=" << name_ << "\n";
  ss << "[http_server]\nport=" << http_port() << "\n";

  mysql_harness::Config config{mysql_harness::Config::allow_keys};
  config.read(ss);

  const auto name = get_configured_router_name(config, kDefaultHttpPort);
  return name ? *name
              : std::string{kHostOnResolveFailed} + ":" +
                    std::to_string(http_port());
}

std::string MrsdSetup::mysql_destination() const {
  if (!socket_.empty()) return "local:" + socket_;

  const bool is_ipv6 = target_uri_.host.find(':') != std::string::npos;
  return (is_ipv6 ? "[" + target_uri_.host + "]" : target_uri_.host) + ":" +
         std::to_string(target_uri_.port);
}

void MrsdSetup::connect() {
  if (target_uri_.password.empty()) {
    target_uri_.password = mysqlrouter::prompt_password(
        "Please enter MySQL password for " + target_uri_.username);
  }

  mysql_ = std::make_unique<MySQLSession>();

  const auto ssl_option = [this](const std::string &name) {
    const auto it = ssl_options_.find(name);
    return it == ssl_options_.end() ? std::string{} : it->second;
  };
  const std::string ssl_mode = ssl_option("mysql_ssl_mode");

  try {
    mysql_->set_ssl_options(
        MySQLSession::parse_ssl_mode(
            ssl_mode.empty() ? MySQLSession::kSslModePreferred : ssl_mode),
        ssl_option("mysql_tls_version"), ssl_option("mysql_ssl_cipher"),
        ssl_option("mysql_ssl_ca"), ssl_option("mysql_ssl_capath"),
        ssl_option("mysql_ssl_crl"), ssl_option("mysql_ssl_crlpath"));
    mysql_->connect(target_uri_.host, target_uri_.port, target_uri_.username,
                    target_uri_.password, socket_, "", connect_timeout_,
                    read_timeout_);
  } catch (const MySQLSession::Error &e) {
    throw std::runtime_error("Unable to connect to the MySQL server at '" +
                             mysql_destination() + "': " + e.what());
  }

  accounts_cleaner_.set_session(mysql_.get());
}

void MrsdSetup::check_mrs_metadata() {
  mrs::database::MrsSchemaVersion version;
  try {
    version = mrs::database::QueryVersion().query_version(mysql_.get());
  } catch (const MySQLSession::Error &e) {
    if (e.code() == ER_BAD_DB_ERROR) {
      throw std::runtime_error(
          "The MRS metadata schema (mysql_rest_service_metadata) was not found "
          "on the MySQL server. Create it first, e.g. with MySQL Shell "
          "(\\sql CONFIGURE REST METADATA).");
    }
    throw std::runtime_error("Could not read the MRS metadata version: "s +
                             e.what());
  }

  // the versions the MRS plugin accepts at runtime
  if (!version.is_compatible({mrs::database::kCurrentMrsMetadataVersion,
                              {3, 0, 2},
                              {2, 2, 0}})) {
    throw std::runtime_error("Unsupported MRS metadata version " +
                             version.str());
  }

  check_version_compatibility(mysql_.get());
}

void MrsdSetup::prepare_directory() {
  Path path(directory_);
  const bool new_directory = !path.exists();
  if (new_directory) {
    make_directory(directory_, auto_cleaner_, true);
  } else if (!path.is_directory()) {
    throw std::runtime_error("'" + directory_ + "' is not a directory");
  }

  path = path.real_path();
  directory_ = path.str();
  config_path_ = path.join(kConfigFileName).str();

  if (Path(config_path_).exists()) {
    if (!force_) {
      throw std::runtime_error("'" + directory_ + "' already contains " +
                               kConfigFileName +
                               "; use --force to overwrite it");
    }
    load_existing_deployment();
  } else if (!new_directory && !mysql_harness::Directory(path).is_empty()) {
    throw std::runtime_error("Directory '" + directory_ +
                             "' already contains files");
  }

  logdir_ = path.join("log").str();
  rundir_ = path.join("run").str();
  datadir_ = path.join("data").str();
  for (const auto &dir : {logdir_, rundir_, datadir_}) {
    make_directory(dir, auto_cleaner_, !new_directory);
  }

  keyring_info_.set_keyring_file(Path(datadir_).join(kKeyringFileName).str());
  if (keyring_info_.get_master_key_reader().empty()) {
    keyring_info_.set_master_key_file(path.join(kMasterKeyFileName).str());
  }
}

/**
 * Takes over the MRS accounts and the JWT secret of the deployment that
 * --force overwrites, unless given on the command line, so that a re-run
 * doesn't leave unused accounts behind.
 */
void MrsdSetup::load_existing_deployment() {
  mysql_harness::Config config{mysql_harness::Config::allow_keys};
  try {
    config.read(config_path_);
  } catch (const std::exception &e) {
    out_stream_ << "- Ignoring the existing configuration: " << e.what()
                << "\n";
    return;
  }

  const auto &defaults = config.get_default_section();
  if (!config.has(kConfigMrsSection) || !defaults.has("keyring_path") ||
      !defaults.has("master_key_path")) {
    return;
  }
  const auto &mrs = config.get(kConfigMrsSection, "");
  const auto option = [&mrs](const char *name) {
    return mrs.has(name) ? mrs.get(name) : std::string{};
  };
  const std::string metadata_user = option("mysql_user");
  const std::string data_user = option("mysql_user_data_access");

  try {
    mysql_harness::init_keyring(defaults.get("keyring_path"),
                                defaults.get("master_key_path"), false);
    auto *keyring = mysql_harness::get_keyring();

    if (metadata_account_.user.empty() && !metadata_user.empty()) {
      metadata_account_ = {metadata_user,
                           keyring->fetch(metadata_user,
                                          kKeyringAttributePassword)};
      reuse_metadata_account_ = true;
    }
    if (data_account_.user.empty() && !data_user.empty() &&
        data_user != metadata_account_.user) {
      data_account_ = {data_user,
                       keyring->fetch(data_user, kKeyringAttributePassword)};
      reuse_data_account_ = true;
    }
    if (jwt_secret_.empty()) {
      try {
        jwt_secret_ = keyring->fetch("rest-user", "jwt_secret");
      } catch (const std::out_of_range &) {
      }
    }
  } catch (const std::exception &e) {
    out_stream_ << "- Could not read the existing keyring (" << e.what()
                << "), new accounts are created\n";
    if (reuse_metadata_account_) metadata_account_ = {};
    if (reuse_data_account_) data_account_ = {};
    reuse_metadata_account_ = reuse_data_account_ = false;
  }
  mysql_harness::reset_keyring();

  if (reuse_metadata_account_) {
    out_stream_ << "- Reusing the account(s) of the existing configuration\n";
  }
}

uint64_t MrsdSetup::register_instance() {
  std::string report_host = report_host_;
  if (report_host.empty()) {
    try {
      report_host = mysql_harness::SocketOperations::instance()
                        ->get_local_hostname();
    } catch (
        const mysql_harness::SocketOperations::LocalHostnameResolutionError &) {
      out_stream_ << "Could not determine the host name to store in the "
                     "metadata, storing '"
                  << kHostOnResolveFailed
                  << "'. --report-host sets it explicitly.\n";
      report_host = kHostOnResolveFailed;
    }
  }

  const std::string name = router_name();
  mysql_->execute(
      "INSERT INTO mysql_rest_service_metadata.router"
      " (router_name, address, product_name, version, attributes, options)"
      " VALUES (" +
      mysql_->quote(name) + ", " + mysql_->quote(report_host) + ", " +
      mysql_->quote(MYSQL_ROUTER_PACKAGE_NAME) + ", " +
      mysql_->quote(MYSQL_ROUTER_VERSION) +
      ", '{}', '{}') ON DUPLICATE KEY UPDATE version=" +
      mysql_->quote(MYSQL_ROUTER_VERSION) +
      ", router_name=" + mysql_->quote(name) + ", last_check_in=NOW()");

  // id of the row just inserted or updated
  const auto row = mysql_->query_one(
      "SELECT id FROM mysql_rest_service_metadata.router WHERE router_name = " +
      mysql_->quote(name) + " AND address = " + mysql_->quote(report_host));
  if (row && (*row)[0]) {
    try {
      return std::stoull(std::string((*row)[0]));
    } catch (const std::exception &) {
    }
  }
  throw std::runtime_error(
      "Could not determine the id of this instance in the MRS metadata");
}

void MrsdSetup::store_developer(uint64_t router_id) {
  std::string sql = "UPDATE mysql_rest_service_metadata.router SET attributes=";
  if (developer_.empty()) {
    sql += "JSON_REMOVE(attributes, '$.developer')";
  } else {
    sql +=
        "JSON_SET(attributes, '$.developer'," + mysql_->quote(developer_) + ")";
  }
  sql += " WHERE id = " + std::to_string(router_id);
  mysql_->execute(sql);
}

void MrsdSetup::store_account_metadata(uint64_t router_id,
                                       const std::string &key,
                                       const std::string &user) {
  mysql_->execute(
      "UPDATE mysql_rest_service_metadata.router SET attributes = "
      "JSON_MERGE_PRESERVE(attributes, JSON_OBJECT(" +
      mysql_->quote(key) + ", JSON_ARRAY(" + mysql_->quote(user + "@%") +
      "))) WHERE id = " + std::to_string(router_id));
}

void MrsdSetup::create_accounts(uint64_t router_id) {
  bool password_change_ok = false;
  bool autogenerated = false;
  if (reuse_metadata_account_) {
    // password from the existing keyring
  } else if (metadata_account_.user.empty()) {
    // mariadb-mrsd -> mariadb_mrsd<router_id>_<random>
    std::string prefix = MRSD_PROGRAM_NAME;
    std::replace(prefix.begin(), prefix.end(), '-', '_');
    metadata_account_.user = generate_username(prefix, router_id);
    password_change_ok = true;
    autogenerated = true;
  } else {
    metadata_account_.pass = mysqlrouter::prompt_password(
        "Please enter MySQL password for MRS metadata account " +
        metadata_account_.user);
  }

  const bool separate_data_account =
      !data_account_.user.empty() &&
      data_account_.user != metadata_account_.user;
  if (separate_data_account && !reuse_data_account_) {
    data_account_.pass = mysqlrouter::prompt_password(
        "Please enter MySQL password for MRS data account " +
        data_account_.user);
  } else {
    data_account_ = metadata_account_;
  }

  try {
    BootstrapMySQLAccount accounts{mysql_.get(), accounts_cleaner_};

    UserOptions user_options;
    user_options.account_create = "if-not-exists";
    user_options.autogenerated = autogenerated;
    user_options.grant_role = {"mysql_rest_service_meta_provider"};
    if (!separate_data_account) {
      user_options.grant_role.push_back("mysql_rest_service_data_provider");
    }

    metadata_account_.pass = accounts.create_router_accounts(
        user_options, {"%"}, metadata_account_.user, metadata_account_.pass,
        password_change_ok);
    store_account_metadata(router_id, "mrs_metadata_accounts",
                           metadata_account_.user);

    if (separate_data_account) {
      user_options.autogenerated = false;
      user_options.grant_role = {"mysql_rest_service_data_provider"};
      data_account_.pass = accounts.create_router_accounts(
          user_options, {"%"}, data_account_.user, data_account_.pass, false);
      store_account_metadata(router_id, "mrs_data_accounts",
                             data_account_.user);
    } else {
      data_account_ = metadata_account_;
    }
  } catch (const MySQLSession::Error &e) {
    throw std::runtime_error("Creating the MRS accounts failed: "s + e.what());
  }
}

bool MrsdSetup::prepare_tls_certificates() {
  // only if the HTTPS server uses the default certificate
  if (!http_ssl() || !get_cmdln_option("http_server.ssl_cert").empty() ||
      !get_cmdln_option("http_server.ssl_key").empty()) {
    return false;
  }

  const Path data(datadir_);
  const Path ca_key = data.join(kCaKeyFileName);
  const Path ca_cert = data.join(kCaCertFileName);
  const Path router_key = data.join(kRouterKeyFileName);
  const Path router_cert = data.join(kRouterCertFileName);

  CertificateHandler cert_handler{ca_key, ca_cert, router_key, router_cert};
  if (cert_handler.router_cert_files_exists()) {
    out_stream_ << "- Using the existing TLS certificate in '" << datadir_
                << "'\n";
    return true;
  }
  if (!cert_handler.no_cert_files_exists()) {
    throw std::runtime_error(
        "Incomplete TLS certificate files in '" + datadir_ + "': " +
        kRouterKeyFileName + " and " + kRouterCertFileName +
        " are both needed. Provide them or remove the existing ones.");
  }

  out_stream_ << "- Creating a self-signed TLS certificate for the HTTPS "
                 "server\n";
  for (const auto &file : {ca_key, ca_cert, router_key, router_cert}) {
    auto_cleaner_.add_file_delete(file.str());
  }
  const auto res = cert_handler.create();
  if (!res) {
    throw std::runtime_error("Creating the TLS certificate failed: " +
                             res.error().message());
  }
  for (const auto &file : {ca_key, ca_cert, router_key, router_cert}) {
    make_private(file.str(), false);
  }
  return true;
}

void MrsdSetup::store_secrets_in_keyring(uint64_t router_id) {
  while (jwt_secret_.empty()) {
    out_stream_
        << "\nPlease enter a secret for signing JSON Web Tokens (JWT).\n"
           "All instances serving the same MRS metadata must use the same "
           "secret;\nfor the first instance, enter a new random string.\n";
    jwt_secret_ = mysqlrouter::prompt_password("JWT secret");
    if (jwt_secret_.empty()) {
      out_stream_ << "The JWT secret can't be empty.\n";
    }
  }

  out_stream_ << "- Storing the account password(s) and the JWT secret in "
                 "the keyring\n";

  const auto &keyring_file = keyring_info_.get_keyring_file();
  if (Path(keyring_file).exists()) {
    auto_cleaner_.add_file_revert(keyring_file);
  } else {
    auto_cleaner_.add_file_delete(keyring_file);
  }

  if (keyring_info_.use_master_key_external_facility()) {
    keyring_info_.add_router_id_to_env(static_cast<uint32_t>(router_id));
    if (!keyring_info_.read_master_key()) {
      throw std::runtime_error("Could not read the master key with " +
                               keyring_info_.get_master_key_reader());
    }
    if (keyring_info_.get_master_key().empty()) {
      keyring_info_.generate_master_key();
      if (!keyring_info_.write_master_key()) {
        throw std::runtime_error("Could not store the master key with " +
                                 keyring_info_.get_master_key_writer());
      }
    }
    mysql_harness::init_keyring_with_key(keyring_file,
                                         keyring_info_.get_master_key(), true);
  } else {
    const auto &master_key_file = keyring_info_.get_master_key_file();
    if (Path(master_key_file).exists()) {
      auto_cleaner_.add_file_revert(master_key_file);
    } else {
      auto_cleaner_.add_file_delete(master_key_file);
    }
    try {
      mysql_harness::init_keyring(keyring_file, master_key_file, true);
    } catch (const mysql_harness::invalid_master_keyfile &) {
      throw std::runtime_error("Invalid master key file " + master_key_file);
    }
  }

  auto *keyring = mysql_harness::get_keyring();
  keyring->store("rest-user", "jwt_secret", jwt_secret_);
  keyring->store(metadata_account_.user, kKeyringAttributePassword,
                 metadata_account_.pass);
  if (data_account_.user != metadata_account_.user) {
    keyring->store(data_account_.user, kKeyringAttributePassword,
                   data_account_.pass);
  }

  try {
    mysql_harness::flush_keyring();
  } catch (const std::exception &e) {
    throw std::runtime_error("Storing the keyring failed: "s + e.what());
  }
  mysql_harness::reset_keyring();
}

void MrsdSetup::write_config(uint64_t router_id) {
  out_stream_ << "- Creating configuration " << config_path_ << "\n";

  const std::string tmp_path = config_path_ + ".tmp";
  auto_cleaner_.add_file_delete(tmp_path);
  {
    auto os = open_for_writing(tmp_path);
    const auto &cmdln = config_cmdln_options_;

    os << "# File automatically generated by " MRSD_PROGRAM_NAME " --setup\n";
    {
      mysql_harness::ConfigSectionPrinter section(os, cmdln, "DEFAULT");
      section.add_line("name", name_);
      section.add_line("logging_folder", logdir_);
      section.add_line("runtime_folder", rundir_);
      section.add_line("data_folder", datadir_);
      section.add_line("keyring_path", keyring_info_.get_keyring_file());
      section.add_line("master_key_path", keyring_info_.get_master_key_file());
      section.add_line("master_key_reader",
                       keyring_info_.get_master_key_reader());
      section.add_line("master_key_writer",
                       keyring_info_.get_master_key_writer());
      section.add_line("unknown_config_option", "error");
    }
    {
      mysql_harness::ConfigSectionPrinter section(os, cmdln, "logger");
      section.add_line("level", "info");
    }
    {
      mysql_harness::ConfigSectionPrinter section(os, cmdln, "http_server");
      section.add_line("port", std::to_string(kDefaultSetupHttpPort));
      section.add_line("ssl", "1");
      if (http_ssl()) {
        section.add_line("ssl_cert",
                         Path(datadir_).join(kRouterCertFileName).str());
        section.add_line("ssl_key",
                         Path(datadir_).join(kRouterKeyFileName).str());
      }
    }
    {
      // set by --setup's own options only (the printer keeps a reference)
      const std::map<std::string, std::string> no_overrides;
      mysql_harness::ConfigSectionPrinter section(os, no_overrides,
                                                  kConfigMrsSection);
      section.add_line("mysql_read_write_destinations", mysql_destination());
      for (const auto &[option, value] : ssl_options_) {
        section.add_line(option, value);
      }
      section.add_line("mysql_user", metadata_account_.user);
      if (data_account_.user != metadata_account_.user) {
        section.add_line("mysql_user_data_access", data_account_.user);
      }
      section.add_line("router_id", std::to_string(router_id));
      section.add_line("developer", developer_);
      section.add_line("developer_debug_port", developer_debug_port_);
    }
    mysql_harness::ConfigSectionPrinter::add_remaining_sections(os, cmdln);

    if (!os.flush()) {
      throw std::system_error(std::error_code{errno, std::generic_category()},
                              "Could not write '" + tmp_path + "'");
    }
  }

  const bool overwrite = Path(config_path_).exists();
  if (overwrite) {
    // restored if the setup fails later
    auto_cleaner_.add_file_revert(config_path_);

    const std::string backup = config_path_ + ".bak";
    mysql_harness::copy_file(config_path_, backup);
    make_private(backup, false);
    out_stream_ << "- Existing configuration backed up to " << backup << "\n";
  }

  auto rename_res =
      mysql_harness::rename_file(tmp_path.c_str(), config_path_.c_str());
  if (!rename_res) {
    throw std::system_error(rename_res.error(),
                            "Could not move '" + tmp_path + "' to '" +
                                config_path_ + "'");
  }
  if (!overwrite) auto_cleaner_.add_file_delete(config_path_);
  make_private(config_path_, true);
}

void MrsdSetup::write_scripts() {
  const std::string pid_file = Path(rundir_).join(kPidFileName).str();

#ifdef _WIN32
  {
    const std::string script = Path(directory_).join("start.ps1").str();
    auto_cleaner_.add_file_delete(script);
    auto os = open_for_writing(script);
    os << "[Environment]::SetEnvironmentVariable(\"ROUTER_PID\", \""
       << pid_file << "\", \"Process\")\n"
       << "Start-Process \"" << program_path_ << "\" -ArgumentList \"-c\", '\""
       << config_path_ << "\"' -NoNewWindow\n";
  }
  {
    const std::string script = Path(directory_).join("stop.ps1").str();
    auto_cleaner_.add_file_delete(script);
    auto os = open_for_writing(script);
    os << "$filename = \"" << pid_file << "\"\n"
       << "If (Test-Path $filename) {\n"
       << "  $mypid = [IO.File]::ReadAllText($filename)\n"
       << "  Stop-Process -Id $mypid\n"
       << "  [IO.File]::Delete($filename)\n"
       << "} else { Write-Host \"" MRSD_PROGRAM_NAME " is not running\" }\n";
  }
#else
  const auto write_script = [this](const std::string &name,
                                   const std::string &body) {
    const std::string script = Path(directory_).join(name).str();
    auto_cleaner_.add_file_delete(script);
    {
      auto os = open_for_writing(script);
      os << "#!/bin/sh\n" << body;
    }
    if (::chmod(script.c_str(), S_IRWXU) != 0) {
      throw std::system_error(std::error_code{errno, std::generic_category()},
                              "Could not make '" + script + "' executable");
    }
  };

  write_script("start.sh", "ROUTER_PID='" + pid_file + "' '" + program_path_ +
                               "' -c '" + config_path_ + "' &\n");
  write_script("stop.sh", "if [ -f '" + pid_file + "' ]; then\n  kill -TERM " +
                              "\"$(cat '" + pid_file + "')\" && rm -f '" +
                              pid_file + "'\nfi\n");
#endif
}

void MrsdSetup::print_report() const {
  const std::string url = std::string(http_ssl() ? "https" : "http") + "://" +
                          (report_host_.empty() ? "localhost" : report_host_) +
                          ":" + std::to_string(http_port()) + "/<service>";

  out_stream_ << "\n"
              << Vt100::foreground(Vt100::Color::Green) << "# "
              << MRSD_PROGRAM_NAME << " '" << router_name()
              << "' configured for the MySQL server at '"
              << mysql_destination() << "'"
              << Vt100::render(Vt100::Render::ForegroundDefault) << "\n\n"
              << "Start it with\n\n"
              << "    " << Path(directory_).join(IF_WIN("start.ps1", "start.sh")).str()
              << "\n\nor\n\n"
              << "    " << program_path_ << " -c " << config_path_ << "\n\n"
              << "The MySQL REST Service can then be reached at\n\n"
              << "    " << url << "\n";
}

void MrsdSetup::run() {
  if (showing_info_) return;

  // keeps the progress lines in order with the error messages on stderr
  out_stream_ << std::unitbuf;

  out_stream_ << Vt100::foreground(Vt100::Color::Yellow) << "# Setting up "
              << MRSD_PROGRAM_NAME << " in '" << directory_ << "'"
              << Vt100::render(Vt100::Render::ForegroundDefault) << "\n\n";

  connect();

  out_stream_ << "- Checking the MRS metadata\n";
  check_mrs_metadata();

  prepare_directory();

  out_stream_ << "- Registering the instance in the MRS metadata\n";
  const auto router_id = register_instance();
  store_developer(router_id);

  out_stream_ << "- Creating the MRS account(s) if needed\n";
  create_accounts(router_id);

  prepare_tls_certificates();
  store_secrets_in_keyring(router_id);
  write_config(router_id);
  write_scripts();

  // success: keep what was created
  auto_cleaner_.clear();
  accounts_cleaner_.clear();

  print_report();
}
