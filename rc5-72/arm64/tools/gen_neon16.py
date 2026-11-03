#!/usr/bin/env python3
"""Generate rc5-72/arm64/r72-neon-mix16.S: an AArch64 NEON port of MIX ZMM
(rc5-72/amd64/r72-avx512z.asm, 4 pipes x 16 lanes) as 4 pipes x 4 lanes = 16 keys.

Usage: gen_neon16.py [--testmask] > ../r72-neon-mix16.S
--testmask: test build only. ANDs the low and high cipher words with the
32-bit value at symbol r72_testmask before comparing (the harness passes a
masked cypher), so partial and multiple matches happen every few keys.
"""
import sys

TESTMASK = "--testmask" in sys.argv
NP = 4                       # pipes
STRIDE = 16 * NP             # bytes per subkey in the S table (64)

# ---- vector register map ------------------------------------------------
T = [f"v{i}" for i in range(0, 4)]          # scratch / rotate amount
U = [f"v{i}" for i in range(4, 8)]          # scratch
A = [f"v{i}" for i in range(8, 12)]         # A per pipe (d8-d11 callee-saved)
B = [[f"v{12 + 3 * p + j}" for j in range(3)] for p in range(NP)]  # B_p0..B_p2: v12-v23
C31, CM32, CLO, CHI = "v24", "v25", "v26", "v27"
LANES = ["v28", "v29", "v30", "v31"]
# C and D reuse B_0 and B_2 registers, dead after the key schedule (as in MIX ZMM).
# B_1 stays live for the rare path (k=77).
C = [B[0][0], B[0][2], B[1][0], B[1][2]]
D = [B[2][0], B[2][2], B[3][0], B[3][2]]
assert len(set(C + D + [B[p][1] for p in range(NP)])) == 12

out = []
def e(s=""): out.append(s)
def ins(s): out.append("        " + s)
def s4(r): return r + ".4s"
def b16(r): return r + ".16b"
def q(r): return "q" + r[1:]
def each(fmt, **lists):
    for p in range(NP):
        ins(fmt.format(**{k: v[p] for k, v in lists.items()}))

def load4(dst, base, off):
    ins(f"ldp     {q(dst[0])}, {q(dst[1])}, [{base}, #{off}]")
    ins(f"ldp     {q(dst[2])}, {q(dst[3])}, [{base}, #{off + 32}]")

def store4(src, base, off):
    ins(f"stp     {q(src[0])}, {q(src[1])}, [{base}, #{off}]")
    ins(f"stp     {q(src[2])}, {q(src[3])}, [{base}, #{off + 32}]")

def vrotl(x, s, t1, t2):
    """x <<<= s per lane. t1, t2 scratch; t2 may be s (s is consumed last)."""
    each("and     {u}, {s}, " + b16(C31), u=[b16(r) for r in t1], s=[b16(r) for r in s])
    each("orr     {t}, {s}, " + b16(CM32), t=[b16(r) for r in t2], s=[b16(r) for r in s])
    each("ushl    {u}, {x}, {u}", u=[s4(r) for r in t1], x=[s4(r) for r in x])
    each("ushl    {t}, {x}, {t}", t=[s4(r) for r in t2], x=[s4(r) for r in x])
    each("orr     {x}, {u}, {t}", x=[b16(r) for r in x], u=[b16(r) for r in t1], t=[b16(r) for r in t2])

def rotl3(dst, src):
    each("shl     {d}, {s}, #3", d=[s4(r) for r in dst], s=[s4(r) for r in src])
    each("sri     {d}, {s}, #29", d=[s4(r) for r in dst], s=[s4(r) for r in src])

def ks_step(off, bx, by, title):
    """MIX ZMM STEP A/B/C for all pipes:
    A = (A + S[src] + Bx) <<< 3; S[dst] = A; T = Bx + A; By = (By + T) <<< T."""
    Bx = [B[p][bx] for p in range(NP)]
    By = [B[p][by] for p in range(NP)]
    ins(f"// === {title} ===")
    load4(T, "x10", off)
    each("add     {t}, {t}, {a}", t=[s4(r) for r in T], a=[s4(r) for r in A])
    each("add     {t}, {t}, {b}", t=[s4(r) for r in T], b=[s4(r) for r in Bx])
    rotl3(A, T)
    store4(A, "x11", off)
    each("add     {t}, {b}, {a}", t=[s4(r) for r in T], b=[s4(r) for r in Bx], a=[s4(r) for r in A])
    each("add     {y}, {y}, {t}", y=[s4(r) for r in By], t=[s4(r) for r in T])
    vrotl(By, T, U, T)

def half_round(X, Y, off, base="x10"):
    """X = ((X ^ Y) <<< Y) + S[off], all pipes."""
    each("eor     {x}, {x}, {y}", x=[b16(r) for r in X], y=[b16(r) for r in Y])
    vrotl(X, Y, U, T)
    load4(T, base, off)
    each("add     {x}, {x}, {t}", x=[s4(r) for r in X], t=[s4(r) for r in T])

def compare(dst, vecs, ref, vtmp):
    """dst[p] = (vecs[p] == ref) per lane. In the --testmask build, compares
    copies of vecs ANDed with r72_testmask, leaving vecs unchanged."""
    if not TESTMASK:
        each("cmeq    {t}, {v}, " + s4(ref), t=[s4(r) for r in dst], v=[s4(r) for r in vecs])
        return
    ins("// R72_TESTMASK (test build only): compare masked copies")
    ins("adrp    x16, r72_testmask")
    ins("add     x16, x16, :lo12:r72_testmask")
    ins(f"ld1r    {{{s4(vtmp)}}}, [x16]")
    each("and     {t}, {v}, " + b16(vtmp), t=[b16(r) for r in dst], v=[b16(r) for r in vecs])
    each("cmeq    {t}, {t}, " + s4(ref), t=[s4(r) for r in dst])

def movemask(dst_w, vecs, wreg, vtmp, tmpw):
    """dst_w = 16-bit mask; bit 4p+lane set where vecs[p] lane is all ones."""
    for p in range(NP):
        ins(f"and     {b16(vtmp)}, {b16(vecs[p])}, {b16(wreg)}")
        ins(f"addv    s{vtmp[1:]}, {s4(vtmp)}")
        if p == 0:
            ins(f"fmov    {dst_w}, s{vtmp[1:]}")
        else:
            ins(f"fmov    {tmpw}, s{vtmp[1:]}")
            ins(f"orr     {dst_w}, {dst_w}, {tmpw}, lsl #{4 * p}")

def popcnt(dst_w, src_w, vtmp):
    ins(f"fmov    s{vtmp[1:]}, {src_w}")
    ins(f"cnt     {vtmp}.8b, {vtmp}.8b")
    ins(f"addv    b{vtmp[1:]}, {vtmp}.8b")
    ins(f"fmov    {dst_w}, s{vtmp[1:]}")

def mov32(reg, val):
    ins(f"mov     {reg}, #0x{val & 0xFFFF:04X}")
    ins(f"movk    {reg}, #0x{val >> 16:04X}, lsl #16")

# ---- RC5-72 constants ----------------------------------------------------
M = 0xFFFFFFFF
P, Q = 0xB7E15163, 0x9E3779B9
def rotl(x, s):
    s &= 31
    return ((x << s) | (x >> (32 - s))) & M if s else x
S0 = rotl(P, 3)                              # pass-1 S[0], the same for every key
K1 = (P + Q + S0) & M                        # S[1] init + A after step 0
K2 = (P + 2 * Q) & M                         # S[2] init
assert (S0, K1, K2) == (0xBF0A8B1D, 0x15235639, 0xF45044D5)
ROM = [(P + i * Q) & M for i in range(3, 26)] + [S0]   # IS3..IS25, IS0 (read at k=26)

SAVE = 64                                    # d8-d15
S_OFF = SAVE                                 # S table at sp+64
FRAME = SAVE + 26 * STRIDE                   # 1728
assert FRAME % 64 == 0 and S_OFF % 64 == 0      # rows must not straddle cache lines

def S(n): return S_OFF + n * STRIDE          # sp offset of S[n]

# ==========================================================================
e("""// RC5-72 NEON core for AArch64 (MIX NEON16), 16 keys per batch.
// 4 pipes x 4 lanes. A port of Mix's 64-key AVX-512F core (MIX ZMM,
// rc5-72/amd64/r72-avx512z.asm), itself inspired by Yasuhiro Katsui's AVX2
// core: the same scalar precompute of the first key-schedule steps, rolled
// 3-step key-schedule loop with branchless pointer wraps, deferred k=77 step,
// merged low-word check and exact reference check.count/check.hi semantics.
//
// NEON has no vector rotate. Variable rotate:
//   x <<< s = ushl(x, s & 31) | ushl(x, s | 0xFFFFFFE0)
// USHL reads the low byte of each lane as a signed shift amount, so
// s | 0xFFFFFFE0 is (s & 31) - 32: a right shift by 32 - (s & 31), or a
// shift out to 0 when s & 31 = 0. Both amounts come from s in parallel.
// Rotate by 3 is shl + sri (sri: 2 cycles everywhere; usra is 3 on Apple and
// a slow forwarding producer on Neoverse N2).
//
// All key state stays in v0-v31 (no spills); the S table is on the stack,
// 64-byte aligned.
// Needs MINIMUM_ITERATIONS to be a multiple of 16, so that L0hi is a
// multiple of 16 on entry.
//
// Generated by rc5-72/arm64/tools/gen_neon16.py; edit that, not this file.""" + ("\n// TEST BUILD: R72_TESTMASK enabled. Do not ship." if TESTMASK else ""))
e("""
#if defined(__APPLE__)
#define FUNC(name) _##name
#define L(name) L##name
#else
#define FUNC(name) name
#define L(name) .L##name
#endif

        .text
        .p2align 4
        .globl  FUNC(rc5_72_unit_func_neon_mix16)
#if !defined(__APPLE__)
        .type   rc5_72_unit_func_neon_mix16, %function
#endif
FUNC(rc5_72_unit_func_neon_mix16):
// x0 = RC5_72UnitWork *, x1 = u32 *iterations, x2 = memblk (unused)
//
// Scalar registers (MIX ZMM equivalent in brackets):
//   w9  batches left [r10d]    w13 L0hi [r13d]    w14 L0mid [r14d]   w15 L0lo [r15d]
//   x10 S source [rax]         x11 S dest [rdx]   x12 &S[1] [r12]    x8  &S[-1] [r8]
//   w3  step counter [ebx]
//   w2  pre_B_0    w5 pre_S1    w4 pre_B_0 + pre_S1 [ecx]
//   w6  pre_B_1    w7 pre_S2    w17 pre_B_2
//   w10, w11, w16 scratch. The rare path uses only these, w3 and x8, so the
//   pre_* values survive for the next batch (MIX ZMM: "must not touch ecx").
// Vector registers:
//   v0-v3 T (scratch)   v4-v7 U (scratch)   v8-v11 A1-A4
//   v12-v23 B1_0 B1_1 B1_2 ... B4_0 B4_1 B4_2
//   C1-C4 = v12 v14 v15 v17 (B1_0 B1_2 B2_0 B2_2)
//   D1-D4 = v18 v20 v21 v23 (B3_0 B3_2 B4_0 B4_2)
//   v24 = 31  v25 = 0xFFFFFFE0  v26 = cypher.lo  v27 = cypher.hi
//   v28-v31 = L0hi lane offsets 0-3, 4-7, 8-11, 12-15
""")
ins("// frame pointer, then a 64-byte-aligned frame: the S table, L area and")
ins("// constant rows are 64 or 128 bytes, and a 32-byte ldp/stp pair must not")
ins("// straddle a cache line")
ins("stp     x29, x30, [sp, #-16]!")
ins("mov     x29, sp")
ins(f"sub     x16, x29, #{FRAME}")
ins("and     sp, x16, #-64")
ins("stp     d8, d9, [sp, #0]")
ins("stp     d10, d11, [sp, #16]")
ins("stp     d12, d13, [sp, #32]")
ins("stp     d14, d15, [sp, #48]")
e()
ins("ldr     w9, [x1]")
ins("lsr     w9, w9, #4                 // divide by 16 keys per batch")
ins("ldr     w13, [x0, #16]             // L0.hi")
ins("ldr     w14, [x0, #20]             // L0.mid")
ins("ldr     w15, [x0, #24]             // L0.lo")
ins(f"add     x12, sp, #{S(1)}             // &S[1]")
e()
ins(f"movi    {s4(C31)}, #31")
ins(f"mvni    {s4(CM32)}, #31              // 0xFFFFFFE0")
ins("add     x16, x0, #12")
ins(f"ld1r    {{{s4(CLO)}}}, [x16]          // cypher.lo")
ins("add     x16, x0, #8")
ins(f"ld1r    {{{s4(CHI)}}}, [x16]          // cypher.hi")
ins("adr     x16, L(lanes)")
ins(f"ldp     {q(LANES[0])}, {q(LANES[1])}, [x16]")
ins(f"ldp     {q(LANES[2])}, {q(LANES[3])}, [x16, #32]")
e()
e("L(outer_loop):")
ins("// k=0: pre_B_0 = (L0lo + S0) <<< S0 (S0 & 31 = 29)")
mov32("w16", S0)
ins("add     w2, w15, w16")
ins("ror     w2, w2, #3                 // <<< 29")
ins("// k=1: pre_S1 = (P+Q + S0 + pre_B_0) <<< 3")
mov32("w16", K1)
ins("add     w5, w2, w16")
ins("ror     w5, w5, #29                // <<< 3")
ins("add     w4, w2, w5")
e()
e("L(mid_loop):")
ins("// k=1: pre_B_1 = (L0mid + w4) <<< w4")
ins("add     w6, w14, w4")
ins("neg     w16, w4")
ins("ror     w6, w6, w16")
ins("// k=2: pre_S2 = (P+2Q + pre_S1 + pre_B_1) <<< 3; pre_B_2 = pre_S2 + pre_B_1")
mov32("w16", K2)
ins("add     w7, w5, w6")
ins("add     w7, w7, w16")
ins("ror     w7, w7, #29")
ins("add     w17, w6, w7")
e()
ins(".p2align 4")
e("L(inner_loop):")
each(f"dup     {{a}}, w7", a=[s4(r) for r in A])
each(f"dup     {{b}}, w2", b=[s4(B[p][0]) for p in range(NP)])
each(f"dup     {{b}}, w6", b=[s4(B[p][1]) for p in range(NP)])
ins(f"dup     {s4(T[0])}, w5")
store4([T[0]] * 4, "sp", S(1))
store4(A, "sp", S(2))
e()
ins("// k=2: B_2 = (L0hi + lane + pre_B_2) <<< pre_B_2, natively per lane")
each(f"dup     {{b}}, w13", b=[s4(B[p][2]) for p in range(NP)])
each("dup     {t}, w17", t=[s4(r) for r in T])
each("add     {b}, {b}, {l}", b=[s4(B[p][2]) for p in range(NP)], l=[s4(r) for r in LANES])
each("add     {b}, {b}, {t}", b=[s4(B[p][2]) for p in range(NP)], t=[s4(r) for r in T])
vrotl([B[p][2] for p in range(NP)], T, U, T)
e()
ins("adr     x10, L(IS3)")
ins(f"add     x11, sp, #{S(3)}")
ins(f"add     x8, sp, #{S(0) - STRIDE}             // wrap target for csel")
ins("mov     w3, #0")
ins("b       L(round1)")
e()
ins(".p2align 4")
e("L(round):")
ins("cmp     w3, #7")
ins("csel    x11, x12, x11, eq          // branchless wrap to S[1]")
ks_step(-STRIDE, 1, 2, "STEP A: A += B_1, B_2 <<<")
ins("add     w3, w3, #1")
e()
e("L(round1):")
ins("cmp     w3, #8")
ins("csel    x10, x11, x10, eq          // switch from ROM constants to stack subkeys")
ks_step(0, 2, 0, "STEP B: A += B_2, B_0 <<<")
e()
ins("cmp     w3, #16")
ins("csel    x11, x8, x11, eq           // branchless wrap to S[0]")
ins("csel    x10, x8, x10, eq")
ks_step(STRIDE, 0, 1, "STEP C: A += B_0, B_1 <<<")
e()
ins(f"add     x10, x10, #{3 * STRIDE}")
ins(f"add     x11, x11, #{3 * STRIDE}")
ins("cmp     w3, #24")
ins("b.ne    L(round)")
e()
e("L(encrypt_setup):")
ins("// C = plain.lo + S[0], D = plain.hi + S[1]")
ins("ldr     w16, [x0, #4]")
ins(f"dup     {s4(U[0])}, w16")
ins("ldr     w16, [x0, #0]")
ins(f"dup     {s4(U[1])}, w16")
load4(T, "sp", S(0))
each("add     {c}, {t}, " + s4(U[0]), c=[s4(r) for r in C], t=[s4(r) for r in T])
load4(T, "sp", S(1))
each("add     {d}, {t}, " + s4(U[1]), d=[s4(r) for r in D], t=[s4(r) for r in T])
ins(f"add     x10, sp, #{S(2)}")
ins("mov     w3, #0")
e()
ins(".p2align 4")
e("L(encrypt):")
ins("add     w3, w3, #1")
ins("// C = ((C ^ D) <<< D) + S[2r]")
half_round(C, D, 0)
ins("// D = ((D ^ C) <<< C) + S[2r+1]")
half_round(D, C, STRIDE)
ins(f"add     x10, x10, #{2 * STRIDE}")
ins("cmp     w3, #11")
ins("b.ne    L(encrypt)")
e()
e("L(encrypt_end):")
ins("// final half-round: C = ((C ^ D) <<< D) + S[24]; x10 = &S[24]")
ins("// D is computed only if C matches cypher.lo")
half_round(C, D, 0)
e()
e("L(check_key):")
compare(T, C, CLO, U[0])
ins(f"orr     {b16(U[0])}, {b16(T[0])}, {b16(T[1])}")
ins(f"orr     {b16(U[1])}, {b16(T[2])}, {b16(T[3])}")
ins(f"orr     {b16(U[0])}, {b16(U[0])}, {b16(U[1])}")
ins(f"umaxv   s{U[0][1:]}, {s4(U[0])}")
ins(f"fmov    w16, s{U[0][1:]}")
ins("cbnz    w16, L(check_hi)")
e()
e("L(next_key):")
ins("subs    w9, w9, #1")
ins("b.eq    L(finished_nothing)")
ins("add     w13, w13, #16")
ins("tbnz    w13, #8, L(carry_hi)")
ins("str     w13, [x0, #16]")
ins("b       L(inner_loop)")
e("L(carry_hi):")
ins("and     w13, w13, #0xFF")
ins("str     w13, [x0, #16]")
ins("rev     w14, w14")
ins("adds    w14, w14, #1")
ins("rev     w14, w14")
ins("b.cc    L(mid_loop)")
ins("rev     w15, w15")
ins("add     w15, w15, #1")
ins("rev     w15, w15")
ins("b       L(outer_loop)")
e()
e("L(check_hi):")
ins("// Rare path (about 1 batch in 2^28). Uses only w3, x8, w10, w11, w16, x16.")
ins(f"add     x8, x10, #{STRIDE}               // &S[25] (x10 = &S[24]; x8 is rebuilt each batch)")
ins("adr     x16, L(weights)")
ins(f"ldr     {q(U[0])}, [x16]")
movemask("w10", T, U[0], U[1], "w11")
ins("// w10 = 16-bit low-word match mask, bit n = key n")
e()
ins("// k=77: S[25] = (S[25] + A + B_1) <<< 3, then D = ((D ^ C) <<< C) + S[25]")
load4(U, "x8", 0)
each("add     {a}, {a}, {u}", a=[s4(r) for r in A], u=[s4(r) for r in U])
each("add     {a}, {a}, {b}", a=[s4(r) for r in A], b=[s4(B[p][1]) for p in range(NP)])
rotl3(T, A)                                   # T = S[25] of pass 3
each("eor     {d}, {d}, {c}", d=[b16(r) for r in D], c=[b16(r) for r in C])
vrotl(D, C, U, A)                             # A is free now
each("add     {d}, {d}, {t}", d=[s4(r) for r in D], t=[s4(r) for r in T])
compare(T, D, CHI, A[0])
ins("adr     x16, L(weights)")
ins(f"ldr     {q(U[0])}, [x16]")
movemask("w11", T, U[0], U[1], "w16")
ins("ands    w16, w11, w10              // keys matching both words")
ins("b.ne    L(save_found_key)")
e()
ins("// partial match(es) only: count them, record the last one (as the reference does)")
popcnt("w11", "w10", U[0])
ins("ldr     w16, [x0, #28]")
ins("add     w16, w16, w11")
ins("str     w16, [x0, #28]")
ins("clz     w16, w10")
ins("mov     w11, #31")
ins("sub     w16, w11, w16              // index of the highest set bit")
ins("add     w16, w16, w13")
ins("str     w16, [x0, #32]")
ins("str     w14, [x0, #36]")
ins("str     w15, [x0, #40]")
ins("b       L(next_key)")
e()
e("L(save_found_key):")
ins("// f = first full match. Count only partial matches at or before f, and")
ins("// record f as the last partial match: exactly what the reference does.")
ins("rbit    w16, w16")
ins("clz     w3, w16                    // w3 = f")
ins("mov     w11, #2")
ins("lsl     w11, w11, w3")
ins("sub     w11, w11, #1               // mask of keys 0..f")
ins("and     w10, w10, w11")
popcnt("w11", "w10", U[0])
ins("ldr     w16, [x0, #28]")
ins("add     w16, w16, w11")
ins("str     w16, [x0, #28]")
ins("add     w16, w3, w13")
ins("str     w16, [x0, #32]")
ins("str     w14, [x0, #36]")
ins("str     w15, [x0, #40]")
ins("// *iterations = keys before the winning one")
ins("ldr     w16, [x1]")
ins("lsr     w16, w16, #4")
ins("sub     w16, w16, w9")
ins("lsl     w16, w16, #4")
ins("add     w16, w16, w3")
ins("str     w16, [x1]")
ins("str     w14, [x0, #20]")
ins("str     w15, [x0, #24]")
ins("mov     w0, #2                     // RESULT_FOUND")
ins("b       L(finished)")
e()
e("L(finished_nothing):")
ins("add     w13, w13, #16")
ins("ubfx    w16, w13, #8, #1           // carry out of the L0hi byte")
ins("and     w13, w13, #0xFF")
ins("rev     w14, w14")
ins("rev     w15, w15")
ins("adds    w14, w14, w16")
ins("adc     w15, w15, wzr")
ins("rev     w14, w14")
ins("rev     w15, w15")
ins("str     w13, [x0, #16]")
ins("str     w14, [x0, #20]")
ins("str     w15, [x0, #24]")
ins("mov     w0, #1                     // RESULT_NOTHING")
e()
e("L(finished):")
ins("ldp     d8, d9, [sp, #0]")
ins("ldp     d10, d11, [sp, #16]")
ins("ldp     d12, d13, [sp, #32]")
ins("ldp     d14, d15, [sp, #48]")
ins("mov     sp, x29")
ins("ldp     x29, x30, [sp], #16")
ins("ret")
e("#if !defined(__APPLE__)")
ins(".size   rc5_72_unit_func_neon_mix16, . - rc5_72_unit_func_neon_mix16")
e("#endif")
e()
ins("// Constant tables, in .text so adr reaches them on both ELF and Mach-O.")
ins(".p2align 6")
e("L(lanes):")
for p in range(NP):
    ins(".word   " + ", ".join(str(4 * p + i) for i in range(4)))
e("L(weights):")
ins(".word   1, 2, 4, 8")
e("// pass-1 subkey constants, one 64-byte row (4 pipes x 4 lanes) per subkey;")
e("// IS0 follows IS25 so the walking pointer reads pass-1 S[0] at k=26")
ins(".p2align 6")
names = [f"IS{i}" for i in range(3, 26)] + ["IS0"]
for name, val in zip(names, ROM):
    e(f"L({name}):")
    ins(".word   " + ", ".join([f"0x{val:08X}"] * (4 * NP)))
e()
e("#if !defined(__APPLE__)")
ins('.section .note.GNU-stack,"",%progbits')
e("#endif")

sys.stdout.write("\n".join(out) + "\n")
