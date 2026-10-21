/* r72bench: RC5-72 AVX-512 pipe-count benchmark.
   Cores: z = MIX ZMM (r72-avx512z.asm from the client, unchanged) and
   c1-c4 = gen.py cores with 1-4 pipes x 16 lanes, same algorithm.
   Usage:
     r72bench test
     r72bench sweep <seconds> <rounds> <cpus>    cpus: "0", "0,24", "0-3", "all" */

#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RESULT_NOTHING 1
#define RESULT_FOUND 2

typedef struct
{
  uint32_t plainhi;
  uint32_t plainlo;
  uint32_t cipherhi;
  uint32_t cipherlo;
  uint32_t L0hi;
  uint32_t L0mid;
  uint32_t L0lo;
  uint32_t count;
  uint32_t chi;
  uint32_t cmid;
  uint32_t clo;
} work_t;

typedef int32_t (*core_fn)(work_t *w, uint32_t *iterations, void *memblk);

extern int32_t rc5_72_unit_func_avx512z(work_t *w, uint32_t *iterations, void *memblk);
extern int32_t r72b_c1(work_t *w, uint32_t *iterations, void *memblk);
extern int32_t r72b_c2(work_t *w, uint32_t *iterations, void *memblk);
extern int32_t r72b_c3(work_t *w, uint32_t *iterations, void *memblk);
extern int32_t r72b_c4(work_t *w, uint32_t *iterations, void *memblk);

typedef struct
{
  const char *name;
  core_fn fn;
  uint32_t keys;
  int exact;
} core_t;

#define NCORES 5
static core_t cores[NCORES] =
{
  { "z", rc5_72_unit_func_avx512z, 32, 1 },
  { "c1", r72b_c1, 16, 1 },
  { "c2", r72b_c2, 32, 1 },
  { "c3", r72b_c3, 48, 0 },
  { "c4", r72b_c4, 64, 1 },
};

#define RC5_P 0xB7E15163u
#define RC5_Q 0x9E3779B9u
#define MAXCPUS 1024
#define MAXROUNDS 256

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;

static uint32_t rnd32(void)
{
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 7;
  rng_state ^= rng_state << 17;
  return (uint32_t)(rng_state >> 16);
}

static uint32_t rol32(uint32_t x, uint32_t s)
{
  s &= 31;
  if (s == 0)
  {
    return x;
  }
  return (x << s) | (x >> (32 - s));
}

static uint32_t bswap32(uint32_t x)
{
  return __builtin_bswap32(x);
}

// RC5-32/12/9 with L[0] = L0lo, L[1] = L0mid, L[2] = L0hi
static void rc5_72(uint32_t hi, uint32_t mid, uint32_t lo, uint32_t plo, uint32_t phi,
                   uint32_t *clo, uint32_t *chi)
{
  uint32_t S[26];
  uint32_t L[3];
  uint32_t A = 0;
  uint32_t B = 0;
  int i = 0;
  int j = 0;
  int k;
  int r;

  L[0] = lo;
  L[1] = mid;
  L[2] = hi;
  for (k = 0; k < 26; k++)
  {
    S[k] = RC5_P + (uint32_t)k * RC5_Q;
  }
  for (k = 0; k < 78; k++)
  {
    A = S[i] = rol32(S[i] + A + B, 3);
    B = L[j] = rol32(L[j] + A + B, A + B);
    i = (i + 1) % 26;
    j = (j + 1) % 3;
  }
  A = plo + S[0];
  B = phi + S[1];
  for (r = 1; r <= 12; r++)
  {
    A = rol32(A ^ B, B) + S[2 * r];
    B = rol32(B ^ A, A) + S[2 * r + 1];
  }
  *clo = A;
  *chi = B;
}

// Client key increment: L0hi is one byte; L0mid and L0lo count in byte-swapped order.
static void key_inc(uint32_t *hi, uint32_t *mid, uint32_t *lo)
{
  *hi = (*hi + 1) & 0xFF;
  if (*hi != 0)
  {
    return;
  }
  *mid = bswap32(bswap32(*mid) + 1);
  if (*mid != 0)
  {
    return;
  }
  *lo = bswap32(bswap32(*lo) + 1);
}

// Reference unit function, one key at a time.
static int32_t ref_unit(work_t *w, uint32_t *iterations)
{
  uint32_t n = *iterations;
  uint32_t k;

  for (k = 0; k < n; k++)
  {
    uint32_t clo;
    uint32_t chi;

    rc5_72(w->L0hi, w->L0mid, w->L0lo, w->plainlo, w->plainhi, &clo, &chi);
    if (clo == w->cipherlo)
    {
      w->count++;
      w->chi = w->L0hi;
      w->cmid = w->L0mid;
      w->clo = w->L0lo;
      if (chi == w->cipherhi)
      {
        *iterations = k;
        return RESULT_FOUND;
      }
    }
    key_inc(&w->L0hi, &w->L0mid, &w->L0lo);
  }
  return RESULT_NOTHING;
}

static void work_random(work_t *w, uint32_t keys)
{
  w->plainhi = rnd32();
  w->plainlo = rnd32();
  w->cipherhi = rnd32();
  w->cipherlo = rnd32();
  w->L0hi = (rnd32() & 0xFF) / keys * keys;
  w->L0mid = rnd32();
  w->L0lo = rnd32();
  w->count = 0;
  w->chi = rnd32();
  w->cmid = rnd32();
  w->clo = rnd32();
}

// Plant the key at position p (from the start of w) as a full or low-word-only match.
static void plant(work_t *w, uint32_t p, int full)
{
  uint32_t hi = w->L0hi;
  uint32_t mid = w->L0mid;
  uint32_t lo = w->L0lo;
  uint32_t clo;
  uint32_t chi;
  uint32_t k;

  for (k = 0; k < p; k++)
  {
    key_inc(&hi, &mid, &lo);
  }
  rc5_72(hi, mid, lo, w->plainlo, w->plainhi, &clo, &chi);
  w->cipherlo = clo;
  w->cipherhi = chi;
  if (!full)
  {
    w->cipherhi = chi ^ 1;
  }
}

// Run core c and the reference on the same work and compare everything the client uses.
static int check_case(const core_t *c, const work_t *start, uint32_t n)
{
  work_t a = *start;
  work_t b = *start;
  uint32_t ia = n;
  uint32_t ib = n;
  int32_t ra = c->fn(&a, &ia, 0);
  int32_t rb = ref_unit(&b, &ib);

  if (ra != rb || ia != ib)
  {
    return 0;
  }
  if (a.count != b.count || a.chi != b.chi || a.cmid != b.cmid || a.clo != b.clo)
  {
    return 0;
  }
  // problem.cpp ignores L0 on RESULT_FOUND
  if (ra == RESULT_NOTHING && (a.L0hi != b.L0hi || a.L0mid != b.L0mid || a.L0lo != b.L0lo))
  {
    return 0;
  }
  return 1;
}

static int test_core(const core_t *c)
{
  uint32_t K = c->keys;
  int cases = 0;
  int fails = 0;
  int rep;
  uint32_t t;
  work_t w;

  for (rep = 0; rep < 4; rep++)
  {
    for (t = 0; t < 3 * K; t++)
    {
      int full;

      if (!c->exact && t >= K)
      {
        break;
      }
      for (full = 0; full <= 1; full++)
      {
        uint32_t n = 3 * K;

        // random aligned start
        work_random(&w, K);
        if (!c->exact)
        {
          w.L0hi = (rnd32() % 5) * 48;
          n = K;
        }
        plant(&w, t, full);
        cases++;
        fails += !check_case(c, &w, n);
        if (!c->exact)
        {
          continue;
        }
        // L0hi carry into L0mid after the first batch
        work_random(&w, K);
        w.L0hi = 256 - K;
        plant(&w, t, full);
        cases++;
        fails += !check_case(c, &w, n);
        // L0mid carry into L0lo after the first batch
        work_random(&w, K);
        w.L0hi = 256 - K;
        w.L0mid = 0xFFFFFFFF;
        plant(&w, t, full);
        cases++;
        fails += !check_case(c, &w, n);
      }
    }
  }
  // long random runs: no false matches, L0 advance across many carries
  for (rep = 0; rep < 4; rep++)
  {
    work_random(&w, K);
    if (!c->exact)
    {
      w.L0hi = 0;
      cases++;
      fails += !check_case(c, &w, K);
      continue;
    }
    cases++;
    fails += !check_case(c, &w, 512 * K);
  }
  if (c->exact)
  {
    printf("test %-2s (%2u keys/batch): %d/%d passed\n", c->name, K, cases - fails, cases);
  }
  else
  {
    printf("test %-2s (%2u keys/batch, no-straddle cases only): %d/%d passed\n", c->name, K, cases - fails, cases);
  }
  return fails;
}

static int run_tests(void)
{
  int failed = 0;
  int n;

  for (n = 0; n < NCORES; n++)
  {
    failed += test_core(&cores[n]);
  }
  if (failed)
  {
    printf("TEST FAILED\n");
    return 1;
  }
  printf("all tests passed\n");
  return 0;
}

static double now(void)
{
  struct timespec ts;

  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

typedef struct
{
  int cpu;
  const core_t *core;
  double secs;
  double rate;
  pthread_barrier_t *bar;
} targ;

static void *bench_thread(void *p)
{
  targ *a = (targ *)p;
  cpu_set_t set;
  work_t w;
  uint32_t per_call = 65536 / a->core->keys * a->core->keys;
  uint64_t keys = 0;
  double t0;
  double t1;

  CPU_ZERO(&set);
  CPU_SET(a->cpu, &set);
  pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
  work_random(&w, a->core->keys);

  // warm up (vector unit power-up, clocks), then start together
  t0 = now();
  while (now() - t0 < 0.3)
  {
    uint32_t it = per_call;

    a->core->fn(&w, &it, 0);
  }
  pthread_barrier_wait(a->bar);

  t0 = now();
  t1 = t0;
  while (t1 - t0 < a->secs)
  {
    uint32_t it = per_call;

    a->core->fn(&w, &it, 0);
    keys += per_call;
    t1 = now();
  }
  a->rate = (double)keys / (t1 - t0);
  return 0;
}

static double run_once(const core_t *c, int *cpus, int ncpu, double secs)
{
  static pthread_t th[MAXCPUS];
  static targ args[MAXCPUS];
  pthread_barrier_t bar;
  double total = 0;
  int n;

  pthread_barrier_init(&bar, 0, (unsigned)ncpu);
  for (n = 0; n < ncpu; n++)
  {
    args[n].cpu = cpus[n];
    args[n].core = c;
    args[n].secs = secs;
    args[n].rate = 0;
    args[n].bar = &bar;
    pthread_create(&th[n], 0, bench_thread, &args[n]);
  }
  for (n = 0; n < ncpu; n++)
  {
    pthread_join(th[n], 0);
    total += args[n].rate;
  }
  pthread_barrier_destroy(&bar);
  return total;
}

static int parse_cpus(const char *s, int *cpus)
{
  int n = 0;

  if (strcmp(s, "all") == 0)
  {
    cpu_set_t set;
    int c;

    sched_getaffinity(0, sizeof(set), &set);
    for (c = 0; c < CPU_SETSIZE && n < MAXCPUS; c++)
    {
      if (CPU_ISSET(c, &set))
      {
        cpus[n++] = c;
      }
    }
    return n;
  }
  while (*s && n < MAXCPUS)
  {
    char *end;
    long a = strtol(s, &end, 10);
    long b;

    if (end == s)
    {
      return -1;
    }
    b = a;
    s = end;
    if (*s == '-')
    {
      s++;
      b = strtol(s, &end, 10);
      if (end == s)
      {
        return -1;
      }
      s = end;
    }
    for (; a <= b && n < MAXCPUS; a++)
    {
      cpus[n++] = (int)a;
    }
    if (*s == ',')
    {
      s++;
    }
  }
  return n;
}

static int cmp_double(const void *a, const void *b)
{
  double x = *(const double *)a;
  double y = *(const double *)b;

  if (x < y)
  {
    return -1;
  }
  if (x > y)
  {
    return 1;
  }
  return 0;
}

static double median(const double *v, int n)
{
  double tmp[MAXROUNDS];
  int k;

  for (k = 0; k < n; k++)
  {
    tmp[k] = v[k];
  }
  qsort(tmp, (size_t)n, sizeof(double), cmp_double);
  if (n % 2)
  {
    return tmp[n / 2];
  }
  return 0.5 * (tmp[n / 2 - 1] + tmp[n / 2]);
}

static int run_sweep(double secs, int rounds, const char *cpuspec)
{
  static int cpus[MAXCPUS];
  static double rate[NCORES][MAXROUNDS];
  static double ratio[NCORES][MAXROUNDS];
  int ncpu = parse_cpus(cpuspec, cpus);
  int r;
  int n;

  if (ncpu <= 0 || rounds < 1 || rounds > MAXROUNDS)
  {
    fprintf(stderr, "bad cpu list or rounds\n");
    return 1;
  }
  printf("sweep: %d thread(s) on cpus %s, %.1f s x %d rounds, Mkeys/s total\n", ncpu, cpuspec, secs, rounds);
  for (r = 0; r < rounds; r++)
  {
    int k;

    printf("  round %d:", r + 1);
    // rotate the order each round so no core always runs first
    for (k = 0; k < NCORES; k++)
    {
      n = (k + r) % NCORES;
      rate[n][r] = run_once(&cores[n], cpus, ncpu, secs) / 1e6;
    }
    for (n = 0; n < NCORES; n++)
    {
      printf("  %s %8.1f", cores[n].name, rate[n][r]);
      ratio[n][r] = rate[n][r] / rate[0][r];
    }
    printf("\n");
    fflush(stdout);
  }
  printf("  %-9s %10s %11s %9s %16s\n", "core", "median", "per thread", "vs z", "vs z min/max");
  for (n = 0; n < NCORES; n++)
  {
    double lo = ratio[n][0];
    double hi = ratio[n][0];
    double med = median(rate[n], rounds);

    for (r = 1; r < rounds; r++)
    {
      if (ratio[n][r] < lo)
      {
        lo = ratio[n][r];
      }
      if (ratio[n][r] > hi)
      {
        hi = ratio[n][r];
      }
    }
    printf("  %-2s (%2u)   %10.1f %11.1f %+8.1f%% %+7.1f%%/%+6.1f%%\n", cores[n].name, cores[n].keys, med,
           med / ncpu, (median(ratio[n], rounds) - 1) * 100, (lo - 1) * 100, (hi - 1) * 100);
  }
  return 0;
}

int main(int argc, char **argv)
{
  if (!__builtin_cpu_supports("avx512f") || !__builtin_cpu_supports("popcnt"))
  {
    fprintf(stderr, "this CPU (or OS) does not support AVX-512F and POPCNT\n");
    return 1;
  }
  if (argc == 2 && strcmp(argv[1], "test") == 0)
  {
    return run_tests();
  }
  if (argc == 5 && strcmp(argv[1], "sweep") == 0)
  {
    return run_sweep(atof(argv[2]), atoi(argv[3]), argv[4]);
  }
  fprintf(stderr, "usage: r72bench test\n       r72bench sweep <seconds> <rounds> <cpus|all>\n");
  return 1;
}
