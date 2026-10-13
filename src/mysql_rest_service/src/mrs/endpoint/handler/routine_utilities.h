/*
  Copyright (c) 2025, 2026, Oracle and/or its affiliates.
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

#ifndef _MYSQL_REST_SERVICE_SRC_MRS_ENDPOINT_HANDLER_ROUTINE_UTILITIES_H_
#define _MYSQL_REST_SERVICE_SRC_MRS_ENDPOINT_HANDLER_ROUTINE_UTILITIES_H_

#include <memory>
#include <string>
#include <vector>
#include "helper/http/url.h"
#include "mrs/endpoint/handler/helper/utilities.h"
#include "mrs/http/error.h"
#include "mrs/interface/rest_handler.h"
#include "mrs/rest/request_context.h"
#include "mysqlrouter/utils_sqlstring.h"

namespace mrs {
namespace endpoint {
namespace handler {

using HttpResult = mrs::interface::HttpResult;

inline std::string get_endpoint_url(
    std::weak_ptr<mrs::endpoint::DbObjectEndpoint> &wp) {
  auto locked = lock_or_throw_unavail(wp);
  return locked->get_url().join();
}

inline HttpResult handler_mysqlerror(const mysqlrouter::MySQLSession::Error &e,
                                     const char *sql_state) {
  static const std::string k_state_with_user_defined_error = "45000";
  if (!sql_state) throw e;

  log_debug("While handling a routine, received a mysql-error with state: %s",
            sql_state);
  if (k_state_with_user_defined_error != sql_state) {
    throw e;
  }
  // 5000 is the offset for HTTPStatus errors,
  // Still first HTTP status begins with 100 code,
  // because of that we are validating the value
  // not against 5000, but 5100.
  if (e.code() < 5100 || e.code() >= 5600) {
    throw e;
  }
  helper::json::MapObject map{{"message", e.message()}};
  HttpResult::HttpStatus status = e.code() - 5000;
  try {
    HttpStatusCode::get_default_status_text(status);
  } catch (...) {
    throw e;
  }
  auto json = helper::json::to_string(map);
  log_debug("routine - generated custom HTTPstats + message:%s", json.c_str());
  return HttpResult(status, std::move(json), HttpResult::Type::typeJson);
}

inline mysqlrouter::sqlstring get_user_id(rest::RequestContext *ctxt,
                                          bool required) {
  // this will not be set if the endpoint does not require auth, even if the
  // request IS authenticated
  if (!ctxt->user.has_user_id) {
    if (required) throw http::Error(HttpStatusCode::Forbidden);
    return {};
  }

  mysqlrouter::sqlstring sql("?");
  sql << to_string(ctxt->user.user_id);

  return sql;
}

inline void check_input_parameters(
    const std::vector<database::entry::Field> &param_fields,
    const rapidjson::Document &doc) {
  for (auto el : helper::json::member_iterator(doc)) {
    auto key = el.first;
    if (!mysql_harness::utility::container::has_if(
            param_fields, [key](const auto &v) {
              return v.mode != database::entry::Field::modeOut && v.name == key;
            })) {
      throw http::Error(HttpStatusCode::BadRequest,
                        "Not allowed parameter:" + std::string{key});
    }
  }
}

}  // namespace handler
}  // namespace endpoint
}  // namespace mrs

#endif /* _MYSQL_REST_SERVICE_SRC_MRS_ENDPOINT_HANDLER_ROUTINE_UTILITIES_H_ */
