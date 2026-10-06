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

# Install layouts. The directory names derive from MRSD_PROGRAM_NAME
# (cmake/settings.cmake).
#
# STANDALONE: a relocatable tree for the tarballs, the Windows ZIP and the
#   MSI; the compiled-in defaults are relative to the executable
#   (cmake/paths.cmake: "{origin}/..").
#     bin/                       executables (Windows: also the DLLs)
#     lib/<prog>/                plugins (Windows: lib/)
#     lib/<prog>/private/        libraries (Linux; macOS and Windows: lib/)
#     docs/                      README, license, sample configuration
#     run/, var/lib/<prog>/      runtime and data folders
#
# SYSTEM: the deb/rpm layout, with CMAKE_INSTALL_PREFIX=/usr.
#     /usr/bin/                  executables
#     /usr/lib/<prog>/           plugins
#     /usr/lib/<prog>/private/   libraries
#     /usr/share/doc/<prog>/     README, license, sample configuration
#     /etc/<prog>/               configuration
#     /var/lib/<prog>/, /var/log/<prog>/, /run/<prog>/

SET(INSTALL_LAYOUT "STANDALONE" CACHE STRING
  "Install layout: STANDALONE (tarballs, ZIP, MSI) or SYSTEM (deb/rpm)")
SET_PROPERTY(CACHE INSTALL_LAYOUT PROPERTY STRINGS STANDALONE SYSTEM)
IF(NOT INSTALL_LAYOUT MATCHES "^(STANDALONE|SYSTEM)$")
  MESSAGE(FATAL_ERROR
    "INSTALL_LAYOUT must be STANDALONE or SYSTEM, not '${INSTALL_LAYOUT}'")
ENDIF()
IF(INSTALL_LAYOUT STREQUAL "SYSTEM" AND WIN32)
  MESSAGE(FATAL_ERROR "INSTALL_LAYOUT=SYSTEM is for Linux packages")
ENDIF()

SET(ROUTER_INSTALL_LAYOUT "${INSTALL_LAYOUT}")
SET(ROUTER_INSTALL_BINDIR "bin")

IF(INSTALL_LAYOUT STREQUAL "SYSTEM")
  SET(ROUTER_INSTALL_PLUGINDIR   "lib/${MRSD_PROGRAM_NAME}")
  SET(ROUTER_INSTALL_LIBDIR      "lib/${MRSD_PROGRAM_NAME}/private")
  SET(ROUTER_INSTALL_DOCDIR      "share/doc/${MRSD_PROGRAM_NAME}")
  SET(ROUTER_INSTALL_CONFIGDIR   "/etc/${MRSD_PROGRAM_NAME}")
  SET(ROUTER_INSTALL_DATADIR     "/var/lib/${MRSD_PROGRAM_NAME}")
  SET(ROUTER_INSTALL_LOGDIR      "/var/log/${MRSD_PROGRAM_NAME}")
  SET(ROUTER_INSTALL_RUNTIMEDIR  "/run/${MRSD_PROGRAM_NAME}")
ELSE()
  IF(WIN32)
    SET(ROUTER_INSTALL_PLUGINDIR "lib")
  ELSE()
    SET(ROUTER_INSTALL_PLUGINDIR "lib/${MRSD_PROGRAM_NAME}")
  ENDIF()
  IF(LINUX)
    SET(ROUTER_INSTALL_LIBDIR    "lib/${MRSD_PROGRAM_NAME}/private")
  ELSE()
    SET(ROUTER_INSTALL_LIBDIR    "lib")
  ENDIF()
  SET(ROUTER_INSTALL_DOCDIR      "docs")
  SET(ROUTER_INSTALL_CONFIGDIR   ".")
  SET(ROUTER_INSTALL_DATADIR     "var/lib/${MRSD_PROGRAM_NAME}")
  SET(ROUTER_INSTALL_LOGDIR      ".")
  SET(ROUTER_INSTALL_RUNTIMEDIR  "run")
ENDIF()

SET(INSTALL_BINDIR "bin")
SET(INSTALL_LIBDIR "lib")
SET(INSTALL_PRIV_LIBDIR "${ROUTER_INSTALL_LIBDIR}")
SET(INSTALL_INCLUDE_DIR "include")
SET(INSTALL_CONFIGDIR "${ROUTER_INSTALL_CONFIGDIR}")
SET(HARNESS_INSTALL_INCLUDE_PREFIX "include/mysql")
