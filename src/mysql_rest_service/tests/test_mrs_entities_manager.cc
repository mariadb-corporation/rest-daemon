/*  Copyright (c) 2025, 2026, Oracle and/or its affiliates.
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

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "mrs/database/query_statistics.h"
#include "mrs/observability/entities_manager.h"
#include "mrs/router_observation_entities.h"

static uint64_t get_counter(mrs::observability::EntitiesManager *em,
                            const std::string &name) {
  auto c = em->fetch_counters();
  for (const auto &[k, v] : c) {
    if (k == name) return v;
  }

  throw std::logic_error("Item not found");
}

static void assertEntities(mrs::observability::EntitiesManager *em) {
  mrs::initialize_entities(em);
  mrs::Counter<kEntityCounterMySQLConnectionsClosed>::increment();
}

TEST(EntitiesManager, call_multiple_times) {
  mrs::observability::EntitiesManager em1;
  ASSERT_NO_FATAL_FAILURE(assertEntities(&em1));

  mrs::observability::EntitiesManager em2;
  ASSERT_NO_FATAL_FAILURE(assertEntities(&em2));
  ASSERT_EQ(1, get_counter(&em2, "mariadbConnectionsClosed"));
}

// restd: the statusVariables list published in rest_daemon.attributes has the
// format and the entries of metadata 5.0.0's fallback list
// (rest_daemon_status_do_cleanup()'s old_status_variables)
TEST(EntitiesManager, status_variables) {
  mrs::observability::EntitiesManager em;
  mrs::initialize_entities(&em);

  const auto json = mrs::database::QueryStatistics::status_variables(em);

  EXPECT_THAT(json, ::testing::StartsWith(
                        "[{\"name\":\"httpRequestGet\",\"column\":"
                        "\"http_requests_get\"},"));
  EXPECT_THAT(json, ::testing::HasSubstr(
                        "{\"name\":\"mariadbConnectionsCreated\",\"column\":"
                        "\"mariadb_connections\"}"));
  EXPECT_THAT(json, ::testing::HasSubstr(
                        "{\"name\":\"mariadbConnectionsActive\",\"column\":"
                        "\"active_mariadb_connections\",\"nonResettable\":true}"));
  EXPECT_THAT(json, ::testing::HasSubstr(
                        "{\"name\":\"mariadbQueries\",\"column\":"
                        "\"mariadb_queries\"}"));
  EXPECT_THAT(json, ::testing::HasSubstr(
                        "{\"name\":\"restCachedItems\",\"nonResettable\":true}"));
  EXPECT_THAT(json, ::testing::HasSubstr(
                        "{\"name\":\"changesAuthentications\",\"nonResettable\":true}"));
  EXPECT_THAT(json, ::testing::HasSubstr("{\"name\":\"mariadbRemoveStmt\"}"));
  EXPECT_THAT(json, ::testing::EndsWith("{\"name\":\"sqlQueryTimeouts\"}]"));
  EXPECT_THAT(json, ::testing::Not(::testing::HasSubstr("mysql")));
}
