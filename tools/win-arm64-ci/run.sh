#!/bin/bash
# Run the RC5-72 test sequence on a built Windows client and collect the
# client's own logs (-l), unedited, into one evidence file.
#   run.sh <exe> <output dir> <name> [full|quick|bench] [expected core count]
# quick: -cpuinfo and -test only. bench: -cpuinfo, -test and -bench.
# The expected core count (default 8, or 'any') is checked against -test.
set -u
EXE=$1
OUT=$2
NAME=$3
MODE=${4:-full}
EXPECT=${5:-8}
mkdir -p "$OUT"
EV=$OUT/dnetc-$NAME.log
: > "$EV"

run()
{
  local n=$1
  shift
  {
    echo
    echo "### dnetc $*"
  } >> "$EV"
  timeout 1800 "$EXE" -l "$OUT/log-$n.txt" "$@" > "$OUT/console-$n.txt" 2>&1
  echo "dnetc $* -> exit code $?"
  cat "$OUT/log-$n.txt" >> "$EV" 2>/dev/null
}

run cpuinfo -cpuinfo
run test -test rc5-72
if [ "$MODE" = full ]
then
  run stress6 -stress rc5-72 6
  run stress7 -stress rc5-72 7
  run bench -bench rc5-72
  run crunch7 -runoffline -nodisk -c rc5-72 7 -h 0:02
elif [ "$MODE" = bench ]
then
  run bench -bench rc5-72
fi

c()
{
  tr '\r' '\n' < "$1" 2>/dev/null | grep -a -c -E "$2"
}
NT=$(c "$OUT/log-test.txt" 'RC5-72: using core #')
NP=$(c "$OUT/log-test.txt" 'RC5-72: 32/32 Tests Passed')
echo "--- summary ($NAME)"
echo "-test: $NP of $NT cores pass 32/32"
STATUS=0
if [ "$EXPECT" = any ]
then
  [ "$NT" -ge 1 ] && [ "$NP" = "$NT" ] || STATUS=1
else
  [ "$NT" = "$EXPECT" ] && [ "$NP" = "$EXPECT" ] || STATUS=1
fi
if [ "$MODE" = full ]
then
  for k in 6 7
  do
    S=$(c "$OUT/log-stress$k.txt" 'Stress-test [0-9] passed')
    echo "-stress core $k: $S of 4 passed"
    [ "$S" = 4 ] || STATUS=1
  done
  tr '\r' '\n' < "$OUT/log-bench.txt" | grep -a -E 'Benchmark for core|keys/sec' | sed -E 's/^\[[^]]*\] //'
  tr '\r' '\n' < "$OUT/log-crunch7.txt" | grep -a -E 'threads|crunchers|reached time limit|Shutdown complete|using core' | sed -E 's/^\[[^]]*\] //' | head -8
fi
if [ "$MODE" = bench ]
then
  tr '\r' '\n' < "$OUT/log-bench.txt" | grep -a -E 'Benchmark for core|keys/sec' | sed -E 's/^\[[^]]*\] //'
fi
exit $STATUS
