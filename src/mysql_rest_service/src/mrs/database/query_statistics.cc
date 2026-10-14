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

#ifdef RAPIDJSON_NO_SIZETYPEDEFINE
#include "my_rapidjson_size_t.h"
#endif

#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>

#include "helper/json/serializer_to_text.h"
#include "mrs/router_observation_entities.h"


namespace mrs {
namespace database {

namespace {

// restd: the counters stored in their own rest_daemon_status columns, in the
// order of the INSERT below (the others go to `details`, keyed by name)
struct StatusColumn {
  uint32_t id;
  const char *column;
};

constexpr StatusColumn k_status_columns[]{
    {kEntityCounterMySQLConnectionsCreated, "mariadb_connections"},
    {kEntityCounterMySQLQueries, "mariadb_queries"},
    {kEntityCounterHttpRequestGet, "http_requests_get"},
    {kEntityCounterHttpRequestPost, "http_requests_post"},
    {kEntityCounterHttpRequestPut, "http_requests_put"},
    {kEntityCounterHttpRequestDelete, "http_requests_delete"},
    {kEntityCounterMySQLConnectionsActive, "active_mariadb_connections"},
};

const char *status_column(uint32_t id) {
  for (const auto &c : k_status_columns)
    if (c.id == id) return c.column;
  return nullptr;
}

}  // namespace

std::string QueryStatistics::status_variables(
    const observability::EntitiesManager &entities) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  writer.StartArray();
  for (const auto &e : entities.describe()) {
    writer.StartObject();
    writer.Key("name");
    writer.String(e.name.c_str());
    if (const auto column = status_column(e.id)) {
      writer.Key("column");
      writer.String(column);
    }
    if (!e.resettable) {
      writer.Key("nonResettable");
      writer.Bool(true);
    }
    writer.EndObject();
  }
  writer.EndArray();
  return buffer.GetString();
}

void QueryStatistics::update_statistics(MySQLSession *session,
                                        const std::string &rest_daemon_id,
                                        uint64_t timespan,
                                        const Snapshot &snap) {
  std::string columns;
  std::string values;
  for (const auto &c : k_status_columns) {
    columns += std::string(c.column) + ", ";
    values += "?, ";
  }
  query_.reset(metadata_sql("INSERT INTO mariadb_rest_service.rest_daemon_status("
                            "rest_daemon_id, timespan, " +
                            columns + "details) VALUES(?, ?, " + values + "?)")
                   .c_str());

  helper::json::SerializerToText stt;
  {
    auto obj = stt.add_object();
    for (size_t i = 0; i < snap.size(); ++i) {
      if (status_column(static_cast<uint32_t>(i))) continue;
      if (snap[i].first.empty()) continue;

      obj->member_add_value(snap[i].first, snap[i].second);
    }
  }

  query_ << rest_daemon_id << timespan;
  for (const auto &c : k_status_columns) {
    query_ << snap[c.id].second;
  }

  query_ << stt.get_result();
  execute(session);
}

}  // namespace database
}  // namespace mrs
