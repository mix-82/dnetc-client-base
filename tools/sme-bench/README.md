# sme_rc5_bench

A stand-alone probe: does Arm SME (streaming SVE, 512-bit on Apple M4) check RC5-72 keys faster
than NEON? It is not part of the distributed.net client and does no distributed.net work.

## For the person running it (macOS on Apple silicon, or Linux on arm64)

```sh
cc -O2 -o sme_rc5_bench sme_rc5_bench.c -lpthread
./sme_rc5_bench
```

Only `sme_rc5_bench.c` is needed. It takes about 30 seconds and prints one block of text; please
send back all of it. Any outcome is useful, including "SME is not available" or a reported fault.
For the real comparison, also run `dnetc -bench rc5-72` on the same machine.

## What it does

1. Prints what the system reports about SME (macOS `sysctl` keys, Linux hardware capabilities).
2. Checks the plain C RC5-72 against three distributed.net test keys.
3. Probes: `smstart`/`smstop` and each kind of instruction the SME kernels need are tried once.
   An illegal instruction is caught and reported with its code offset and instruction word.
4. Checks every kernel against the plain C version (768 keys or more, across a carry).
5. Times every kernel that passed on one thread.
6. Times the best NEON and best SME kernel on 1, 2, 4, all performance cores and all cores at once
   (the SME unit is shared by a core cluster on Apple chips).

## Files

- `sme_rc5_bench.c`: the single-file program (generated; do not edit).
- `sme_rc5_bench.in.c`: its source, without the embedded machine code.
- `gen_kernels.py`: generates the SVE kernels (1, 2 or 4 streams; rotate by 3 with `xar` or with
  `lsl` + `usra`), assembles them and writes them as `.long` words, so building the program needs
  no assembler support for SME. `gen/kernels.S` is the readable assembly, `gen/kernels.inc` the words.
- `make_single.py`: pastes `gen/kernels.inc` into `sme_rc5_bench.in.c`.
- `build_linux_arm64.sh`: cross-build for the QEMU tests (needs an unpacked arm64 sysroot and lld;
  set `X` to their folder).
- `HANDOFF.md`: a brief for an AI agent testing and tuning this on a Mac with SME.
- `pretest/`: unedited output of the runs under QEMU 8.2.2 user-mode emulation.

To regenerate: `python3 gen_kernels.py clang gen && python3 make_single.py`.

## Pre-tests done (QEMU emulation, 2026-11-15)

All kernels match the plain C version in every run. Speeds under emulation mean nothing.

| Emulated CPU | Result |
|---|---|
| SME 512-bit, NEON illegal in streaming mode (like M4) | 6 SME + 6 SVE kernels pass |
| SME 128, 256 and 2048-bit | pass |
| SME 512-bit, NEON legal in streaming mode | pass |
| SME 512-bit, built with -O0 and with -O3 | pass (logs not kept) |
| No SME, SVE2 present | `smstart` fault reported; SVE kernels pass |
| No SME, no SVE (Neoverse N1) | `smstart` fault reported; NEON only |
| A64FX (SVE without SVE2) | `usra` and `xar` faults reported; SVE kernels skipped |
| A64FX with `force` | kernel faults reported with offset and instruction word |

The embedded code also assembles as a Mach-O object (`--target=arm64-apple-macos14`).

## Runs on GitHub runners (2026-11-15, version 2)

Branch `sme-bench-test` of mix-82/dnetc-client-base, workflow `.github/workflows/sme-bench.yml`,
run 43788333267. Unedited output is in `ci-logs/`.

| Runner | CPU | Build | Result |
|---|---|---|---|
| `macos-26` | Apple M1 (Virtual), Apple clang 21 | no warnings | no SME: `smstart` fault reported; NEON kernels pass |
| `macos-15` | Apple M1 (Virtual), Apple clang 17 | no warnings | same |
| `ubuntu-24.04-arm` | Neoverse N2 (SVE2, 128-bit), GCC 13.3 | no warnings | 6 SVE kernels pass natively; SVE 4x4 xar 22.3 M keys/s against NEON 4x4 21.5 M |

On all three runners `gen_kernels.py` and `make_single.py` reproduce the committed
`sme_rc5_bench.c` byte for byte (`ci-logs/regen-*.log`).

This confirms on real macOS: the file compiles with Apple's toolchain, the `sysctl` keys
`hw.optional.arm.FEAT_SME`, `FEAT_SME2` and `sme_max_svl_b` exist (all 0 on M1), and an illegal
instruction is caught and reported. Version 1 gave a GCC warning about calling the stubs through
a cast; version 2 removes it.

For scale: the client's tuned cores measured earlier were 50.5 M keys/s on an M1 P-core (MIX NEON)
and 33.0 M on a Neoverse N2 (MIX NEON HYBRID). The plain C NEON kernels here reach 32 to 40 M on
the virtual M1 and 21.5 M on the N2, so they are a weaker baseline than `dnetc -bench`.

## Not tested

Nothing here has run on a CPU with SME. Untested until then: whether the M4 accepts every
instruction used in streaming mode, recovery after a fault inside streaming mode on macOS, and
all SME speeds.
