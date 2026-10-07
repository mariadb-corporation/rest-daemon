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

# Settings for building MySQL Router

# General
# mrsd: the program and product names are set here only; the executables,
# the default configuration and log file names, the Windows service and the
# MRS metadata registration derive from them. Plain variables, so that a
# change also reaches existing build directories.
SET(MRSD_PROGRAM_NAME "mariadb-restd")
SET(MYSQL_ROUTER_NAME "MariaDB REST Service Daemon")
SET(MYSQL_ROUTER_INI "${MRSD_PROGRAM_NAME}.conf")

# package metadata (cmake/packaging.cmake)
SET(MRSD_PACKAGE_VENDOR "MariaDB plc")
SET(MRSD_PACKAGE_CONTACT "MariaDB plc <maintainer address not set yet>"
  CACHE STRING "Maintainer of the packages: Name <email>")
SET(MRSD_PACKAGE_SUMMARY
  "standalone daemon for the MySQL REST Service (MRS)")
SET(MRSD_PACKAGE_DESCRIPTION
  "${MYSQL_ROUTER_NAME} serves REST endpoints for MySQL tables, views, \
stored procedures, functions and scripts, as defined in the MySQL REST \
Service metadata schema of a MySQL server.")
SET(MRSD_PACKAGE_HOMEPAGE "https://mariadb.com"
  CACHE STRING "Homepage shown in the packages")

# MySQL Harness
SET(HARNESS_NAME "mysqlrouter" CACHE STRING "Name of Harness")

# Hidden configuration flag for developer-only OpenSSL alert-symbol tests.
# These tests depend on non-public OpenSSL symbols/APIs (currently buildable
# with OpenSSL 3.6.1), so they are not suitable for the regular regression
# suite. We keep them in-tree as documentation/reference for alert behavior.
SET(MYSQL_ROUTER_ENABLE_OPENSSL_INTERNAL_ALERT_TESTS OFF
  CACHE INTERNAL
  "Enable developer-only OpenSSL alert-symbol documentation tests")
