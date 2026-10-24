#!/bin/bash
# ROTL spelling pre-screen for Apple's compiler. No GPU needed. Each file in
# tools/ci-bench/variants/ is the CL 1-pipe kernel with a different ROTL.
# The optimised AIR from the metal compiler shows whether the optimiser
# folded the spelling back into air.rotate (known to lower to 5
# instructions per variable rotate on AGX) or kept a 64-bit shift that the
# backend might turn into a single extr. Only survivors are worth a run on
# a real Mac (tools/ci-bench/ci-macos-gpu.sh).
#   usage: ci-rotl-prescreen.sh <out dir> <summary file>
# Used by ci-macos-arm64.sh and by the macos-rotl-prescreen CI job.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/tools/ci-bench/ci-out}
SUMMARY=${2:-$OUT/summary-prescreen.md}

mkdir -p "$OUT"
cd "$ROOT" || exit 1

note()
{
  echo "$*"
  echo "$*" >> "$SUMMARY"
}

note ""
note "## ROTL variants, optimised AIR"
note ""
note "| variant | air.rotate | fshl | lshr i64 | mul i64 | bitcast | shl i32 | lshr i32 | and | sub |"
note "|---|---|---|---|---|---|---|---|---|---|"
for f in tools/ci-bench/variants/rc5-*pipe-*.metal; do
  v=$(basename "$f" .metal | sed 's/^rc5-//')
  if xcrun -sdk macosx metal -O3 -S -emit-llvm -o "$OUT/variant-$v.ll" "$f" > "$OUT/variant-$v.txt" 2>&1; then
    L=$OUT/variant-$v.ll
    note "| $v | $(grep -c 'air.rotate' "$L") | $(grep -c 'fshl' "$L") | $(grep -c 'lshr i64' "$L") | $(grep -c 'mul nuw i64' "$L") | $(grep -c 'bitcast' "$L") | $(grep -c 'shl i32' "$L") | $(grep -c 'lshr i32' "$L") | $(grep -c ' and i' "$L") | $(grep -c ' sub i' "$L") |"
  else
    note "| $v | compile failed (variant-$v.txt) | | | | | | | | |"
  fi
done

# ---- predefined macros of Apple's OpenCL and Metal front ends ----------
# What a kernel can test with #if defined(...) to recognise the compiler.
OPENCLC=/System/Library/Frameworks/OpenCL.framework/Libraries/openclc
: > "$OUT/empty.cl"
note ""
note "## Predefined macros"
if [ -x "$OPENCLC" ]; then
  for arch in gpu_64 gpu_32; do
    if "$OPENCLC" -x cl -cl-std=CL1.1 -arch "$arch" -dM -E "$OUT/empty.cl" > "$OUT/openclc-macros-$arch.txt" 2> "$OUT/openclc-macros-$arch.err"; then
      note "- openclc -arch $arch: $(wc -l < "$OUT/openclc-macros-$arch.txt" | tr -d ' ') macros (openclc-macros-$arch.txt)"
    else
      note "- openclc -arch $arch: failed (openclc-macros-$arch.err)"
    fi
  done
  if [ -s "$OUT/openclc-macros-gpu_64.txt" ]; then
    note "- openclc gpu_64, vendor- or target-looking names:"
    grep -iE 'apple|mach|air|gpu|metal|opencl_c|cl_khr|cl_APPLE|__clang|__llvm|ENDIAN|IMAGE_SUPPORT|FAST_RELAXED' "$OUT/openclc-macros-gpu_64.txt" | sed 's/^/    /' >> "$SUMMARY"
  fi
else
  note "- openclc: not present"
fi
: > "$OUT/empty.metal"
if xcrun -sdk macosx metal -dM -E "$OUT/empty.metal" > "$OUT/metal-macros.txt" 2> "$OUT/metal-macros.err"; then
  note "- metal: $(wc -l < "$OUT/metal-macros.txt" | tr -d ' ') macros (metal-macros.txt)"
  note "- metal, vendor- or target-looking names:"
  grep -iE 'apple|mach|air|gpu|metal|__clang|__llvm|ENDIAN' "$OUT/metal-macros.txt" | sed 's/^/    /' >> "$SUMMARY"
else
  note "- metal -dM: failed (metal-macros.err)"
fi
exit 0
