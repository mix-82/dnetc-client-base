/* Key-by-key reference harness for the MIX NEON16/NEON32 cores
 * (rc5-72/arm64/r72-neon-mix16.S, r72-neon-mix32.S).
 * Compares result, *iterations, check.count/hi/mid/lo, and L0 (on
 * RESULT_NOTHING) with a scalar reference that has the client's semantics:
 * no match, full match and low-word-only match at every position in three
 * batches, and the L0hi->mid, mid->lo and full-wrap carries.
 *
 * -DCORE=<function> -DBATCH=<keys per call> select the core (default
 * MIX NEON16, 16). With -DTESTMASK, link the core built with --testmask:
 * both cipher words are compared under r72_testmask, so partial and
 * multiple matches per batch are common.
 * Usage: harness [rounds]. run-tests.sh builds and runs everything.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef uint32_t u32;
typedef struct {
  struct { u32 hi, lo; } plain;
  struct { u32 hi, lo; } cypher;
  struct { u32 hi, mid, lo; } L0;
  struct { u32 count, hi, mid, lo; } check;
} __attribute__((packed)) RC5_72UnitWork;

#ifndef CORE
#define CORE rc5_72_unit_func_neon_mix16
#endif
#ifndef BATCH
#define BATCH 16
#endif
extern int CORE(RC5_72UnitWork *, u32 *, void *);
u32 r72_testmask = 0xFFFFFFFFu;

#define RESULT_NOTHING 1
#define RESULT_FOUND 2
#define P 0xB7E15163u
#define Q 0x9E3779B9u

static u32 rotl(u32 x, u32 s) { s &= 31; return s ? (x << s) | (x >> (32 - s)) : x; }
static u32 bswap(u32 x) { return __builtin_bswap32(x); }

static void rc5_encrypt(u32 lo, u32 mid, u32 hi, u32 plo, u32 phi, u32 *out_lo, u32 *out_hi)
{
  u32 S[26], L[3] = { lo, mid, hi }, A = 0, B = 0;
  for (int i = 0; i < 26; i++) S[i] = P + (u32)i * Q;
  for (int k = 0, i = 0, j = 0; k < 78; k++) {
    A = S[i] = rotl(S[i] + A + B, 3);
    B = L[j] = rotl(L[j] + A + B, A + B);
    if (++i == 26) i = 0;
    if (++j == 3) j = 0;
  }
  A = plo + S[0]; B = phi + S[1];
  for (int r = 1; r <= 12; r++) {
    A = rotl(A ^ B, B) + S[2 * r];
    B = rotl(B ^ A, A) + S[2 * r + 1];
  }
  *out_lo = A; *out_hi = B;
}

static void key_inc(RC5_72UnitWork *w)
{
  w->L0.hi = (w->L0.hi + 1) & 0xFF;
  if (w->L0.hi) return;
  u32 m = bswap(w->L0.mid) + 1;
  w->L0.mid = bswap(m);
  if (m) return;
  w->L0.lo = bswap(bswap(w->L0.lo) + 1);
}

static int reference(RC5_72UnitWork *w, u32 *iters)
{
  u32 n = *iters, mask = r72_testmask;
  for (u32 k = 0; k < n; k++) {
    u32 lo, hi;
    rc5_encrypt(w->L0.lo, w->L0.mid, w->L0.hi, w->plain.lo, w->plain.hi, &lo, &hi);
    if ((lo & mask) == w->cypher.lo) {
      w->check.count++;
      w->check.hi = w->L0.hi; w->check.mid = w->L0.mid; w->check.lo = w->L0.lo;
      if ((hi & mask) == w->cypher.hi) { *iters = k; return RESULT_FOUND; }
    }
    key_inc(w);
  }
  return RESULT_NOTHING;
}

static u32 rng_state = 12345;
static u32 rnd(void) { rng_state ^= rng_state << 13; rng_state ^= rng_state >> 17; rng_state ^= rng_state << 5; return rng_state; }

static long cases, failures, found_cases, partial_total;

static void run_case(const RC5_72UnitWork *init, u32 iters, const char *what)
{
  RC5_72UnitWork wr = *init, wc = *init;
  u32 ir = iters, ic = iters;
  int rr = reference(&wr, &ir);
  int rc = CORE(&wc, &ic, NULL);
  cases++;
  if (rr == RESULT_FOUND) found_cases++;
  partial_total += wr.check.count - init->check.count;
  int bad = rr != rc || ir != ic ||
            wr.check.count != wc.check.count || wr.check.hi != wc.check.hi ||
            wr.check.mid != wc.check.mid || wr.check.lo != wc.check.lo;
  if (rr == RESULT_NOTHING)
    bad |= wr.L0.hi != wc.L0.hi || wr.L0.mid != wc.L0.mid || wr.L0.lo != wc.L0.lo;
  if (bad && failures++ < 10)
    printf("FAIL %s: L0=%02x:%08x:%08x it=%u | ref res=%d it=%u cnt=%u chk=%02x:%08x:%08x L0=%02x:%08x:%08x"
           " | core res=%d it=%u cnt=%u chk=%02x:%08x:%08x L0=%02x:%08x:%08x\n",
           what, init->L0.hi, init->L0.mid, init->L0.lo, iters,
           rr, ir, wr.check.count, wr.check.hi, wr.check.mid, wr.check.lo, wr.L0.hi, wr.L0.mid, wr.L0.lo,
           rc, ic, wc.check.count, wc.check.hi, wc.check.mid, wc.check.lo, wc.L0.hi, wc.L0.mid, wc.L0.lo);
}

static void random_work(RC5_72UnitWork *w)
{
  memset(w, 0, sizeof *w);
  w->plain.hi = rnd(); w->plain.lo = rnd();
  w->cypher.hi = rnd() & r72_testmask; w->cypher.lo = rnd() & r72_testmask;
  w->L0.hi = rnd() & (0x100 - BATCH); w->L0.mid = rnd(); w->L0.lo = rnd();
  w->check.count = rnd() & 0xFF; w->check.hi = rnd(); w->check.mid = rnd(); w->check.lo = rnd();
}

/* key 'ofs' keys after w->L0 */
static void key_at(const RC5_72UnitWork *w, u32 ofs, u32 *lo, u32 *mid, u32 *hi)
{
  RC5_72UnitWork t = *w;
  while (ofs--) key_inc(&t);
  *lo = t.L0.lo; *mid = t.L0.mid; *hi = t.L0.hi;
}

/* starting keys that exercise the carries */
static void starts(RC5_72UnitWork *w, int kind)
{
  switch (kind) {
  case 0: break;                                             /* random */
  case 1: w->L0.hi = 0x100 - BATCH; break;                            /* hi -> mid carry in batch 2 */
  case 2: w->L0.hi = 0x100 - 2 * BATCH; w->L0.mid = bswap(0xFFFFFFFFu); break;  /* mid -> lo carry */
  case 3: w->L0.hi = 0x100 - BATCH; w->L0.mid = bswap(0xFFFFFFFFu); w->L0.lo = bswap(0xFFFFFFFFu); break; /* full wrap */
  case 4: w->L0.hi = 0x100 - 3 * BATCH; w->L0.mid = bswap(0x00FFFFFFu); break; /* multi-byte mid carry */
  }
}

int main(int argc, char **argv)
{
  long rounds = argc > 1 ? atol(argv[1]) : 200;
#ifdef TESTMASK
  u32 masks[] = { 0x0000000Fu, 0x00000003u, 0x00000001u, 0x0000003Fu };
  for (unsigned mi = 0; mi < sizeof masks / sizeof *masks; mi++) {
    r72_testmask = masks[mi];
    for (long r = 0; r < rounds; r++) {
      RC5_72UnitWork w; random_work(&w); starts(&w, (int)(r % 5));
      run_case(&w, BATCH * (1 + rnd() % 24), "masked");
    }
  }
#else
  /* 1. no match, random keys and carries, 1..40 batches */
  for (long r = 0; r < rounds; r++) {
    RC5_72UnitWork w; random_work(&w); starts(&w, (int)(r % 5));
    run_case(&w, BATCH * (1 + rnd() % 40), "nomatch");
  }
  /* 2. full match and low-word-only match at every position in 3 batches */
  for (int kind = 0; kind < 5; kind++)
    for (u32 pos = 0; pos < 3 * BATCH; pos++)
      for (int full = 0; full < 2; full++) {
        RC5_72UnitWork w; random_work(&w); starts(&w, kind);
        u32 lo, mid, hi, clo, chi;
        key_at(&w, pos, &lo, &mid, &hi);
        rc5_encrypt(lo, mid, hi, w.plain.lo, w.plain.hi, &clo, &chi);
        w.cypher.lo = clo; w.cypher.hi = full ? chi : ~chi;
        run_case(&w, 3 * BATCH, full ? "full" : "partial");
        run_case(&w, BATCH * (1 + pos / BATCH), full ? "full-exact" : "partial-exact");
      }
#endif
  printf("%ld cases, %ld failures (found %ld, partial matches %ld)\n", cases, failures, found_cases, partial_total);
  return failures != 0;
}
