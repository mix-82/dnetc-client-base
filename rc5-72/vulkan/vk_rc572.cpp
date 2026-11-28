/*
 * Copyright distributed.net 2012-2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: RC5-72 cores.
 *
 * Port of rc5-72/opencl/ocl_ref.cpp. Everything except the shader is shared
 * by all cores: a core is one entry in the table below.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vk_rc572.h"
#include "vk_compute.h"

#include "rc5-ref.cpp"

// Words in the constants buffer (the shaders use the first 9).
#define CONST_WORDS 16
// Words in the output buffer. Must match OUT_WORDS in the shaders.
#define OUT_WORDS 64

#define VK_LOCAL_SIZE_DEFAULT 64

// Target time of one kernel run in milliseconds: grow below, shrink above.
#define KERNEL_MS_LOW  8.
#define KERNEL_MS_HIGH 12.

typedef struct
{
  u32         coreID;
  const u32  *spirv;
  size_t      spirvBytes;
} vk_core_t;

static const vk_core_t core_ref = { VKCORE_REF, vk_rc5_ref_spv, sizeof(vk_rc5_ref_spv) };

static u32 localSizeWanted = 0;

void VKSetWorkGroupSize(u32 localSize)
{
  localSizeWanted = localSize;
}

// -----------------------------------------------------------------------

static bool InitCore(vk_context_t *cont, const vk_core_t *core)
{
  if (!cont->active)
  {
    Log("Device %d is not supported\n", cont->clientDeviceNo);
    return false;
  }

  u32 localSize = VK_LOCAL_SIZE_DEFAULT;
  if (localSizeWanted != 0)
    localSize = localSizeWanted;
  if (localSize > cont->maxGroupSize[0])
    localSize = cont->maxGroupSize[0];
  if (localSize > cont->maxGroupInvocations)
    localSize = cont->maxGroupInvocations;

  if (!VKBuildProgram(cont, core->spirv, core->spirvBytes,
                      CONST_WORDS * sizeof(u32), OUT_WORDS * sizeof(u32), localSize))
    return false;

  // Run sizes are whole work groups, so that no work item is wasted.
  cont->runSizeMultiplier = localSize;
  cont->maxWorkSize = (VKMaxDispatchItems(cont) / localSize) * localSize;
  cont->runSize = (65536 / localSize) * localSize;
  if (cont->runSize == 0)
    cont->runSize = localSize;
  if (cont->runSize > cont->maxWorkSize)
    cont->runSize = cont->maxWorkSize;

  cont->coreID = core->coreID;
  return true;
}

static void FillConstantBuffer(vk_context_t *cont, const RC5_72UnitWork *rc5_72unitwork, u32 keys, u32 rowKeys)
{
  u32 *constPtr = cont->constBuffer.mapped;

  //key_hi,key_mid,key_lo,keys in this run
  constPtr[0] = rc5_72unitwork->L0.hi;
  constPtr[1] = rc5_72unitwork->L0.mid;
  constPtr[2] = rc5_72unitwork->L0.lo;
  constPtr[3] = keys;

  //plain_lo,plain_hi,cypher_lo,cypher_hi
  constPtr[4] = rc5_72unitwork->plain.lo;
  constPtr[5] = rc5_72unitwork->plain.hi;
  constPtr[6] = rc5_72unitwork->cypher.lo;
  constPtr[7] = rc5_72unitwork->cypher.hi;

  //keys in one row of the dispatch
  constPtr[8] = rowKeys;
}

// Tests 'keys' keys starting at the unit's L0 in one kernel run. If 'ms' is
// not NULL it receives the time the run took, measured with the client's
// clock. If the clock fails it receives 10, which is inside the target
// range, so the run size stays as it is.
static bool RunKeys(vk_context_t *cont, const RC5_72UnitWork *rc5_72unitwork, u32 keys, double *ms)
{
  u32 groupsX;
  u32 groupsY;

  if (!VKDispatchSize(cont, keys, &groupsX, &groupsY))
  {
    Log("Internal error: cannot run %u keys in one kernel, device %d\n", keys, cont->clientDeviceNo);
    return false;
  }
  FillConstantBuffer(cont, rc5_72unitwork, keys, groupsX * cont->localSize);

  struct timeval started;
  struct timeval finished;
  bool timed = (CliGetMonotonicClock(&started) == 0);

  VkResult status = VKRunKernel(cont, groupsX, groupsY);
  if (ms != NULL)
  {
    *ms = 10.;
    if (timed && CliGetMonotonicClock(&finished) == 0)
    {
      *ms = 1e3 * (double) (finished.tv_sec - started.tv_sec) +
            1e-3 * (double) (finished.tv_usec - started.tv_usec);
    }
  }
  if (vk_diagnose(status, "running kernel", cont) != VK_SUCCESS)
    return false;
  return true;
}

// Returns 1 for a full match, 0 for none, -1 on error. *CMC is the number of
// partial matches up to and including the full match, *iters_done the key
// number of the last of them.
static s32 ReadResults(vk_context_t *cont, u32 *CMC, u32 *iters_done)
{
  u32 *outPtr = cont->outBuffer.mapped;
  u32 found;

  *CMC = 0;
  *iters_done = 0x7fffffff;

  found = outPtr[0];
  outPtr[0] = 0;
  if (found)
  {
    u32 fullmatchkeyidx = 0xffffffff;
    if (found >= OUT_WORDS)
    {
      Log("Internal error reading kernel output\n");
      return -1;
    }
    for (u32 idx = 1; idx <= found; idx++)
    {
      if (outPtr[idx] & 0x80000000)
      {
        fullmatchkeyidx = outPtr[idx] & 0x7fffffff;
        break;
      }
    }
    //second pass, calculate CMCs
    for (u32 idx = 1; idx <= found; idx++)
    {
      u32 data = outPtr[idx] & 0x7fffffff;
      if (data <= fullmatchkeyidx)
      {
        (*CMC)++;
        if ((data > *iters_done) || (data == fullmatchkeyidx) || (*iters_done == 0x7fffffff))
        {
          *iters_done = data;
        }
      }
    }
    if (fullmatchkeyidx < 0xffffffff)
      return 1;
    return 0;
  }
  return 0;
}

//Internal test function to make sure core is working properly in user environment
static bool selftest(vk_context_t *cont)
{
  RC5_72UnitWork tmp_unit;
  u32 CMC, iters_done;
  s32 read_res;

  memset(&tmp_unit, 0, sizeof(tmp_unit));
  cont->outBuffer.mapped[0] = 0;

  //first case: "not found"
  tmp_unit.L0.hi = 0xcc;
  tmp_unit.L0.mid = 0x55555555;
  tmp_unit.L0.lo = 0xaaaaaaaa;
  tmp_unit.plain.lo = 0x21436587;
  tmp_unit.plain.hi = 0xa9cbed0f;
  tmp_unit.cypher.lo = 0x12345678;
  tmp_unit.cypher.hi = 0x9abcdef0;

  if (!RunKeys(cont, &tmp_unit, 1, NULL))
    return false;
  read_res = ReadResults(cont, &CMC, &iters_done);
  if ((read_res < 0) || (CMC > 0) || (read_res > 0))
    return false;

  //second case, partial match
  tmp_unit.L0.hi = 0xb6;
  tmp_unit.L0.mid = 0xb843b603;
  tmp_unit.L0.lo = 0x825d8bd0;
  tmp_unit.plain.lo = 0x6cf2bd15;
  tmp_unit.plain.hi = 0x989e1475;
  tmp_unit.cypher.lo = 0xbefcafe7;
  tmp_unit.cypher.hi = 0xa6ec745f;

  if (!RunKeys(cont, &tmp_unit, 1, NULL))
    return false;
  read_res = ReadResults(cont, &CMC, &iters_done);
  if ((read_res < 0) || (CMC != 1) || (read_res > 0))
    return false;

  //Third case, full match
  tmp_unit.L0.hi = 0x2a;
  tmp_unit.L0.mid = 0x47634;
  tmp_unit.L0.lo = 0xba6196cc;
  tmp_unit.plain.lo = 0xc13fb62;
  tmp_unit.plain.hi = 0x7e370fcb;
  tmp_unit.cypher.lo = 0x4da0ae1c;
  tmp_unit.cypher.hi = 0xd1c60cfb;

  if (!RunKeys(cont, &tmp_unit, 1, NULL))
    return false;
  read_res = ReadResults(cont, &CMC, &iters_done);
  if ((read_res <= 0) || (CMC != 1))
    return false;

  return true;
}

// -----------------------------------------------------------------------

static s32 rc5_72_unit_func_vk(RC5_72UnitWork *rc5_72unitwork, u32 *iterations, const vk_core_t *core)
{
  vk_context_t *cont = vk_get_context(rc5_72unitwork->devicenum);
  RC5_72UnitWork tmp_unit;

  if (cont == NULL)
  {
    RaiseExitRequestTrigger();
    return -1;
  }

  if (cont->coreID != core->coreID)
  {
    if (!InitCore(cont, core))
    {
      RaiseExitRequestTrigger();
      return -1;
    }
  }

  if (!cont->sanityChecked)
  {
    if (!selftest(cont))
    {
      Log("Sanity checks failed - Vulkan system is not functional! Device: %d\n", cont->clientDeviceNo);
      RaiseExitRequestTrigger();
      return -1;
    }
    cont->sanityChecked = true;
  }

  memmove(&tmp_unit, rc5_72unitwork, sizeof(RC5_72UnitWork));

  u32 kiter = *iterations;

  cont->outBuffer.mapped[0] = 0;

  while (kiter)
  {
    u32 rest0;

    if (kiter >= cont->runSize)
      rest0 = cont->runSize;
    else
      rest0 = kiter;
    kiter -= rest0;

    double d;
    if (!RunKeys(cont, &tmp_unit, rest0, &d))
    {
      RaiseExitRequestTrigger();
      return -1;          //err
    }

    if (d > KERNEL_MS_HIGH)
    {
      //Decrease worksize by 5%
      u32 diffm = cont->runSize /20 /cont->runSizeMultiplier;
      if (diffm == 0)
        diffm = 1;
      if (cont->runSize > (diffm*cont->runSizeMultiplier))
        cont->runSize -= diffm*cont->runSizeMultiplier;
    }
    else if ((d < KERNEL_MS_LOW) && (rest0 == cont->runSize))
    {
      u32 diffm = cont->runSize /20 /cont->runSizeMultiplier;
      if (diffm == 0)
        diffm = 1;
      if (cont->runSize < cont->maxWorkSize)
        cont->runSize += diffm*cont->runSizeMultiplier;
      if (cont->runSize > cont->maxWorkSize)
        cont->runSize = cont->maxWorkSize;
    }

    //Check the results
    u32 CMC, iters_done;
    s32 read_res = ReadResults(cont, &CMC, &iters_done);
    if (read_res < 0)
    {
      RaiseExitRequestTrigger();
      return -1;          //err
    }

    if (CMC)
    {
      u32 hi = tmp_unit.L0.hi;
      u32 mid = tmp_unit.L0.mid;
      u32 lo = tmp_unit.L0.lo;

      key_incr(&hi, &mid, &lo, iters_done);

      //update cmc data
      tmp_unit.check.hi = hi;
      tmp_unit.check.mid = mid;
      tmp_unit.check.lo = lo;
      tmp_unit.check.count += CMC;

      if (read_res > 0) //Full match
      {
        //re-check the result using reference software core
        RC5_72UnitWork t;

        memcpy(&t, rc5_72unitwork, sizeof(RC5_72UnitWork));
        t.L0.hi = hi;
        t.L0.mid = mid;
        t.L0.lo = lo;

        if (rc5_72_unit_func_ansi_ref(&t) != RESULT_FOUND)
        {
          Log("WARNING!!! False positive detected, device:%d!\n", cont->clientDeviceNo);
          Log("Debug info: %x:%x:%x\n", hi, mid, lo);
          RaiseExitRequestTrigger();
          return -1;
        }

        tmp_unit.L0.hi = hi;
        tmp_unit.L0.mid = mid;
        tmp_unit.L0.lo = lo;

        *iterations -= kiter-iters_done+rest0;
        memmove(rc5_72unitwork, &tmp_unit, sizeof(RC5_72UnitWork));
        return RESULT_FOUND;
      }
    }
    key_incr(&tmp_unit.L0.hi, &tmp_unit.L0.mid, &tmp_unit.L0.lo, rest0);
  }

  /* tell the client about the optimal timeslice increment for this core
     (with current parameters) */
  memmove(rc5_72unitwork, &tmp_unit, sizeof(RC5_72UnitWork));
  rc5_72unitwork->optimal_timeslice_increment = cont->runSize;
  return RESULT_NOTHING;
}

s32 rc5_72_unit_func_vk_ref(RC5_72UnitWork *rc5_72unitwork, u32 *iterations, void *)
{
  return rc5_72_unit_func_vk(rc5_72unitwork, iterations, &core_ref);
}
