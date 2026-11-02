/* RC5-72 NEON 8x4 x3 core for arm64 - Nov 2026
 *
 * 32 keys per block as 8 groups of uint32x4_t (4 keys per group), like
 * NEON 8x4, but built so its speed does not depend on the compiler or the
 * optimisation level:
 * - the key schedule runs as rolled iterations of three written-out steps,
 *   so the L index is a constant and only S goes through memory; with all
 *   78 steps unrolled, some compilers reorder the groups apart (NEON 8x4:
 *   8 Mkeys/s on an Apple M1 at clang -O3, against 28 at -Os)
 * - S is laid out row by row (all groups' S[i] together)
 * - steps 0 and 1 depend only on L0.lo and L0.mid, so they are computed
 *   once per block in scalar code (as in the AVX2 and AVX-512 cores)
 * - the first pass through S reads P + i*Q from a shared constant table
 *   instead of initialising every group's S each block
 * - the result check compares all groups with cmeq and one umaxv; single
 *   lanes are only examined when one of them matches cypher.lo
 * - the constant rotate is shl + usra
 * 32 keys/block and 32 divides 256, so the hi byte never crosses a block
 * boundary within a group assuming the start is aligned -- the ANSI key
 * counter applies as-is.
 */
#include "ccoreio.h"
#include <arm_neon.h>

#if defined(__clang__)
#define UNROLL_FULL _Pragma("clang loop unroll(full)")
#define NO_UNROLL _Pragma("nounroll")
#else
#define UNROLL_FULL _Pragma("GCC unroll 128")
#define NO_UNROLL _Pragma("GCC unroll 1")
#endif

#define P 0xB7E15163u
#define Q 0x9E3779B9u
#define NG 8                 // vector groups (4 keys each)
#define NP (4 * NG)          // 32 keys per block

// rom[i][g] = P + i*Q in every lane of every group
#define RV(i) {P + (i) * Q, P + (i) * Q, P + (i) * Q, P + (i) * Q}
#define RG(i) {RV(i), RV(i), RV(i), RV(i), RV(i), RV(i), RV(i), RV(i)}
static const u32 rom[26][NG][4] __attribute__((aligned(16))) =
{
  RG(0), RG(1), RG(2), RG(3), RG(4), RG(5), RG(6), RG(7), RG(8), RG(9),
  RG(10), RG(11), RG(12), RG(13), RG(14), RG(15), RG(16), RG(17), RG(18),
  RG(19), RG(20), RG(21), RG(22), RG(23), RG(24), RG(25)
};

static inline u32 rotl32(u32 x, u32 s)
{
  s &= 31;
  if (s == 0)
  {
    return x;
  }
  return (x << s) | (x >> (32 - s));
}

static inline uint32x4_t VROTL(uint32x4_t x, uint32x4_t s)
{
  int32x4_t m = vreinterpretq_s32_u32(vandq_u32(s, vdupq_n_u32(31)));
  return vorrq_u32(vshlq_u32(x, m), vshlq_u32(x, vsubq_s32(m, vdupq_n_s32(32))));
}

static inline uint32x4_t VROTL3(uint32x4_t x)
{
  return vsraq_n_u32(vshlq_n_u32(x, 3), x, 29);
}

// one key-schedule step for all groups: read S[i] from rd, write it to sm
static inline void step(u32 *sm, const u32 *rd, uint32x4_t (*L)[3], uint32x4_t *A, uint32x4_t *B, int i, int jj)
{
  UNROLL_FULL
  for (int g = 0; g < NG; g++)
  {
    uint32x4_t ab = vaddq_u32(A[g], B[g]);
    A[g] = VROTL3(vaddq_u32(vld1q_u32(rd + (i * NG + g) * 4), ab));
    vst1q_u32(sm + (i * NG + g) * 4, A[g]);
    uint32x4_t ab2 = vaddq_u32(A[g], B[g]);
    B[g] = L[g][jj] = VROTL(vaddq_u32(L[g][jj], ab2), ab2);
  }
}

extern "C" s32 rc5_72_unit_func_neon_8x4x3(RC5_72UnitWork *w, u32 *iterations, void *)
{
  u32 Sm[26][NG][4] __attribute__((aligned(16)));
  uint32x4_t L[NG][3];
  uint32x4_t A[NG];
  uint32x4_t B[NG];
  uint32x4_t av[NG];
  uint32x4_t bv[NG];
  const uint32x4_t lane = {0, 1, 2, 3};
  u32 kiter = *iterations / NP;
  u32 *sm = &Sm[0][0][0];

  while (kiter--)
  {
    // steps 0 and 1 in scalar code: the same for every lane and group
    u32 s0 = rotl32(P, 3);
    u32 l0 = rotl32(w->L0.lo + s0, s0);
    u32 s1 = rotl32(P + Q + s0 + l0, 3);
    u32 l1 = rotl32(w->L0.mid + s1 + l0, s1 + l0);
    UNROLL_FULL
    for (int g = 0; g < NG; g++)
    {
      L[g][2] = vaddq_u32(vdupq_n_u32(w->L0.hi), vaddq_u32(lane, vdupq_n_u32((u32)(4 * g))));
      L[g][1] = vdupq_n_u32(l1);
      L[g][0] = vdupq_n_u32(l0);
      A[g] = vdupq_n_u32(s1);
      B[g] = vdupq_n_u32(l1);
      vst1q_u32(sm + (0 * NG + g) * 4, vdupq_n_u32(s0));
      vst1q_u32(sm + (1 * NG + g) * 4, vdupq_n_u32(s1));
    }

    // steps 2..77: step 2 (j = 2), then 25 iterations of j = 0, 1, 2;
    // S[i] comes from the constant table until i first wraps to 0
    const u32 *rd = &rom[0][0][0];
    int i = 2;
    step(sm, rd, L, A, B, i, 2);
    i++;
    NO_UNROLL
    for (int t = 0; t < 25; t++)
    {
      step(sm, rd, L, A, B, i, 0);
      if (++i == 26)
      {
        i = 0;
        rd = sm;
      }
      step(sm, rd, L, A, B, i, 1);
      if (++i == 26)
      {
        i = 0;
        rd = sm;
      }
      step(sm, rd, L, A, B, i, 2);
      if (++i == 26)
      {
        i = 0;
        rd = sm;
      }
    }

    // encryption
    UNROLL_FULL
    for (int g = 0; g < NG; g++)
    {
      uint32x4_t a = vaddq_u32(vdupq_n_u32(w->plain.lo), vld1q_u32(sm + (0 * NG + g) * 4));
      uint32x4_t b = vaddq_u32(vdupq_n_u32(w->plain.hi), vld1q_u32(sm + (1 * NG + g) * 4));
      UNROLL_FULL
      for (int r = 1; r <= 12; r++)
      {
        a = vaddq_u32(VROTL(veorq_u32(a, b), b), vld1q_u32(sm + ((2 * r) * NG + g) * 4));
        b = vaddq_u32(VROTL(veorq_u32(b, a), a), vld1q_u32(sm + ((2 * r + 1) * NG + g) * 4));
      }
      av[g] = a;
      bv[g] = b;
    }

    // check: all groups at once, single lanes only on a cypher.lo match
    uint32x4_t clo = vdupq_n_u32(w->cypher.lo);
    uint32x4_t hit = vceqq_u32(av[0], clo);
    UNROLL_FULL
    for (int g = 1; g < NG; g++)
    {
      hit = vorrq_u32(hit, vceqq_u32(av[g], clo));
    }
    if (vmaxvq_u32(hit) != 0)
    {
      for (int g = 0; g < NG; g++)
      {
        u32 al[4];
        u32 bl[4];
        vst1q_u32(al, av[g]);
        vst1q_u32(bl, bv[g]);
        for (int p = 0; p < 4; p++)
        {
          if (al[p] == w->cypher.lo)
          {
            ++w->check.count;
            w->check.hi = w->L0.hi + (u32)(4 * g + p);
            w->check.mid = w->L0.mid;
            w->check.lo = w->L0.lo;
            if (bl[p] == w->cypher.hi)
            {
              *iterations -= (kiter + 1) * NP - (u32)(4 * g + p);
              return RESULT_FOUND;
            }
          }
        }
      }
    }

    // key += NP (byte hi, full ANSI carry into mid/lo)
    w->L0.hi = (w->L0.hi + NP) & 0xFF;
    if (!w->L0.hi)
    {
      w->L0.mid = w->L0.mid + 0x01000000;
      if (!(w->L0.mid & 0xFF000000u))
      {
        w->L0.mid = (w->L0.mid + 0x00010000) & 0x00FFFFFF;
        if (!(w->L0.mid & 0x00FF0000))
        {
          w->L0.mid = (w->L0.mid + 0x00000100) & 0x0000FFFF;
          if (!(w->L0.mid & 0x0000FF00))
          {
            w->L0.mid = (w->L0.mid + 1) & 0xFF;
            if (!w->L0.mid)
            {
              w->L0.lo = w->L0.lo + 0x01000000;
              if (!(w->L0.lo & 0xFF000000u))
              {
                w->L0.lo = (w->L0.lo + 0x00010000) & 0x00FFFFFF;
                if (!(w->L0.lo & 0x00FF0000))
                {
                  w->L0.lo = (w->L0.lo + 0x00000100) & 0x0000FFFF;
                  if (!(w->L0.lo & 0x0000FF00))
                  {
                    w->L0.lo = (w->L0.lo + 0x00000001) & 0x000000FF;
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  return RESULT_NOTHING;
}
