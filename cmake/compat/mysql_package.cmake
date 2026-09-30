# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA

# Locate the MySQL client library in a MySQL server binary package.
#
#   -DMYSQL_PACKAGE_DIR=<path to an extracted MySQL server package>
#
# Uses <pkg>/include (mysql.h, mysql_version.h, errmsg.h, mysqld_error.h, ...)
# and the shared client library from <pkg>/lib.
#
# Defines:
#   MySQL::client            IMPORTED shared library target
#   MYSQL_CLIENT_VERSION     e.g. 26.7.0
#   MYSQL_CLIENT_VERSION_ID  e.g. 260700
#   MYSQL_CLIENT_LIBRARY     full path of the shared library

SET(MYSQL_PACKAGE_DIR "" CACHE PATH
  "Path to an extracted MySQL server binary package (9.x or later)")

IF(NOT MYSQL_PACKAGE_DIR)
  MESSAGE(FATAL_ERROR
    "MYSQL_PACKAGE_DIR is not set. Pass -DMYSQL_PACKAGE_DIR=<path to an "
    "extracted MySQL server package> (it must contain include/mysql.h and "
    "the client library in lib/).")
ENDIF()

GET_FILENAME_COMPONENT(MYSQL_PACKAGE_DIR "${MYSQL_PACKAGE_DIR}" ABSOLUTE)

FIND_PATH(MYSQL_CLIENT_INCLUDE_DIR
  NAMES mysql.h
  PATHS "${MYSQL_PACKAGE_DIR}/include"
  NO_DEFAULT_PATH)
IF(NOT MYSQL_CLIENT_INCLUDE_DIR)
  MESSAGE(FATAL_ERROR "mysql.h not found in ${MYSQL_PACKAGE_DIR}/include")
ENDIF()

FILE(STRINGS "${MYSQL_CLIENT_INCLUDE_DIR}/mysql_version.h" _ver_line
  REGEX "^#define[ \t]+MYSQL_SERVER_VERSION[ \t]+\"")
FILE(STRINGS "${MYSQL_CLIENT_INCLUDE_DIR}/mysql_version.h" _ver_id_line
  REGEX "^#define[ \t]+MYSQL_VERSION_ID[ \t]+[0-9]+")
STRING(REGEX REPLACE ".*\"([0-9.]+)[^\"]*\".*" "\\1"
  MYSQL_CLIENT_VERSION "${_ver_line}")
STRING(REGEX REPLACE ".*[ \t]([0-9]+).*" "\\1"
  MYSQL_CLIENT_VERSION_ID "${_ver_id_line}")

IF(NOT MYSQL_CLIENT_VERSION_ID OR MYSQL_CLIENT_VERSION_ID LESS 90000)
  MESSAGE(FATAL_ERROR
    "MySQL client ${MYSQL_CLIENT_VERSION} in ${MYSQL_PACKAGE_DIR} is too old, "
    "9.0 or later is required.")
ENDIF()

IF(WIN32)
  # import library + DLL
  FIND_LIBRARY(MYSQL_CLIENT_IMPLIB
    NAMES libmysql
    PATHS "${MYSQL_PACKAGE_DIR}/lib"
    NO_DEFAULT_PATH)
  FIND_FILE(MYSQL_CLIENT_LIBRARY
    NAMES libmysql.dll
    PATHS "${MYSQL_PACKAGE_DIR}/lib" "${MYSQL_PACKAGE_DIR}/bin"
    NO_DEFAULT_PATH)
  IF(NOT MYSQL_CLIENT_IMPLIB OR NOT MYSQL_CLIENT_LIBRARY)
    MESSAGE(FATAL_ERROR "libmysql.lib/libmysql.dll not found in ${MYSQL_PACKAGE_DIR}")
  ENDIF()
ELSE()
  # prefer the shared library; the static archive would pull in the
  # package's private copy of OpenSSL/zstd/... at link time.
  SET(_save_suffixes ${CMAKE_FIND_LIBRARY_SUFFIXES})
  IF(APPLE)
    SET(CMAKE_FIND_LIBRARY_SUFFIXES ".dylib")
  ELSE()
    SET(CMAKE_FIND_LIBRARY_SUFFIXES ".so")
  ENDIF()
  FIND_LIBRARY(MYSQL_CLIENT_LIBRARY
    NAMES mysqlclient
    PATHS "${MYSQL_PACKAGE_DIR}/lib" "${MYSQL_PACKAGE_DIR}/lib/private"
          "${MYSQL_PACKAGE_DIR}/lib64"
    NO_DEFAULT_PATH)
  SET(CMAKE_FIND_LIBRARY_SUFFIXES ${_save_suffixes})
  IF(NOT MYSQL_CLIENT_LIBRARY)
    MESSAGE(FATAL_ERROR "shared libmysqlclient not found in ${MYSQL_PACKAGE_DIR}/lib")
  ENDIF()
ENDIF()

ADD_LIBRARY(MySQL::client SHARED IMPORTED GLOBAL)
SET_TARGET_PROPERTIES(MySQL::client PROPERTIES
  IMPORTED_LOCATION "${MYSQL_CLIENT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${MYSQL_CLIENT_INCLUDE_DIR}")
IF(WIN32)
  SET_TARGET_PROPERTIES(MySQL::client PROPERTIES
    IMPORTED_IMPLIB "${MYSQL_CLIENT_IMPLIB}")
ENDIF()

GET_FILENAME_COMPONENT(MYSQL_CLIENT_LIBRARY_DIR "${MYSQL_CLIENT_LIBRARY}" DIRECTORY)

MESSAGE(STATUS "MySQL client ${MYSQL_CLIENT_VERSION}: ${MYSQL_CLIENT_LIBRARY}")
