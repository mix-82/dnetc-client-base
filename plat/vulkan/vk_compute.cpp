/*
 * Copyright distributed.net 2026 - All Rights Reserved
 * For use in distributed.net projects only.
 * Any other distribution or use of this source violates copyright.
 *
 * Vulkan compute client: one compute program per device, and running it.
*/

#include <string.h>

#include "vk_compute.h"

#include "logstuff.h"

// A work item number must fit in 31 bits; cores use the top bit as a flag.
#define VK_MAX_ITEMS 0x40000000u

// A kernel is sized to run for about 10 ms. One that has not finished after
// this many seconds is treated as a failure of the device.
#ifndef VK_KERNEL_TIMEOUT_SECONDS
#define VK_KERNEL_TIMEOUT_SECONDS 30
#endif

// -----------------------------------------------------------------------

static bool CreateMappedBuffer(vk_context_t *cont, u32 bytes, VkBufferUsageFlags usage,
                               const char *what, vk_buffer_t *buf)
{
  VkBufferCreateInfo bufferInfo;

  memset(&bufferInfo, 0, sizeof(bufferInfo));
  bufferInfo.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  bufferInfo.size        = bytes;
  bufferInfo.usage       = usage;
  bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

  VkResult status = vkCreateBuffer(cont->device, &bufferInfo, NULL, &buf->buffer);
  if (vk_diagnose(status, what, cont) != VK_SUCCESS)
  {
    buf->buffer = VK_NULL_HANDLE;
    return false;
  }

  // Memory the host can map, and that needs no explicit flush or invalidate.
  const VkMemoryPropertyFlags wanted =
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  VkMemoryRequirements req;
  VkPhysicalDeviceMemoryProperties memProps;
  u32 typeIndex = 0;
  bool found = false;

  vkGetBufferMemoryRequirements(cont->device, buf->buffer, &req);
  vkGetPhysicalDeviceMemoryProperties(cont->physDevice, &memProps);
  for (u32 i = 0; i < memProps.memoryTypeCount && !found; i++)
  {
    if ((req.memoryTypeBits & (1u << i)) != 0 &&
        (memProps.memoryTypes[i].propertyFlags & wanted) == wanted)
    {
      typeIndex = i;
      found = true;
    }
  }
  if (!found)
  {
    Log("Error %s on device %d: no host-visible memory type\n", what, cont->clientDeviceNo);
    return false;
  }

  VkMemoryAllocateInfo allocInfo;

  memset(&allocInfo, 0, sizeof(allocInfo));
  allocInfo.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  allocInfo.allocationSize  = req.size;
  allocInfo.memoryTypeIndex = typeIndex;
  status = vkAllocateMemory(cont->device, &allocInfo, NULL, &buf->memory);
  if (vk_diagnose(status, what, cont) != VK_SUCCESS)
  {
    buf->memory = VK_NULL_HANDLE;
    return false;
  }

  status = vkBindBufferMemory(cont->device, buf->buffer, buf->memory, 0);
  if (vk_diagnose(status, what, cont) != VK_SUCCESS)
    return false;

  void *ptr = NULL;
  status = vkMapMemory(cont->device, buf->memory, 0, VK_WHOLE_SIZE, 0, &ptr);
  if (vk_diagnose(status, what, cont) != VK_SUCCESS)
    return false;
  buf->mapped = (u32 *) ptr;
  memset(buf->mapped, 0, bytes);
  return true;
}

static void ReleaseMappedBuffer(vk_context_t *cont, vk_buffer_t *buf)
{
  if (buf->buffer != VK_NULL_HANDLE)
    vkDestroyBuffer(cont->device, buf->buffer, NULL);
  if (buf->memory != VK_NULL_HANDLE)
    vkFreeMemory(cont->device, buf->memory, NULL);  // unmaps as well
  buf->buffer = VK_NULL_HANDLE;
  buf->memory = VK_NULL_HANDLE;
  buf->mapped = NULL;
}

// -----------------------------------------------------------------------

void VKReleaseProgram(vk_context_t *cont)
{
  // An unusable device may still be running a kernel, and waiting for it
  // could block forever. Its objects are abandoned, not destroyed.
  if (cont->device != VK_NULL_HANDLE && !cont->unusable)
  {
    vkDeviceWaitIdle(cont->device);
    if (cont->pipeline != VK_NULL_HANDLE)
      vkDestroyPipeline(cont->device, cont->pipeline, NULL);
    if (cont->pipeLayout != VK_NULL_HANDLE)
      vkDestroyPipelineLayout(cont->device, cont->pipeLayout, NULL);
    if (cont->descPool != VK_NULL_HANDLE)
      vkDestroyDescriptorPool(cont->device, cont->descPool, NULL);  // frees descSet too
    if (cont->setLayout != VK_NULL_HANDLE)
      vkDestroyDescriptorSetLayout(cont->device, cont->setLayout, NULL);
    if (cont->shader != VK_NULL_HANDLE)
      vkDestroyShaderModule(cont->device, cont->shader, NULL);
    ReleaseMappedBuffer(cont, &cont->constBuffer);
    ReleaseMappedBuffer(cont, &cont->outBuffer);
  }
  memset(&cont->constBuffer, 0, sizeof(cont->constBuffer));
  memset(&cont->outBuffer, 0, sizeof(cont->outBuffer));
  cont->pipeline   = VK_NULL_HANDLE;
  cont->pipeLayout = VK_NULL_HANDLE;
  cont->descPool   = VK_NULL_HANDLE;
  cont->descSet    = VK_NULL_HANDLE;
  cont->setLayout  = VK_NULL_HANDLE;
  cont->shader     = VK_NULL_HANDLE;
  cont->coreID     = VKCORE_NONE;
  cont->localSize  = 0;
  cont->sanityChecked = false;
}

bool VKBuildProgram(vk_context_t *cont, const u32 *spirv, size_t spirvBytes,
                    u32 constBytes, u32 outBytes, u32 localSize)
{
  if (cont->unusable)
  {
    Log("Device %d cannot be used after the earlier failure\n", cont->clientDeviceNo);
    return false;
  }
  VKReleaseProgram(cont);
  if (!VKCreateDevice(cont))
    return false;

  if (localSize == 0 || localSize > cont->maxGroupSize[0] || localSize > cont->maxGroupInvocations)
  {
    Log("Work-group size %u is not supported by device %d (limits: %u per group, %u work items)\n",
        localSize, cont->clientDeviceNo, cont->maxGroupSize[0], cont->maxGroupInvocations);
    return false;
  }

  VkResult status;
  bool ok;

  ok = CreateMappedBuffer(cont, constBytes, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                          "creating constants buffer", &cont->constBuffer);
  if (ok)
  {
    ok = CreateMappedBuffer(cont, outBytes, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                            "creating output buffer", &cont->outBuffer);
  }

  if (ok)
  {
    VkShaderModuleCreateInfo shaderInfo;

    memset(&shaderInfo, 0, sizeof(shaderInfo));
    shaderInfo.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    shaderInfo.codeSize = spirvBytes;
    shaderInfo.pCode    = spirv;
    status = vkCreateShaderModule(cont->device, &shaderInfo, NULL, &cont->shader);
    if (vk_diagnose(status, "loading shader", cont) != VK_SUCCESS)
    {
      cont->shader = VK_NULL_HANDLE;
      ok = false;
    }
  }

  if (ok)
  {
    VkDescriptorSetLayoutBinding bindings[2];
    VkDescriptorSetLayoutCreateInfo layoutInfo;

    memset(bindings, 0, sizeof(bindings));
    bindings[0].binding         = 0;
    bindings[0].descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;
    bindings[1].binding         = 1;
    bindings[1].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    bindings[1].descriptorCount = 1;
    bindings[1].stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT;
    memset(&layoutInfo, 0, sizeof(layoutInfo));
    layoutInfo.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = 2;
    layoutInfo.pBindings    = bindings;
    status = vkCreateDescriptorSetLayout(cont->device, &layoutInfo, NULL, &cont->setLayout);
    if (vk_diagnose(status, "creating descriptor set layout", cont) != VK_SUCCESS)
    {
      cont->setLayout = VK_NULL_HANDLE;
      ok = false;
    }
  }

  if (ok)
  {
    VkPipelineLayoutCreateInfo pipeLayoutInfo;

    memset(&pipeLayoutInfo, 0, sizeof(pipeLayoutInfo));
    pipeLayoutInfo.sType          = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeLayoutInfo.setLayoutCount = 1;
    pipeLayoutInfo.pSetLayouts    = &cont->setLayout;
    status = vkCreatePipelineLayout(cont->device, &pipeLayoutInfo, NULL, &cont->pipeLayout);
    if (vk_diagnose(status, "creating pipeline layout", cont) != VK_SUCCESS)
    {
      cont->pipeLayout = VK_NULL_HANDLE;
      ok = false;
    }
  }

  if (ok)
  {
    // constant_id 0 = work-group size. The driver compiles the shader here.
    VkSpecializationMapEntry specEntry;
    VkSpecializationInfo specInfo;
    VkComputePipelineCreateInfo pipeInfo;

    specEntry.constantID = 0;
    specEntry.offset     = 0;
    specEntry.size       = sizeof(u32);
    specInfo.mapEntryCount = 1;
    specInfo.pMapEntries   = &specEntry;
    specInfo.dataSize      = sizeof(u32);
    specInfo.pData         = &localSize;
    memset(&pipeInfo, 0, sizeof(pipeInfo));
    pipeInfo.sType                     = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipeInfo.stage.sType               = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    pipeInfo.stage.stage               = VK_SHADER_STAGE_COMPUTE_BIT;
    pipeInfo.stage.module              = cont->shader;
    pipeInfo.stage.pName               = "main";
    pipeInfo.stage.pSpecializationInfo = &specInfo;
    pipeInfo.layout                    = cont->pipeLayout;
    status = vkCreateComputePipelines(cont->device, VK_NULL_HANDLE, 1, &pipeInfo, NULL, &cont->pipeline);
    if (vk_diagnose(status, "building shader", cont) != VK_SUCCESS)
    {
      cont->pipeline = VK_NULL_HANDLE;
      ok = false;
    }
  }

  if (ok)
  {
    VkDescriptorPoolSize poolSizes[2];
    VkDescriptorPoolCreateInfo poolInfo;

    poolSizes[0].type            = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[0].descriptorCount = 1;
    poolSizes[1].type            = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    poolSizes[1].descriptorCount = 1;
    memset(&poolInfo, 0, sizeof(poolInfo));
    poolInfo.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.maxSets       = 1;
    poolInfo.poolSizeCount = 2;
    poolInfo.pPoolSizes    = poolSizes;
    status = vkCreateDescriptorPool(cont->device, &poolInfo, NULL, &cont->descPool);
    if (vk_diagnose(status, "creating descriptor pool", cont) != VK_SUCCESS)
    {
      cont->descPool = VK_NULL_HANDLE;
      ok = false;
    }
  }

  if (ok)
  {
    VkDescriptorSetAllocateInfo setInfo;

    memset(&setInfo, 0, sizeof(setInfo));
    setInfo.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    setInfo.descriptorPool     = cont->descPool;
    setInfo.descriptorSetCount = 1;
    setInfo.pSetLayouts        = &cont->setLayout;
    status = vkAllocateDescriptorSets(cont->device, &setInfo, &cont->descSet);
    if (vk_diagnose(status, "creating descriptor set", cont) != VK_SUCCESS)
    {
      cont->descSet = VK_NULL_HANDLE;
      ok = false;
    }
  }

  if (ok)
  {
    VkDescriptorBufferInfo bufferInfos[2];
    VkWriteDescriptorSet writes[2];

    bufferInfos[0].buffer = cont->constBuffer.buffer;
    bufferInfos[0].offset = 0;
    bufferInfos[0].range  = VK_WHOLE_SIZE;
    bufferInfos[1].buffer = cont->outBuffer.buffer;
    bufferInfos[1].offset = 0;
    bufferInfos[1].range  = VK_WHOLE_SIZE;
    memset(writes, 0, sizeof(writes));
    writes[0].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[0].dstSet          = cont->descSet;
    writes[0].dstBinding      = 0;
    writes[0].descriptorCount = 1;
    writes[0].descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    writes[0].pBufferInfo     = &bufferInfos[0];
    writes[1].sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[1].dstSet          = cont->descSet;
    writes[1].dstBinding      = 1;
    writes[1].descriptorCount = 1;
    writes[1].descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[1].pBufferInfo     = &bufferInfos[1];
    vkUpdateDescriptorSets(cont->device, 2, writes, 0, NULL);
  }

  if (!ok)
  {
    VKReleaseProgram(cont);
    return false;
  }
  cont->localSize = localSize;
  return true;
}

// -----------------------------------------------------------------------

u32 VKMaxDispatchItems(const vk_context_t *cont)
{
  // 64-bit arithmetic: the device limits can be as large as 2^32 - 1 each.
  unsigned long long limit =
      (unsigned long long) cont->maxGroupCount[0] * cont->maxGroupCount[1] * cont->localSize;
  if (limit > VK_MAX_ITEMS)
    limit = VK_MAX_ITEMS;
  return (u32) limit;
}

bool VKDispatchSize(const vk_context_t *cont, u32 items, u32 *groupsX, u32 *groupsY)
{
  if (items == 0 || cont->localSize == 0 || items > VKMaxDispatchItems(cont))
    return false;

  u32 groups = items / cont->localSize;
  if (items % cont->localSize != 0)
    groups++;

  u32 rows = groups / cont->maxGroupCount[0];
  if (groups % cont->maxGroupCount[0] != 0)
    rows++;

  // Spread the groups evenly over the rows, to waste as few as possible.
  u32 perRow = groups / rows;
  if (groups % rows != 0)
    perRow++;

  *groupsX = perRow;
  *groupsY = rows;
  return true;
}

// Records, submits and waits. Does not touch cont->unusable.
static VkResult RunKernel(vk_context_t *cont, u32 groupsX, u32 groupsY)
{
  VkCommandBufferBeginInfo beginInfo;
  VkMemoryBarrier barrier;
  VkSubmitInfo submitInfo;

  // The work-group counts are part of the command buffer, so it is recorded
  // again for every run. Beginning it resets the previous contents.
  memset(&beginInfo, 0, sizeof(beginInfo));
  beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  VkResult status = vkBeginCommandBuffer(cont->cmdBuffer, &beginInfo);
  if (status != VK_SUCCESS)
    return status;
  vkCmdBindPipeline(cont->cmdBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, cont->pipeline);
  vkCmdBindDescriptorSets(cont->cmdBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, cont->pipeLayout,
                          0, 1, &cont->descSet, 0, NULL);
  vkCmdDispatch(cont->cmdBuffer, groupsX, groupsY, 1);

  // Make what the shader wrote visible to the host. Waiting on the fence
  // alone does not guarantee that, not even for host-coherent memory.
  memset(&barrier, 0, sizeof(barrier));
  barrier.sType         = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
  barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
  vkCmdPipelineBarrier(cont->cmdBuffer, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                       0, 1, &barrier, 0, NULL, 0, NULL);

  status = vkEndCommandBuffer(cont->cmdBuffer);
  if (status != VK_SUCCESS)
    return status;

  memset(&submitInfo, 0, sizeof(submitInfo));
  submitInfo.sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO;
  submitInfo.commandBufferCount = 1;
  submitInfo.pCommandBuffers    = &cont->cmdBuffer;
  status = vkQueueSubmit(cont->queue, 1, &submitInfo, cont->fence);
  if (status != VK_SUCCESS)
    return status;

  // Wait for the kernel. The wait blocks; the one-second slices only bound
  // how long a broken device can hold the thread.
  status = VK_TIMEOUT;
  for (int waited = 0; waited < VK_KERNEL_TIMEOUT_SECONDS && status == VK_TIMEOUT; waited++)
    status = vkWaitForFences(cont->device, 1, &cont->fence, VK_TRUE, 1000000000ull);
  if (status != VK_SUCCESS)
    return status;

  return vkResetFences(cont->device, 1, &cont->fence);
}

VkResult VKRunKernel(vk_context_t *cont, u32 groupsX, u32 groupsY)
{
  if (cont->unusable)
    return VK_ERROR_DEVICE_LOST;

  // After any failure the command buffer may still be pending and the fence
  // state is unknown, so the device must not be used again.
  VkResult status = RunKernel(cont, groupsX, groupsY);
  if (status != VK_SUCCESS)
    cont->unusable = true;
  return status;
}
