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

# Get the dependencies in vcpkg.json (MariaDB Connector/C, OpenSSL) from vcpkg,
# as MariaDB Shell does (its cmake/bootstrap_vcpkg.cmake, which this follows):
#
#   -DWITH_VCPKG_TRIPLET=<triplet>
#
# clones vcpkg if needed, bootstraps it and sets
#
#   CMAKE_TOOLCHAIN_FILE   = <VCPKG_ROOT>/scripts/buildsystems/vcpkg.cmake
#   VCPKG_TARGET_TRIPLET   = <triplet>
#   VCPKG_INSTALLED_PREFIX = <build>/vcpkg_installed/<triplet>
#
# The toolchain installs the manifest at the PROJECT() call, so this file must
# be included before it. cmake/compat/mariadb_connector.cmake then takes
# Connector/C and OpenSSL from VCPKG_INSTALLED_PREFIX.
#
# Without MARIADB_CONNECTOR_DIR and WITH_VCPKG_TRIPLET, the dynamic triplet of
# the host is chosen, so a configure without options works. restd links the
# shared libmariadb, which the static default triplets on macOS and Linux do
# not have. -DWITH_VCPKG_TRIPLET=OFF turns vcpkg off.
#
# vcpkg is taken from -DVCPKG_ROOT, $VCPKG_ROOT (only if it is a vcpkg git
# checkout: Visual Studio's developer environment points it at its bundled
# vcpkg) or ../vcpkg (the checkout MariaDB Shell uses, when the two are cloned
# side by side), in that order, and cloned there at the "builtin-baseline"
# commit of vcpkg.json if missing; a directory that exists and isn't a vcpkg
# checkout is never replaced. An existing checkout follows the baseline: each
# configure, also of an existing build directory, moves it to the baseline
# commit (fetching it if needed) and bootstraps vcpkg again when that commit
# needs a newer executable. -DVCPKG_GIT_TAG=<ref> pins it instead.
# A vcpkg toolchain file passed with -DCMAKE_TOOLCHAIN_FILE is used as is.

IF(NOT DEFINED WITH_VCPKG_TRIPLET AND NOT MARIADB_CONNECTOR_DIR)
  CMAKE_HOST_SYSTEM_INFORMATION(RESULT _vcpkg_host_arch QUERY OS_PLATFORM)
  IF(CMAKE_HOST_WIN32)
    # restd is x64 only on Windows (the JIT executor library), also when
    # cross-built on Windows on ARM; x64-windows is dynamic
    SET(_vcpkg_default_triplet "x64-windows")
  ELSEIF(CMAKE_HOST_APPLE AND _vcpkg_host_arch STREQUAL "arm64")
    SET(_vcpkg_default_triplet "arm64-osx-dynamic")
  ELSEIF(CMAKE_HOST_APPLE)
    SET(_vcpkg_default_triplet "x64-osx-dynamic")
  ELSEIF(_vcpkg_host_arch MATCHES "^(aarch64|arm64)$")
    SET(_vcpkg_default_triplet "arm64-linux-dynamic")
  ELSEIF(_vcpkg_host_arch MATCHES "^(x86_64|AMD64)$")
    SET(_vcpkg_default_triplet "x64-linux-dynamic")
  ELSE()
    MESSAGE(FATAL_ERROR
      "No vcpkg triplet known for ${_vcpkg_host_arch}: pass "
      "-DMARIADB_CONNECTOR_DIR=<Connector/C installation> or "
      "-DWITH_VCPKG_TRIPLET=<triplet>")
  ENDIF()
  SET(WITH_VCPKG_TRIPLET "${_vcpkg_default_triplet}" CACHE STRING
    "vcpkg triplet to get the dependencies with (OFF: no vcpkg)")
  MESSAGE(STATUS "MARIADB_CONNECTOR_DIR not set: dependencies from vcpkg, "
                 "triplet ${WITH_VCPKG_TRIPLET}")
ENDIF()

IF(NOT WITH_VCPKG_TRIPLET)
  RETURN()
ENDIF()

IF(NOT VCPKG_TARGET_TRIPLET)
  SET(VCPKG_TARGET_TRIPLET "${WITH_VCPKG_TRIPLET}"
    CACHE STRING "vcpkg target triplet" FORCE)
ENDIF()

# VCPKG_INSTALLED_DIR is the toolchain's install root, which holds one
# directory per triplet: it must not be the per-triplet prefix, or the
# toolchain installs into <root>/<triplet>/<triplet>.
SET(VCPKG_INSTALLED_DIR "${CMAKE_BINARY_DIR}/vcpkg_installed"
  CACHE PATH "vcpkg install root (holds one directory per triplet)" FORCE)
SET(VCPKG_INSTALLED_PREFIX "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}"
  CACHE PATH "Per-triplet vcpkg install prefix of this build" FORCE)

# The toolchain this file derived itself (cached at the end) is not the
# caller's: a re-configure goes through the steps below again, so a baseline
# bump in vcpkg.json moves the checkout and updates the vcpkg executable in an
# existing build directory too, rather than building against the old ports.
IF(CMAKE_TOOLCHAIN_FILE MATCHES "[Vv]cpkg"
   AND NOT (VCPKG_ROOT AND
            CMAKE_TOOLCHAIN_FILE STREQUAL "${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"))
  MESSAGE(STATUS "vcpkg: using ${CMAKE_TOOLCHAIN_FILE}, "
                 "triplet ${VCPKG_TARGET_TRIPLET}")
  RETURN()
ENDIF()

# The vcpkg commit: the "builtin-baseline" of vcpkg.json, so that the port
# versions and vcpkg's port scripts are from the same commit
SET(VCPKG_GIT_REPOSITORY "https://github.com/microsoft/vcpkg.git"
  CACHE STRING "Git URL of vcpkg, cloned if there is no checkout")
#
# The baseline is read on every configure, so VCPKG_GIT_TAG follows a bump of
# it in an existing build directory. Only a ref the caller pinned
# (-DVCPKG_GIT_TAG=...) is left alone. _VCPKG_GIT_TAG_DERIVED remembers what
# this file derived, which is how the two are told apart. A build directory
# configured before it existed holds the baseline it derived back then: a full
# commit id, with VCPKG_ROOT cached.
SET(_vcpkg_follow_baseline FALSE)
STRING(LENGTH "${VCPKG_GIT_TAG}" _vcpkg_tag_length)
IF(NOT VCPKG_GIT_TAG
   OR VCPKG_GIT_TAG STREQUAL "${_VCPKG_GIT_TAG_DERIVED}"
   OR (NOT DEFINED _VCPKG_GIT_TAG_DERIVED AND VCPKG_ROOT
       AND VCPKG_GIT_TAG MATCHES "^[0-9a-fA-F]+$" AND _vcpkg_tag_length EQUAL 40))
  SET(_vcpkg_follow_baseline TRUE)
  FILE(READ "${CMAKE_CURRENT_SOURCE_DIR}/vcpkg.json" _vcpkg_manifest)
  STRING(JSON _vcpkg_baseline ERROR_VARIABLE _vcpkg_json_error
         GET "${_vcpkg_manifest}" "builtin-baseline")
  IF(_vcpkg_json_error OR NOT _vcpkg_baseline MATCHES "^[0-9a-fA-F]+$")
    MESSAGE(FATAL_ERROR
      "No \"builtin-baseline\" commit in ${CMAKE_CURRENT_SOURCE_DIR}/vcpkg.json; "
      "pass -DVCPKG_GIT_TAG=<commit>")
  ENDIF()
  SET(VCPKG_GIT_TAG "${_vcpkg_baseline}"
    CACHE STRING "Git ref (branch, tag or commit) of vcpkg to clone" FORCE)
  SET(_VCPKG_GIT_TAG_DERIVED "${_vcpkg_baseline}" CACHE INTERNAL
    "VCPKG_GIT_TAG as derived from vcpkg.json (anything else was pinned)")
ENDIF()

# The environment's VCPKG_ROOT only when it is a vcpkg checkout: a Visual
# Studio developer environment sets it to the vcpkg bundled with Visual
# Studio (no git checkout, so no baseline commit, and under "Program Files",
# where ports built with autotools, ICU among them, fail on the space).
IF(VCPKG_ROOT)
  SET(_vcpkg_root "${VCPKG_ROOT}")
ELSEIF(NOT "$ENV{VCPKG_ROOT}" STREQUAL "" AND EXISTS "$ENV{VCPKG_ROOT}/.git")
  SET(_vcpkg_root "$ENV{VCPKG_ROOT}")
ELSE()
  IF(NOT "$ENV{VCPKG_ROOT}" STREQUAL "")
    MESSAGE(STATUS "vcpkg: ignoring VCPKG_ROOT=$ENV{VCPKG_ROOT} "
                   "(not a vcpkg git checkout)")
  ENDIF()
  SET(_vcpkg_root "${CMAKE_CURRENT_SOURCE_DIR}/../vcpkg")
ENDIF()
GET_FILENAME_COMPONENT(_vcpkg_root "${_vcpkg_root}" ABSOLUTE)

# Cloned only into a missing or empty directory: anything else there isn't
# ours to replace (the fallback below removes what the first clone created)
IF(NOT EXISTS "${_vcpkg_root}/.git" AND EXISTS "${_vcpkg_root}")
  FILE(GLOB _vcpkg_root_entries "${_vcpkg_root}/*")
  IF(_vcpkg_root_entries)
    MESSAGE(FATAL_ERROR
      "${_vcpkg_root} exists but is not a vcpkg git checkout: pass "
      "-DVCPKG_ROOT=<vcpkg checkout, or a missing or empty directory to "
      "clone vcpkg into>")
  ENDIF()
ENDIF()

IF(CMAKE_HOST_WIN32)
  SET(_vcpkg_bootstrap "${_vcpkg_root}/bootstrap-vcpkg.bat")
  SET(_vcpkg_exe "${_vcpkg_root}/vcpkg.exe")
ELSE()
  SET(_vcpkg_bootstrap "${_vcpkg_root}/bootstrap-vcpkg.sh")
  SET(_vcpkg_exe "${_vcpkg_root}/vcpkg")
ENDIF()

IF(NOT EXISTS "${_vcpkg_root}/.git")
  FIND_PACKAGE(Git REQUIRED)
  MESSAGE(STATUS "vcpkg: cloning ${VCPKG_GIT_REPOSITORY} at ${VCPKG_GIT_TAG} "
                 "into ${_vcpkg_root}")
  GET_FILENAME_COMPONENT(_vcpkg_parent "${_vcpkg_root}" DIRECTORY)
  FILE(MAKE_DIRECTORY "${_vcpkg_parent}")
  EXECUTE_PROCESS(
    COMMAND "${GIT_EXECUTABLE}" clone --progress --branch "${VCPKG_GIT_TAG}"
            "${VCPKG_GIT_REPOSITORY}" "${_vcpkg_root}"
    RESULT_VARIABLE _rc)
  IF(NOT _rc EQUAL 0)
    # --branch does not take a commit: clone the default branch and check out
    FILE(REMOVE_RECURSE "${_vcpkg_root}")
    EXECUTE_PROCESS(
      COMMAND "${GIT_EXECUTABLE}" clone --progress
              "${VCPKG_GIT_REPOSITORY}" "${_vcpkg_root}"
      RESULT_VARIABLE _rc)
    IF(NOT _rc EQUAL 0)
      MESSAGE(FATAL_ERROR "Failed to clone ${VCPKG_GIT_REPOSITORY}")
    ENDIF()
    EXECUTE_PROCESS(
      COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" checkout "${VCPKG_GIT_TAG}"
      RESULT_VARIABLE _rc)
    IF(NOT _rc EQUAL 0)
      MESSAGE(FATAL_ERROR "Failed to check out vcpkg ${VCPKG_GIT_TAG}")
    ENDIF()
  ENDIF()
ELSEIF(_vcpkg_follow_baseline)
  # A checkout cloned for an earlier baseline stays there unless moved: vcpkg
  # would then build the old ports, or, once the new baseline needs a newer
  # vcpkg executable, fail outright. Move it to the baseline commit, fetching
  # it if the checkout predates it. A pinned ref is the caller's business, and
  # a checkout with local changes is not ours to move.
  #
  # The checkout may be shared (../vcpkg is MariaDB Shell's too): each
  # configure moves it to its own baseline. vcpkg reads older baselines from
  # git history, so a build directory still on one keeps working.
  FIND_PACKAGE(Git REQUIRED)
  EXECUTE_PROCESS(
    COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" rev-parse HEAD
    OUTPUT_VARIABLE _vcpkg_head OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _rc)
  STRING(TOLOWER "${VCPKG_GIT_TAG}" _vcpkg_want)
  IF(_rc EQUAL 0 AND NOT _vcpkg_head STREQUAL _vcpkg_want)
    EXECUTE_PROCESS(
      COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" status --porcelain
              --untracked-files=no
      OUTPUT_VARIABLE _vcpkg_dirty OUTPUT_STRIP_TRAILING_WHITESPACE)
    IF(_vcpkg_dirty)
      MESSAGE(WARNING
        "${_vcpkg_root} is at ${_vcpkg_head}, not at the vcpkg.json baseline "
        "${VCPKG_GIT_TAG}, and has local changes, so it is left where it is. "
        "Commit or discard them and re-configure, or pass -DVCPKG_GIT_TAG to "
        "pin the checkout as it is.")
    ELSE()
      EXECUTE_PROCESS(
        COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" cat-file -e
                "${VCPKG_GIT_TAG}^{commit}"
        RESULT_VARIABLE _rc ERROR_QUIET)
      IF(NOT _rc EQUAL 0)
        # By id first: a clone made with --branch fetches only that branch
        # otherwise. GitHub serves any reachable commit by id; a server that
        # does not gets the plain fetch.
        MESSAGE(STATUS "vcpkg: fetching baseline ${VCPKG_GIT_TAG}")
        EXECUTE_PROCESS(
          COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" fetch origin "${VCPKG_GIT_TAG}"
          RESULT_VARIABLE _rc ERROR_QUIET)
        IF(NOT _rc EQUAL 0)
          EXECUTE_PROCESS(
            COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" fetch origin)
        ENDIF()
        EXECUTE_PROCESS(
          COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}" cat-file -e
                  "${VCPKG_GIT_TAG}^{commit}"
          RESULT_VARIABLE _rc ERROR_QUIET)
        IF(NOT _rc EQUAL 0)
          MESSAGE(FATAL_ERROR
            "Could not fetch the vcpkg baseline ${VCPKG_GIT_TAG} into "
            "${_vcpkg_root} from its 'origin' remote. Fetch it there yourself, "
            "or pass -DVCPKG_GIT_TAG to pin the checkout as it is.")
        ENDIF()
      ENDIF()
      MESSAGE(STATUS "vcpkg: moving ${_vcpkg_root} to baseline "
                     "${VCPKG_GIT_TAG} (was ${_vcpkg_head})")
      EXECUTE_PROCESS(
        COMMAND "${GIT_EXECUTABLE}" -C "${_vcpkg_root}"
                -c advice.detachedHead=false checkout -q "${VCPKG_GIT_TAG}"
        RESULT_VARIABLE _rc)
      IF(NOT _rc EQUAL 0)
        MESSAGE(FATAL_ERROR "Failed to check out vcpkg ${VCPKG_GIT_TAG}")
      ENDIF()
    ENDIF()
  ENDIF()
ENDIF()

# Bootstrapped unless the executable is there and is the release this checkout
# asks for. Each vcpkg commit names its tool release in
# scripts/vcpkg-tool-metadata.txt; a checkout moved to a newer baseline usually
# needs a newer one (an older executable rejects the newer tool data:
# "document schema version 2 is not supported").
SET(_vcpkg_need_bootstrap FALSE)
IF(NOT EXISTS "${_vcpkg_exe}")
  SET(_vcpkg_need_bootstrap TRUE)
ELSEIF(EXISTS "${_vcpkg_root}/scripts/vcpkg-tool-metadata.txt")
  FILE(STRINGS "${_vcpkg_root}/scripts/vcpkg-tool-metadata.txt" _vcpkg_tool_tag
       REGEX "^VCPKG_TOOL_RELEASE_TAG=")
  STRING(REGEX REPLACE "^VCPKG_TOOL_RELEASE_TAG=" "" _vcpkg_tool_tag
         "${_vcpkg_tool_tag}")
  EXECUTE_PROCESS(
    COMMAND "${_vcpkg_exe}" version
    OUTPUT_VARIABLE _vcpkg_exe_version ERROR_QUIET RESULT_VARIABLE _rc)
  IF(_vcpkg_tool_tag AND NOT (_rc EQUAL 0 AND
                              _vcpkg_exe_version MATCHES "version ${_vcpkg_tool_tag}"))
    MESSAGE(STATUS "vcpkg: the executable is not release ${_vcpkg_tool_tag}, "
                   "which this checkout needs: bootstrapping it again")
    SET(_vcpkg_need_bootstrap TRUE)
  ENDIF()
ENDIF()
IF(_vcpkg_need_bootstrap)
  MESSAGE(STATUS "vcpkg: bootstrapping ${_vcpkg_root}")
  IF(CMAKE_HOST_WIN32)
    SET(_vcpkg_bootstrap_cmd cmd /c "${_vcpkg_bootstrap}" -disableMetrics)
  ELSE()
    SET(_vcpkg_bootstrap_cmd "${_vcpkg_bootstrap}" -disableMetrics)
  ENDIF()
  EXECUTE_PROCESS(COMMAND ${_vcpkg_bootstrap_cmd}
    WORKING_DIRECTORY "${_vcpkg_root}"
    RESULT_VARIABLE _rc)
  IF(NOT _rc EQUAL 0)
    MESSAGE(FATAL_ERROR "vcpkg bootstrap failed (see the output above)")
  ENDIF()
ENDIF()

SET(VCPKG_ROOT "${_vcpkg_root}"
  CACHE PATH "Root of the vcpkg checkout of this build" FORCE)
SET(CMAKE_TOOLCHAIN_FILE "${_vcpkg_root}/scripts/buildsystems/vcpkg.cmake"
  CACHE FILEPATH "vcpkg toolchain file" FORCE)
MESSAGE(STATUS "vcpkg: ${VCPKG_ROOT}, triplet ${VCPKG_TARGET_TRIPLET}")
