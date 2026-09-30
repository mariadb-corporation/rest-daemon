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

# mrsd module set; see docs/PLAN.md "Target module set".
# Order matters where a module uses targets defined by another one.

ADD_SUBDIRECTORY(json_schema_embedder)
ADD_SUBDIRECTORY(harness)
ADD_SUBDIRECTORY(openssl)
ADD_SUBDIRECTORY(io)
ADD_SUBDIRECTORY(router)
ADD_SUBDIRECTORY(mysql_protocol)
ADD_SUBDIRECTORY(http)
ADD_SUBDIRECTORY(rest_api)
ADD_SUBDIRECTORY(destination_status)
ADD_SUBDIRECTORY(keepalive)
ADD_SUBDIRECTORY(plugin_info)
ADD_SUBDIRECTORY(rest_router)
IF(MRS_JIT_EXECUTOR_LIB)
  ADD_SUBDIRECTORY(jit_executor)
  ADD_DEFINITIONS(-DHAVE_JIT_EXECUTOR_PLUGIN)
ENDIF()
ADD_SUBDIRECTORY(mysql_rest_service)
ADD_SUBDIRECTORY(mock_server)
