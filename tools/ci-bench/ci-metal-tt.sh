#!/bin/bash
# Offline GPU code for every target Apple's Metal toolchain knows, with no
# GPU needed: the kernels' Metal translations (tools/ci-bench/variants, base
# = rotate() as shipped, astype = the funnel-shift form) go through metal
# to AIR and then through metal-tt, whose native translators (applegpu-nt,
# amdgpu-nt, intelgpu-nt) produce one Mach-O slice per GPU. The slices are
# split out (metal_slices.py); Apple bodies are sized, hashed and, for the
# G13/G14 families, disassembled with the applegpu tools; AMD bodies are
# disassembled with llvm-mc from Homebrew LLVM when it is present. Results
# and summary-tt.md go to the directory given as the first argument.
#
# usage: ci-metal-tt.sh <out-dir>
# Run from the source root. Used by .github/workflows/ci-platforms.yml on
# both the Intel and the Apple Silicon runners (the Xcode version decides
# which GPU families are available: Xcode 16 stops at the M4 generation).

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/tools/ci-bench/ci-out}
SUMMARY=$OUT/summary-tt.md
APPLEGPU=$ROOT/tools/ci-bench/applegpu
# every rc5-*.metal in variants/ unless VARIANTS names a subset
VARIANTS=${VARIANTS:-$(ls "$ROOT"/tools/ci-bench/variants/rc5-*.metal | sed 's|.*/rc5-||; s|\.metal$||' | tr '\n' ' ')}

mkdir -p "$OUT"
cd "$ROOT" || exit 1

note()
{
  echo "$*"
  echo "$*" >> "$SUMMARY"
}

run_step()
{
  local name=$1
  shift
  "$@" > "$OUT/$name.txt" 2>&1
  local rc=$?
  note "- $name: exit $rc"
  return $rc
}

: > "$SUMMARY"
note "# metal-tt offline GPU code"
note ""
note "- $(sw_vers -productVersion) on $(uname -m), $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"

# the Metal toolchain: part of Xcode up to 16, a downloadable component from 26
if ! xcrun -sdk macosx -f metal > /dev/null 2>&1; then
  run_step metal-toolchain-download xcodebuild -downloadComponent MetalToolchain
fi
if ! xcrun -sdk macosx -f metal-tt > "$OUT/metal-tt-path.txt" 2>&1; then
  note "- metal-tt not available; stopping"
  exit 0
fi
note "- translators: $(ls "$(dirname "$(cat "$OUT/metal-tt-path.txt")")" | grep -E 'nt$' | tr '\n' ' ')"

LLVM_MC=
if [ -x "$(brew --prefix llvm 2>/dev/null)/bin/llvm-mc" ]; then
  LLVM_MC=$(brew --prefix llvm)/bin/llvm-mc
fi
if [ ! -d "$APPLEGPU" ]; then
  run_step applegpu-clone git clone -q --depth 1 https://github.com/dougallj/applegpu "$APPLEGPU"
fi

for v in $VARIANTS; do
  METAL=tools/ci-bench/variants/rc5-$v.metal
  p=${v%%pipe-*}
  FN=ocl_rc572_${p}pipe
  note ""
  note "## $v"
  run_step "metallib-$v" xcrun -sdk macosx metal -O3 -o "$OUT/$v.metallib" "$METAL" || continue
  cat > "$OUT/$v.mtlp-json" <<JSON
{ "libraries": { "paths": [ { "path": "$OUT/$v.metallib", "label": "rc5" } ] },
  "pipelines": { "compute_pipelines": [ { "compute_function": "$FN" } ] } }
JSON
  run_step "metal-tt-$v" xcrun -sdk macosx metal-tt -verbose "$OUT/$v.metallib" "$OUT/$v.mtlp-json" -o "$OUT/$v-gpu.metallib" || continue
  if [ ! -s "$OUT/targets.txt" ]; then
    grep -oE '\-arch [a-z_0-9]+' "$OUT/metal-tt-$v.txt" | sort -u | sed 's/-arch //' | tr '\n' ' ' > "$OUT/targets.txt"
    note "- targets: $(cat "$OUT/targets.txt")"
  fi
  python3 -I tools/ci-bench/metal_slices.py "$OUT/$v-gpu.metallib" "$OUT/$v" gfx1012 "$LLVM_MC" "$APPLEGPU" > "$OUT/slices-$v.txt" 2>&1
  # Apple: one line per distinct code body
  note "### Apple GPU bodies"
  grep -E 'slice applegpu|main body|disassembled|not decodable' "$OUT/slices-$v.txt" | python3 -I -c '
import sys, re
bodies = {}
cur = None
for l in sys.stdin:
    m = re.search(r"slice applegpu-(\S+) subtype", l)
    if m:
        cur = m.group(1)
        continue
    m = re.search(r"main body (\d+) bytes, sha (\w+)", l)
    if m:
        b = bodies.setdefault(m.group(2), {"size": int(m.group(1)), "subs": [], "info": ""})
        b["subs"].append(cur)
        continue
    m = re.search(r"disassembled: (\d+) instructions; (.*)", l)
    if m and cur:
        for b in bodies.values():
            if cur in b["subs"]:
                b["info"] = "%s instructions (%d per key): %s" % (m.group(1), int(m.group(1)) // '"$p"', m.group(2))
        continue
    if "not decodable" in l and cur:
        for b in bodies.values():
            if cur in b["subs"]:
                b["info"] = "not decodable (G15 or later)"
for sha, b in sorted(bodies.items(), key=lambda kv: kv[1]["size"]):
    print("    %6d bytes  %s  [%s]  %s" % (b["size"], sha, " ".join(b["subs"]), b["info"]))
' >> "$SUMMARY"
  # AMD: one line per gfx
  if [ -n "$LLVM_MC" ]; then
    note "### AMD (llvm-mc)"
    for asm in "$OUT/$v"-amdgpu-gfx*.s; do
      [ -s "$asm" ] || continue
      g=$(basename "$asm" .s | sed 's/.*amdgpu-//')
      python3 -I tools/ci-bench/isa_counts.py "$asm" "$p" "$FN" 2>/dev/null | sed -n '2,3p' | tr '\n' ' ' | sed "s/^/    $g: /; s/- //g" >> "$SUMMARY"
      echo "and31 $(grep -cE 'v_and_b32.* 31, ' "$asm")" >> "$SUMMARY"
    done
  fi
done

note ""
note "Done."
exit 0
