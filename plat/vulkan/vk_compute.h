/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: one compute program per device, and running it.
 *
 * Nothing here knows about RC5. A program is a SPIR-V compute shader with
 *   set 0, binding 0   uniform buffer: parameters, written by the host
 *   set 0, binding 1   storage buffer: results, written by the shader
 *   constant_id 0      work-group size (local_size_x)
 * Both buffers stay mapped (cont->constBuffer.mapped, cont->outBuffer.mapped)
 * and may be read and written by the host whenever no kernel is running.
*/
#ifndef VK_COMPUTE_H
#define VK_COMPUTE_H

#include <stddef.h>
#include "vk_context.h"

// Creates the logical device if needed, then the pipeline and both buffers.
// Any program the device already has is released first.
bool VKBuildProgram(vk_context_t *cont, const u32 *spirv, size_t spirvBytes,
                    u32 constBytes, u32 outBytes, u32 localSize);
void VKReleaseProgram(vk_context_t *cont);

// Largest number of work items one kernel run can cover on this device.
u32  VKMaxDispatchItems(const vk_context_t *cont);

// Splits 'items' work items into groupsX * groupsY work groups. The shader
// numbers its work items as
//   gl_GlobalInvocationID.y * (groupsX * localSize) + gl_GlobalInvocationID.x
// and has to ignore numbers >= items, because the last group and the last
// row are usually not full.
bool VKDispatchSize(const vk_context_t *cont, u32 items, u32 *groupsX, u32 *groupsY);

// Runs the kernel once and waits until it has finished. Any failure,
// including a kernel that does not finish in time (VK_TIMEOUT), marks the
// device unusable: later calls fail at once and its objects are abandoned.
VkResult VKRunKernel(vk_context_t *cont, u32 groupsX, u32 groupsY);

#endif // VK_COMPUTE_H
