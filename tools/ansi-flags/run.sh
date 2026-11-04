#!/bin/sh
# Compiler-option experiment for the RC5-72 ANSI cores on linux-arm64 (gcc).
# Builds the client once with configure's flags, then for each option set
# rebuilds only the three ANSI core objects, relinks, runs -test rc5-72 and
# times cores #0-2 (ANSI 4/2/1-pipe). Results go to $OUT/results.md.
#
# Usage: tools/ansi-flags/run.sh [outdir] [rounds]
# Environment: MAKE_ARGS (e.g. "CC=aarch64-linux-gnu-g++ AS='aarch64-linux-gnu-gcc -c'"),
#              RUN (e.g. "qemu-aarch64 -L /usr/aarch64-linux-gnu") for cross testing.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/ansi-flags-out}
ROUNDS=${2:-2}
RUN=${RUN:-}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
cd "$ROOT" || exit 1

# Option sets, taken from configure's per-platform conventions. Each replaces
# "-O2 -funroll-loops" in the linux-arm64 CCFLAGS; the shared base stays.
SETS='-O2 -funroll-loops
-O2
-O3 -funroll-loops
-O3
-Os
-Os -funroll-loops
-O2 -funroll-loops -finline-functions
-O2 -funroll-loops -mtune=cortex-a76'
[ -n "${SETS_OVERRIDE:-}" ] && SETS=$SETS_OVERRIDE

./configure linux-arm64 > "$OUT/configure.txt" 2>&1 || { echo "configure failed"; exit 1; }
cp Makefile Makefile.orig
grep -q -- ' -O2 -funroll-loops ' Makefile || { echo "CCFLAGS has no -O2 -funroll-loops"; exit 1; }
# A failing post-link step (e.g. -genman in a cross build) is tolerated if the
# binary was produced; the -test run below catches a broken binary.
eval make -j"$(nproc)" $MAKE_ARGS > "$OUT/build-base.txt" 2>&1 || [ -x dnetc ] || { echo "base build failed"; tail -20 "$OUT/build-base.txt"; exit 1; }
"$(command -v gcc)" --version | head -1 > "$OUT/gcc.txt" 2>&1

rate() {  # keys/sec from a -bench log
  sed -E 's/^\[[^]]*\] //' "$1" | grep -oE '\[[0-9,]+ keys/sec\]' | tail -1 | tr -d '[],' | awk '{print $1}'
}

{
  echo "# ANSI core option sets, linux-arm64, $(cat "$OUT/gcc.txt")"
  echo
  echo "CPU: $(grep -m1 -E 'CPU part|model name' /proc/cpuinfo | sed 's/.*: //') x $(nproc); rounds per set: $ROUNDS (keys/sec, best of rounds)"
  echo
  echo "| options | -test | #0 ANSI 4-pipe | #1 ANSI 2-pipe | #2 ANSI 1-pipe |"
  echo "|---|---|---|---|---|"
} > "$OUT/results.md"

n=0
echo "$SETS" | while IFS= read -r set; do
  n=$((n + 1))
  sed "s|^\(CCFLAGS = .*\) -O2 -funroll-loops |\1 $set |" Makefile.orig > Makefile
  rm -f output/r72ansi1.o output/r72ansi2.o output/r72ansi4.o dnetc
  eval make $MAKE_ARGS > "$OUT/build-$n.txt" 2>&1
  if [ ! -x dnetc ] || [ output/r72ansi4.o -ot Makefile ]; then
    echo "| \`$set\` | build failed | - | - | - |" >> "$OUT/results.md"; continue
  fi
  grep -c -- "$set" "$OUT/build-$n.txt" > /dev/null || echo "warning: set $n not seen in build log"
  $RUN ./dnetc -test rc5-72 > "$OUT/test-$n.txt" 2>&1
  passed=$(grep -cE '32/32 Tests Passed' "$OUT/test-$n.txt")
  total=$(grep -cE 'using core #' "$OUT/test-$n.txt")
  t="$passed/$total"
  r=""
  for core in 0 1 2; do
    best=0
    i=0
    while [ $i -lt "$ROUNDS" ]; do
      i=$((i + 1))
      $RUN ./dnetc -bench rc5-72 $core > "$OUT/bench-$n-$core-$i.txt" 2>&1
      k=$(rate "$OUT/bench-$n-$core-$i.txt"); k=${k:-0}
      [ "$k" -gt "$best" ] && best=$k
    done
    r="$r | $best"
  done
  echo "| \`$set\` | $t$r |" >> "$OUT/results.md"
  echo "set $n done: $set"
done

cp Makefile.orig Makefile
cat "$OUT/results.md"
