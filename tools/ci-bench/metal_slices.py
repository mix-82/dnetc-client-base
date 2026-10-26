#!/usr/bin/env python3
# Pull the GPU code out of a Metal binary archive or GPU-binary metallib.
# On Intel Macs these are fat files (magic 0xcbfebabe) whose slices are the
# AIR metallib and one Mach-O per GPU target (cputype 0x01000014 = AMD,
# 0x01000013 = Intel, 0x01000017 = AIR); the Mach-O's __TEXT,__compute
# section holds the compiled kernel. Each GPU slice's section is written to
# <prefix>-<name>.code; an AMD one is also disassembled with llvm-mc when a
# path to it is given (the code starts after a header, found by looking for
# the first offset that decodes without errors).
#
# usage: metal_slices.py archive out-prefix [gfx-target] [llvm-mc]
import struct
import subprocess
import sys

blob = open(sys.argv[1], "rb").read()
prefix = sys.argv[2]
gfx = sys.argv[3] if len(sys.argv) > 3 else ""
llvm_mc = sys.argv[4] if len(sys.argv) > 4 else ""

CPUTYPES = {0x01000014: "amdgpu", 0x01000013: "intelgpu", 0x01000017: "air64", 0x01000016: "applegpu"}

def macho_sections(m):
    ncmds = struct.unpack("<I", m[16:20])[0]
    off = 32
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", m[off:off + 8])
        if cmd == 0x19:
            nsects = struct.unpack("<I", m[off + 64:off + 68])[0]
            so = off + 72
            for _ in range(nsects):
                sect = m[so:so + 16].rstrip(b"\0").decode()
                seg = m[so + 16:so + 32].rstrip(b"\0").decode()
                _, ssize, soff = struct.unpack("<QQI", m[so + 32:so + 52])
                out.append((seg, sect, soff, ssize))
                so += 80
        off += size
    return out

if blob[:4] != b"\xcb\xfe\xba\xbe":
    print("not a Metal fat archive (magic %s)" % blob[:4].hex())
    sys.exit(0)
n = struct.unpack(">I", blob[4:8])[0]
print("fat archive with %d slices" % n)
for i in range(n):
    ct, cst, off, size, align = struct.unpack(">IIIII", blob[8 + 20 * i:28 + 20 * i])
    name = CPUTYPES.get(ct, "cputype_%x" % ct)
    sl = blob[off:off + size]
    print("  slice %s subtype %#x: %d bytes" % (name, cst, size))
    if sl[:4] != b"\xcf\xfa\xed\xfe":
        continue
    for seg, sect, soff, ssize in macho_sections(sl):
        print("    %s,%s %d bytes" % (seg, sect, ssize))
        if sect != "__compute":
            continue
        code = sl[soff:soff + ssize]
        out = "%s-%s.code" % (prefix, name)
        open(out, "wb").write(code)
        print("    -> %s" % out)
        if name == "amdgpu" and gfx and llvm_mc:
            end = code.find(b"\x00\x00\x81\xbf")   # s_endpgm
            end = len(code) if end < 0 else end + 4
            best = None
            for start in range(0, min(0x800, end - 256), 4):
                chunk = " ".join("0x%02x" % b for b in code[start:start + 512])
                r = subprocess.run([llvm_mc, "-disassemble", "-triple=amdgcn-amd-amdhsa", "-mcpu=" + gfx],
                                   input=chunk, capture_output=True, text=True)
                bad = r.stderr.count("invalid") + r.stdout.count("s_nop")
                if best is None or bad < best[0]:
                    best = (bad, start)
                if bad == 0:
                    break
            start = best[1]
            chunk = " ".join("0x%02x" % b for b in code[start:end])
            r = subprocess.run([llvm_mc, "-disassemble", "-triple=amdgcn-amd-amdhsa", "-mcpu=" + gfx],
                               input=chunk, capture_output=True, text=True)
            asm = "%s-%s-%s.s" % (prefix, name, gfx)
            open(asm, "w").write(r.stdout)
            print("    -> %s (code at %#x..%#x, %d decode errors)" % (asm, start, end, r.stderr.count("invalid")))
