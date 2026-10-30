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

#include "mrs/database/query_changes_db_object.h"
#include "mrs/database/metadata_schema.h"

#include <utility>

#include "helper/mysql_row.h"

#include "mrs/database/query_entries_audit_log.h"
#include "mrs/database/query_entry_fields.h"
#include "mrs/database/query_entry_group_row_security.h"
#include "mrs/database/query_entry_object.h"

#include "mysql/harness/logging/logging.h"

IMPORT_LOG_FUNCTIONS()

namespace mrs {
namespace database {

const std::string kDbObjectTableName = "rest_object";
const std::string kObjTableName = "data_mapping";
const std::string kObjRefTableName = "data_mapping_reference";
const std::string kObjFieldTableName = "data_mapping_field";

QueryChangesDbObject::QueryChangesDbObject(QueryFactory *query_factory,
                                           const uint64_t last_audit_id)
    : QueryEntriesDbObject(query_factory) {
  audit_log_id_ = last_audit_id;
  query_length_ = query_.str().length();
}

void QueryChangesDbObject::query_entries(MySQLSession *session) {
  path_entries_fetched.clear();

  std::vector<DbObject> local_path_entries;
  uint64_t max_audit_log_id = audit_log_id_;
  audit_entries_.query_entries(
      session,
      {kDbObjectTableName, kObjTableName, kObjRefTableName, kObjFieldTableName},
      audit_log_id_);

  for (const auto &audit_entry : audit_entries_.entries) {
    if (audit_entry.old_table_id.has_value())
      query_path_entries(session, &local_path_entries, audit_entry.table,
                         audit_entry.old_table_id.value());

    if (audit_entry.new_table_id.has_value())
      query_path_entries(session, &local_path_entries, audit_entry.table,
                         audit_entry.new_table_id.value());

    if (max_audit_log_id < audit_entry.id) max_audit_log_id = audit_entry.id;
  }

  auto qgroup = query_factory_->create_query_group_row_security();
  auto qfields = query_factory_->create_query_fields();
  auto qobject = query_factory_->create_query_object();

  for (auto &e : local_path_entries) {
    qgroup->query_group_row_security(session, e.id);
    e.row_group_security = std::move(qgroup->get_result());
    qfields->query_parameters(session, e.id);
    auto &r = qfields->get_result();
    e.fields = std::move(r);

    qobject->query_entries(session, skip_starting_slash(e.schema_name),
                           skip_starting_slash(e.name), e.id);
    e.object_description = qobject->object;

  }

  entries_.swap(local_path_entries);

  audit_log_id_ = max_audit_log_id;
}

void QueryChangesDbObject::query_path_entries(
    MySQLSession *session, std::vector<DbObject> *out,
    const std::string &table_name, const entry::UniversalId &id) {
  entries_.clear();

  query(session, build_query(table_name, id));

  for (const auto &entry : entries_) {
    if (path_entries_fetched.count(entry.id)) continue;

    out->push_back(entry);
    path_entries_fetched.insert(entry.id);
  }

  if (entries_.empty() && table_name == kDbObjectTableName) {
    DbObject pe;
    pe.id = id;
    pe.deleted = true;
    path_entries_fetched.insert(id);
    out->push_back(pe);
  }
}

std::string QueryChangesDbObject::build_query(const std::string &table_name,
                                              const entry::UniversalId &id) {
  mysqlrouter::sqlstring query = query_;

  if (kObjTableName == table_name) {
    mysqlrouter::sqlstring where =
        metadata_query(" WHERE rest_object_id in (select rest_object_id from "
        "mariadb_rest_service.data_mapping as f where f.id=? GROUP BY "
        "rest_object_id)");
    where << id;
    return query.str() + where.str();
  } else if (kObjRefTableName == table_name) {
    mysqlrouter::sqlstring where =
        metadata_query(" WHERE rest_object_id in (SELECT o.rest_object_id FROM "
        "mariadb_rest_service.data_mapping_field AS f JOIN "
        "mariadb_rest_service.data_mapping AS o ON o.id=f.data_mapping_id WHERE "
        "(f.parent_reference_id=? or f.represents_reference_id=?) GROUP BY "
        "rest_object_id)");
    where << id << id;
    return query.str() + where.str();
  } else if (kObjFieldTableName == table_name) {
    mysqlrouter::sqlstring where =
        metadata_query(" WHERE rest_object_id in (SELECT o.rest_object_id FROM "
        "mariadb_rest_service.data_mapping_field AS f  JOIN "
        "mariadb_rest_service.data_mapping AS o ON o.id=f.data_mapping_id WHERE "
        "f.id=? GROUP BY rest_object_id)");
    where << id;
    return query.str() + where.str();
  }

  mysqlrouter::sqlstring where = " WHERE !=? ";
  where << (table_name + "_id") << id;

  return query.str() + where.str();
}

}  // namespace database
}  // namespace mrs
