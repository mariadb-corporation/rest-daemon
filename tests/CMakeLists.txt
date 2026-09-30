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

INCLUDE_DIRECTORIES(SYSTEM ${GMOCK_INCLUDE_DIRS})

OPTION(WITH_COMPONENT_TESTS "Build the component tests (tests/component)" OFF)
OPTION(WITH_INTEGRATION_TESTS "Build the integration tests (tests/integration)" OFF)

SET(helper_sources
  helpers/filesystem_utils.cc
  helpers/gtest_testname.cc
  helpers/core_dumper.cc
  helpers/core_finder.cc
  helpers/process_manager.cc
  helpers/process_wrapper.cc
  helpers/router_component_system_layout.cc
  helpers/router_test_helpers.cc
  helpers/script_generator.cc
  helpers/tcp_port_pool.cc
  # used by the MRS database tests (src/mysql_rest_service/tests)
  helpers/shared_server.cc
)
# mrsd: helpers of the component/integration suites; they still depend on
# routing and cluster metadata code and are ported with those suites.
IF(WITH_COMPONENT_TESTS OR WITH_INTEGRATION_TESTS)
  LIST(APPEND helper_sources
    helpers/mock_server_testutils.cc
    helpers/router_component_clusterset.cc
    helpers/router_component_test.cc
    helpers/router_component_testutils.cc
    helpers/router_component_metadata.cc
    helpers/rest_api_testutils.cc
    helpers/rest_metadata_client.cc
    helpers/routing_guidelines_builder.cc
    )
ENDIF()

IF(MY_COMPILER_IS_CLANG)
  STRING_APPEND(CMAKE_CXX_FLAGS " -Wno-deprecated")
ENDIF()

ADD_LIBRARY(routertest_helpers STATIC ${helper_sources})

TARGET_LINK_LIBRARIES(routertest_helpers
  harness-library
  router_utils
  router_mysql
  mock_server_rest_client
  )
# mrsd: shared_server starts mysqld from the MySQL server package
TARGET_COMPILE_DEFINITIONS(routertest_helpers PRIVATE
  MRSD_MYSQL_PACKAGE_DIR="${MYSQL_PACKAGE_DIR}")

TARGET_INCLUDE_DIRECTORIES(routertest_helpers
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/helpers
  ${PROJECT_SOURCE_DIR}/src/harness/shared/include/
  )

# mrsd: component/integration suites are being triaged (routing, cluster and
# bootstrap tests don't apply); off until that is done.
IF(WITH_COMPONENT_TESTS)
  ADD_SUBDIRECTORY(component)
ENDIF()
IF(WITH_INTEGRATION_TESTS)
  ADD_SUBDIRECTORY(integration)
ENDIF()

ADD_DEFINITIONS(
  -DCOMPONENT_TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/component/data/")
ADD_DEFINITIONS(
  -DSSL_TEST_DATA_DIR="${CMAKE_SOURCE_DIR}/tests/data/ssl/")
