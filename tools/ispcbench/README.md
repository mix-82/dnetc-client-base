# ispcbench: MIX SPMD ISPC builds against the asm cores

Tests whether ISPC builds of the MIX SPMD kernel can replace the hand-written
asm cores. Linux x86-64 with AVX2; AVX-512 cores are skipped on CPUs without
AVX-512F, and results are then compared with YK AVX2 instead of MIX ZMM.

| Core | What it is | Keys per call |
|---|---|---|
| z, z2 | MIX ZMM (#7), r72-avx512z.asm; z2 is an A/A control | 32 |
| z64 | MIX ZMM64 (#9), r72-avx512z64.asm | 64 |
| m6 | MIX SPMD (#6), the client's r72-mix-spmd-ispc.ispc, avx512skx-x32 | 32 |
| s16 / s32 / s64 | mix.ispc, avx512skx-x16 / x32 / x64 | 16 / 32 / 64 |
| s32c / s64c | mix.ispc, avx512skx-x16 with 2 / 4 explicit chains | 32 / 64 |
| yk, yk2 | YK AVX2 (#4), r72-avx2.asm; yk2 is an A/A control | 16 |
| a16 | mix.ispc, avx2-i32x16 | 16 |
| a32 / a32c | mix.ispc, avx2-i32x16 x 2 chains / avx2-i32x8 x 4 chains | 32 |

`mix.ispc` is one source for all ISPC builds: `MIX_PIPES` sets the keys per
call and `MIX_CHAINS` the number of chains written out in the source; the
ISPC target width adds chains of its own (x32 = 2 zmm per variable, x64 = 4).
`wrap.c` is the client-style wrapper (same semantics as r72-mix-spmd.cpp).

    make            # needs nasm, ispc 1.32.0, gcc with static glibc, python3
    make isacheck   # AVX-512 builds: AVX-512F only; AVX2 builds: no AVX-512;
                    # also counts stack loads/stores per 16 keys (spills)
    ./ispcbench test
    sh run.sh       # checks, tests and sweeps -> ispc-report.txt
