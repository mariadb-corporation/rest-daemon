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

#include "mrs/database/query_entries_auth_role.h"
#include "mrs/database/metadata_schema.h"
#include "helper/mysql_row.h"

#include <stdexcept>

namespace mrs {
namespace database {

void QueryEntriesAuthRole::query_role(MySQLSession *session,
                                      const entry::AuthUser::UserId user_id) {
  query_ = {
      metadata_query("SELECT id, caption, derived_from_role_id, specific_to_service_id "
      " FROM mariadb_rest_service.mrs_user_has_role as h "
      " JOIN mariadb_rest_service.mrs_role as r ON r.id=h.role_id "
      " WHERE h.user_id = ?")};

  query_ << to_sqlstring(user_id);
  Query::execute(session);
}

void QueryEntriesAuthRole::on_row(const ResultRow &r) {
  auto &role = result.emplace_back();
  helper::MySQLRow mysql_row(r, metadata_, num_of_metadata_);

  mysql_row.unserialize(&role.id);
  mysql_row.unserialize(&role.caption);
  mysql_row.unserialize(&role.derived_from_role_id);
  mysql_row.unserialize(&role.specific_to_service_id);
}

}  // namespace database
}  // namespace mrs
