// Control for stackprobe.c: bad_probe(pages, value) moves sp down
// `pages` pages and writes there without touching the pages in between
// (what Windows forbids beyond the guard region).
        .text
        .p2align 2
        .globl  bad_probe
bad_probe:
        mov     x9, sp
        sub     x10, x9, x0, lsl #12
        mov     sp, x10
        str     x1, [sp]
        mov     sp, x9
        mov     w0, #1
        ret
