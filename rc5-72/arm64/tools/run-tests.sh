#!/bin/sh
# Regenerate the MIX NEON16/NEON32 cores and test them against the
# key-by-key reference harness, plain and with masked compares
# (--testmask: many partial and multiple matches per batch).
#
# Checks first that the committed .S files match their generators.
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
  # Mach-O: C symbols carry a leading underscore; the test hook symbol
  # is reached with adrp/:lo12:, which only the ELF build uses.
  echo "note: masked (--testmask) runs need an ELF target; skipped on macOS"
  MASKED=0
else
  MASKED=1
fi

fail=0
for n in 16 32; do
  gen=$TOOLS/gen_neon$n.py
  core=$CORES/r72-neon-mix$n.S
  if ! python3 -I "$gen" | cmp -s - "$core"; then
    echo "FAIL: $core differs from $gen output (regenerate it)"
    fail=1
  fi
  python3 -I "$gen" > "$WORK/core$n.S"
  "$CC" -c "$WORK/core$n.S" -o "$WORK/core$n.o"
  "$CC" -O2 $STATIC -DCORE=rc5_72_unit_func_neon_mix$n -DBATCH=$n \
      "$TOOLS/harness.c" "$WORK/core$n.o" -o "$WORK/harness$n"
  printf "MIX NEON%s plain:  " "$n"
  $RUN "$WORK/harness$n" "$ROUNDS" || fail=1
  if [ $MASKED = 1 ]; then
    python3 -I "$gen" --testmask > "$WORK/core${n}m.S"
    "$CC" -c "$WORK/core${n}m.S" -o "$WORK/core${n}m.o"
    "$CC" -O2 $STATIC -DTESTMASK -DCORE=rc5_72_unit_func_neon_mix$n -DBATCH=$n \
        "$TOOLS/harness.c" "$WORK/core${n}m.o" -o "$WORK/harness${n}m"
    printf "MIX NEON%s masked: " "$n"
    $RUN "$WORK/harness${n}m" "$ROUNDS" || fail=1
  fi
done
exit $fail
