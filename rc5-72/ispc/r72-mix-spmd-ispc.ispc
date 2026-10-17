// MIX SPMD: RC5-72 ISPC core, 32 keys per call.
// Derived from Sunset Ash's KS-SPMD core (r72-ks-spmd-ispc.ispc). Changes:
//  - 32 keys per call; built with --target=avx512skx-x32 every variable spans
//    two zmm registers, giving two independent dependency chains
//  - key schedule steps 0 and 1 (identical for all keys) computed once (uniform)
//  - (A + S) + B ordering, loops fully unrolled
#ifndef ISPC_UINT_IS_DEFINED
typedef unsigned int32 uint32;
#endif
#define P 0xB7E15163
#define Q 0x9E3779B9
#define ROTL(x, s) (((x) << ((s) & 31)) | ((x) >> ((32 - ((s) & 31)) & 31)))
#define ROTL3(x)   (((x) << 3) | ((x) >> 29))

export void rc5_32pipe(uniform uint32 hi, uniform uint32 mid, uniform uint32 lo,
                       uniform uint32 plainhi, uniform uint32 plainlo,
                       uniform uint32 outA[], uniform uint32 outB[])
{
  /* steps 0 and 1 are the same for every key: compute them once */
  uniform uint32 uS0 = ROTL3(P);
  uniform uint32 uL0 = ROTL(lo + uS0, uS0);
  uniform uint32 uS1 = ROTL3((P + Q) + uS0 + uL0);
  uniform uint32 uL1 = ROTL(mid + uS1 + uL0, uS1 + uL0);

  foreach (i = 0 ... 32)
  {
    uint32 S[26];
    uint32 L0 = uL0, L1 = uL1, L2 = hi + i;
    uint32 A = uS1, B = uL1;
    S[0] = uS0; S[1] = uS1;
    #pragma unroll
    for (uniform int k = 2; k < 26; k++) S[k] = P + k * Q;

    /* step 2 */
    A = S[2] = ROTL3((S[2] + A) + B);
    {
      uint32 t = A + B;
      B = L2 = ROTL(L2 + t, t);
    }

    /* steps 3..77, (A + S) + B keeps the constant add off the critical path */
    #pragma unroll
    for (uniform int k = 3; k < 78; k++)
    {
      uniform int j = k % 3, s = k % 26;
      A = S[s] = ROTL3((S[s] + A) + B);
      uint32 t = A + B;
      if (j == 0)
      {
        B = L0 = ROTL(L0 + t, t);
      }
      else if (j == 1)
      {
        B = L1 = ROTL(L1 + t, t);
      }
      else
      {
        B = L2 = ROTL(L2 + t, t);
      }
    }

    uint32 a = plainlo + S[0], b = plainhi + S[1];
    #pragma unroll
    for (uniform int r = 1; r <= 12; r++)
    {
      a = ROTL(a ^ b, b) + S[2 * r];
      b = ROTL(b ^ a, a) + S[2 * r + 1];
    }
    outA[i] = a; outB[i] = b;
  }
}
