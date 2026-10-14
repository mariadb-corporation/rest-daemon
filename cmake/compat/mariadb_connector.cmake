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

# Locate MariaDB Connector/C (libmariadb) in an installed package.
#
#   -DMARIADB_CONNECTOR_DIR=<prefix of a MariaDB Connector/C installation>
#
# The prefix is what `mariadb_config` was built for, e.g. a Connector/C
# release package, Homebrew's keg /opt/homebrew/opt/mariadb-connector-c, or
# /usr with the distribution's libmariadb-dev (also works unpacked anywhere
# with `dpkg -x`, as <dir>/usr), or vcpkg's installed/x64-windows with its
# libmariadb port. Without MARIADB_CONNECTOR_DIR, the vcpkg install prefix of
# the build (VCPKG_INSTALLED_PREFIX, see cmake/bootstrap_vcpkg.cmake), which
# then also provides OpenSSL. Uses <prefix>/include/mariadb (mysql.h,
# mariadb_version.h, errmsg.h, mysqld_error.h, ...), the shared library from
# <prefix>/lib[/mariadb | /<multiarch>] and the client auth plugins from
# <prefix>/lib[/<multiarch>]/{mariadb,libmariadb3}/plugin.
#
# Defines the names the router CMake files expect for the client library
# (upstream's names, kept so those files stay close to upstream):
#   MySQL::client             IMPORTED shared library target
#   MYSQL_CLIENT_INCLUDE_DIR  include directory
#   MYSQL_CLIENT_VERSION      Connector/C version, e.g. 3.4.11
#   MYSQL_CLIENT_VERSION_ID   e.g. 30411
#   MYSQL_CLIENT_LIBRARY      full path of the shared library
#   MYSQL_CLIENT_LIBRARY_DIR  its directory
# plus
#   MARIADB_CLIENT_PLUGIN_DIR the client auth plugin directory

SET(MARIADB_CONNECTOR_DIR "" CACHE PATH
  "Prefix of a MariaDB Connector/C installation (3.4 or later)")

IF(NOT MARIADB_CONNECTOR_DIR)
  IF(NOT VCPKG_INSTALLED_PREFIX)
    MESSAGE(FATAL_ERROR
      "MARIADB_CONNECTOR_DIR is not set and vcpkg is off "
      "(WITH_VCPKG_TRIPLET=${WITH_VCPKG_TRIPLET}): pass "
      "-DMARIADB_CONNECTOR_DIR=<Connector/C installation> or "
      "-DWITH_VCPKG_TRIPLET=<triplet>")
  ENDIF()
  # a normal variable: the cache entry stays empty, and the next configure
  # takes the vcpkg prefix again
  SET(MARIADB_CONNECTOR_DIR "${VCPKG_INSTALLED_PREFIX}")
  # its dependencies (zlib, OpenSSL) are vcpkg's too: the packages bundle them
  SET(MARIADB_CONNECTOR_FROM_VCPKG ON)
  # the OpenSSL libmariadb is linked with, so that one OpenSSL is loaded: the
  # release libraries in lib/, as libmariadb's below, also in a Debug build
  # (the vcpkg toolchain would find debug/lib's there)
  IF(NOT OPENSSL_ROOT_DIR)
    SET(OPENSSL_ROOT_DIR "${VCPKG_INSTALLED_PREFIX}")
    SET(OPENSSL_INCLUDE_DIR "${VCPKG_INSTALLED_PREFIX}/include")
    FOREACH(_var OPENSSL_SSL_LIBRARY OPENSSL_CRYPTO_LIBRARY)
      STRING(FIND "${${_var}}" "${VCPKG_INSTALLED_PREFIX}/debug/" _pos)
      IF(_pos EQUAL 0)
        UNSET(${_var} CACHE)
      ENDIF()
    ENDFOREACH()
    FIND_LIBRARY(OPENSSL_SSL_LIBRARY NAMES ssl libssl
      PATHS "${VCPKG_INSTALLED_PREFIX}/lib" NO_DEFAULT_PATH)
    FIND_LIBRARY(OPENSSL_CRYPTO_LIBRARY NAMES crypto libcrypto
      PATHS "${VCPKG_INSTALLED_PREFIX}/lib" NO_DEFAULT_PATH)
  ENDIF()
ENDIF()

GET_FILENAME_COMPONENT(MARIADB_CONNECTOR_DIR "${MARIADB_CONNECTOR_DIR}" ABSOLUTE)

FIND_PATH(MYSQL_CLIENT_INCLUDE_DIR
  NAMES mysql.h
  PATHS "${MARIADB_CONNECTOR_DIR}/include/mariadb"
        "${MARIADB_CONNECTOR_DIR}/include/mysql"  # vcpkg's libmariadb port
        "${MARIADB_CONNECTOR_DIR}/include"
  NO_DEFAULT_PATH)
IF(NOT MYSQL_CLIENT_INCLUDE_DIR OR
   NOT EXISTS "${MYSQL_CLIENT_INCLUDE_DIR}/mariadb_version.h")
  MESSAGE(FATAL_ERROR
    "MariaDB Connector/C headers (mysql.h, mariadb_version.h) not found in "
    "${MARIADB_CONNECTOR_DIR}/include/mariadb")
ENDIF()

FILE(STRINGS "${MYSQL_CLIENT_INCLUDE_DIR}/mariadb_version.h" _ver_line
  REGEX "^#define[ \t]+MARIADB_PACKAGE_VERSION[ \t]+\"")
FILE(STRINGS "${MYSQL_CLIENT_INCLUDE_DIR}/mariadb_version.h" _ver_id_line
  REGEX "^#define[ \t]+MARIADB_PACKAGE_VERSION_ID[ \t]+[0-9]+")
STRING(REGEX REPLACE ".*\"([0-9.]+)[^\"]*\".*" "\\1"
  MYSQL_CLIENT_VERSION "${_ver_line}")
STRING(REGEX REPLACE ".*[ \t]([0-9]+).*" "\\1"
  MYSQL_CLIENT_VERSION_ID "${_ver_id_line}")

IF(NOT MYSQL_CLIENT_VERSION_ID OR MYSQL_CLIENT_VERSION_ID LESS 30400)
  MESSAGE(FATAL_ERROR
    "MariaDB Connector/C ${MYSQL_CLIENT_VERSION} in ${MARIADB_CONNECTOR_DIR} "
    "is too old, 3.4 or later is required.")
ENDIF()

IF(WIN32)
  # import library + DLL
  FIND_LIBRARY(MYSQL_CLIENT_IMPLIB
    NAMES libmariadb
    PATHS "${MARIADB_CONNECTOR_DIR}/lib" "${MARIADB_CONNECTOR_DIR}/lib/mariadb"
    NO_DEFAULT_PATH)
  FIND_FILE(MYSQL_CLIENT_LIBRARY
    NAMES libmariadb.dll
    PATHS "${MARIADB_CONNECTOR_DIR}/lib" "${MARIADB_CONNECTOR_DIR}/lib/mariadb"
          "${MARIADB_CONNECTOR_DIR}/bin"
    NO_DEFAULT_PATH)
  IF(NOT MYSQL_CLIENT_IMPLIB OR NOT MYSQL_CLIENT_LIBRARY)
    MESSAGE(FATAL_ERROR
      "libmariadb.lib/libmariadb.dll not found in ${MARIADB_CONNECTOR_DIR}")
  ENDIF()
ELSE()
  # the shared library: the static one would need the connector's own
  # OpenSSL/zlib/zstd at link time
  SET(_save_suffixes ${CMAKE_FIND_LIBRARY_SUFFIXES})
  IF(APPLE)
    SET(CMAKE_FIND_LIBRARY_SUFFIXES ".dylib")
  ELSE()
    SET(CMAKE_FIND_LIBRARY_SUFFIXES ".so")
  ENDIF()
  FIND_LIBRARY(MYSQL_CLIENT_LIBRARY
    NAMES mariadb
    PATHS "${MARIADB_CONNECTOR_DIR}/lib" "${MARIADB_CONNECTOR_DIR}/lib/mariadb"
          "${MARIADB_CONNECTOR_DIR}/lib64" "${MARIADB_CONNECTOR_DIR}/lib64/mariadb"
          "${MARIADB_CONNECTOR_DIR}/lib/${CMAKE_LIBRARY_ARCHITECTURE}"
    NO_DEFAULT_PATH)
  SET(CMAKE_FIND_LIBRARY_SUFFIXES ${_save_suffixes})
  IF(NOT MYSQL_CLIENT_LIBRARY)
    MESSAGE(FATAL_ERROR
      "shared libmariadb not found in ${MARIADB_CONNECTOR_DIR}/lib")
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

# client auth plugins (caching_sha2_password, client_ed25519, parsec, dialog,
# ... are dynamic in Connector/C)
FIND_PATH(MARIADB_CLIENT_PLUGIN_DIR
  NAMES caching_sha2_password.so caching_sha2_password.dylib
        caching_sha2_password.dll
  PATHS "${MARIADB_CONNECTOR_DIR}/lib/mariadb/plugin"
        "${MARIADB_CONNECTOR_DIR}/lib/plugin"
        "${MARIADB_CONNECTOR_DIR}/lib64/mariadb/plugin"
        "${MARIADB_CONNECTOR_DIR}/lib/${CMAKE_LIBRARY_ARCHITECTURE}/libmariadb3/plugin"
        "${MARIADB_CONNECTOR_DIR}/lib/${CMAKE_LIBRARY_ARCHITECTURE}/mariadb/plugin"
        "${MARIADB_CONNECTOR_DIR}/plugins/libmariadb"  # vcpkg
  NO_DEFAULT_PATH)
# where the packages install the client plugins, next to the bundled
# libmariadb (config.h: restd looks there first)
SET(MRSD_CLIENT_PLUGIN_SUBDIR "mariadb-client-plugins")
IF(NOT MARIADB_CLIENT_PLUGIN_DIR)
  MESSAGE(WARNING
    "MariaDB Connector/C client plugin directory not found under "
    "${MARIADB_CONNECTOR_DIR}/lib; only the built-in auth plugins will work")
ENDIF()


MESSAGE(STATUS "MariaDB Connector/C ${MYSQL_CLIENT_VERSION}: ${MYSQL_CLIENT_LIBRARY}")
