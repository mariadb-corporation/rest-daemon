/*
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License, version 2.0,
  as published by the Free Software Foundation.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License, version 2.0, for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
*/

#ifndef ROUTER_SRC_MYSQL_REST_SERVICE_INCLUDE_HELPER_SERVER_FLAVOR_H_
#define ROUTER_SRC_MYSQL_REST_SERVICE_INCLUDE_HELPER_SERVER_FLAVOR_H_

namespace helper {

// mrsd: the kind of server the service runs against, for the SQL generators
// that have no session at hand. Set once at plugin start from the first
// connection (MySQLSession::is_mariadb()); MySQL until then.
bool is_mariadb_server();
void set_mariadb_server(bool is_mariadb);

}  // namespace helper

#endif  // ROUTER_SRC_MYSQL_REST_SERVICE_INCLUDE_HELPER_SERVER_FLAVOR_H_
