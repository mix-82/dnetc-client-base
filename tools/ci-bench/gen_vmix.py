#!/usr/bin/env python3
"""Generate vmix.S: AArch64 microbenchmark kernels for the MIX NEON cores'
instruction mix. Each kernel is `void vmix_<name>(uint64_t iters, void *scratch)`
running its body `iters` times. vmix.c times them and converts to cycles with
a calibrated clock. Data values are irrelevant (timing is data-independent).

Kernels:
  add, shl, sri, ushl, stp     one instruction type, independent (pipe throughput)
  mix_ind_cluster / mix_ind_inter
                               the key-schedule step's 4-shift : 7-other mix with no
                               data dependences, shifts clustered vs. spread
  step32_lockstep              the real MIX NEON32 key-schedule step (3 sub-steps,
                               8 pipes, loads and stores), as the core issues it
  step32_skew                  same, pipe group 2 half a step behind group 1,
                               phases merged (the rejected skew experiment)
  step32_fine                  same, the two groups' instructions alternated
  step32_nostore               lockstep without the stores (store cost)
  step16_lockstep              the MIX NEON16 step (4 pipes)
  sc4                          the hybrid core's scalar phase: one key-schedule
                               step for 4 independent scalar keys (pass-2 form:
                               S load, add, add, ror #29, transposed S store,
                               t = a+b, neg, add, ror by register)
  hyb16_1/2/3, hyb32_2/4/6     a NEON16 / NEON32 step with 1-6 scalar 4-key steps
                               interleaved proportionally: measures how many scalar
                               steps ride free beside the vector stream (the
                               KKS7450-style hybrid's balance point)
  xar, step32_xar, step16_xar  SVE2 (Linux only, run only when HWCAP2_SVE2 is set):
                               XAR alone, and the two steps with rotate-by-3 done as
                               one in-place XAR with a zero register instead of
                               shl + sri (A += S; A += B; xar A, A, zero, #29)
"""
import sys

out = []
def e(s=""): out.append(s)
def ins(s): out.append("        " + s)

# --- NEON32 register map (as in gen_neon32.py) --------------------------
NP = 8
A  = [f"v{8 + p}" for p in range(NP)]
BL = [f"v{16 + p}" for p in range(NP)]
T  = [f"v{i}" for i in range(0, 4)]
U  = [f"v{i}" for i in range(4, 8)]
Y  = [f"v{i}" for i in range(24, 28)]
T2 = [f"v{i}" for i in range(24, 28)]
C31, CM32 = "v30", "v31"
G1, G2 = list(range(0, 4)), list(range(4, 8))
STRIDE = 128
def q(r): return "q" + r[1:]

def cap(fn, *a):
    """capture the instructions fn emits as a list"""
    global out
    saved, out = out, []
    fn(*a)
    got, out = out, saved
    return got

def grp(fmt, g, **regs):
    for i, p in enumerate(g):
        ins(fmt.format(**{k: (v[p] if len(v) == NP else v[i]) for k, v in regs.items()}))

def ld4(dst, base, off):
    ins(f"ldp     {q(dst[0])}, {q(dst[1])}, [{base}, #{off}]")
    ins(f"ldp     {q(dst[2])}, {q(dst[3])}, [{base}, #{off + 32}]")

def st4(src, base, off):
    ins(f"stp     {q(src[0])}, {q(src[1])}, [{base}, #{off}]")
    ins(f"stp     {q(src[2])}, {q(src[3])}, [{base}, #{off + 32}]")

def gl(regs, g): return [regs[p] for p in g] if len(regs) == NP else regs

XAR = False         # SVE2: rotate A in place with XAR (needs zero register v28)
def z(r): return "z" + r[1:]

def rotl3(dst, src, g):
    grp("shl     {d}.4s, {s}.4s, #3", g, d=dst, s=src)
    grp("sri     {d}.4s, {s}.4s, #29", g, d=dst, s=src)

def vrotl(dst, x, s, t1, t2, g):
    grp("and     {u}.16b, {s}.16b, " + C31 + ".16b", g, u=t1, s=s)
    grp("orr     {t}.16b, {s}.16b, " + CM32 + ".16b", g, t=t2, s=s)
    grp("ushl    {u}.4s, {x}.4s, {u}.4s", g, u=t1, x=x)
    grp("ushl    {t}.4s, {x}.4s, {t}.4s", g, t=t2, x=x)
    grp("orr     {d}.16b, {u}.16b, {t}.16b", g, d=dst, u=t1, t=t2)

STORES = True
def ks_step(off, x, y):
    """MIX NEON32 step, lockstep (gen_neon32.py ks_step with sri)."""
    for g in (G1, G2):
        p0 = g[0]
        ld4(T, "x10", off + 16 * p0)
        if XAR:
            grp("add     {a}.4s, {a}.4s, {t}.4s", g, a=A, t=T)
            grp("add     {a}.4s, {a}.4s, {b}.4s", g, a=A, b=BL)
            for p in g: ins(f"xar     {z(A[p])}.s, {z(A[p])}.s, z28.s, #29")
        else:
            grp("add     {t}.4s, {t}.4s, {a}.4s", g, t=T, a=A)
            grp("add     {t}.4s, {t}.4s, {b}.4s", g, t=T, b=BL)
            rotl3(A, T, g)
        if STORES: st4(gl(A, g), "x11", off + 16 * p0)
        grp("add     {t}.4s, {b}.4s, {a}.4s", g, t=T, b=BL, a=A)
        ld4(Y, "x12", 128 * y + 16 * p0)
        if STORES: st4(gl(BL, g), "x12", 128 * x + 16 * p0)
        grp("add     {y}.4s, {y}.4s, {t}.4s", g, y=Y, t=T)
        vrotl(BL, Y, T, U, T, g)

def e_phase(g, Tg, off, x):
    p0 = g[0]
    ld4(Tg, "x10", off + 16 * p0)
    grp("add     {t}.4s, {t}.4s, {a}.4s", g, t=Tg, a=A)
    grp("add     {t}.4s, {t}.4s, {b}.4s", g, t=Tg, b=BL)
    rotl3(A, Tg, g)
    st4(gl(A, g), "x11", off + 16 * p0)
    grp("add     {t}.4s, {b}.4s, {a}.4s", g, t=Tg, b=BL, a=A)
    st4(gl(BL, g), "x12", 128 * x + 16 * p0)

def l_phase(g, Tg, y):
    ld4(gl(BL, g), "x12", 128 * y + 16 * g[0])
    grp("add     {b}.4s, {b}.4s, {t}.4s", g, b=BL, t=Tg)
    vrotl(BL, BL, Tg, U, Tg, g)

STEPS = {"A": (-STRIDE, 1, 2), "B": (0, 2, 0), "C": (STRIDE, 0, 1)}
def E(g, s): off, x, y = STEPS[s]; return cap(e_phase, g, T if g is G1 else T2, off, x)
def L(g, s): off, x, y = STEPS[s]; return cap(l_phase, g, T if g is G1 else T2, y)

def concat(a, b): out.extend(a); out.extend(b)
def alternate(a, b):
    for i in range(max(len(a), len(b))):
        if i < len(a): out.append(a[i])
        if i < len(b): out.append(b[i])

def skewed_round(merge):
    """one 3-sub-step round with group 2 half a step behind; `merge` combines
    the two groups' phase streams (concat = skew experiment, alternate = fine)."""
    merge(E(G1, "A"), L(G2, "C"))
    merge(L(G1, "A"), E(G2, "A"))
    merge(E(G1, "B"), L(G2, "A"))
    merge(L(G1, "B"), E(G2, "B"))
    merge(E(G1, "C"), L(G2, "B"))
    merge(L(G1, "C"), E(G2, "C"))

# --- NEON16 step (gen_neon16.py layout) ------------------------------------
def step16(ngroups=4, loads=True, stores=True, mul=False):
    """ngroups < 4 runs only the first ngroups vector chains (latency probe);
    loads/stores False drop the S-row ldp/stp (memory-cost probe)."""
    A16 = [f"v{i}" for i in range(8, 12)]
    B16 = [[f"v{12 + 3 * p + j}" for j in range(3)] for p in range(4)]
    g = list(range(4))
    def grp4(fmt, **regs):
        for i in range(ngroups):
            ins(fmt.format(**{k: v[i] for k, v in regs.items()}))
    for off, bx, by in ((-64, 1, 2), (0, 2, 0), (64, 0, 1)):
        Bx = [B16[p][bx] for p in range(4)]; By = [B16[p][by] for p in range(4)]
        if loads:
            ins(f"ldp     q0, q1, [x10, #{off + 256}]")
            ins(f"ldp     q2, q3, [x10, #{off + 288}]")
        if XAR:
            grp4("add     {a}.4s, {a}.4s, {t}.4s", a=A16, t=T)
            grp4("add     {a}.4s, {a}.4s, {b}.4s", a=A16, b=Bx)
            for i in range(4): ins(f"xar     z{8 + i}.s, z{8 + i}.s, z28.s, #29")
        else:
            grp4("add     {t}.4s, {t}.4s, {a}.4s", t=T, a=A16)
            grp4("add     {t}.4s, {t}.4s, {b}.4s", t=T, b=Bx)
            if mul:  # x<<3 as x*8: vector mul issues on V0, shifts only on V1 (N2)
                grp4("mul     {a}.4s, {t}.4s, v29.4s", a=A16, t=T)
            else:
                grp4("shl     {a}.4s, {t}.4s, #3", a=A16, t=T)
            grp4("sri     {a}.4s, {t}.4s, #29", a=A16, t=T)
        if stores:
            ins(f"stp     q8, q9, [x11, #{off + 256}]")
            ins(f"stp     q10, q11, [x11, #{off + 288}]")
        grp4("add     {t}.4s, {b}.4s, {a}.4s", t=T, b=Bx, a=A16)
        grp4("add     {y}.4s, {y}.4s, {t}.4s", y=By, t=T)
        grp4("and     {u}.16b, {s}.16b, v30.16b", u=U, s=T)
        grp4("orr     {t}.16b, {s}.16b, v31.16b", t=T, s=T)
        grp4("ushl    {u}.4s, {x}.4s, {u}.4s", u=U, x=By)
        grp4("ushl    {t}.4s, {x}.4s, {t}.4s", t=T, x=By)
        grp4("orr     {x}.16b, {u}.16b, {t}.16b", x=By, u=U, t=T)

# --- hybrid: scalar 4-key key-schedule step --------------------------------
# a_k = ROTL3(S_k[i] + a_k + b_k); S stored transposed (4 x 4 B in one 16 B
# row, the scalar->vector handoff); t = a_k + b_k; l_k = ROTL(l_k + t, t).
# ARM64 has no rotate-left: ROTL3 = ror #29, ROTL(x,t) = ror x, neg t.
SCA = ["w2", "w3", "w4", "w5"]        # a (S chain)
SCB = ["w6", "w7", "w8", "w9"]        # one L word per key
SCC = ["w19", "w20", "w21", "w22"]    # the other L word per key
SCT = ["w13", "w14", "w15", "w16"]    # t = a + b
SCN = ["w23", "w24", "w25", "w26"]    # -t for the register rotate
# x19-x26 are callee-saved (saved by the kernel wrapper); x17/x18 avoided
# (x18 is reserved on Apple platforms).
SC_S = 6144                           # transposed S rows in the scratch area

def sc_step(i, src, dst):
    off = SC_S + (i % 26) * 16
    for k in range(4): ins(f"add     {SCT[k]}, {SCA[k]}, {src[k]}")
    for k in range(4): ins(f"ldr     {SCA[k]}, [x1, #{off + 4 * k}]")
    for k in range(4): ins(f"add     {SCA[k]}, {SCA[k]}, {SCT[k]}")
    for k in range(4): ins(f"ror     {SCA[k]}, {SCA[k]}, #29")
    for k in range(4): ins(f"str     {SCA[k]}, [x1, #{off + 4 * k}]")
    for k in range(4): ins(f"add     {SCT[k]}, {SCA[k]}, {src[k]}")
    for k in range(4): ins(f"neg     {SCN[k]}, {SCT[k]}")
    for k in range(4): ins(f"add     {dst[k]}, {dst[k]}, {SCT[k]}")
    for k in range(4): ins(f"ror     {dst[k]}, {dst[k]}, {SCN[k]}")

def sc_lines(nsteps, base=10):
    def f():
        for i in range(nsteps):
            src, dst = (SCB, SCC) if i % 2 == 0 else (SCC, SCB)
            sc_step(base + i, src, dst)
    return cap(f)

def merge_prop(a, b):
    """append a with b's lines distributed evenly through it"""
    bi = 0
    for i, line in enumerate(a):
        out.append(line)
        want = (i + 1) * len(b) // len(a)
        while bi < want:
            out.append(b[bi]); bi += 1
    while bi < len(b):
        out.append(b[bi]); bi += 1

def hyb16(r, mul=False):
    merge_prop(cap(step16, 4, True, True, mul), sc_lines(3 * r))

def hyb32(r):
    merge_prop(cap(lock), sc_lines(3 * r))

# --- ordering / load-store variants of the NEON16 step (Arm guides, Nov 7) --
# ld/st: "pair" = ldp/stp q (as step16), "single" = ldr/str q per pipe.
# order: "grp" = as step16 (4 pipes per op, e.g. 4 shl then 4 sri);
#        "skew" = diagonal wavefront over the 3 sub-steps, pipe p one op
#        behind pipe p-1, so adjacent instructions are different ops (spreads
#        the F1-only shifts on Cortex-A57/A72). Same instructions and
#        dependences; dependent ops stay 4 apart except at the loop edge.
def step16v(ld="pair", st="pair", order="grp"):
    A16 = [f"v{i}" for i in range(8, 12)]
    B16 = [[f"v{12 + 3 * p + j}" for j in range(3)] for p in range(4)]
    seq = [[] for _ in range(4)]
    for off, bx, by in ((-64, 1, 2), (0, 2, 0), (64, 0, 1)):
        Bx = [B16[p][bx] for p in range(4)]; By = [B16[p][by] for p in range(4)]
        def ops(i):
            t, u, a, x, y = T[i], U[i], A16[i], Bx[i], By[i]
            l = []
            if ld == "single": l.append(f"ldr     q{i}, [x10, #{off + 256 + 16 * i}]")
            l += [f"add     {t}.4s, {t}.4s, {a}.4s", f"add     {t}.4s, {t}.4s, {x}.4s",
                  f"shl     {a}.4s, {t}.4s, #3", f"sri     {a}.4s, {t}.4s, #29"]
            if st == "single": l.append(f"str     q{8 + i}, [x11, #{off + 256 + 16 * i}]")
            l += [f"add     {t}.4s, {x}.4s, {a}.4s", f"add     {y}.4s, {y}.4s, {t}.4s",
                  f"and     {u}.16b, {t}.16b, v30.16b", f"orr     {t}.16b, {t}.16b, v31.16b",
                  f"ushl    {u}.4s, {y}.4s, {u}.4s", f"ushl    {t}.4s, {y}.4s, {t}.4s",
                  f"orr     {y}.16b, {u}.16b, {t}.16b"]
            return l
        P = [ops(i) for i in range(4)]
        if order == "skew":
            assert st == "single" and ld == "single"
            for i in range(4): seq[i] += P[i]
            continue
        if ld == "pair":
            ins(f"ldp     q0, q1, [x10, #{off + 256}]")
            ins(f"ldp     q2, q3, [x10, #{off + 288}]")
        n = len(P[0])
        if order == "grp":
            for j in range(n):
                for i in range(4): ins(P[i][j])
                if st == "pair" and P[0][j].startswith("sri"):
                    ins(f"stp     q8, q9, [x11, #{off + 256}]")
                    ins(f"stp     q10, q11, [x11, #{off + 288}]")
    if order == "skew":     # one wavefront over all 3 sub-steps (pipes are independent)
        n = len(seq[0])
        for t in range(n + 3):
            for i in range(4):
                if 0 <= t - i < n: ins(seq[i][t - i])

def merge_pair(a, b):
    """in-order dual-issue order (Cortex-A55 rule: a 128-bit vector op pairs
    only as the older instruction): each line of a is followed by one line of
    b; b's surplus goes in pairs after evenly spaced lines of a."""
    extra = max(0, len(b) - len(a))
    pairs, bi, got = extra // 2, 0, 0
    for i, line in enumerate(a):
        out.append(line)
        if bi < len(b) and (len(b) >= len(a) or (i + 1) * len(b) // len(a) > bi):
            out.append(b[bi]); bi += 1
        want = (i + 1) * pairs // len(a)
        while got < want and bi + 1 < len(b):
            out.append(b[bi]); out.append(b[bi + 1]); bi += 2; got += 1
    out.extend(b[bi:])

def hyb16v(r, merge, **kw):
    v = cap(step16v, kw.get("ld", "pair"), kw.get("st", "pair"), kw.get("order", "grp"))
    merge(v, sc_lines(3 * r))

# --- simple kernels ----------------------------------------------------------
def simple(op, n=32):
    """n independent instructions rotating over v8-v23 (16 registers)."""
    for i in range(n):
        d = f"v{8 + i % 16}"; s = f"v{8 + (i + 5) % 16}"
        if op == "add":  ins(f"add     {d}.4s, {s}.4s, {d}.4s")
        if op == "shl":  ins(f"shl     {d}.4s, {s}.4s, #3")
        if op == "sri":  ins(f"sri     {d}.4s, {s}.4s, #29")
        if op == "ushl": ins(f"ushl    {d}.4s, {s}.4s, v30.4s")
        if op == "stp":  ins(f"stp     {q(d)}, {q(s)}, [x10, #{(i % 8) * 32}]")
        if op == "xar":  ins(f"xar     {z(d)}.s, {z(d)}.s, {z(s)}.s, #29")

def mix_ind(cluster):
    """44 instructions = 4 x (4 shifts + 7 others), independent."""
    regs = [f"v{8 + i}" for i in range(16)]
    k = [0]
    def r():
        k[0] += 1; return regs[k[0] % 16]
    shifts = [lambda: ins(f"shl     {r()}.4s, {r()}.4s, #3"),
              lambda: ins(f"sri     {r()}.4s, {r()}.4s, #29"),
              lambda: ins(f"ushl    {r()}.4s, {r()}.4s, v30.4s"),
              lambda: ins(f"ushl    {r()}.4s, {r()}.4s, v30.4s")]
    others = [lambda: ins(f"add     {r()}.4s, {r()}.4s, {r()}.4s")] * 4 + \
             [lambda: ins(f"and     {r()}.16b, {r()}.16b, v30.16b"),
              lambda: ins(f"orr     {r()}.16b, {r()}.16b, v31.16b"),
              lambda: ins(f"orr     {r()}.16b, {r()}.16b, {r()}.16b")]
    for _ in range(4):
        if cluster:
            for f in shifts: f()
            for f in others: f()
        else:
            seq = [others[0], shifts[0], others[1], others[2], shifts[1], others[3],
                   others[4], shifts[2], others[5], shifts[3], others[6]]
            for f in seq: f()

# --- emit ----------------------------------------------------------------
KERNELS = {}
def kernel(name, body, unit):
    """unit: instructions or steps per iteration, for the report"""
    KERNELS[name] = unit
    e(f"        .globl  FUNC(vmix_{name})")
    e("#if !defined(__APPLE__)")
    e(f"        .type   vmix_{name}, %function")
    e("#endif")
    e("        .p2align 6")
    e(f"FUNC(vmix_{name}):")
    ins("stp     x29, x30, [sp, #-16]!")
    ins("mov     x29, sp")
    ins("sub     sp, sp, #128")
    ins("stp     d8, d9, [sp, #0]")
    ins("stp     d10, d11, [sp, #16]")
    ins("stp     d12, d13, [sp, #32]")
    ins("stp     d14, d15, [sp, #48]")
    ins("stp     x19, x20, [sp, #64]")
    ins("stp     x21, x22, [sp, #80]")
    ins("stp     x23, x24, [sp, #96]")
    ins("stp     x25, x26, [sp, #112]")
    ins("add     x10, x1, #1024             // S source / scratch rows")
    ins("add     x11, x1, #1024             // S dest")
    ins("add     x12, x1, #4096             // L area")
    ins("movi    v30.4s, #31")
    ins("mvni    v31.4s, #31")
    ins("movi    v28.16b, #0                // zero register for XAR")
    ins("movi    v29.4s, #8                 // multiplier for the mul variants")
    e(f"L(vmix_{name}_loop):")
    body()
    ins("subs    x0, x0, #1")
    e(f"        b.ne    L(vmix_{name}_loop)")
    ins("ldp     d8, d9, [sp, #0]")
    ins("ldp     d10, d11, [sp, #16]")
    ins("ldp     d12, d13, [sp, #32]")
    ins("ldp     d14, d15, [sp, #48]")
    ins("ldp     x19, x20, [sp, #64]")
    ins("ldp     x21, x22, [sp, #80]")
    ins("ldp     x23, x24, [sp, #96]")
    ins("ldp     x25, x26, [sp, #112]")
    ins("mov     sp, x29")
    ins("ldp     x29, x30, [sp], #16")
    ins("ret")
    e()

e("""// Generated by tools/ci-bench/gen_vmix.py. See that file.
#if defined(__APPLE__)
#define FUNC(name) _##name
#define L(name) L##name
#else
#define FUNC(name) name
#define L(name) .L##name
#endif
        .text
""")
for op in ("add", "shl", "sri", "ushl", "stp"):
    kernel(op, lambda op=op: simple(op), 32)
kernel("mix_ind_cluster", lambda: mix_ind(True), 44)
kernel("mix_ind_inter", lambda: mix_ind(False), 44)
def lock():
    ks_step(-STRIDE, 1, 2); ks_step(0, 2, 0); ks_step(STRIDE, 0, 1)
kernel("step32_lockstep", lock, 3)
kernel("step32_skew", lambda: skewed_round(concat), 3)
kernel("step32_fine", lambda: skewed_round(alternate), 3)
def nostore():
    global STORES
    STORES = False; lock(); STORES = True
kernel("step32_nostore", nostore, 3)
kernel("step16_lockstep", step16, 3)
kernel("step16_noload", lambda: step16(loads=False), 3)
kernel("step16_nomem", lambda: step16(loads=False, stores=False), 3)
kernel("step16_g1", lambda: step16(ngroups=1), 3)
kernel("step16_g2", lambda: step16(ngroups=2), 3)
kernel("step16_g3", lambda: step16(ngroups=3), 3)
kernel("step16_mul", lambda: step16(mul=True), 3)
def sc3():
    sc_step(15, SCB, SCC); sc_step(16, SCC, SCB); sc_step(17, SCB, SCC)
kernel("sc4", sc3, 3)
for r in (1, 2, 3):
    kernel(f"hyb16_{r}", lambda r=r: hyb16(r), 3)
for r in (1, 2):
    kernel(f"hyb16_mul_{r}", lambda r=r: hyb16(r, True), 3)
kernel("step16_v", lambda: step16v(), 3)
kernel("step16_str", lambda: step16v(st="single"), 3)
kernel("step16_ldr", lambda: step16v(ld="single"), 3)
kernel("step16_ls", lambda: step16v(ld="single", st="single"), 3)
kernel("step16_skew", lambda: step16v("single", "single", "skew"), 3)
for r in (1, 2):
    kernel(f"hyb16_pair_{r}", lambda r=r: hyb16v(r, merge_pair), 3)
    kernel(f"hyb16_lsp_{r}", lambda r=r: hyb16v(r, merge_pair, ld="single", st="single"), 3)
    kernel(f"hyb16_skp_{r}", lambda r=r: hyb16v(r, merge_pair, ld="single", st="single", order="skew"), 3)
    kernel(f"hyb16_skw_{r}", lambda r=r: hyb16v(r, merge_prop, ld="single", st="single", order="skew"), 3)
for r in (2, 4, 6):
    kernel(f"hyb32_{r}", lambda r=r: hyb32(r), 3)

# SVE2 kernels: ELF only (Apple has no SVE); vmix.c runs them only if the
# kernel reports HWCAP2_SVE2.
e("#if !defined(__APPLE__)")
e("        .arch_extension sve2")
kernel("xar", lambda: simple("xar"), 32)
def lock_xar():
    global XAR
    XAR = True; lock(); XAR = False
kernel("step32_xar", lock_xar, 3)
def step16_xar():
    global XAR
    XAR = True; step16(); XAR = False
kernel("step16_xar", step16_xar, 3)
e("#endif")

e("#if !defined(__APPLE__)")
e('        .section .note.GNU-stack,"",%progbits')
e("#endif")
sys.stdout.write("\n".join(out) + "\n")
sys.stderr.write("kernels: " + " ".join(f"{k}={v}" for k, v in KERNELS.items()) + "\n")
