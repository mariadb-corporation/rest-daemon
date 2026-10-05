# Copyright (c) 2019, 2026, Oracle and/or its affiliates.
# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2.0,
# as published by the Free Software Foundation.
#
# This program is designed to work with certain software (including
# but not limited to OpenSSL) that is licensed under separate terms,
# as designated in a particular file or component or in included license
# documentation.  The authors of MySQL hereby grant you an additional
# permission to link the program and your derivative works with the
# separately licensed software that they have either included with
# the program or referenced in the documentation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

INCLUDE(GenerateExportHeader)
INCLUDE(Plugin)


# mrsd: no generated JSON schemas (dynamic_state and configuration_update
# were used by the router's cluster metadata code only)

# mrsd: upstream builds a private libmysqlrouter_mysqlclient here, merging
# clientlib, vio and mysys and re-exporting internal symbols. mrsd links the
# stock libmysqlclient from MYSQL_PACKAGE_DIR instead; the few internal symbols
# that are needed come from mrsd_compat (see docs/phase0-inventory.md).
ADD_LIBRARY(router_mysqlclient INTERFACE)
TARGET_LINK_LIBRARIES(router_mysqlclient INTERFACE MySQL::client mrsd_compat)

SET(harness_source
  access_rights.cc
  loader.cc
  dynamic_loader.cc
  utilities.cc
  config_option.cc
  config_parser.cc
  plugin_config.cc
  plugin_state.cc
  designator.cc
  event_state_tracker.cc
  loader_config.cc
  common.cc
  filesystem.cc
  string_utils.cc
  arg_handler.cc
  builtin_plugins.cc
  config_section_printer.cc
  dim.cc
  hostname_validator.cc
  mysql_router_thread.cc
  process_launcher.cc
  logging/consolelog_plugin.cc
  logging/filelog_plugin.cc
  logging/handler.cc
  logging/logger.cc
  logging/logger_plugin.cc
# logging/logging.cc       empty file
  logging/registry.cc
  log_reopen.cc
  random_generator.cc
  signal_handler.cc
  scoped_callback.cc
  sd_notify.cc
  socket_operations.cc
  tls_cipher.cc
  tty.cc
  vt100.cc
  vt100_filter.cc
  keyring/keyring_manager.cc
  keyring/keyring_memory.cc
  keyring/keyring_file.cc
  keyring/master_key_file.cc
  process_state_component.cc
  log_reopen_component.cc
  destination.cc
  destination_acceptor.cc
  destination_endpoint.cc
  destination_socket.cc
  secure_string.cc
  regex_matcher.cc
  auto_cleaner.cc
  resolver/resolver.cc
  resolver/registry.cc
  resolver/error_code.cc
  )

IF(NOT SOLARIS)
  LIST(APPEND harness_source
    secure_memory_pool.cc
  )
ENDIF()

IF(WIN32)
  LIST(APPEND harness_source
    filesystem-windows.cc
    utilities-windows.cc
    logging/eventlog_plugin.cc)
ELSE()
  LIST(APPEND harness_source
    filesystem-posix.cc
    utilities-posix.cc
    logging/syslog_plugin.cc)
ENDIF()

INCLUDE_DIRECTORIES(
  ${CMAKE_CURRENT_SOURCE_DIR}/../include
  ${CMAKE_CURRENT_SOURCE_DIR}/
  ${MySQLRouter_BINARY_DIR}/include
  )

IF(WIN32)
  INCLUDE(CheckIncludeFileCXX)
  CHECK_INCLUDE_FILE_CXX("shlwapi.h" Shlwapi_FOUND)
  IF(Shlwapi_FOUND)
    SET(SHLWAPI_LIBRARIES "shlwapi.dll")
  ELSE()
    MESSAGE(FATAL_ERROR "Shlwapi library not found")
  ENDIF()

  SET(WINSOCK_LIBRARIES ws2_32)
ELSE()
  SET(SHLWAPI_LIBRARIES)
ENDIF()

SET(common_libraries ${CMAKE_DL_LIBS} ${CMAKE_THREAD_LIBS_INIT}
  ${SHLWAPI_LIBRARIES} ${WINSOCK_LIBRARIES} OpenSSL::SSL OpenSSL::Crypto)

SET(INSTALL_INCLUDE_DIR "include/mysql/harness")

## for plugin.h.in
SET(MYSQL_HARNESS_ARCH_CPU ${MYSQL_MACHINE_TYPE})
SET(MYSQL_HARNESS_ARCH_OS ${CMAKE_SYSTEM_NAME})
SET(MYSQL_HARNESS_ARCH_COMPILER ${CMAKE_CXX_COMPILER_ID}-${CMAKE_CXX_COMPILER_VERSION})
SET(MYSQL_HARNESS_ARCH_RUNTIME "*")

CONFIGURE_FILE(plugin.h.in ${MySQLRouter_BINARY_DIR}/${INSTALL_INCLUDE_DIR}/plugin.h
  ESCAPE_QUOTES @ONLY)

# create harness library - dynamic version
ROUTER_ADD_SHARED_LIBRARY(harness-library
  ${harness_source}

  NO_EXPORT_HEADER  # custom include-path

  OUTPUT_NAME "mysqlharness"

  LINK_LIBRARIES
  ${common_libraries}
  router_mysqlclient
  extra::rapidjson
  ext::icu
  )

TARGET_INCLUDE_DIRECTORIES(harness-library PUBLIC
  ../include
  ${CMAKE_CURRENT_BINARY_DIR})

generate_export_header(harness-library
  BASE_NAME HARNESS
  EXPORT_FILE_NAME ${MySQLRouter_BINARY_DIR}/include/harness_export.h)

IF(SOLARIS)
  TARGET_LINK_LIBRARIES(harness-library -lnsl -lsocket)
ENDIF()

ROUTER_ADD_SHARED_LIBRARY(harness_stdx
  stdx/filesystem.cc
  stdx/io/file_handle.cc

  NO_EXPORT_HEADER

  OUTPUT_NAME "mysqlharness_stdx"
)

TARGET_SOURCES(harness_stdx
  INTERFACE
  ${CMAKE_CURRENT_SOURCE_DIR}/../include/mysql/harness/stdx/bit.h
  ${CMAKE_CURRENT_SOURCE_DIR}/../include/mysql/harness/stdx/expected.h
  ${CMAKE_CURRENT_SOURCE_DIR}/../include/mysql/harness/stdx/type_traits.h
  )
TARGET_INCLUDE_DIRECTORIES(harness_stdx
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../include/
  ${CMAKE_CURRENT_BINARY_DIR}/../include/
  )
GENERATE_EXPORT_HEADER(harness_stdx
  EXPORT_FILE_NAME ${CMAKE_CURRENT_BINARY_DIR}/../include/mysql/harness/stdx_export.h)

## harness_tls

ROUTER_ADD_SHARED_LIBRARY(harness_tls
  tls_client_context.cc
  tls_context.cc
  tls_error.cc
  tls_server_context.cc

  NO_EXPORT_HEADER  # custom include-path
  OUTPUT_NAME "mysqlharness_tls"

  LINK_LIBRARIES
  PUBLIC OpenSSL::SSL OpenSSL::Crypto
  )

IF(TARGET copy_openssl_dlls)
  ADD_DEPENDENCIES(harness_tls copy_openssl_dlls)
ENDIF()

GENERATE_EXPORT_HEADER(harness_tls
  EXPORT_FILE_NAME ${CMAKE_CURRENT_BINARY_DIR}/../include/mysql/harness/tls_export.h)

TARGET_INCLUDE_DIRECTORIES(harness_tls
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../include/
  ${CMAKE_CURRENT_BINARY_DIR}/../include/
  )
