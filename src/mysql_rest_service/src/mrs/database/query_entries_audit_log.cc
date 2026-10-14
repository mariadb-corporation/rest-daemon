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

#include "mysql/harness/utility/string.h"
#include "mrs/database/metadata_schema.h"

#include "helper/mysql_row.h"
#include "mrs/database/query_entries_audit_log.h"

namespace mrs {
namespace database {

uint64_t QueryAuditLogEntries::query_entries(
    MySQLSession *session, const std::vector<std::string> &allowed_tables,
    const uint64_t audit_log_id) {
  entries.clear();
  max_id_ = audit_log_id;
  fetch_entries_ = true;
  build_query(allowed_tables, audit_log_id, false);
  execute(session);

  // forget the ids that dropped out of the window: no row older than its
  // start is read again (`changed_at` text compares in time order)
  if (!window_start_.empty()) {
    for (auto it = returned_.begin(); it != returned_.end();) {
      if (it->second < window_start_)
        it = returned_.erase(it);
      else
        ++it;
    }
  }

  return max_id_;
}

uint64_t QueryAuditLogEntries::count_entries(
    MySQLSession *session, const std::vector<std::string> &allowed_tables,
    const uint64_t audit_log_id) {
  fetch_entries_ = false;
  no_of_entries_ = 0;
  build_query(allowed_tables, audit_log_id, true);
  execute(session);
  return no_of_entries_;
}

void QueryAuditLogEntries::build_query(
    const std::vector<std::string> &allowed_tables, const uint64_t audit_log_id,
    bool count_entries) {
  // restd: not static (upstream kept the first call's column list for all)
  mysqlrouter::sqlstring columns{
      !count_entries ? "id, dml_type, table_name, old_row_id, new_row_id, "
                       "changed_at, NOW(6) - INTERVAL ? SECOND"
                     : "count(*)"};
  if (!count_entries)
    columns << static_cast<uint64_t>(k_overlap_window.count());

  query_ = {metadata_query(
      "SELECT ! FROM mariadb_rest_service.audit_log WHERE table_name in (?) "
      "AND (id > ? OR changed_at >= NOW(6) - INTERVAL ? SECOND) ORDER BY id")};

  query_ << columns;
  query_ << allowed_tables;
  query_ << audit_log_id;
  query_ << static_cast<uint64_t>(k_overlap_window.count());
}

void QueryAuditLogEntries::on_row(const ResultRow &row) {
  if (!fetch_entries_) {
    on_row_count(row);
    return;
  }
  on_row_entries(row);
}

void QueryAuditLogEntries::on_row_count(const ResultRow &row) {
  no_of_entries_ = atoi(row[0]);
}

void QueryAuditLogEntries::on_row_entries(const ResultRow &row) {
  entry::AuditLog entry;
  std::string changed_at;

  helper::MySQLRow mysql_row(row, metadata_, num_of_metadata_);
  mysql_row.unserialize(&entry.id);
  mysql_row.unserialize(&entry.op);
  mysql_row.unserialize(&entry.table);
  mysql_row.unserialize(&entry.old_table_id);
  mysql_row.unserialize(&entry.new_table_id);
  mysql_row.unserialize(&changed_at);
  mysql_row.unserialize(&window_start_);

  if (max_id_ < entry.id) {
    max_id_ = entry.id;
  }

  // within the overlap window: once only
  if (!returned_.emplace(entry.id, changed_at).second) return;

  entries.push_back(std::move(entry));
}

}  // namespace database
}  // namespace mrs
