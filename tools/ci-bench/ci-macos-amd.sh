#!/bin/bash
# Intel Mac check for the OpenCL client: Macs with AMD (Radeon) graphics
# first of all, but any GPU the macOS OpenCL driver exposes (Intel, or the
# NVIDIA Kepler parts that run up to Catalina) is captured the same way; the
# AMD and Intel/NVIDIA code objects are told apart afterwards. Run from the
# source root. Every step is attempted even if an earlier one fails, so one
# run answers all of:
#   1. does the amd64 OpenCL client build (configure macosx-amd64-opencl)
#   2. what device the machine exposes (-gpuinfo), and -test/-bench on it,
#      with the standard kernels and with the kernels built as ROTL_EXTR
#      (DNETC_ROTL_EXTR=1 switch in ocl_common.cpp on this branch)
#   3. what Apple's OpenCL driver hands back as the compiled program
#      (dumpcl, CL_PROGRAM_BINARIES; on Intel Macs a property list naming
#      the compiler service's code object, which dumpcl saves from its own
#      memory) and what a Metal binary archive holds (mtlpipe): any GPU code
#      object inside is pulled out (find_elf.py) and, for AMD, disassembled
#      with llvm-objdump from Homebrew LLVM (installed only when the device
#      is AMD, or WANT_LLVM=1); a Mach-O object (CPU device) goes through
#      otool; Intel and NVIDIA objects are kept as bytes for offline tools
#   4. a baseline from upstream LLVM: the 1-, 2- and 4-pipe kernels compiled
#      offline for gfx803/gfx900/gfx1010 (Polaris, Vega, Navi 10, the GPUs
#      Apple shipped) with rotate as shifts, and with the ROTL_EXTR form, so
#      the counts of v_alignbit_b32 and 64-bit shifts and the VGPR use can be
#      set beside whatever the macOS driver produces
# Results go to tools/ci-bench/ci-out/. No work is fetched or returned.
# Used by .github/workflows/ci-platforms.yml (macos-amd job) and by hand on
# an Intel Mac. Needs the Command Line Tools (clang, swiftc, otool).

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/tools/ci-bench/ci-out
NCPU=$(sysctl -n hw.ncpu)
SUMMARY=$OUT/summary-amd.md
RUN_MINUTES=${RUN_MINUTES:-2}
GFX_LIST=${GFX_LIST:-"gfx803 gfx900 gfx1010"}
WANT_LLVM=${WANT_LLVM:-0}

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

# isa_counts <assembly or disassembly> <pipes>: instruction counts for the
# kernel (tools/ci-bench/isa_counts.py)
isa_counts()
{
  python3 -I tools/ci-bench/isa_counts.py "$1" "$2" "ocl_rc572_${2}pipe" >> "$SUMMARY"
}

: > "$SUMMARY"
note "# macos-amd results"
note ""
{
  sw_vers
  echo
  uname -a
  echo
  sysctl -n machdep.cpu.brand_string
  sysctl -n hw.model
  system_profiler SPHardwareDataType 2>/dev/null | grep -E "Model Name|Model Identifier|Processor|Chip|Memory"
  echo "hw.ncpu=$NCPU"
  echo
  system_profiler SPDisplaysDataType
  echo
  xcodebuild -version 2>/dev/null
  clang --version
  echo
  ls -l /System/Library/Frameworks/OpenCL.framework/Libraries/ 2>&1
  echo
  ls -la /private/var/db/CVMS/ 2>&1 | head -20
} > "$OUT/system-amd.txt" 2>&1
grep -E 'ProductVersion|Chipset Model|Vendor|VRAM|Metal' "$OUT/system-amd.txt" | sed 's/^ */    /' >> "$SUMMARY"
note ""

# ---- 1. OpenCL client ------------------------------------------------
note "## OpenCL client (configure macosx-amd64-opencl)"
make clean > /dev/null 2>&1
rm -f dnetc output/*.o
run_step build-opencl bash -c "SHELL=/bin/sh ./configure macosx-amd64-opencl && make -j$NCPU"
HAVE_CLIENT=0
if [ -x dnetc ]; then
  HAVE_CLIENT=1
  cp dnetc "$OUT/dnetc-opencl"
else
  note "- no OpenCL client built"
fi
note ""

# ---- 2. tests and benchmark on whatever device the machine exposes ---
HAVE_DEVICE=0
if [ $HAVE_CLIENT = 1 ]; then
  LOG=$OUT/dnetc-amd.log
  rm -f "$LOG"
  run_step gpu-gpuinfo ./dnetc -l "$LOG" -gpuinfo
  if grep -q 'No OpenCL compatible devices' "$LOG"; then
    note "- no OpenCL device visible to the client; skipping -test/-bench"
  else
    HAVE_DEVICE=1
    grep -iE 'Device|Vendor|Compute units|Clock|Version' "$LOG" | sed 's/^ */    /' >> "$SUMMARY"
    run_step gpu-test ./dnetc -l "$LOG" -test rc5-72
    run_step gpu-bench ./dnetc -l "$LOG" -bench rc5-72
    note ""
    note "### Client log, standard kernels"
    grep -E 'Tests Passed|keys/sec|Default core|Fastest core|using core' "$LOG" | sed 's/^/    /' >> "$SUMMARY"

    LOGX=$OUT/dnetc-amd-extr.log
    rm -f "$LOGX"
    export DNETC_ROTL_EXTR=1
    run_step gpux-test ./dnetc -l "$LOGX" -test rc5-72
    run_step gpux-bench ./dnetc -l "$LOGX" -bench rc5-72
    unset DNETC_ROTL_EXTR
    note ""
    note "### Client log, ROTL_EXTR kernels"
    grep -E 'Tests Passed|keys/sec|Default core|Fastest core|using core' "$LOGX" | sed 's/^/    /' >> "$SUMMARY"

    # a timed run of the 2-pipe, standard kernels, for the first-packet rate
    run_step gpu-run-2pipe ./dnetc -l "$OUT/dnetc-run.log" -runoffline -nodisk -c rc5-72 2 -h 0:0$RUN_MINUTES
    note "- first packet: $(grep -m1 -A1 'Summary: 1 packet' "$OUT/dnetc-run.log" | tail -1 | tr -s ' ')"
  fi
fi
note ""

# ---- Homebrew LLVM: AMDGPU disassembler and offline compiler ----------
# 2 GB from Homebrew, so only when the device is AMD (or asked for): the
# vendor comes from the client's -gpuinfo output
note "## LLVM with the AMDGPU target"
LLVM_BIN=
if [ $HAVE_DEVICE = 1 ] && grep -qiE 'AMD|Radeon|FirePro|Vega' "$OUT/gpu-gpuinfo.txt" "$LOG"; then
  WANT_LLVM=1
fi
if [ "$WANT_LLVM" = 1 ]; then
  if [ -x "$(brew --prefix llvm 2>/dev/null)/bin/llvm-objdump" ]; then
    LLVM_BIN=$(brew --prefix llvm)/bin
  elif command -v brew > /dev/null 2>&1; then
    run_step brew-llvm brew install llvm
    if [ -x "$(brew --prefix llvm 2>/dev/null)/bin/llvm-objdump" ]; then
      LLVM_BIN=$(brew --prefix llvm)/bin
    fi
  else
    note "- Homebrew not installed; AMD code can still be disassembled from the saved objects later"
  fi
fi
if [ -n "$LLVM_BIN" ]; then
  note "- $("$LLVM_BIN/clang" --version | head -1), targets: $("$LLVM_BIN/llc" --version | grep -c amdgcn) amdgcn"
else
  note "- not used (device is not AMD, or Homebrew LLVM unavailable); saved code objects are analysed offline"
fi
note ""

# ---- 3. what the driver compiles -------------------------------------
# dumpcl: the program binary the OpenCL driver returns for the GPU device.
# On Apple Silicon this is bitcode (the driver compiles at kernel creation);
# what the AMD and Intel plug-ins return is what this step finds out.
note "## Compiled kernels from the driver"
# the gfx target for the disassembler, from the Radeon's marketing name
# (override with GFX=gfxNNNN in the environment)
if [ -z "${GFX:-}" ]; then
  RNAME=$(grep -m1 -oE 'Radeon[^;,]*|FirePro[^;,]*|Vega[^;,]*' "$OUT/system-amd.txt")
  case "$RNAME" in
    *6[6-9]00*|*W6[89]00*)           GFX=gfx1030 ;;
    *5700*|*5600*|*W5700*)           GFX=gfx1010 ;;
    *5500*|*5300*|*W5500*)           GFX=gfx1012 ;;
    *Vega*|*VII*)                    GFX=gfx900 ;;
    *5[5-8]0*|*4[6-8]0*|*WX*|*Pro\ 5[5-9]*) GFX=gfx803 ;;
    *)                               GFX=gfx803 ;;
  esac
fi
note "- disassembler target for the Radeon: $GFX ($RNAME)"
run_step build-dumpcl clang -Wno-deprecated-declarations -framework OpenCL -o "$OUT/dumpcl" tools/ci-bench/dumpcl.c
run_step build-mtlpipe swiftc -O -o "$OUT/mtlpipe" tools/ci-bench/mtlpipe.swift
for p in 1 2 4; do
  KERNEL=rc5-72/opencl/rc5-${p}pipe.cl
  note ""
  note "### ${p}-pipe"
  BLOBS=
  if [ -x "$OUT/dumpcl" ]; then
    # an AMD GPU first (a Mac may list its Intel iGPU before the Radeon)
    if run_step "dumpcl-${p}pipe-amd" "$OUT/dumpcl" "$KERNEL" "$OUT/${p}pipe-amd.bin" AMD; then
      BLOBS="$OUT/${p}pipe-amd.bin"
    elif run_step "dumpcl-${p}pipe-gpu" "$OUT/dumpcl" "$KERNEL" "$OUT/${p}pipe-gpu.bin" gpu; then
      BLOBS="$OUT/${p}pipe-gpu.bin"
    elif run_step "dumpcl-${p}pipe-all" "$OUT/dumpcl" "$KERNEL" "$OUT/${p}pipe-all.bin" all; then
      BLOBS="$OUT/${p}pipe-all.bin"
    fi
  fi
  if [ -x "$OUT/mtlpipe" ]; then
    # the base Metal translation of the same kernel; the archive holds the
    # pipeline's compiled code for this device
    METAL=tools/ci-bench/variants/rc5-${p}pipe-base.metal
    if run_step "mtlpipe-${p}pipe" "$OUT/mtlpipe" "$METAL" ocl_rc572_${p}pipe "$OUT/${p}pipe.archive"; then
      grep -E 'device:|maxTotalThreads|threadExecutionWidth' "$OUT/mtlpipe-${p}pipe.txt" | sed 's/^ */    /' >> "$SUMMARY"
      BLOBS="$BLOBS $OUT/${p}pipe.archive"
    fi
  fi
  for blob in $BLOBS; do
    [ -s "$blob" ] || continue
    # dumpcl copies the driver's code object next to the blob while it exists
    if [ -s "$blob.cvms" ]; then
      note "- code object from the driver: $(file -b "$blob.cvms" | cut -c1-100) ($(stat -f %z "$blob.cvms") bytes)"
      blob=$blob.cvms
    fi
    base=$(basename "$blob" | sed 's/\.[a-z]*$//')
    note "- $(file -b "$blob" | cut -c1-80) ($(basename "$blob"), $(stat -f %z "$blob") bytes)"
    python3 -I tools/ci-bench/find_elf.py "$blob" "$OUT/$base" > "$OUT/find_elf-$base.txt" 2>&1
    # the driver's code object may sit in a cache the user cannot read
    cvms=$(grep -oE 'cannot read /[^:]+' "$OUT/find_elf-$base.txt" | cut -c13-)
    if [ -n "$cvms" ] && sudo -n cp "$cvms" "$OUT/$base-cvms.bin" 2>> "$OUT/find_elf-$base.txt"; then
      sudo -n chown "$(id -u)" "$OUT/$base-cvms.bin"
      python3 -I tools/ci-bench/find_elf.py "$OUT/$base-cvms.bin" "$OUT/$base" >> "$OUT/find_elf-$base.txt" 2>&1
    fi
    sed 's/^/    /' "$OUT/find_elf-$base.txt" >> "$SUMMARY"
    # a Metal binary archive is a fat file of per-GPU Mach-O slices
    if python3 -I tools/ci-bench/metal_slices.py "$blob" "$OUT/$base" "$GFX" "${LLVM_BIN:+$LLVM_BIN/llvm-mc}" > "$OUT/slices-$base.txt" 2>&1; then
      sed 's/^/    /' "$OUT/slices-$base.txt" >> "$SUMMARY"
      if [ -s "$OUT/$base-amdgpu-$GFX.s" ]; then
        isa_counts "$OUT/$base-amdgpu-$GFX.s" $p
      fi
    fi
    if [ -s "$OUT/$base-cvms.bin" ]; then
      note "- code object: $(file -b "$OUT/$base-cvms.bin" | cut -c1-100)"
    fi
    # bitcode: readable IR, same front end as on Apple Silicon
    if xcrun llvm-dis "$blob" -o "$OUT/$base.ll" 2> /dev/null; then
      note "- llvm-dis: ok, $base.ll ($(grep -c 'rotate' "$OUT/$base.ll") rotate calls)"
    fi
    strings -n 8 "$blob" | grep -iE 'gfx|amdgcn|amdgpu|radeon|intel|gen[0-9]|air64|apple|nvidia|nvptx|\.version|\.target|cubin|sm_[0-9]' | sort -u | head -30 > "$OUT/strings-$base.txt"
    if [ -s "$OUT/strings-$base.txt" ]; then
      note "- strings of note: $(head -5 "$OUT/strings-$base.txt" | tr '\n' ';' | cut -c1-160)"
    fi
    # a Mach-O object is host code (the CPU device): disassemble it too, so the
    # route from driver to instruction counts is proven on any Intel Mac
    if file -b "$blob" | grep -q 'Mach-O'; then
      if xcrun otool -tV "$blob" > "$OUT/$base-x86.s" 2>&1; then
        note "- $base-x86.s: $(grep -cE '^[0-9a-f]+\s' "$OUT/$base-x86.s") instructions, rotates: $(grep -oE '\s(v?p?ro[lr][a-z]*|sh[lr]d[a-z]*)\s' "$OUT/$base-x86.s" | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
      fi
    fi
    for elf in "$OUT/$base"-*.elf; do
      [ -s "$elf" ] || continue
      if [ -n "$LLVM_BIN" ]; then
        mach=$(grep -oE 'gfx[0-9a-f]+' "$OUT/find_elf-$base.txt" | head -1)
        "$LLVM_BIN/llvm-readelf" --file-headers --notes "$elf" > "$OUT/$(basename "$elf" .elf)-readelf.txt" 2>&1
        if "$LLVM_BIN/llvm-objdump" -d ${mach:+--mcpu=$mach} "$elf" > "$OUT/$(basename "$elf" .elf).s" 2>&1; then
          note "- $(basename "$elf"): disassembled (${mach:-no gfx in header}), metadata: $(grep -oE '\.[sv]gpr_count:\s*[0-9]+' "$OUT/$(basename "$elf" .elf)-readelf.txt" | tr -s ' ' | tr '\n' ' ')"
          isa_counts "$OUT/$(basename "$elf" .elf).s" $p
        else
          note "- $(basename "$elf"): llvm-objdump failed"
        fi
      fi
    done
  done
done
note ""

# ---- 3b. inline-asm probe: front end (openclc) and AMD back end (dumpcl) ---
note ""
note "## Inline GCN assembly probe (variants/rotate-asm.cl)"
OPENCLC=/System/Library/Frameworks/OpenCL.framework/Libraries/openclc
ASMCL=tools/ci-bench/variants/rotate-asm.cl
if [ -x "$OPENCLC" ]; then
  for arch in gpu_64 x86_64; do
    if run_step "openclc-asm-$arch" "$OPENCLC" -x cl -cl-std=CL1.1 -emit-llvm -S -arch "$arch" -o "$OUT/rotate-asm-$arch.ll" "$ASMCL"; then
      note "- front end accepted the asm: $(grep -c 'call .*asm' "$OUT/rotate-asm-$arch.ll") inline-asm calls in the IR"
      break
    fi
  done
fi
if [ -x "$OUT/dumpcl" ]; then
  # the real test: Apple's AMD plug-in building the asm kernel
  if run_step dumpcl-asm-amd "$OUT/dumpcl" "$ASMCL" "$OUT/rotate-asm-amd.bin" AMD; then
    note "- AMD back end built the inline-asm kernel"
    for blob in "$OUT/rotate-asm-amd.bin.cvms" "$OUT/rotate-asm-amd.bin"; do
      [ -s "$blob" ] || continue
      note "- $(file -b "$blob" | cut -c1-100) ($(basename "$blob"))"
      python3 -I tools/ci-bench/find_elf.py "$blob" "$OUT/rotate-asm" > "$OUT/find_elf-rotate-asm.txt" 2>&1
      python3 -I tools/ci-bench/metal_slices.py "$blob" "$OUT/rotate-asm" "$GFX" "${LLVM_BIN:+$LLVM_BIN/llvm-mc}" >> "$OUT/find_elf-rotate-asm.txt" 2>&1
      sed 's/^/    /' "$OUT/find_elf-rotate-asm.txt" >> "$SUMMARY"
      break
    done
  elif grep -q 'no OpenCL GPU device' "$OUT/dumpcl-asm-amd.txt"; then
    note "- no AMD device here; the back-end half of the probe needs a Radeon Mac"
  else
    note "- AMD back end rejected it; build log:"
    grep -iE 'error|asm|assembl' "$OUT/dumpcl-asm-amd.txt" | head -8 | sed 's/^/    /' >> "$SUMMARY"
  fi
fi

# ---- 3c. offline GPU-binary build (metal-tt): works without the GPU? ------
note ""
note "## metal-tt offline GPU binaries"
if xcrun -sdk macosx -f metal-tt > "$OUT/metal-tt-path.txt" 2>&1; then
  run_step metal-tt-help xcrun -sdk macosx metal-tt -help
  run_step metal-tt-noargs xcrun -sdk macosx metal-tt
  METAL2=tools/ci-bench/variants/rc5-2pipe-base.metal
  if run_step metallib-2pipe xcrun -sdk macosx metal -O3 -o "$OUT/2pipe.metallib" "$METAL2"; then
    cat > "$OUT/2pipe.mtlp-json" <<JSON
{ "libraries": { "paths": [ { "path": "$OUT/2pipe.metallib", "label": "rc5" } ] },
  "pipelines": { "compute_pipelines": [ { "compute_function": "ocl_rc572_2pipe", "label": "2pipe" } ] } }
JSON
    if run_step metal-tt-2pipe xcrun -sdk macosx metal-tt "$OUT/2pipe.metallib" "$OUT/2pipe.mtlp-json" -o "$OUT/2pipe-gpu.metallib"; then
      note "- $(file -b "$OUT/2pipe-gpu.metallib" | cut -c1-160)"
      python3 -I tools/ci-bench/metal_slices.py "$OUT/2pipe-gpu.metallib" "$OUT/2pipe-tt" "$GFX" "${LLVM_BIN:+$LLVM_BIN/llvm-mc}" > "$OUT/slices-2pipe-tt.txt" 2>&1
      sed 's/^/    /' "$OUT/slices-2pipe-tt.txt" >> "$SUMMARY"
    else
      grep -iE 'error|target|device' "$OUT/metal-tt-2pipe.txt" | head -5 | sed 's/^/    /' >> "$SUMMARY"
    fi
  fi
else
  note "- metal-tt not found"
fi

# ---- 4. offline baseline from upstream LLVM --------------------------
# The kernels as the generic path builds them on macOS (no vendor macros,
# so ROTL falls to rotate()), compiled for the Radeon generations Apple
# shipped. Without the ROCm device library rotate() stays a call, so ROTL
# is given as shifts, which LLVM folds to a funnel shift; a compiler that
# handles rotate() well ends up in the same place. ROTL_EXTR is the Apple
# funnel-shift spelling, to see what it costs on GCN.
note "## Offline baseline (upstream LLVM, generic kernel path)"
if [ -n "$LLVM_BIN" ]; then
  for p in 1 2 4; do
    KERNEL=rc5-72/opencl/rc5-${p}pipe.cl
    if [ $p = 1 ]; then
      V=uint
    else
      V=uint$p
    fi
    ROTL="-DROTL(x,s)=((($V)(x)<<(($V)(s)&($V)(31u)))|(($V)(x)>>((($V)(0u)-($V)(s))&($V)(31u))))"
    ROTL3="-DROTL3(x)=ROTL(x,3u)"
    ROTL1="-DROTL1(x,s)=(((uint)(x)<<((uint)(s)&31u))|((uint)(x)>>((0u-(uint)(s))&31u)))"
    for gfx in $GFX_LIST; do
      for form in shifts extr; do
        name=${p}pipe-$gfx-$form
        if [ $form = shifts ]; then
          DEFS=("$ROTL" "$ROTL3" "$ROTL1")
        else
          DEFS=("-DROTL_EXTR=1")
        fi
        if run_step "llvm-$name" "$LLVM_BIN/clang" -target amdgcn-amd-amdhsa -mcpu=$gfx -nogpulib -x cl -cl-std=CL1.2 -O3 -Xclang -finclude-default-header "${DEFS[@]}" -S -o "$OUT/$name.s" "$KERNEL"; then
          note "- $name:"
          isa_counts "$OUT/$name.s" $p
        fi
      done
    done
  done
else
  note "- skipped, no LLVM"
fi

note ""
note "Done."
exit 0
