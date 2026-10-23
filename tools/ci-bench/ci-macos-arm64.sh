#!/bin/bash
# Apple Silicon runner check for the OpenCL client. Run from the source root
# on a macOS arm64 machine. Every step is attempted even if an earlier one
# fails, so one run answers all of:
#   1. does the arm64 CPU client build and pass -test/-stress/-bench
#   2. does the arm64 OpenCL client build (configure macosx-arm64-opencl)
#   3. does the runner expose an OpenCL device at all (-gpuinfo, -test)
#   4. what Apple's OpenCL compiler makes of rc5-4pipe.cl: the compiled
#      form from the driver (dumpcl) and from the offline compiler (openclc),
#      turned into LLVM IR where possible, plus counts of rotate intrinsics
# Results go to tools/ci-bench/ci-out/. No work is fetched or returned.
# Used by .github/workflows/ci-platforms.yml.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/ci-bench/ci-out
KERNEL=rc5-72/opencl/rc5-4pipe.cl
NCPU=$(sysctl -n hw.ncpu)
SUMMARY=$OUT/summary.md

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
note "# macos-arm64 results"
note ""

# ---- system information ----------------------------------------------
{
  sw_vers
  echo
  uname -a
  echo
  sysctl -n machdep.cpu.brand_string
  echo "hw.ncpu=$NCPU"
  echo
  system_profiler SPDisplaysDataType
  echo
  xcodebuild -version 2>/dev/null
  clang --version
  echo
  ls -l /System/Library/Frameworks/OpenCL.framework/Libraries/ 2>&1
} > "$OUT/system.txt" 2>&1

# ---- 1. CPU client ---------------------------------------------------
note "## CPU client (configure macosx-arm64)"
run_step build-cpu bash -c "SHELL=/bin/sh ./configure macosx-arm64 && make -j$NCPU"
if [ -x dnetc ]; then
  cp dnetc "$OUT/dnetc-cpu"
  for step in cpuinfo test stress bench; do
    run_step "cpu-$step" ./dnetc -l "$OUT/dnetc-cpu.log" -$step rc5-72
  done
  grep -E 'Tests Passed|Stress-test|keys/sec|Default core|using core' "$OUT/dnetc-cpu.log" >> "$SUMMARY"
else
  note "- no CPU client built"
fi
note ""

# ---- 2. OpenCL client ------------------------------------------------
note "## OpenCL client (configure macosx-arm64-opencl)"
make clean > /dev/null 2>&1
rm -f dnetc output/*.o
run_step build-opencl bash -c "SHELL=/bin/sh ./configure macosx-arm64-opencl && make -j$NCPU"
if [ -x dnetc ]; then
  cp dnetc "$OUT/dnetc-opencl"
  run_step ocl-gpuinfo ./dnetc -l "$OUT/dnetc-opencl.log" -gpuinfo
  # only try the cores if a device was found; otherwise they just repeat the message
  if grep -q 'No OpenCL compatible devices' "$OUT/dnetc-opencl.log"; then
    note "- no OpenCL device visible to the client; skipping -test/-stress/-bench"
  else
    for step in test stress bench; do
      run_step "ocl-$step" ./dnetc -l "$OUT/dnetc-opencl.log" -$step rc5-72
    done
    grep -E 'Tests Passed|Stress-test|keys/sec|Default core|using core' "$OUT/dnetc-opencl.log" >> "$SUMMARY"
  fi
else
  note "- no OpenCL client built"
fi
note ""

# ---- 3. compiled form of the 4-pipe kernel ---------------------------
note "## Compiled 4-pipe kernel"
run_step build-dumpcl clang -Wno-deprecated-declarations -framework OpenCL -o "$OUT/dumpcl" tools/ci-bench/dumpcl.c
if [ -x "$OUT/dumpcl" ]; then
  # GPU first; if the VM has none, any device type gives the same front-end output
  if run_step dumpcl-gpu "$OUT/dumpcl" "$KERNEL" "$OUT/4pipe-gpu.bin" gpu; then
    BIN=$OUT/4pipe-gpu.bin
  elif run_step dumpcl-all "$OUT/dumpcl" "$KERNEL" "$OUT/4pipe-all.bin" all; then
    BIN=$OUT/4pipe-all.bin
  else
    BIN=
  fi
  if [ -n "$BIN" ]; then
    file "$BIN" | tee -a "$SUMMARY"
    # readable IR if the blob is plain bitcode, strings otherwise
    if xcrun llvm-dis "$BIN" -o "$OUT/4pipe.ll" 2> "$OUT/llvm-dis.txt"; then
      note "- llvm-dis: ok, 4pipe.ll"
    else
      note "- llvm-dis: failed (see llvm-dis.txt); using strings"
      strings -n 8 "$BIN" > "$OUT/4pipe.txt"
    fi
  fi
fi

# offline compiler, if this macOS still ships it
OPENCLC=/System/Library/Frameworks/OpenCL.framework/Libraries/openclc
if [ -x "$OPENCLC" ]; then
  run_step openclc-help "$OPENCLC" --help
  for arch in gpu_64 gpu_32 arm64; do
    if run_step "openclc-$arch" "$OPENCLC" -x cl -cl-std=CL1.1 -emit-llvm -S -arch "$arch" -o "$OUT/4pipe-openclc-$arch.ll" "$KERNEL"; then
      break
    fi
  done
else
  note "- openclc: not present"
fi

# counts: rotate intrinsics vs shift/or triples
for f in "$OUT"/4pipe.ll "$OUT"/4pipe-openclc-*.ll "$OUT"/4pipe.txt; do
  [ -f "$f" ] || continue
  note ""
  note "### $(basename "$f")"
  for pat in 'fshl' 'rotate' 'rotl' ' shl ' ' lshr ' ' or ' 'alloca' '<4 x i32>'; do
    note "- \`$pat\`: $(grep -c -- "$pat" "$f")"
  done
done

note ""
note "Done."
exit 0
