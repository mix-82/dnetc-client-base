#!/bin/sh
# Build the client and r72bench and run the RC5-72 tester sequence:
#   dnetc -cpuinfo, -test, -stress, -bench
# then, on CPUs with AVX-512F, r72bench and 4-minute offline runs on cores
# 6, 7, 8 and 9; on CPUs without it, a 1-minute run that checks a request for
# core #9 falls back to #4. Results go to tools/r72bench/ci-out/ (dnetc.log is
# the client's own log, as testers send it).
# Used by .github/workflows/avx512-bench.yml; also runs on any Linux x86-64
# machine with nasm, ispc, gcc (static glibc) and python3.
# SECS and ROUNDS (default 3 and 3) are passed to r72bench's run.sh.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/r72bench/ci-out
SECS=${SECS:-3}
ROUNDS=${ROUNDS:-3}
STATUS=0
AVX512=no
if grep -q -w avx512f /proc/cpuinfo
then
  AVX512=yes
fi

mkdir -p "$OUT"
cd "$ROOT" || exit 1

{
  echo "== $(date -u '+%Y-%m-%d %H:%M UTC'), AVX-512F: $AVX512"
  lscpu
  echo
  echo "load average: $(cat /proc/loadavg)"
  echo "nasm: $(nasm -v)"
  echo "ispc: $(ispc --version 2>&1 | head -1)"
  echo "gcc: $(gcc --version | head -1)"
  echo "commit: $(git rev-parse --short HEAD 2>/dev/null)"
} > "$OUT/system.txt" 2>&1

# client build
if ! { SHELL=/bin/sh ./configure linux-amd64 && make -j"$(nproc)"; } > "$OUT/client-build.log" 2>&1
then
  echo "client build failed" | tee -a "$OUT/client-build.log"
  exit 1
fi

# tester sequence; -l replaces the -config logging setup
D="./dnetc -l $OUT/dnetc.log"
$D -cpuinfo > "$OUT/console-cpuinfo.txt" 2>&1
$D -test > "$OUT/console-test.txt" 2>&1
$D -stress > "$OUT/console-stress.txt" 2>&1
$D -bench > "$OUT/console-bench.txt" 2>&1

# -test and -stress skip cores that would be substituted on this CPU, so
# count the cores they actually ran
count()
{
  tr '\r' '\n' < "$1" | grep -a -c -E "$2"
}
NTEST=$(count "$OUT/console-test.txt" 'RC5-72: using core #')
NSTRESS=$(count "$OUT/console-stress.txt" 'RC5-72: using core #')
TPASS=$(count "$OUT/console-test.txt" 'RC5-72: 32/32 Tests Passed')
SPASS=$(count "$OUT/console-stress.txt" 'RC5-72: Stress-test [0-9] passed')
if [ "$NTEST" -lt 5 ] || [ "$TPASS" != "$NTEST" ] ||
   [ "$NSTRESS" -lt 5 ] || [ "$SPASS" != $((NSTRESS * 4)) ] ||
   tr '\r' '\n' < "$OUT/console-stress.txt" | grep -a -q FAILED
then
  STATUS=1
fi

# a timed run ended normally at its -h limit
timedout()
{
  tr '\r' '\n' < "$1" | grep -a -q 'Shutdown - reached time limit' &&
  tr '\r' '\n' < "$1" | grep -a -q 'Shutdown complete'
}

if [ "$AVX512" = yes ]
then
  # r72bench: 1 thread, 2 SMT siblings, all CPUs
  if make -C tools/r72bench > "$OUT/r72bench-build.log" 2>&1 &&
     make -C tools/r72bench verify >> "$OUT/r72bench-build.log" 2>&1
  then
    (cd tools/r72bench && SECS="$SECS" ROUNDS="$ROUNDS" sh run.sh > /dev/null 2>&1)
    cp tools/r72bench/bench-report.txt "$OUT/" 2>/dev/null
    grep -q "all tests passed" "$OUT/bench-report.txt" 2>/dev/null || STATUS=1
  else
    echo "r72bench build or verify failed" >> "$OUT/r72bench-build.log"
    STATUS=1
  fi

  # 4-minute runs on random local work (-runoffline: no keyserver contact).
  # The client exits with code 3 after stopping at the -h time limit, so
  # check its shutdown message instead of the exit code.
  for c in 6 7 8 9
  do
    $D -runoffline -nodisk -c rc5-72 $c -h 0:04 > "$OUT/console-run-core$c.txt" 2>&1
    timedout "$OUT/console-run-core$c.txt" || STATUS=1
  done
else
  # no AVX-512F: a request for #9 must fall back to #4 (YK AVX2)
  $D -runoffline -nodisk -c rc5-72 9 -h 0:01 > "$OUT/console-run-core9.txt" 2>&1
  timedout "$OUT/console-run-core9.txt" || STATUS=1
  tr '\r' '\n' < "$OUT/console-run-core9.txt" | grep -a -q 'using core #4 ' || STATUS=1
fi

# rate at the last full round (completed packets a multiple of the CPU count)
lastround()
{
  tr '\r' '\n' < "$1" | sed 's/^\[[^]]*\] //' | awk -v n="$(nproc)" '
    /Summary: [0-9]+ packets/ { p = $3; next }
    /Mkeys\/s\]/ && p != "" {
      if (p % n == 0) { t = $1; r = $0; sub(/.*\[/, "", r); sub(/\].*/, "", r); lp = p }
      p = "" }
    END { if (lp != "") print lp " packets, " t ", " r; else print "no full round" }'
}

# short summary, also shown on the workflow run page
{
  echo "#### $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
  echo '```'
  grep -m1 '^cpu family' /proc/cpuinfo
  grep -m1 -E '^model[[:space:]]*:' /proc/cpuinfo
  grep -m1 '^stepping' /proc/cpuinfo
  echo "vCPUs: $(nproc), cpu0 SMT siblings: $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list 2>/dev/null), AVX-512F: $AVX512"
  echo
  echo "dnetc -test: $TPASS of $NTEST cores passed 32/32 (cores tested: $(tr '\r' '\n' < "$OUT/console-test.txt" | grep -a -o -E 'using core #[0-9]+' | sed 's/using core //' | tr '\n' ' '))"
  echo "dnetc -stress: $SPASS of $((NSTRESS * 4)) stress tests passed on $NSTRESS cores"
  if [ "$AVX512" = no ]
  then
    echo "-c rc5-72 9 ran as: $(tr '\r' '\n' < "$OUT/console-run-core9.txt" | grep -a -o -m1 -E 'using core #[0-9]+ \([^)]*\)' | sed 's/using //')"
  fi
  echo
  echo "dnetc -bench rc5-72 (1 thread):"
  tr '\r' '\n' < "$OUT/console-bench.txt" | sed 's/^\[[^]]*\] //' |
    awk '/Benchmark for core/ { sub(/^RC5-72: Benchmark for core /, ""); c = $0; next }
         /keys\/sec\]/ && c != "" { match($0, /\[[0-9,]+ keys\/sec\]/); print "  " c ": " substr($0, RSTART + 1, RLENGTH - 2); c = "" }
         /Default core|Fastest core/ { sub(/^ +/, ""); print "  " $0 }'
  if [ "$AVX512" = yes ]
  then
    echo
    echo "4-minute runs, all $(nproc) CPUs (rate at the last full round; ~1 s timing steps):"
    for c in 6 7 8 9
    do
      echo "  core #$c: $(lastround "$OUT/console-run-core$c.txt")"
    done
    echo
    grep -E '^(sweep|  core|  [zc][0-9 ]+\()' "$OUT/bench-report.txt" 2>/dev/null
  fi
  echo '```'
} > "$OUT/summary.md"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
then
  cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi
cat "$OUT/summary.md"
exit $STATUS
