# r72bench: RC5-72 AVX-512 pipe-count benchmark (Linux x86-64).
# Named GNUmakefile because the repository's .gitignore ignores "Makefile".

NASM ?= nasm
CC ?= gcc
CFLAGS ?= -O2 -Wall
DNETC ?= ../..

CORES = r72-avx512z.o r72b_c1.o r72b_c2.o r72b_c3.o r72b_c4.o

all: r72bench

r72-avx512z.o: $(DNETC)/rc5-72/amd64/r72-avx512z.asm
	$(NASM) -f elf64 -o $@ $<

r72b_c%.asm: gen.py
	python3 gen.py $* > $@

r72b_c%.o: r72b_c%.asm
	$(NASM) -f elf64 -o $@ $<

r72bench: r72bench.c $(CORES)
	$(CC) $(CFLAGS) -static -pthread -o $@ r72bench.c $(CORES)

# c2 must be the same code as the client's MIX ZMM core
verify: r72-avx512z.o r72b_c2.o
	objcopy -O binary --only-section=.text r72-avx512z.o z.text
	objcopy -O binary --only-section=.text r72b_c2.o c2.text
	objcopy -O binary --only-section=.rodata r72-avx512z.o z.rodata
	objcopy -O binary --only-section=.rodata r72b_c2.o c2.rodata
	cmp z.text c2.text
	cmp z.rodata c2.rodata
	readelf -rW r72-avx512z.o | awk '/R_X86_64/ {print $$1, $$3, $$5, $$6, $$7}' > z.rel
	readelf -rW r72b_c2.o | awk '/R_X86_64/ {print $$1, $$3, $$5, $$6, $$7}' > c2.rel
	cmp z.rel c2.rel
	rm -f z.text c2.text z.rodata c2.rodata z.rel c2.rel
	@echo "c2 matches r72-avx512z.asm (.text, .rodata, relocations)"

test: r72bench
	./r72bench test

run: r72bench
	sh run.sh

dist: r72bench
	tar czf r72bench.tar.gz r72bench run.sh README.md

clean:
	rm -f r72bench $(CORES) r72b_c*.asm r72bench.tar.gz bench-report.txt

.PRECIOUS: r72b_c%.asm
.PHONY: all verify test run dist clean
