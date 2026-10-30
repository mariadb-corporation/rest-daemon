/*
  Copyright (c) 2021, 2026, Oracle and/or its affiliates.
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

#include "mrs/database/query_entries_db_object.h"
#include "mrs/database/metadata_schema.h"

#include <map>
#include <string>
#include <utility>

#include "helper/mysql_row.h"
#include "mrs/database/helper/query_audit_log_maxid.h"
#include "mrs/database/query_entry_fields.h"
#include "mrs/database/query_entry_group_row_security.h"
#include "mrs/database/query_entry_object.h"
#include "mysql/harness/logging/logging.h"

IMPORT_LOG_FUNCTIONS()

namespace mrs {
namespace database {

template <typename Map>
auto get_map_converter(Map *map, const typename Map::mapped_type value) {
  return [map, value](auto *out, const char *v) {
    auto e = v ? map->find(v) : map->end();

    if (e != map->end()) {
      *out = e->second;
      return;
    }
    *out = value;
  };
}

QueryEntriesDbObject::QueryEntriesDbObject(
    interface::QueryFactory *query_factory)
    : query_factory_{query_factory} {
  query_ =
      metadata_query("SELECT * FROM (SELECT "
      "  o.id as rest_object_id, db.id as rest_schema_id, o.requires_auth,"
      "  o.auth_stored_procedure, o.enabled, o.request_path,"
      "  COALESCE(o.items_per_page, db.items_per_page) as `on_page`, "
      "  o.name, db.name as `schema_name`, o.crud_operations + 0, o.format,"
      "  o.media_type, o.auto_detect_media_type, o.object_type, o.options !"
      " FROM mariadb_rest_service.`rest_object` as o"
      "  JOIN mariadb_rest_service.`rest_schema` as db on"
      "   o.rest_schema_id = db.id !"
      ") as parent ");

  query_ << mysqlrouter::sqlstring{
      ", o.metadata, cso.content_set_id, cso.priority, cso.language, "
      "cso.class_name, "
      "cso.name as method_name, cso.options as cset_options"};

  query_ << mysqlrouter::sqlstring{
      metadata_query(" LEFT JOIN mariadb_rest_service.`content_set_has_rest_object` as "
      "cso "
      "ON o.id = cso.rest_object_id")};
}

uint64_t QueryEntriesDbObject::get_last_update() { return audit_log_id_; }

void QueryEntriesDbObject::query_entries(MySQLSession *session) {
  entries_.clear();

  QueryAuditLogMaxId query_audit_id;

  auto audit_log_id = query_audit_id.query_max_id(session);
  if (!query_.done()) query_ << mysqlrouter::sqlstring{""};
  execute(session);

  auto qgroup = query_factory_->create_query_group_row_security();
  auto qfields = query_factory_->create_query_fields();
  auto qobject = query_factory_->create_query_object();

  for (auto &e : entries_) {
    qgroup->query_group_row_security(session, e.id);
    e.row_group_security = std::move(qgroup->get_result());

    qfields->query_parameters(session, e.id);
    auto &r = qfields->get_result();
    e.fields = std::move(r);

    qobject->query_entries(session, skip_starting_slash(e.schema_name),
                           skip_starting_slash(e.name), e.id);
    e.object_description = qobject->object;
  }

  audit_log_id_ = audit_log_id;
}

void QueryEntriesDbObject::on_row(const ResultRow &row) {
  entries_.emplace_back();
  auto &entry = entries_.back();

  static std::map<std::string, DbObject::ObjectType> path_types{
      {"TABLE", DbObject::k_objectTypeTable},
      {"PROCEDURE", DbObject::k_objectTypeProcedure},
      {"FUNCTION", DbObject::k_objectTypeFunction},
      {"SCRIPT", DbObject::k_objectTypeScript}};

  static std::map<std::string, DbObject::Format> format_types{
      {"FEED", DbObject::formatFeed},
      {"ITEM", DbObject::formatItem},
      {"MEDIA", DbObject::formatMedia}};

  helper::MySQLRow mysql_row(row, metadata_, num_of_metadata_);

  auto path_type_converter =
      get_map_converter(&path_types, DbObject::k_objectTypeTable);

  auto format_type_converter =
      get_map_converter(&format_types, DbObject::formatFeed);

  mysql_row.unserialize(&entry.id);
  mysql_row.unserialize(&entry.schema_id);
  mysql_row.unserialize(&entry.requires_authentication);
  mysql_row.unserialize(&entry.auth_stored_procedure);
  mysql_row.unserialize(&entry.enabled);
  mysql_row.unserialize(&entry.request_path);
  mysql_row.unserialize(&entry.items_per_page);
  mysql_row.unserialize(&entry.name);
  mysql_row.unserialize(&entry.schema_name);
  mysql_row.unserialize(&entry.crud_operation);
  mysql_row.unserialize_with_converter(&entry.format, format_type_converter);
  mysql_row.unserialize(&entry.media_type);
  mysql_row.unserialize(&entry.autodetect_media_type);
  mysql_row.unserialize_with_converter(&entry.type, path_type_converter);
  mysql_row.unserialize(&entry.options);

  mysql_row.unserialize(&entry.metadata);
  helper::Optional<entry::UniversalId> cset_id;
  mysql_row.unserialize(&cset_id);

  if (cset_id) {
    entry::ContentSetHasObjectDef cset_def;
    cset_def.content_set_id = std::move(*cset_id);
    mysql_row.unserialize(&cset_def.priority);
    mysql_row.unserialize(&cset_def.language);
    mysql_row.unserialize(&cset_def.class_name);
    mysql_row.unserialize(&cset_def.name);
    mysql_row.unserialize(&cset_def.options);
    entry.content_set_def = std::move(cset_def);
  } else {
    mysql_row.skip(5);
  }

  entry.deleted = false;
}

std::string QueryEntriesDbObject::skip_starting_slash(
    const std::string &value) {
  if (value.length()) {
    if (value[0] == '/') return value.substr(1);
  }

  return value;
}

QueryEntriesDbObject::VectorOfPathEntries QueryEntriesDbObject::get_entries()
    const {
  VectorOfPathEntries result;
  for (const auto &e : entries_) {
    result.push_back(e);
  }
  return result;
}

}  // namespace database
}  // namespace mrs
