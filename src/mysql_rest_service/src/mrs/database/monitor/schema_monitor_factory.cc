/*
  Copyright (c) 2024, 2026, Oracle and/or its affiliates.
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

#include "mrs/interface/query_monitor_factory.h"

#include "mrs/database/query_changes_auth_app.h"
#include "mrs/database/query_changes_content_file.h"
#include "mrs/database/query_changes_content_set.h"
#include "mrs/database/query_changes_db_object.h"
#include "mrs/database/query_changes_db_schema.h"
#include "mrs/database/query_changes_db_service.h"
#include "mrs/database/query_changes_state.h"
#include "mrs/database/query_changes_url_host.h"
#include "mrs/database/query_factory.h"

namespace mrs {
namespace database {

// restd: one factory (upstream kept one per schema version 2/3)
class SchemaMonitorFactory : public mrs::interface::QueryMonitorFactory {
 public:
  ~SchemaMonitorFactory() override = default;

  std::unique_ptr<database::QueryState> create_turn_state_fetcher(
      const std::optional<uint64_t> &router_id) override {
    return std::make_unique<QueryState>(router_id);
  }

  std::unique_ptr<database::QueryEntriesUrlHost> create_url_host_fetcher()
      override {
    return std::make_unique<QueryEntriesUrlHost>();
  }

  std::unique_ptr<database::QueryEntriesDbService> create_db_service_fetcher(
      const std::optional<uint64_t> &router_id) override {
    return std::make_unique<QueryEntriesDbService>(router_id);
  }

  std::unique_ptr<database::QueryEntriesDbSchema> create_db_schema_fetcher()
      override {
    return std::make_unique<QueryEntriesDbSchema>();
  }

  std::unique_ptr<database::QueryEntriesDbObject> create_db_object_fetcher(
      interface::QueryFactory *query_factory) override {
    return std::make_unique<QueryEntriesDbObject>(query_factory);
  }

  std::unique_ptr<database::QueryEntriesAuthApp> create_authentication_fetcher()
      override {
    return std::make_unique<QueryEntriesAuthAppImpl>();
  }

  std::unique_ptr<database::QueryEntriesContentFile>
  create_content_file_fetcher() override {
    return std::make_unique<QueryEntriesContentFile>();
  }

  std::unique_ptr<database::QueryEntriesContentSet> create_content_set_fetcher()
      override {
    return std::make_unique<QueryEntriesContentSet>();
  }

  std::unique_ptr<database::QueryEntriesUrlHost> create_url_host_monitor(
      const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesUrlHost>(last_audit_log_id);
  }

  std::unique_ptr<database::QueryEntriesDbService> create_db_service_monitor(
      const uint64_t last_audit_log_id,
      const std::optional<uint64_t> &router_id) override {
    return std::make_unique<QueryChangesDbService>(last_audit_log_id,
        router_id);
  }

  std::unique_ptr<database::QueryEntriesDbSchema> create_db_schema_monitor(
      const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesDbSchema>(last_audit_log_id);
  }

  std::unique_ptr<database::QueryEntriesDbObject> create_db_object_monitor(
      interface::QueryFactory *query_factory,
      const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesDbObject>(query_factory,
        last_audit_log_id);
  }

  std::unique_ptr<database::QueryEntriesAuthApp> create_authentication_monitor(
      const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesAuthApp>(last_audit_log_id);
  }

  virtual std::unique_ptr<database::QueryChangesAuthUser>
  create_auth_user_monitor(const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesAuthUser>(last_audit_log_id);
  }

  std::unique_ptr<database::QueryEntriesContentFile>
  create_content_file_monitor(const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesContentFile>(
        last_audit_log_id);
  }

  std::unique_ptr<database::QueryEntriesContentSet> create_content_set_monitor(
      const uint64_t last_audit_log_id) override {
    return std::make_unique<QueryChangesContentSet>(
        last_audit_log_id);
  }
};


std::unique_ptr<mrs::interface::QueryMonitorFactory>
create_schema_monitor_factory() {
  return std::make_unique<SchemaMonitorFactory>();
}

std::unique_ptr<mrs::interface::QueryFactory> create_query_factory() {
  return std::make_unique<QueryFactory>();
}

}  // namespace database
}  // namespace mrs
