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

#include "mrsd/compat_client.h"

#include <cstdint>
#include <iterator>

namespace {
// Maximum bytes per character, indexed by collation id (MYSQL_FIELD::charsetnr).
// 0 marks an unused id.
//
// Generated from MySQL 26.7.0:
//   SELECT c.ID, s.MAXLEN FROM information_schema.COLLATIONS c
//     JOIN information_schema.CHARACTER_SETS s USING (CHARACTER_SET_NAME)
// Replaces get_charset(id)->mbmaxlen from the server's strings library.
constexpr uint8_t kMbMaxLen[] = {
    0, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 2, 1, 1, 1, 0, 1, 2,  // 0
    1, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 1, 3, 1, 2, 1, 1, 1, 1,  // 20
    1, 1, 1, 1, 1, 4, 4, 1, 1, 1, 1, 1, 1, 1, 4, 4, 4, 1, 1, 1,  // 40
    4, 4, 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 1,  // 60
    1, 1, 1, 3, 2, 2, 2, 2, 2, 1, 2, 3, 1, 1, 1, 2, 2, 3, 3, 1,  // 80
    0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,  // 100
    4, 4, 4, 4, 4, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,  // 120
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 2,  // 140
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,  // 160
    4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 3,  // 180
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0,  // 200
    0, 0, 0, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,  // 220
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 0, 0, 0, 0, 4, 4, 4, 4, 4,  // 240
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 0, 4, 4, 4, 0, 4, 4, 4,  // 260
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 0, 4, 4, 4, 0,  // 280
    4, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,  // 300
    4, 4, 4, 4,  // 320
};
}  // namespace

namespace mrsd {

unsigned int charset_mbmaxlen(unsigned int collation_id) {
  if (collation_id < std::size(kMbMaxLen)) return kMbMaxLen[collation_id];

  return 0;
}

}  // namespace mrsd
