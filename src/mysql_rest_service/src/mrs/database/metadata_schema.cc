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

#include "mrs/database/metadata_schema.h"

#include <cctype>
#include <mutex>
#include <stdexcept>

namespace mrs {
namespace database {

namespace {

bool is_word(unsigned char c) { return std::isalnum(c) || c == '_'; }

std::string g_schema{kMetadataSchemaBaseName};
MetadataSchemaName g_parts;
std::mutex g_mutex;

}  // namespace

MetadataSchemaName parse_metadata_schema_name(std::string_view name) {
  if (name.empty()) throw std::invalid_argument("the schema name is empty");
  if (name.size() > 64)
    throw std::invalid_argument("the schema name is longer than 64 characters");
  const auto pos = name.find(kMetadataSchemaBaseName);
  if (pos == std::string_view::npos)
    throw std::invalid_argument("the schema name does not contain '" +
                                std::string(kMetadataSchemaBaseName) + "'");
  if (name.find(kMetadataSchemaBaseName, pos + 1) != std::string_view::npos)
    throw std::invalid_argument("the schema name contains '" +
                                std::string(kMetadataSchemaBaseName) +
                                "' more than once");
  MetadataSchemaName result;
  result.prefix = std::string(name.substr(0, pos));
  result.postfix = std::string(name.substr(pos + kMetadataSchemaBaseName.size()));
  for (unsigned char c : result.prefix + result.postfix) {
    if (!is_word(c))
      throw std::invalid_argument(
          "the schema name's prefix and postfix may only contain letters, "
          "digits and '_'");
  }
  if (!result.prefix.empty() && std::isdigit((unsigned char)result.prefix[0]))
    throw std::invalid_argument(
        "the schema name's prefix must start with a letter or '_'");
  if (!result.postfix.empty() && result.postfix[0] != '_')
    throw std::invalid_argument("the schema name's postfix must start with '_'");
  return result;
}

const std::string &metadata_schema() { return g_schema; }

void set_metadata_schema(std::string_view name) {
  auto parts = parse_metadata_schema_name(name);
  std::lock_guard lock(g_mutex);
  g_schema = std::string(name);
  g_parts = std::move(parts);
}

std::string metadata_role(std::string_view role) {
  return g_parts.prefix + std::string(kMetadataRoleBaseName) + "_" +
         std::string(role) + g_parts.postfix;
}

std::string metadata_sql(std::string_view fmt) {
  if (g_schema == kMetadataSchemaBaseName) return std::string(fmt);
  std::string out;
  out.reserve(fmt.size() + 32);
  size_t pos = 0;
  while (true) {
    const auto hit = fmt.find(kMetadataSchemaBaseName, pos);
    if (hit == std::string_view::npos) {
      out.append(fmt.substr(pos));
      return out;
    }
    const auto end = hit + kMetadataSchemaBaseName.size();
    // a whole word only (the base name is not a prefix of a longer identifier)
    const bool word_before = hit > 0 && is_word((unsigned char)fmt[hit - 1]);
    const bool word_after = end < fmt.size() && is_word((unsigned char)fmt[end]);
    out.append(fmt.substr(pos, hit - pos));
    out.append(word_before || word_after ? std::string(kMetadataSchemaBaseName)
                                         : g_schema);
    pos = end;
  }
}

mysqlrouter::sqlstring metadata_query(std::string_view fmt) {
  return mysqlrouter::sqlstring(metadata_sql(fmt).c_str());
}

}  // namespace database
}  // namespace mrs
