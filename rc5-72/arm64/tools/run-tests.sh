#!/bin/sh
# Test the MIX NEON and MIX NEON HYBRID cores against the key-by-key
# reference harness (harness.c).
#
# MIX NEON HYBRID is generated: this first checks that the committed
# r72-neon-hyb.S matches gen_hybrid.py's output, then tests it plain and
# with masked compares (--testmask: many partial and multiple matches per
# batch). MIX NEON is hand-written and is tested plain.
#
# Runs natively on arm64 Linux/macOS; on other hosts it cross-builds with
# aarch64-linux-gnu-gcc and runs under qemu-aarch64.
#
# Usage: sh rc5-72/arm64/tools/run-tests.sh [rounds]   (default 1000)

set -eu
TOOLS=$(cd "$(dirname "$0")" && pwd)
CORES=$(cd "$TOOLS/.." && pwd)
ROUNDS=${1:-1000}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

case "$(uname -m)" in
  arm64|aarch64)
    CC=${CC:-cc}
    RUN=""
    STATIC=""
    [ "$(uname -s)" = Linux ] && STATIC=-static
    ;;
  *)
    CC=${CC:-aarch64-linux-gnu-gcc}
    RUN=qemu-aarch64
    STATIC=-static
    ;;
esac
if [ "$(uname -s)" = Darwin ]; then
  # The --testmask build reaches its mask with adrp/:lo12:, which is ELF
  # syntax.
  echo "note: masked (--testmask) runs need an ELF target; skipped on macOS"
  MASKED=0
else
  MASKED=1
fi

fail=0

# build_and_run <label> <core.S> <function> <keys per batch> [extra cc flags]
build_and_run() {
  "$CC" -c "$2" -o "$WORK/core.o"
  "$CC" -O2 $STATIC ${5:-} -DCORE="$3" -DBATCH="$4" \
      "$TOOLS/harness.c" "$WORK/core.o" -o "$WORK/harness"
  printf "%-24s " "$1:"
  $RUN "$WORK/harness" "$ROUNDS" || fail=1
}

build_and_run "MIX NEON plain" "$CORES/r72-neon-mix.S" rc5_72_unit_func_neon_mix 32

if ! python3 -I "$TOOLS/gen_hybrid.py" | cmp -s - "$CORES/r72-neon-hyb.S"; then
  echo "FAIL: r72-neon-hyb.S differs from gen_hybrid.py output (regenerate it)"
  fail=1
fi
build_and_run "MIX NEON HYBRID plain" "$CORES/r72-neon-hyb.S" rc5_72_unit_func_neon_hyb 16
if [ $MASKED = 1 ]; then
  python3 -I "$TOOLS/gen_hybrid.py" --testmask > "$WORK/hyb-masked.S"
  build_and_run "MIX NEON HYBRID masked" "$WORK/hyb-masked.S" rc5_72_unit_func_neon_hyb 16 -DTESTMASK
fi
exit $fail
