#!/bin/sh
# Test only: stands in for dnetc when the kit script is dry-run in CI.
case "$1" in
-test)
  for c in "0 (CL ANSI 1-pipe)" "1 (CL 1-pipe)" "2 (CL 2-pipe)" "3 (CL 4-pipe)"; do
    echo "[stub] RC5-72: using core #$c."
    echo "[stub] RC5-72: 32/32 Tests Passed (0.1 seconds)"
  done ;;
-bench)
  if [ -n "$3" ]; then
    echo "[stub] RC5-72: using core #$3 (CL 1-pipe)."
    echo "[stub] RC5-72: Benchmark for core #$3 (CL 1-pipe)"
    echo "                      0.00:00:16.62 [1,234,567 keys/sec]"
  else
    for c in "0 (CL ANSI 1-pipe)" "1 (CL 1-pipe)" "2 (CL 2-pipe)" "3 (CL 4-pipe)"; do
      echo "[stub] RC5-72: Benchmark for core #$c"
      echo "                      0.00:00:16.62 [1,234,567 keys/sec]"
    done
  fi ;;
esac
