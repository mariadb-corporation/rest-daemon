/*
  Copyright (c) 2025, 2026, Oracle and/or its affiliates.
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

#ifndef MYSQL_REST_SERVICE_SUPPORTED_OPTIONS_INCLUDED
#define MYSQL_REST_SERVICE_SUPPORTED_OPTIONS_INCLUDED

#include <array>

// restd: the options of [mariadb_rest_service]; the server accounts and the
// backend destinations and TLS settings (replacing upstream's
// mysql_read_write_route/mysql_read_only_route) are named without upstream's
// mysql_ prefix. The old names are still accepted (deprecated).
static constexpr std::array mysql_rest_service_supported_options{
    "metadata_user",
    "data_user",
    "read_write_destinations",
    "read_only_destinations",
    "ssl_mode",
    "ssl_ca",
    "ssl_capath",
    "ssl_crl",
    "ssl_crlpath",
    "ssl_curves",
    "ssl_cipher",
    "tls_version",
    // deprecated names, accepted until the next major release
    "mysql_user",
    "mysql_user_data_access",
    "mysql_read_write_destinations",
    "mysql_read_only_destinations",
    "mysql_ssl_mode",
    "mysql_ssl_ca",
    "mysql_ssl_capath",
    "mysql_ssl_crl",
    "mysql_ssl_crlpath",
    "mysql_ssl_curves",
    "mysql_ssl_cipher",
    "mysql_tls_version",
    "rest_daemon_id",
    // restd: the REST metadata schema (<prefix>mariadb_rest_service<postfix>)
    "metadata_schema",
    "metadata_refresh_interval",
    "developer",
    "developer_debug_port",
    "wait_for_metadata_schema_access",
    "level"};

#endif /* MYSQL_REST_SERVICE_SUPPORTED_OPTIONS_INCLUDED */
