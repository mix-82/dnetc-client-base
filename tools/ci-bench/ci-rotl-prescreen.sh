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
note "## ROTL variants, optimised AIR (1-pipe)"
note ""
note "| variant | air.rotate | lshr i64 | shl i64 | shl i32 | lshr i32 | or | and | sub |"
note "|---|---|---|---|---|---|---|---|---|"
for f in tools/ci-bench/variants/rc5-1pipe-*.metal; do
  v=$(basename "$f" .metal | sed 's/rc5-1pipe-//')
  if xcrun -sdk macosx metal -O3 -S -emit-llvm -o "$OUT/variant-$v.ll" "$f" > "$OUT/variant-$v.txt" 2>&1; then
    L=$OUT/variant-$v.ll
    note "| $v | $(grep -c 'air.rotate' "$L") | $(grep -c 'lshr i64' "$L") | $(grep -c 'shl i64' "$L") | $(grep -c 'shl i32' "$L") | $(grep -c 'lshr i32' "$L") | $(grep -c ' or i' "$L") | $(grep -c ' and i' "$L") | $(grep -c ' sub i' "$L") |"
  else
    note "| $v | compile failed (variant-$v.txt) | | | | | | | |"
  fi
done
exit 0
