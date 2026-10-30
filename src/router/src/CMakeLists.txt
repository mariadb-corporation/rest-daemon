# Copyright (c) 2015, 2026, Oracle and/or its affiliates.
# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2.0,
# as published by the Free Software Foundation.
#
# This program is designed to work with certain software (including
# but not limited to OpenSSL) that is licensed under separate terms,
# as designated in a particular file or component or in included license
# documentation.  The authors of MySQL and, with respect to its
# modifications and additions, MariaDB plc hereby grant you an additional
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

# MS Visual C++ specifics
IF(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
  ADD_DEFINITIONS(-D_CRT_SECURE_NO_WARNINGS)  # bypass Warning C4996 (getenv)
ENDIF()

ROUTER_ADD_SHARED_LIBRARY(router_utils
  default_paths.cc
  keyring_info.cc
  utils.cc
  uri.cc
  router_config_utils.cc

  OUTPUT_NAME "restd_utils"

  LINK_LIBRARIES
  PUBLIC
  harness_stdx
  harness-library
  )

ROUTER_ADD_SHARED_LIBRARY(router_mysql
  common/accounts_cleaner.cc
  common/log_filter.cc
  common/mysql_session.cc
  common/server_compatibility.cc
  common/utils_sqlstring.cc

  OUTPUT_NAME "restd_client"

  LINK_LIBRARIES
  PUBLIC
  harness_stdx
  harness-library  # log_debug
  router_mysqlclient
  )
IF(MY_COMPILER_IS_GNU AND (WITH_LTO OR CMAKE_COMPILER_FLAG_WITH_LTO))
  TARGET_LINK_OPTIONS(router_mysql PRIVATE -Wno-error=stringop-overflow)
ENDIF()

# restd: the shared libraries are named librestd_*; the plugins and the
# executables keep their own names
IF(WIN32)
  SET(router_lib_output_name "restd_lib")
ELSE()
  SET(router_lib_output_name "restd")
ENDIF()

ROUTER_ADD_SHARED_LIBRARY(router_lib
  certificate_generator.cc
  certificate_handler.cc
  config_files.cc
  sys_user_operations.cc

  NO_EXPORT_HEADER  # custom names
  OUTPUT_NAME "${router_lib_output_name}"

  LINK_LIBRARIES
  ${CMAKE_DL_LIBS}
  harness-library
  harness_stdx
  harness_tls
  router_utils
  # router_mysql
  OpenSSL::SSL OpenSSL::Crypto
  io_component
  extra::rapidjson
  )

TARGET_INCLUDE_DIRECTORIES(router_lib
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/../include
  ${CMAKE_CURRENT_BINARY_DIR}/../include
  )

GENERATE_EXPORT_HEADER(router_lib
  EXPORT_FILE_NAME ${CMAKE_CURRENT_BINARY_DIR}/../include/mysqlrouter/router_export.h)

SET(frontend_lib_source_files
  router_app.cc
  )

IF(WIN32)
  LIST(APPEND frontend_lib_source_files
    windows/main-windows.cc
    windows/nt_servc.cc
    windows/password_vault.cc
    windows/service_operations.cc
    )
ENDIF()

ADD_LIBRARY(router_frontend_lib STATIC
  ${frontend_lib_source_files})

TARGET_LINK_LIBRARIES(router_frontend_lib
  router_lib
  harness-library)
IF(WIN32)
  # for the password_vault.cc
  TARGET_LINK_LIBRARIES(router_frontend_lib Crypt32)
ENDIF()

TARGET_INCLUDE_DIRECTORIES(router_frontend_lib
  PUBLIC
  ${PROJECT_SOURCE_DIR}/src/http/include/
  ${PROJECT_SOURCE_DIR}/src/mysql_protocol/include/
  ${PROJECT_SOURCE_DIR}/src/http/include/
  ${PROJECT_SOURCE_DIR}/src/rest_api/include/
)

IF(WIN32)
  SET(router_rc_files
    ../../harness/src/logging/eventlog_rc/message.rc
    ../../harness/src/logging/eventlog_rc/MSG00001.bin)
ENDIF()

# restd: --setup (mrsd_setup.cc; bootstrap_mysql_account.cc is upstream's
# router/src/bootstrap/src/bootstrap_mysql_account.cc)
MYSQL_ADD_EXECUTABLE(mysqlrouter
  main.cc
  mrsd_setup.cc
  bootstrap_mysql_account.cc
  ${router_rc_files}
  COMPONENT Router
  LINK_LIBRARIES
  harness-library
  router_lib
  router_frontend_lib
  router_mysql
  mysql_rest_service_if
  mysql_rest_service_db
  ${CMAKE_DL_LIBS}
  )

# restd: the targets keep the router's names; the files get mrsd's
SET_TARGET_PROPERTIES(mysqlrouter PROPERTIES
  OUTPUT_NAME "${MRSD_PROGRAM_NAME}")

IF(SOLARIS)
  TARGET_LINK_LIBRARIES(mysqlrouter -lnsl -lsocket)
ENDIF()

IF(APPLE)
  SET_TARGET_PROPERTIES(mysqlrouter PROPERTIES
    LINK_FLAGS "-undefined dynamic_lookup")
ENDIF()

MYSQL_ADD_EXECUTABLE(mysqlrouter_keyring
  keyring_cli.cc
  keyring_frontend.cc
  COMPONENT Router
  LINK_LIBRARIES
  router_utils
  extra::rapidjson
  )
SET_TARGET_PROPERTIES(mysqlrouter_keyring PROPERTIES
  OUTPUT_NAME "${MRSD_PROGRAM_NAME}-keyring")
