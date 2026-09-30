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

// Crash reporting for the harness signal handler.
//
// Much simpler than the server's mysys/stacktrace.cc: backtrace(3) on POSIX,
// DbgHelp on Windows.

#include "my_stacktrace.h"

#include <cstdarg>
#include <cstdio>

#ifdef _WIN32
#include <windows.h>
// windows.h must come first
#include <dbghelp.h>
#include <io.h>
#include <process.h>

#pragma comment(lib, "dbghelp.lib")
#else
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#endif

namespace {
#ifdef _WIN32
EXCEPTION_POINTERS *exception_ptrs{nullptr};

void write_stderr(const char *buf, size_t len) {
  _write(2, buf, static_cast<unsigned int>(len));
}
#else
void write_stderr(const char *buf, size_t len) {
  while (len > 0) {
    const auto written = ::write(STDERR_FILENO, buf, len);
    if (written <= 0) return;
    buf += written;
    len -= static_cast<size_t>(written);
  }
}
#endif
}  // namespace

size_t my_safe_printf_stderr(const char *fmt, ...) {
  // vsnprintf into a stack buffer: no heap allocation in the signal handler.
  char buf[2048];

  va_list args;
  va_start(args, fmt);
  const int len = vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);

  if (len <= 0) return 0;

  const size_t to_write =
      static_cast<size_t>(len) < sizeof(buf) ? len : sizeof(buf) - 1;
  write_stderr(buf, to_write);

  return to_write;
}

#ifdef _WIN32

namespace {
bool sym_initialized{false};

void init_symbols() {
  if (sym_initialized) return;
  sym_initialized = true;

  SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES);
  // search the directories of the loaded modules for their .pdb files
  SymInitialize(GetCurrentProcess(), nullptr, TRUE);
}
}  // namespace

void my_init_stacktrace() { init_symbols(); }

void my_set_exception_pointers(EXCEPTION_POINTERS *ep) { exception_ptrs = ep; }

void my_print_stacktrace(const unsigned char *, unsigned long) {
  // the Windows exception filter calls this without my_init_stacktrace()
  init_symbols();

  void *frames[64];
  const USHORT num_frames = CaptureStackBackTrace(0, 64, frames, nullptr);

  alignas(SYMBOL_INFO) char sym_buf[sizeof(SYMBOL_INFO) + 256];
  auto *sym = reinterpret_cast<SYMBOL_INFO *>(sym_buf);
  sym->SizeOfStruct = sizeof(SYMBOL_INFO);
  sym->MaxNameLen = 255;

  const HANDLE process = GetCurrentProcess();
  for (USHORT i = 0; i < num_frames; ++i) {
    const auto addr = reinterpret_cast<DWORD64>(frames[i]);
    DWORD64 displacement{0};
    if (!SymFromAddr(process, addr, &displacement, sym)) {
      my_safe_printf_stderr("%p\n", frames[i]);
      continue;
    }

    IMAGEHLP_LINE64 line{};
    line.SizeOfStruct = sizeof(line);
    DWORD line_displacement{0};
    if (SymGetLineFromAddr64(process, addr, &line_displacement, &line)) {
      my_safe_printf_stderr("%p %s()[%s:%lu]\n", frames[i], sym->Name,
                            line.FileName, line.LineNumber);
    } else {
      my_safe_printf_stderr("%p %s()+0x%llx\n", frames[i], sym->Name,
                            static_cast<unsigned long long>(displacement));
    }
  }
}

void my_write_core(int) {
  char dump_name[MAX_PATH];
  snprintf(dump_name, sizeof(dump_name), "mrsd.%d.dmp", _getpid());

  const HANDLE file =
      CreateFileA(dump_name, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                  FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION info{};
    info.ThreadId = GetCurrentThreadId();
    info.ExceptionPointers = exception_ptrs;
    info.ClientPointers = FALSE;

    const auto dump_type = static_cast<MINIDUMP_TYPE>(
        MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithProcessThreadData |
        MiniDumpWithIndirectlyReferencedMemory);

    if (MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file,
                          dump_type, exception_ptrs ? &info : nullptr, nullptr,
                          nullptr)) {
      my_safe_printf_stderr("Minidump written to %s\n", dump_name);
    } else {
      my_safe_printf_stderr("MiniDumpWriteDump() failed: %lu\n",
                            GetLastError());
    }
    CloseHandle(file);
  }
}

#else

void my_init_stacktrace() {
  // the first call to backtrace() may allocate (it loads libgcc on some
  // platforms); do it outside of the signal handler.
  void *frames[1];
  (void)backtrace(frames, 1);
}

void my_print_stacktrace(const unsigned char *, unsigned long) {
  void *frames[64];
  const int num_frames = backtrace(frames, 64);

  my_safe_printf_stderr("stack_bottom = %p\n", frames[0]);
  backtrace_symbols_fd(frames, num_frames, STDERR_FILENO);
}

void my_write_core(int sig) {
  // restore the default action and re-raise to get a core file.
  signal(sig, SIG_DFL);
  raise(sig);
}

#endif
