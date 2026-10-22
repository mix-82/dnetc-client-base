/* Client-style wrapper for one build of mix.ispc, compiled once per variant:
     -DPIPES=<keys per call> -DKERNEL=<ISPC export> -DFUNC=<unit function name>
   Same result semantics as rc5-72/ispc/r72-mix-spmd.cpp. */

#include <stdint.h>

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

extern void KERNEL(uint32_t hi, uint32_t mid, uint32_t lo, uint32_t plainhi, uint32_t plainlo,
                   uint32_t *outA, uint32_t *outB);

int32_t FUNC(work_t *w, uint32_t *iterations, void *memblk)
{
  uint32_t kiter = *iterations / PIPES;
  uint32_t bufferA[PIPES];
  uint32_t bufferB[PIPES];
  uint32_t i;

  (void)memblk;
  while (kiter--)
  {
    KERNEL(w->L0hi, w->L0mid, w->L0lo, w->plainhi, w->plainlo, bufferA, bufferB);

    for (i = 0; i < PIPES; i++)
    {
      if (bufferA[i] == w->cipherlo)
      {
        ++w->count;
        w->chi = w->L0hi + i;
        w->cmid = w->L0mid;
        w->clo = w->L0lo;
        if (bufferB[i] == w->cipherhi)
        {
          *iterations -= (kiter + 1) * PIPES - i;
          return RESULT_FOUND;
        }
      }
    }

    /* advance the (mangled) key by PIPES; L0hi is always PIPES-aligned */
    w->L0hi = (w->L0hi + PIPES) & 0x000000FF;
    if (!w->L0hi)
    {
      w->L0mid = __builtin_bswap32(__builtin_bswap32(w->L0mid) + 1);
      if (!w->L0mid)
      {
        w->L0lo = __builtin_bswap32(__builtin_bswap32(w->L0lo) + 1);
      }
    }
  }
  return RESULT_NOTHING;
}
