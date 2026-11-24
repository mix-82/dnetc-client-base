#!/bin/bash
# Test only (not for a pull request).
#
# Compares two builds of Mesa's OpenCL library on a Raspberry Pi GPU:
#   mesa-stock/  Mesa as packaged for Raspberry Pi OS, rebuilt unchanged
#   mesa-ror/    the same source plus one patch: 32-bit rotates use the
#                GPU's "ror" instruction (see v3d-ror.diff)
#
# Usage:  ./run.sh /path/to/dnetc
#
# Nothing is installed and nothing outside this directory is changed. The
# libraries are used only by the commands started here, through the
# OCL_ICD_VENDORS environment variable. Do not run this with sudo.
#
# Result: one archive, results-<host>-<date>.tar.gz, next to this script.

DNETC_SHA256=52d5eab4e54e823fbfdae23c438ed36208f2148ef0ca641b6922790fcc349e5f
SYSTEM_MESA=26.2.7-1~bpo13+0~rpt1

KIT=$(cd "$(dirname "$0")" && pwd -P)
DNETC=${1:-}
MODE=${2:-}
DRY=0; [ "$MODE" = "--dry-run" ] && DRY=1
DEVICE=v3d; EXPECT=V3D
[ $DRY = 1 ] && { DEVICE=llvmpipe; EXPECT=llvmpipe; }

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$KIT/results-$(hostname)-$STAMP"
mkdir -p "$OUT" || exit 2
SUM="$OUT/summary.txt"
say()  { echo "$*" | tee -a "$SUM"; }
stop() { say "STOP: $*"; say "Nothing was changed on this system. Send $OUT as it is."; exit 2; }

say "# V3D ror test kit results"
say "date: $(date)"
say "host: $(hostname)"
say "kit: $(cat "$KIT/BUILD-INFO.txt" 2>/dev/null | head -1)"
[ $DRY = 1 ] && say "mode: DRY RUN on $DEVICE (no Raspberry Pi GPU)"

# ---------------------------------------------------------------- pre-flight
say ""
say "## Pre-flight"
[ "$(id -u)" = 0 ] && [ $DRY = 0 ] && stop "do not run this as root or with sudo"
[ -n "$DNETC" ] || stop "usage: ./run.sh /path/to/dnetc"
MODEL=$( { tr -d '\0' < /proc/device-tree/model; } 2>/dev/null )
say "model: ${MODEL:-unknown}"
say "kernel: $(uname -srm)"
say "os: $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
say "mesa-opencl-icd: $(dpkg-query -W -f='${Version}' mesa-opencl-icd 2>/dev/null || echo 'not installed')"
if [ $DRY = 0 ]; then
  [ "$(uname -m)" = aarch64 ] || stop "this kit needs a 64-bit ARM system (uname -m says $(uname -m))"
  case "$MODEL" in
    *"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Raspberry Pi 400"*|*"Raspberry Pi 500"*|*"Compute Module 4"*|*"Compute Module 5"*) ;;
    *) stop "this kit is for a Raspberry Pi 4 or 5" ;;
  esac
  grep -q trixie /etc/os-release || stop "this kit was built for Raspberry Pi OS based on Debian 13 (trixie)"
  [ "$(dpkg-query -W -f='${Version}' mesa-opencl-icd 2>/dev/null)" = "$SYSTEM_MESA" ] ||
    say "NOTE: the system package is not $SYSTEM_MESA; continuing, the kit brings its own libraries"
  ls /dev/dri/renderD* >/dev/null 2>&1 || stop "no /dev/dri/renderD* device"
  for n in /dev/dri/renderD*; do [ -r "$n" ] && [ -w "$n" ] && RENDER_OK=1; done
  [ "${RENDER_OK:-0}" = 1 ] || stop "no access to /dev/dri/renderD* (is the user in the 'render' group?)"
fi

( cd "$KIT" && sha256sum -c SHA256SUMS ) > "$OUT/kit-sha256-check.txt" 2>&1 ||
  stop "the kit files do not match SHA256SUMS (see kit-sha256-check.txt)"
say "kit files: match SHA256SUMS"

for v in stock ror; do
  lib="$KIT/mesa-$v/libRusticlOpenCL.so.1"
  ldd "$lib" > "$OUT/ldd-$v.txt" 2>&1
  if grep -q "not found" "$OUT/ldd-$v.txt"; then
    say "missing libraries for mesa-$v:"; grep "not found" "$OUT/ldd-$v.txt" | tee -a "$SUM"
    stop "a library the kit needs is not installed (they come with the mesa-opencl-icd package)"
  fi
  mkdir -p "$OUT/icd-$v"
  echo "$lib" > "$OUT/icd-$v/rusticl.icd"
done
say "kit libraries: all dependencies found"

[ -x "$DNETC" ] || stop "$DNETC is not an executable file"
DNETC=$(cd "$(dirname "$DNETC")" && pwd)/$(basename "$DNETC")
GOT=$(sha256sum "$DNETC" | cut -d' ' -f1)
say "dnetc: $DNETC"
say "dnetc sha256: $GOT"
if [ "$GOT" != "$DNETC_SHA256" ] && [ $DRY = 0 ] && [ "${ALLOW_OTHER_DNETC:-0}" != 1 ]; then
  stop "this is not the dnetc binary of the 22 Nov test (expected sha256 $DNETC_SHA256)"
fi

temp() {
  if command -v vcgencmd >/dev/null 2>&1; then
    echo "$(vcgencmd measure_temp 2>/dev/null) $(vcgencmd get_throttled 2>/dev/null)"
  else
    echo "temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
  fi
}

# run <label> <mesa: system|stock|ror> <timeout seconds> <command...>
run() {
  local label=$1 mesa=$2 limit=$3; shift 3
  local log="$OUT/$label.txt"
  {
    echo "## $label"
    echo "## mesa: $mesa   command: $*"
    echo "## start: $(date)   $(temp)"
  } > "$log"
  if [ "$mesa" = system ]; then
    env -u OCL_ICD_VENDORS RUSTICL_ENABLE=$DEVICE MESA_SHADER_CACHE_DISABLE=true ${EXTRA_ENV:-} \
      timeout --signal=INT --kill-after=15 "$limit" "$@" >> "$log" 2>&1
  else
    env OCL_ICD_VENDORS="$OUT/icd-$mesa" RUSTICL_ENABLE=$DEVICE MESA_SHADER_CACHE_DISABLE=true ${EXTRA_ENV:-} \
      timeout --signal=INT --kill-after=15 "$limit" "$@" >> "$log" 2>&1
  fi
  RC=$?
  echo "## end: $(date)   exit=$RC   $(temp)" >> "$log"
  return $RC
}

# ------------------------------------------------------------ rotate check
say ""
say "## Rotate check (GPU results against CPU results, 65 kernels)"
ROT_FAIL=0
for mesa in system stock ror; do
  ROTCHECK_EXPECT=$EXPECT run "rotcheck-$mesa" $mesa 900 "$KIT/rotcheck"
  rc=$RC
  line=$(grep "^ROTCHECK" "$OUT/rotcheck-$mesa.txt" | tail -1)
  lib=$(grep "^library:" "$OUT/rotcheck-$mesa.txt" | head -1)
  say "$mesa: exit $rc; ${line:-no result line}; ${lib:-library unknown}"
  if [ $rc != 0 ] && ! { [ $DRY = 1 ] && [ $mesa = system ]; }; then ROT_FAIL=1; fi
done
if grep -q "^library: $KIT/mesa-stock/" "$OUT/rotcheck-stock.txt" &&
   grep -q "^library: $KIT/mesa-ror/" "$OUT/rotcheck-ror.txt"; then
  say "library selection: OK (each run loaded the kit library it was meant to)"
else
  say "library selection: NOT CONFIRMED"
  stop "the kit libraries were not the ones loaded; results would be meaningless"
fi

ROTCHECK_CONTROL=1 ROTCHECK_ONLY=var ROTCHECK_EXPECT=$EXPECT run "rotcheck-control" stock 300 "$KIT/rotcheck"
if [ $RC = 1 ]; then say "control: OK (a wrong reference is detected)"
else say "control: UNEXPECTED exit $RC (the checker did not report a deliberately wrong reference)"; fi

if [ $DRY = 0 ]; then
  for mesa in stock ror; do
    EXTRA_ENV="V3D_DEBUG=cs" ROTCHECK_ONLY=var ROTCHECK_EXPECT=$EXPECT run "qpu-dump-$mesa" $mesa 300 "$KIT/rotcheck"
    say "compiled code, $mesa: $(grep -c ' ror ' "$OUT/qpu-dump-$mesa.txt") lines with a ror instruction"
  done
  unset EXTRA_ENV
fi

if [ $ROT_FAIL = 1 ]; then
  say ""
  say "RESULT: the rotate check FAILED on at least one library. dnetc is not run."
else
# -------------------------------------------------------------------- dnetc
  say ""
  say "## dnetc -test rc5-72 (all four OpenCL cores)"
  cd "$(dirname "$DNETC")" || stop "cannot enter the dnetc directory"
  for mesa in stock ror; do
    run "dnetc-test-$mesa" $mesa 900 "$DNETC" -test rc5-72
    cores=$(grep -c "using core" "$OUT/dnetc-test-$mesa.txt")
    passed=$(grep -c "32/32 Tests Passed" "$OUT/dnetc-test-$mesa.txt")
    failed=$(grep -c -i "FAILED" "$OUT/dnetc-test-$mesa.txt")
    say "$mesa: $passed of $cores cores passed 32/32; lines with FAILED: $failed"
  done

  say ""
  say "## dnetc -bench rc5-72 1 (CL 1-pipe), stock and patched alternating"
  for round in 1 2 3; do
    for mesa in stock ror; do
      run "dnetc-bench1-$mesa-$round" $mesa 300 "$DNETC" -bench rc5-72 1
      rate=$(grep -o "\[[0-9,]* keys/sec\]" "$OUT/dnetc-bench1-$mesa-$round.txt" | tail -1)
      say "round $round $mesa: ${rate:-no rate}   $(temp)"
    done
  done

  say ""
  say "## dnetc -bench rc5-72 (all cores)"
  for mesa in stock ror; do
    run "dnetc-bench-all-$mesa" $mesa 600 "$DNETC" -bench rc5-72
    say "$mesa:"
    grep -E "Benchmark for core|keys/sec\]" "$OUT/dnetc-bench-all-$mesa.txt" | sed 's/^\[[^]]*\] //; s/^ *//' |
      paste -d' ' - - | sed 's/^/  /' | tee -a "$SUM"
  done
  say ""
  say "RESULT: all steps ran. See the lines above for pass/fail and rates."
fi

cd "$KIT" || exit 2
tar czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")"
echo
echo "Results archive: $KIT/$(basename "$OUT").tar.gz"
echo "sha256: $(sha256sum "$(basename "$OUT").tar.gz" | cut -d' ' -f1)"
exit $ROT_FAIL
