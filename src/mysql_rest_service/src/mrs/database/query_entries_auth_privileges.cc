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

#include "mrs/database/query_entries_auth_privileges.h"
#include "mrs/database/metadata_schema.h"
#include "helper/mysql_row.h"

namespace mrs {
namespace database {



void QueryEntriesAuthPrivilegesImpl::query_user(
    MySQLSession *session, const entry::AuthUser::UserId &user_id,
    Privileges *out_privileges) {
  privileges_ = out_privileges;
  privileges_->clear();
  query_ =
      metadata_query("SELECT p.service_path, p.schema_path, p.object_path, "
      "BIT_OR(p.crud_operations) as crud FROM "
      "mysql_rest_service_metadata.mrs_privilege as p "
      "  WHERE p.role_id in ( "
      "    WITH recursive cte As "
      "        ( "
      "      SELECT r.id AS id, r.derived_from_role_id FROM "
      "mysql_rest_service_metadata.mrs_role r WHERE "
      "r.id IN (SELECT role_id FROM "
      "mysql_rest_service_metadata.mrs_user_has_role WHERE user_id=?) "
      "      UNION ALL "
      "      SELECT h.id AS id, h.derived_from_role_id "
      "        FROM mysql_rest_service_metadata.mrs_role AS h "
      "        JOIN cte c ON c.derived_from_role_id=h.id "
      "        ) "
      "        SELECT id FROM cte) "
      "GROUP BY p.service_path, p.schema_path, p.object_path");

  query_ << to_sqlstring(user_id);

  execute(session);
}

void QueryEntriesAuthPrivilegesImpl::on_row(const ResultRow &r) {
  helper::MySQLRow row{r, metadata_, num_of_metadata_};
  entry::AuthPrivilege entry;
  entry::AuthPrivilege::ApplyToV4 apply_to;

  row.unserialize(&apply_to.service_name);
  row.unserialize(&apply_to.schema_name);
  row.unserialize(&apply_to.object_name);
  row.unserialize(&entry.crud);

  entry.select_by = apply_to;

  privileges_->push_back(entry);
}


}  // namespace database
}  // namespace mrs
