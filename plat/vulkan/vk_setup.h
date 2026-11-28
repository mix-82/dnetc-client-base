/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: start-up and shutdown, as seen by the client.
*/
#ifndef VK_SETUP_H
#define VK_SETUP_H

// Finds the Vulkan devices. Returns their number, or -1 if Vulkan cannot be
// used at all. Safe to call more than once; only the first call does work.
int  InitializeVulkan(void);

// Releases everything InitializeVulkan(), VKCreateDevice() and
// VKBuildProgram() created. No cruncher may be running.
void ShutdownVulkan(void);

#endif // VK_SETUP_H
