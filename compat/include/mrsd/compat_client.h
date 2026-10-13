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

#include <cstring>
#include <type_traits>

#include <errmsg.h>
#include <mysql.h>
#include <mysqld_error.h>

// restd: what the code forked from MySQL Router expects of the client library
// and MariaDB Connector/C (libmariadb) doesn't have; see
// docs/milestone2-inventory.md, section 2.
// libmariadb has no MYSQL_OPT_SSL_MODE; MySQLSession emulates the modes with
// MYSQL_OPT_SSL_ENFORCE and MYSQL_OPT_SSL_VERIFY_SERVER_CERT. Same names and
// values as MySQL's enum, so the rest of the code is unchanged.
enum mysql_ssl_mode {
  SSL_MODE_DISABLED = 1,
  SSL_MODE_PREFERRED,
  SSL_MODE_REQUIRED,
  SSL_MODE_VERIFY_CA,
  SSL_MODE_VERIFY_IDENTITY
};

// MySQL-only column type codes (MySQL's values). A MariaDB server never sends
// them; they keep the type tables of helper/mysql_column_types.cc unchanged.
constexpr enum_field_types MYSQL_TYPE_TYPED_ARRAY =
    static_cast<enum_field_types>(20);
constexpr enum_field_types MYSQL_TYPE_INVALID =
    static_cast<enum_field_types>(243);
constexpr enum_field_types MYSQL_TYPE_BOOL = static_cast<enum_field_types>(244);
#if MARIADB_PACKAGE_VERSION_ID < 30410
// added to libmariadb's enum in 3.4.10 (same value as MySQL's)
constexpr enum_field_types MYSQL_TYPE_VECTOR =
    static_cast<enum_field_types>(242);
#endif


namespace mrsd {

// the type MYSQL_BIND::is_null points to (my_bool, i.e. char, in libmariadb;
// bool in the library the code was written for)
using bind_bool_t = std::remove_pointer_t<decltype(MYSQL_BIND::is_null)>;

/**
 * the type of a result column, with JSON and VECTOR recognised on MariaDB.
 *
 * A MariaDB server sends JSON columns and routine results as LONGTEXT and
 * VECTOR as VARBINARY, with the kind in the extended column metadata, which
 * Connector/C exposes as field attributes (format "json", data type
 * "vector"). For everything else it is MYSQL_FIELD::type.
 */
inline enum_field_types effective_field_type(const MYSQL_FIELD *field) {
  MARIADB_CONST_STRING attr;
  if (mariadb_field_attr(&attr, field, MARIADB_FIELD_ATTR_FORMAT_NAME) == 0 &&
      attr.length == 4 && memcmp(attr.str, "json", 4) == 0)
    return MYSQL_TYPE_JSON;
  if (mariadb_field_attr(&attr, field, MARIADB_FIELD_ATTR_DATA_TYPE_NAME) ==
          0 &&
      attr.length == 6 && memcmp(attr.str, "vector", 6) == 0)
    return MYSQL_TYPE_VECTOR;
  return field->type;
}

/**
 * is the error code a client-side (CR_*) error, as opposed to a server (ER_*)
 * error; replaces `code >= CR_ERROR_FIRST && code <= CR_ERROR_LAST`.
 *
 * libmariadb has a second client error range (5000-5999).
 */
constexpr bool is_client_error(unsigned int code) {
  return (code >= CR_MIN_ERROR && code <= CR_MAX_ERROR) ||
         (code >= CER_MIN_ERROR && code < CER_MIN_ERROR + 1000);
}

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
