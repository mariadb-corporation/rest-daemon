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

// Same interface as the MySQL server's my_aligned_malloc.h (mysys);
// implemented in compat/src/aligned_malloc.cc.

#ifndef MY_ALIGNED_MALLOC_INCLUDED
#define MY_ALIGNED_MALLOC_INCLUDED

#include <cstddef>

/**
 * allocate size bytes aligned to alignment (a power of 2).
 *
 * @returns nullptr on failure. Free with my_aligned_free().
 */
void *my_aligned_malloc(size_t size, size_t alignment);

void my_aligned_free(void *ptr);

#endif
