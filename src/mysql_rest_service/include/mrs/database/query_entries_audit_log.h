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

#ifndef ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_QUERY_AUDIT_LOG_ENTRIES_H_
#define ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_QUERY_AUDIT_LOG_ENTRIES_H_

#include <chrono>
#include <map>
#include <string>
#include <vector>

#include "mrs/database/entry/audit_log.h"
#include "mrs/database/helper/query.h"

namespace mrs {
namespace database {

// restd: Galera-safe polling. audit_log ids are AUTO_INCREMENT values taken
// when the trigger inserts the row, not at commit: with concurrent writers,
// and on a Galera cluster with several write nodes, a row with a lower id can
// become visible after a higher one. A poll therefore also re-reads the rows
// changed within an overlap window (by `changed_at`, on the server's clock)
// and skips the ids it has already returned. Keep one instance per monitor
// (the ids returned so far are its state). Upstream read `id > <last id>` only.
class QueryAuditLogEntries : private Query {
 public:
  using VectorOfAuditEntries = std::vector<entry::AuditLog>;

  // covers a transaction's duration, the replication delay and the clock skew
  // between the nodes
  static constexpr std::chrono::seconds k_overlap_window{60};

 public:
  // the entries after audit_log_id, plus the ones within the overlap window
  // not returned by an earlier call; returns the highest id seen
  virtual uint64_t query_entries(MySQLSession *session,
                                 const std::vector<std::string> &allowed_tables,
                                 const uint64_t audit_log_id);
  virtual uint64_t count_entries(MySQLSession *session,
                                 const std::vector<std::string> &allowed_tables,
                                 const uint64_t audit_log_id);
  VectorOfAuditEntries entries;

 private:
  void build_query(const std::vector<std::string> &allowed_tables,
                   const uint64_t audit_log_id, bool count_entries);
  void on_row(const ResultRow &r) override;
  void on_row_entries(const ResultRow &r);
  void on_row_count(const ResultRow &r);

  bool fetch_entries_;
  uint64_t max_id_;
  uint64_t no_of_entries_;
  // ids returned within the overlap window -> their changed_at (server text)
  std::map<uint64_t, std::string> returned_;
  std::string window_start_;
};

}  // namespace database
}  // namespace mrs

#endif  // ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_QUERY_AUDIT_LOG_ENTRIES_H_
