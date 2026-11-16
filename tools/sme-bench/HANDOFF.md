# RC5-72 with SME on Apple silicon: test and tune

From: Mix (mix-82 on GitHub)
For: zebe and any AI agent helping him
About: the stand-alone probe in this folder, `sme_rc5_bench.c` version 2

This file is a starting point for an agent working on a Mac with SME (M4 or later; zebe has an
M5). The question is whether RC5-72 key search in SME streaming mode (512-bit SVE, 16 keys per
instruction) can beat the client's NEON cores, and if so, in which configuration. I have no
Apple hardware with SME, so everything here was checked only under emulation and on machines
without SME. Nothing below is a claim about speed on your machine.

zebe decides what is worth doing. The task list is the order I would try things, not a request.

## How to use this file

1. Read "Ground rules" and "What is known".
2. Do Task 1 exactly as written before changing anything. It is one build and one run.
3. Tasks 2 to 5 are measurements and tuning. Each gives the change, the steps and a pass
   condition.
4. `README.md` has the build, file list and all pre-test results.

## Ground rules

- This is a probe, not client code. It does no distributed.net work: it encrypts made-up keys
  and measures speed. Keep it that way.
- Correctness comes before speed. Every kernel is checked against the plain C RC5-72
  (`rc5_72_ref`), which is itself checked against three distributed.net test keys. A kernel that
  fails or was not checked has no speed.
- Keep every program output unedited, one file per run, in a `results/` folder, with the exact
  command line. Report what the output says, including failures.
- Measure on a quiet machine on mains power. Say how many runs a number comes from and how far
  they spread.
- Do not push, post or send anything anywhere. zebe decides what gets shared.
- The comparison that matters is against the client: `./dnetc -bench rc5-72` on the same machine.
  The NEON kernels in this program are plain C and slower than the client's tuned cores
  (on an M1 P-core: 32 to 40 M keys/s here, 50.5 M for the client's MIX NEON core).

## What is known

Verified:

- `sme_rc5_bench.c` builds without warnings with Apple clang 21 (macOS 15 and 26) and GCC 13.
- On Apple M1 (no SME) it reports the `smstart` fault and continues with NEON only.
- macOS has the `sysctl` keys `hw.optional.arm.FEAT_SME`, `hw.optional.arm.FEAT_SME2` and
  `hw.optional.arm.sme_max_svl_b` (all 0 on M1).
- The six SVE kernels give correct results on a real Neoverse N2 (plain SVE2, 128-bit) and, under
  QEMU 8.2 emulation, in streaming mode at 128, 256, 512 and 2048 bits with NEON made illegal in
  streaming mode.

Not verified, from public reports only:

- M4 and M5 have SME2 with 512-bit streaming vectors; SVE instructions fault outside streaming
  mode; the SME unit is shared by all cores of a cluster.

Unknown:

- Whether every instruction the kernels use is accepted in streaming mode on Apple chips. The
  probes test `add`, `usra`, `lslr` and `xar`; the kernels also use `index`, `ld1rw`, `ld1w`,
  `st1w`, `addvl`, `cntw`, `lsl`/`lsr` by a constant, `and`, `sub`, `eor`, `orr`, `lsrr`, `mov`.
- Whether the program recovers after a fault inside streaming mode on macOS (it does on Linux).
- All SME speeds, on one thread and on several.

## Task 1: build and run as is

```sh
cc -O2 -o sme_rc5_bench sme_rc5_bench.c -lpthread
mkdir -p results
./sme_rc5_bench 2>&1 | tee results/run-01.log
```

About 30 seconds. Pass: the reference check says `ok`, and every line under "Checks" says `ok`.

- If a probe or check says `FAULT`, the line gives the code offset and the instruction word.
  Find the instruction in `gen/kernels.S` (offset divided by 4 is the instruction's index within
  that function). That instruction is not allowed in streaming mode on this chip: report it and
  go to Task 4.
- If the program crashes instead of reporting, note the last line printed. The likely cause is
  fault recovery in streaming mode; run again with a debugger to get the faulting address.
- Also record `./dnetc -bench rc5-72` (the client's best cores, per-core rate) in
  `results/dnetc-bench.log` if a client is at hand.

## Task 2: read the one-thread result

From `results/run-01.log`, per kernel: keys/s, and the ratio to the best NEON kernel and to the
client's per-core `-bench` rate. Repeat the run three times and give the spread.

The kernel names are streams x keys per stream. `xar` kernels rotate by 3 in one instruction,
`usra` kernels in two. More streams give the CPU independent work to overlap; whether that helps
depends on how the SME unit schedules, which is one of the things to find out.

## Task 3: threads and the shared SME unit

The program already times the best NEON and best SME kernel on 1, 2, 4, all performance cores and
all cores at once. If the SME unit is shared per cluster, the SME total will stop growing after
one thread per cluster.

The configuration that could win in the client is mixed: one thread per cluster in streaming
mode, the other cores on NEON. The program cannot measure that yet. Change: let `time_threads()`
take one variant per thread, and add rows for "1 SME thread + (N-1) NEON threads" with
N = performance cores and N = all cores, printing the total and each kind's share. Pass: totals
reproducible over three runs; compare with N NEON threads.

On macOS a thread cannot be pinned to a core. The program asks for user-interactive QoS, which
prefers performance cores. For efficiency cores, try `QOS_CLASS_BACKGROUND` in a separate run and
say so in the log name.

## Task 4: tune the kernels

The kernels come from `gen_kernels.py`. To change them:

```sh
python3 gen_kernels.py clang gen     # writes gen/kernels.S and gen/kernels.inc
python3 make_single.py               # writes sme_rc5_bench.c
cc -O2 -o sme_rc5_bench sme_rc5_bench.c -lpthread && ./sme_rc5_bench
```

The generator assembles with `clang --target=aarch64-linux-gnu` and reads the ELF object, so it
needs no SME support in Apple's assembler. It has not been run on macOS yet; if Apple's clang
refuses that target, assemble natively and adapt `elf_text_and_symbols()`.

Rules for kernel code:

- Only instructions that are legal in streaming mode. No NEON.
- Use only `x0` to `x17` (not `x18`, which macOS reserves) and no stack. `call_sm` saves `d8` to
  `d15`; `smstart` and `smstop` zero every Z and P register.
- No relocations: the code is copied as words. The generator asserts this.
- Add the kernel to `SVE_KERNEL_LIST` through the generator so it is checked before it is timed.

Ideas, roughly in the order I would try them:

1. Stream count. 1, 2 and 4 exist. Four streams use 28 of 32 registers; 3 streams, or 5 with
   shared temporaries, are possible.
2. Keep part of `S[]` in registers instead of the scratch buffer for the one-stream kernel.
3. The variable rotate is five instructions (`and`, `sub`, `lslr`, `lsrr`, `orr`). SVE and SVE2
   have no rotate by a register. Check whether SME2's multi-vector instructions (operating on two
   or four Z registers at once) cover any of the adds or shifts.
4. Share the first key-schedule steps across lanes: the lanes of a batch differ only in the
   low key byte (`L2`), so step 0 and step 1 are the same for all lanes unless `L1` changes
   within the batch.
5. Compare only the first encrypted word, as the client's cores do, and skip the last half round.
6. Loop alignment and instruction order within a step.

Pass for each: the check says `ok`, and the gain is larger than the run-to-run spread.

## Task 5: if SME wins, what a client core needs

Only worth doing if Task 2 or 3 shows a real gain over `dnetc -bench`.

- A core with the client's interface (`RC5_72UnitWork`, the key increment and the `check` fields;
  see `rc5-72/ansi/r72ansi1.cpp` and the arm64 cores in `rc5-72/arm64`).
- Detection at run time with `hw.optional.arm.FEAT_SME` (and a probe as here), in the same place
  as the other Apple silicon core selection.
- The client runs the same core on every thread. If only one thread per cluster should use
  streaming mode, that needs a design decision, not just a core.

## What to send back

The `results/` folder, unedited, and a short table: machine, kernel, keys/s on one thread, ratio
to `dnetc -bench`, and the thread totals. Anything that faulted, with its line from the log.
