/*
  Copyright (c) 2021, 2026, Oracle and/or its affiliates.
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License, version 2.0,
  as published by the Free Software Foundation.

  This program is designed to work with certain software (including
  but not limited to OpenSSL) that is licensed under separate terms,
  as designated in a particular file or component or in included license
  documentation.  The authors of MySQL hereby grant you an additional
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

#include <initializer_list>
#include <optional>
#include <stdexcept>

#include "helper/plugin_monitor.h"
#include "mrs/database/metadata_schema.h"
#include "mysql_rest_service_plugin_config.h"

#include "mysql/harness/destination.h"
#include "mysql/harness/logging/logging.h"
#include "mysql/harness/string_utils.h"
#include "mysql/harness/utility/container/generic.h"
#include "mysqlrouter/io_component.h"

IMPORT_LOG_FUNCTIONS()

namespace {

constexpr uint16_t kDefaultMysqlPort{3306};
constexpr std::string_view kLocalPrefix{"local:"};

class DestinationStatic : public collector::DestinationProvider {
 public:
  DestinationStatic(const std::vector<Node> &nodes, const SslConfiguration &ssl)
      : nodes_{nodes}, ssl_{ssl} {}

  std::optional<Node> get_node(const WaitingOp) override {
    // Waiting operation is ignored, the list is static.
    if (nodes_.empty()) return {};

    auto idx = nodes_idx_++ % nodes_.size();
    return nodes_[idx];
  }

  bool is_node_supported(const Node &node) override {
    for (const auto &n : nodes_) {
      if (node == n) return true;
    }

    return false;
  }

  const SslConfiguration &get_ssl_configuration() override { return ssl_; }

  bool is_dynamic() const override { return false; }

 protected:
  std::vector<Node> nodes_;
  uint32_t nodes_idx_{0};
  SslConfiguration ssl_;
};

/**
 * parse a comma-separated list of destinations.
 *
 * - host[:port], ipv4[:port], [ipv6]:port  (port defaults to 3306)
 * - local:/path/to/mysql.sock
 *
 * mrsd replacement for upstream's dependency on the routing plugin, which
 * provided the destinations of the `mysql_read_{write,only}_route` routes.
 */
std::vector<mysql_harness::Destination> parse_destinations(
    std::string_view option_name, const std::string &value) {
  std::vector<mysql_harness::Destination> result;

  for (auto part : mysql_harness::split_string(value, ',', false)) {
    mysql_harness::trim(part);

    if (part.starts_with(kLocalPrefix)) {
      auto path = part.substr(kLocalPrefix.size());
      if (path.empty()) {
        throw std::invalid_argument("empty socket path in option `" +
                                    std::string(option_name) + "`");
      }
      result.emplace_back(mysql_harness::LocalDestination(path));
      continue;
    }

    auto tcp_res = mysql_harness::make_tcp_destination(part);
    if (!tcp_res) {
      throw std::invalid_argument("invalid destination '" + part +
                                  "' in option `" + std::string(option_name) +
                                  "`: " + tcp_res.error().message());
    }
    auto tcp = std::move(*tcp_res);
    if (tcp.port() == 0) tcp.port(kDefaultMysqlPort);

    result.emplace_back(std::move(tcp));
  }

  return result;
}

mysql_ssl_mode parse_ssl_mode(const std::string &value) {
  auto mode = mysql_harness::make_upper(value);

  if (mode.empty() || mode == "PREFERRED") return SSL_MODE_PREFERRED;
  if (mode == "DISABLED") return SSL_MODE_DISABLED;
  if (mode == "REQUIRED") return SSL_MODE_REQUIRED;
  if (mode == "VERIFY_CA") return SSL_MODE_VERIFY_CA;
  if (mode == "VERIFY_IDENTITY") return SSL_MODE_VERIFY_IDENTITY;

  throw std::invalid_argument(
      "invalid value '" + value +
      "' for option `mysql_ssl_mode`, expected one of DISABLED, PREFERRED, "
      "REQUIRED, VERIFY_CA, VERIFY_IDENTITY");
}

std::shared_ptr<collector::DestinationProvider> create_destination(
    const std::string_view option_name, const std::string &destinations,
    const mrs::SslConfiguration &ssl) {
  if (destinations.empty()) return {};

  auto nodes = parse_destinations(option_name, destinations);
  if (nodes.empty()) {
    throw std::invalid_argument("option `" + std::string(option_name) +
                                "` contains no destinations");
  }

  return std::make_shared<DestinationStatic>(nodes, ssl);
}

}  // namespace

namespace mrs {

using namespace std::string_literals;

class UserConfigurationInfo {
 public:
  void operator()(const char *variable) {
    log_error(
        "MySQL Server account: '%s', set in configuration file "
        "must have a password stored in `MySQLRouter's` keyring.",
        variable);
    log_info(
        "Please consult the MRS documentation on: how to configure MySQL "
        "Server accounts for MRS");
  }
};

PluginConfig::PluginConfig(const ConfigSection *section,
                           const std::optional<std::string> &router_name,
                           const uint32_t http_port)
    : mysql_harness::BasePluginConfig(section) {
  static const char *kKeyringAttributePassword = "password";
  mysql_user_ = get_option(section, "mysql_user", StringOption{});
  mysql_user_data_access_ =
      get_option(section, "mysql_user_data_access", StringOption{});
  destinations_rw_ =
      get_option(section, "mysql_read_write_destinations", StringOption{});
  destinations_ro_ =
      get_option(section, "mysql_read_only_destinations", StringOption{});

  destination_ssl_.ssl_mode_ = parse_ssl_mode(
      get_option(section, "mysql_ssl_mode", StringOption{}));
  destination_ssl_.ssl_ca_file_ =
      get_option(section, "mysql_ssl_ca", StringOption{});
  destination_ssl_.ssl_ca_path_ =
      get_option(section, "mysql_ssl_capath", StringOption{});
  destination_ssl_.ssl_crl_file_ =
      get_option(section, "mysql_ssl_crl", StringOption{});
  destination_ssl_.ssl_crl_path_ =
      get_option(section, "mysql_ssl_crlpath", StringOption{});
  destination_ssl_.ssl_curves_ =
      get_option(section, "mysql_ssl_curves", StringOption{});
  destination_ssl_.ssl_ciphers_ =
      get_option(section, "mysql_ssl_cipher", StringOption{});
  destination_ssl_.tls_version_ =
      get_option(section, "mysql_tls_version", StringOption{});
  router_id_ = get_option(section, "router_id", IntOption<uint64_t>{});
  // restd: the metadata schema name, for every statement on the metadata and
  // the role names derived from it
  metadata_schema_ = get_option(section, "metadata_schema", StringOption{});
  try {
    mrs::database::set_metadata_schema(metadata_schema_);
  } catch (const std::invalid_argument &e) {
    throw std::invalid_argument("option `metadata_schema`: "s + e.what());
  }
  metadata_refresh_interval_ =
      get_option(section, k_option_metadata_refresh, MilliSecondsOption{});
  router_name_ = router_name;
  http_port_ = http_port;

  if (mysql_user_data_access_.empty()) {
    mysql_user_data_access_ = mysql_user_;
  }

  if (metadata_refresh_interval_.count() == 0)
    throw std::logic_error(
        "`metadata_refresh_interval` option, must be greater than zero.");

  mysql_user_password_ = get_keyring_value<UserConfigurationInfo>(
      mysql_user_, kKeyringAttributePassword);
  mysql_user_data_access_password_ =
      get_keyring_value(mysql_user_data_access_, kKeyringAttributePassword);
  jwt_secret_ = get_keyring_value("rest-user", "jwt_secret");

  // validate early, so configuration errors are reported during init().
  (void)parse_destinations("mysql_read_write_destinations", destinations_rw_);
  (void)parse_destinations("mysql_read_only_destinations", destinations_ro_);

  wait_for_metadata_schema_access_ =
      get_option(section, "wait_for_metadata_schema_access", SecondsOption{});

  developer_ = get_option(section, "developer", StringOption{});
  developer_debug_port_ =
      get_option(section, "developer_debug_port", StringOption{});
}

bool PluginConfig::init_runtime_configuration() {
  provider_rw_ = create_destination("mysql_read_write_destinations",
                                    destinations_rw_, destination_ssl_);
  provider_ro_ = create_destination("mysql_read_only_destinations",
                                    destinations_ro_, destination_ssl_);

  log_debug("destinations_rw_=%s", destinations_rw_.c_str());
  log_debug("destinations_ro_=%s", destinations_ro_.c_str());

  if (!provider_ro_) provider_ro_ = provider_rw_;

  is_https_ = HttpServerComponent::get_instance().is_ssl_configured();
  auto num_of_io_threads = IoComponent::get_instance().io_threads().size();
  default_mysql_cache_instances_ = num_of_io_threads + 3;
  return true;
}

bool PluginConfig::is_required(std::string_view option) const {
  if (option == "mysql_user") return true;
  if (option == "mysql_read_write_destinations") return true;
  if (option == "router_id") return true;

  return false;
}

std::string PluginConfig::get_default(std::string_view option) const {
  if (option == k_option_metadata_refresh) return "5";
  if (option == "wait_for_metadata_schema_access") return "0";
  if (option == "metadata_schema")
    return std::string(mrs::database::kMetadataSchemaBaseName);

  return {};
}

}  // namespace mrs
