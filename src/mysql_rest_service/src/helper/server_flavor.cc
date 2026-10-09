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

#include "helper/server_flavor.h"

#include <atomic>

namespace helper {

namespace {
std::atomic<bool> g_is_mariadb{false};
}

bool is_mariadb_server() { return g_is_mariadb.load(); }
void set_mariadb_server(bool is_mariadb) { g_is_mariadb.store(is_mariadb); }

}  // namespace helper
