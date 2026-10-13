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

#include <array>
#include <stdexcept>

#include "mrs/database/query_uuid.h"
#include "mrs/database/metadata_schema.h"

namespace mrs {
namespace database {

using UserId = QueryUuid::UserId;

QueryUuid::QueryUuid() {
  query_ = metadata_query("SELECT `mysql_rest_service_metadata`.`get_sequence_id`();");
}

void QueryUuid::generate_uuid(MySQLSession *session) { execute(session); }

UserId QueryUuid::get_result() {
  UserId result;
  result.raw = uuid_;
  return result;
}

void QueryUuid::on_metadata(unsigned number, MYSQL_FIELD *) {
  if (1 != number)
    throw std::runtime_error(
        metadata_sql("Function `mysql_rest_service_metadata`.`get_sequence_id`, returned "
        "invalid data."));
}

void QueryUuid::on_row(const ResultRow &r) {
  // restd: 16 raw bytes (schema 4) or the text of a `UUID` (schema 5)
  const auto id = r[0] ? UserId::from_cstr(r[0], r.get_data_size(0)) : UserId{};
  if (id.empty()) throw std::runtime_error("Generated UUID has invalid size.");
  uuid_ = id.raw;
}

}  // namespace database
}  // namespace mrs
