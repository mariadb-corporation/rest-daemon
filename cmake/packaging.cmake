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
SET(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_SOURCE_DIR}/LICENSE.router")
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
ELSEIF(WIN32)
  SET(CPACK_GENERATOR "ZIP")
ELSE()
  SET(CPACK_GENERATOR "TGZ")
ENDIF()
# the archives unpack into <name>-<version>-<platform>/
SET(CPACK_INCLUDE_TOPLEVEL_DIRECTORY ON)

SET(CPACK_SOURCE_GENERATOR "TGZ")
SET(CPACK_SOURCE_PACKAGE_FILE_NAME "${MRSD_PROGRAM_NAME}-${MRSD_VERSION}-src")
SET(CPACK_SOURCE_IGNORE_FILES "/\\\\.git/" "/build[^/]*/" "__pycache__")

INCLUDE(CPack)
