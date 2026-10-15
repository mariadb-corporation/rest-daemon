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

# CPack packages ("cmake --build <dir> --target package"):
#   STANDALONE layout: tar.gz (Linux, macOS), ZIP + MSI (Windows)
#   SYSTEM layout:     deb + rpm (Linux)
# Names and metadata come from cmake/settings.cmake; the version from VERSION.

SET(CPACK_PACKAGE_NAME "${MRSD_PROGRAM_NAME}")
SET(CPACK_PACKAGE_VENDOR "${MRSD_PACKAGE_VENDOR}")
SET(CPACK_PACKAGE_CONTACT "${MRSD_PACKAGE_CONTACT}")
SET(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${MRSD_PACKAGE_SUMMARY}")
SET(CPACK_PACKAGE_DESCRIPTION "${MRSD_PACKAGE_DESCRIPTION}")
SET(CPACK_PACKAGE_HOMEPAGE_URL "${MRSD_PACKAGE_HOMEPAGE}")
SET(CPACK_PACKAGE_VERSION "${MRSD_VERSION}")
SET(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_SOURCE_DIR}/LICENSE")
SET(CPACK_RESOURCE_FILE_README "${CMAKE_SOURCE_DIR}/README.md")
SET(CPACK_STRIP_FILES OFF)  # keep symbols for the stack traces

# platform part of the file names: linux-<arch>, macos-<arch>, windows-x64
IF(WIN32)
  SET(_platform "windows-x64")
ELSEIF(APPLE)
  SET(_platform "macos-${MRSD_TARGET_ARCH}")
ELSE()
  SET(_platform "linux-${MRSD_TARGET_ARCH}")
ENDIF()
SET(CPACK_PACKAGE_FILE_NAME
  "${MRSD_PROGRAM_NAME}-${MRSD_VERSION}-${_platform}")

IF(INSTALL_LAYOUT STREQUAL "SYSTEM")
  SET(CPACK_GENERATOR "DEB;RPM")
  SET(CPACK_PACKAGING_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

  # systemd unit, service account (sysusers.d), folders (tmpfiles.d) and the
  # install/remove scripts shared by deb and rpm
  SET(_src "${CMAKE_SOURCE_DIR}/packaging/linux")
  SET(_gen "${CMAKE_BINARY_DIR}/packaging/linux")
  FOREACH(_f service sysusers.conf tmpfiles.conf)
    CONFIGURE_FILE("${_src}/${_f}.in" "${_gen}/${_f}" @ONLY)
  ENDFOREACH()
  INSTALL(FILES "${_gen}/service" DESTINATION lib/systemd/system
    RENAME ${MRSD_PROGRAM_NAME}.service COMPONENT Router)
  INSTALL(FILES "${_gen}/sysusers.conf" DESTINATION lib/sysusers.d
    RENAME ${MRSD_PROGRAM_NAME}.conf COMPONENT Router)
  INSTALL(FILES "${_gen}/tmpfiles.conf" DESTINATION lib/tmpfiles.d
    RENAME ${MRSD_PROGRAM_NAME}.conf COMPONENT Router)
  FOREACH(_f postinst prerm postrm)
    CONFIGURE_FILE("${_src}/${_f}.in" "${_gen}/${_f}" @ONLY
      FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                       GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
  ENDFOREACH()

  # deb
  SET(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
  SET(CPACK_DEBIAN_PACKAGE_SECTION "database")
  SET(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
  # libraries the package ships itself
  SET(CPACK_DEBIAN_PACKAGE_SHLIBDEPS_PRIVATE_DIRS
    "${CMAKE_INSTALL_PREFIX}/${ROUTER_INSTALL_LIBDIR}"
    "${CMAKE_INSTALL_PREFIX}/${ROUTER_INSTALL_PLUGINDIR}")
  SET(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA
    "${_gen}/postinst" "${_gen}/prerm" "${_gen}/postrm")
  SET(CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION TRUE)

  # rpm
  SET(CPACK_RPM_FILE_NAME RPM-DEFAULT)
  SET(CPACK_RPM_PACKAGE_LICENSE "GPL-2.0-only")
  SET(CPACK_RPM_PACKAGE_GROUP "Applications/Databases")
  SET(CPACK_RPM_PACKAGE_URL "${MRSD_PACKAGE_HOMEPAGE}")
  SET(CPACK_RPM_POST_INSTALL_SCRIPT_FILE "${_gen}/postinst")
  SET(CPACK_RPM_PRE_UNINSTALL_SCRIPT_FILE "${_gen}/prerm")
  SET(CPACK_RPM_POST_UNINSTALL_SCRIPT_FILE "${_gen}/postrm")
  # no automatic provides/requires for what the package ships itself
  # (libmariadb, libjitexecutor, the internal libraries and the plugins)
  SET(CPACK_RPM_SPEC_MORE_DEFINE
"%global __provides_exclude_from ^${CMAKE_INSTALL_PREFIX}/lib/${MRSD_PROGRAM_NAME}/.*$
%global __requires_exclude ^(lib(mariadb|jitexecutor|mysqlharness|mysqlrouter)[^(]*|[a-z_]+[.]so)[(]")
  SET(CPACK_RPM_EXCLUDE_FROM_AUTO_FILELIST_ADDITION
    /usr/lib/systemd /usr/lib/systemd/system /usr/lib/sysusers.d
    /usr/lib/tmpfiles.d /usr/share/doc)
ELSEIF(WIN32)
  SET(CPACK_GENERATOR "ZIP")
  # the MSVC runtime DLLs next to the executables, no separate redistributable
  SET(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${ROUTER_INSTALL_BINDIR}")
  SET(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT Router)
  INCLUDE(InstallRequiredSystemLibraries)
ELSE()
  SET(CPACK_GENERATOR "TGZ")
ENDIF()
# the archives unpack into <name>-<version>-<platform>/
SET(CPACK_INCLUDE_TOPLEVEL_DIRECTORY ON)

SET(CPACK_SOURCE_GENERATOR "TGZ")
SET(CPACK_SOURCE_PACKAGE_FILE_NAME "${MRSD_PROGRAM_NAME}-${MRSD_VERSION}-src")
SET(CPACK_SOURCE_IGNORE_FILES "/\\\\.git/" "/build[^/]*/" "__pycache__")

INCLUDE(CPack)
