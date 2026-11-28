/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: instance, device list and logical devices.
 *
 * Requires Vulkan 1.2. No extensions and no optional features are used.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vk_setup.h"
#include "vk_info.h"
#include "vk_compute.h"

#include "logstuff.h"

#define VK_NOT_INITIALIZED (-12345)

static int numDevices = VK_NOT_INITIALIZED;
static vk_context_t *vk_context = NULL;
static VkInstance vk_instance = VK_NULL_HANDLE;

// -----------------------------------------------------------------------

const char *vkStrError(VkResult status)
{
  switch (status)
  {
    case VK_SUCCESS:                        return "VK_SUCCESS";
    case VK_NOT_READY:                      return "VK_NOT_READY";
    case VK_TIMEOUT:                        return "VK_TIMEOUT";
    case VK_INCOMPLETE:                     return "VK_INCOMPLETE";
    case VK_ERROR_OUT_OF_HOST_MEMORY:       return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY:     return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_INITIALIZATION_FAILED:    return "VK_ERROR_INITIALIZATION_FAILED";
    case VK_ERROR_DEVICE_LOST:              return "VK_ERROR_DEVICE_LOST";
    case VK_ERROR_MEMORY_MAP_FAILED:        return "VK_ERROR_MEMORY_MAP_FAILED";
    case VK_ERROR_LAYER_NOT_PRESENT:        return "VK_ERROR_LAYER_NOT_PRESENT";
    case VK_ERROR_EXTENSION_NOT_PRESENT:    return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case VK_ERROR_FEATURE_NOT_PRESENT:      return "VK_ERROR_FEATURE_NOT_PRESENT";
    case VK_ERROR_INCOMPATIBLE_DRIVER:      return "VK_ERROR_INCOMPATIBLE_DRIVER";
    case VK_ERROR_TOO_MANY_OBJECTS:         return "VK_ERROR_TOO_MANY_OBJECTS";
    case VK_ERROR_FRAGMENTED_POOL:          return "VK_ERROR_FRAGMENTED_POOL";
    case VK_ERROR_OUT_OF_POOL_MEMORY:       return "VK_ERROR_OUT_OF_POOL_MEMORY";
    case VK_ERROR_INVALID_SHADER_NV:        return "VK_ERROR_INVALID_SHADER_NV";
    case VK_ERROR_UNKNOWN:                  return "VK_ERROR_UNKNOWN";
    default:                                return "unknown Vulkan error";
  }
}

VkResult vk_diagnose(VkResult status, const char *where, const vk_context_t *cont)
{
  if (status != VK_SUCCESS)
  {
    if (where != NULL && cont != NULL)
      Log("Error %s on device %d\n", where, cont->clientDeviceNo);
    else if (where != NULL)
      Log("Error %s\n", where);
    Log("Error code %d, message: %s\n", (int) status, vkStrError(status));
  }
  return status;
}

// -----------------------------------------------------------------------

int getVulkanDeviceCount(void)
{
  return numDevices;
}

vk_context_t *vk_get_context(int device)
{
  if (device >= 0 && device < numDevices)
    return &vk_context[device];
  return NULL;
}

// -----------------------------------------------------------------------

// Fills the description part of 'cont' for one physical device.
// Returns false if the device is not to be listed at all. A listed device
// that the client cannot use gets active = false and a log line saying why.
static bool DescribeDevice(VkPhysicalDevice phys, int deviceNo, vk_context_t *cont)
{
  VkPhysicalDeviceProperties props;

  vkGetPhysicalDeviceProperties(phys, &props);

  // Software rasterizers such as Mesa llvmpipe. Allowed for testing and debug only.
#ifndef VK_ALLOW_CPU_DEVICES
  if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU)
    return false;
#endif

  memset(cont, 0, sizeof(*cont));
  cont->clientDeviceNo = deviceNo;
  cont->physDevice     = phys;
  cont->apiVersion     = props.apiVersion;
  cont->vendorID       = props.vendorID;
  cont->deviceID       = props.deviceID;
  cont->deviceType     = (u32) props.deviceType;
  // same array size on both sides; the last byte stays 0 from the memset
  memcpy(cont->deviceName, props.deviceName, sizeof(cont->deviceName) - 1);
  for (int i = 0; i < 3; i++)
  {
    cont->maxGroupCount[i] = props.limits.maxComputeWorkGroupCount[i];
    cont->maxGroupSize[i]  = props.limits.maxComputeWorkGroupSize[i];
  }
  cont->maxGroupInvocations = props.limits.maxComputeWorkGroupInvocations;

  if (props.apiVersion < VK_API_VERSION_1_2)
  {
    Log("Device %d (%s) is not supported: its driver offers Vulkan %u.%u, 1.2 is required\n",
        deviceNo, cont->deviceName,
        VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion));
    return true;
  }

  // Driver identity. Part of Vulkan 1.2, so only asked for after the version check.
  VkPhysicalDeviceDriverProperties driver;
  VkPhysicalDeviceProperties2 props2;

  memset(&driver, 0, sizeof(driver));
  driver.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
  memset(&props2, 0, sizeof(props2));
  props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
  props2.pNext = &driver;
  vkGetPhysicalDeviceProperties2(phys, &props2);
  cont->driverID = (u32) driver.driverID;
  memcpy(cont->driverName, driver.driverName, sizeof(cont->driverName) - 1);
  memcpy(cont->driverInfo, driver.driverInfo, sizeof(cont->driverInfo) - 1);

  // First queue family that can run compute work.
  u32 familyCount = 0;
  bool found = false;

  vkGetPhysicalDeviceQueueFamilyProperties(phys, &familyCount, NULL);
  if (familyCount != 0)
  {
    VkQueueFamilyProperties *families =
        (VkQueueFamilyProperties *) malloc(familyCount * sizeof(VkQueueFamilyProperties));
    if (families != NULL)
    {
      vkGetPhysicalDeviceQueueFamilyProperties(phys, &familyCount, families);
      for (u32 i = 0; i < familyCount && !found; i++)
      {
        if ((families[i].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0 && families[i].queueCount != 0)
        {
          cont->queueFamily = i;
          found = true;
        }
      }
      free(families);
    }
  }
  if (!found)
  {
    Log("Device %d (%s) is not supported: no compute queue\n", deviceNo, cont->deviceName);
    return true;
  }

  cont->active = true;
  return true;
}

// -----------------------------------------------------------------------

int InitializeVulkan(void)
{
  if (numDevices != VK_NOT_INITIALIZED)
    return numDevices;

  numDevices = -1;  /* assume detection failure for now */

  u32 instanceVersion = 0;
  VkResult status = vkEnumerateInstanceVersion(&instanceVersion);
  if (vk_diagnose(status, "obtaining the Vulkan version (vkEnumerateInstanceVersion)", NULL) != VK_SUCCESS)
    return numDevices;
  if (instanceVersion < VK_API_VERSION_1_2)
  {
    Log("Vulkan %u.%u is installed, version 1.2 or later is required\n",
        VK_VERSION_MAJOR(instanceVersion), VK_VERSION_MINOR(instanceVersion));
    return numDevices;
  }

  VkApplicationInfo appInfo;
  VkInstanceCreateInfo instInfo;

  memset(&appInfo, 0, sizeof(appInfo));
  appInfo.sType            = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  appInfo.pApplicationName = "dnetc";
  appInfo.apiVersion       = VK_API_VERSION_1_2;
  memset(&instInfo, 0, sizeof(instInfo));
  instInfo.sType            = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  instInfo.pApplicationInfo = &appInfo;

  status = vkCreateInstance(&instInfo, NULL, &vk_instance);
  if (vk_diagnose(status, "creating the Vulkan instance (vkCreateInstance)", NULL) != VK_SUCCESS)
  {
    vk_instance = VK_NULL_HANDLE;
    return numDevices;
  }

  u32 physCount = 0;
  status = vkEnumeratePhysicalDevices(vk_instance, &physCount, NULL);
  if (vk_diagnose(status, "obtaining number of devices (vkEnumeratePhysicalDevices/1)", NULL) != VK_SUCCESS)
    return numDevices;
  if (physCount == 0)
  {
    numDevices = 0;
    return numDevices;
  }

  VkPhysicalDevice *phys = (VkPhysicalDevice *) malloc(physCount * sizeof(VkPhysicalDevice));
  vk_context = (vk_context_t *) calloc(physCount, sizeof(vk_context_t));
  if (phys == NULL || vk_context == NULL)
  {
    Log("Out of memory listing Vulkan devices\n");
    free(phys);
    free(vk_context);
    vk_context = NULL;
    return numDevices;
  }

  status = vkEnumeratePhysicalDevices(vk_instance, &physCount, phys);
  if (status == VK_INCOMPLETE)  // a device appeared in between; use the ones we have room for
    status = VK_SUCCESS;
  if (vk_diagnose(status, "obtaining list of devices (vkEnumeratePhysicalDevices/2)", NULL) != VK_SUCCESS)
  {
    free(phys);
    free(vk_context);
    vk_context = NULL;
    return numDevices;
  }

  int listed = 0;
  for (u32 i = 0; i < physCount; i++)
  {
    if (DescribeDevice(phys[i], listed, &vk_context[listed]))
      listed++;
  }
  free(phys);

  numDevices = listed;
  return numDevices;
}

void ShutdownVulkan(void)
{
  bool abandoned = false;

  if (vk_context != NULL)
  {
    for (int i = 0; i < numDevices; i++)
    {
      if (vk_context[i].unusable && vk_context[i].device != VK_NULL_HANDLE)
        abandoned = true;
      VKReleaseProgram(&vk_context[i]);
      VKReleaseDevice(&vk_context[i]);
    }
    free(vk_context);
    vk_context = NULL;
  }
  // The instance must outlive its devices, so it is abandoned with them.
  if (vk_instance != VK_NULL_HANDLE && !abandoned)
    vkDestroyInstance(vk_instance, NULL);
  vk_instance = VK_NULL_HANDLE;
  numDevices = VK_NOT_INITIALIZED;
}

// -----------------------------------------------------------------------

bool VKCreateDevice(vk_context_t *cont)
{
  if (!cont->active)
  {
    Log("Device %d is not supported\n", cont->clientDeviceNo);
    return false;
  }
  if (cont->unusable)
    return false;
  if (cont->device != VK_NULL_HANDLE)
    return true;

  float priority = 1.0f;
  VkDeviceQueueCreateInfo queueInfo;
  VkDeviceCreateInfo deviceInfo;

  memset(&queueInfo, 0, sizeof(queueInfo));
  queueInfo.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  queueInfo.queueFamilyIndex = cont->queueFamily;
  queueInfo.queueCount       = 1;
  queueInfo.pQueuePriorities = &priority;
  memset(&deviceInfo, 0, sizeof(deviceInfo));
  deviceInfo.sType                = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  deviceInfo.queueCreateInfoCount = 1;
  deviceInfo.pQueueCreateInfos    = &queueInfo;

  VkResult status = vkCreateDevice(cont->physDevice, &deviceInfo, NULL, &cont->device);
  if (vk_diagnose(status, "creating Vulkan device", cont) != VK_SUCCESS)
  {
    cont->device = VK_NULL_HANDLE;
    return false;
  }
  vkGetDeviceQueue(cont->device, cont->queueFamily, 0, &cont->queue);

  VkCommandPoolCreateInfo poolInfo;

  memset(&poolInfo, 0, sizeof(poolInfo));
  poolInfo.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  poolInfo.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  poolInfo.queueFamilyIndex = cont->queueFamily;
  status = vkCreateCommandPool(cont->device, &poolInfo, NULL, &cont->cmdPool);
  if (vk_diagnose(status, "creating command pool", cont) != VK_SUCCESS)
  {
    cont->cmdPool = VK_NULL_HANDLE;
    VKReleaseDevice(cont);
    return false;
  }

  VkCommandBufferAllocateInfo bufferInfo;

  memset(&bufferInfo, 0, sizeof(bufferInfo));
  bufferInfo.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  bufferInfo.commandPool        = cont->cmdPool;
  bufferInfo.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  bufferInfo.commandBufferCount = 1;
  status = vkAllocateCommandBuffers(cont->device, &bufferInfo, &cont->cmdBuffer);
  if (vk_diagnose(status, "creating command buffer", cont) != VK_SUCCESS)
  {
    cont->cmdBuffer = VK_NULL_HANDLE;
    VKReleaseDevice(cont);
    return false;
  }

  VkFenceCreateInfo fenceInfo;

  memset(&fenceInfo, 0, sizeof(fenceInfo));
  fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  status = vkCreateFence(cont->device, &fenceInfo, NULL, &cont->fence);
  if (vk_diagnose(status, "creating fence", cont) != VK_SUCCESS)
  {
    cont->fence = VK_NULL_HANDLE;
    VKReleaseDevice(cont);
    return false;
  }
  return true;
}

// The program (VKReleaseProgram) must be released first.
void VKReleaseDevice(vk_context_t *cont)
{
  // See VKReleaseProgram() for why an unusable device is not destroyed.
  if (cont->device != VK_NULL_HANDLE && !cont->unusable)
  {
    vkDeviceWaitIdle(cont->device);
    if (cont->fence != VK_NULL_HANDLE)
      vkDestroyFence(cont->device, cont->fence, NULL);
    if (cont->cmdPool != VK_NULL_HANDLE)
      vkDestroyCommandPool(cont->device, cont->cmdPool, NULL);  // frees cmdBuffer too
    vkDestroyDevice(cont->device, NULL);
  }
  cont->fence     = VK_NULL_HANDLE;
  cont->cmdPool   = VK_NULL_HANDLE;
  cont->cmdBuffer = VK_NULL_HANDLE;
  cont->queue     = VK_NULL_HANDLE;
  cont->device    = VK_NULL_HANDLE;
}
