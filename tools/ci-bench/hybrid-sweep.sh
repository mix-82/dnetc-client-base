#!/bin/sh
# Sweep the MIX HYB generator's --split on this machine: rebuild only the
# hybrid core per split, self-test all cores, bench core #8 once per round.
# Usage: tools/ci-bench/hybrid-sweep.sh [outdir] [rounds]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/sweep-out}
ROUNDS=${2:-2}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
cd "$ROOT" || exit 1
SPLITS="20 23 26 29 32 35 38 41"

./configure linux-arm64 > "$OUT/cfg.log" 2>&1 || exit 1
make -j"$(getconf _NPROCESSORS_ONLN)" > "$OUT/build.log" 2>&1 || [ -x dnetc ] || { tail -5 "$OUT/build.log"; exit 1; }
cc -O2 tools/ci-bench/clockcal.c -o "$OUT/clockcal"
rate() { sed -E 's/^\[[^]]*\] //' "$1" | grep -oE '\[[0-9,]+ keys/sec\]' | tail -1 | tr -d '[],' | awk '{print $1}'; }

{
  echo "## MIX HYB split sweep, $(grep -m1 -E 'CPU part|model name' /proc/cpuinfo | sed 's/.*: //')"
  echo
  echo "| split (first vector step) | -test | keys/sec (best of $ROUNDS) | GHz | cycles/key |"
  echo "|---|---|---|---|---|"
} > "$OUT/results.md"

for sp in $SPLITS; do
  python3 rc5-72/arm64/tools/gen_hybrid.py --split=$sp > rc5-72/arm64/r72-neon-hyb.S || continue
  rm -f output/r72-neon-hyb.s.o dnetc
  make > "$OUT/b$sp.log" 2>&1 || [ -x dnetc ] || { echo "| $sp | build failed | - | - | - |" >> "$OUT/results.md"; continue; }
  ./dnetc -test rc5-72 > "$OUT/t$sp.log" 2>&1
  pass=$(grep -cE '32/32 Tests Passed' "$OUT/t$sp.log")
  best=0; ghz=0
  r=0
  while [ $r -lt "$ROUNDS" ]; do
    r=$((r + 1))
    ghz=$("$OUT/clockcal" 5 | awk '{print $1}')
    ./dnetc -bench rc5-72 8 > "$OUT/k$sp-$r.log" 2>&1
    k=$(rate "$OUT/k$sp-$r.log"); k=${k:-0}
    [ "$k" -gt "$best" ] && best=$k
  done
  cpk=$(awk -v g="$ghz" -v r="$best" 'BEGIN { if (r > 0) printf "%.0f", g * 1e9 / r; else print "-" }')
  echo "| $sp | $pass/9 | $best | $ghz | $cpk |" >> "$OUT/results.md"
  echo "split $sp done: $best keys/s, $cpk c/k"
done
git checkout -- rc5-72/arm64/r72-neon-hyb.S 2>/dev/null || true
cat "$OUT/results.md"
