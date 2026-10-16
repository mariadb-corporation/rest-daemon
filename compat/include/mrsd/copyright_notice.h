/* Copyright (c) 2026, MariaDB plc.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License, version 2.0,
   as published by the Free Software Foundation.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

#ifndef MRSD_COPYRIGHT_NOTICE_INCLUDED
#define MRSD_COPYRIGHT_NOTICE_INCLUDED

// restd: the copyright notice of the help screens, worded as MariaDB Shell's
// welcome banner; it replaces ORACLE_WELCOME_COPYRIGHT_NOTICE of the vendored
// welcome_copyright_notice.h, which still supplies the current year.
#include "welcome_copyright_notice.h"  // COPYRIGHT_NOTICE_CURRENT_YEAR

#define MRSD_WELCOME_COPYRIGHT_NOTICE(first_year)                   \
  "Copyright (c) " first_year ", " COPYRIGHT_NOTICE_CURRENT_YEAR    \
  ", Oracle, MariaDB plc and others.\n"

#endif  // MRSD_COPYRIGHT_NOTICE_INCLUDED
