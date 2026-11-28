/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: per-device state.
 *
 * Ownership:
 *   vk_setup.cpp    fills the "device description" part once at start-up and
 *                   creates/destroys the "logical device" part.
 *   vk_compute.cpp  creates/destroys the "program" part (pipeline and buffers).
 *   the cores       own coreID, sanityChecked and the run size members.
*/
#ifndef VK_CONTEXT_INCLUDED
#define VK_CONTEXT_INCLUDED

#include <vulkan/vulkan.h>

#include "cputypes.h"

enum
{
  VKCORE_NONE = 0,
  VKCORE_REF,
  VKCORE_TOTAL
};

// A buffer with its memory, mapped for the whole life of the core.
typedef struct
{
  VkBuffer        buffer;
  VkDeviceMemory  memory;
  u32            *mapped;
} vk_buffer_t;

typedef struct
{
  // --- device description (InitializeVulkan) ---
  bool              active;          // meets the client's requirements
  int               clientDeviceNo;  // client GPU index (for logs)
  VkPhysicalDevice  physDevice;
  u32               queueFamily;     // first queue family with compute
  u32               apiVersion;
  u32               vendorID;        // PCI vendor id
  u32               deviceID;        // PCI device id
  u32               deviceType;      // VkPhysicalDeviceType
  u32               driverID;        // VkDriverId
  char              deviceName[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];
  char              driverName[VK_MAX_DRIVER_NAME_SIZE];
  char              driverInfo[VK_MAX_DRIVER_INFO_SIZE];
  u32               maxGroupCount[3];     // maxComputeWorkGroupCount
  u32               maxGroupSize[3];      // maxComputeWorkGroupSize
  u32               maxGroupInvocations;  // maxComputeWorkGroupInvocations

  // --- logical device (VKCreateDevice / VKReleaseDevice) ---
  VkDevice          device;
  VkQueue           queue;
  VkCommandPool     cmdPool;
  VkCommandBuffer   cmdBuffer;
  VkFence           fence;
  bool              unusable;        // a kernel failed or never finished: the device
                                     // is abandoned, no further Vulkan calls on it

  // --- program (VKBuildProgram / VKReleaseProgram) ---
  u32               coreID;            // which core's program this is (set by the core)
  bool              sanityChecked;     // the core's start-up check passed on this device
  VkShaderModule         shader;
  VkDescriptorSetLayout  setLayout;
  VkPipelineLayout       pipeLayout;
  VkPipeline             pipeline;
  VkDescriptorPool       descPool;
  VkDescriptorSet        descSet;
  vk_buffer_t       constBuffer;
  vk_buffer_t       outBuffer;
  u32               localSize;         // work-group size the pipeline was built with
  u32               runSize;           // keys per kernel run (changes with timing)
  u32               runSizeMultiplier; // run size changes in steps of this
  u32               maxWorkSize;       // upper limit for runSize
} vk_context_t;

vk_context_t *vk_get_context(int device);

// Logical device, queue, command buffer and fence for one device (vk_setup.cpp).
bool VKCreateDevice(vk_context_t *cont);
void VKReleaseDevice(vk_context_t *cont);

// Error reporting (vk_setup.cpp). vk_diagnose() logs anything but VK_SUCCESS
// and returns the status unchanged; 'where' and 'cont' may be NULL.
const char *vkStrError(VkResult status);
VkResult vk_diagnose(VkResult status, const char *where, const vk_context_t *cont);

#endif // VK_CONTEXT_INCLUDED
