/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: device information for -gpuinfo.
*/

#include "vk_info.h"
#include "vk_context.h"

#include "logstuff.h"

static const char *DeviceTypeName(u32 deviceType)
{
  switch (deviceType)
  {
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated GPU";
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "discrete GPU";
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return "virtual GPU";
    case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "CPU";
    default:                                     return "other";
  }
}

long getVulkanRawProcessorID(int device, const char **cpuname)
{
  vk_context_t *cont = vk_get_context(device);

  if (cont == NULL)
  {
    if (cpuname)
      *cpuname = "Unknown";
    return -1;
  }
  if (cpuname)
    *cpuname = cont->deviceName;
  return (long) (((cont->vendorID & 0xffff) << 16) | (cont->deviceID & 0xffff));
}

void VulkanPrintExtendedGpuInfo(int device)
{
  vk_context_t *cont = vk_get_context(device);

  if (cont == NULL)
    return;

  LogRaw("Device %d: %s\n", cont->clientDeviceNo, cont->deviceName);
  LogRaw("  Type:            %s\n", DeviceTypeName(cont->deviceType));
  LogRaw("  Vendor/device:   0x%04x / 0x%04x\n", cont->vendorID, cont->deviceID);
  LogRaw("  Vulkan version:  %u.%u.%u\n", VK_VERSION_MAJOR(cont->apiVersion),
      VK_VERSION_MINOR(cont->apiVersion), VK_VERSION_PATCH(cont->apiVersion));
  if (cont->driverName[0] != 0)
    LogRaw("  Driver:          %s %s (driver id %u)\n", cont->driverName, cont->driverInfo, cont->driverID);
  LogRaw("  Max group count: %u x %u x %u\n", cont->maxGroupCount[0], cont->maxGroupCount[1], cont->maxGroupCount[2]);
  LogRaw("  Max group size:  %u x %u x %u, %u invocations\n", cont->maxGroupSize[0], cont->maxGroupSize[1],
      cont->maxGroupSize[2], cont->maxGroupInvocations);
  if (cont->active)
    LogRaw("  Compute queue family: %u\n", cont->queueFamily);
  else
    LogRaw("  Not supported by this client\n");
}
