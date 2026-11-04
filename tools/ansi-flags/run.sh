#!/bin/sh
# Compiler-option experiment for the RC5-72 ANSI cores on arm64.
# linux-arm64 (gcc) or macosx-arm64 (clang), picked from uname.
#
# Builds the client once with configure's flags, then for each option set
# rebuilds only the three ANSI core objects and keeps the binary. Every
# binary must pass -test rc5-72. The benchmarks then run round-robin (round
# 1 of every set, then round 2, ...) so a drifting clock (the macOS runners
# are VMs) affects all sets alike, with a clock measurement before each run.
# Reports the median cycles/key and keys/sec per set and core (#0-2 = ANSI
# 4/2/1-pipe) in $OUT/results.md.
#
# Usage: tools/ansi-flags/run.sh [outdir] [rounds]
# Environment: MAKE_ARGS (extra make arguments, for cross testing),
#              RUN (e.g. qemu-aarch64), SETS_OVERRIDE (newline-separated sets),
#              CLOCKCC (compiler for clockcal.c, default cc).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/ansi-flags-out}
ROUNDS=${2:-3}
RUN=${RUN:-}
MAKE_ARGS=${MAKE_ARGS:-}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
cd "$ROOT" || exit 1
NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

case "$(uname -s)" in
Darwin)
  TARGET=macosx-arm64
  CUR="-Os"                       # configure's OPTS_CLANGCC
  CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  # -mcpu=apple-m1 is safe on every Apple Silicon Mac, not on Android
  SETS='-Os
-O2
-O2 -funroll-loops
-O3
-O3 -funroll-loops
-Os -funroll-loops
-O2 -funroll-loops -fomit-frame-pointer -fno-inline-functions
-O2 -funroll-loops -mcpu=apple-m1'
  ;;
*)
  TARGET=linux-arm64
  CUR="-O2 -funroll-loops"        # configure's internal-arm64 (gcc)
  CPU="part $(grep -m1 'CPU part' /proc/cpuinfo | sed 's/.*: //')"
  SETS='-O2 -funroll-loops
-O2
-O3 -funroll-loops
-O3
-Os
-Os -funroll-loops
-O2 -funroll-loops -finline-functions
-O2 -funroll-loops -mtune=cortex-a76'
  ;;
esac
[ -n "${SETS_OVERRIDE:-}" ] && SETS=$SETS_OVERRIDE

./configure $TARGET > "$OUT/configure.txt" 2>&1 || { echo "configure failed"; tail -20 "$OUT/configure.txt"; exit 1; }
cp Makefile Makefile.orig
grep '^CCFLAGS' Makefile | grep -q -- " $CUR " || { echo "CCFLAGS has no '$CUR'"; grep '^CCFLAGS' Makefile; exit 1; }
# A failing post-link step (e.g. -genman in a cross build) is tolerated if the
# binary was produced; -test below catches a broken binary.
eval make -j"$NCPU" $MAKE_ARGS > "$OUT/build-base.txt" 2>&1 || [ -x dnetc ] || { echo "base build failed"; tail -20 "$OUT/build-base.txt"; exit 1; }
CXX=$(sed -n 's/^CC = //p' Makefile)
COMPILER=$($CXX --version 2>&1 | head -1)
${CLOCKCC:-cc} -O2 tools/ansi-flags/clockcal.c -o "$OUT/clockcal" > "$OUT/clockcal-build.txt" 2>&1 || echo "clockcal build failed (no cycles/key)"

# ---- phase 1: one binary per option set ------------------------------------
echo "$SETS" > "$OUT/sets.txt"
n=0
while IFS= read -r set; do
  n=$((n + 1))
  sed "s|^\(CCFLAGS = .*\) $CUR |\1 $set |" Makefile.orig > Makefile
  rm -f output/r72ansi1.o output/r72ansi2.o output/r72ansi4.o dnetc
  eval make $MAKE_ARGS > "$OUT/build-$n.txt" 2>&1
  if [ ! -x dnetc ] || ! grep -q -- " $set " "$OUT/build-$n.txt"; then
    echo "set $n ($set): build failed"; echo "build failed" > "$OUT/test-$n.status"; continue
  fi
  cp dnetc "$OUT/dnetc-$n"
  $RUN "$OUT/dnetc-$n" -test rc5-72 > "$OUT/test-$n.txt" 2>&1
  echo "$(grep -cE '32/32 Tests Passed' "$OUT/test-$n.txt")/$(grep -cE 'using core #' "$OUT/test-$n.txt")" > "$OUT/test-$n.status"
  echo "set $n built and tested: $set ($(cat "$OUT/test-$n.status"))"
done < "$OUT/sets.txt"
cp Makefile.orig Makefile
NSETS=$n

# ---- phase 2: round-robin benchmarks ---------------------------------------
rate() {  # keys/sec from a -bench log
  sed -E 's/^\[[^]]*\] //' "$1" | grep -oE '\[[0-9,]+ keys/sec\]' | tail -1 | tr -d '[],' | awk '{print $1}'
}
: > "$OUT/data.txt"            # set core round keys ghz
r=0
while [ $r -lt "$ROUNDS" ]; do
  r=$((r + 1))
  n=0
  while [ $n -lt "$NSETS" ]; do
    n=$((n + 1))
    [ -x "$OUT/dnetc-$n" ] || continue
    for core in 0 1 2; do
      ghz=0
      [ -x "$OUT/clockcal" ] && ghz=$($RUN "$OUT/clockcal" 3 | awk '{print $1}')
      $RUN "$OUT/dnetc-$n" -bench rc5-72 $core > "$OUT/bench-$n-$core-$r.txt" 2>&1
      k=$(rate "$OUT/bench-$n-$core-$r.txt")
      echo "$n $core $r ${k:-0} ${ghz:-0}" >> "$OUT/data.txt"
    done
  done
  echo "round $r done"
done

# ---- report ----------------------------------------------------------------
{
  echo "# ANSI core option sets, $TARGET, $COMPILER"
  echo
  echo "CPU: $CPU x $NCPU; $ROUNDS rounds, round-robin; median cycles/key (median Mkeys/s)."
  echo "Current $TARGET set: \`$CUR\`."
  echo
  echo "| options | -test | #0 ANSI 4-pipe | #1 ANSI 2-pipe | #2 ANSI 1-pipe |"
  echo "|---|---|---|---|---|"
  n=0
  while IFS= read -r set; do
    n=$((n + 1))
    row="| \`$set\` | $(cat "$OUT/test-$n.status" 2>/dev/null)"
    for core in 0 1 2; do
      cell=$(awk -v n=$n -v c=$core '
             function med(a, cnt,   i, j, t) {
               for (i = 1; i <= cnt; i++) for (j = i + 1; j <= cnt; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
               return (cnt % 2) ? a[(cnt + 1) / 2] : (a[cnt / 2] + a[cnt / 2 + 1]) / 2 }
             $1 == n && $2 == c && $4 > 0 { k[++m] = $4; if ($5 > 0) y[++p] = $5 * 1e9 / $4 }
             END { if (!m) { print "-"; exit }
                   s = sprintf("%.2f M", med(k, m) / 1e6)
                   if (p) s = sprintf("%.0f c/k (%s)", med(y, p), s)
                   print s }' "$OUT/data.txt")
      row="$row | $cell"
    done
    echo "$row |"
  done < "$OUT/sets.txt"
} > "$OUT/results.md"
cat "$OUT/results.md"
