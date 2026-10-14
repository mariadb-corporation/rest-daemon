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

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "mock/mock_session.h"
#include "mrs/database/query_entries_audit_log.h"

using namespace testing;
using mrs::database::QueryAuditLogEntries;
using mysqlrouter::MySQLSession;
using FieldValidator = MySQLSession::FieldValidator;
using RowProcessor = MySQLSession::RowProcessor;
using Row = MySQLSession::Row;

namespace {

// id, dml_type, table_name, old_row_id, new_row_id, changed_at, window start
Row audit_row(const char *id, const char *changed_at,
              const char *window_start) {
  return {id, "UPDATE", "rest_object", nullptr, nullptr, changed_at,
          window_start};
}

std::vector<uint64_t> ids_of(const QueryAuditLogEntries &q) {
  std::vector<uint64_t> result;
  for (const auto &e : q.entries) result.push_back(e.id);
  return result;
}

}  // namespace

class AuditLogWindowTest : public Test {
 public:
  // the next query on the audit log returns `rows`
  void expect_poll(const std::string &where, std::vector<Row> rows) {
    EXPECT_CALL(session_, query(HasSubstr(where), _, _))
        .WillOnce(Invoke([rows](Unused, const RowProcessor &rp,
                                const FieldValidator &fv) {
          fv(7, nullptr);
          for (const auto &r : rows) rp(r);
        }))
        .RetiresOnSaturation();
  }

  StrictMock<MockMySQLSession> session_;
  QueryAuditLogEntries sut_;
};

// a row that commits after a higher id was read (Galera, concurrent writers)
// is returned by the next poll; rows already returned are not returned again
TEST_F(AuditLogWindowTest, late_commit_with_lower_id_is_returned_once) {
  const char *w1 = "2026-10-14 10:00:00.000000";

  expect_poll("(id > 4 OR changed_at >= NOW(6) - INTERVAL 60 SECOND)",
              {audit_row("5", "2026-10-14 10:00:01.000000", w1),
               audit_row("7", "2026-10-14 10:00:02.000000", w1)});
  EXPECT_EQ(7, sut_.query_entries(&session_, {"rest_object"}, 4));
  EXPECT_THAT(ids_of(sut_), ElementsAre(5, 7));

  // id 6 was assigned before 7 but became visible only now
  expect_poll("(id > 7 OR",
              {audit_row("5", "2026-10-14 10:00:01.000000", w1),
               audit_row("6", "2026-10-14 10:00:01.500000", w1),
               audit_row("7", "2026-10-14 10:00:02.000000", w1),
               audit_row("8", "2026-10-14 10:00:03.000000", w1)});
  EXPECT_EQ(8, sut_.query_entries(&session_, {"rest_object"}, 7));
  EXPECT_THAT(ids_of(sut_), ElementsAre(6, 8));

  // nothing new
  expect_poll("(id > 8 OR",
              {audit_row("6", "2026-10-14 10:00:01.500000", w1),
               audit_row("8", "2026-10-14 10:00:03.000000", w1)});
  EXPECT_EQ(8, sut_.query_entries(&session_, {"rest_object"}, 8));
  EXPECT_THAT(ids_of(sut_), IsEmpty());
}

// ids older than the window are forgotten (the server no longer returns them)
TEST_F(AuditLogWindowTest, ids_out_of_the_window_are_forgotten) {
  expect_poll("(id > 0 OR",
              {audit_row("1", "2026-10-14 10:00:01.000000",
                         "2026-10-14 10:00:00.000000")});
  EXPECT_EQ(1, sut_.query_entries(&session_, {"rest_object"}, 0));
  EXPECT_THAT(ids_of(sut_), ElementsAre(1));

  // a minute later: id 1 is out of the window and forgotten
  expect_poll("(id > 1 OR",
              {audit_row("2", "2026-10-14 10:01:05.000000",
                         "2026-10-14 10:00:05.000000")});
  EXPECT_EQ(2, sut_.query_entries(&session_, {"rest_object"}, 1));
  EXPECT_THAT(ids_of(sut_), ElementsAre(2));

  // were id 1 read again (it can't: the window no longer reaches it), it
  // would count as new, which shows that it was forgotten
  expect_poll("(id > 2 OR",
              {audit_row("1", "2026-10-14 10:00:01.000000",
                         "2026-10-14 10:00:06.000000")});
  sut_.query_entries(&session_, {"rest_object"}, 2);
  EXPECT_THAT(ids_of(sut_), ElementsAre(1));
}

// count_entries and query_entries use their own column lists (upstream kept
// the first call's list in a static)
TEST_F(AuditLogWindowTest, count_and_entries_use_their_own_columns) {
  EXPECT_CALL(session_, query(StartsWith("SELECT count(*) FROM"), _, _))
      .WillOnce(Invoke([](Unused, const RowProcessor &rp,
                          const FieldValidator &fv) {
        fv(1, nullptr);
        rp({"3"});
      }));
  EXPECT_EQ(3, sut_.count_entries(&session_, {"rest_object"}, 0));

  expect_poll("SELECT id, dml_type, table_name", {});
  sut_.query_entries(&session_, {"rest_object"}, 0);
}
