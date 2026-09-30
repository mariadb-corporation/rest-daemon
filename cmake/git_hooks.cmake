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

# Activate the repository's git hooks for this clone.
#
# The hooks themselves are tracked in .githooks/ so they are reviewed and shared
# like any other source, but git only ever runs hooks from core.hooksPath or
# <git-dir>/hooks -- and neither can be set by repository content, since that
# would mean cloning a repository could execute its code. So every clone needs
# one local action, and doing it here means nobody has to remember it: configure
# the build and the hooks are live.
#
# A symlink per hook rather than pointing core.hooksPath at .githooks: hooksPath
# REPLACES the hook directory wholesale, so it would silently disable any hook a
# developer keeps in .git/hooks of their own. A link claims only the names we
# actually ship.
#
# Turn it off with -DINSTALL_GIT_HOOKS=OFF.

IF(NOT DEFINED INSTALL_GIT_HOOKS)
  SET(INSTALL_GIT_HOOKS ON CACHE BOOL
      "Point this clone's git hooks at the tracked ones in .githooks/")
ENDIF()

FUNCTION(_INSTALL_GIT_HOOKS)
  IF(NOT INSTALL_GIT_HOOKS)
    RETURN()
  ENDIF()

  SET(_hooks_src "${CMAKE_CURRENT_SOURCE_DIR}/.githooks")
  IF(NOT IS_DIRECTORY "${_hooks_src}")
    RETURN()
  ENDIF()

  FIND_PACKAGE(Git QUIET)
  IF(NOT GIT_EXECUTABLE)
    MESSAGE(STATUS "git not found; not activating the hooks in .githooks/")
    RETURN()
  ENDIF()

  # Ask git where its hooks live rather than assuming <source>/.git/hooks: that
  # is wrong for a worktree or a submodule (where .git is a file pointing
  # elsewhere) and for a repository configured with a separate git dir. A
  # non-zero result means this is not a checkout at all -- a source tarball, say
  # -- which is not a problem, there is just nothing to hook into.
  EXECUTE_PROCESS(
    COMMAND "${GIT_EXECUTABLE}" rev-parse --git-path hooks
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    OUTPUT_VARIABLE _hooks_dir
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE _rc)
  IF(NOT _rc EQUAL 0 OR NOT _hooks_dir)
    RETURN()
  ENDIF()

  # git prints this relative to the working directory unless it has a reason not
  # to (worktrees get an absolute path).
  IF(NOT IS_ABSOLUTE "${_hooks_dir}")
    SET(_hooks_dir "${CMAKE_CURRENT_SOURCE_DIR}/${_hooks_dir}")
  ENDIF()
  FILE(TO_CMAKE_PATH "${_hooks_dir}" _hooks_dir)

  # `--git-path hooks` honours core.hooksPath, so a developer who has already
  # pointed it at .githooks lands here with source and destination equal. Leave
  # that alone instead of trying to link a file onto itself.
  GET_FILENAME_COMPONENT(_hooks_dir_real "${_hooks_dir}" REALPATH)
  GET_FILENAME_COMPONENT(_hooks_src_real "${_hooks_src}" REALPATH)
  IF(_hooks_dir_real STREQUAL _hooks_src_real)
    MESSAGE(STATUS "git hooks: core.hooksPath already points at .githooks/")
    RETURN()
  ENDIF()

  FILE(GLOB _hooks RELATIVE "${_hooks_src}" "${_hooks_src}/*")
  FILE(MAKE_DIRECTORY "${_hooks_dir}")

  FOREACH(_hook ${_hooks})
    SET(_src "${_hooks_src}/${_hook}")
    SET(_dst "${_hooks_dir}/${_hook}")
    IF(IS_DIRECTORY "${_src}")
      CONTINUE()
    ENDIF()

    # Say so when a real file is being displaced: it may be something the
    # developer wrote, and it should not vanish without a word.
    IF(EXISTS "${_dst}" AND NOT IS_SYMLINK "${_dst}")
      MESSAGE(STATUS "git hooks: replacing existing ${_hook} with the tracked one")
    ENDIF()
    FILE(REMOVE "${_dst}")

    # A relative target keeps the link valid if the checkout is moved. Not
    # file(CREATE_LINK), which needs CMake 3.14 while this project still
    # supports 3.8 on some generators.
    FILE(RELATIVE_PATH _rel "${_hooks_dir}" "${_src}")
    EXECUTE_PROCESS(
      COMMAND "${CMAKE_COMMAND}" -E create_symlink "${_rel}" "${_dst}"
      RESULT_VARIABLE _link_rc
      ERROR_QUIET)

    IF(_link_rc EQUAL 0)
      MESSAGE(STATUS "git hooks: ${_hook} -> ${_rel}")
    ELSE()
      # Windows needs Developer Mode or elevation to create a symlink, so fall
      # back to a copy. file(COPY) carries the executable bit over, which the
      # hook needs on the platforms where that matters. The copy is refreshed on
      # every configure, so it cannot drift far from the tracked version -- but
      # it CAN be stale between configures, hence saying which one happened.
      FILE(COPY "${_src}" DESTINATION "${_hooks_dir}")
      IF(EXISTS "${_dst}")
        MESSAGE(STATUS "git hooks: ${_hook} copied (symlinks unavailable; "
                       "re-run cmake after changing .githooks/${_hook})")
      ELSE()
        MESSAGE(WARNING "git hooks: could not install ${_hook} into ${_hooks_dir}")
      ENDIF()
    ENDIF()
  ENDFOREACH()
ENDFUNCTION()

_INSTALL_GIT_HOOKS()
