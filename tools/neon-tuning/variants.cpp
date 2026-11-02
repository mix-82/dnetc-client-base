// variants.cpp: experimental RC5-72 NEON cores (top candidates of the pre-screen).
// One template, four switches:
//   NG    groups of 4 keys (4, 8 or 16)
//   X3    0 = 78-step key schedule fully unrolled (as in NEON 8x4)
//         1 = 26 rolled iterations of three written-out steps, so the L
//             index is a constant and only S goes through memory
//   BAR   empty asm after every step so no group runs ahead of the others
//   USRA  constant rotate written as shl + usra (two instructions)
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

static inline uint32x4_t VROTL(uint32x4_t x, uint32x4_t s)
{
  int32x4_t m = vreinterpretq_s32_u32(vandq_u32(s, vdupq_n_u32(31)));
  return vorrq_u32(vshlq_u32(x, m), vshlq_u32(x, vsubq_s32(m, vdupq_n_s32(32))));
}

template <int USRA>
static inline uint32x4_t VROTL3(uint32x4_t x)
{
  if (USRA)
  {
    return vsraq_n_u32(vshlq_n_u32(x, 3), x, 29);
  }
  return vorrq_u32(vshlq_n_u32(x, 3), vshrq_n_u32(x, 29));
}

template <int NG, int BAR>
static inline void lockstep(uint32x4_t *A, uint32x4_t *B)
{
  if (BAR)
  {
    UNROLL_FULL
    for (int g = 0; g < NG; g++)
    {
      __asm__ volatile("" : "+w"(A[g]), "+w"(B[g]));
    }
  }
}

// one key-schedule step for all groups, L index jj fixed
template <int NG, int USRA>
static inline void step(uint32x4_t (*S)[26], uint32x4_t (*L)[3], uint32x4_t *A, uint32x4_t *B, int i, int jj)
{
  UNROLL_FULL
  for (int g = 0; g < NG; g++)
  {
    uint32x4_t ab = vaddq_u32(A[g], B[g]);
    A[g] = S[g][i] = VROTL3<USRA>(vaddq_u32(S[g][i], ab));
    uint32x4_t ab2 = vaddq_u32(A[g], B[g]);
    B[g] = L[g][jj] = VROTL(vaddq_u32(L[g][jj], ab2), ab2);
  }
}

template <int NG, int X3, int BAR, int USRA>
static s32 core(RC5_72UnitWork *w, u32 *iterations)
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

    if (X3)
    {
      int i = 0;
      NO_UNROLL
      for (int t = 0; t < 26; t++)
      {
        step<NG, USRA>(S, L, A, B, i, 0);
        lockstep<NG, BAR>(A, B);
        if (++i == 26)
        {
          i = 0;
        }
        step<NG, USRA>(S, L, A, B, i, 1);
        lockstep<NG, BAR>(A, B);
        if (++i == 26)
        {
          i = 0;
        }
        step<NG, USRA>(S, L, A, B, i, 2);
        lockstep<NG, BAR>(A, B);
        if (++i == 26)
        {
          i = 0;
        }
      }
    }
    else
    {
      int i = 0;
      int j = 0;
      UNROLL_FULL
      for (int k = 0; k < 78; k++)
      {
        step<NG, USRA>(S, L, A, B, i, j);
        lockstep<NG, BAR>(A, B);
        if (++i == 26)
        {
          i = 0;
        }
        if (++j == 3)
        {
          j = 0;
        }
      }
    }

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

    // key += NP; the harness never crosses a hi-byte wrap
    w->L0.hi = (w->L0.hi + NP) & 0xFF;
  }
  return RESULT_NOTHING;
}

#define V(ng, x3, bar, usra) \
  extern "C" s32 v_##ng##_##x3##bar##usra(RC5_72UnitWork *w, u32 *it, void *) \
  { \
    return core<ng, x3, bar, usra>(w, it); \
  }

// top candidates from the llvm-mca pre-screen, plus 4x4 full (the
// arm64-neon-cores NEON 4x4, fastest measured with gcc on Neoverse N2)
V(8, 1, 0, 1)
V(8, 1, 1, 1)
V(8, 1, 0, 0)
V(8, 0, 1, 0)
V(16, 1, 0, 1)
V(4, 0, 1, 0)
V(4, 0, 0, 0)
