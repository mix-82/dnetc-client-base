#!/usr/bin/env python3
# make_single.py: writes sme_rc5_bench.c, the single-file program, from
# sme_rc5_bench.in.c with gen/kernels.inc pasted in.
import sys
src = open('sme_rc5_bench.in.c').read()
inc = open('gen/kernels.inc').read()
marker = '#include "kernels.inc"\n'
assert src.count(marker) == 1
open('sme_rc5_bench.c', 'w').write(src.replace(marker, inc))
