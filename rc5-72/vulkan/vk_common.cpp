/*
 * Copyright distributed.net 2009-2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: RC5-72 helpers shared by the Vulkan cores.
*/

#include "vk_common.h"

// Software reference: tests the one key in the unit. Used to re-check every
// full match a kernel reports.
s32 rc5_72_unit_func_ansi_ref (RC5_72UnitWork *rc5_72unitwork)
{
  u32 i, j, k;
  u32 A, B;
  u32 S[26];
  u32 L[3];
  u32 kiter = 1;
  while (kiter--)
  {
    L[2] = rc5_72unitwork->L0.hi;
    L[1] = rc5_72unitwork->L0.mid;
    L[0] = rc5_72unitwork->L0.lo;
    for (S[0] = P, i = 1; i < 26; i++)
      S[i] = S[i-1] + Q;

    for (A = B = i = j = k = 0;
         k < 3*26; k++, i = (i + 1) % 26, j = (j + 1) % 3)
    {
      A = S[i] = ROTL3(S[i]+(A+B));
      B = L[j] = ROTL(L[j]+(A+B),(A+B));
    }
    A = rc5_72unitwork->plain.lo + S[0];
    B = rc5_72unitwork->plain.hi + S[1];
    for (i=1; i<=12; i++)
    {
      A = ROTL(A^B,B)+S[2*i];
      B = ROTL(B^A,A)+S[2*i+1];
    }
    if (A == rc5_72unitwork->cypher.lo)
    {
        return RESULT_FOUND;
    }
  }
  return RESULT_NOTHING;
}

//Key increment

void key_incr(u32 *hi, u32 *mid, u32 *lo, u32 incr)
{
  *hi+=incr;
  u32 ad=*hi>>8;
  if(*hi<incr)
    ad+=0x01000000;
  u32 t_m=SWAP32(*mid)+ad;
  u32 t_l=SWAP32(*lo);
  if(t_m<ad)
    t_l++;

  *hi=*hi&0xff;
  *mid=SWAP32(t_m);
  *lo=SWAP32(t_l);
}
