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

// restd: the configurable metadata schema name

#include <gtest/gtest.h>

#include "mrs/database/metadata_schema.h"

using namespace mrs::database;

namespace {
const std::string k_base{kMetadataSchemaBaseName};

struct ResetSchema {
  ~ResetSchema() { set_metadata_schema(k_base); }
};
}  // namespace

TEST(MetadataSchema, parse_base_name) {
  auto n = parse_metadata_schema_name(k_base);
  EXPECT_EQ("", n.prefix);
  EXPECT_EQ("", n.postfix);
}

TEST(MetadataSchema, parse_prefix_and_postfix) {
  auto n = parse_metadata_schema_name("acme_" + k_base + "_eu");
  EXPECT_EQ("acme_", n.prefix);
  EXPECT_EQ("_eu", n.postfix);
  n = parse_metadata_schema_name("_" + k_base);
  EXPECT_EQ("_", n.prefix);
}

TEST(MetadataSchema, parse_rejects) {
  EXPECT_THROW(parse_metadata_schema_name(""), std::invalid_argument);
  EXPECT_THROW(parse_metadata_schema_name("rest"), std::invalid_argument);
  EXPECT_THROW(parse_metadata_schema_name(k_base + k_base),
               std::invalid_argument);
  EXPECT_THROW(parse_metadata_schema_name("1" + k_base), std::invalid_argument);
  EXPECT_THROW(parse_metadata_schema_name(k_base + "eu"), std::invalid_argument);
  EXPECT_THROW(parse_metadata_schema_name("a-b_" + k_base),
               std::invalid_argument);
  EXPECT_THROW(parse_metadata_schema_name(std::string(60, 'x') + "_" + k_base),
               std::invalid_argument);
}

TEST(MetadataSchema, roles_and_sql_follow_the_name) {
  ResetSchema reset;
  EXPECT_EQ(std::string(kMetadataRoleBaseName) + "_meta_provider",
            metadata_role("meta_provider"));
  EXPECT_EQ("SELECT 1 FROM " + k_base + ".config",
            metadata_sql("SELECT 1 FROM " + k_base + ".config"));

  set_metadata_schema("acme_" + k_base + "_eu");
  EXPECT_EQ("acme_" + k_base + "_eu", metadata_schema());
  EXPECT_EQ("acme_" + std::string(kMetadataRoleBaseName) + "_data_provider_eu",
            metadata_role("data_provider"));
  EXPECT_EQ("SELECT 1 FROM acme_" + k_base + "_eu.config, acme_" + k_base +
                "_eu.`router`",
            metadata_sql("SELECT 1 FROM " + k_base + ".config, " + k_base +
                         ".`router`"));
  // not inside a longer identifier
  EXPECT_EQ("SELECT " + k_base + "_x", metadata_sql("SELECT " + k_base + "_x"));
  EXPECT_EQ("SELECT ?", metadata_query("SELECT ?").str().substr(0, 8));
}
