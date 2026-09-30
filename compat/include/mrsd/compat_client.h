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

// Replacements for libmysqlclient internals that aren't part of the public
// client API (see docs/phase0-inventory.md, section 3).

#ifndef MRSD_COMPAT_CLIENT_H
#define MRSD_COMPAT_CLIENT_H

namespace mrsd {

/**
 * text of a client error (CR_*); replaces my_get_err_msg().
 *
 * Unknown codes map to the text of CR_UNKNOWN_ERROR.
 */
const char *client_error_message(unsigned int code);

/**
 * maximum bytes per character of a collation; replaces
 * get_charset(id, 0)->mbmaxlen.
 *
 * @returns 0 if the collation id is unknown.
 */
unsigned int charset_mbmaxlen(unsigned int collation_id);

}  // namespace mrsd

#endif
