#!/bin/sh
# Run the ispcbench ISA checks, correctness tests and sweeps (1 thread, cpu0
# and its SMT sibling, all CPUs), writing ispc-report.txt. Needs AVX2; the
# AVX-512 cores are skipped on CPUs without AVX-512F.
# SECS (default 3) and ROUNDS (default 3) set each run's length and count.

B=./ispcbench
SECS=${SECS:-3}
ROUNDS=${ROUNDS:-3}
OUT=ispc-report.txt

SIB=$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list 2>/dev/null)

{
  echo "== ispcbench report, $(date -u '+%Y-%m-%d %H:%M UTC')"
  grep -m1 'model name' /proc/cpuinfo
  grep -m1 '^cpu family' /proc/cpuinfo
  grep -m1 -E '^model[[:space:]]*:' /proc/cpuinfo
  grep -m1 '^stepping' /proc/cpuinfo
  echo "logical CPUs: $(nproc), cpu0 SMT siblings: ${SIB:-unknown}"
  echo
  make -s isacheck || { echo "ISA check failed"; exit 1; }
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
