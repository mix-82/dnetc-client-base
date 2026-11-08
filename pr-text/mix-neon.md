Adds MIX NEON (`rc5-72/arm64/r72-neon-mix.S`), a NEON port of the MIX ZMM AVX-512 core: 8 pipes x 4 lanes, 32 keys per call, one `.S` file for Linux and macOS. Registered as arm64 core 6. No default-core change.

Tested on GitHub runners with this branch: `-cpuinfo`, `-test rc5-72`, `-stress rc5-72 6` and `-bench rc5-72` (all cores). All cores pass 32/32 and MIX NEON passes all 4 stress tests on every runner. On Linux the build also needs #50, since `configure linux-arm64` currently stops before building.

| Runner | Best existing core | MIX NEON |
|---|---|---|
| Neoverse N2 (`ubuntu-24.04-arm`) | ANSI 4-pipe 16.44 M | 21.95 M (+34%) |
| Apple M1 VM (`macos-15`) | NEON 8x4 22.92 M | 33.47 M (+46%) |
| Apple M1 VM (`macos-26`) | NEON 8x4 18.46 M | 35.31 M (+91%) |

The macOS runners are VMs and their keyrates vary from run to run.


The complete logs, unedited, from GitHub Actions run 42532080120 (one per runner, with SHA-256 sums):
- [dnetc-ubuntu-24.04-arm.log](https://github.com/mix-82/dnetc-client-base/blob/c5c5b89375f9/evidence/dnetc-ubuntu-24.04-arm.log)
- [dnetc-macos-15.log](https://github.com/mix-82/dnetc-client-base/blob/c5c5b89375f9/evidence/dnetc-macos-15.log)
- [dnetc-macos-26.log](https://github.com/mix-82/dnetc-client-base/blob/c5c5b89375f9/evidence/dnetc-macos-26.log)
- [SHA256SUMS](https://github.com/mix-82/dnetc-client-base/blob/c5c5b89375f9/evidence/SHA256SUMS)

Each log is also posted in full as a comment below.
