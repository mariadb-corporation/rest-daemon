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

# Print the DLLs every PE binary under a directory imports, as
#
#     <path relative to the root, forward slashes>\t<DLL name>
#
# Used by verify_package.sh's dependency audit on Windows. It reads the PE import
# directory directly rather than shelling out to dumpbin or objdump, because
# neither is present on a machine that has only unpacked a package -- and running
# there is the whole point of that script. (From MariaDB Shell's
# scripts/pe_imports.py, which runs it with the shell's bundled Python; restd
# has none, so it runs with the runner's Python, which reads files only and
# takes no part in how the package's DLLs are resolved.)
#
# Only the standard import directory is read, not the delay-load one: a
# delay-loaded DLL would be a soft failure at first use rather than a
# load-time one.
#
# Run as: python pe_imports.py <package-root>
import os
import struct
import sys


def _rva_to_offset(rva, sections):
    """File offset for a virtual address, or None if it falls outside every section."""
    for vaddr, vsize, rawsize, rawptr in sections:
        if vaddr <= rva < vaddr + max(vsize, rawsize):
            return rawptr + (rva - vaddr)
    return None


def _cstring(data, off):
    end = data.find(b"\0", off)
    if end < 0:
        end = len(data)
    return data[off:end].decode("ascii", "replace")


def imported_dlls(path):
    """DLL names in the PE at `path`; None if it is not a PE at all.

    Offsets are from the PE format itself: e_lfanew at 0x3c, the 20-byte COFF
    header after the "PE\\0\\0" signature, then the optional header whose magic
    picks where the data directories start (PE32 vs PE32+). Directory entry 1 is
    the import table: an array of 20-byte descriptors, each holding an RVA to the
    DLL's name, terminated by an all-zero entry.
    """
    with open(path, "rb") as fh:
        data = fh.read()

    if len(data) < 0x40 or data[:2] != b"MZ":
        return None
    (e_lfanew,) = struct.unpack_from("<I", data, 0x3C)
    if len(data) < e_lfanew + 24 or data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return None

    coff = e_lfanew + 4
    (num_sections,) = struct.unpack_from("<H", data, coff + 2)
    (size_opt,) = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    (magic,) = struct.unpack_from("<H", data, opt)
    if magic == 0x10B:      # PE32
        dirs = opt + 96
    elif magic == 0x20B:    # PE32+
        dirs = opt + 112
    else:
        return None

    if size_opt < (dirs - opt) + 16:
        return []
    imp_rva, _imp_size = struct.unpack_from("<II", data, dirs + 8)
    if not imp_rva:
        return []

    sections = []
    sec = opt + size_opt
    for i in range(num_sections):
        off = sec + i * 40
        if off + 40 > len(data):
            break
        # Section header: name[8], VirtualSize, VirtualAddress, SizeOfRawData,
        # PointerToRawData, ...
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append((vaddr, vsize, rawsize, rawptr))

    entry = _rva_to_offset(imp_rva, sections)
    if entry is None:
        return []

    names = []
    while entry + 20 <= len(data):
        ilt, _stamp, _chain, name_rva, iat = struct.unpack_from("<IIIII", data, entry)
        if not (ilt or name_rva or iat):
            break
        if name_rva:
            noff = _rva_to_offset(name_rva, sections)
            if noff is not None and noff < len(data):
                names.append(_cstring(data, noff))
        entry += 20
    return names


def main(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.lower().endswith((".exe", ".dll", ".pyd", ".drv")):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            # A path that does not resolve is a dangling symlink, which
            # verify_package.sh reports separately; not this check's business.
            if not os.path.exists(full):
                continue
            try:
                dlls = imported_dlls(full)
            except Exception as exc:                       # noqa: BLE001
                print("%s\t!could not be read: %s" % (rel, exc))
                continue
            if dlls is None:
                print("%s\t!not a PE binary, despite its extension" % rel)
                continue
            for dll in dlls:
                print("%s\t%s" % (rel, dll))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.stderr.write("usage: pe_imports.py <package-root>\n")
        raise SystemExit(2)
    main(sys.argv[1])
