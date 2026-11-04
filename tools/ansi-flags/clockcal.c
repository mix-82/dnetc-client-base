/* Estimate the running clock of one AArch64 core: time a long chain of
 * dependent scalar adds (1 cycle latency on every current AArch64 core).
 * Prints the median and maximum of several runs in GHz.
 * Used by tools/ansi-flags/run.sh to turn keys/sec into cycles/key.
 * Build: cc -O2 clockcal.c -o clockcal
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#if !defined(__aarch64__)
#error "clockcal.c: AArch64 only"
#endif

#define ADDS_PER_ITER 100

static double now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

#define A1 "add %x0, %x0, #1\n\t"
#define A10 A1 A1 A1 A1 A1 A1 A1 A1 A1 A1
#define A100 A10 A10 A10 A10 A10 A10 A10 A10 A10 A10

static double run(uint64_t iters)
{
  uint64_t x = 0, n = iters;
  double t0 = now();
  __asm__ volatile(
      "1:\n\t" A100
      "subs %x1, %x1, #1\n\t"
      "b.ne 1b\n\t"
      : "+r"(x), "+r"(n) : : "cc");
  double t1 = now();
  if (x != iters * ADDS_PER_ITER) { fprintf(stderr, "clockcal: bad sum\n"); exit(1); }
  return iters * (double)ADDS_PER_ITER / (t1 - t0) / 1e9;
}

static int cmp(const void *a, const void *b)
{
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
  int runs = argc > 1 ? atoi(argv[1]) : 7;
  double ghz[64];
  if (runs < 1 || runs > 64) runs = 7;
  run(2000000);                               /* warm up: let the clock ramp */
  for (int i = 0; i < runs; i++) ghz[i] = run(20000000);   /* 2e9 adds, ~0.6 s */
  qsort(ghz, runs, sizeof ghz[0], cmp);
  printf("%.3f %.3f\n", ghz[runs / 2], ghz[runs - 1]);    /* median max */
  return 0;
}
