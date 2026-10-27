#!/bin/bash
# Which source operations does Apple's GPU compiler lower to the funnel
# shift, and with an immediate or a register amount? Builds every probe
# from extr_probes.py through metal and metal-tt (offline, no GPU needed)
# for the M1 target (decoded with the applegpu tools), the Radeon gfx1012
# target (decoded with llvm-mc when Homebrew LLVM is present) and the Intel
# KBL and ICL targets (slices kept for IGA, which runs elsewhere), and tables
# per probe: total instructions, extr with an immediate / a register
# amount, v_alignbit_b32 immediate / register, v_and 31, and the M1
# instruction histogram. Writes <out>/summary-probe.md.
#
# usage: ci-extr-probe.sh <out-dir>     (run from the source root)

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/tools/ci-bench/ci-out}
PROBES=$OUT/probes
SUMMARY=$OUT/summary-probe.md
APPLEGPU=$ROOT/tools/ci-bench/applegpu
ARCHS=${ARCHS:-"applegpu_g13g amdgpu_gfx1012 intelgpu_kbl_gt2r0 intelgpu_icl_1x8x8r7"}

mkdir -p "$OUT" "$PROBES"
cd "$ROOT" || exit 1
: > "$SUMMARY"

note()
{
  echo "$*"
  echo "$*" >> "$SUMMARY"
}

note "# Funnel-shift probe: Apple's GPU compiler"
note ""
note "- $(sw_vers -productVersion) on $(uname -m), $(xcodebuild -version 2>/dev/null | head -1)"

if ! xcrun -sdk macosx -f metal > /dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain > "$OUT/metal-toolchain-download.txt" 2>&1
fi
if ! xcrun -sdk macosx -f metal-tt > /dev/null 2>&1; then
  note "- metal-tt not available; stopping"
  exit 0
fi
if [ ! -d "$APPLEGPU" ]; then
  git clone -q --depth 1 https://github.com/dougallj/applegpu "$APPLEGPU"
fi
LLVM_MC=
if [ -x "$(brew --prefix llvm 2>/dev/null)/bin/llvm-mc" ]; then
  LLVM_MC=$(brew --prefix llvm)/bin/llvm-mc
elif command -v brew > /dev/null 2>&1; then
  brew install llvm > "$OUT/brew-llvm.txt" 2>&1
  if [ -x "$(brew --prefix llvm 2>/dev/null)/bin/llvm-mc" ]; then
    LLVM_MC=$(brew --prefix llvm)/bin/llvm-mc
  fi
fi
note "- targets: $ARCHS; AMD disassembly: ${LLVM_MC:-none}"

python3 -I tools/ci-bench/extr_probes.py "$PROBES" > /dev/null
ARCHOPTS=
for a in $ARCHS; do
  ARCHOPTS="$ARCHOPTS -arch $a"
done

while IFS=$'\t' read -r name desc; do
  src=$PROBES/probe-$name.metal
  base=$PROBES/$name
  if ! xcrun -sdk macosx metal -O3 -o "$base.metallib" "$src" < /dev/null > "$base.metal.txt" 2>&1; then
    echo "$name	compile-error" >> "$PROBES/results.tsv"
    continue
  fi
  cat > "$base.mtlp-json" <<JSON
{ "libraries": { "paths": [ { "path": "$base.metallib", "label": "probe" } ] },
  "pipelines": { "compute_pipelines": [ { "compute_function": "probe" } ] } }
JSON
  if ! xcrun -sdk macosx metal-tt $ARCHOPTS "$base.metallib" "$base.mtlp-json" -o "$base-gpu.metallib" < /dev/null > "$base.tt.txt" 2>&1; then
    echo "$name	metal-tt-error" >> "$PROBES/results.tsv"
    continue
  fi
  python3 -I tools/ci-bench/metal_slices.py "$base-gpu.metallib" "$base" gfx1012 "$LLVM_MC" "$APPLEGPU" < /dev/null > "$base.slices.txt" 2>&1
  python3 -I - "$name" "$base" >> "$PROBES/results.tsv" <<'EOF'
import collections, glob, re, sys
name, base = sys.argv[1], sys.argv[2]
cols = [name]
# Apple M1: the first decodable body
agx = sorted(glob.glob(base + "-applegpu-*.agx"))
ins = []
for f in agx:
    t = open(f).read()
    if "disassembly failed" in t:
        continue
    ins = [l.split(None, 2)[2] for l in t.splitlines() if re.match(r"^\s*[0-9a-f]+:\s+[0-9a-f]+\s+\S", l)]
    break
if ins:
    ops = [i.split()[0] for i in ins]
    extr = [i for i in ins if i.startswith("extr")]
    imm = sum(1 for e in extr if re.search(r",\s*-?\d+\s*$", e))
    hist = collections.Counter(o for o in ops if o not in ("stop", "wait", "device_store", "device_load", "get_sr", "mov_imm"))
    cols += [str(len(ins)), str(imm), str(len(extr) - imm), " ".join("%s:%d" % kv for kv in hist.most_common(7))]
else:
    cols += ["-", "-", "-", "not decoded"]
# AMD gfx1012
s = sorted(glob.glob(base + "-amdgpu-gfx1012.s"))
if s:
    lines = [l.strip() for l in open(s[0]) if re.match(r"\s+[sv]_", l)]
    al = [l for l in lines if l.startswith("v_alignbit_b32")]
    aimm = sum(1 for l in al if re.search(r",\s*-?\d+\s*$", l))
    and31 = sum(1 for l in lines if l.startswith("v_and_b32") and re.search(r"\b31\b", l))
    valu = sum(1 for l in lines if l.startswith("v_"))
    cols += [str(valu), str(aimm), str(len(al) - aimm), str(and31)]
else:
    cols += ["-", "-", "-", "-"]
print("\t".join(cols))
EOF
done < "$PROBES/probes.txt"

note ""
note "| probe | source | M1 instrs | extr imm | extr reg | M1 ops (top) | AMD VALU | alignbit imm | alignbit reg | AMD and 31 |"
note "|---|---|---|---|---|---|---|---|---|---|"
python3 -I - "$PROBES/probes.txt" "$PROBES/results.tsv" >> "$SUMMARY" <<'EOF'
import sys
desc = dict(l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1]))
for l in open(sys.argv[2]):
    c = l.rstrip("\n").split("\t")
    c += [""] * (10 - len(c))
    print("| %s | %s | %s |" % (c[0], desc.get(c[0], "").replace("|", "\\|"), " | ".join(c[1:10])))
EOF
cat "$SUMMARY"
exit 0
