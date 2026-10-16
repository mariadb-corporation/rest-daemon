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

#ifndef ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_ENTRY_AUTH_PRIVILEGE_H_
#define ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_ENTRY_AUTH_PRIVILEGE_H_

#include <cstdint>
#include <optional>
#include <string>

#include "mrs/database/entry/set_operation.h"
#include "mrs/database/entry/universal_id.h"

namespace mrs {
namespace database {
namespace entry {

/**
 Representation of entries in `auth_privilege`.

 This class doesn't have row-id, primary key etc, because it may represent
 several aggregated entries.
 */
class AuthPrivilege {
 public:
  class ApplyToV4 {
   public:
    std::string service_name;
    std::string schema_name;
    std::string object_name;
  };

  ApplyToV4 select_by;  // restd: schema 4 only (upstream: a variant with 2/3)

  // restd: the service of the role that holds the privilege
  // (`mrs_role.specific_to_service_id`), none for a global role. A service
  // role's privileges apply to requests on that service only; upstream matched
  // every privilege of every role by path alone, so a service role reached
  // other services.
  std::optional<UniversalId> service_id;

  Operation::ValueType crud;
};

}  // namespace entry
}  // namespace database
}  // namespace mrs

#endif  // ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_ENTRY_AUTH_PRIVILEGE_H_
