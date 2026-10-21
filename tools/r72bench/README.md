# r72bench: RC5-72 AVX-512 pipe-count benchmark

Measures whether more 16-lane zmm pipes per thread speed up the MIX ZMM
core, alone and alongside an SMT sibling. Linux x86-64 with AVX-512F.

| Core | Pipes x lanes | Keys per batch | What it is |
|---|---|---|---|
| z | 2 x 16 | 32 | MIX ZMM (#7), r72-avx512z.asm from the client, unchanged |
| c1 | 1 x 16 | 16 | gen.py, same algorithm |
| c2 | 2 x 16 | 32 | gen.py; same code as z (checked by `make verify`) |
| c3 | 3 x 16 | 48 | gen.py; benchmark only (not valid in the client) |
| c4 | 4 x 16 | 64 | gen.py; the 64-key core candidate |

All gen.py cores use MIX ZMM's algorithm: the rolled 3-step key-schedule
loop, round-1 constants from ROM with the cmove switch to the stack S
table, interleaved S table, C/D reusing dead B registers, merged
kortestw check and the same rare path. Only the pipe count changes.

z is the reference. c2 vs z is an A/A control: it shows the noise.

## Running

    tar xzf r72bench.tar.gz
    sh run.sh

`run.sh` checks every core against a C reference first (full and
low-word-only matches at every key position, L0hi and L0mid carries,
long random runs), then runs each core on 1 thread (cpu0), on cpu0 and
its SMT sibling, and on all CPUs, rotating the order each round. It
writes `bench-report.txt`. Keep the machine otherwise idle. Defaults: 5 s
per run, 5 rounds. Override with `SECS=3 ROUNDS=7 sh run.sh`.

## Reading the result

"vs z" is the median of per-round ratios against z. For the 64-key
question, look at c4 in the 2-sibling and all-CPU runs. c2's "vs z"
range shows how much difference is noise.

## Building

    make          # needs python3, nasm and gcc with static glibc; uses the
                  # client source two levels up (override with DNETC=/path)
    make verify
    make test
    make dist     # r72bench.tar.gz with the static binary

## GitHub Actions

`.github/workflows/avx512-bench.yml` runs on a push to the `ci-bench` branch;
"Re-run all jobs" on the run page samples new runners. It starts 6 jobs on
GitHub-hosted runners, and each runs `ci-run.sh`: it builds the client and
runs the tester sequence (`-cpuinfo`, `-test`, `-stress`, `-bench`, logged to
`dnetc.log` with `-l`). On CPUs with AVX-512F it then runs this kit and
4-minute offline runs on cores 6-9 (`-runoffline -nodisk -c rc5-72 N -h 0:04`);
on CPUs without it, a 1-minute run checks that core #9 falls back to #4.
`ci-out/` is uploaded as an artifact named after the CPU, and each job's
summary is shown on the run page. No distributed.net work units are fetched
or returned.
