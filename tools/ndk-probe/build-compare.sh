#!/bin/bash
# Full NDK build of the client: dcti master vs. the android-detect branch.
# Both trees get the same two out-of-scope build fixes (socklen_t, -std)
# so that the only difference is common/cputypes.h.
set -u
NDK=${ANDROID_NDK_LATEST_HOME}
B=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
OUT=$PWD/cmp; mkdir -p "$OUT"
for v in orig fix; do
  ref=$([ $v = orig ] && echo upstream/master || echo origin/android-detect)
  rm -rf "t-$v"; git worktree add -q --detach "t-$v" "$ref"
  ( cd "t-$v"
    sed -i 's|^#if (defined(__GLIBC__) \&\& (__GLIBC__ >= 2)) \\$|&\n    \|\| defined(__ANDROID__) \\|' common/netbase.cpp
    SHELL=/bin/sh ./configure linux-arm64 > "$OUT/cfg-$v.log" 2>&1
    make -k -j4 CC="$B/aarch64-linux-android30-clang++ -std=gnu++14 -DANDROID" \
         AS="$B/aarch64-linux-android30-clang -c" STRIP="$B/llvm-strip" \
         LIBS="" LDFLAGS="-static" > "$OUT/build-$v.log" 2>&1
    echo "make exit: $?" >> "$OUT/build-$v.log"
    [ -x dnetc ] && cp dnetc "$OUT/dnetc-$v" )
  grep -E '(error|warning):' "$OUT/build-$v.log" | sed -E 's/:[0-9]+:[0-9]+:/:/' | sort -u > "$OUT/diag-$v.txt"
  grep -E 'error:' "$OUT/diag-$v.txt" > "$OUT/err-$v.txt"
done
{
  echo "## Full NDK r30 build: dcti master vs android-detect"
  echo "NDK: $(grep Pkg.Revision $NDK/source.properties)"
  for v in orig fix; do
    echo "- $v: $(tail -1 "$OUT/build-$v.log"), errors $(wc -l < "$OUT/err-$v.txt"), unique warnings $(grep -c 'warning:' "$OUT/diag-$v.txt"), binary: $([ -f "$OUT/dnetc-$v" ] && file -b "$OUT/dnetc-$v" | cut -c1-80 || echo none)"
  done
  echo; echo "### errors (orig)"; sed 's/^/    /' "$OUT/err-orig.txt" | head -40
  echo; echo "### errors (fix)"; sed 's/^/    /' "$OUT/err-fix.txt" | head -40
  echo; echo "### diagnostics only in fix"; comm -13 "$OUT/diag-orig.txt" "$OUT/diag-fix.txt" | sed 's/^/    /' | head -40
  echo; echo "### diagnostics only in orig"; comm -23 "$OUT/diag-orig.txt" "$OUT/diag-fix.txt" | sed 's/^/    /' | head -40
} > "$OUT/summary.md"
cat "$OUT/summary.md"
