#!/bin/bash
# GPU-only retest for the OpenCL client on an Apple Silicon Mac. Run from
# the source root. About 10 minutes. Does not build or run the CPU client.
#   1. build the arm64 OpenCL client (configure macosx-arm64-opencl)
#   2. -gpuinfo, -test and -bench with the standard kernels, then -test,
#      -stress and -bench with the kernels built as ROTL_EXTR (rotate as a
#      64-bit funnel shift; DNETC_ROTL_EXTR=1 switch in ocl_common.cpp on
#      this branch), and a timed run of the 1-pipe both ways
#   3. for each kernel variant in tools/ci-bench/variants/: the optimised
#      AIR from the metal compiler, pipeline statistics from the runtime
#      (mtlpipe.swift), and
#      the machine code from the applegpu project's compiler_explorer.py,
#      with an instruction histogram and register high-water mark
#   4. the ROTL spellings through the optimiser and the predefined macros of
#      Apple's OpenCL and Metal front ends (ci-rotl-prescreen.sh)
# Results go to tools/ci-bench/ci-out/. No work is fetched or returned.
# Needs full Xcode (the metal compiler is not in the Command Line Tools).

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/ci-bench/ci-out
NCPU=$(sysctl -n hw.ncpu)
SUMMARY=$OUT/summary-gpu.md
RUN_MINUTES=${RUN_MINUTES:-2}
APPLEGPU=$ROOT/tools/ci-bench/applegpu

mkdir -p "$OUT"
cd "$ROOT" || exit 1

note()
{
  echo "$*"
  echo "$*" >> "$SUMMARY"
}

run_step()
{
  # run_step <name> <command...>: log to ci-out/<name>.txt, record the status
  local name=$1
  shift
  "$@" > "$OUT/$name.txt" 2>&1
  local rc=$?
  note "- $name: exit $rc"
  return $rc
}

: > "$SUMMARY"
note "# macos GPU results"
note ""
{
  sw_vers
  echo
  sysctl -n machdep.cpu.brand_string
  echo "hw.ncpu=$NCPU"
  echo
  system_profiler SPDisplaysDataType
  echo
  xcodebuild -version 2>/dev/null
  clang --version
} > "$OUT/system-gpu.txt" 2>&1

# ---- 1. OpenCL client ------------------------------------------------
note "## OpenCL client (configure macosx-arm64-opencl)"
make clean > /dev/null 2>&1
rm -f dnetc output/*.o
run_step build-opencl bash -c "SHELL=/bin/sh ./configure macosx-arm64-opencl && make -j$NCPU"
if [ ! -x dnetc ]; then
  note "- no OpenCL client built; stopping"
  exit 0
fi
cp dnetc "$OUT/dnetc-opencl"
LOG=$OUT/dnetc-gpu.log
rm -f "$LOG"

# ---- 2. tests, benchmark, timed runs ---------------------------------
run_step gpu-gpuinfo ./dnetc -l "$LOG" -gpuinfo
if grep -q 'No OpenCL compatible devices' "$LOG"; then
  note "- no OpenCL device visible to the client; stopping"
  exit 0
fi
run_step gpu-test ./dnetc -l "$LOG" -test rc5-72
run_step gpu-bench ./dnetc -l "$LOG" -bench rc5-72
note ""
note "### Client log, standard kernels"
grep -E 'Tests Passed|keys/sec|Default core|Fastest core|using core' "$LOG" | sed 's/^/    /' >> "$SUMMARY"

# the same client with the kernels built as ROTL_EXTR (environment switch
# in ocl_common.cpp on this branch): correctness first, then speed
LOGX=$OUT/dnetc-gpu-extr.log
rm -f "$LOGX"
export DNETC_ROTL_EXTR=1
run_step gpux-test ./dnetc -l "$LOGX" -test rc5-72
run_step gpux-stress ./dnetc -l "$LOGX" -stress rc5-72
run_step gpux-bench ./dnetc -l "$LOGX" -bench rc5-72
unset DNETC_ROTL_EXTR
note ""
note "### Client log, ROTL_EXTR kernels"
grep -E 'Tests Passed|Stress-test|keys/sec|Default core|Fastest core|using core' "$LOGX" | sed 's/^/    /' >> "$SUMMARY"

# a timed run of the fastest core, both ways, for the first-packet rate
for v in std extr; do
  if [ $v = extr ]; then export DNETC_ROTL_EXTR=1; fi
  run_step "gpu-run-1pipe-$v" ./dnetc -l "$OUT/dnetc-run-$v.log" -runoffline -nodisk -c rc5-72 1 -h 0:0$RUN_MINUTES
  unset DNETC_ROTL_EXTR
  note "- first packet ($v): $(grep -m1 -A1 'Summary: 1 packet' "$OUT/dnetc-run-$v.log" | tail -1 | tr -s ' ')"
done
note ""

# ---- 3. the three kernels through Apple's Metal toolchain ------------
note "## Metal toolchain"
run_step build-mtlpipe swiftc -O -o "$OUT/mtlpipe" tools/ci-bench/mtlpipe.swift
if [ ! -d "$APPLEGPU" ]; then
  run_step applegpu-clone git clone -q --depth 1 https://github.com/dougallj/applegpu "$APPLEGPU"
fi

for METAL in tools/ci-bench/variants/rc5-*pipe-*.metal; do
  name=$(basename "$METAL" .metal | sed 's/^rc5-//')     # e.g. 1pipe-astype
  p=${name%%pipe-*}
  FN=ocl_rc572_${p}pipe
  note ""
  note "### CL $name ($METAL)"
  run_step "metal-air-$name" xcrun -sdk macosx metal -O3 -S -emit-llvm -o "$OUT/$name-metal.ll" "$METAL"
  if [ -x "$OUT/mtlpipe" ]; then
    run_step "mtlpipe-$name" "$OUT/mtlpipe" "$METAL" "$FN" "$OUT/$name.archive"
    grep -E 'device:|maxTotalThreads|threadExecutionWidth' "$OUT/mtlpipe-$name.txt" | sed 's/^ */    /' >> "$SUMMARY"
  fi
  if [ -d "$APPLEGPU" ]; then
    ( cd "$APPLEGPU" && python3 compiler_explorer.py "$ROOT/$METAL" ) > "$OUT/$name-agx.txt" 2>&1
    note "- applegpu compiler_explorer: exit $?"
    AGX=$OUT/$name-agx.txt
    if grep -q '^compute shader:' "$AGX"; then
      total=$(awk '/^compute shader:/{m=1} m && /^ *[0-9a-f]+:/' "$AGX" | wc -l | tr -d ' ')
      hireg=$(awk '/^compute shader:/{m=1} m' "$AGX" | grep -oE '\br[0-9]+' | sed 's/r//' | sort -n | tail -1)
      memops=$(awk '/^compute shader:/{m=1} m && /^ *[0-9a-f]+:/ {print $3}' "$AGX" | grep -cE 'load|store|stack')
      note "- main shader: $total instructions, $(( total / p )) per key, highest register r$hireg, $memops memory ops"
      note "- instruction histogram:"
      awk '/^compute shader:/{m=1} m && /^ *[0-9a-f]+:/ {print $3}' "$AGX" | sort | uniq -c | sort -rn | head -12 | awk '{printf "    %6d %s\n", $1, $2}' >> "$SUMMARY"
      note "- extr spacing (instructions between extr, top 5):"
      awk '/^compute shader:/{m=1} m && /^ *[0-9a-f]+:/ {n++; if ($3=="extr") print n}' "$AGX" | awk 'NR>1{print $1-p} {p=$1}' | sort -n | uniq -c | sort -rn | head -5 | awk '{printf "    gap %3d: %d times\n", $2, $1}' >> "$SUMMARY"
    fi
  fi
done

# ---- ROTL spellings through the optimiser, and the front ends' macros ---
bash tools/ci-bench/ci-rotl-prescreen.sh "$OUT" "$SUMMARY"

note ""
note "Done."
exit 0
