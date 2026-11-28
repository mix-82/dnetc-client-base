/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: device information for the client (-gpuinfo, core
 * selection).
*/
#ifndef VK_INFO_H
#define VK_INFO_H

int  getVulkanDeviceCount(void);

// Returns -1 if there is no such device, otherwise the PCI vendor id (upper
// 16 bits) and device id (lower 16 bits). *cpuname receives the device name.
long getVulkanRawProcessorID(int device, const char **cpuname);

void VulkanPrintExtendedGpuInfo(int device);

#endif // VK_INFO_H
