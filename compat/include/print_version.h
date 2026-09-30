/*
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; version 2 of the License.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA
*/

// Subset of the MySQL server's print_version.h (mysys); implemented in
// compat/src/print_version.cc.

#ifndef PRINT_VERSION_INCLUDED
#define PRINT_VERSION_INCLUDED

#include <string>

/**
 * build the "--version" line:
 *
 *   <progname>  Ver <version> for <os> on <arch> (<compilation comment>)
 */
void build_version(const std::string &progname, std::string *destination);

#endif
