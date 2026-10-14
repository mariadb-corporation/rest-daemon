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

# Build the JIT executor library (ext/polyglot) at configure time:
#
#   -DWITH_JIT_EXECUTOR=ON
#
# downloads GraalVM CE for JDK 23.0.1 and Maven, clones the one directory of
# the Graal sources the build copies (substratevm/src/
# org.graalvm.polyglot.nativeapi, tag jdk-23.0.1), all into RESTD_DEPS_DIR
# (default ../restd-deps, outside the build directory), runs `mvn package` in
# ext/polyglot and sets MRS_JIT_EXECUTOR_LIB to its output,
# ext/polyglot/polyglot-nativeapi-native-library/target.
#
# The build runs again only when its inputs change (the versions, the patch,
# the poms): a stamp file in the output directory records them. It takes a few
# minutes, and native-image asks for a 20 GB heap (-J-Xmx20g in the pom).
# On Windows, configure from a vcvars64 environment: native-image needs it.
#
# An explicit -DMRS_JIT_EXECUTOR_LIB=<dir> is used as is.

OPTION(WITH_JIT_EXECUTOR
  "Build the JIT executor library from ext/polyglot (downloads GraalVM)" OFF)
IF(NOT WITH_JIT_EXECUTOR OR MRS_JIT_EXECUTOR_LIB)
  RETURN()
ENDIF()

SET(RESTD_DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../restd-deps" CACHE PATH
  "Where the JIT executor build tools (GraalVM, Maven, Graal sources) go")
GET_FILENAME_COMPONENT(_deps "${RESTD_DEPS_DIR}" ABSOLUTE)

SET(_graal_tag "jdk-23.0.1")
SET(_graal_commit "4d9a08f482271b778fb72171d80e3970c034924f")
SET(_graalvm_dir "graalvm-community-openjdk-23.0.1+11.1")
SET(_maven_version "3.9.9")
SET(_maven_sha512 "a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b")

# GraalVM release assets and their SHA-256 (the release's .sha256 files);
# the platforms are those of the profiles in ext/polyglot/pom.xml
CMAKE_HOST_SYSTEM_INFORMATION(RESULT _arch QUERY OS_PLATFORM)
IF(CMAKE_HOST_APPLE AND _arch STREQUAL "arm64")
  SET(_graalvm_platform "macos-aarch64")
  SET(_graalvm_sha256 "d142ecf3d36775e457cdfe67e31982821dfe2d75ade28083990be19ee955f48f")
ELSEIF(CMAKE_HOST_APPLE)
  SET(_graalvm_platform "macos-x64")
  SET(_graalvm_sha256 "d8206c29232a68908bbce146012925c52f060722fe2fc2dbb41fe17bd906b210")
ELSEIF(CMAKE_HOST_WIN32)
  SET(_graalvm_platform "windows-x64")
  SET(_graalvm_sha256 "be5fe8f734476469f364329d9126c365a35d245755f3fc17a583e3a0f3688d38")
ELSEIF(_arch MATCHES "^(aarch64|arm64)$")
  SET(_graalvm_platform "linux-aarch64")
  SET(_graalvm_sha256 "5a456db9162a89be5fadd50e703c19313d25ef7f5043b750b639cd0460335e60")
ELSEIF(_arch MATCHES "^(x86_64|AMD64)$")
  SET(_graalvm_platform "linux-x64")
  SET(_graalvm_sha256 "e26a0a74064b1689c056b5f24d7cc3b271f57f576be063b139d27aafa1322951")
ELSE()
  MESSAGE(FATAL_ERROR "WITH_JIT_EXECUTOR: no GraalVM for ${_arch}")
ENDIF()
IF(CMAKE_HOST_WIN32)
  SET(_graalvm_ext "zip")
  SET(_java_home "${_deps}/${_graalvm_dir}")
  SET(_mvn "${_deps}/apache-maven-${_maven_version}/bin/mvn.cmd")
ELSE()
  SET(_graalvm_ext "tar.gz")
  SET(_mvn "${_deps}/apache-maven-${_maven_version}/bin/mvn")
  IF(CMAKE_HOST_APPLE)
    SET(_java_home "${_deps}/${_graalvm_dir}/Contents/Home")
  ELSE()
    SET(_java_home "${_deps}/${_graalvm_dir}")
  ENDIF()
ENDIF()

# _jit_fetch(<dir> <url> <algo> <hash>): download <url> and unpack it into
# RESTD_DEPS_DIR, unless <dir> is already there
FUNCTION(_jit_fetch dir url algo hash)
  IF(EXISTS "${_deps}/${dir}")
    RETURN()
  ENDIF()
  GET_FILENAME_COMPONENT(_name "${url}" NAME)
  SET(_archive "${_deps}/downloads/${_name}")
  MESSAGE(STATUS "WITH_JIT_EXECUTOR: downloading ${url}")
  FILE(DOWNLOAD "${url}" "${_archive}"
    EXPECTED_HASH ${algo}=${hash} STATUS _status)
  LIST(GET _status 0 _rc)
  IF(NOT _rc EQUAL 0)
    MESSAGE(FATAL_ERROR "Download of ${url} failed: ${_status}")
  ENDIF()
  FILE(ARCHIVE_EXTRACT INPUT "${_archive}" DESTINATION "${_deps}")
  IF(NOT EXISTS "${_deps}/${dir}")
    MESSAGE(FATAL_ERROR "${_archive} did not unpack to ${_deps}/${dir}")
  ENDIF()
  FILE(REMOVE "${_archive}")
ENDFUNCTION()

_jit_fetch("${_graalvm_dir}"
  "https://github.com/graalvm/graalvm-ce-builds/releases/download/${_graal_tag}/graalvm-community-${_graal_tag}_${_graalvm_platform}_bin.${_graalvm_ext}"
  SHA256 "${_graalvm_sha256}")
_jit_fetch("apache-maven-${_maven_version}"
  "https://archive.apache.org/dist/maven/maven-3/${_maven_version}/binaries/apache-maven-${_maven_version}-bin.tar.gz"
  SHA512 "${_maven_sha512}")

# the Graal sources: only the directory the build copies (a sparse clone)
SET(_graal_src "${_deps}/graal-${_graal_tag}")
FIND_PACKAGE(Git REQUIRED)
IF(NOT EXISTS "${_graal_src}/substratevm/src/org.graalvm.polyglot.nativeapi")
  MESSAGE(STATUS "WITH_JIT_EXECUTOR: cloning the Graal sources at ${_graal_tag}")
  FILE(REMOVE_RECURSE "${_graal_src}")
  EXECUTE_PROCESS(
    COMMAND "${GIT_EXECUTABLE}" -c advice.detachedHead=false clone --quiet
            --depth 1 --branch ${_graal_tag} --filter=blob:none --sparse
            https://github.com/oracle/graal.git "${_graal_src}"
    COMMAND_ERROR_IS_FATAL ANY)
  EXECUTE_PROCESS(
    COMMAND "${GIT_EXECUTABLE}" -C "${_graal_src}" sparse-checkout set
            substratevm/src/org.graalvm.polyglot.nativeapi
    COMMAND_ERROR_IS_FATAL ANY)
ENDIF()
EXECUTE_PROCESS(
  COMMAND "${GIT_EXECUTABLE}" -C "${_graal_src}" rev-parse HEAD
  OUTPUT_VARIABLE _head OUTPUT_STRIP_TRAILING_WHITESPACE)
IF(NOT _head STREQUAL _graal_commit)
  MESSAGE(FATAL_ERROR "${_graal_src} is at ${_head}, expected ${_graal_tag} "
                      "(${_graal_commit}); remove it to clone it again")
ENDIF()

# the build, unless the stamp of its inputs matches
SET(_polyglot "${CMAKE_CURRENT_SOURCE_DIR}/ext/polyglot")
SET(_out "${_polyglot}/polyglot-nativeapi-native-library/target")
SET(_stamp_text "${_graalvm_dir} ${_graalvm_platform} maven ${_maven_version} graal ${_graal_commit}")
FOREACH(_input pom.xml polyglot-nativeapi/pom.xml
               polyglot-nativeapi-native-library/pom.xml
               polyglot-nativeapi/patches/enhancements.patch)
  FILE(SHA256 "${_polyglot}/${_input}" _hash)
  STRING(APPEND _stamp_text "\n${_input} ${_hash}")
ENDFOREACH()
SET(_stamp "${_out}/restd-build-stamp.txt")
IF(EXISTS "${_stamp}")
  FILE(READ "${_stamp}" _old_stamp)
ENDIF()

IF(NOT _old_stamp STREQUAL _stamp_text OR
   NOT EXISTS "${_out}/polyglot_api.h")
  # from scratch: with the copied Graal sources still there, `mvn package`
  # skips copying and patching them and builds an unpatched library
  FILE(REMOVE_RECURSE
    "${_polyglot}/polyglot-nativeapi/src/main/java/org"
    "${_polyglot}/polyglot-nativeapi/src/main/resources"
    "${_polyglot}/polyglot-nativeapi/target"
    "${_out}")
  MESSAGE(STATUS "WITH_JIT_EXECUTOR: building the JIT executor library "
                 "(mvn package, a few minutes; log: "
                 "${CMAKE_BINARY_DIR}/jit-executor-build.log)")
  IF(CMAKE_HOST_WIN32)
    SET(_path "${_java_home}/bin;$ENV{PATH}")
  ELSE()
    SET(_path "${_java_home}/bin:$ENV{PATH}")
  ENDIF()
  EXECUTE_PROCESS(
    COMMAND ${CMAKE_COMMAND} -E env
            "JAVA_HOME=${_java_home}" "GRAALJDK_ROOT=${_graal_src}"
            "PATH=${_path}"
            "${_mvn}" -B package
    WORKING_DIRECTORY "${_polyglot}"
    OUTPUT_FILE "${CMAKE_BINARY_DIR}/jit-executor-build.log"
    ERROR_FILE "${CMAKE_BINARY_DIR}/jit-executor-build.log"
    RESULT_VARIABLE _rc)
  IF(NOT _rc EQUAL 0)
    MESSAGE(FATAL_ERROR "The JIT executor library build failed, see "
                        "${CMAKE_BINARY_DIR}/jit-executor-build.log")
  ENDIF()
  FILE(STRINGS "${_polyglot}/polyglot-nativeapi/target/patches-applied.txt"
    _applied)
  IF(NOT "enhancements.patch" IN_LIST _applied)
    MESSAGE(FATAL_ERROR "The JIT executor library was built without "
                        "polyglot-nativeapi/patches/enhancements.patch")
  ENDIF()
  FILE(WRITE "${_stamp}" "${_stamp_text}")
ENDIF()

# a normal variable, so that the next configure checks the stamp again
SET(MRS_JIT_EXECUTOR_LIB "${_out}")
MESSAGE(STATUS "WITH_JIT_EXECUTOR: ${MRS_JIT_EXECUTOR_LIB}")
