#!/usr/bin/env python3
# Scan a binary blob (CL_PROGRAM_BINARIES output, a Metal binary archive,
# anything) for embedded ELF objects and write each one out as a file, with
# its machine type. Meant for the GPU code the macOS driver keeps inside its
# own containers (see tools/ci-bench/ci-macos-amd.sh): an AMDGPU ELF
# (e_machine 224) can then go to llvm-objdump, an NVIDIA cubin (190) to
# nvdisasm. Also reports PTX text, LLVM bitcode wrappers and Mach-O headers,
# so a blob that holds no ISA is still described.
#
# usage: find_elf.py blob out-prefix
import struct
import sys

blob = open(sys.argv[1], "rb").read()
prefix = sys.argv[2]

# On Intel Macs the OpenCL driver returns a property list whose clBinaryData
# is the path of the code object in the compiler service's cache
# (/private/var/db/CVMS/). Follow it and scan that file instead.
if blob.startswith(b"bplist00"):
    import plistlib
    plist = plistlib.loads(blob)
    print("blob: %s is a property list: %s" % (sys.argv[1],
          {k: (v if k != "clBinaryData" else v[:60]) for k, v in plist.items()}))
    data = plist.get("clBinaryData", b"")
    if isinstance(data, bytes) and data.startswith(b"/"):
        path = data.rstrip(b"\x00").decode()
        try:
            blob = open(path, "rb").read()
            open(prefix + "-cvms.bin", "wb").write(blob)
            print("  followed to %s (%d bytes), copy in %s-cvms.bin" % (path, len(blob), prefix))
        except OSError as e:
            print("  cannot read %s: %s" % (path, e))
            sys.exit(0)

MACHINES = {224: "AMDGPU", 190: "NVIDIA CUDA (cubin)", 62: "x86_64", 183: "AArch64", 3: "x86"}
AMDGPU_MACH = {   # EF_AMDGPU_MACH values (e_flags & 0xff), llvm/BinaryFormat/ELF.h
    0x20: "gfx600", 0x21: "gfx601", 0x22: "gfx700", 0x23: "gfx701",
    0x24: "gfx702", 0x25: "gfx703", 0x26: "gfx704", 0x28: "gfx801",
    0x29: "gfx802", 0x2a: "gfx803", 0x2b: "gfx810", 0x2c: "gfx900",
    0x2d: "gfx902", 0x2e: "gfx904", 0x2f: "gfx906", 0x30: "gfx908",
    0x31: "gfx909", 0x32: "gfx90c", 0x33: "gfx1010", 0x34: "gfx1011",
    0x35: "gfx1012", 0x36: "gfx1030", 0x37: "gfx1031", 0x38: "gfx1032",
    0x39: "gfx1033", 0x3a: "gfx602", 0x3b: "gfx705", 0x3c: "gfx805",
    0x3d: "gfx1035", 0x3e: "gfx1034", 0x3f: "gfx90a", 0x40: "gfx940",
    0x41: "gfx1100", 0x42: "gfx1013", 0x43: "gfx1150", 0x44: "gfx1103",
    0x45: "gfx1036", 0x46: "gfx1101", 0x47: "gfx1102",
}

print("blob: %s, %d bytes" % (sys.argv[1], len(blob)))
head = blob[:4]
if head == b"\xde\xc0\x17\x0b" or head == b"BC\xc0\xde":
    print("  starts with LLVM bitcode (wrapper or raw)")
if head in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
    print("  starts with a Mach-O header")

found = 0
pos = blob.find(b"\x7fELF")
while pos >= 0:
    if pos + 64 <= len(blob) and blob[pos + 4] == 2 and blob[pos + 5] == 1:
        # ELF64, little endian: pull the header fields we need
        (e_machine,) = struct.unpack_from("<H", blob, pos + 18)
        (e_flags,) = struct.unpack_from("<I", blob, pos + 48)
        (e_shoff,) = struct.unpack_from("<Q", blob, pos + 40)
        (e_shentsize, e_shnum) = struct.unpack_from("<HH", blob, pos + 58)
        end = pos + e_shoff + e_shentsize * e_shnum
        if e_shoff == 0 or end > len(blob):
            end = len(blob)
        name = MACHINES.get(e_machine, "machine %d" % e_machine)
        mach = ""
        if e_machine == 224:
            mach = " " + AMDGPU_MACH.get(e_flags & 0xff, "mach 0x%02x" % (e_flags & 0xff))
        out = "%s-%d.elf" % (prefix, found)
        open(out, "wb").write(blob[pos:end])
        print("  ELF at offset %d: %s%s, %d bytes -> %s" % (pos, name, mach, end - pos, out))
        found += 1
        pos = blob.find(b"\x7fELF", end)
    else:
        pos = blob.find(b"\x7fELF", pos + 1)

ptx = blob.find(b".version ")
if ptx >= 0 and blob.find(b".target ", ptx) >= 0:
    print("  PTX text at offset %d: %s" % (ptx, blob[ptx:ptx + 60].split(b"\n")[0].decode(errors="replace")))
bc = blob.count(b"BC\xc0\xde")
if bc:
    print("  raw bitcode magic occurrences: %d" % bc)
print("  ELF objects found: %d" % found)
