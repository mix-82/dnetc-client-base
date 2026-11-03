#!/bin/bash
# RC5-72 arm64 core comparison on an already built client: -cpuinfo,
# -test rc5-72, then ROUNDS rounds of -bench rc5-72 (every core, single
# thread). Writes per-round rates and a summary table of medians to
# tools/ci-bench/ci-out/ and, on GitHub Actions, to the job summary.
#
# Environment:
#   DNETC   client to run (default ./dnetc)
#   BUILD   short build name for the summary (e.g. "linux-arm64")
#   ROUNDS  benchmark rounds (default 3)
# No work is fetched or returned.
# Used by .github/workflows/arm64-bench.yml.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/ci-bench/ci-out
DNETC=${DNETC:-./dnetc}
BUILD=${BUILD:-unknown}
ROUNDS=${ROUNDS:-3}
STATUS=0

mkdir -p "$OUT"
cd "$ROOT" || exit 1

# ---- machine ---------------------------------------------------------
{
  uname -a
  if [ "$(uname -s)" = Darwin ]; then
    sw_vers
    sysctl -n machdep.cpu.brand_string
    sysctl -n hw.model
    echo "hw.ncpu=$(sysctl -n hw.ncpu) perflevel0=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)"
  else
    lscpu
    grep -m1 -E 'CPU part|CPU implementer' /proc/cpuinfo
    grep -E 'CPU implementer|CPU part' /proc/cpuinfo | sort | uniq -c
  fi
} > "$OUT/machine.txt" 2>&1

"$DNETC" -cpuinfo > "$OUT/cpuinfo.txt" 2>&1

# ---- self-test -------------------------------------------------------
"$DNETC" -test rc5-72 > "$OUT/test.txt" 2>&1 || STATUS=1
TESTS=$(sed -E 's/^\[[^]]*\] //' "$OUT/test.txt" | awk '
  /using core #/ { match($0, /#[0-9]+ \([^)]*\)/); core = substr($0, RSTART, RLENGTH) }
  /Tests Passed/ { print core ": " $2 }')
echo "$TESTS" | grep -vq ' 32/32' && STATUS=1

# ---- clock calibration -------------------------------------------------
CLOCKCAL=""
if cc -O2 "$ROOT/tools/ci-bench/clockcal.c" -o "$OUT/clockcal" > "$OUT/clockcal-build.txt" 2>&1; then
  CLOCKCAL="$OUT/clockcal"
fi

# ---- benchmark rounds --------------------------------------------------
: > "$OUT/clock.txt"
for r in $(seq 1 "$ROUNDS"); do
  [ -n "$CLOCKCAL" ] && "$CLOCKCAL" >> "$OUT/clock.txt"
  "$DNETC" -bench rc5-72 > "$OUT/bench-$r.txt" 2>&1 || STATUS=1
  sed -E 's/^\[[^]]*\] //' "$OUT/bench-$r.txt" | awk -v round="$r" '
    /Benchmark for core #/ { match($0, /#[0-9]+ \([^)]*\)/); core = substr($0, RSTART, RLENGTH) }
    /keys\/sec\]/ && core != "" {
      match($0, /\[[0-9,]+ keys\/sec\]/); rate = substr($0, RSTART + 1, RLENGTH - 11)
      gsub(",", "", rate); print round "\t" core "\t" rate; core = "" }'
done > "$OUT/rates.tsv"
[ -n "$CLOCKCAL" ] && "$CLOCKCAL" >> "$OUT/clock.txt"
# clock: median of the per-calibration medians, in GHz (0 if unavailable)
GHZ=$(awk '{ v[++n] = $1 } END { if (!n) { print 0; exit }
  for (a = 1; a <= n; a++) for (b = a + 1; b <= n; b++) if (v[b] < v[a]) { t = v[a]; v[a] = v[b]; v[b] = t }
  print (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2 }' "$OUT/clock.txt")

# ---- instruction-mix microbenchmark (tools/ci-bench/vmix.c, gen_vmix.py) ----
VMIX=""
if cc -O2 "$ROOT/tools/ci-bench/vmix.c" "$ROOT/tools/ci-bench/vmix.S" -o "$OUT/vmix" > "$OUT/vmix-build.txt" 2>&1; then
  "$OUT/vmix" 5 > "$OUT/vmix.md" 2>&1 && VMIX=1
fi

# ---- summary ---------------------------------------------------------
CPU=$(grep -m1 -E 'Model name|machdep|Apple' "$OUT/machine.txt" | sed -E 's/^Model name: *//')
{
  echo "## $BUILD: $CPU"
  echo
  echo "Self-test:"
  echo '```'
  echo "$TESTS"
  echo '```'
  echo
  echo "Clock (clockcal, median / range of medians, GHz): $GHZ / $(awk 'NR == 1 { lo = hi = $1 } { if ($1 < lo) lo = $1; if ($1 > hi) hi = $1 } END { printf "%.2f-%.2f", lo, hi }' "$OUT/clock.txt")"
  echo
  echo "| Core | Mkeys/s (median of $ROUNDS) | Rounds | vs NEON 8x4 | cycles/key |"
  echo "|---|---|---|---|---|"
  awk -F'\t' -v ghz="$GHZ" '
    { r[$2] = r[$2] (r[$2] == "" ? "" : " ") $3; if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } }
    END {
      for (i = 1; i <= n; i++) {
        c = order[i]; k = split(r[c], v, " ")
        for (a = 1; a <= k; a++) for (b = a + 1; b <= k; b++) if (v[b] + 0 < v[a] + 0) { t = v[a]; v[a] = v[b]; v[b] = t }
        med[c] = (k % 2) ? v[(k + 1) / 2] : (v[k / 2] + v[k / 2 + 1]) / 2
        list = ""; for (a = 1; a <= k; a++) list = list (a > 1 ? ", " : "") sprintf("%.1f", v[a] / 1e6)
        rounds[c] = list
        if (c ~ /NEON 8x4/) base = med[c]
      }
      for (i = 1; i <= n; i++) {
        c = order[i]
        rel = base ? sprintf("%+.1f%%", (med[c] / base - 1) * 100) : "-"
        cpk = ghz > 0 ? sprintf("%.0f", ghz * 1e9 / med[c]) : "-"
        printf "| %s | %.2f | %s | %s | %s |\n", c, med[c] / 1e6, rounds[c], rel, cpk
      }
    }' "$OUT/rates.tsv"
  if [ -n "$VMIX" ]; then
    echo
    echo "### Instruction-mix microbenchmark (cycles per unit, min of 5)"
    echo
    cat "$OUT/vmix.md"
  fi
} > "$OUT/summary.md"

cat "$OUT/summary.md"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
exit $STATUS
