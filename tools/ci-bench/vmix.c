/* Driver for the vmix.S microbenchmark kernels (see gen_vmix.py).
 * Calibrates the core clock with a chain of dependent 1-cycle adds, then
 * times each kernel and prints cycles per unit (instruction or step).
 * Build: cc -O2 vmix.c vmix.S -o vmix      Run: ./vmix [repeats]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define K(name, unit, what) { #name, vmix_##name, unit, what }
#define DECL(name) void vmix_##name(uint64_t, void *);
DECL(add) DECL(shl) DECL(sri) DECL(ushl) DECL(stp)
DECL(mix_ind_cluster) DECL(mix_ind_inter)
DECL(step32_lockstep) DECL(step32_skew) DECL(step32_fine) DECL(step32_nostore)
DECL(step16_lockstep)

static struct { const char *name; void (*fn)(uint64_t, void *); int unit; const char *what; } kernels[] = {
  K(add, 32, "add v.4s, independent"),
  K(shl, 32, "shl v.4s #3, independent"),
  K(sri, 32, "sri v.4s #29, independent"),
  K(ushl, 32, "ushl v.4s, independent"),
  K(stp, 32, "stp q,q (32 B), independent"),
  K(mix_ind_cluster, 44, "4 shifts : 7 others, independent, shifts clustered"),
  K(mix_ind_inter, 44, "4 shifts : 7 others, independent, shifts spread"),
  K(step32_lockstep, 3, "MIX NEON32 key-schedule step (8 pipes), lockstep"),
  K(step32_skew, 3, "same, group 2 half a step behind, phases concatenated"),
  K(step32_fine, 3, "same, group 2 half a step behind, instructions alternated"),
  K(step32_nostore, 3, "lockstep without the S/L stores"),
  K(step16_lockstep, 3, "MIX NEON16 key-schedule step (4 pipes), lockstep"),
};

static double now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

#define A1 "add %x0, %x0, #1\n\t"
#define A10 A1 A1 A1 A1 A1 A1 A1 A1 A1 A1
#define A100 A10 A10 A10 A10 A10 A10 A10 A10 A10 A10
static double ghz(void)
{
  uint64_t x = 0, n = 20000000;
  double t0 = now();
  __asm__ volatile("1:\n\t" A100 "subs %x1, %x1, #1\n\tb.ne 1b\n\t" : "+r"(x), "+r"(n) : : "cc");
  return 20000000 * 100.0 / (now() - t0) / 1e9;
}

static double time_kernel(void (*fn)(uint64_t, void *), void *scratch, double target_s)
{
  uint64_t iters = 1000;
  double t;
  for (;;) {                                   /* grow until the run is long enough */
    double t0 = now();
    fn(iters, scratch);
    t = now() - t0;
    if (t >= target_s) break;
    iters *= 2;
  }
  return t / iters;                            /* seconds per iteration */
}

int main(int argc, char **argv)
{
  int repeats = argc > 1 ? atoi(argv[1]) : 5;
  static char scratch[16384] __attribute__((aligned(64)));
  memset(scratch, 1, sizeof scratch);
  double g0 = ghz(), g1 = ghz(), g2 = ghz();
  double g = g0 < g1 ? (g1 < g2 ? g1 : (g0 < g2 ? g2 : g0)) : (g0 < g2 ? g0 : (g1 < g2 ? g2 : g1));
  printf("clock: %.3f GHz (median of %.3f %.3f %.3f)\n\n", g, g0, g1, g2);
  printf("| kernel | cycles/unit (min of %d) | runs | what |\n|---|---|---|---|\n", repeats);
  for (unsigned i = 0; i < sizeof kernels / sizeof *kernels; i++) {
    double best = 1e9, runs[16];
    for (int r = 0; r < repeats && r < 16; r++) {
      double s = time_kernel(kernels[i].fn, scratch, 0.15);
      runs[r] = s * g * 1e9 / kernels[i].unit;
      if (runs[r] < best) best = runs[r];
    }
    printf("| %s | %.2f | ", kernels[i].name, best);
    for (int r = 0; r < repeats && r < 16; r++) printf("%s%.2f", r ? " " : "", runs[r]);
    printf(" | %s |\n", kernels[i].what);
  }
  return 0;
}
