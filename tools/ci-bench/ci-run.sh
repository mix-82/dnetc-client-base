#!/bin/bash
# Run the RC5-72 tester sequence on an already built client:
#   dnetc -cpuinfo, -test, -stress, -bench
# then, for 64-bit x86 builds (ARCH=amd64): on CPUs with AVX-512F, check
# that -bench picks #6 (MIX ZMM) and make 4-minute offline runs on cores
# 4, 5 and 6; on CPUs without it, check that -bench picks #4 and that
# requests for cores 5 and 6 fall back to #4.
# 32-bit x86 builds (ARCH=x86) only run the tester sequence.
# Results go to tools/ci-bench/ci-out/ (dnetc.log is the client's own log,
# as testers send it).
#
# Environment:
#   DNETC  client to run (default ./dnetc; dnetc.com on Windows)
#   ARCH   amd64 or x86
#   BUILD  short build name for the summary (e.g. "linux-amd64")
# Used by .github/workflows/ci-platforms.yml on Linux, macOS and Windows
# (Git Bash). No work is fetched or returned (-runoffline -nodisk).

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/ci-bench/ci-out
DNETC=${DNETC:-./dnetc}
ARCH=${ARCH:-amd64}
BUILD=${BUILD:-unknown}
STATUS=0

mkdir -p "$OUT"
cd "$ROOT" || exit 1

case "$(uname -s)" in
  Linux)
    OS=linux
    ;;
  Darwin)
    OS=macos
    ;;
  MINGW*|MSYS*|CYGWIN*)
    OS=windows
    ;;
  *)
    OS=other
    ;;
esac

ncpu()
{
  getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1
}

cpumodel()
{
  case $OS in
    linux)
      grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'
      ;;
    macos)
      sysctl -n machdep.cpu.brand_string
      ;;
    windows)
      pwsh -NoProfile -Command '(Get-CimInstance Win32_Processor).Name' | tr -d '\r'
      ;;
  esac
}

# does the CPU (and OS) support AVX-512F, independently of the client?
has_avx512f()
{
  case $OS in
    linux)
      grep -q -w avx512f /proc/cpuinfo
      ;;
    macos)
      sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -q -w AVX512F
      ;;
    windows)
      [ "$(pwsh -NoProfile -Command '[System.Runtime.Intrinsics.X86.Avx512F]::IsSupported' | tr -d '\r')" = "True" ]
      ;;
    *)
      return 1
      ;;
  esac
}

AVX512=no
if has_avx512f
then
  AVX512=yes
fi

{
  echo "== $(date -u '+%Y-%m-%d %H:%M UTC'), $BUILD, $OS"
  echo "CPU: $(cpumodel), $(ncpu) logical CPUs, AVX-512F: $AVX512"
  case $OS in
    linux)
      lscpu
      ;;
    macos)
      sysctl machdep.cpu
      ;;
    windows)
      pwsh -NoProfile -Command 'Get-CimInstance Win32_Processor | Format-List Name,Manufacturer,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed'
      ;;
  esac
  echo "commit: $(git rev-parse --short HEAD 2>/dev/null)"
} > "$OUT/system.txt" 2>&1

# one log per step (-l replaces the -config logging setup); dnetc.log is
# all of them in order
run()
{
  local name=$1
  shift
  "$DNETC" -l "$OUT/log-$name.txt" "$@" > "$OUT/console-$name.txt" 2>&1
  tr '\r' '\n' < "$OUT/log-$name.txt" >> "$OUT/dnetc.log" 2>/dev/null
}

: > "$OUT/dnetc.log"
run cpuinfo -cpuinfo
run test -test
run stress -stress
run bench -bench

count()
{
  tr '\r' '\n' < "$1" | grep -a -c -E "$2"
}
L=$OUT/log
NTEST=$(count "$L-test.txt" 'RC5-72: using core #')
NSTRESS=$(count "$L-stress.txt" 'RC5-72: using core #')
TPASS=$(count "$L-test.txt" 'RC5-72: 32/32 Tests Passed')
SPASS=$(count "$L-stress.txt" 'RC5-72: Stress-test [0-9] passed')
if [ "$NTEST" -lt 1 ] || [ "$TPASS" != "$NTEST" ] ||
   [ "$NSTRESS" -lt 1 ] || [ "$SPASS" != $((NSTRESS * 4)) ] ||
   tr '\r' '\n' < "$L-stress.txt" | grep -a -q FAILED
then
  STATUS=1
fi

# the client's own AVX-512 detection must agree with the OS
CLIENT_AVX512=no
if tr '\r' '\n' < "$L-cpuinfo.txt" | grep -a -q -w AVX512
then
  CLIENT_AVX512=yes
fi
if [ "$CLIENT_AVX512" != "$AVX512" ]
then
  STATUS=1
fi

# a timed run ended normally at its -h limit
timedout()
{
  tr '\r' '\n' < "$1" | grep -a -q 'Shutdown - reached time limit' &&
  tr '\r' '\n' < "$1" | grep -a -q 'Shutdown complete'
}

if [ "$ARCH" = amd64 ]
then
  if [ "$AVX512" = yes ]
  then
    # 7 cores; -bench must pick #6 (MIX ZMM) as the default core
    [ "$NTEST" = 7 ] || STATUS=1
    tr '\r' '\n' < "$L-bench.txt" | grep -a -q 'Default core : #6 ' || STATUS=1
    # 4-minute runs on random local work (-runoffline: no keyserver contact).
    # The client exits with code 3 after stopping at the -h time limit, so
    # check its shutdown message instead of the exit code.
    for c in 4 5 6
    do
      run core$c -runoffline -nodisk -c rc5-72 $c -h 0:04
      timedout "$L-core$c.txt" || STATUS=1
    done
  else
    # 5 cores; requests for #5 and #6 must fall back to #4 (YK AVX2), which
    # the client reports as "... is not supported ... Using core #4 (YK AVX2) instead."
    [ "$NTEST" = 5 ] || STATUS=1
    tr '\r' '\n' < "$L-bench.txt" | grep -a -q 'Default core : #4 ' || STATUS=1
    for c in 5 6
    do
      run core$c -runoffline -nodisk -c rc5-72 $c -h 0:01
      timedout "$L-core$c.txt" || STATUS=1
      tr '\r' '\n' < "$L-core$c.txt" | grep -a -q -i 'using core #4 ' || STATUS=1
    done
  fi
fi

# rate at the last full round (completed packets a multiple of the CPU count),
# ignoring the summary the client prints when it stops at the time limit
lastround()
{
  tr '\r' '\n' < "$1" | sed 's/^\[[^]]*\] //' | awk -v n="$(ncpu)" '
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
  echo "#### $BUILD: $(cpumodel)"
  echo '```'
  echo "OS: $OS, logical CPUs: $(ncpu), AVX-512F: $AVX512 (client -cpuinfo: $CLIENT_AVX512)"
  echo
  echo "dnetc -test: $TPASS of $NTEST cores passed 32/32 (cores tested: $(tr '\r' '\n' < "$L-test.txt" | grep -a -o -E 'using core #[0-9]+' | sed 's/using core //' | tr '\n' ' '))"
  echo "dnetc -stress: $SPASS of $((NSTRESS * 4)) stress tests passed on $NSTRESS cores"
  if [ "$ARCH" = amd64 ] && [ "$AVX512" = no ]
  then
    for c in 5 6
    do
      echo "-c rc5-72 $c ran as: $(tr '\r' '\n' < "$L-core$c.txt" | grep -a -o -i -m1 -E 'using core #[0-9]+ \([^)]*\)' | sed 's/^[Uu]sing //')"
    done
  fi
  echo
  echo "dnetc -bench rc5-72 (1 thread):"
  tr '\r' '\n' < "$L-bench.txt" | sed 's/^\[[^]]*\] //' |
    awk '/Benchmark for core/ { sub(/^.*Benchmark for core /, ""); c = $0; next }
         /keys\/sec\]/ && c != "" { match($0, /\[[0-9,]+ keys\/sec\]/); print "  " c ": " substr($0, RSTART + 1, RLENGTH - 2); c = "" }
         /Default core|Fastest core/ { sub(/^ +/, ""); print "  " $0 }'
  if [ "$ARCH" = amd64 ] && [ "$AVX512" = yes ]
  then
    echo
    echo "4-minute runs, all $(ncpu) CPUs (rate at the last full round; ~1 s timing steps):"
    for c in 4 5 6
    do
      echo "  core #$c: $(lastround "$L-core$c.txt")"
    done
  fi
  if [ "$STATUS" != 0 ]
  then
    echo
    echo "FAILED: see the logs in the artifact"
  fi
  echo '```'
} > "$OUT/summary.md"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
then
  cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi
cat "$OUT/summary.md"
exit $STATUS
