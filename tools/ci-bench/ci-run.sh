#!/bin/sh
# Build the client and run the RC5-72 tester sequence:
#   dnetc -cpuinfo, -test, -stress, -bench
# then, on CPUs with AVX-512F, 4-minute offline runs on cores 4, 5 and 6;
# on CPUs without it, 1-minute runs that check that requests for cores 5
# and 6 fall back to #4.
# Results go to tools/ci-bench/ci-out/ (dnetc.log is the client's own log,
# as testers send it).
# Used by .github/workflows/avx512-bench.yml; also runs on any Linux x86-64
# machine with nasm, ispc and g++.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/ci-bench/ci-out
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
  echo "g++: $(g++ --version | head -1)"
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
# count the cores they actually ran: 7 with AVX-512F, 5 without
count()
{
  tr '\r' '\n' < "$1" | grep -a -c -E "$2"
}
NTEST=$(count "$OUT/console-test.txt" 'RC5-72: using core #')
NSTRESS=$(count "$OUT/console-stress.txt" 'RC5-72: using core #')
TPASS=$(count "$OUT/console-test.txt" 'RC5-72: 32/32 Tests Passed')
SPASS=$(count "$OUT/console-stress.txt" 'RC5-72: Stress-test [0-9] passed')
NCORES=5
if [ "$AVX512" = yes ]
then
  NCORES=7
fi
if [ "$NTEST" != "$NCORES" ] || [ "$TPASS" != "$NTEST" ] ||
   [ "$NSTRESS" != "$NCORES" ] || [ "$SPASS" != $((NSTRESS * 4)) ] ||
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
  # -bench must pick #6 (MIX ZMM) as the default core
  tr '\r' '\n' < "$OUT/console-bench.txt" | grep -a -q 'Default core : #6 ' || STATUS=1

  # 4-minute runs on random local work (-runoffline: no keyserver contact).
  # The client exits with code 3 after stopping at the -h time limit, so
  # check its shutdown message instead of the exit code.
  for c in 4 5 6
  do
    $D -runoffline -nodisk -c rc5-72 $c -h 0:04 > "$OUT/console-run-core$c.txt" 2>&1
    timedout "$OUT/console-run-core$c.txt" || STATUS=1
  done
else
  # no AVX-512F: requests for #5 and #6 must fall back to #4 (YK AVX2);
  # the client reports this as "... is not supported ... Using core #4 (YK AVX2) instead."
  tr '\r' '\n' < "$OUT/console-bench.txt" | grep -a -q 'Default core : #4 ' || STATUS=1
  for c in 5 6
  do
    $D -runoffline -nodisk -c rc5-72 $c -h 0:01 > "$OUT/console-run-core$c.txt" 2>&1
    timedout "$OUT/console-run-core$c.txt" || STATUS=1
    tr '\r' '\n' < "$OUT/console-run-core$c.txt" | grep -a -q -i 'using core #4 ' || STATUS=1
  done
fi

# rate at the last full round (completed packets a multiple of the CPU count),
# ignoring the summary the client prints when it stops at the time limit
lastround()
{
  tr '\r' '\n' < "$1" | sed 's/^\[[^]]*\] //' | awk -v n="$(nproc)" '
    /Shutdown - reached time limit/ { stop = 1 }
    stop { next }
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
    for c in 5 6
    do
      echo "-c rc5-72 $c ran as: $(tr '\r' '\n' < "$OUT/console-run-core$c.txt" | grep -a -o -i -m1 -E 'using core #[0-9]+ \([^)]*\)' | sed 's/^[Uu]sing //')"
    done
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
    for c in 4 5 6
    do
      echo "  core #$c: $(lastround "$OUT/console-run-core$c.txt")"
    done
  fi
  echo '```'
} > "$OUT/summary.md"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
then
  cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi
cat "$OUT/summary.md"
exit $STATUS
