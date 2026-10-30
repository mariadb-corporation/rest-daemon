/*
  Copyright (c) 2023, 2026, Oracle and/or its affiliates.
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

#include "mysqlrouter/server_compatibility.h"

#include <iostream>

#include "mysqlrouter/mysql_session.h"

void check_version_compatibility(mysqlrouter::MySQLSession *session) {
  bool ok = true;
  // restd: a MariaDB server, 11.7 or later (the 5.0 metadata schema uses
  // UUID_v7()); upstream accepted MySQL 8+ here
  if (!session->is_mariadb()) {
    std::cout << "Unsupported server: "
              << (*session->query_one("SELECT @@version"))[0]
              << " (a MariaDB server, 11.7 or later, is required)\n";
    ok = false;
  } else if (session->server_version() < 110700) {  // e.g. 110809
    std::cout << "Unsupported MariaDB server version: "
              << (*session->query_one("SELECT @@version"))[0]
              << " (11.7 or later is required)\n";
    ok = false;
  }

  auto row = session->query_one("SELECT @@basedir");
  if (strstr((*row)[0], "rds")) {
    ok = false;
  }
  try {
    session->query_one("SELECT aurora_version()");
    ok = false;
  } catch (...) {
  }
  if (!ok) throw std::runtime_error("Target DB System is not fully supported");
}
