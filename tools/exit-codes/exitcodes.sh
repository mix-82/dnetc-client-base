#!/bin/sh
# exitcodes.sh: run the distributed.net client through a fixed list of cases
# and record the exit code of each one.
#
#   exitcodes.sh <client binary> <label> [output dir]
#
# Every case runs in its own empty directory with its own copy of the client,
# so no ini or buffer file is shared between cases or with a real client.
# Nothing is fetched from or sent to distributed.net: every case that would
# use the network runs with -runoffline.
#
# Environment switches:
#   SLOW=1        also run the timed cases (time limit, stop requests, exit file,
#                 buffer cases); about 5 minutes
#   PACKET=1      also run the cases that must finish a whole packet
#                 (needs a fast machine; skip under emulation)
#   STOP=signal   stop a running client with SIGTERM/SIGINT (default, Unix)
#   STOP=shutdown stop it with "<client> -shutdown" from a second instance
#                 (Windows; also acts on any other client of this user)
#   OTHERS=1      also run -shutdown/-pause/-unpause/-restart/-hup with no client
#                 running. These act on every client of this user, so only use
#                 this on a throw-away machine.
#   INFO=-gpuinfo use -gpuinfo instead of -cpuinfo (OpenCL and CUDA clients)
#   WRAP="..."    command prefix for every client start, e.g. an emulator
#   NETNS=0       do not isolate the client from the network. By default, where
#                 "unshare -rn" works (Linux), every client start runs in its own
#                 empty network namespace, so it cannot reach any server.
#   SKIPCONFIG=1  leave out the "-config with no terminal" case (use where
#                 "ulimit -f" cannot cap its endless output, e.g. Windows)
#   TRIM=1        after each case, cut an output file larger than 1 MB down to
#                 its first 200 lines (keeps CI artifacts small)
#   CAP=300       seconds after which a case that has not finished is stopped
#                 and recorded as "hung"
#
# Each client start is limited to about 20 MB of output (ulimit -f), because
# "-config" without a terminal prints its menu in an endless loop. A client
# stopped by that limit shows exit code 153 (128 + SIGXFSZ).
#
# Every case gets a minimal ini file with a made-up id, because a client with
# no id refuses most options. Cases named "no ini" remove it again.
#   EXE=.exe      suffix of the client's file name (Windows)

BIN=$1
LABEL=$2
OUT=${3:-./exitcode-results}
[ -n "$BIN" ] && [ -n "$LABEL" ] || { echo "usage: $0 <client> <label> [outdir]"; exit 2; }
[ -f "$BIN" ] || { echo "no such file: $BIN"; exit 2; }

INFO=${INFO:--cpuinfo}
STOP=${STOP:-signal}
CAP=${CAP:-300}
if [ -z "$WRAP" ] && [ "$NETNS" != 0 ] && unshare -rn true 2>/dev/null
then
  WRAP="unshare -rn"
fi
EXE=${EXE:-}
NAME=dnetc$EXE

mkdir -p "$OUT" || exit 2
OUT=$(cd "$OUT" && pwd)
BIN=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
WORK=$OUT/work-$LABEL
RES=$OUT/$LABEL.tsv
rm -rf "$WORK"
mkdir -p "$WORK" || exit 2
printf 'case\texpected\texit\tlast line of output\n' > "$RES"

n=0

# newdir: make an empty directory for the next case and go there
newdir()
{
  n=$((n + 1))
  D=$WORK/$(printf '%02d' $n)
  mkdir -p "$D"
  cp "$BIN" "$D/$NAME"
  cd "$D" || exit 2
  printf '[parameters]\nid=exitcode-test@example.invalid\n' > dnetc.ini
}

# record <case name> <expected> <exit code>: one result line; output is in out.txt
record()
{
  last=$(tr '\r' '\n' < out.txt | grep -a -v '^[[:space:]]*$' | tail -1 | cut -c1-100)
  if [ "$TRIM" = 1 ] && [ "$(wc -c < out.txt)" -gt 1000000 ]
  then
    head -200 out.txt > out-first-200-lines.txt
    rm -f out.txt
    : > out.txt
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$last" >> "$RES"
  printf '%-44s expected %-9s got %-4s %s\n' "$1" "$2" "$3" "$last"
}

# start <client options...>: start the client in the background, output to out.txt.
# Sets pid. Input comes from the file named by STDIN (default: none).
start()
{
  ( ulimit -f 40000 2>/dev/null; exec $WRAP ./$NAME "$@" > out.txt 2>&1 < "${STDIN:-/dev/null}" ) &
  pid=$!
}

# finish <seconds>: wait for $pid, at most <seconds>. Sets rc to its exit code,
# or to "hung" after stopping it.
finish()
{
  t=0
  while kill -0 $pid 2>/dev/null
  do
    if [ $t -ge $1 ]
    then
      kill $pid 2>/dev/null
      wait $pid 2>/dev/null
      rc=hung
      return
    fi
    sleep 1
    t=$((t + 1))
  done
  wait $pid
  rc=$?
}

# simple <case name> <expected> <client options...>
simple()
{
  cname=$1
  exp=$2
  shift 2
  newdir
  start "$@"
  finish ${CAPSEC:-$CAP}
  record "$cname" "$exp" $rc
}

# stop_client <pid> <signal name>: ask a running client to stop
stop_client()
{
  if [ "$STOP" = shutdown ]
  then
    $WRAP ./$NAME -shutdown > stop.txt 2>&1 < /dev/null
  else
    kill -$2 $1
  fi
}

# timed <case name> <expected> <seconds> <signal> <client options...>
# start the client, wait, ask it to stop, record its exit code
timed()
{
  cname=$1
  exp=$2
  secs=$3
  sig=$4
  shift 4
  newdir
  start "$@"
  sleep $secs
  stop_client $pid $sig
  finish $CAP
  record "$cname" "$exp" $rc
}

# noini <case name> <expected> <client options...>: like simple, without an ini file
noini()
{
  cname=$1
  exp=$2
  shift 2
  newdir
  rm -f dnetc.ini
  start "$@"
  finish ${CAPSEC:-$CAP}
  record "$cname" "$exp" $rc
}

echo "== $LABEL: $BIN"
echo "== client starts are prefixed with: ${WRAP:-(nothing)}"

# --- information and mode requests ---
simple "info ($INFO)"                    0   $INFO
simple "-help"                           0   -help
simple "-version"                        0   -version
simple "-ident"                          0   -ident
simple "unknown option"                  0   -nosuchoption
if [ "$SKIPCONFIG" != 1 ]
then
  CAPSEC=5
  simple "-config, no terminal"          0   -config
  CAPSEC=
fi
noini  "no ini: -fetch, offline"         0   -runoffline -fetch
noini  "no ini: -import, file missing"   0   -import nosuchfile.r72
simple "-fetch, offline"                 0   -runoffline -fetch
simple "-flush, offline"                 0   -runoffline -flush
simple "-update, offline"                0   -runoffline -update
simple "-import, file missing"           0   -import nosuchfile.r72
simple "-forceunlock, file missing"      0   -forceunlock nosuchfile.r72
# with no file name the option is ignored and a normal run starts, so stop it
timed  "-import, no file name"           "3 (read)" 5 TERM -runoffline -nodisk -import
timed  "-forceunlock, no file name"      "3 (read)" 5 TERM -runoffline -nodisk -forceunlock

# --- command line errors ---
LONG=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LONG=$LONG$LONG$LONG$LONG$LONG$LONG$LONG$LONG
simple "-ini, no file name"              3   -ini
simple "-ini, name too long"             3   -ini $LONG.ini $INFO
simple "-bench, unknown project"         3   -bench nosuchproject
simple "-test, unknown project"          3   -test nosuchproject
simple "-stress, unknown project"        3   -stress nosuchproject
simple "-test, core does not exist"      3   -test rc5-72 99
simple "-bench, core does not exist"     3   -bench rc5-72 99

# --- self test and benchmark ---
simple "-test rc5-72"                    0   -test rc5-72
simple "-benchmark2 rc5-72"              0   -benchmark2 rc5-72

if [ "$SLOW" = 1 ]
then
  # --- run loop ---
  simple "run: time limit (-h 0:01)"     3   -runoffline -nodisk -h 0:01
  timed  "run: stop request (TERM)"      1   8 TERM  -runoffline -nodisk
  if [ "$STOP" = signal ]
  then
    timed "run: stop request (INT)"      1   8 INT   -runoffline -nodisk
  fi

  # exit flag file created while running; the client checks for it periodically
  newdir
  start -runoffline -nodisk -exitfile exitnow.flg
  sleep 8
  : > exitnow.flg
  finish 120
  record "run: exit flag file appears" "2 (doc)" $rc

  # exit flag file already there at start
  newdir
  : > exitnow.flg
  start -runoffline -nodisk -exitfile exitnow.flg
  finish 60
  record "start: exit flag file present" 0 $rc

  # -runbuffers with nothing in the buffers
  simple "run: -runbuffers, empty buffers" "-2" -runoffline -runbuffers -inbase in -outbase out -ckpoint ck

  if [ "$PACKET" = 1 ]
  then
    # one packet, then the -n limit
    simple "run: -n 1 packet limit"      "4 (doc)" -runoffline -nodisk -numcpu 1 -n 1

    # leave one unfinished packet in the input buffer, then let -runbuffers use it up
    newdir
    start -runoffline -numcpu 1 -inbase in -outbase out -ckpoint ck
    sleep 8
    stop_client $pid TERM
    finish $CAP
    mv out.txt first.txt
    start -runoffline -runbuffers -numcpu 1 -inbase in -outbase out -ckpoint ck
    finish $CAP
    record "run: -runbuffers uses up the buffer" 4 $rc
  fi
fi

if [ "$OTHERS" = 1 ]
then
  # --- requests to other clients, none running ---
  simple "-shutdown, no client running"  0   -shutdown
  simple "-pause, no client running"     0   -pause
  simple "-unpause, no client running"   0   -unpause
  simple "-restart, no client running"   0   -restart
  simple "-hup, no client running"       0   -hup
fi

echo "results: $RES"
