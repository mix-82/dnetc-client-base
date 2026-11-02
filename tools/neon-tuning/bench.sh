#!/bin/sh
# bench.sh <label> <compiler and flags...>
# Builds the candidate cores and the harness with the given compiler and
# flags, checks correctness, and benchmarks every candidate. Run from the
# repository root. Output goes to stdout.
label=$1
shift
out=tools/neon-tuning/out
mkdir -p $out
echo "=== $label: $*"
"$@" -fno-exceptions -fno-rtti -Icommon -o $out/harness-$label \
  tools/neon-tuning/harness.cpp tools/neon-tuning/variants.cpp tools/neon-tuning/tricks.cpp rc5-72/arm64/r72-neon-8x4.cpp || exit 1
$out/harness-$label bench 2
