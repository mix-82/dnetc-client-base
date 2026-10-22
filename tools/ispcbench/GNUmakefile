# ispcbench: MIX SPMD ISPC builds against the client's asm cores (Linux x86-64).
# Named GNUmakefile because the repository's .gitignore ignores "Makefile".
NASM ?= nasm
ISPC ?= ispc
CC ?= gcc
CFLAGS ?= -O2 -Wall
ISPCFLAGS ?= -O2 --pic --wno-perf
DNETC ?= ../..

# name:target:keys:chains
VARIANTS = s16:avx512skx-x16:16:1 s32:avx512skx-x32:32:1 s64:avx512skx-x64:64:1 \
           s32c:avx512skx-x16:32:2 s64c:avx512skx-x16:64:4 \
           a16:avx2-i32x16:16:1 a32:avx2-i32x16:32:2 a32c:avx2-i32x8:32:4

NAMES = $(foreach v,$(VARIANTS),$(word 1,$(subst :, ,$(v))))
field = $(word $(2),$(subst :, ,$(filter $(1):%,$(VARIANTS))))

KOBJS = $(NAMES:%=k_%.o) k_m6.o
WOBJS = $(NAMES:%=w_%.o) w_m6.o
AOBJS = r72-avx512z.o r72-avx512z64.o r72-avx2.o

all: ispcbench

r72-%.o: $(DNETC)/rc5-72/amd64/r72-%.asm
	$(NASM) -f elf64 -o $@ $<

k_m6.o: $(DNETC)/rc5-72/ispc/r72-mix-spmd-ispc.ispc
	$(ISPC) $(ISPCFLAGS) --target=avx512skx-x32 $< -o $@

w_m6.o: wrap.c
	$(CC) $(CFLAGS) -c -DPIPES=32 -DKERNEL=rc5_32pipe -DFUNC=u_m6 -o $@ $<

k_%.o: mix.ispc
	$(ISPC) $(ISPCFLAGS) --target=$(call field,$*,2) -DMIX_PIPES=$(call field,$*,3) \
	  -DMIX_CHAINS=$(call field,$*,4) -DMIX_EXPORT=rc5_mix_$* $< -o $@

w_%.o: wrap.c
	$(CC) $(CFLAGS) -c -DPIPES=$(call field,$*,3) -DKERNEL=rc5_mix_$* -DFUNC=u_$* -o $@ $<

ispcbench: ispcbench.c $(AOBJS) $(KOBJS) $(WOBJS)
	$(CC) $(CFLAGS) -static -pthread -o $@ ispcbench.c $(AOBJS) $(KOBJS) $(WOBJS)

# AVX-512 builds must use AVX-512F only; AVX2 builds no AVX-512 at all
isacheck: $(KOBJS)
	python3 isacheck.py k_m6.o avx512f 32
	@for v in $(VARIANTS); do \
	  set -- $$(echo $$v | tr ':' ' '); \
	  case $$2 in avx512*) kind=avx512f ;; *) kind=avx2 ;; esac; \
	  python3 isacheck.py k_$$1.o $$kind $$3 || exit 1; \
	done

clean:
	rm -f ispcbench *.o

.PHONY: all isacheck clean
.SECONDARY:
