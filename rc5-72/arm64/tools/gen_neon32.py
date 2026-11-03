#!/usr/bin/env python3
"""Generate rc5-72/arm64/r72-neon-mix32.S: AArch64 NEON port of MIX ZMM with 8 pipes x 4
lanes = 32 keys. Same structure as r72-neon-mix16.S (and MIX ZMM), except:
  - only the most recently updated B word of each pipe stays in a register;
    each step loads the word it updates from an L area on the stack and
    stores the word that just went idle;
  - the 8 pipes run as two lockstep groups of 4 sharing scratch registers;
  - A + B_1 is saved before encryption for the rare path's k=77 step.

Usage: gen_neon32.py [--testmask] > ../r72-neon-mix32.S
"""
import sys

TESTMASK = "--testmask" in sys.argv
NP = 8
GROUPS = [list(range(0, 4)), list(range(4, 8))]
STRIDE = 16 * NP                              # 128 bytes per subkey / L word

A  = [f"v{8 + p}" for p in range(NP)]         # v8-v15  (d8-d15 callee-saved)
BL = [f"v{16 + p}" for p in range(NP)]        # v16-v23 last-updated B word
T  = [f"v{i}" for i in range(0, 4)]           # scratch, per group
U  = [f"v{i}" for i in range(4, 8)]
Y  = [f"v{i}" for i in range(24, 28)]
CLO, CHI, C31, CM32 = "v28", "v29", "v30", "v31"
C = A                                         # encryption: C in v8-v15
D = BL                                        #             D in v16-v23
ALLT = [f"v{i}" for i in range(0, 8)]         # 8 scratch for the check

SAVE = 64
LS = SAVE                                     # L area: 3 words x 128 B
AB = LS + 3 * STRIDE                          # A + B_1 for the rare path: 128 B
S_OFF = AB + STRIDE                           # S table: 26 x 128 B
FRAME = S_OFF + 26 * STRIDE
assert FRAME % 64 == 0 and S_OFF % 64 == 0      # rows must not straddle cache lines
def S(n): return S_OFF + n * STRIDE
def L(j, p=0): return LS + j * STRIDE + 16 * p

out = []
def e(s=""): out.append(s)
def ins(s): out.append("        " + s)
def s4(r): return r + ".4s"
def b16(r): return r + ".16b"
def q(r): return "q" + r[1:]

def grp(fmt, g, **regs):
    """emit fmt once per pipe of group g; regs map name -> list indexed by
    pipe (len NP) or by position in group (len 4)."""
    for i, p in enumerate(g):
        ins(fmt.format(**{k: (v[p] if len(v) == NP else v[i]) for k, v in regs.items()}))

def ld4(dst, base, off):
    ins(f"ldp     {q(dst[0])}, {q(dst[1])}, [{base}, #{off}]")
    ins(f"ldp     {q(dst[2])}, {q(dst[3])}, [{base}, #{off + 32}]")

def st4(src, base, off):
    ins(f"stp     {q(src[0])}, {q(src[1])}, [{base}, #{off}]")
    ins(f"stp     {q(src[2])}, {q(src[3])}, [{base}, #{off + 32}]")

def gl(regs, g): return [regs[p] for p in g] if len(regs) == NP else regs

def rotl3(dst, src, g):
    grp("shl     {d}.4s, {s}.4s, #3", g, d=dst, s=src)
    grp("usra    {d}.4s, {s}.4s, #29", g, d=dst, s=src)

def vrotl(dst, x, s, t1, t2, g):
    """dst = x <<< s per lane; t1, t2 scratch (t2 may be s)."""
    grp("and     {u}.16b, {s}.16b, " + b16(C31), g, u=t1, s=s)
    grp("orr     {t}.16b, {s}.16b, " + b16(CM32), g, t=t2, s=s)
    grp("ushl    {u}.4s, {x}.4s, {u}.4s", g, u=t1, x=x)
    grp("ushl    {t}.4s, {x}.4s, {t}.4s", g, t=t2, x=x)
    grp("orr     {d}.16b, {u}.16b, {t}.16b", g, d=dst, u=t1, t=t2)

def ks_step(off, x, y, title):
    """MIX ZMM STEP A/B/C, Bx = BL (register), By loaded from the L area:
    A = (A + S[src] + Bx) <<< 3; S[dst] = A; T = Bx + A; By = (By + T) <<< T."""
    ins(f"// === {title} ===")
    for g in GROUPS:
        p0 = g[0]
        ld4(T, "x10", off + 16 * p0)
        grp("add     {t}.4s, {t}.4s, {a}.4s", g, t=T, a=A)
        grp("add     {t}.4s, {t}.4s, {b}.4s", g, t=T, b=BL)
        rotl3(A, T, g)
        st4(gl(A, g), "x11", off + 16 * p0)
        grp("add     {t}.4s, {b}.4s, {a}.4s", g, t=T, b=BL, a=A)
        ld4(Y, "sp", L(y, p0))
        st4(gl(BL, g), "sp", L(x, p0))
        grp("add     {y}.4s, {y}.4s, {t}.4s", g, y=Y, t=T)
        vrotl(BL, Y, T, U, T, g)

def half_round(X, Yr, off):
    """X = ((X ^ Y) <<< Y) + S[off], all pipes, in two groups."""
    for g in GROUPS:
        grp("eor     {x}.16b, {x}.16b, {y}.16b", g, x=X, y=Yr)
        vrotl(X, X, Yr, U, T, g)
        ld4(T, "x10", off + 16 * g[0])
        grp("add     {x}.4s, {x}.4s, {t}.4s", g, x=X, t=T)

def compare(dst, vecs, ref, vtmp):
    """dst[p] = (vecs[p] == ref); testmask build compares masked copies."""
    g = list(range(NP))
    if TESTMASK:
        ins("// R72_TESTMASK (test build only): compare masked copies")
        ins("adrp    x16, r72_testmask")
        ins("add     x16, x16, :lo12:r72_testmask")
        ins(f"ld1r    {{{s4(vtmp)}}}, [x16]")
        grp("and     {d}.16b, {v}.16b, " + b16(vtmp), g, d=dst, v=vecs)
        grp("cmeq    {d}.4s, {d}.4s, " + s4(ref), g, d=dst)
    else:
        grp("cmeq    {d}.4s, {v}.4s, " + s4(ref), g, d=dst, v=vecs)

def movemask(dst_w, vecs, wreg, vtmp, tmpw):
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

M = 0xFFFFFFFF
P, Qc = 0xB7E15163, 0x9E3779B9
def rotl(x, s):
    s &= 31
    return ((x << s) | (x >> (32 - s))) & M if s else x
S0 = rotl(P, 3)
K1 = (P + Qc + S0) & M
K2 = (P + 2 * Qc) & M
ROM = [(P + i * Qc) & M for i in range(3, 26)] + [S0]

# ==========================================================================
e("""// RC5-72 NEON core for AArch64 (MIX NEON32), 32 keys per batch.
// 8 pipes x 4 lanes. Same design as MIX NEON16 (r72-neon-mix16.S), a port
// of Mix's 64-key AVX-512F core (MIX ZMM, rc5-72/amd64/r72-avx512z.asm):
// scalar precompute of the first key-schedule steps, rolled 3-step loop
// with branchless pointer wraps, deferred k=77, merged low-word check and
// exact reference check.count/check.hi semantics. Twice the independent
// key chains of MIX NEON16, for cores with 4 or more vector pipes.
//
// 8 pipes x (A + 3 B words) does not fit in 32 registers, so:
//  - each pipe keeps A and its most recently updated B word in registers;
//    a step loads the B word it updates from an L area on the stack and
//    stores the word that just went idle (MIX ZMM keeps all three in zmm);
//  - the pipes run as two lockstep groups of 4 sharing scratch registers;
//  - A + B_1 is saved before encryption for the rare path's k=77 step.
//
// Variable rotate: x <<< s = ushl(x, s & 31) | ushl(x, s | 0xFFFFFFE0)
// (USHL takes the low byte of each lane as a signed shift). Rotate by 3:
// shl + usra.
// Needs MINIMUM_ITERATIONS to be a multiple of 32, so that L0hi is a
// multiple of 32 on entry.
//
// Generated by rc5-72/arm64/tools/gen_neon32.py; edit that, not this file.""" + ("\n// TEST BUILD: R72_TESTMASK enabled. Do not ship." if TESTMASK else ""))
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
        .globl  FUNC(rc5_72_unit_func_neon_mix32)
#if !defined(__APPLE__)
        .type   rc5_72_unit_func_neon_mix32, %function
#endif
FUNC(rc5_72_unit_func_neon_mix32):
// x0 = RC5_72UnitWork *, x1 = u32 *iterations, x2 = memblk (unused)
//
// Scalar registers (MIX ZMM equivalent in brackets):
//   w9  batches left [r10d]    w13 L0hi [r13d]    w14 L0mid [r14d]   w15 L0lo [r15d]
//   x10 S source [rax]         x11 S dest [rdx]   x12 &S[1] [r12]    x8  &S[-1] [r8]
//   w3  step counter [ebx]
//   w2  pre_B_0    w5 pre_S1    w4 pre_B_0 + pre_S1 [ecx]
//   w6  pre_B_1    w7 pre_S2    w17 pre_B_2
//   w10, w11, w16 scratch. The rare path uses only these, w3 and x8.
// Vector registers:
//   v8-v15  A, pipes 0-7 (C during encryption)
//   v16-v23 last-updated B word, pipes 0-7 (D during encryption)
//   v0-v7, v24-v27 scratch (shared by the two groups of 4 pipes)
//   v28 = cypher.lo  v29 = cypher.hi  v30 = 31  v31 = 0xFFFFFFE0
// Stack (64-byte aligned): d8-d15 | L words (3 x 128 B) | A + B_1 (128 B) | S table (26 x 128 B)
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
ins("lsr     w9, w9, #5                 // divide by 32 keys per batch")
ins("ldr     w13, [x0, #16]             // L0.hi")
ins("ldr     w14, [x0, #20]             // L0.mid")
ins("ldr     w15, [x0, #24]             // L0.lo")
ins(f"add     x12, sp, #{S(1)}            // &S[1]")
e()
ins(f"movi    {s4(C31)}, #31")
ins(f"mvni    {s4(CM32)}, #31              // 0xFFFFFFE0")
ins("add     x16, x0, #12")
ins(f"ld1r    {{{s4(CLO)}}}, [x16]          // cypher.lo")
ins("add     x16, x0, #8")
ins(f"ld1r    {{{s4(CHI)}}}, [x16]          // cypher.hi")
e()
e("L(outer_loop):")
ins("// k=0: pre_B_0 = (L0lo + S0) <<< 29")
mov32("w16", S0)
ins("add     w2, w15, w16")
ins("ror     w2, w2, #3")
ins("// k=1: pre_S1 = (P+Q + S0 + pre_B_0) <<< 3")
mov32("w16", K1)
ins("add     w5, w2, w16")
ins("ror     w5, w5, #29")
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
grp("dup     {a}.4s, w7", list(range(NP)), a=A)
ins(f"dup     {s4(T[0])}, w2                // L[0] = pre_B_0")
ins(f"dup     {s4(T[1])}, w6                // L[1] = pre_B_1")
ins(f"dup     {s4(T[2])}, w5                // S[1] = pre_S1")
for k in range(0, NP, 2):
    ins(f"stp     {q(T[0])}, {q(T[0])}, [sp, #{L(0, k)}]")
for k in range(0, NP, 2):
    ins(f"stp     {q(T[1])}, {q(T[1])}, [sp, #{L(1, k)}]")
for k in range(0, NP, 2):
    ins(f"stp     {q(T[2])}, {q(T[2])}, [sp, #{S(1) + 16 * k}]")
for k in range(0, NP, 2):
    ins(f"stp     {q(A[k])}, {q(A[k + 1])}, [sp, #{S(2) + 16 * k}]")
e()
ins("// k=2: B_2 = (L0hi + lane + pre_B_2) <<< pre_B_2 (same amount in every lane)")
ins(f"dup     {s4(Y[0])}, w17")
ins(f"and     {b16(Y[1])}, {b16(Y[0])}, {b16(C31)}")
ins(f"orr     {b16(Y[2])}, {b16(Y[0])}, {b16(CM32)}")
ins("adr     x16, L(lanes)")
for g in GROUPS:
    grp("dup     {b}.4s, w13", g, b=BL)
    ld4(T, "x16", 16 * g[0])
    grp("add     {b}.4s, {b}.4s, {t}.4s", g, b=BL, t=T)
    grp("add     {b}.4s, {b}.4s, " + s4(Y[0]), g, b=BL)
    grp("ushl    {u}.4s, {b}.4s, " + s4(Y[1]), g, u=U, b=BL)
    grp("ushl    {t}.4s, {b}.4s, " + s4(Y[2]), g, t=T, b=BL)
    grp("orr     {b}.16b, {u}.16b, {t}.16b", g, b=BL, u=U, t=T)
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
ins("// save A + B_1 (BL holds B_1 after k=76) for the rare path's k=77")
for g in GROUPS:
    grp("add     {t}.4s, {a}.4s, {b}.4s", g, t=T, a=A, b=BL)
    st4(T, "sp", AB + 16 * g[0])
ins("// C = plain.lo + S[0], D = plain.hi + S[1]")
ins("ldr     w16, [x0, #4]")
ins(f"dup     {s4(Y[0])}, w16")
ins("ldr     w16, [x0, #0]")
ins(f"dup     {s4(Y[1])}, w16")
ins(f"add     x10, sp, #{S(0)}")
for g in GROUPS:
    ld4(T, "x10", 16 * g[0])
    grp("add     {c}.4s, {t}.4s, " + s4(Y[0]), g, c=C, t=T)
    ld4(T, "x10", STRIDE + 16 * g[0])
    grp("add     {d}.4s, {t}.4s, " + s4(Y[1]), g, d=D, t=T)
ins(f"add     x10, x10, #{2 * STRIDE}")
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
half_round(C, D, 0)
e()
e("L(check_key):")
compare(ALLT, C, CLO, Y[0])
for i in range(4):
    ins(f"orr     {b16(Y[i])}, {b16(ALLT[2 * i])}, {b16(ALLT[2 * i + 1])}")
ins(f"orr     {b16(Y[0])}, {b16(Y[0])}, {b16(Y[1])}")
ins(f"orr     {b16(Y[2])}, {b16(Y[2])}, {b16(Y[3])}")
ins(f"orr     {b16(Y[0])}, {b16(Y[0])}, {b16(Y[2])}")
ins(f"umaxv   s{Y[0][1:]}, {s4(Y[0])}")
ins(f"fmov    w16, s{Y[0][1:]}")
ins("cbnz    w16, L(check_hi)")
e()
e("L(next_key):")
ins("subs    w9, w9, #1")
ins("b.eq    L(finished_nothing)")
ins("add     w13, w13, #32")
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
ins("// Rare path (about 1 batch in 2^27). Uses only w3, x8, w10, w11, w16, x16.")
ins(f"add     x8, x10, #{STRIDE}              // &S[25] (x10 = &S[24])")
ins("adr     x16, L(weights)")
ins(f"ldr     {q(Y[0])}, [x16]")
movemask("w10", ALLT, Y[0], Y[1], "w11")
ins("// w10 = 32-bit low-word match mask, bit n = key n")
e()
ins("// k=77: S[25] = (S[25] + A + B_1) <<< 3, then D = ((D ^ C) <<< C) + S[25]")
for g in GROUPS:
    ld4(Y, "x8", 16 * g[0])
    ld4(T, "sp", AB + 16 * g[0])
    grp("add     {t}.4s, {t}.4s, {y}.4s", g, t=T, y=Y)
    rotl3(Y, T, g)                            # Y = S[25] of pass 3
    grp("eor     {d}.16b, {d}.16b, {c}.16b", g, d=D, c=C)
    vrotl(D, D, C, U, T, g)
    grp("add     {d}.4s, {d}.4s, {y}.4s", g, d=D, y=Y)
compare(D, D, CHI, Y[0])
ins("adr     x16, L(weights)")
ins(f"ldr     {q(Y[0])}, [x16]")
movemask("w11", D, Y[0], Y[1], "w16")
ins("ands    w16, w11, w10              // keys matching both words")
ins("b.ne    L(save_found_key)")
e()
ins("// partial match(es) only: count them, record the last one (as the reference does)")
popcnt("w11", "w10", Y[0])
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
ins("sub     w11, w11, #1               // mask of keys 0..f (f=31 gives all ones)")
ins("and     w10, w10, w11")
popcnt("w11", "w10", Y[0])
ins("ldr     w16, [x0, #28]")
ins("add     w16, w16, w11")
ins("str     w16, [x0, #28]")
ins("add     w16, w3, w13")
ins("str     w16, [x0, #32]")
ins("str     w14, [x0, #36]")
ins("str     w15, [x0, #40]")
ins("// *iterations = keys before the winning one")
ins("ldr     w16, [x1]")
ins("lsr     w16, w16, #5")
ins("sub     w16, w16, w9")
ins("lsl     w16, w16, #5")
ins("add     w16, w16, w3")
ins("str     w16, [x1]")
ins("str     w14, [x0, #20]")
ins("str     w15, [x0, #24]")
ins("mov     w0, #2                     // RESULT_FOUND")
ins("b       L(finished)")
e()
e("L(finished_nothing):")
ins("add     w13, w13, #32")
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
ins(".size   rc5_72_unit_func_neon_mix32, . - rc5_72_unit_func_neon_mix32")
e("#endif")
e()
ins("// Constant tables, in .text so adr reaches them on both ELF and Mach-O.")
ins(".p2align 6")
e("L(lanes):")
for p in range(NP):
    ins(".word   " + ", ".join(str(4 * p + i) for i in range(4)))
e("L(weights):")
ins(".word   1, 2, 4, 8")
e("// pass-1 subkey constants, one 128-byte row (8 pipes x 4 lanes) per subkey;")
e("// IS0 follows IS25 so the walking pointer reads pass-1 S[0] at k=26")
ins(".p2align 6")
names = [f"IS{i}" for i in range(3, 26)] + ["IS0"]
for name, val in zip(names, ROM):
    e(f"L({name}):")
    for half in range(2):
        ins(".word   " + ", ".join([f"0x{val:08X}"] * 16))
e()
e("#if !defined(__APPLE__)")
ins('.section .note.GNU-stack,"",%progbits')
e("#endif")

sys.stdout.write("\n".join(out) + "\n")
