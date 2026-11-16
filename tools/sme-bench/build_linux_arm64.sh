#!/bin/sh
# Cross-builds sme_rc5_bench.c as a static Linux arm64 program for testing under QEMU.
# Uses the clang on this machine plus an arm64 sysroot and lld unpacked in $X
# (Ubuntu packages libc6-dev-arm64-cross, libgcc-13-dev-arm64-cross, lld-18 and their
# dependencies, extracted with dpkg -x into $X/root).
X=${X:?set X to the folder holding the unpacked arm64 sysroot and lld (root/usr/...)}
L=$X/root/usr/aarch64-linux-gnu/lib
G=$X/root/usr/lib/gcc-cross/aarch64-linux-gnu/13
clang --target=aarch64-linux-gnu -O2 -Wall -Wextra -isystem $X/root/usr/aarch64-linux-gnu/include -c sme_rc5_bench.c -o gen/sme_rc5_bench.o || exit 1
$X/root/usr/lib/llvm-18/bin/ld.lld -static -o gen/sme_rc5_bench.linux-arm64 $L/crt1.o $L/crti.o $G/crtbeginT.o gen/sme_rc5_bench.o -L$L -L$G --start-group -lc -lgcc -lgcc_eh --end-group $G/crtend.o $L/crtn.o
