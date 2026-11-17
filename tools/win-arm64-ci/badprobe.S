// Control for stackprobe.c: moves sp down two pages and writes there
// without touching the page in between (what Windows forbids).
        .text
        .p2align 2
        .globl  bad_probe
bad_probe:
        sub     sp, sp, #2, lsl #12
        str     x0, [sp]
        add     sp, sp, #2, lsl #12
        mov     w0, #1
        ret
