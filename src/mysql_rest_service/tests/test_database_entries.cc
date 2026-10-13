/*
  Copyright (c) 2022, 2026, Oracle and/or its affiliates.
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

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include <vector>

#include "helper/mysql_row.h"
#include "helper/string/hex.h"
#include "mrs/authentication/helper/universal_id_container.h"
#include "mrs/database/entry/entry.h"
#include "mrs/database/entry/universal_id.h"
#include "mrs/database/query_rest_table.h"

#include "mock/mock_session.h"

using testing::Test;

using namespace mrs::database::entry;
using UserId = AuthUser::UserId;

TEST(AuthUser, to_string) {
  ASSERT_EQ("00000000000000000000000000000000", UserId().to_string());
  ASSERT_EQ("04000000000000000000000000000000", UserId({0x04}).to_string());
  ASSERT_EQ(
      "00000000000000000000000000000004",
      UserId({0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04}).to_string());
}

UniversalId k_id0{0};
UniversalId k_id1{1};
UniversalId k_id2{2};
UniversalId k_id3{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
UniversalId k_id4{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2};
UniversalId k_id5{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3};

TEST(UniversalID, equal) {
  ASSERT_EQ(k_id0, k_id0);
  ASSERT_EQ(k_id1, k_id1);
  ASSERT_EQ(k_id2, k_id2);
  ASSERT_EQ(k_id3, k_id3);
  ASSERT_EQ(k_id4, k_id4);
  ASSERT_EQ(k_id5, k_id5);
}

TEST(UniversalID, not_equal) {
  ASSERT_NE(k_id0, k_id1);
  ASSERT_NE(k_id1, k_id2);
  ASSERT_NE(k_id2, k_id3);
  ASSERT_NE(k_id3, k_id4);
  ASSERT_NE(k_id4, k_id5);

  ASSERT_NE(k_id1, k_id0);
  ASSERT_NE(k_id2, k_id1);
  ASSERT_NE(k_id3, k_id2);
  ASSERT_NE(k_id4, k_id3);
  ASSERT_NE(k_id5, k_id4);
}

TEST(UniversalID, less_equal) {
  EXPECT_LE(k_id0, k_id1);
  EXPECT_LE(k_id0, k_id0);

  EXPECT_LE(k_id1, k_id2);
  EXPECT_LE(k_id2, k_id3);
  EXPECT_LE(k_id3, k_id4);
  EXPECT_LE(k_id4, k_id5);
}

TEST(UniversalID, less) {
  EXPECT_LT(k_id0, k_id1);
  EXPECT_LT(k_id1, k_id2);
  EXPECT_LT(k_id2, k_id3);
  EXPECT_LT(k_id3, k_id4);
  EXPECT_LT(k_id4, k_id5);
}

TEST(UniversalID, greater) {
  EXPECT_GT(k_id1, k_id0);
  EXPECT_GT(k_id2, k_id1);
  EXPECT_GT(k_id3, k_id2);
  EXPECT_GT(k_id4, k_id3);
  EXPECT_GT(k_id5, k_id4);
}

TEST(UniversalID, greater_equal) {
  EXPECT_GE(k_id1, k_id0);
  EXPECT_GE(k_id2, k_id1);
  EXPECT_GE(k_id3, k_id2);
  EXPECT_GE(k_id4, k_id3);
  EXPECT_GE(k_id5, k_id4);
}

TEST(UniversalID, equal_to_string) {
  const auto str1 = k_id3.to_string();
  const auto data = helper::string::unhex<std::vector<uint8_t>>(str1);
  UniversalId from_txt_id = UniversalId::from_cstr(
      reinterpret_cast<const char *>(data.data()), data.size());

  ASSERT_EQ(k_id3, from_txt_id);
}

// restd: ids come as 16 raw bytes (schema 4) or as text (schema 5 `UUID`)
TEST(UniversalID, from_text) {
  const UniversalId expected{0x01, 0x99, 0xa1, 0xb2, 0x6c, 0x3e, 0x7d, 0x41,
                             0x9a, 0x0f, 0x2b, 0x8c, 0x4d, 0x5e, 0x6f, 0x70};
  const std::string dashed = "0199a1b2-6c3e-7d41-9a0f-2b8c4d5e6f70";
  const std::string hex = "0199A1B26C3E7D419A0F2B8C4D5E6F70";

  EXPECT_EQ(expected, UniversalId::from_cstr(dashed.c_str(), dashed.size()));
  EXPECT_EQ(expected, UniversalId::from_cstr(hex.c_str(), hex.size()));
  EXPECT_EQ(expected,
            UniversalId::from_cstr(expected.to_raw(), UniversalId::k_size));
  EXPECT_EQ("0199a1b26c3e7d419a0f2b8c4d5e6f70", expected.to_string());

  // malformed text gives the zero id
  EXPECT_TRUE(UniversalId::from_cstr("0199a1b2-6c3e-7d41-9a0f-2b8c4d5e6f7Z", 36)
                  .empty());
  EXPECT_TRUE(UniversalId::from_cstr("0199a1b26c3e-7d41-9a0f-2b8c4d5e6f70", 36)
                  .empty());
  EXPECT_TRUE(UniversalId::from_cstr("0199a1b2", 8).empty());
}

TEST(UniversalID, mysql_row_by_field_charset) {
  const UniversalId expected{0x01, 0x99, 0xa1, 0xb2, 0x6c, 0x3e, 0x7d, 0x41,
                             0x9a, 0x0f, 0x2b, 0x8c, 0x4d, 0x5e, 0x6f, 0x70};
  const char *text = "0199a1b2-6c3e-7d41-9a0f-2b8c4d5e6f70";
  MYSQL_FIELD fields[2]{};
  fields[0].charsetnr = 224;  // a `UUID` column, utf8mb4
  fields[1].charsetnr = 63;   // a `BINARY(16)` column
  mysqlrouter::MySQLSession::ResultRow row{{text, expected.to_raw()}};

  UniversalId from_uuid, from_binary;
  helper::MySQLRow mysql_row(row, fields, 2);
  mysql_row.unserialize(&from_uuid);
  mysql_row.unserialize(&from_binary);
  EXPECT_EQ(expected, from_uuid);
  EXPECT_EQ(expected, from_binary);

  // without field metadata the value is raw
  mysqlrouter::MySQLSession::ResultRow raw_row{{expected.to_raw(), nullptr}};
  UniversalId from_raw;
  std::optional<UniversalId> from_null;
  helper::MySQLRow raw_mysql_row(raw_row, nullptr, 2);
  raw_mysql_row.unserialize(&from_raw);
  raw_mysql_row.unserialize(&from_null);
  EXPECT_EQ(expected, from_raw);
  EXPECT_FALSE(from_null.has_value());
}

TEST(UniversalID, equal_uuid_converter) {
  using Conv = mrs::authentication::UniversalIdContainer;
  const auto str1 = k_id3.to_string();
  const auto result = helper::string::unhex<Conv>(str1);

  ASSERT_EQ(k_id3, result.get_user_id());
}
