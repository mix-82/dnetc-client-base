/*
 * Copyright distributed.net 2012-2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: RC5-72 cores.
*/
#ifndef VK_RC572_H
#define VK_RC572_H

#include "vk_common.h"

#ifdef __cplusplus
extern "C" s32 rc5_72_unit_func_vk_ref (RC5_72UnitWork *rc5_72unitwork, u32 *iterations, void *);
#endif

// Work-group size the cores build their shaders with. 0 selects the default.
// Takes effect the next time a core builds its program. For tuning tests.
void VKSetWorkGroupSize(u32 localSize);

#endif // VK_RC572_H
