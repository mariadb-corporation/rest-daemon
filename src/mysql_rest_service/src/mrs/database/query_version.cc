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

#include <array>
#include <stdexcept>

#include "mrs/database/query_version.h"
#include "mrs/database/metadata_schema.h"

#include "mysqld_error.h"
#include "router_config.h"

namespace mrs {
namespace database {

static void throw_invalid_function_result() {
  throw std::runtime_error(
      metadata_sql("View `mariadb_rest_service`.`msm_schema_version` returned "
      "invalid data."));
}

MrsSchemaVersion QueryVersion::query_version(MySQLSession *session) {
  // restd: only the msm view (upstream tried `schema_version`, the name of
  // versions before 4.0, first)
  query(session,
        metadata_sql("SELECT `major`,`minor`,`patch` FROM "
        "mariadb_rest_service.msm_schema_version;"));
  return v_;
}

std::string unsupported_metadata_version_message(
    const MrsSchemaVersion &version) {
  const auto supported = std::to_string(kCurrentMrsMetadataVersion.major) +
                         "." + std::to_string(kCurrentMrsMetadataVersion.minor) +
                         ".x";
  const auto daemon =
      std::string(MRSD_PROGRAM_NAME) + " " + MYSQL_ROUTER_VERSION;
  if (kCurrentMrsMetadataVersion < version)
    return "The REST metadata schema version " + version.str() +
           " is newer than " + daemon + " supports (" + supported +
           "): upgrade " + MRSD_PROGRAM_NAME;
  return "The REST metadata schema version " + version.str() +
         " is not supported: " + daemon + " needs version " + supported +
         " (deploy it with MariaDB Shell's CONFIGURE REST METADATA)";
}

void QueryVersion::on_metadata(unsigned number, MYSQL_FIELD *) {
  if (3 != number) throw_invalid_function_result();
}

void QueryVersion::on_row(const ResultRow &r) {
  if (r.size() != 3) throw_invalid_function_result();
  v_.major = std::stoi(r[0]);
  v_.minor = std::stoi(r[1]);
  v_.patch = std::stoi(r[2]);
}

}  // namespace database
}  // namespace mrs
