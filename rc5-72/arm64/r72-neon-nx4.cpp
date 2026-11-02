/* RC5-72 NEON cores for arm64 with 1, 2 and 4 vector groups - Nov 2026
 *
 * The same algorithm as the NEON 8x4 core, built as a template on the number
 * of vector groups (NG, 4 keys per uint32x4_t group). Fewer groups keep more
 * of the working state in the 32 vector registers; more groups give the CPU
 * more independent work. Which is fastest depends on the CPU and the compiler,
 * so each count is its own core and the client's benchmark picks.
 *
 * NP = 4 * NG keys per block divides 256, so the hi byte never crosses a
 * block boundary within a group assuming the start is aligned -- the ANSI
 * key counter applies as-is.
 */
#include "ccoreio.h"
#include <arm_neon.h>

// Fully unroll the fixed-count loops; clang and gcc spell the pragma differently
#if defined(__clang__)
#define UNROLL_FULL _Pragma("clang loop unroll(full)")
#else
#define UNROLL_FULL _Pragma("GCC unroll 128")
#endif

#define P 0xB7E15163u
#define Q 0x9E3779B9u

static inline uint32x4_t VROTL(uint32x4_t x, uint32x4_t s)
{
  int32x4_t m = vreinterpretq_s32_u32(vandq_u32(s, vdupq_n_u32(31)));
  return vorrq_u32(vshlq_u32(x, m), vshlq_u32(x, vsubq_s32(m, vdupq_n_s32(32))));
}

static inline uint32x4_t VROTL3(uint32x4_t x)
{
  return vorrq_u32(vshlq_n_u32(x, 3), vshrq_n_u32(x, 29));
}

template <int NG>
static s32 rc5_72_neon_nx4(RC5_72UnitWork *w, u32 *iterations)
{
  const u32 NP = 4 * NG;
  uint32x4_t S[NG][26];
  uint32x4_t L[NG][3];
  uint32x4_t A[NG];
  uint32x4_t B[NG];
  const uint32x4_t lane = {0, 1, 2, 3};
  u32 kiter = *iterations / NP;

  while (kiter--)
  {
    UNROLL_FULL
    for (int g = 0; g < NG; g++)
    {
      L[g][2] = vaddq_u32(vdupq_n_u32(w->L0.hi), vaddq_u32(lane, vdupq_n_u32((u32)(4 * g))));
      L[g][1] = vdupq_n_u32(w->L0.mid);
      L[g][0] = vdupq_n_u32(w->L0.lo);
      UNROLL_FULL
      for (int i = 0; i < 26; i++)
      {
        S[g][i] = vdupq_n_u32(P + (u32)i * Q);
      }
      A[g] = vdupq_n_u32(0);
      B[g] = vdupq_n_u32(0);
    }

    // key schedule: 3 * 26 mixing steps
    int i = 0;
    int j = 0;
    UNROLL_FULL
    for (int k = 0; k < 78; k++)
    {
      UNROLL_FULL
      for (int g = 0; g < NG; g++)
      {
        uint32x4_t ab = vaddq_u32(A[g], B[g]);
        A[g] = S[g][i] = VROTL3(vaddq_u32(S[g][i], ab));
        uint32x4_t ab2 = vaddq_u32(A[g], B[g]);
        B[g] = L[g][j] = VROTL(vaddq_u32(L[g][j], ab2), ab2);
      }
      if (++i == 26)
      {
        i = 0;
      }
      if (++j == 3)
      {
        j = 0;
      }
    }

    // encryption and check
    UNROLL_FULL
    for (int g = 0; g < NG; g++)
    {
      uint32x4_t a = vaddq_u32(vdupq_n_u32(w->plain.lo), S[g][0]);
      uint32x4_t b = vaddq_u32(vdupq_n_u32(w->plain.hi), S[g][1]);
      UNROLL_FULL
      for (int r = 1; r <= 12; r++)
      {
        a = vaddq_u32(VROTL(veorq_u32(a, b), b), S[g][2 * r]);
        b = vaddq_u32(VROTL(veorq_u32(b, a), a), S[g][2 * r + 1]);
      }
      u32 al[4];
      u32 bl[4];
      vst1q_u32(al, a);
      vst1q_u32(bl, b);
      UNROLL_FULL
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

extern "C" s32 rc5_72_unit_func_neon_1x4(RC5_72UnitWork *w, u32 *iterations, void *)
{
  return rc5_72_neon_nx4<1>(w, iterations);
}

extern "C" s32 rc5_72_unit_func_neon_2x4(RC5_72UnitWork *w, u32 *iterations, void *)
{
  return rc5_72_neon_nx4<2>(w, iterations);
}

extern "C" s32 rc5_72_unit_func_neon_4x4(RC5_72UnitWork *w, u32 *iterations, void *)
{
  return rc5_72_neon_nx4<4>(w, iterations);
}
