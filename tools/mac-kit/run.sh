#!/bin/sh
# dnetc Apple-silicon kit: MIX NEON vs MIX NEON HYBRID (old and new order) on
# a performance core and on an efficiency core, plus the vmix microbenchmark.
# About 25 minutes. Writes one results file; please send that back.
#   sh run.sh          everything
#   sh run.sh dnetc    sections 1-2 only (no vmix)
#
# macOS has no CPU pinning. Efficiency cores are reached with the background
# QoS class (taskpolicy -c background); performance cores with the default
# class, which the scheduler places on P cores when they are free. Every run
# is checked by its measured clock: on M-series chips the E cores run well
# below the P cores (M1: ~2.06 vs ~3.2 GHz), and a run whose clock does not
# match its intended core type is marked so.
MODE=$1
cd "$(dirname "$0")" || exit 1
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "This kit needs an Apple-silicon Mac (uname says $(uname -s) $(uname -m))."; exit 1
fi
chmod +x dnetc dnetc-old dnetc-new clockcal vmix 2>/dev/null
xattr -dr com.apple.quarantine . 2>/dev/null
err=$(./clockcal 1 2>&1); rc=$?
if [ $rc -ne 0 ]; then echo "clockcal failed to run: ${err:-no message} (exit $rc). Please send this message back."; exit 1; fi
MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null | tr -c 'A-Za-z0-9_-' '_')
OUT="mac-${MODEL:-unknown}-$(date +%Y%m%d-%H%M).txt"
rate() { sed -E 's/^\[[^]]*\] //' "$1" | grep -oE '\[[0-9,]+ keys/sec\]' | tail -1 | tr -d '[],' | awk '{print $1}'; }
log() { echo "$*" | tee -a "$OUT"; }
qos() { [ "$1" = E ] && echo "taskpolicy -c background"; }   # P: default class
ghz() { $(qos "$1") ./clockcal 3 > /dev/null 2>&1; $(qos "$1") ./clockcal 3 2>/dev/null | awk '{print $1}'; }

: > "$OUT"
log "# dnetc Apple-silicon kit results (kit v1)"
log "date: $(date -u)"
log "chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null); $(sysctl -n hw.ncpu) cpus, perf levels: $(sysctl -n hw.nperflevels 2>/dev/null)"
for l in 0 1; do
  n=$(sysctl -n hw.perflevel$l.physicalcpu 2>/dev/null); [ -n "$n" ] || continue
  log "  perflevel $l: $(sysctl -n hw.perflevel$l.name 2>/dev/null) x$n, L1I $(sysctl -n hw.perflevel$l.l1icachesize 2>/dev/null) B"
done
log "macOS: $(sw_vers -productVersion 2>/dev/null) $(uname -r)"
log "power: $(pmset -g batt 2>/dev/null | grep -oE "'[A-Za-z ]+'" | head -1)"
log ""; log "## clock by core type (clockcal, GHz): P $(ghz P) $(ghz P)  E $(ghz E) $(ghz E)"
log "(E should be clearly lower than P. If both are equal, QoS placement is not working on this Mac.)"

log ""; log "## 1. -test rc5-72"
for b in dnetc dnetc-old dnetc-new; do
  "./$b" -test rc5-72 < /dev/null > t.log 2>&1
  n=$(grep -c '32/32 Tests Passed' t.log)
  log "$b: $n of 9 cores pass 32/32"
  [ "$n" -eq 0 ] && { log "  dnetc said:"; head -5 t.log | sed 's/^/    /' | tee -a "$OUT"; }
done

log ""; log "## 2. keyrates, P then E, 3 rounds, order rotated (hyb-new(tree-build) is the tree's own build of the new default: a consistency check)"
log "| core type | round | build | core | keys/sec | GHz before / after | cycles/key |"
log "|---|---|---|---|---|---|---|"
JOBS="dnetc:7:MIX-NEON dnetc-old:8:hyb-old(26) dnetc-new:8:hyb-new(25,skew) dnetc:8:hyb-new(tree-build)"
for ct in P E; do
  r=0; while [ $r -lt 3 ]; do r=$((r + 1))
    order=$(echo $JOBS | awk -v s=$((r - 1)) '{for (i = 0; i < NF; i++) printf "%s ", $(((i + s) % NF) + 1)}')
    for job in $order; do
      bin=${job%%:*}; rest=${job#*:}; core=${rest%%:*}; tag=${rest#*:}
      sleep 5
      g1=$(ghz $ct)
      $(qos $ct) "./$bin" -bench rc5-72 "$core" < /dev/null > b.log 2>&1
      g2=$(ghz $ct)
      k=$(rate b.log)
      ck=$(awk -v a="$g1" -v b="$g2" -v k="$k" 'BEGIN{ if (k > 0 && a > 0 && b > 0) printf "%.0f", (a + b) / 2 * 1e9 / k; else print "-" }')
      log "| $ct | $r | $tag | #$core | $k | $g1 / $g2 | $ck |"
      [ -z "$k" ] && { log "  dnetc said:"; head -5 b.log | sed 's/^/    /' | tee -a "$OUT"; }
    done
  done
done

[ "$MODE" = dnetc ] || {
log ""; log "## 3. vmix, P then E, 1 round each"
for ct in P E; do
  sleep 5
  $(qos $ct) ./clockcal 5 < /dev/null > /dev/null 2>&1
  $(qos $ct) ./vmix 5 < /dev/null > v.log 2>&1
  ga=$($(qos $ct) ./clockcal 3 < /dev/null 2>/dev/null | awk '{print $1}')
  gv=$(grep -m1 '^clock:' v.log | awk '{print $2}')
  ok=$(awk -v a="$gv" -v b="$ga" 'BEGIN{ print (a > 0 && b > 0 && a / b > 0.95 && a / b < 1.05) ? 1 : 0 }')
  log "### $ct cores, clock right after vmix: $ga GHz"
  [ "$ok" = 1 ] || log "WARNING: vmix's clock ($gv) differs from the reading after it: this table may not be valid"
  tee -a "$OUT" < v.log
done
}

log ""; log "end: $(date -u)"
rm -f b.log t.log v.log
echo; echo "Done. Please send back: $OUT"
