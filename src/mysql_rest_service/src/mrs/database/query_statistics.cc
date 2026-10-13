/*
  Copyright (c) 2023, 2026, Oracle and/or its affiliates.
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

#include "mrs/database/query_statistics.h"
#include "mrs/database/metadata_schema.h"

#include <vector>

#include "helper/json/serializer_to_text.h"
#include "mrs/router_observation_entities.h"

#include "mysql/harness/utility/container/generic.h"

namespace mrs {
namespace database {

void QueryStatistics::update_statistics(MySQLSession *session,
                                        const std::string &rest_daemon_id,
                                        uint64_t timespan,
                                        const Snapshot &snap) {
  query_.reset(
      metadata_sql("INSERT INTO "
      "mariadb_rest_service.rest_daemon_status("
      "rest_daemon_id, timespan, mariadb_connections, mariadb_queries, "
      "http_requests_get, "
      "http_requests_post, "
      "http_requests_put, http_requests_delete, active_mariadb_connections, "
      "details) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").c_str());

  std::vector<uint32_t> direct_ids{
      kEntityCounterMySQLConnectionsCreated, kEntityCounterMySQLQueries,
      kEntityCounterHttpRequestGet,          kEntityCounterHttpRequestPost,
      kEntityCounterHttpRequestPut,          kEntityCounterHttpRequestDelete,
      kEntityCounterMySQLConnectionsActive};

  helper::json::SerializerToText stt;
  {
    auto obj = stt.add_object();
    for (size_t i = 0; i < snap.size(); ++i) {
      if (mysql_harness::utility::container::has(direct_ids, i)) continue;
      if (snap[i].first.empty()) continue;

      obj->member_add_value(snap[i].first, snap[i].second);
    }
  }

  query_ << rest_daemon_id << timespan;
  for (auto id : direct_ids) {
    query_ << snap[id].second;
  }

  query_ << stt.get_result();
  execute(session);
}

}  // namespace database
}  // namespace mrs
