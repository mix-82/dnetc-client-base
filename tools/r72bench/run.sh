#!/bin/sh
# Run the r72bench correctness test and chain-count sweeps, writing bench-report.txt.
# SECS (default 5) and ROUNDS (default 5) set each run's length and repeat count.
# Keep the machine otherwise idle.

B=./r72bench
SECS=${SECS:-5}
ROUNDS=${ROUNDS:-5}
OUT=bench-report.txt

SIB=$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list 2>/dev/null)

{
  echo "== r72bench report, $(date -u '+%Y-%m-%d %H:%M UTC')"
  grep -m1 'model name' /proc/cpuinfo
  grep -m1 '^cpu family' /proc/cpuinfo
  grep -m1 -E '^model[[:space:]]*:' /proc/cpuinfo
  grep -m1 '^stepping' /proc/cpuinfo
  echo "logical CPUs: $(nproc), cpu0 SMT siblings: ${SIB:-unknown}"
  grep -m1 -o -w hypervisor /proc/cpuinfo >/dev/null && echo "running under a hypervisor"
  echo
  $B test || { echo "correctness test failed; not benchmarking"; exit 1; }
  echo
  $B sweep "$SECS" "$ROUNDS" 0
  echo
  case "$SIB" in
    *,*|*-*) $B sweep "$SECS" "$ROUNDS" "$SIB"; echo ;;
    *) echo "cpu0 has no SMT sibling; skipping the 2-sibling run"; echo ;;
  esac
  $B sweep "$SECS" "$ROUNDS" all
} 2>&1 | tee "$OUT"
echo "report written to $OUT"
