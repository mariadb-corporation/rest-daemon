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

#include "my_thread.h"

#ifdef _WIN32
#include <windows.h>

#include <string>
#else
#include <pthread.h>

#include <cstring>
#endif

void my_thread_self_setname(const char *name) {
#if defined(_WIN32)
  const int len = MultiByteToWideChar(CP_UTF8, 0, name, -1, nullptr, 0);
  if (len <= 0) return;
  std::wstring wname(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, name, -1, wname.data(), len);
  SetThreadDescription(GetCurrentThread(), wname.c_str());
#elif defined(__APPLE__)
  pthread_setname_np(name);
#else
  // Linux limits thread names to 16 bytes including the trailing \0
  char truncated[16];
  strncpy(truncated, name, sizeof(truncated) - 1);
  truncated[sizeof(truncated) - 1] = '\0';
  pthread_setname_np(pthread_self(), truncated);
#endif
}
