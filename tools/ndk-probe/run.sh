#!/bin/sh
# Which OS/CPU does common/cputypes.h pick under the real Android NDK?
# Compares the original header with a patched copy (Android tested before
# linux, __ANDROID__ accepted, __aarch64__ recognised). Writes results.md.
set -u
NDK=${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}
BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
CXX="$BIN/clang++"
W=$(mktemp -d); mkdir -p "$W/orig" "$W/fix"
cp common/cputypes.h "$W/orig/"; cp common/cputypes.h "$W/fix/"
python3 - "$W/fix/cputypes.h" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
start=s.index('#elif defined(_ANDROID_)')
end=s.index('  #define CLIENT_OS        OS_ANDROID\n',start)+len('  #define CLIENT_OS        OS_ANDROID\n')
blk=s[start:end]; s=s[:start]+s[end:]
blk=blk.replace('#elif defined(_ANDROID_)','#elif defined(__ANDROID__) || defined(_ANDROID_)')
blk=blk.replace('#if defined(__arm64__)','#if defined(__arm64__) || defined(__aarch64__)')
s=s.replace('#elif defined(linux)\n',blk+'#elif defined(linux)\n',1)
open(p,'w').write(s)
PY
diff -u "$W/orig/cputypes.h" "$W/fix/cputypes.h" > fix.diff
for d in orig fix; do
  printf '#include "cputypes.h"\nRESULT: OS=CLIENT_OS CPU=CLIENT_CPU NAME=CLIENT_OS_NAME\n' > "$W/$d/probe.txt"
  printf '#include "cputypes.h"\nint os = CLIENT_OS, cpu = CLIENT_CPU;\n' > "$W/$d/probe.cpp"
done
res() { d=$1; shift; "$CXX" "$@" -E -P -x c++ "$W/$d/probe.txt" 2>&1 | grep -m1 -E 'RESULT|error' | sed 's/RESULT: //'; }
cc_ok() { d=$1; shift; "$CXX" "$@" -c "$W/$d/probe.cpp" -o "$W/p.o" > "$W/cc.log" 2>&1 && echo yes || echo "NO: $(head -1 "$W/cc.log")"; }
{
  echo "## cputypes.h under the real NDK"
  echo
  echo "NDK: \`$NDK\` — $(grep Pkg.Revision "$NDK/source.properties")"
  echo "Compiler: $("$CXX" --version | head -1)"
  echo
  echo "Values: OS_LINUX=4, OS_ANDROID=50, CPU_ARM=11, CPU_ARM64=22"
  echo
  echo "### A: predefined macros (aarch64-linux-android21)"
  for std in gnu++17 c++17; do
    echo "- \`-std=$std\`: $("$CXX" --target=aarch64-linux-android21 -std=$std -dM -E -x c++ /dev/null | grep -oE '#define (linux|__linux__|__ANDROID__|_ANDROID_|ANDROID|__aarch64__|__arm64__) ' | awk '{print $2}' | sort | tr '\n' ' ')"
  done
  echo
  echo "### B-H: what cputypes.h selects (real bionic sysroot; compile = full -c of a file including cputypes.h)"
  echo
  echo "| test | header | flags | result | compiles |"
  echo "|---|---|---|---|---|"
  T=--target=aarch64-linux-android21
  echo "| B | original | normal (gnu++17) | $(res orig $T -std=gnu++17) | $(cc_ok orig $T -std=gnu++17) |"
  echo "| C | original | + -DANDROID (configure) | $(res orig $T -std=gnu++17 -DANDROID) | $(cc_ok orig $T -std=gnu++17 -DANDROID) |"
  echo "| D | original | + -D_ANDROID_ | $(res orig $T -std=gnu++17 -D_ANDROID_) | $(cc_ok orig $T -std=gnu++17 -D_ANDROID_) |"
  echo "| E | original | strict c++17 + -D_ANDROID_ | $(res orig $T -std=c++17 -D_ANDROID_) | $(cc_ok orig $T -std=c++17 -D_ANDROID_) |"
  echo "| F | fixed | normal (gnu++17) | $(res fix $T -std=gnu++17) | $(cc_ok fix $T -std=gnu++17) |"
  echo "| G | fixed | armv7a-linux-androideabi21 | $(res fix --target=armv7a-linux-androideabi21 -std=gnu++17) | $(cc_ok fix --target=armv7a-linux-androideabi21 -std=gnu++17) |"
  echo "| H | fixed | x86_64-linux-android21 | $(res fix --target=x86_64-linux-android21 -std=gnu++17) | $(cc_ok fix --target=x86_64-linux-android21 -std=gnu++17) |"
  echo
  echo "Control (host gcc, Linux x86_64): original $(g++ -E -P -x c++ "$W/orig/probe.txt" | grep -m1 RESULT | sed 's/RESULT: //'), fixed $(g++ -E -P -x c++ "$W/fix/probe.txt" | grep -m1 RESULT | sed 's/RESULT: //')"
} > results.md
cat results.md
