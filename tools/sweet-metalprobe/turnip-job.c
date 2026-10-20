/*
 * Stage 2 of the Metal probe: one Turnip compute job from inside the
 * process that loaded the plugin. Loads the ICD without a loader (like
 * tools/sweet-vkinfo), runs tools/sweet-vktest's compute shader
 * (out[i] = i*i + 7) over 64K uints, checks every word, destroys
 * everything (the connection's GPU VA window goes back to the kernel) and
 * returns a one-line summary. Never exits the host process: every failure
 * is a return.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include "compute_comp.h"
#include "turnip-job.h"

typedef PFN_vkVoidFunction (*PFN_icdGetInstanceProcAddr)(VkInstance, const char *);

#define FN(name) PFN_##name name = NULL
#define TRY(call) do { \
	VkResult r_ = (call); \
	if (r_ != VK_SUCCESS) { \
		snprintf(msg, len, "%s: %d", #call, r_); \
		goto out; \
	} \
} while (0)

static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int
sweet_turnip_job(const char *icd, char *msg, size_t len)
{
	const uint32_t words = 1u << 16;
	int ok = 0;
	VkInstance inst = VK_NULL_HANDLE;
	VkDevice dev = VK_NULL_HANDLE;
	VkBuffer buf = VK_NULL_HANDLE;
	VkDeviceMemory mem = VK_NULL_HANDLE;
	VkShaderModule sm = VK_NULL_HANDLE;
	VkDescriptorSetLayout dsl = VK_NULL_HANDLE;
	VkPipelineLayout pl = VK_NULL_HANDLE;
	VkPipeline pipe = VK_NULL_HANDLE;
	VkDescriptorPool dp = VK_NULL_HANDLE;
	VkCommandPool pool = VK_NULL_HANDLE;
	FN(vkCreateInstance); FN(vkDestroyInstance); FN(vkEnumeratePhysicalDevices);
	FN(vkGetPhysicalDeviceMemoryProperties); FN(vkGetPhysicalDeviceProperties); FN(vkCreateDevice);
	FN(vkGetDeviceProcAddr); FN(vkDestroyDevice); FN(vkGetDeviceQueue); FN(vkCreateBuffer);
	FN(vkDestroyBuffer); FN(vkGetBufferMemoryRequirements); FN(vkAllocateMemory); FN(vkFreeMemory);
	FN(vkBindBufferMemory); FN(vkMapMemory); FN(vkCreateShaderModule); FN(vkDestroyShaderModule);
	FN(vkCreateDescriptorSetLayout); FN(vkDestroyDescriptorSetLayout); FN(vkCreatePipelineLayout);
	FN(vkDestroyPipelineLayout); FN(vkCreateComputePipelines); FN(vkDestroyPipeline);
	FN(vkCreateDescriptorPool); FN(vkDestroyDescriptorPool); FN(vkAllocateDescriptorSets);
	FN(vkUpdateDescriptorSets); FN(vkCreateCommandPool); FN(vkDestroyCommandPool);
	FN(vkAllocateCommandBuffers); FN(vkBeginCommandBuffer); FN(vkEndCommandBuffer); FN(vkCmdBindPipeline);
	FN(vkCmdBindDescriptorSets); FN(vkCmdDispatch); FN(vkCmdPipelineBarrier); FN(vkQueueSubmit);
	FN(vkQueueWaitIdle);

	snprintf(msg, len, "no result");
	setenv("TU_DARWIN_SERVICE", "NativeAdrenoGpuPublished", 0);
	void *lib = dlopen(icd, RTLD_NOW | RTLD_LOCAL);
	PFN_icdGetInstanceProcAddr gipa = lib ? (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr") : NULL;
	if (!gipa) {
		snprintf(msg, len, "cannot load %s: %s", icd, dlerror());
		return 0;
	}
	vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "SweetMetalProbe",
		.apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	double t0 = now_ms();
	TRY(vkCreateInstance(&ici, NULL, &inst));
#define ILOAD(name) name = (PFN_##name)gipa(inst, #name)
	ILOAD(vkDestroyInstance); ILOAD(vkEnumeratePhysicalDevices); ILOAD(vkGetPhysicalDeviceMemoryProperties);
	ILOAD(vkGetPhysicalDeviceProperties); ILOAD(vkCreateDevice); ILOAD(vkGetDeviceProcAddr);
	uint32_t n = 1;
	VkPhysicalDevice pd;
	TRY(vkEnumeratePhysicalDevices(inst, &n, &pd));
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0,
		.queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	TRY(vkCreateDevice(pd, &dci, NULL, &dev));
#define DLOAD(name) name = (PFN_##name)vkGetDeviceProcAddr(dev, #name)
	DLOAD(vkDestroyDevice); DLOAD(vkGetDeviceQueue); DLOAD(vkCreateBuffer); DLOAD(vkDestroyBuffer);
	DLOAD(vkGetBufferMemoryRequirements); DLOAD(vkAllocateMemory); DLOAD(vkFreeMemory); DLOAD(vkBindBufferMemory);
	DLOAD(vkMapMemory); DLOAD(vkCreateShaderModule); DLOAD(vkDestroyShaderModule); DLOAD(vkCreateDescriptorSetLayout);
	DLOAD(vkDestroyDescriptorSetLayout); DLOAD(vkCreatePipelineLayout); DLOAD(vkDestroyPipelineLayout);
	DLOAD(vkCreateComputePipelines); DLOAD(vkDestroyPipeline); DLOAD(vkCreateDescriptorPool);
	DLOAD(vkDestroyDescriptorPool); DLOAD(vkAllocateDescriptorSets); DLOAD(vkUpdateDescriptorSets);
	DLOAD(vkCreateCommandPool); DLOAD(vkDestroyCommandPool); DLOAD(vkAllocateCommandBuffers);
	DLOAD(vkBeginCommandBuffer); DLOAD(vkEndCommandBuffer); DLOAD(vkCmdBindPipeline); DLOAD(vkCmdBindDescriptorSets);
	DLOAD(vkCmdDispatch); DLOAD(vkCmdPipelineBarrier); DLOAD(vkQueueSubmit); DLOAD(vkQueueWaitIdle);
	double t_dev = now_ms() - t0;

	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = words * 4ull,
		.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
	TRY(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, buf, &req);
	const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	uint32_t type = UINT32_MAX;
	for (uint32_t i = 0; i < mp.memoryTypeCount && type == UINT32_MAX; ++i) {
		if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) {
			type = i;
		}
	}
	if (type == UINT32_MAX) {
		snprintf(msg, len, "no host-visible memory type");
		goto out;
	}
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
		.memoryTypeIndex = type };
	TRY(vkAllocateMemory(dev, &mai, NULL, &mem));
	TRY(vkBindBufferMemory(dev, buf, mem, 0));
	uint32_t *words_out;
	TRY(vkMapMemory(dev, mem, 0, words * 4ull, 0, (void **)&words_out));
	memset(words_out, 0, words * 4ull);

	VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = sizeof(spv_compute_comp), .pCode = spv_compute_comp };
	TRY(vkCreateShaderModule(dev, &smci, NULL, &sm));
	VkDescriptorSetLayoutBinding b = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
	VkDescriptorSetLayoutCreateInfo dlci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &b };
	TRY(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &dsl };
	TRY(vkCreatePipelineLayout(dev, &plci, NULL, &pl));
	t0 = now_ms();
	VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		    .module = sm, .pName = "main" },
		.layout = pl };
	TRY(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));
	double t_compile = now_ms() - t0;
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
		.poolSizeCount = 1, .pPoolSizes = &ps };
	TRY(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
	VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet ds;
	TRY(vkAllocateDescriptorSets(dev, &dsai, &ds));
	VkDescriptorBufferInfo dbi = { buf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0,
		.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	TRY(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cb;
	TRY(vkAllocateCommandBuffers(dev, &cai, &cb));
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	TRY(vkBeginCommandBuffer(cb, &cbi));
	vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
	vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
	vkCmdDispatch(cb, words / 64, 1, 1);
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0,
	    NULL, 0, NULL);
	TRY(vkEndCommandBuffer(cb));
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
	t0 = now_ms();
	TRY(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
	TRY(vkQueueWaitIdle(q));
	double t_run = now_ms() - t0;
	uint32_t bad = 0;
	for (uint32_t i = 0; i < words; ++i) {
		bad += words_out[i] != i * i + 7u;
	}
	ok = bad == 0;
	snprintf(msg, len, "%s: compute %u words %s (%u bad), device %.1f ms, ir3 %.1f ms, run %.2f ms",
	    props.deviceName, words, ok ? "OK" : "WRONG", bad, t_dev, t_compile, t_run);
out:
	if (dev) {
		if (pool) vkDestroyCommandPool(dev, pool, NULL);
		if (dp) vkDestroyDescriptorPool(dev, dp, NULL);
		if (pipe) vkDestroyPipeline(dev, pipe, NULL);
		if (pl) vkDestroyPipelineLayout(dev, pl, NULL);
		if (dsl) vkDestroyDescriptorSetLayout(dev, dsl, NULL);
		if (sm) vkDestroyShaderModule(dev, sm, NULL);
		if (buf) vkDestroyBuffer(dev, buf, NULL);
		if (mem) vkFreeMemory(dev, mem, NULL);
		vkDestroyDevice(dev, NULL);
	}
	if (inst && vkDestroyInstance) {
		vkDestroyInstance(inst, NULL);
	}
	return ok;
}
