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

// Subset of the MySQL server's my_stacktrace.h used by the harness crash
// handler (harness/src/signal_handler.cc); implemented in
// compat/src/stacktrace.cc.

#ifndef MY_STACKTRACE_INCLUDED
#define MY_STACKTRACE_INCLUDED

#include <cstddef>

#ifdef _WIN32
#include <windows.h>
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__) || \
    defined(_WIN32)
#define HAVE_STACKTRACE 1

void my_init_stacktrace();

/** print a stacktrace of the current thread to stderr. */
void my_print_stacktrace(const unsigned char *stack_bottom,
                         unsigned long thread_stack);

#ifdef _WIN32
void my_set_exception_pointers(EXCEPTION_POINTERS *ep);
#endif
#endif

/**
 * produce a core file (POSIX) or a minidump (Windows) and terminate.
 */
void my_write_core(int sig);

/**
 * printf() to stderr that doesn't allocate memory.
 */
size_t my_safe_printf_stderr(const char *fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;

#endif
