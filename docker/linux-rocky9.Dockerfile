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

# Build image of the Linux release packages (rest-daemon-release.yml), as
# MariaDB Shell's: Rocky Linux 9, for a glibc 2.34 floor (RHEL 9+, Ubuntu
# 22.04+, Debian 12+). The run mounts the source tree at /workspace/src and
# runs tools/release/build_package.sh.
FROM rockylinux:9

RUN dnf install -y epel-release dnf-plugins-core && \
    crb enable && \
    dnf update -y

# Build tooling only: Connector/C, OpenSSL and ICU come from vcpkg and are
# bundled, so no -devel packages of them here (the build would link the
# system copy). perl-core: vcpkg's OpenSSL; autoconf, automake, libtool,
# python3: vcpkg's ICU; patchelf: the package's rpaths; gcc, glibc-devel,
# zlib-devel, zlib-static (CRB): GraalVM native-image (the JIT executor
# library), which links libz.a; patch: the JIT executor build's
# maven-patch-plugin.
RUN dnf install -y \
    gcc gcc-c++ glibc-devel zlib-devel zlib-static git ninja-build perl-core python3 \
    autoconf automake libtool make pkgconfig zip unzip tar patchelf patch which findutils \
    gcc-toolset-14-gcc gcc-toolset-14-gcc-c++ gcc-toolset-14-binutils \
    && dnf clean all

RUN command -v ninja || ln -s /usr/bin/ninja-build /usr/bin/ninja

# CMake from upstream: vcpkg builds its ports with the system CMake on arm64
# Linux, and its port scripts need a newer one than Rocky's (as in MariaDB
# Shell's workflows)
ARG CMAKE_VERSION=4.4.1
RUN case "$(uname -m)" in \
      x86_64)  a=linux-x86_64 ;; \
      aarch64) a=linux-aarch64 ;; \
      *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL --retry 3 -o /tmp/cmake.tar.gz \
      "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-${a}.tar.gz" && \
    tar -xzf /tmp/cmake.tar.gz -C /opt && rm /tmp/cmake.tar.gz && \
    ln -s "/opt/cmake-${CMAKE_VERSION}-${a}/bin/"* /usr/local/bin/

ENV PATH="/opt/rh/gcc-toolset-14/root/usr/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/rh/gcc-toolset-14/root/usr/lib64" \
    CC="/opt/rh/gcc-toolset-14/root/usr/bin/gcc" \
    CXX="/opt/rh/gcc-toolset-14/root/usr/bin/g++" \
    VCPKG_FORCE_SYSTEM_BINARIES=1

WORKDIR /workspace/src
