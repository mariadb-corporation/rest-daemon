/*
  Copyright (c) 2019, 2026, Oracle and/or its affiliates.
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

#ifndef MRSD_TESTS_HELPERS_CLUSTER_METADATA_TYPES_H
#define MRSD_TESTS_HELPERS_CLUSTER_METADATA_TYPES_H

// restd: the two types the component-test helpers use from upstream's
// mysqlrouter/cluster_metadata.h (router_cluster isn't part of mrsd). The
// helpers use them to generate mock-server metadata.

namespace mysqlrouter {

struct MetadataSchemaVersion {
  unsigned int major;
  unsigned int minor;
  unsigned int patch;

  bool operator<(const MetadataSchemaVersion &o) const {
    if (major == o.major) {
      if (minor == o.minor) {
        return patch < o.patch;
      } else {
        return minor < o.minor;
      }
    } else {
      return major < o.major;
    }
  }

  bool operator<=(const MetadataSchemaVersion &o) const {
    return operator<(o) || operator==(o);
  }

  bool operator>(const MetadataSchemaVersion &o) const {
    return operator!=(o) && !operator<(o);
  }

  bool operator>=(const MetadataSchemaVersion &o) const {
    return operator>(o) || operator==(o);
  }

  bool operator==(const MetadataSchemaVersion &o) const {
    return major == o.major && minor == o.minor && patch == o.patch;
  }

  bool operator!=(const MetadataSchemaVersion &o) const {
    return !operator==(o);
  }
};

enum class ClusterType {
  GR_V2, /* based on Group Replication (metadata 2.x) */
  GR_CS, /* based on Group Replication, part of ClusterSet (metadata 2.1+) */
  RS_V2  /* ReplicaSet (metadata 2.x) */
};

}  // namespace mysqlrouter

#endif
