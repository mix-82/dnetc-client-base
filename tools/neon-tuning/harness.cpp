// harness.cpp: correctness check and benchmark for the NEON core candidates.
//   harness check              every candidate (and NEON 8x4) must find a
//                              planted key and report no false match
//   harness run <name>         two passes of one candidate, no match (tracing)
//   harness bench [seconds]    keyrate of every candidate, round-robin,
//                              three rounds (default 2 seconds per run)
#include "ccoreio.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef s32 (*corefn)(RC5_72UnitWork *, u32 *, void *);

extern "C" s32 v_8_101(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 v_8_111(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 v_8_100(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 v_8_010(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 v_16_101(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 v_4_010(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 v_4_000(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_1100(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_1110(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_1101(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_1111(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_0100(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_0110(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_0101(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 w_8_0111(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 rc5_72_unit_func_neon_8x4(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_x3(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_x3_pre(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_x3_rom(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_x3_vchk(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_x3_all(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_x3_all_bar(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_8_full_bar_all(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_4_x3_all(RC5_72UnitWork *, u32 *, void *);
extern "C" s32 t_16_x3_all(RC5_72UnitWork *, u32 *, void *);

struct entry
{
  const char *name;
  const char *desc;
  corefn fn;
  u32 np;
  int carry;      // 1 if the core carries the key into L0.mid and L0.lo
};

static const entry table[] =
{
  {"zebe_8x4", "NEON 8x4 as shipped", rc5_72_unit_func_neon_8x4, 32, 1},
  {"v_8_101", "8x4 x3 + usra", v_8_101, 32, 0},
  {"v_8_111", "8x4 x3 + barrier + usra", v_8_111, 32, 0},
  {"v_8_100", "8x4 x3", v_8_100, 32, 0},
  {"v_8_010", "8x4 full + barrier", v_8_010, 32, 0},
  {"v_16_101", "16x4 x3 + usra", v_16_101, 64, 0},
  {"v_4_010", "4x4 full + barrier", v_4_010, 16, 0},
  {"v_4_000", "4x4 full (arm64-neon-cores)", v_4_000, 16, 0},
  {"t_8_x3", "8x4 x3 + usra (new layout)", t_8_x3, 32, 1},
  {"t_8_x3_pre", "  + precompute steps 0-1", t_8_x3_pre, 32, 1},
  {"t_8_x3_rom", "  + ROM table for first S pass", t_8_x3_rom, 32, 1},
  {"t_8_x3_vchk", "  + vector result check", t_8_x3_vchk, 32, 1},
  {"t_8_x3_all", "8x4 x3 + all three", t_8_x3_all, 32, 1},
  {"t_8_x3_all_bar", "8x4 x3 + all three + barrier", t_8_x3_all_bar, 32, 1},
  {"t_8_full_bar_all", "8x4 full + barrier + all three", t_8_full_bar_all, 32, 1},
  {"t_4_x3_all", "4x4 x3 + all three", t_4_x3_all, 16, 1},
  {"t_16_x3_all", "16x4 x3 + all three", t_16_x3_all, 64, 1},
};

// reference RC5-32/12 with a 3-word key (lo, mid, hi), as the cores use it
static u32 rotl(u32 x, u32 s)
{
  s &= 31;
  if (s == 0)
  {
    return x;
  }
  return (x << s) | (x >> (32 - s));
}

static void encrypt(u32 lo, u32 mid, u32 hi, u32 plo, u32 phi, u32 *clo, u32 *chi)
{
  u32 S[26];
  u32 L[3];
  u32 A = 0;
  u32 B = 0;
  int i = 0;
  int j = 0;
  L[0] = lo;
  L[1] = mid;
  L[2] = hi;
  for (int n = 0; n < 26; n++)
  {
    S[n] = 0xB7E15163u + (u32)n * 0x9E3779B9u;
  }
  for (int k = 0; k < 78; k++)
  {
    A = S[i] = rotl(S[i] + A + B, 3);
    B = L[j] = rotl(L[j] + A + B, A + B);
    i = (i + 1) % 26;
    j = (j + 1) % 3;
  }
  A = plo + S[0];
  B = phi + S[1];
  for (int r = 1; r <= 12; r++)
  {
    A = rotl(A ^ B, B) + S[2 * r];
    B = rotl(B ^ A, A) + S[2 * r + 1];
  }
  *clo = A;
  *chi = B;
}

static void setup(RC5_72UnitWork *w)
{
  memset(w, 0, sizeof(*w));
  w->plain.hi = 0x12345678u;
  w->plain.lo = 0x9abcdef0u;
  w->L0.hi = 0;
  w->L0.mid = 0x11223344u;
  w->L0.lo = 0x55667788u;
}

static void nomatch(RC5_72UnitWork *w)
{
  setup(w);
  w->cypher.lo = 0xdeadbeefu;
  w->cypher.hi = 0x0badf00du;
}

static double now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int check(int n)
{
  int bad = 0;
  for (int e = 0; e < n; e++)
  {
    RC5_72UnitWork w;
    u32 it;
    u32 want = table[e].np + 5;     // planted key: second pass, lane 5
    u32 clo;
    u32 chi;
    s32 rc;
    setup(&w);
    encrypt(w.L0.lo, w.L0.mid, want, w.plain.lo, w.plain.hi, &clo, &chi);
    w.cypher.lo = clo;
    w.cypher.hi = chi;
    it = 2 * table[e].np;
    rc = table[e].fn(&w, &it, 0);
    if (rc != RESULT_FOUND || it != want)
    {
      printf("FAIL %s rc=%d it=%u want %u\n", table[e].name, (int)rc, (unsigned)it, (unsigned)want);
      bad++;
    }
    if (table[e].carry)
    {
      // start in the last block before the hi byte wraps; the planted key
      // is in the next block, after the carry into L0.mid
      setup(&w);
      w.L0.hi = 256 - table[e].np;
      encrypt(w.L0.lo, w.L0.mid + 0x01000000u, 5, w.plain.lo, w.plain.hi, &clo, &chi);
      w.cypher.lo = clo;
      w.cypher.hi = chi;
      it = 2 * table[e].np;
      rc = table[e].fn(&w, &it, 0);
      if (rc != RESULT_FOUND || it != table[e].np + 5)
      {
        printf("FAIL %s (carry) rc=%d it=%u want %u\n", table[e].name, (int)rc, (unsigned)it, (unsigned)(table[e].np + 5));
        bad++;
      }
    }
    nomatch(&w);
    it = 2 * table[e].np;
    rc = table[e].fn(&w, &it, 0);
    if (rc != RESULT_NOTHING || w.L0.hi != 2 * table[e].np)
    {
      printf("FAIL %s (no match) rc=%d hi=%u\n", table[e].name, (int)rc, (unsigned)w.L0.hi);
      bad++;
    }
    // partial match: cypher.lo right, cypher.hi wrong -> counter-measure
    // check records it, the search goes on and nothing is found
    u32 part = table[e].np + 2 * table[e].np / 3;
    setup(&w);
    encrypt(w.L0.lo, w.L0.mid, part, w.plain.lo, w.plain.hi, &clo, &chi);
    w.cypher.lo = clo;
    w.cypher.hi = chi ^ 1u;
    it = 2 * table[e].np;
    rc = table[e].fn(&w, &it, 0);
    if (rc != RESULT_NOTHING || w.check.count != 1 || w.check.hi != part ||
        w.check.mid != 0x11223344u || w.check.lo != 0x55667788u)
    {
      printf("FAIL %s (partial match) rc=%d count=%u hi=%u want %u\n", table[e].name, (int)rc,
             (unsigned)w.check.count, (unsigned)w.check.hi, (unsigned)part);
      bad++;
    }
  }
  printf("%d cores checked, %d failures\n", n, bad);
  return bad;
}

static void bench(int n, double secs)
{
  const int rounds = 3;
  double rate[sizeof(table) / sizeof(table[0])][3];
  for (int r = 0; r < rounds; r++)
  {
    for (int e = 0; e < n; e++)
    {
      RC5_72UnitWork w;
      double keys = 0.0;
      double t0;
      double t1;
      nomatch(&w);
      t0 = now();
      do
      {
        u32 it = 65536;
        table[e].fn(&w, &it, 0);
        keys += 65536.0;
        t1 = now();
      } while (t1 - t0 < secs);
      rate[e][r] = keys / (t1 - t0) / 1e6;
    }
  }
  printf("%-17s %-32s %10s %10s %10s %10s\n", "core", "description", "round 1", "round 2", "round 3", "median");
  for (int e = 0; e < n; e++)
  {
    double a = rate[e][0];
    double b = rate[e][1];
    double c = rate[e][2];
    double med = a;
    if ((a <= b && b <= c) || (c <= b && b <= a))
    {
      med = b;
    }
    else if ((b <= c && c <= a) || (a <= c && c <= b))
    {
      med = c;
    }
    printf("%-17s %-32s %10.2f %10.2f %10.2f %10.2f\n", table[e].name, table[e].desc, a, b, c, med);
  }
  printf("(Mkeys/s, single thread)\n");
}

int main(int argc, char **argv)
{
  int n = (int)(sizeof(table) / sizeof(table[0]));
  if (argc >= 2 && strcmp(argv[1], "check") == 0)
  {
    return check(n) != 0;
  }
  if (argc >= 2 && strcmp(argv[1], "bench") == 0)
  {
    double secs = 2.0;
    if (argc >= 3)
    {
      secs = atof(argv[2]);
    }
    if (check(n) != 0)
    {
      return 1;
    }
    bench(n, secs);
    return 0;
  }
  if (argc >= 3 && strcmp(argv[1], "run") == 0)
  {
    for (int e = 0; e < n; e++)
    {
      if (strcmp(table[e].name, argv[2]) == 0)
      {
        RC5_72UnitWork w;
        u32 it = 2 * table[e].np;
        nomatch(&w);
        if (table[e].fn(&w, &it, 0) != RESULT_NOTHING)
        {
          return 1;
        }
        return 0;
      }
    }
  }
  return 2;
}
