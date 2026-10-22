// MIX SPMD, parameterised: RC5-72 ISPC kernel for the r72bench experiment.
// Same algorithm as rc5-72/ispc/r72-mix-spmd-ispc.ispc (steps 0-1 uniform,
// (A + S) + B ordering, fully unrolled), with two compile-time parameters:
//   MIX_PIPES   keys per call
//   MIX_CHAINS  independent chains written out explicitly in the source;
//               each chain covers MIX_PIPES / MIX_CHAINS keys, one gang
// The target width adds chains of its own: avx512skx-x32 makes every varying
// span two zmm registers, x64 four, avx2-i32x16 two ymm registers.
// MIX_EXPORT is the exported function name.
#ifndef ISPC_UINT_IS_DEFINED
typedef unsigned int32 uint32;
#endif
#ifndef MIX_PIPES
#define MIX_PIPES 32
#endif
#ifndef MIX_CHAINS
#define MIX_CHAINS 1
#endif
#ifndef MIX_EXPORT
#define MIX_EXPORT rc5_mix
#endif
#define GANG (MIX_PIPES / MIX_CHAINS)
#define P 0xB7E15163
#define Q 0x9E3779B9
#define ROTL(x, s) (((x) << ((s) & 31)) | ((x) >> (-(s) & 31)))
#define ROTL3(x)   (((x) << 3) | ((x) >> 29))

export void MIX_EXPORT(uniform uint32 hi, uniform uint32 mid, uniform uint32 lo,
                       uniform uint32 plainhi, uniform uint32 plainlo,
                       uniform uint32 outA[], uniform uint32 outB[])
{
  /* steps 0 and 1 are the same for every key: compute them once */
  uniform uint32 uS0 = ROTL3(P);
  uniform uint32 uL0 = ROTL(lo + uS0, uS0);
  uniform uint32 uS1 = ROTL3((P + Q) + uS0 + uL0);
  uniform uint32 uL1 = ROTL(mid + uS1 + uL0, uS1 + uL0);

  foreach (i = 0 ... GANG)
  {
    uint32 S[MIX_CHAINS][26];
    uint32 L0[MIX_CHAINS];
    uint32 L1[MIX_CHAINS];
    uint32 L2[MIX_CHAINS];
    uint32 A[MIX_CHAINS];
    uint32 B[MIX_CHAINS];

    #pragma unroll
    for (uniform int c = 0; c < MIX_CHAINS; c++)
    {
      L0[c] = uL0;
      L1[c] = uL1;
      L2[c] = hi + i + c * GANG;
      A[c] = uS1;
      B[c] = uL1;
      S[c][0] = uS0;
      S[c][1] = uS1;
      #pragma unroll
      for (uniform int k = 2; k < 26; k++)
      {
        S[c][k] = P + k * Q;
      }
    }

    /* step 2 */
    #pragma unroll
    for (uniform int c = 0; c < MIX_CHAINS; c++)
    {
      A[c] = S[c][2] = ROTL3((S[c][2] + A[c]) + B[c]);
      uint32 t = A[c] + B[c];
      B[c] = L2[c] = ROTL(L2[c] + t, t);
    }

    /* steps 3..77, (A + S) + B keeps the constant add off the critical path */
    #pragma unroll
    for (uniform int k = 3; k < 78; k++)
    {
      uniform int j = k % 3;
      uniform int s = k % 26;
      #pragma unroll
      for (uniform int c = 0; c < MIX_CHAINS; c++)
      {
        A[c] = S[c][s] = ROTL3((S[c][s] + A[c]) + B[c]);
        uint32 t = A[c] + B[c];
        if (j == 0)
        {
          B[c] = L0[c] = ROTL(L0[c] + t, t);
        }
        else if (j == 1)
        {
          B[c] = L1[c] = ROTL(L1[c] + t, t);
        }
        else
        {
          B[c] = L2[c] = ROTL(L2[c] + t, t);
        }
      }
    }

    uint32 a[MIX_CHAINS];
    uint32 b[MIX_CHAINS];
    #pragma unroll
    for (uniform int c = 0; c < MIX_CHAINS; c++)
    {
      a[c] = plainlo + S[c][0];
      b[c] = plainhi + S[c][1];
    }
    #pragma unroll
    for (uniform int r = 1; r <= 12; r++)
    {
      #pragma unroll
      for (uniform int c = 0; c < MIX_CHAINS; c++)
      {
        a[c] = ROTL(a[c] ^ b[c], b[c]) + S[c][2 * r];
        b[c] = ROTL(b[c] ^ a[c], a[c]) + S[c][2 * r + 1];
      }
    }
    #pragma unroll
    for (uniform int c = 0; c < MIX_CHAINS; c++)
    {
      outA[i + c * GANG] = a[c];
      outB[i + c * GANG] = b[c];
    }
  }
}
