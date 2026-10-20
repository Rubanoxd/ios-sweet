/*
 * The Vulkan (Turnip) side of the SweetMetalProbe device (sweet-mtl-vk.h).
 * Every buffer is its own VkBuffer in host-visible coherent memory, mapped
 * for its lifetime (Metal's shared storage). A command list owns its pool,
 * so lists record on any thread without locks; only vkQueueSubmit, which
 * Vulkan wants externally synchronized, takes the queue lock. Each transfer
 * is followed by a full transfer/host barrier, so commands run in order.
 * vkCmdFillBuffer needs 4-byte aligned ranges; Metal fills bytes, so the
 * unaligned head and tail are copied from a small staging buffer instead.
 *
 * Kernels (Iridium's SPIR-V, sweet-iridium.h): Vulkan 1.3 with
 * bufferDeviceAddress, shaderInt64 and maintenance4 (LocalSizeId); every
 * buffer has a GPU address. A dispatch writes the addresses of its buffer
 * arguments into a small uniform buffer (descriptor set 0, binding 0) and
 * gets a pipeline specialized for its threadgroup size (cached per kernel).
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include "sweet-mtl-vk.h"

typedef PFN_vkVoidFunction (*PFN_icdGetInstanceProcAddr)(VkInstance, const char *);

#define FNS(X) \
	X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceMemoryProperties) \
	X(vkGetPhysicalDeviceProperties) X(vkCreateDevice) X(vkGetDeviceProcAddr)
#define DFNS(X) \
	X(vkGetDeviceQueue) X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) \
	X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory) X(vkMapMemory) X(vkCreateCommandPool) \
	X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
	X(vkCmdFillBuffer) X(vkCmdCopyBuffer) X(vkCmdPipelineBarrier) X(vkQueueSubmit) X(vkCreateFence) \
	X(vkDestroyFence) X(vkWaitForFences) X(vkGetBufferDeviceAddress) X(vkCreateShaderModule) \
	X(vkDestroyShaderModule) X(vkCreateDescriptorSetLayout) X(vkCreatePipelineLayout) \
	X(vkCreateComputePipelines) X(vkDestroyPipeline) X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) \
	X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) \
	X(vkCmdDispatch)
#define DECL(name) static PFN_##name name;
FNS(DECL)
DFNS(DECL)
static PFN_vkCreateInstance vkCreateInstance;

static VkInstance sInst;
static VkDevice sDev;
static VkQueue sQueue;
static VkPhysicalDeviceMemoryProperties sMem;
static VkPhysicalDeviceProperties sProps;
static VkDescriptorSetLayout sArgsLayout;
static VkPipelineLayout sKernelLayout;
static pthread_mutex_t sQueueLock = PTHREAD_MUTEX_INITIALIZER;
static __thread char sError[256];

struct smv_buffer {
	VkBuffer buf;
	VkDeviceMemory mem;
	void *map;
	uint64_t length;
	uint64_t address;       /* GPU address (buffer device address) */
};

enum { KERNEL_SIZES = 8, CMD_SETS = 64 };

struct smv_kernel {
	VkShaderModule module;
	char entry[128];
	pthread_mutex_t lock;
	struct {
		uint32_t local[3];
		VkPipeline pipe;
	} sized[KERNEL_SIZES];
};

enum { STAGING_BYTES = 4096 };

struct smv_cmd {
	VkCommandPool pool;
	VkCommandBuffer cb;
	smv_buffer *staging;    /* lazily: byte patterns for unaligned fills */
	uint32_t staging_used;
	int in_flight;          /* a wait timed out: never freed */
	VkDescriptorPool sets;  /* lazily, for dispatch arguments */
	smv_buffer **args;      /* one small uniform buffer per dispatch */
	unsigned nargs;
};

static int
fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(sError, sizeof(sError), fmt, ap);
	va_end(ap);
	return 0;
}

const char *
smv_error(void)
{
	return sError;
}

#define TRY(call) do { \
	VkResult r_ = (call); \
	if (r_ != VK_SUCCESS) { \
		return fail("%s: %d", #call, r_); \
	} \
} while (0)

int
smv_open(const char *icd, char *name, size_t len)
{
	if (sDev) {
		snprintf(name, len, "%s", sProps.deviceName);
		return 1;
	}
	setenv("TU_DARWIN_SERVICE", "NativeAdrenoGpuPublished", 0);
	void *lib = dlopen(icd, RTLD_NOW | RTLD_LOCAL);
	PFN_icdGetInstanceProcAddr gipa = lib ? (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr") : NULL;
	if (!gipa) {
		return fail("cannot load %s: %s", icd, dlerror());
	}
	vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "SweetMetal",
		.apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	TRY(vkCreateInstance(&ici, NULL, &sInst));
#define ILOAD(n) n = (PFN_##n)gipa(sInst, #n);
	FNS(ILOAD)
	uint32_t n = 1;
	VkPhysicalDevice pd;
	TRY(vkEnumeratePhysicalDevices(sInst, &n, &pd));
	vkGetPhysicalDeviceProperties(pd, &sProps);
	vkGetPhysicalDeviceMemoryProperties(pd, &sMem);
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0,
		.queueCount = 1, .pQueuePriorities = &prio };
	VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.maintenance4 = VK_TRUE };
	VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &f13, .bufferDeviceAddress = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12,
		.features = { .shaderInt64 = VK_TRUE } };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	TRY(vkCreateDevice(pd, &dci, NULL, &dev));
#define DLOAD(n) n = (PFN_##n)vkGetDeviceProcAddr(dev, #n);
	DFNS(DLOAD)
	vkGetDeviceQueue(dev, 0, 0, &sQueue);
	VkDescriptorSetLayoutBinding arg = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
	VkDescriptorSetLayoutCreateInfo dlci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &arg };
	TRY(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &sArgsLayout));
	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &sArgsLayout };
	TRY(vkCreatePipelineLayout(dev, &plci, NULL, &sKernelLayout));
	sDev = dev;
	snprintf(name, len, "%s", sProps.deviceName);
	return 1;
}

uint64_t
smv_max_buffer_length(void)
{
	/* One BO comes from the kernel's contiguous DDR pool; stay well inside it. */
	return 256ull << 20;
}

smv_buffer *
smv_buffer_new(uint64_t length, const void *bytes)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	if (length == 0 || length > smv_max_buffer_length()) {
		fail("buffer length %llu", (unsigned long long)length);
		return NULL;
	}
	smv_buffer *b = calloc(1, sizeof(*b));
	if (!b) {
		fail("out of memory");
		return NULL;
	}
	b->length = length;
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = length,
		.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
		    VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
		    VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
		    VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT };
	VkResult r = vkCreateBuffer(sDev, &bci, NULL, &b->buf);
	if (r != VK_SUCCESS) {
		fail("vkCreateBuffer: %d", r);
		goto bad;
	}
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(sDev, b->buf, &req);
	const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	uint32_t type = UINT32_MAX;
	for (uint32_t i = 0; i < sMem.memoryTypeCount && type == UINT32_MAX; ++i) {
		if ((req.memoryTypeBits & (1u << i)) && (sMem.memoryTypes[i].propertyFlags & want) == want) {
			type = i;
		}
	}
	if (type == UINT32_MAX) {
		fail("no host-visible coherent memory type");
		goto bad;
	}
	VkMemoryAllocateFlagsInfo flags = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
		.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT };
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &flags,
		.allocationSize = req.size, .memoryTypeIndex = type };
	if ((r = vkAllocateMemory(sDev, &mai, NULL, &b->mem)) != VK_SUCCESS) {
		fail("vkAllocateMemory %llu: %d", (unsigned long long)req.size, r);
		goto bad;
	}
	if ((r = vkBindBufferMemory(sDev, b->buf, b->mem, 0)) != VK_SUCCESS ||
	    (r = vkMapMemory(sDev, b->mem, 0, VK_WHOLE_SIZE, 0, &b->map)) != VK_SUCCESS) {
		fail("bind/map: %d", r);
		goto bad;
	}
	VkBufferDeviceAddressInfo bai = { .sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = b->buf };
	b->address = vkGetBufferDeviceAddress(sDev, &bai);
	if (bytes) {
		memcpy(b->map, bytes, length);
	} else {
		memset(b->map, 0, length);      /* Metal hands out zeroed buffers */
	}
	return b;
bad:
	smv_buffer_free(b);
	return NULL;
}

void
smv_buffer_free(smv_buffer *b)
{
	if (!b) {
		return;
	}
	if (b->buf) {
		vkDestroyBuffer(sDev, b->buf, NULL);
	}
	if (b->mem) {
		vkFreeMemory(sDev, b->mem, NULL);
	}
	free(b);
}

void *
smv_buffer_contents(smv_buffer *b)
{
	return b->map;
}

uint64_t
smv_buffer_length(smv_buffer *b)
{
	return b->length;
}

uint64_t
smv_buffer_address(smv_buffer *b)
{
	return b->address;
}

smv_kernel *
smv_kernel_new(const void *spirv, size_t bytes, const char *entry)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	smv_kernel *k = calloc(1, sizeof(*k));
	if (!k) {
		fail("out of memory");
		return NULL;
	}
	snprintf(k->entry, sizeof(k->entry), "%s", entry);
	pthread_mutex_init(&k->lock, NULL);
	VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = bytes,
		.pCode = spirv };
	VkResult r = vkCreateShaderModule(sDev, &smci, NULL, &k->module);
	if (r != VK_SUCCESS) {
		fail("vkCreateShaderModule: %d", r);
		free(k);
		return NULL;
	}
	return k;
}

void
smv_kernel_free(smv_kernel *k)
{
	if (!k) {
		return;
	}
	for (unsigned i = 0; i < KERNEL_SIZES; ++i) {
		if (k->sized[i].pipe) {
			vkDestroyPipeline(sDev, k->sized[i].pipe, NULL);
		}
	}
	vkDestroyShaderModule(sDev, k->module, NULL);
	free(k);
}

/* The pipeline for one threadgroup size: Iridium reads it from
 * specialization constants 0..2 (LocalSizeId). */
static VkPipeline
kernel_pipeline(smv_kernel *k, const uint32_t local[3])
{
	VkPipeline pipe = VK_NULL_HANDLE;
	pthread_mutex_lock(&k->lock);
	unsigned i;
	for (i = 0; i < KERNEL_SIZES && k->sized[i].pipe; ++i) {
		if (!memcmp(k->sized[i].local, local, sizeof(k->sized[i].local))) {
			pipe = k->sized[i].pipe;
			break;
		}
	}
	if (!pipe) {
		VkSpecializationMapEntry map[3] = { { 0, 0, 4 }, { 1, 4, 4 }, { 2, 8, 4 } };
		VkSpecializationInfo spec = { 3, map, 12, local };
		VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
			.stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			    .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = k->module, .pName = k->entry,
			    .pSpecializationInfo = &spec },
			.layout = sKernelLayout };
		VkResult r = vkCreateComputePipelines(sDev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe);
		if (r != VK_SUCCESS) {
			fail("vkCreateComputePipelines %ux%ux%u: %d", local[0], local[1], local[2], r);
			pipe = VK_NULL_HANDLE;
		} else if (i < KERNEL_SIZES) {
			memcpy(k->sized[i].local, local, sizeof(k->sized[i].local));
			k->sized[i].pipe = pipe;
		} else {
			fail("more than %d threadgroup sizes for one kernel", KERNEL_SIZES);
			vkDestroyPipeline(sDev, pipe, NULL);
			pipe = VK_NULL_HANDLE;
		}
	}
	pthread_mutex_unlock(&k->lock);
	return pipe;
}

smv_cmd *
smv_cmd_new(void)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	smv_cmd *c = calloc(1, sizeof(*c));
	if (!c) {
		fail("out of memory");
		return NULL;
	}
	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0,
		.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT };
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	VkResult r = vkCreateCommandPool(sDev, &pci, NULL, &c->pool);
	if (r == VK_SUCCESS) {
		cai.commandPool = c->pool;
		r = vkAllocateCommandBuffers(sDev, &cai, &c->cb);
	}
	if (r == VK_SUCCESS) {
		r = vkBeginCommandBuffer(c->cb, &cbi);
	}
	if (r != VK_SUCCESS) {
		fail("command list: %d", r);
		smv_cmd_free(c);
		return NULL;
	}
	return c;
}

static void
barrier(smv_cmd *c)
{
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
	    VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
}

static int
in_range(smv_buffer *b, uint64_t offset, uint64_t length)
{
	return b && offset <= b->length && length <= b->length - offset;
}

int
smv_cmd_fill(smv_cmd *c, smv_buffer *b, uint64_t offset, uint64_t length, uint8_t value)
{
	if (!in_range(b, offset, length)) {
		return fail("fill out of range");
	}
	if (length == 0) {
		return 1;
	}
	uint64_t head = (4 - (offset & 3)) & 3, end = offset + length;
	if (head > length) {
		head = length;
	}
	uint64_t mid_end = (offset + head) + ((end - offset - head) & ~3ull), tail = end - mid_end;
	if (head || tail) {
		if (!c->staging && !(c->staging = smv_buffer_new(STAGING_BYTES, NULL))) {
			return 0;
		}
		if (c->staging_used + 8 > STAGING_BYTES) {
			return fail("too many unaligned fills in one command buffer");
		}
		uint64_t at = c->staging_used;
		memset((char *)c->staging->map + at, value, 8);
		c->staging_used += 8;
		if (head) {
			VkBufferCopy r = { at, offset, head };
			vkCmdCopyBuffer(c->cb, c->staging->buf, b->buf, 1, &r);
		}
		if (tail) {
			VkBufferCopy r = { at, mid_end, tail };
			vkCmdCopyBuffer(c->cb, c->staging->buf, b->buf, 1, &r);
		}
	}
	if (mid_end > offset + head) {
		vkCmdFillBuffer(c->cb, b->buf, offset + head, mid_end - offset - head, value * 0x01010101u);
	}
	barrier(c);
	return 1;
}

int
smv_cmd_copy(smv_cmd *c, smv_buffer *src, uint64_t src_offset, smv_buffer *dst, uint64_t dst_offset, uint64_t length)
{
	if (!in_range(src, src_offset, length) || !in_range(dst, dst_offset, length)) {
		return fail("copy out of range");
	}
	if (length) {
		VkBufferCopy r = { src_offset, dst_offset, length };
		vkCmdCopyBuffer(c->cb, src->buf, dst->buf, 1, &r);
		barrier(c);
	}
	return 1;
}

int
smv_cmd_dispatch(smv_cmd *c, smv_kernel *k, const uint64_t *addresses, unsigned count, const uint32_t groups[3],
    const uint32_t local[3])
{
	VkPipeline pipe = kernel_pipeline(k, local);
	if (!pipe) {
		return 0;
	}
	if (!c->sets) {
		VkDescriptorPoolSize size = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, CMD_SETS };
		VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
			.maxSets = CMD_SETS, .poolSizeCount = 1, .pPoolSizes = &size };
		TRY(vkCreateDescriptorPool(sDev, &dpci, NULL, &c->sets));
	}
	if (c->nargs == CMD_SETS) {
		return fail("more than %d dispatches in one command buffer", CMD_SETS);
	}
	smv_buffer *args = smv_buffer_new(count ? count * 8ull : 8, count ? addresses : NULL);
	if (!args) {
		return 0;
	}
	smv_buffer **list = realloc(c->args, (c->nargs + 1) * sizeof(*list));
	if (!list) {
		smv_buffer_free(args);
		return fail("out of memory");
	}
	c->args = list;
	c->args[c->nargs++] = args;
	VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = c->sets, .descriptorSetCount = 1, .pSetLayouts = &sArgsLayout };
	VkDescriptorSet set;
	TRY(vkAllocateDescriptorSets(sDev, &dsai, &set));
	VkDescriptorBufferInfo dbi = { args->buf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0,
		.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(sDev, 1, &w, 0, NULL);
	vkCmdBindPipeline(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
	vkCmdBindDescriptorSets(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, sKernelLayout, 0, 1, &set, 0, NULL);
	vkCmdDispatch(c->cb, groups[0], groups[1], groups[2]);
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
		    VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
	    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0, 1,
	    &mb, 0, NULL, 0, NULL);
	return 1;
}

int
smv_cmd_run(smv_cmd *c, uint32_t timeout_ms)
{
	TRY(vkEndCommandBuffer(c->cb));
	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	TRY(vkCreateFence(sDev, &fci, NULL, &fence));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c->cb };
	pthread_mutex_lock(&sQueueLock);
	VkResult r = vkQueueSubmit(sQueue, 1, &si, fence);
	pthread_mutex_unlock(&sQueueLock);
	if (r != VK_SUCCESS) {
		vkDestroyFence(sDev, fence, NULL);
		return fail("vkQueueSubmit: %d", r);
	}
	r = vkWaitForFences(sDev, 1, &fence, VK_TRUE, timeout_ms * 1000000ull);
	if (r != VK_SUCCESS) {
		/* The GPU may still use the list and its buffers: keep them. */
		c->in_flight = 1;
		return fail("vkWaitForFences: %d%s", r, r == VK_TIMEOUT ? " (GPU timeout)" : "");
	}
	vkDestroyFence(sDev, fence, NULL);
	return 1;
}

void
smv_cmd_free(smv_cmd *c)
{
	if (!c || c->in_flight) {
		return;
	}
	if (c->pool) {
		vkDestroyCommandPool(sDev, c->pool, NULL);      /* frees c->cb */
	}
	smv_buffer_free(c->staging);
	if (c->sets) {
		vkDestroyDescriptorPool(sDev, c->sets, NULL);
	}
	for (unsigned i = 0; i < c->nargs; ++i) {
		smv_buffer_free(c->args[i]);
	}
	free(c->args);
	free(c);
}
