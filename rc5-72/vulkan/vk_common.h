/*
 * Copyright distributed.net 2009-2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: RC5-72 helpers shared by the Vulkan cores.
 *
 * key_incr() and rc5_72_unit_func_ansi_ref() are the functions of the same
 * name in rc5-72/opencl/ocl_common.cpp, unchanged.
*/
#ifndef VK_COMMON_H
#define VK_COMMON_H

#include "vk_context.h"

#include "ccoreio.h"
#include "logstuff.h"  // Log()
#include "triggers.h"
#include "clitime.h"   // CliGetMonotonicClock()

#define P 0xB7E15163
#define Q 0x9E3779B9

#define SHL(x, s) ((u32) ((x) << ((s) & 31)))
#define SHR(x, s) ((u32) ((x) >> (32 - ((s) & 31))))
#define ROTL(x, s) ((u32) (SHL((x), (s)) | SHR((x), (s))))
#define ROTL3(x) ROTL(x, 3)

#define SWAP32(x) (((((x) >> 24) | ((x) << 24)) | (((x) & 0x00ff0000) >> 8)) | (((x) & 0x0000ff00 ) << 8))

void key_incr(u32 *hi, u32 *mid, u32 *lo, u32 incr);
s32 rc5_72_unit_func_ansi_ref (RC5_72UnitWork *rc5_72unitwork);

#endif // VK_COMMON_H
