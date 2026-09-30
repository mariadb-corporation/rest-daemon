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

# GoogleTest/GoogleMock from extra/googletest, exposed like the server's
# cmake/googletest.cmake: targets gmock, gtest, gmock_main, gtest_main and
# the variables GTEST_LIBRARIES and GMOCK_INCLUDE_DIRS.

SET(GOOGLETEST_RELEASE googletest-1.17.0)
SET(GMOCK_SOURCE_DIR
  ${CMAKE_SOURCE_DIR}/extra/googletest/${GOOGLETEST_RELEASE}/googlemock)
SET(GTEST_SOURCE_DIR
  ${CMAKE_SOURCE_DIR}/extra/googletest/${GOOGLETEST_RELEASE}/googletest)

SET(GMOCK_FOUND 1)
SET(GMOCK_INCLUDE_DIRS
  ${GMOCK_SOURCE_DIR}
  ${GMOCK_SOURCE_DIR}/include
  ${GTEST_SOURCE_DIR}
  ${GTEST_SOURCE_DIR}/include)

ADD_LIBRARY(gmock STATIC ${GMOCK_SOURCE_DIR}/src/gmock-all.cc)
ADD_LIBRARY(gtest STATIC ${GTEST_SOURCE_DIR}/src/gtest-all.cc)
ADD_LIBRARY(gmock_main STATIC ${GMOCK_SOURCE_DIR}/src/gmock_main.cc)
ADD_LIBRARY(gtest_main STATIC ${GTEST_SOURCE_DIR}/src/gtest_main.cc)
SET(GTEST_LIBRARIES gmock gtest)

FOREACH(lib gmock gtest gmock_main gtest_main)
  TARGET_INCLUDE_DIRECTORIES(${lib} SYSTEM PUBLIC ${GMOCK_INCLUDE_DIRS})
  IF(MY_COMPILER_IS_GNU_OR_CLANG)
    TARGET_COMPILE_OPTIONS(${lib} PRIVATE -Wno-undef -Wno-conversion)
  ENDIF()
ENDFOREACH()

MY_CHECK_CXX_COMPILER_WARNING("-Wsuggest-override" HAS_SUGGEST_OVERRIDE)
IF(HAS_SUGGEST_OVERRIDE)
  SET_TARGET_PROPERTIES(gmock PROPERTIES INTERFACE_COMPILE_OPTIONS
    "${HAS_SUGGEST_OVERRIDE}")
ENDIF()
