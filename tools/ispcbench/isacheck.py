#!/usr/bin/env python3
# isacheck.py OBJ KIND KEYS
# KIND avx512f: EVEX code must need only AVX-512F (no VL/BW/DQ/other).
# KIND avx2:    no EVEX, zmm or opmask code at all.
# Also counts vector loads/stores against the stack, per 16 keys.
import re
import subprocess
import sys

obj, kind, keys = sys.argv[1], sys.argv[2], int(sys.argv[3])
dis = subprocess.run(["objdump", "-d", "--no-addresses", obj], capture_output=True, text=True).stdout

# EVEX encodings that need more than AVX-512F, by mnemonic
NOT_F = re.compile(
    r"^(kmov[bdq]|k(add|and|andn|or|xor|xnor|not|test|ortest|shiftl|shiftr|unpck)[bdq]"
    r"|vpmov[bwdq]2m|vpmovm2[bwdq]|vpcmpu?[bw]|vpcmpeq[bw]|vpcmpgt[bw]"
    r"|vpadd[bw]|vpsub[bw]|vpaddu?s[bw]|vpsubu?s[bw]|vpmull[wq]|vpmulh"
    r"|vextract[if](32x8|64x2)|vinsert[if](32x8|64x2)|vbroadcast[if](32x8|64x2|32x2)"
    r"|vpermw|vpermb|vpshufb|vpbroadcast[bw]|vpsllv?w|vpsrlv?w|vpsrav?w|vpblendm[bw]"
    r"|vpcompress[bw]|vpexpand[bw]|vpopcnt|vpshld|vpshrd|vpdp)"
)
SCALAR_OK = re.compile(r"(ss|sd|sh)$|^(vmov[dq]|vpextr|vpinsr|vcvt\w*s[sd]2|vbroadcastss|vbroadcastsd)$")

evex = 0
bad = []
zmm_or_k = 0
lines = 0
stack_load = 0
stack_store = 0
for line in dis.splitlines():
    m = re.match(r"^\s*((?:[0-9a-f]{2} )+)\s*(\S+)\s*(.*)$", line)
    if not m:
        continue
    raw, mnem, ops = m.group(1).split(), m.group(2), m.group(3)
    lines += 1
    vec = ("%zmm" in ops) or ("%ymm" in ops) or ("%xmm" in ops)
    if vec and ("(%rsp)" in ops or "(%rbp)" in ops):
        # AT&T: destination is the last operand
        if ops.rstrip().endswith(")"):
            stack_store += 1
        else:
            stack_load += 1
    is_evex = raw and raw[0] == "62"
    if "%zmm" in ops or re.search(r"%k[0-7]", ops):
        zmm_or_k += 1
    if not is_evex:
        continue
    evex += 1
    base = mnem.split("{")[0]
    if NOT_F.match(base):
        bad.append(line.strip())
        continue
    dest = ops.split(",")[-1] if ops else ""
    if ("%xmm" in dest or "%ymm" in dest) and not SCALAR_OK.search(base):
        bad.append(line.strip() + "   [VL: xmm/ymm destination]")

per16 = 16.0 / keys
print("%-14s %-8s insns %5d  evex %5d  stack loads/16 keys %6.1f  stores/16 keys %6.1f" %
      (obj, kind, lines, evex, stack_load * per16, stack_store * per16))
ok = True
if kind == "avx512f" and bad:
    ok = False
    print("  NOT AVX-512F-only:")
    for b in bad[:12]:
        print("   ", b)
if kind == "avx2" and (evex or zmm_or_k):
    ok = False
    print("  AVX-512 code in an AVX2 build: %d EVEX, %d zmm/opmask" % (evex, zmm_or_k))
sys.exit(0 if ok else 1)
