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

# Third-party dependencies, exposed under the target names the router CMake
# files use in the server build:
#   OpenSSL::SSL, OpenSSL::Crypto, extra::rapidjson, ext::icu, ext::cno

# --- OpenSSL ---------------------------------------------------------------
IF(APPLE AND NOT OPENSSL_ROOT_DIR AND EXISTS "/opt/homebrew/opt/openssl@3")
  SET(OPENSSL_ROOT_DIR "/opt/homebrew/opt/openssl@3")
ENDIF()
FIND_PACKAGE(OpenSSL 3.0 REQUIRED)
MESSAGE(STATUS "OpenSSL ${OPENSSL_VERSION}: ${OPENSSL_SSL_LIBRARY}")
# upstream code uses these directly in a few places
SET(SSL_LIBRARIES OpenSSL::SSL OpenSSL::Crypto)

# --- rapidjson (vendored, MySQL's patched copy) ----------------------------
ADD_LIBRARY(rapidjson INTERFACE)
ADD_LIBRARY(extra::rapidjson ALIAS rapidjson)
TARGET_INCLUDE_DIRECTORIES(rapidjson SYSTEM INTERFACE
  ${CMAKE_SOURCE_DIR}/extra/rapidjson/include)
TARGET_COMPILE_DEFINITIONS(rapidjson INTERFACE
  RAPIDJSON_NO_SIZETYPEDEFINE
  RAPIDJSON_SCHEMA_USE_INTERNALREGEX=0
  RAPIDJSON_SCHEMA_USE_STDREGEX=1
  RAPIDJSON_HAS_STDSTRING=1)

# --- ICU (system) ----------------------------------------------------------
IF(APPLE AND NOT ICU_ROOT AND EXISTS "/opt/homebrew/opt/icu4c")
  SET(ICU_ROOT "/opt/homebrew/opt/icu4c")
ENDIF()
FIND_PACKAGE(ICU 69 REQUIRED COMPONENTS uc i18n data)
MESSAGE(STATUS "ICU ${ICU_VERSION}: ${ICU_INCLUDE_DIRS}")
ADD_LIBRARY(icu_interface INTERFACE)
ADD_LIBRARY(ext::icu ALIAS icu_interface)
TARGET_LINK_LIBRARIES(icu_interface INTERFACE ICU::i18n ICU::uc ICU::data)

# --- libcno (vendored) -----------------------------------------------------
ADD_SUBDIRECTORY(${CMAKE_SOURCE_DIR}/extra/libcno ${CMAKE_BINARY_DIR}/extra/libcno)
ADD_LIBRARY(ext::cno ALIAS cno)
SET_PROPERTY(TARGET cno PROPERTY POSITION_INDEPENDENT_CODE ON)
