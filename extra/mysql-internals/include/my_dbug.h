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

/*
  Minimal stand-in for the MySQL server's my_dbug.h (the DBUG debugging
  library lives in mysys, which mrsd doesn't link).

  All DBUG macros compile to nothing; DBUG_ASSERT maps to assert().
*/
#ifndef MY_DBUG_INCLUDED
#define MY_DBUG_INCLUDED

#include <cassert>

#define DBUG_TRACE \
  do {             \
  } while (false)
#define DBUG_PRINT(keyword, arglist) \
  do {                               \
  } while (false)
#define DBUG_EXECUTE_IF(keyword, a1) \
  do {                               \
  } while (false)
#define DBUG_EVALUATE_IF(keyword, a1, a2) (a2)
#define DBUG_ASSERT(A) assert(A)

#endif  // MY_DBUG_INCLUDED
