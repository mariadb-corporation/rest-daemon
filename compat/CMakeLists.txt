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

# mrsd_compat: replacements for the libmysqlclient internals (mysys/strings)
# that upstream router takes from its private libmysqlrouter_mysqlclient.
# See docs/phase0-inventory.md, section 3.

CONFIGURE_FILE(mrsd_compat_version.h.in
  ${CMAKE_CURRENT_BINARY_DIR}/include/mrsd_compat_version.h @ONLY)

ADD_LIBRARY(mrsd_compat STATIC
  src/aligned_malloc.cc
  src/charset.cc
  src/client_errors.cc
  src/print_version.cc
  src/stacktrace.cc
  src/thread_name.cc
  # vendored from the server's strings/ (my_gcvt(), my_fcvt(), my_strtod())
  ${CMAKE_SOURCE_DIR}/extra/mysql-internals/src/dtoa.cc
  )

SET_TARGET_PROPERTIES(mrsd_compat PROPERTIES POSITION_INDEPENDENT_CODE ON)

TARGET_INCLUDE_DIRECTORIES(mrsd_compat
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/include)

TARGET_LINK_LIBRARIES(mrsd_compat PUBLIC MySQL::client)

IF(WIN32)
  TARGET_LINK_LIBRARIES(mrsd_compat PRIVATE dbghelp)
ENDIF()
