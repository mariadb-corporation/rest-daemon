# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA

# Platform checks feeding extra/mysql-internals/my_config.h.in

INCLUDE(CheckIncludeFiles)
INCLUDE(CheckSymbolExists)
INCLUDE(CheckTypeSize)
INCLUDE(TestBigEndian)

CHECK_INCLUDE_FILES(sys/prctl.h HAVE_SYS_PRCTL_H)
CHECK_SYMBOL_EXISTS(stpcpy "string.h" HAVE_STPCPY)
CHECK_SYMBOL_EXISTS(stpncpy "string.h" HAVE_STPNCPY)
IF(NOT WIN32)
  SET(CMAKE_REQUIRED_DEFINITIONS -D_GNU_SOURCE)
  CHECK_SYMBOL_EXISTS(strptime "time.h" HAVE_STRPTIME)
  UNSET(CMAKE_REQUIRED_DEFINITIONS)
ENDIF()
CHECK_SYMBOL_EXISTS(epoll_create "sys/epoll.h" HAVE_EPOLL)
CHECK_SYMBOL_EXISTS(kqueue "sys/types.h;sys/event.h" HAVE_KQUEUE)
TEST_BIG_ENDIAN(WORDS_BIGENDIAN)

SET(CMAKE_EXTRA_INCLUDE_FILES sys/types.h)
CHECK_TYPE_SIZE(ulong SIZEOF_ULONG)
UNSET(CMAKE_EXTRA_INCLUDE_FILES)
IF(SIZEOF_ULONG)
  SET(HAVE_ULONG 1)
ENDIF()

CHECK_CXX_SOURCE_COMPILES("
  #include <cxxabi.h>
  int main() {
    char *foo = 0; int bar = 0;
    foo = abi::__cxa_demangle(foo, foo, 0, &bar);
    return 0;
  }" HAVE_ABI_CXA_DEMANGLE)
CHECK_CXX_SOURCE_COMPILES("
  int main() { __builtin_unreachable(); return 0; }" HAVE_BUILTIN_UNREACHABLE)
CHECK_CXX_SOURCE_COMPILES("
  int main() { int a = 42; return __builtin_expect(a, 42) == 42 ? 0 : 1; }"
  HAVE_BUILTIN_EXPECT)
CHECK_CXX_SOURCE_COMPILES("
  int main() { char buf[4]; __builtin_stpcpy(buf, \"ab\"); return 0; }"
  HAVE_BUILTIN_STPCPY)

IF(LINUX AND EXISTS "/etc/alpine-release")
  SET(LINUX_ALPINE 1)
ENDIF()

IF(WITH_ASAN)
  SET(HAVE_ASAN 1)
ENDIF()
IF(WITH_UBSAN)
  SET(HAVE_UBSAN 1)
ENDIF()
IF(WITH_TSAN)
  SET(HAVE_TSAN 1)
ENDIF()
IF(WITH_VALGRIND)
  SET(HAVE_VALGRIND 1)
ENDIF()

CONFIGURE_FILE(${CMAKE_SOURCE_DIR}/extra/mysql-internals/my_config.h.in
  ${CMAKE_BINARY_DIR}/include/my_config.h)
