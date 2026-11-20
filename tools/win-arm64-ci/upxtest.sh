#!/bin/bash
# Experiment, informational: does a UPX-packed Windows ARM64 client work?
# UPX has a Windows ARM64 format (win64/arm64) since 5.3.0. The build does
# not run the exe compressor (see build.cmd); this packs copies of the built
# client afterwards and runs the same sequence as the unpacked client on
# each copy (run.sh full): -cpuinfo, -test, -stress on cores 6 and 7, -bench
# and a threaded offline crunch. No work units are fetched or returned.
#   upxtest.sh <dnetc.exe> <upx.exe> <output dir>
# Variants:
#   mk    the options makefile.vc passes to UPX, without -qq
#   lzma  the same with LZMA instead of the default NRV method
set -u
SRC=$1
UPX=$(cygpath -u "$2")
OUT=$3
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SUMMARY=$OUT/summary.txt
: > "$SUMMARY"
STATUS=0

echo "--- UPX"
"$UPX" --version | head -1
echo "unpacked client: $(stat -c %s "$SRC") bytes"

c()
{
  tr '\r' '\n' < "$1" 2>/dev/null | grep -a -c -E "$2"
}

pack_and_run()
{
  local name=$1
  shift
  local dir=$OUT/$name
  local rc
  local res
  mkdir -p "$dir"
  cp "$SRC" "$dir/dnetc.exe"

  echo
  echo "=== $name: upx $*"
  "$UPX" "$@" "$dir/dnetc.exe" > "$dir/upx-pack.txt" 2>&1
  rc=$?
  cat "$dir/upx-pack.txt"
  if [ $rc != 0 ]
  then
    echo "$name: upx exit code $rc, not packed"
    echo "$name: NOT PACKED (upx exit code $rc)" >> "$SUMMARY"
    STATUS=1
    return
  fi
  echo "--- $name: upx -t (UPX's own check of the packed file)"
  "$UPX" -t "$dir/dnetc.exe" 2>&1 | tee "$dir/upx-test.txt"
  echo "--- $name: upx --fileinfo"
  "$UPX" --fileinfo "$dir/dnetc.exe" 2>&1 | tee "$dir/upx-fileinfo.txt"
  echo "--- $name: run"
  bash "$HERE/run.sh" "$dir/dnetc.exe" "$dir" "upx-$name" full
  rc=$?
  # run.sh does not check the threaded crunch; a packed client that dies in
  # a cruncher thread never logs its shutdown
  if [ "$(c "$dir/log-crunch7.txt" 'Shutdown complete')" != 1 ]
  then
    echo "$name: threaded crunch did not shut down cleanly"
    rc=1
  fi
  if [ $rc = 0 ]
  then
    res=ok
  else
    res=FAILED
    STATUS=1
  fi
  echo "$name: $(stat -c %s "$dir/dnetc.exe") bytes packed, tests $res" >> "$SUMMARY"
}

pack_and_run mk -9 --compress-resources=0
pack_and_run lzma -9 --lzma --compress-resources=0

echo
echo "--- summary (UPX-packed Windows ARM64 client)"
cat "$SUMMARY"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
then
  {
    echo "UPX-packed Windows ARM64 client (informational)"
    echo
    echo '```'
    "$UPX" --version | head -1
    echo "unpacked client: $(stat -c %s "$SRC") bytes"
    cat "$SUMMARY"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "--- upx test status: $STATUS"
exit $STATUS
