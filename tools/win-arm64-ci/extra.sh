#!/bin/bash
# Further checks on the native Windows ARM64 client:
#   -stress on every core, a threaded run on core 6, a run with automatic
#   core selection and disk buffers long enough to finish blocks, and the
#   dnetc.com console stub.
#   extra.sh <dir with dnetc.exe/dnetc.com> <output dir> [all|auto]
# auto: only the automatic-core-selection run.
set -u
BIN=$(cd "$1" && pwd)
OUT=$2
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WHAT=${3:-all}
EV=$OUT/dnetc-extra.log
: > "$EV"
STATUS=0

run()
{
  local n=$1 t=$2
  shift 2
  { echo; echo "### dnetc $*"; } >> "$EV"
  timeout "$t" "$BIN/dnetc.exe" -l "$OUT/log-$n.txt" "$@" > "$OUT/console-$n.txt" 2>&1
  echo "dnetc $* -> exit code $?"
  cat "$OUT/log-$n.txt" >> "$EV" 2>/dev/null
}
c() { tr '\r' '\n' < "$1" 2>/dev/null | grep -a -c -E "$2"; }
show() { tr '\r' '\n' < "$1" 2>/dev/null | grep -a -E "$2" | sed -E 's/^\[[^]]*\] //; s/^ +//' | head -${3:-12}; }

if [ "$WHAT" = all ]
then
echo "--- -stress, all cores"
run stressall 2700 -stress rc5-72
NS=$(c "$OUT/log-stressall.txt" 'RC5-72: using core #')
PS=$(c "$OUT/log-stressall.txt" 'Stress-test [0-9] passed')
echo "-stress: $PS stress tests passed on $NS cores (expect 32 on 8)"
[ "$NS" = 8 ] && [ "$PS" = 32 ] || STATUS=1
tr '\r' '\n' < "$OUT/log-stressall.txt" | grep -a -i -E 'fail' | head -5

echo "--- core 6 (MIX NEON) on 4 threads, 1 minute"
run crunch6 300 -runoffline -nodisk -c rc5-72 6 -h 0:01
show "$OUT/log-crunch6.txt" 'using core|crunchers|keys/s\]|time limit|Shutdown complete' 8
[ "$(c "$OUT/log-crunch6.txt" 'Shutdown complete')" = 1 ] || STATUS=1

fi

echo "--- automatic core selection, disk buffers, 6 minutes"
mkdir -p "$OUT/auto"
cp "$BIN/dnetc.exe" "$OUT/auto/"
# The client refuses to run unconfigured without -nodisk; nothing is sent
# (-runoffline), the address is a placeholder.
printf '[parameters]\r\nid=win-arm64-ci@example.invalid\r\n' > "$OUT/auto/dnetc.ini"
( cd "$OUT/auto" && { echo; echo "### dnetc -runoffline -h 0:06 (no -c, no -nodisk, own directory)"; } >> "$EV"
  timeout 900 ./dnetc.exe -l log-auto.txt -runoffline -h 0:06 > "$OUT/console-auto.txt" 2>&1
  echo "dnetc -runoffline -h 0:06 -> exit code $?" )
cp "$OUT/auto/log-auto.txt" "$OUT/log-auto.txt" 2>/dev/null
cat "$OUT/log-auto.txt" >> "$EV" 2>/dev/null
show "$OUT/log-auto.txt" 'core|selected|fastest|crunchers|Completed|Summary|time limit|Shutdown complete' 30
echo "completed blocks: $(c "$OUT/log-auto.txt" 'Completed')"
echo "files left in the run directory:"; ls -la "$OUT/auto" | awk 'NR>1 {print "  " $5, $NF}'
[ "$(c "$OUT/log-auto.txt" 'using core #7')" -ge 1 ] || STATUS=1
[ "$(c "$OUT/log-auto.txt" 'Completed')" -ge 4 ] || STATUS=1
[ "$(c "$OUT/log-auto.txt" 'Shutdown complete')" = 1 ] || STATUS=1

if [ "$WHAT" = all ]
then
echo "--- dnetc.com console stub (informational)"
( cd "$BIN" && timeout 120 cmd //c "dnetc.com -cpuinfo" > "$OUT/console-com.txt" 2>&1; echo "dnetc.com -cpuinfo -> exit code $?" )
tr '\r' '\n' < "$OUT/console-com.txt" | grep -a -v '^\s*$' | head -12

fi

echo "--- extra status: $STATUS"
exit $STATUS
