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

#include <type_traits>

#include <errmsg.h>
#include <mysql.h>
#include <mysqld_error.h>

// restd: MariaDB Connector/C (MRSD_CLIENT_MARIADB) vs. MySQL's libmysqlclient.
// The few public-API differences the code depends on are evened out here; see
// docs/milestone2-inventory.md, section 2.
#ifdef MRSD_CLIENT_MARIADB
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

// MySQL-only server error codes the daemon checks for, mapped to the code a
// MariaDB server returns in the same situation
// (docs/milestone2-inventory.md, 3a). Codes without a counterpart
// (ER_GTID_MODE_OFF) are handled at the call site.
#define ER_ROLE_NOT_GRANTED ER_INVALID_ROLE  // SET ROLE of a role not granted
#define ER_CHECK_CONSTRAINT_VIOLATED ER_CONSTRAINT_FAILED
#define ER_LOCK_NOWAIT ER_LOCK_WAIT_TIMEOUT  // SELECT ... FOR UPDATE NOWAIT
#define ER_USER_ALREADY_EXISTS ER_USER_CREATE_EXISTS  // CREATE USER IF NOT EXISTS
// a statement timeout (max_statement_time, MAX_EXECUTION_TIME hint)
#ifdef ER_QUERY_TIMEOUT  // only in the newest libmariadb headers
#undef ER_QUERY_TIMEOUT
#endif
#define ER_QUERY_TIMEOUT ER_STATEMENT_TIMEOUT
// no offline mode on MariaDB; the code is never returned
#ifndef ER_SERVER_OFFLINE_MODE
#define ER_SERVER_OFFLINE_MODE 3032
#endif
#define ER_SERVER_OFFLINE_MODE_REASON ER_SERVER_OFFLINE_MODE
#endif

namespace mrsd {

// the type MYSQL_BIND::is_null points to: bool (libmysqlclient) or
// my_bool, i.e. char (libmariadb)
using bind_bool_t = std::remove_pointer_t<decltype(MYSQL_BIND::is_null)>;

/**
 * is the error code a client-side (CR_*) error, as opposed to a server (ER_*)
 * error; replaces `code >= CR_ERROR_FIRST && code <= CR_ERROR_LAST`.
 *
 * libmariadb has a second client error range (5000-5999).
 */
constexpr bool is_client_error(unsigned int code) {
#ifdef MRSD_CLIENT_MARIADB
  return (code >= CR_MIN_ERROR && code <= CR_MAX_ERROR) ||
         (code >= CER_MIN_ERROR && code < CER_MIN_ERROR + 1000);
#else
  return code >= CR_ERROR_FIRST && code <= CR_ERROR_LAST;
#endif
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
