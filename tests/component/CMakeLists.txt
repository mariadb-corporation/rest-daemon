# Copyright (c) 2017, 2026, Oracle and/or its affiliates.
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

IF(NOT TARGET mysql_server_mock)
  RETURN()
ENDIF()

ADD_HARNESS_PLUGIN(routertestplugin_logger NO_INSTALL
  DESTINATION harness
  SOURCES logger_testplugin.cc)

MYSQL_ADD_EXECUTABLE(master_key_test_writer
  ../helpers/master_key_test_writer.cc
  COMPONENT Router
  SKIP_INSTALL
  )

MYSQL_ADD_EXECUTABLE(signal_me
  signal_me.cc
  COMPONENT Router
  SKIP_INSTALL
  )

ADD_SUBDIRECTORY(rest_signal)

ADD_DEFINITIONS(-DSSL_TEST_DATA_DIR="${CMAKE_SOURCE_DIR}/tests/data/ssl/")
ADD_DEFINITIONS(-DCMAKE_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
# mrsd: only the component tests that apply to an MRS daemon; the routing,
# cluster, bootstrap, metadata-cache and connection-pool tests were dropped.
FOREACH(test_file
    test_component_test_framework.cc
    test_config.cc
    test_config_overwrites.cc
    test_http_server.cc
    test_logging.cc
    test_logging_eventlog.cc
    test_master_key_reader_writer.cc
    test_mrs_config.cc
    test_pidfile.cc
    test_rest_api.cc
    test_rest_mock_server.cc
    test_rest_router.cc
    test_router_configuration_errors.cc
    test_router_stacktrace.cc
    test_sd_notify.cc
    test_shutdown.cc
    test_stacktrace.cc
    )
  ADD_TEST_FILE(${CMAKE_CURRENT_SOURCE_DIR}/${test_file}
    MODULE "component"
    INCLUDE_DIRS
      ${PROJECT_SOURCE_DIR}/src/mock_server/include/mysqlrouter/
      ${PROJECT_SOURCE_DIR}/tests/
    SYSTEM_INCLUDE_DIRS ${GMOCK_INCLUDE_DIRS}
    LIB_DEPENDS
      http_client
      http_common
      mock_server_rest_client
      mysql_protocol
      routertest_helpers
      test-helpers
    DEPENDS
      http_auth_backend
      http_auth_realm
      http_server
      master_key_test_writer
      mock_server
      mysql_server_mock
      mysqlrouter_passwd
      mysqlrouter
      rest_api
      rest_router
      mysql_rest_service
      routertestplugin_logger
      signal_me
    )
ENDFOREACH()

ADD_DEFINITIONS(-DSKIP_MYSQL_NATIVE_PASSWORD_TESTS)
ADD_DEFINITIONS(-DSKIP_BOOTSTRAP_SYSTEM_DEPLOYMENT_TESTS)
ADD_DEFINITIONS(-DROUTER_SRC_DIR="${CMAKE_SOURCE_DIR}")

# run each test binary without the cases that exercise features mrsd doesn't
# have (see excluded_cases.cmake)
FUNCTION(EXCLUDE_TEST_CASES TEST_NAME)
  LIST(JOIN ARGN ":" _cases)
  SET_PROPERTY(TEST ${TEST_NAME} APPEND PROPERTY
    ENVIRONMENT "GTEST_FILTER=-${_cases}")
ENDFUNCTION()
INCLUDE(${CMAKE_CURRENT_SOURCE_DIR}/excluded_cases.cmake)
