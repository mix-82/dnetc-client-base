#!/usr/bin/env python3
# Pull the GPU code out of a Metal binary archive or GPU-binary metallib.
# On Intel Macs these are fat files (magic 0xcbfebabe) whose slices are the
# AIR metallib and one Mach-O per GPU target (cputype 0x01000013 = Apple,
# 0x01000014 = AMD, 0x01000015 = Intel, 0x01000017 = AIR); the Mach-O's __TEXT,__compute
# section holds the compiled kernel. Each GPU slice's section is written to
# <prefix>-<name>.code; an AMD one is also disassembled with llvm-mc when a
# path to it is given.
#
# An Apple GPU slice's __compute section is itself a Mach-O whose __text
# holds the kernel at the _agc.main symbol; that body is written to
# <prefix>-applegpu-<subtype>-main.bin with its size and hash (the compiler
# emits one body per variant class, shared across G13/G14 and across
# G15/G16), and disassembled with the applegpu project's disassemble.py when
# its directory is given (G13/G14 only; later families are not decodable).
#
# usage: metal_slices.py archive out-prefix [gfx-for-unknown-subtype] [llvm-mc] [applegpu-dir]
import struct
import subprocess
import sys

blob = open(sys.argv[1], "rb").read()
prefix = sys.argv[2]
gfx = sys.argv[3] if len(sys.argv) > 3 else ""
llvm_mc = sys.argv[4] if len(sys.argv) > 4 else ""
applegpu_dir = sys.argv[5] if len(sys.argv) > 5 else ""
import hashlib

CPUTYPES = {0x01000013: "applegpu", 0x01000014: "amdgpu", 0x01000015: "intelgpu", 0x01000017: "air64"}
# AMD slice subtypes as metal-tt numbers them (4000+ GCN3, 5000+ Vega, 6000+ RDNA)
AMD_SUBTYPES = {0x0fa4: "gfx802", 0x0fa5: "gfx803", 0x1388: "gfx900", 0x1389: "gfx904",
                0x138a: "gfx906", 0x1770: "gfx1010", 0x1771: "gfx1010_nsgc", 0x1772: "gfx1011",
                0x1773: "gfx1012", 0x1774: "gfx1030", 0x1775: "gfx1032"}
# Apple subtypes seen on real machines: 0x142 M1 (G13G), 0x212 M1 Pro (G13S),
# 0x1a3 M3 Pro; the rest are named by their number
APPLE_SUBTYPES = {0x0142: "m1", 0x0212: "m1pro", 0x01a3: "m3pro"}

def macho_symbols(m):
    ncmds = struct.unpack("<I", m[16:20])[0]
    off = 32
    syms = {}
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", m[off:off + 8])
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack("<IIII", m[off + 8:off + 24])
            for i in range(nsyms):
                strx, ntype, nsect, ndesc, val = struct.unpack("<IBBHQ", m[symoff + 16 * i:symoff + 16 * i + 16])
                syms[m[stroff + strx:m.index(b"\0", stroff + strx)].decode()] = val
        off += size
    return syms

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
seen_bodies = {}
for i in range(n):
    ct, cst, off, size, align = struct.unpack(">IIIII", blob[8 + 20 * i:28 + 20 * i])
    name = CPUTYPES.get(ct, "cputype_%x" % ct)
    target = ""
    if name == "amdgpu":
        target = AMD_SUBTYPES.get(cst, gfx)
    elif name == "applegpu":
        target = APPLE_SUBTYPES.get(cst, "sub%x" % cst)
    elif name == "intelgpu":
        target = "sub%x" % cst
    label = name + ("-" + target if target else "")
    sl = blob[off:off + size]
    print("  slice %s subtype %#x: %d bytes" % (label, cst, size))
    if sl[:4] != b"\xcf\xfa\xed\xfe":
        continue
    for seg, sect, soff, ssize in macho_sections(sl):
        print("    %s,%s %d bytes" % (seg, sect, ssize))
        if sect != "__compute":
            continue
        code = sl[soff:soff + ssize]
        out = "%s-%s.code" % (prefix, label)
        open(out, "wb").write(code)
        print("    -> %s" % out)
        if name == "applegpu" and code[:4] == b"\xcf\xfa\xed\xfe":
            text = None
            for seg2, sect2, soff2, ssize2 in macho_sections(code):
                if sect2 == "__text":
                    text = (soff2, ssize2)
            syms = macho_symbols(code)
            if text and "_agc.main" in syms:
                main = code[text[0] + syms["_agc.main"]:text[0] + text[1]]
                mb = "%s-%s-main.bin" % (prefix, label)
                open(mb, "wb").write(main)
                sha = hashlib.sha1(main).hexdigest()[:12]
                print("    main body %d bytes, sha %s -> %s" % (len(main), sha, mb))
                if sha in seen_bodies:
                    print("    same body as %s" % seen_bodies[sha])
                elif applegpu_dir:
                    seen_bodies[sha] = label
                    r = subprocess.run([sys.executable, applegpu_dir + "/disassemble.py", mb], capture_output=True, text=True)
                    lines = [l for l in r.stdout.splitlines() if l[:1] == " " or l[:1].isdigit()]
                    failed = r.stdout.count("disassembly failed")
                    asm = "%s-%s.agx" % (prefix, label)
                    open(asm, "w").write(r.stdout)
                    if failed == 0 and lines:
                        import collections
                        hist = collections.Counter(l.split()[2] for l in lines if len(l.split()) > 2)
                        print("    disassembled: %d instructions; %s" % (len(lines), ", ".join("%s %d" % kv for kv in hist.most_common(8))))
                    else:
                        print("    not decodable by applegpu (%d failures) - a G15 or later family" % failed)
            break
        if name == "amdgpu" and target and llvm_mc and "nsgc" not in target:
            end = code.find(b"\x00\x00\x81\xbf")   # s_endpgm
            end = len(code) if end < 0 else end + 4
            # the code follows a header whose layout differs per generation:
            # take the first 4-aligned offset from which 256 bytes decode
            # cleanly and the first instruction is scalar (kernels start with
            # s_load / s_mov / s_version), which rules out the header's zeros
            # decoding as v_cndmask and padding decoding as s_nop
            start = 0
            for cand in [0x1d4, 0x1d0] + list(range(0, min(0x800, end - 256), 4)):
                chunk = " ".join("0x%02x" % b for b in code[cand:cand + 256])
                r = subprocess.run([llvm_mc, "-disassemble", "-triple=amdgcn-amd-amdhsa", "-mcpu=" + target],
                                   input=chunk, capture_output=True, text=True)
                if "invalid" in r.stderr:
                    continue
                first = [l.strip() for l in r.stdout.splitlines() if l.strip() and not l.startswith("\t.")][:2]
                if first and first[0].startswith("s_") and "nop" not in first[0]:
                    start = cand
                    break
            chunk = " ".join("0x%02x" % b for b in code[start:end])
            r = subprocess.run([llvm_mc, "-disassemble", "-triple=amdgcn-amd-amdhsa", "-mcpu=" + target],
                               input=chunk, capture_output=True, text=True)
            asm = "%s-%s.s" % (prefix, label)
            open(asm, "w").write(r.stdout)
            print("    -> %s (code at %#x..%#x, %d decode errors)" % (asm, start, end, r.stderr.count("invalid")))
