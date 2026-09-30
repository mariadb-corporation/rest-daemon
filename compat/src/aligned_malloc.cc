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

#include "my_aligned_malloc.h"

#include <cstdlib>

#ifdef _WIN32
#include <malloc.h>
#endif

void *my_aligned_malloc(size_t size, size_t alignment) {
#ifdef _WIN32
  return _aligned_malloc(size, alignment);
#else
  // posix_memalign() requires a multiple of sizeof(void *)
  if (alignment < sizeof(void *)) alignment = sizeof(void *);

  void *ptr{nullptr};
  if (posix_memalign(&ptr, alignment, size) != 0) return nullptr;

  return ptr;
#endif
}

void my_aligned_free(void *ptr) {
#ifdef _WIN32
  _aligned_free(ptr);
#else
  free(ptr);
#endif
}
