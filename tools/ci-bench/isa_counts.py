#!/usr/bin/env python3
# Instruction counts for one kernel in AMD GPU assembly (clang -S output)
# or an llvm-objdump disassembly: VALU/SALU totals, the instructions a
# rotate can become, the VGPR count from the kernel metadata when present,
# and the top of the histogram. Only the named kernel's own code is counted
# (recent clang also emits a __clang_ocl_kern_imp_* copy of the body).
#
# usage: isa_counts.py file pipes kernel-symbol
import re
import sys

path, pipes, sym = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = open(path, errors="replace").read().split("\n")

# the kernel's region: from its label to the next function end / next symbol
start = None
end = len(lines)
for i, l in enumerate(lines):
    if start is None:
        if l.startswith(sym + ":") or re.match(r"^[0-9a-f]+ <%s>:" % re.escape(sym), l):
            start = i
    elif l.startswith(".Lfunc_end") or re.match(r"^[0-9a-f]+ <", l):
        end = i
        break
if start is None:
    print("- kernel %s not found as a label; counting the whole file" % sym)
    start = 0
body = lines[start:end]

instr = []
for l in body:
    m = re.match(r"^\s*(?:[0-9a-f]+:\s*)?([vs]_[a-z0-9_]+)", l)
    if m:
        instr.append(m.group(1))
valu = sum(1 for i in instr if i.startswith("v_"))
salu = sum(1 for i in instr if i.startswith("s_"))

vgpr = None
m = re.search(r"\.vgpr_count:\s*(\d+)", "\n".join(lines))
if m:
    vgpr = m.group(1)
occ = None
m = re.search(r"; Occupancy: (\d+)\s*$", "\n".join(body + lines[end:end + 80]), re.M)
if m:
    occ = m.group(1)

print("- VALU %d (%d per key), SALU %d, VGPRs %s, occupancy %s"
      % (valu, valu // pipes, salu, vgpr or "?", occ or "?"))
want = ["v_alignbit_b32", "v_lshrrev_b64", "v_lshlrev_b64", "v_lshl_or_b32", "v_bfe_u32", "v_perm_b32", "v_add3_u32"]
print("- " + ", ".join("%s %d" % (w, sum(1 for i in instr if i.startswith(w))) for w in want))
print("- instruction histogram:")
hist = {}
for i in instr:
    hist[i] = hist.get(i, 0) + 1
for name, n in sorted(hist.items(), key=lambda kv: -kv[1])[:10]:
    print("    %6d %s" % (n, name))
