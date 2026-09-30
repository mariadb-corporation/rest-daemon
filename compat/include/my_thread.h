/*
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; version 2 of the License.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA
*/

// Subset of the MySQL server's my_thread.h used by mrsd.
//
// The server header belongs to mysys; only my_thread_self_setname() is used,
// implemented in compat/src/thread_name.cc.

#ifndef MY_THREAD_INCLUDED
#define MY_THREAD_INCLUDED

/**
 * set the name of the current thread (visible in debuggers, top, ...).
 *
 * Linux truncates names to 15 characters.
 */
void my_thread_self_setname(const char *name);

#endif
