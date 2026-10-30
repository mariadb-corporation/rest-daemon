/*
  Copyright (c) 2022, 2026, Oracle and/or its affiliates.
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License, version 2.0,
  as published by the Free Software Foundation.

  This program is designed to work with certain software (including
  but not limited to OpenSSL) that is licensed under separate terms,
  as designated in a particular file or component or in included license
  documentation.  The authors of MySQL and, with respect to its
  modifications and additions, MariaDB plc hereby grant you an additional
  permission to link the program and your derivative works with the
  separately licensed software that they have either included with
  the program or referenced in the documentation.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*/

#ifndef ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_ENTRY_UNIVERSAL_ID_H_
#define ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_ENTRY_UNIVERSAL_ID_H_

#include <algorithm>
#include <array>
#include <cassert>
#include <compare>
#include <cstring>
#include <optional>
#include <utility>

#include "mysqlrouter/utils_sqlstring.h"

#include "my_compiler.h"

namespace mrs {
namespace database {
namespace entry {

struct UniversalId {
  constexpr static uint64_t k_size = 16;
  using Array = std::array<uint8_t, k_size>;

  UniversalId() = default;

  UniversalId(std::initializer_list<uint8_t> v) {
    assert(v.size() <= raw.size());
    std::copy_n(v.begin(), std::min(v.size(), raw.size()), std::begin(raw));
  }

  UniversalId(const Array &v) { raw = v; }

  Array raw{};

  bool empty() const {
    for (uint8_t v : raw) {
      if (0 != v) return false;
    }
    return true;
  }

  auto begin() const { return std::begin(raw); }
  auto end() const { return std::end(raw); }

  MY_COMPILER_DIAGNOSTIC_PUSH()
  MY_COMPILER_GCC_DIAGNOSTIC_IGNORE("-Wzero-as-null-pointer-constant")
  MY_COMPILER_CLANG_DIAGNOSTIC_IGNORE("-Wzero-as-null-pointer-constant")
  std::strong_ordering operator<=>(const UniversalId &rhs) const {
    for (size_t ndx = raw.size() - 1; ndx > 0; --ndx) {
      auto cmp_res = raw[ndx] <=> rhs.raw[ndx];

      if (cmp_res != 0) return cmp_res;
    }

    return raw[0] <=> rhs.raw[0];
  }
  MY_COMPILER_DIAGNOSTIC_POP()

  bool operator==(const UniversalId &rhs) const = default;

  // restd: an id is read from 16 raw bytes (`BINARY(16)`), from the 36-character
  // text of a MariaDB `UUID` column or from 32 hex digits (`HEX()`); anything
  // else is the zero id.
  static UniversalId from_cstr(const char *p, uint32_t length) {
    UniversalId result;
    if (length == k_size) {
      from_raw(&result, p);
      return result;
    }
    if (from_text(&result, p, length)) return result;
    return {};
  }

  static bool from_text(UniversalId *uid, const char *p, size_t length) {
    if (length != 32 && length != 36) return false;
    size_t n = 0;
    for (size_t i = 0; i < length; ++i) {
      const char c = p[i];
      if (c == '-') {
        if (length != 36 || (i != 8 && i != 13 && i != 18 && i != 23))
          return false;
        continue;
      }
      int v;
      if (c >= '0' && c <= '9')
        v = c - '0';
      else if (c >= 'a' && c <= 'f')
        v = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F')
        v = c - 'A' + 10;
      else
        return false;
      if (n >= 2 * k_size) return false;
      if (n % 2 == 0)
        uid->raw[n / 2] = static_cast<uint8_t>(v << 4);
      else
        uid->raw[n / 2] |= static_cast<uint8_t>(v);
      ++n;
    }
    return n == 2 * k_size;
  }

  const char *to_raw() const {
    return reinterpret_cast<const char *>(raw.data());
  }

  static void from_raw(UniversalId *uid, const char *binray) {
    memcpy(uid->raw.data(), binray, k_size);
  }

  static void from_raw_zero_on_null(UniversalId *uid, const char *binray) {
    if (binray)
      memcpy(uid->raw.data(), binray, k_size);
    else
      memset(uid->raw.data(), 0, k_size);
  }

  static void from_raw_optional(std::optional<UniversalId> *uid,
                                const char *binray) {
    if (binray) {
      UniversalId result;
      from_raw(&result, binray);
      *uid = std::move(result);
    } else {
      (*uid).reset();
    }
  }

  // restd: the canonical text of a MariaDB `UUID`
  // (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, lower case)
  std::string to_uuid_string() const {
    auto hex = to_string();
    for (size_t pos : {8, 13, 18, 23}) hex.insert(pos, 1, '-');
    return hex;
  }

  std::string to_string() const {
    // lower-case hex
    constexpr std::array<char, 16> hex_chars = {
        '0', '1', '2', '3', '4', '5', '6', '7',  //
        '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
    };

    std::string out;
    out.reserve(raw.size() * 2);

    for (auto ch : raw) {
      out += hex_chars[ch >> 4];
      out += hex_chars[ch & 0xf];
    }

    return out;
  }
};

inline mysqlrouter::sqlstring to_sqlstring(const UniversalId &ud) {
  mysqlrouter::sqlstring result{"X?"};
  result << ud.to_string();
  return result;
}

inline std::string to_string(const UniversalId &ud) { return ud.to_string(); }

inline mysqlrouter::sqlstring &operator<<(mysqlrouter::sqlstring &sql,
                                          const UniversalId &ud) {
  sql << to_sqlstring(ud);

  return sql;
}

}  // namespace entry
}  // namespace database
}  // namespace mrs

#endif  // ROUTER_SRC_REST_MRS_SRC_MRS_DATABASE_ENTRY_UNIVERSAL_ID_H_
