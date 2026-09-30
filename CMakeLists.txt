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

# mrsd: standalone MySQL REST Service daemon.
#
# Forked from MySQL Router (mysql-server/router). The router CMake files are
# kept as upstream as possible; cmake/compat/ provides the parts of the MySQL
# server build environment they expect.
#
# Required:
#   -DMYSQL_PACKAGE_DIR=<extracted MySQL server package, 9.x or later>
# Optional:
#   -DMRS_JIT_EXECUTOR_LIB=<dir with libjitexecutor and its headers>
#   -DWITH_UNIT_TESTS=ON

CMAKE_MINIMUM_REQUIRED(VERSION 3.24)

# Point this clone's git hooks at the tracked ones in .githooks/ (the MariaDB
# copyright pre-commit hook). No-op outside a git checkout; turn it off with
# -DINSTALL_GIT_HOOKS=OFF. See cmake/git_hooks.cmake.
INCLUDE(${CMAKE_CURRENT_SOURCE_DIR}/cmake/git_hooks.cmake)

FILE(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" MRSD_VERSION LIMIT_COUNT 1)
STRING(STRIP "${MRSD_VERSION}" MRSD_VERSION)

# consumed by cmake/version.cmake
SET(MYSQL_NO_DASH_VERSION "${MRSD_VERSION}")
SET(COMPILATION_COMMENT "Source distribution" CACHE STRING "Build comment")

SET(CMAKE_MODULE_PATH
  ${CMAKE_MODULE_PATH}
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

INCLUDE(cmake/version.cmake)

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
INCLUDE(cmake/compat/mysql_package.cmake)
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
SET(ROUTER_README_FILE "${CMAKE_SOURCE_DIR}/README.router")
SET(DOC_DESTINATION ".")
INSTALL(FILES
  ${ROUTER_LICENSE_FILE}
  ${ROUTER_README_FILE}
  DESTINATION ${DOC_DESTINATION} COMPONENT Router OPTIONAL)

INCLUDE(cmake/settings.cmake)
INCLUDE(cmake/set_rpath.cmake)
INCLUDE(cmake/testing.cmake)  # does not enable testing
INCLUDE(cmake/configure.cmake)
INCLUDE(cmake/Plugin.cmake)
INCLUDE(cmake/install_macros.cmake)

INCLUDE_DIRECTORIES(${PROJECT_BINARY_DIR}/include)

ADD_CUSTOM_TARGET(mysqlrouter_all)

ADD_SUBDIRECTORY(src)

IF(WITH_UNIT_TESTS)
  ENABLE_TESTING()
  ADD_SUBDIRECTORY(tests)
ENDIF()
