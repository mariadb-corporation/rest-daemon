# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2.0,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

# Install-time script: copies the third-party runtime libraries that the
# packages bundle into the installed tree and, on macOS, makes the installed
# binaries find them through @rpath.
#
# Set by the INSTALL(CODE) rule in CMakeLists.txt:
#   BUNDLE_NAME_REGEXES  names of the libraries to bundle (regexes)
#   BUNDLE_SEARCH_DIRS   where to find them
#   BUNDLE_DEST          install-prefix relative directory to copy them to
#   BUNDLE_SCAN_DIRS     install-prefix relative directories with the binaries
#                        whose dependencies are bundled
#   BUNDLE_AVOID_DIR     on a name clash, prefer copies outside this directory
#                        (the client package's private OpenSSL: the binaries
#                        link the build's OpenSSL, and one copy is shipped)

SET(_prefix "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}")
SET(_dest "${_prefix}/${BUNDLE_DEST}")

# the installed binaries
SET(_executables)
SET(_modules)
FOREACH(_dir ${BUNDLE_SCAN_DIRS})
  FILE(GLOB _files LIST_DIRECTORIES false "${_prefix}/${_dir}/*")
  FOREACH(_f ${_files})
    IF(IS_SYMLINK "${_f}")
      CONTINUE()
    ENDIF()
    IF(_f MATCHES "\\.(so|dylib|dll)$" OR _f MATCHES "\\.so\\.[0-9.]+$")
      LIST(APPEND _modules "${_f}")
    ELSEIF(_f MATCHES "\\.exe$" OR (NOT WIN32 AND NOT _f MATCHES "\\."))
      LIST(APPEND _executables "${_f}")
    ENDIF()
  ENDFOREACH()
ENDFOREACH()

FILE(GET_RUNTIME_DEPENDENCIES
  EXECUTABLES ${_executables}
  MODULES ${_modules}
  DIRECTORIES ${BUNDLE_SEARCH_DIRS}
  PRE_INCLUDE_REGEXES ${BUNDLE_NAME_REGEXES}
  PRE_EXCLUDE_REGEXES ".*"
  POST_INCLUDE_REGEXES ${BUNDLE_NAME_REGEXES}
  POST_EXCLUDE_REGEXES ".*"
  RESOLVED_DEPENDENCIES_VAR _resolved
  UNRESOLVED_DEPENDENCIES_VAR _unresolved
  CONFLICTING_DEPENDENCIES_PREFIX _conflicts)

# macOS resolves @rpath/ references only through the binary's rpaths, which
# don't point at the build machine's libraries: look those up by name
FOREACH(_dep ${_unresolved})
  GET_FILENAME_COMPONENT(_name "${_dep}" NAME)
  SET(_found)
  FOREACH(_dir ${BUNDLE_SEARCH_DIRS})
    IF(NOT _found AND EXISTS "${_dir}/${_name}")
      SET(_found "${_dir}/${_name}")
    ENDIF()
  ENDFOREACH()
  IF(NOT _found)
    MESSAGE(FATAL_ERROR "bundled library not found: ${_dep}")
  ENDIF()
  LIST(APPEND _resolved "${_found}")
ENDFOREACH()

FOREACH(_name ${_conflicts_FILENAMES})
  SET(_pick)
  FOREACH(_candidate ${_conflicts_${_name}})
    FILE(REAL_PATH "${_candidate}" _real_candidate)
    IF(NOT _pick AND NOT _real_candidate MATCHES "^${BUNDLE_AVOID_DIR}/")
      SET(_pick "${_candidate}")
    ENDIF()
  ENDFOREACH()
  IF(NOT _pick)
    LIST(GET _conflicts_${_name} 0 _pick)
  ENDIF()
  LIST(APPEND _resolved "${_pick}")
ENDFOREACH()

# copy them, under the name the binaries refer to
SET(_bundled_names)
FOREACH(_lib ${_resolved})
  GET_FILENAME_COMPONENT(_name "${_lib}" NAME)
  FILE(REAL_PATH "${_lib}" _real)
  MESSAGE(STATUS "Bundling: ${_dest}/${_name} (${_real})")
  FILE(MAKE_DIRECTORY "${_dest}")
  FILE(COPY_FILE "${_real}" "${_dest}/${_name}")
  FILE(CHMOD "${_dest}/${_name}" PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)
  LIST(APPEND _bundled_names "${_name}")
ENDFOREACH()

IF(WIN32)
  # the DLLs are copied next to the executables
  RETURN()
ENDIF()

IF(NOT APPLE)
  # ELF: RUNPATH applies only to an object's own dependencies. The bundled
  # libraries get RUNPATH $ORIGIN, so that their dependencies (libssl ->
  # libcrypto, libicuuc -> libicudata, libmariadb -> libssl) are the
  # bundled copies too, not the system's.
  IF(_bundled_names)
    FIND_PROGRAM(_patchelf patchelf)
    IF(NOT _patchelf)
      MESSAGE(FATAL_ERROR
        "patchelf is needed to bundle libraries (apt install patchelf)")
    ENDIF()
  ENDIF()
  FOREACH(_name ${_bundled_names})
    EXECUTE_PROCESS(
      COMMAND ${_patchelf} --set-rpath "$ORIGIN" "${_dest}/${_name}"
      COMMAND_ERROR_IS_FATAL ANY)
  ENDFOREACH()
  RETURN()
ENDIF()

# --- macOS: point the references at @rpath, drop absolute rpaths, re-sign ----
FIND_PROGRAM(_otool otool REQUIRED)
FIND_PROGRAM(_install_name_tool install_name_tool REQUIRED)
FIND_PROGRAM(_codesign codesign REQUIRED)

SET(_bundled_files)
FOREACH(_name ${_bundled_names})
  LIST(APPEND _bundled_files "${_dest}/${_name}")
ENDFOREACH()

FOREACH(_f ${_executables} ${_modules} ${_bundled_files})
  SET(_args)

  # references to bundled libraries by absolute or @loader_path path
  EXECUTE_PROCESS(COMMAND ${_otool} -L "${_f}" OUTPUT_VARIABLE _deps
    COMMAND_ERROR_IS_FATAL ANY)
  STRING(REPLACE "\n" ";" _deps "${_deps}")
  FOREACH(_line ${_deps})
    IF(NOT _line MATCHES "^[ \t]+([^ ]+) \\(")
      CONTINUE()
    ENDIF()
    SET(_ref "${CMAKE_MATCH_1}")
    GET_FILENAME_COMPONENT(_name "${_ref}" NAME)
    IF(_name IN_LIST _bundled_names AND NOT _ref MATCHES "^@rpath/")
      LIST(APPEND _args -change "${_ref}" "@rpath/${_name}")
    ENDIF()
  ENDFOREACH()

  # absolute rpaths point into the build machine
  EXECUTE_PROCESS(COMMAND ${_otool} -l "${_f}" OUTPUT_VARIABLE _loads
    COMMAND_ERROR_IS_FATAL ANY)
  STRING(REGEX MATCHALL "path /[^ \n]+" _abs_rpaths "${_loads}")
  FOREACH(_rp ${_abs_rpaths})
    STRING(REGEX REPLACE "^path " "" _rp "${_rp}")
    LIST(APPEND _args -delete_rpath "${_rp}")
  ENDFOREACH()

  IF(_f IN_LIST _bundled_files)
    GET_FILENAME_COMPONENT(_name "${_f}" NAME)
    LIST(APPEND _args -id "@rpath/${_name}")
    IF(NOT _loads MATCHES "path @loader_path ")
      LIST(APPEND _args -add_rpath "@loader_path")
    ENDIF()
  ENDIF()

  IF(_args)
    EXECUTE_PROCESS(COMMAND ${_install_name_tool} ${_args} "${_f}"
      ERROR_VARIABLE _err RESULT_VARIABLE _res)
    IF(NOT _res EQUAL 0)
      MESSAGE(FATAL_ERROR "install_name_tool ${_f}: ${_err}")
    ENDIF()
    # the changes invalidate the (ad-hoc) signature
    EXECUTE_PROCESS(COMMAND ${_codesign} --force --sign - "${_f}"
      OUTPUT_QUIET ERROR_QUIET COMMAND_ERROR_IS_FATAL ANY)
  ENDIF()
ENDFOREACH()
