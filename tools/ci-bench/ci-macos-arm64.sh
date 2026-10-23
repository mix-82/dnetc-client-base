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
#   5. the same kernel as Metal (tools/ci-bench/rc5-4pipe.metal): the
#      optimised AIR from the metal compiler, the pipeline statistics and
#      a binary archive from the runtime (mtlpipe.swift), and the machine
#      code disassembled with the applegpu project's tools
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
  run_step cpu-cpuinfo ./dnetc -l "$OUT/dnetc-cpu.log" -cpuinfo
  for step in test stress bench; do
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

# ---- 4. Metal: optimised AIR, pipeline statistics, machine code --------
# The MSL translation of the kernel goes through the same backend as the
# OpenCL layer. The metal compiler runs the full optimiser offline (no GPU
# needed); the pipeline statistics and the binary archive need a device.
note ""
note "## Metal (tools/ci-bench/rc5-4pipe.metal)"
METAL=tools/ci-bench/rc5-4pipe.metal
run_step metal-air xcrun -sdk macosx metal -O3 -S -emit-llvm -o "$OUT/4pipe-metal.ll" "$METAL"
run_step metal-air-r1opt xcrun -sdk macosx metal -O3 -DROUND1_OPT=1 -S -emit-llvm -o "$OUT/4pipe-metal-r1opt.ll" "$METAL"
run_step build-mtlpipe swiftc -O -o "$OUT/mtlpipe" tools/ci-bench/mtlpipe.swift
if [ -x "$OUT/mtlpipe" ]; then
  run_step mtlpipe "$OUT/mtlpipe" "$METAL" ocl_rc572_4pipe "$OUT/4pipe.archive"
  sed 's/^/    /' "$OUT/mtlpipe.txt" >> "$SUMMARY"
  run_step mtlpipe-r1opt "$OUT/mtlpipe" "$METAL" ocl_rc572_4pipe "$OUT/4pipe-r1opt.archive" -DROUND1_OPT=1
  sed 's/^/    /' "$OUT/mtlpipe-r1opt.txt" >> "$SUMMARY"
fi

# machine code: the applegpu project's reverse-engineered disassembler
APPLEGPU=$ROOT/tools/ci-bench/applegpu
if run_step applegpu-clone git clone -q --depth 1 https://github.com/dougallj/applegpu "$APPLEGPU"; then
  ( cd "$APPLEGPU" && python3 compiler_explorer.py "$ROOT/$METAL" ) > "$OUT/4pipe-agx.txt" 2>&1
  note "- applegpu compiler_explorer: exit $?"
  if [ -s "$OUT/4pipe.archive" ] && [ -x "$APPLEGPU/compiler_explorer_tools/metal-archive-extractor" ]; then
    "$APPLEGPU/compiler_explorer_tools/metal-archive-extractor" --extract-compute "$OUT/4pipe-agx.bin" "$OUT/4pipe.archive" > "$OUT/extract.txt" 2>&1
    note "- archive extract: exit $?"
    if [ -s "$OUT/4pipe-agx.bin" ]; then
      ( cd "$APPLEGPU" && python3 disassemble.py "$OUT/4pipe-agx.bin" ) > "$OUT/4pipe-agx-archive.txt" 2>&1
      note "- disassemble archive: exit $?"
    fi
  fi
fi
for f in "$OUT"/4pipe-agx.txt "$OUT"/4pipe-agx-archive.txt; do
  [ -s "$f" ] || continue
  note "- $(basename "$f"): $(wc -l < "$f") lines"
done

# counts: rotate intrinsics vs shift/or triples
for f in "$OUT"/4pipe.ll "$OUT"/4pipe-openclc-*.ll "$OUT"/4pipe-metal*.ll "$OUT"/4pipe.txt; do
  [ -f "$f" ] || continue
  note ""
  note "### $(basename "$f")"
  for pat in 'fshl' 'rotate' 'rotl' ' shl ' ' lshr ' ' or ' 'alloca' ' load ' ' store ' '<4 x i32>'; do
    note "- \`$pat\`: $(grep -c -- "$pat" "$f")"
  done
done

note ""
note "Done."
exit 0
