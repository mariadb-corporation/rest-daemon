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

# restd: standalone MySQL REST Service daemon.
#
# Forked from MySQL Router (mysql-server/router). The router CMake files are
# kept as upstream as possible; cmake/compat/ provides the parts of the MySQL
# server build environment they expect.
#
# Required, one of:
#   -DMYSQL_PACKAGE_DIR=<extracted MySQL server package, 9.x or later>
#   -DMARIADB_CONNECTOR_DIR=<MariaDB Connector/C installation, 3.4 or later>
# Optional:
#   -DMRS_JIT_EXECUTOR_LIB=<dir with libjitexecutor and its headers>
#   -DWITH_UNIT_TESTS=ON

CMAKE_MINIMUM_REQUIRED(VERSION 3.24)

# Point this clone's git hooks at the tracked ones in .githooks/ (the MariaDB
# copyright pre-commit hook). No-op outside a git checkout; turn it off with
# -DINSTALL_GIT_HOOKS=OFF. See cmake/git_hooks.cmake.
INCLUDE(${CMAKE_CURRENT_SOURCE_DIR}/cmake/git_hooks.cmake)

# VERSION holds "<KEY> = <value>" entries; VERSION = x.y.z is required
FILE(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" _version_lines
  REGEX "^[ \t]*VERSION[ \t]*=")
IF(NOT _version_lines MATCHES "=[ \t]*([0-9]+\\.[0-9]+\\.[0-9]+)[ \t]*$")
  MESSAGE(FATAL_ERROR "VERSION: expected an entry 'VERSION = x.y.z'")
ENDIF()
SET(MRSD_VERSION "${CMAKE_MATCH_1}")

# consumed by cmake/version.cmake
SET(MYSQL_NO_DASH_VERSION "${MRSD_VERSION}")
SET(COMPILATION_COMMENT "Source distribution" CACHE STRING "Build comment")

SET(CMAKE_MODULE_PATH
  ${CMAKE_MODULE_PATH}
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

INCLUDE(cmake/version.cmake)
# program/product names, needed by the install layout (build_env.cmake)
INCLUDE(cmake/settings.cmake)

# The project keeps the upstream name for now: many CMake files and generated
# headers refer to MySQLRouter_{SOURCE,BINARY}_DIR and MySQLRouter_VERSION.
PROJECT("MySQLRouter" VERSION ${PROJECT_VERSION_TEXT} LANGUAGES C CXX)

SET(CMAKE_CXX_STANDARD 23)
SET(CMAKE_CXX_STANDARD_REQUIRED ON)
SET(CMAKE_CXX_EXTENSIONS ON)
SET(CMAKE_EXPORT_COMPILE_COMMANDS ON)
SET(CMAKE_POSITION_INDEPENDENT_CODE ON)
IF(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  SET(CMAKE_BUILD_TYPE "RelWithDebInfo" CACHE STRING "Build type" FORCE)
ENDIF()

OPTION(WITH_UNIT_TESTS "Build the unit and component tests" OFF)

INCLUDE(cmake/compat/build_env.cmake)
INCLUDE(cmake/compat/fileutils.cmake)
INCLUDE(cmake/compat/configure_checks.cmake)
# the client library: MariaDB Connector/C or MySQL's libmysqlclient. Both
# define MySQL::client; the MariaDB one also defines MRSD_CLIENT_MARIADB.
IF(MARIADB_CONNECTOR_DIR)
  INCLUDE(cmake/compat/mariadb_connector.cmake)
  SET(MRSD_CLIENT_PACKAGE_DIR "${MARIADB_CONNECTOR_DIR}")
ELSE()
  INCLUDE(cmake/compat/mysql_package.cmake)
  SET(MRSD_CLIENT_PACKAGE_DIR "${MYSQL_PACKAGE_DIR}")
ENDIF()
INCLUDE(cmake/compat/third_party.cmake)

# global flags, as in the server build
ADD_COMPILE_DEFINITIONS(
  _USE_MATH_DEFINES
  __STDC_FORMAT_MACROS
  __STDC_LIMIT_MACROS)
IF(WIN32)
  # as in the server's cmake/os/Windows.cmake. NOGDI matters: wingdi.h
  # defines ERROR and GetObject, which clash with MRS/jit_executor code and
  # rapidjson.
  ADD_COMPILE_DEFINITIONS(
    _WIN32_WINNT=0x0601
    WIN32_LEAN_AND_MEAN
    NOGDI
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS
    _CRT_NONSTDC_NO_DEPRECATE
    _WINSOCK_DEPRECATED_NO_WARNINGS
    RAPIDJSON_HAS_CXX11_RVALUE_REFS=1
    RAPIDJSON_HAS_CXX11_NOEXCEPT=1
    RAPIDJSON_HAS_CXX11_RANGE_FOR=1)
ENDIF()
IF(MSVC)
  ADD_COMPILE_OPTIONS(/wd4251 /wd4267 /wd4244
    $<$<COMPILE_LANGUAGE:CXX>:/permissive->
    $<$<COMPILE_LANGUAGE:CXX>:/Zc:__cplusplus>
    /bigobj /utf-8)
ELSE()
  ADD_COMPILE_OPTIONS(-Wall -Wextra -Wformat-security -Wvla -Wundef
    -Woverloaded-virtual -Wcast-qual -Wno-deprecated-declarations)
ENDIF()

# my_config.h, vendored server headers, public client headers
INCLUDE_DIRECTORIES(
  ${CMAKE_BINARY_DIR}/include
  ${CMAKE_SOURCE_DIR}/compat/include
  ${CMAKE_SOURCE_DIR}/extra/mysql-internals/include
  ${CMAKE_SOURCE_DIR}/extra/mysql-internals  # for #include "include/..."
  ${MYSQL_CLIENT_INCLUDE_DIR})

ADD_CUSTOM_TARGET(copy_custom_libraries)
ADD_CUSTOM_TARGET(clang_tidy_prerequisites)

# replacements for libmysqlclient internals + vendored strings/dtoa
ADD_SUBDIRECTORY(compat)

# ---------------------------------------------------------------------------
# from here on: upstream router/CMakeLists.txt (trimmed)
# ---------------------------------------------------------------------------
SET(ROUTER_LICENSE_FILE "${CMAKE_SOURCE_DIR}/LICENSE.router")
SET(ROUTER_README_FILE "${CMAKE_SOURCE_DIR}/README.md")
INSTALL(FILES
  ${CMAKE_SOURCE_DIR}/README.md
  ${CMAKE_SOURCE_DIR}/MRS_README.router
  DESTINATION ${ROUTER_INSTALL_DOCDIR} COMPONENT Router)
INSTALL(FILES ${ROUTER_LICENSE_FILE}
  DESTINATION ${ROUTER_INSTALL_DOCDIR} RENAME LICENSE COMPONENT Router)
INSTALL(FILES ${CMAKE_SOURCE_DIR}/packaging/sample.conf
  DESTINATION ${ROUTER_INSTALL_DOCDIR}
  RENAME ${MRSD_PROGRAM_NAME}.conf.sample COMPONENT Router)

INCLUDE(cmake/set_rpath.cmake)
INCLUDE(cmake/testing.cmake)  # does not enable testing
INCLUDE(cmake/configure.cmake)
INCLUDE(cmake/Plugin.cmake)
INCLUDE(cmake/install_macros.cmake)

INCLUDE_DIRECTORIES(${PROJECT_BINARY_DIR}/include)

ADD_CUSTOM_TARGET(mysqlrouter_all)

IF(WITH_UNIT_TESTS)
  ENABLE_TESTING()
  INCLUDE(cmake/compat/googletest.cmake)
  # JavaScript engine of mysql_server_mock (src/mock_server)
  ADD_SUBDIRECTORY(extra/duktape)
ENDIF()

ADD_SUBDIRECTORY(src)

IF(WITH_UNIT_TESTS)
  ADD_SUBDIRECTORY(tests)
ENDIF()

# ---------------------------------------------------------------------------
# bundled runtime libraries (last install rule: runs after everything else is
# installed). The client library (libmysqlclient or libmariadb) always;
# OpenSSL and ICU in the STANDALONE layout (tarballs, ZIP, MSI), from the
# system in deb/rpm.
# ---------------------------------------------------------------------------
# matched against the dependency as recorded (@rpath/..., absolute path, or a
# bare DLL name), hence the (^|/) anchor
SET(_bundle_regexes "(^|/)libmysqlclient[^/]*$" "(^|/)libmysql\\.dll$"
  "(^|/)libmariadb[^/]*$")
SET(_bundle_dirs "${MYSQL_CLIENT_LIBRARY_DIR}")
IF(INSTALL_LAYOUT STREQUAL "STANDALONE")
  LIST(APPEND _bundle_regexes "(^|/)lib(ssl|crypto)[^/]*$" "(^|/)(lib)?icu[^/]*$")
  FOREACH(_lib ${OPENSSL_SSL_LIBRARY} ${OPENSSL_CRYPTO_LIBRARY}
      ${ICU_UC_LIBRARY} ${ICU_I18N_LIBRARY} ${ICU_DATA_LIBRARY})
    GET_FILENAME_COMPONENT(_dir "${_lib}" DIRECTORY)
    LIST(APPEND _bundle_dirs "${_dir}")
    IF(WIN32)
      # the DLLs are in ../bin (vcpkg) or ../bin64 (ICU zip)
      LIST(APPEND _bundle_dirs "${_dir}/../bin" "${_dir}/../bin64")
    ENDIF()
  ENDFOREACH()
ENDIF()
LIST(REMOVE_DUPLICATES _bundle_dirs)
IF(WIN32)
  SET(_bundle_dest "${ROUTER_INSTALL_BINDIR}")
ELSE()
  SET(_bundle_dest "${ROUTER_INSTALL_LIBDIR}")
ENDIF()
SET(_bundle_scan
  "${ROUTER_INSTALL_BINDIR}" "${ROUTER_INSTALL_LIBDIR}"
  "${ROUTER_INSTALL_PLUGINDIR}")
LIST(REMOVE_DUPLICATES _bundle_scan)
INSTALL(CODE "
  set(BUNDLE_NAME_REGEXES \"${_bundle_regexes}\")
  set(BUNDLE_SEARCH_DIRS \"${_bundle_dirs}\")
  set(BUNDLE_DEST \"${_bundle_dest}\")
  set(BUNDLE_SCAN_DIRS \"${_bundle_scan}\")
  set(BUNDLE_AVOID_DIR \"${MRSD_CLIENT_PACKAGE_DIR}\")
  include(\"${CMAKE_SOURCE_DIR}/cmake/bundle_runtime_libraries.cmake\")
  " COMPONENT Router)


INCLUDE(cmake/packaging.cmake)
