#!/usr/bin/env python3
# Generates the SVE / streaming-SVE RC5-72 kernels for sme_rc5_bench.
#
#   gen_kernels.py <clang> <outdir>
#
# Writes <outdir>/kernels.S (readable assembly) and <outdir>/kernels.inc (the
# same code as .long words, one blob per function, for the single-file C
# program). The machine code is position independent and uses only
# instructions that are legal in streaming SVE mode, so the same bytes run
# under smstart (Apple M4 and later) and as plain SVE2 (other Arm CPUs).
#
# Kernel ABI: void k(const kargs_t *a), see sme_rc5_bench.c. A kernel checks
# a->nbatch batches of W * lanes keys; lanes = cntw (16 at a 512-bit vector).
# Key number idx (0, 1, 2, ...) uses t = hi0 + idx, L2 = t & 0xff,
# L1 = l1 + (t >> 8), L0 = l0. The two encrypted words of every key are
# stored to out_a[idx] and out_b[idx].
#
# Registers: per stream 7 Z registers (A, L0, L1, L2 and three temporaries);
# z29 = 0, z30 = 32, z31 = 31. S[] lives in a->scratch (26 * W vectors).
# Only x0-x13 are used; callee-saved d8-d15 are saved by the C side's call
# stubs, which also do smstart / smstop.

import os
import struct
import subprocess
import sys

ZERO, C32, C31 = 'z29', 'z30', 'z31'


class Stream:
    def __init__(self, w):
        self.w = w
        names = ['A', 'L0', 'L1', 'L2', 't', 't2', 't3']
        self.r = {n: 'z%d' % (w * 7 + k) for k, n in enumerate(names)}

    def __getitem__(self, n):
        return self.r[n]

    def swap(self, a, b):
        self.r[a], self.r[b] = self.r[b], self.r[a]


def gen_kernel(W, xar):
    name = 'k_sve_w%d_%s' % (W, 'xar' if xar else 'sli')
    o = []
    e = o.append
    st = [Stream(w) for w in range(W)]

    def each(fmt):
        # one instruction per stream, streams interleaved
        for s in st:
            e('  ' + fmt(s))

    e('// %s: %d stream(s) of cntw keys; rotate by 3 with %s' %
      (name, W, 'xar' if xar else 'lsl + usra'))
    e('%s:' % name)
    e('  ptrue p0.s')
    e('  ldp w7, w8, [x0, #0]          // l0, l1')
    e('  ldp w6, w5, [x0, #8]          // hi0 (key number base), nbatch')
    e('  ldp w9, w10, [x0, #16]        // plain lo, hi')
    e('  ldp x1, x2, [x0, #32]         // out_a, out_b')
    e('  ldp x3, x4, [x0, #48]         // scratch, constants P + i*Q')
    e('  mov %s.s, #0' % ZERO)
    e('  mov %s.s, #32' % C32)
    e('  mov %s.s, #31' % C31)
    e('  cntw x12')
    e('  cbz w5, 9f')
    e('1:')
    # keys of this batch
    e('  mov w13, w6')
    for s in st:
        e('  index %s.s, w13, #1' % s['L2'])
        e('  add w13, w13, w12')
        e('  lsr %s.s, %s.s, #8' % (s['L1'], s['L2']))
        e('  and %s.s, %s.s, #0xff' % (s['L2'], s['L2']))
        e('  mov %s.s, w8' % s['t'])
        e('  add %s.s, %s.s, %s.s' % (s['L1'], s['L1'], s['t']))
        e('  mov %s.s, w7' % s['L0'])
        e('  mov %s.s, #0' % s['A'])
    e('  mov w6, w13')

    # key schedule: 78 steps
    for k in range(78):
        i, j = k % 26, k % 3
        lj = 'L%d' % j
        lp = 'L%d' % ((j + 2) % 3)
        first = (k == 0)       # A = B = 0
        e('  // step %d: S[%d], L[%d]' % (k, i, j))
        if i == 0:
            e('  mov x11, x3')
        if k < 26:
            each(lambda s: 'ld1rw %s.s, p0/z, [x4, #%d]' % (s['t'], i * 4))
        else:
            each(lambda s: 'ld1w %s.s, p0/z, [x11, #%d, mul vl]' % (s['t'], s.w))
        each(lambda s: 'add %s.s, %s.s, %s.s' % (s['t'], s['t'], s['A']))
        if not first:
            each(lambda s: 'add %s.s, %s.s, %s.s' % (s['t'], s['t'], s[lp]))
        if xar:
            # t = ror(t ^ 0, 29) = rotl(t, 3); the result becomes A
            each(lambda s: 'xar %s.s, %s.s, %s.s, #29' % (s['t'], s['t'], ZERO))
            for s in st:
                s.swap('A', 't')
        else:
            each(lambda s: 'lsl %s.s, %s.s, #3' % (s['A'], s['t']))
            each(lambda s: 'usra %s.s, %s.s, #29' % (s['A'], s['t']))
        each(lambda s: 'st1w %s.s, p0, [x11, #%d, mul vl]' % (s['A'], s.w))
        e('  addvl x11, x11, #%d' % W)
        if first:
            each(lambda s: 'mov %s.d, %s.d' % (s['t2'], s['A']))
        else:
            each(lambda s: 'add %s.s, %s.s, %s.s' % (s['t2'], s['A'], s[lp]))
        each(lambda s: 'add %s.s, %s.s, %s.s' % (s[lj], s[lj], s['t2']))
        each(lambda s: 'and %s.d, %s.d, %s.d' % (s['t2'], s['t2'], C31))
        each(lambda s: 'sub %s.s, %s.s, %s.s' % (s['t3'], C32, s['t2']))
        each(lambda s: 'lslr %s.s, p0/m, %s.s, %s.s' % (s['t2'], s['t2'], s[lj]))
        each(lambda s: 'lsrr %s.s, p0/m, %s.s, %s.s' % (s['t3'], s['t3'], s[lj]))
        each(lambda s: 'orr %s.d, %s.d, %s.d' % (s[lj], s['t2'], s['t3']))

    # encryption; eA in the A register, eB in the L0 register
    e('  // encryption')
    e('  mov x11, x3')
    each(lambda s: 'ld1w %s.s, p0/z, [x11, #%d, mul vl]' % (s['t'], s.w))
    each(lambda s: 'mov %s.s, w9' % s['A'])
    each(lambda s: 'add %s.s, %s.s, %s.s' % (s['A'], s['A'], s['t']))
    e('  addvl x11, x11, #%d' % W)
    each(lambda s: 'ld1w %s.s, p0/z, [x11, #%d, mul vl]' % (s['t'], s.w))
    each(lambda s: 'mov %s.s, w10' % s['L0'])
    each(lambda s: 'add %s.s, %s.s, %s.s' % (s['L0'], s['L0'], s['t']))
    e('  addvl x11, x11, #%d' % W)
    for h in range(24):
        d, src = ('A', 'L0') if h % 2 == 0 else ('L0', 'A')
        e('  // half round %d' % h)
        each(lambda s: 'eor %s.d, %s.d, %s.d' % (s[d], s[d], s[src]))
        each(lambda s: 'and %s.d, %s.d, %s.d' % (s['t2'], s[src], C31))
        each(lambda s: 'sub %s.s, %s.s, %s.s' % (s['t3'], C32, s['t2']))
        each(lambda s: 'lslr %s.s, p0/m, %s.s, %s.s' % (s['t2'], s['t2'], s[d]))
        each(lambda s: 'lsrr %s.s, p0/m, %s.s, %s.s' % (s['t3'], s['t3'], s[d]))
        each(lambda s: 'ld1w %s.s, p0/z, [x11, #%d, mul vl]' % (s['t'], s.w))
        each(lambda s: 'orr %s.d, %s.d, %s.d' % (s[d], s['t2'], s['t3']))
        each(lambda s: 'add %s.s, %s.s, %s.s' % (s[d], s[d], s['t']))
        e('  addvl x11, x11, #%d' % W)
    each(lambda s: 'st1w %s.s, p0, [x1, #%d, mul vl]' % (s['A'], s.w))
    each(lambda s: 'st1w %s.s, p0, [x2, #%d, mul vl]' % (s['L0'], s.w))
    e('  addvl x1, x1, #%d' % W)
    e('  addvl x2, x2, #%d' % W)
    e('  subs w5, w5, #1')
    e('  b.ne 1b')
    e('9:')
    e('  ret')
    return name, o


STUBS = r'''
// uint64_t call_sm(uint64_t (*fn)(void *), void *arg): call fn in streaming SVE mode
call_sm:
  stp x29, x30, [sp, #-80]!
  mov x29, sp
  stp d8, d9, [sp, #16]
  stp d10, d11, [sp, #32]
  stp d12, d13, [sp, #48]
  stp d14, d15, [sp, #64]
  mov x9, x0
  mov x0, x1
  smstart sm
  blr x9
  smstop sm
  ldp d8, d9, [sp, #16]
  ldp d10, d11, [sp, #32]
  ldp d12, d13, [sp, #48]
  ldp d14, d15, [sp, #64]
  ldp x29, x30, [sp], #80
  ret

// the same without the mode switch (plain SVE)
call_plain:
  stp x29, x30, [sp, #-80]!
  mov x29, sp
  stp d8, d9, [sp, #16]
  stp d10, d11, [sp, #32]
  stp d12, d13, [sp, #48]
  stp d14, d15, [sp, #64]
  mov x9, x0
  mov x0, x1
  blr x9
  ldp d8, d9, [sp, #16]
  ldp d10, d11, [sp, #32]
  ldp d12, d13, [sp, #48]
  ldp d14, d15, [sp, #64]
  ldp x29, x30, [sp], #80
  ret

// leave streaming mode; harmless when not in it (only call if SME exists)
do_smstop:
  smstop sm
  ret

// probes: tiny functions to run through call_sm or call_plain
p_nop:
  mov x0, #1
  ret
p_cntw:
  cntw x0
  ret
p_add:
  mov z0.s, #5
  mov z1.s, #7
  add z0.s, z0.s, z1.s
  fmov w0, s0
  ret
p_xar:
  mov z0.s, #1
  mov z1.s, #0
  xar z0.s, z0.s, z1.s, #29
  fmov w0, s0
  ret
p_usra:
  mov z0.s, #1
  lsl z1.s, z0.s, #3
  usra z1.s, z0.s, #29
  fmov w0, s1
  ret
p_shift:
  ptrue p0.s
  mov z0.s, #3
  mov z1.s, #1
  lslr z0.s, p0/m, z0.s, z1.s
  fmov w0, s0
  ret
p_neon:
  movi v0.4s, #9
  add v0.4s, v0.4s, v0.4s
  fmov w0, s0
  ret
'''

STUB_NAMES = ['call_sm', 'call_plain', 'do_smstop', 'p_nop', 'p_cntw', 'p_add', 'p_xar',
              'p_usra', 'p_shift', 'p_neon']


def elf_text_and_symbols(path):
    # minimal ELF64 little-endian relocatable reader: .text bytes and symbol offsets
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF' and d[4] == 2 and d[5] == 1
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3A)
    secs = []
    for i in range(shnum):
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize)
        secs.append((name, typ, off, size, link, entsize))
    shstr = secs[shstrndx]

    def sname(n):
        s = d[shstr[2] + n:]
        return s[:s.index(b'\0')].decode()
    text_idx = [i for i, s in enumerate(secs) if sname(s[0]) == '.text'][0]
    text = d[secs[text_idx][2]:secs[text_idx][2] + secs[text_idx][3]]
    relocs = [sname(s[0]) for s in secs if s[1] in (4, 9) and s[3]]
    assert not relocs, 'unexpected relocations: %s' % relocs
    symtab = [s for s in secs if s[1] == 2][0]
    strtab = secs[symtab[4]]
    syms = {}
    for k in range(symtab[3] // symtab[5]):
        nm, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', d, symtab[2] + k * symtab[5])
        if shndx == text_idx and nm:
            s = d[strtab[2] + nm:]
            syms[s[:s.index(b'\0')].decode()] = value
    return text, syms


def main():
    clang, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    kernels = []
    src = ['// Generated by gen_kernels.py. Do not edit.', '.arch armv9-a+sme', '.text', '.p2align 2']
    src += STUBS.strip('\n').split('\n')
    for W in (1, 2, 4):
        for xar in (True, False):
            name, lines = gen_kernel(W, xar)
            kernels.append((name, W, xar))
            src.append('')
            src += lines
    spath = os.path.join(outdir, 'kernels.S')
    open(spath, 'w').write('\n'.join(src) + '\n')
    opath = os.path.join(outdir, 'kernels.o')
    subprocess.check_call([clang, '--target=aarch64-linux-gnu', '-c', spath, '-o', opath])
    text, syms = elf_text_and_symbols(opath)
    names = STUB_NAMES + [k[0] for k in kernels]
    order = sorted(names, key=lambda n: syms[n])
    assert order == names, 'functions out of order'
    ends = [syms[n] for n in names[1:]] + [len(text)]
    out = ['/* Generated by gen_kernels.py from kernels.S. Do not edit. */']
    for n, end in zip(names, ends):
        words = struct.unpack_from('<%dI' % ((end - syms[n]) // 4), text, syms[n])
        out.append('BLOB_BEGIN(%s)' % n)
        for k in range(0, len(words), 8):
            out.append('".long ' + ','.join('0x%08x' % x for x in words[k:k + 8]) + '\\n"')
        out.append('BLOB_END(%s, %d)' % (n, len(words) * 4))
    out.append('')
    out.append('#define SVE_KERNEL_LIST \\')
    out.append(' \\\n'.join('  K(%s, %d, %d)' % (n, W, 1 if xar else 0) for n, W, xar in kernels))
    out.append('')
    out.append('/* key schedule steps for the C kernels: X(step, S index, L index, previous L index) */')
    out.append('#define KS_STEPS(X) \\')
    out.append(' \\\n'.join('  ' + ' '.join('X(%d, %d, %d, %d)' % (k, k % 26, k % 3, (k + 2) % 3)
                                              for k in range(r, min(r + 6, 78)))
                               for r in range(0, 78, 6)))
    open(os.path.join(outdir, 'kernels.inc'), 'w').write('\n'.join(out) + '\n')
    os.remove(opath)
    sys.stderr.write('%d functions, %d bytes of code\n' % (len(names), len(text)))


if __name__ == '__main__':
    main()
