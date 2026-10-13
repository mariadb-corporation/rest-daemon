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
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
*/

#ifndef ROUTER_SRC_MYSQL_REST_SERVICE_INCLUDE_MRS_DATABASE_METADATA_SCHEMA_H_
#define ROUTER_SRC_MYSQL_REST_SERVICE_INCLUDE_MRS_DATABASE_METADATA_SCHEMA_H_

#include <string>
#include <string_view>

#include "mysqlrouter/utils_sqlstring.h"

namespace mrs {
namespace database {

// restd: the name of the REST metadata schema is configured (upstream
// hard-coded `mysql_rest_service_metadata` in every statement). A server can
// hold several: `<prefix><base><postfix>`, one per deployment; the roles
// follow the same prefix and postfix. One daemon serves one schema.

// the base name, and the base of the role names (`<base>_meta_provider`, ...)
constexpr std::string_view kMetadataSchemaBaseName = "mysql_rest_service_metadata";
constexpr std::string_view kMetadataRoleBaseName = "mysql_rest_service";

struct MetadataSchemaName {
  std::string prefix;   // empty, or a letter or `_` followed by [A-Za-z0-9_]*
  std::string postfix;  // empty, or `_` followed by [A-Za-z0-9_]*
};

/**
 * Split a schema name into its prefix and postfix around the base name.
 *
 * @throws std::invalid_argument with the reason when the name is not
 *         `<prefix><base><postfix>` (the base exactly once, at most 64
 *         characters, the parts as described above).
 */
MetadataSchemaName parse_metadata_schema_name(std::string_view name);

/** the configured schema name (the base name until one is set) */
const std::string &metadata_schema();

/** set the schema name for this process; validates it (see parse) */
void set_metadata_schema(std::string_view name);

/** `<prefix><role base>_<role><postfix>` for the configured schema */
std::string metadata_role(std::string_view role);

/**
 * A statement for the metadata schema: `fmt` with every occurrence of the
 * base schema name replaced by the configured name. For the format strings
 * the queries are written with (string literals, never user data).
 */
std::string metadata_sql(std::string_view fmt);

/** the same as a sqlstring (its placeholders are bound afterwards) */
mysqlrouter::sqlstring metadata_query(std::string_view fmt);

}  // namespace database
}  // namespace mrs

#endif  // ROUTER_SRC_MYSQL_REST_SERVICE_INCLUDE_MRS_DATABASE_METADATA_SCHEMA_H_
