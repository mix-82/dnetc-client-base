/*
 * Copyright distributed.net 1997-2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * MIX SPMD: wrapper for the 32-key ISPC core in r72-mix-spmd-ispc.ispc.
 * Same result semantics as r72-ref.cpp; based on r72-ks-spmd.cpp.
*/
#include "ccoreio.h"

#ifdef __cplusplus
extern "C" s32 CDECL rc5_72_unit_func_mix_spmd ( RC5_72UnitWork *, u32 *, void * );
#endif

/* exported by r72-mix-spmd-ispc.ispc (ISPC exports use C linkage) */
extern "C" void rc5_32pipe(u32 hi, u32 mid, u32 lo, u32 plainhi, u32 plainlo,
                           u32 *outA, u32 *outB);

#define PIPES 32

s32 CDECL rc5_72_unit_func_mix_spmd (RC5_72UnitWork *rc5_72unitwork, u32 *iterations, void * /*memblk*/)
{
  u32 kiter = *iterations / PIPES;
  u32 bufferA[PIPES];
  u32 bufferB[PIPES];

  while (kiter--)
  {
    rc5_32pipe(rc5_72unitwork->L0.hi, rc5_72unitwork->L0.mid, rc5_72unitwork->L0.lo,
               rc5_72unitwork->plain.hi, rc5_72unitwork->plain.lo, bufferA, bufferB);

    for (u32 i = 0; i < PIPES; i++)
    {
      if (bufferA[i] == rc5_72unitwork->cypher.lo)
      {
        ++rc5_72unitwork->check.count;
        rc5_72unitwork->check.hi  = rc5_72unitwork->L0.hi + i;
        rc5_72unitwork->check.mid = rc5_72unitwork->L0.mid;
        rc5_72unitwork->check.lo  = rc5_72unitwork->L0.lo;
        if (bufferB[i] == rc5_72unitwork->cypher.hi)
        {
          *iterations -= (kiter + 1) * PIPES - i;
          return RESULT_FOUND;
        }
      }
    }

    /* advance the (mangled) key by PIPES; L0.hi is always PIPES-aligned */
    #define key rc5_72unitwork->L0
    key.hi = (key.hi + PIPES) & 0x000000FF;
    if (!key.hi)
    {
      key.mid = key.mid + 0x01000000;
      if (!(key.mid & 0xFF000000u))
      {
        key.mid = (key.mid + 0x00010000) & 0x00FFFFFF;
        if (!(key.mid & 0x00FF0000))
        {
          key.mid = (key.mid + 0x00000100) & 0x0000FFFF;
          if (!(key.mid & 0x0000FF00))
          {
            key.mid = (key.mid + 0x00000001) & 0x000000FF;
            if (!key.mid)
            {
              key.lo = key.lo + 0x01000000;
              if (!(key.lo & 0xFF000000u))
              {
                key.lo = (key.lo + 0x00010000) & 0x00FFFFFF;
                if (!(key.lo & 0x00FF0000))
                {
                  key.lo = (key.lo + 0x00000100) & 0x0000FFFF;
                  if (!(key.lo & 0x0000FF00))
                  {
                    key.lo = (key.lo + 0x00000001) & 0x000000FF;
                  }
                }
              }
            }
          }
        }
      }
    }
    #undef key
  }
  return RESULT_NOTHING;
}
