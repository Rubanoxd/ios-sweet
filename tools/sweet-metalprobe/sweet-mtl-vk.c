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
 *
 * Rendering: textures are 2D images that live in VK_IMAGE_LAYOUT_GENERAL
 * from creation on (correct for every use here; tighter layouts later),
 * render passes are dynamic rendering, graphics pipelines take viewport,
 * scissor, topology, cull mode and front face as dynamic state. Iridium
 * gives each stage its own descriptor set (compute and vertex 0, fragment
 * 1): a uniform buffer of buffer addresses at binding 0 when the function
 * takes buffers, then sampled images and samplers at their bindings. Each
 * kernel and pipeline builds its set layouts from the function's bindings
 * (struct smv_stage). Metal's y axis points up in clip space: the viewport
 * is flipped (negative height), as Indium does.
 *
 * Framebuffer reads ([[color(n)]] in a fragment function, Metal's
 * programmable blending): input attachments on the pass's own color
 * attachments through VK_KHR_dynamic_rendering_local_read, with
 * VK_EXT_rasterization_order_attachment_access on such pipelines and a
 * by-region barrier before each of their draws, for Metal's per-pixel
 * ordering.
 *
 * IOSurface textures: the surface's own pages (mapped in this process) are
 * imported with VK_EXT_external_memory_host (the kernel pins them, Turnip
 * maps them into the GPU) as a linear image with the surface's row pitch
 * (VK_EXT_image_drm_format_modifier, DRM_FORMAT_MOD_LINEAR, explicit
 * layout). The GPU does not snoop the CPU caches: the Metal layer cleans
 * and invalidates the surface around every command buffer that uses it.
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
	X(vkCmdDispatch) X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
	X(vkCreateImageView) X(vkDestroyImageView) X(vkCmdCopyBufferToImage) X(vkCmdCopyImageToBuffer) \
	X(vkCreateGraphicsPipelines) X(vkCmdBeginRendering) X(vkCmdEndRendering) X(vkCmdDraw) \
	X(vkCmdSetViewportWithCount) X(vkCmdSetScissorWithCount) X(vkCmdSetPrimitiveTopology) \
	X(vkCmdSetCullMode) X(vkCmdSetFrontFace) X(vkCreateSampler) X(vkDestroySampler) \
	X(vkDestroyDescriptorSetLayout) X(vkDestroyPipelineLayout) X(vkGetMemoryHostPointerPropertiesEXT)
#define DECL(name) static PFN_##name name;
FNS(DECL)
DFNS(DECL)
static PFN_vkCreateInstance vkCreateInstance;

static VkInstance sInst;
static VkDevice sDev;
static VkQueue sQueue;
static VkPhysicalDeviceMemoryProperties sMem;
static VkPhysicalDeviceProperties sProps;
static pthread_mutex_t sQueueLock = PTHREAD_MUTEX_INITIALIZER;
static __thread char sError[256];

struct smv_buffer {
	VkBuffer buf;
	VkDeviceMemory mem;
	void *map;
	uint64_t length;
	uint64_t address;       /* GPU address (buffer device address) */
};

enum { KERNEL_SIZES = 8, CMD_SETS = 256 };

struct smv_texture {
	VkImage image;
	VkImageView view;
	VkDeviceMemory mem;
	VkFormat format;
	uint32_t width, height, texel;
};

struct smv_sampler {
	VkSampler sampler;
};

/* One stage's descriptor set layout, from Iridium's bindings. */
struct stage_layout {
	VkDescriptorSetLayout layout;
	int ubo;                /* binding 0 holds the buffer addresses */
	int reads_targets;      /* has input attachments (framebuffer reads) */
};

struct smv_render_pipeline {
	VkPipeline pipe[3];     /* point, line and triangle topology classes */
	VkShaderModule vs, fs;
	struct stage_layout stage[2];
	VkPipelineLayout layout;
};

struct smv_kernel {
	struct stage_layout stage;
	VkPipelineLayout layout;
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
	smv_buffer **args;      /* one small uniform buffer per argument table */
	unsigned nargs, nsets;
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
	VkPhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT fro = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_FEATURES_EXT,
		.rasterizationOrderColorAttachmentAccess = VK_TRUE };
	VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR flr = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR, .pNext = &fro,
		.dynamicRenderingLocalRead = VK_TRUE };
	const char *exts[] = { "VK_KHR_dynamic_rendering_local_read", "VK_EXT_rasterization_order_attachment_access",
		"VK_EXT_external_memory_host", "VK_EXT_image_drm_format_modifier" };
	VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &flr,
		.maintenance4 = VK_TRUE, .dynamicRendering = VK_TRUE };
	VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &f13, .bufferDeviceAddress = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12,
		.features = { .shaderInt64 = VK_TRUE } };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = 4,
		.ppEnabledExtensionNames = exts };
	VkDevice dev;
	TRY(vkCreateDevice(pd, &dci, NULL, &dev));
#define DLOAD(n) n = (PFN_##n)vkGetDeviceProcAddr(dev, #n);
	DFNS(DLOAD)
	vkGetDeviceQueue(dev, 0, 0, &sQueue);
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

static const VkDescriptorType kDescType[] = {
	[SMV_DESC_UBO] = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
	[SMV_DESC_SAMPLED_IMAGE] = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
	[SMV_DESC_STORAGE_IMAGE] = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
	[SMV_DESC_SAMPLER] = VK_DESCRIPTOR_TYPE_SAMPLER,
	[SMV_DESC_INPUT_ATTACHMENT] = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
};

static int
stage_layout_new(const struct smv_stage *d, struct stage_layout *out)
{
	VkDescriptorSetLayoutBinding b[32];
	unsigned n = 0;
	out->ubo = 0;
	out->reads_targets = 0;
	for (unsigned i = 0; d && i < d->count; ++i) {
		if (d->bindings[i].type > SMV_DESC_INPUT_ATTACHMENT || n == 32) {
			return fail("bad descriptor binding");
		}
		b[n++] = (VkDescriptorSetLayoutBinding){ .binding = d->bindings[i].binding,
			.descriptorType = kDescType[d->bindings[i].type], .descriptorCount = 1,
			.stageFlags = VK_SHADER_STAGE_ALL };
		out->ubo |= d->bindings[i].type == SMV_DESC_UBO;
		out->reads_targets |= d->bindings[i].type == SMV_DESC_INPUT_ATTACHMENT;
	}
	VkDescriptorSetLayoutCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = n, .pBindings = b };
	TRY(vkCreateDescriptorSetLayout(sDev, &ci, NULL, &out->layout));
	return 1;
}

static void
stage_layout_free(struct stage_layout *l)
{
	if (l->layout) {
		vkDestroyDescriptorSetLayout(sDev, l->layout, NULL);
		l->layout = VK_NULL_HANDLE;
	}
}

static int
pipeline_layout_new(const struct stage_layout *stages, unsigned count, VkPipelineLayout *out)
{
	VkDescriptorSetLayout sets[2];
	for (unsigned i = 0; i < count; ++i) {
		sets[i] = stages[i].layout;
	}
	VkPipelineLayoutCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = count, .pSetLayouts = sets };
	TRY(vkCreatePipelineLayout(sDev, &ci, NULL, out));
	return 1;
}

smv_sampler *
smv_sampler_new(const struct smv_sampler_desc *d)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	smv_sampler *s = calloc(1, sizeof(*s));
	if (!s) {
		fail("out of memory");
		return NULL;
	}
	VkSamplerCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = (VkFilter)d->mag,
		.minFilter = (VkFilter)d->min, .mipmapMode = (VkSamplerMipmapMode)d->mip,
		.addressModeU = (VkSamplerAddressMode)d->address[0], .addressModeV = (VkSamplerAddressMode)d->address[1],
		.addressModeW = (VkSamplerAddressMode)d->address[2], .anisotropyEnable = d->anisotropy > 1.0f,
		.maxAnisotropy = d->anisotropy > 1.0f ? d->anisotropy : 1.0f, .compareEnable = d->compare_enable,
		.compareOp = (VkCompareOp)d->compare_op, .minLod = d->lod_min, .maxLod = d->lod_max,
		.borderColor = (VkBorderColor)d->border, .unnormalizedCoordinates = d->unnormalized };
	VkResult r = vkCreateSampler(sDev, &ci, NULL, &s->sampler);
	if (r != VK_SUCCESS) {
		fail("vkCreateSampler: %d", r);
		free(s);
		return NULL;
	}
	return s;
}

void
smv_sampler_free(smv_sampler *s)
{
	if (s) {
		vkDestroySampler(sDev, s->sampler, NULL);
		free(s);
	}
}

smv_kernel *
smv_kernel_new(const void *spirv, size_t bytes, const char *entry, const struct smv_stage *bindings)
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
	if (!stage_layout_new(bindings, &k->stage) || !pipeline_layout_new(&k->stage, 1, &k->layout)) {
		smv_kernel_free(k);
		return NULL;
	}
	VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = bytes,
		.pCode = spirv };
	VkResult r = vkCreateShaderModule(sDev, &smci, NULL, &k->module);
	if (r != VK_SUCCESS) {
		fail("vkCreateShaderModule: %d", r);
		smv_kernel_free(k);
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
	if (k->module) {
		vkDestroyShaderModule(sDev, k->module, NULL);
	}
	if (k->layout) {
		vkDestroyPipelineLayout(sDev, k->layout, NULL);
	}
	stage_layout_free(&k->stage);
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
			.layout = k->layout };
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
	if (r == VK_SUCCESS) {
		/* what the CPU wrote before (buffers, IOSurfaces) must not be read
		 * from the GPU's own caches: host writes -> everything (Turnip
		 * invalidates its caches for this) */
		VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT };
		vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0,
		    NULL, 0, NULL);
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

/* One stage's descriptor set: the uniform buffer of buffer addresses (if
 * the layout has one) and the bound textures and samplers. The address
 * buffer lives as long as the list. */
static int
stage_set(smv_cmd *c, const struct stage_layout *l, const struct smv_args *a, VkDescriptorSet *out)
{
	if (!c->sets) {
		VkDescriptorPoolSize size[] = { { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, CMD_SETS },
			{ VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, CMD_SETS }, { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, CMD_SETS / 4 },
			{ VK_DESCRIPTOR_TYPE_SAMPLER, CMD_SETS }, { VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, CMD_SETS } };
		VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
			.maxSets = CMD_SETS, .poolSizeCount = 5, .pPoolSizes = size };
		TRY(vkCreateDescriptorPool(sDev, &dpci, NULL, &c->sets));
	}
	if (c->nsets == CMD_SETS) {
		return fail("more than %d descriptor sets in one command buffer", CMD_SETS);
	}
	VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = c->sets, .descriptorSetCount = 1, .pSetLayouts = &l->layout };
	VkDescriptorSet set;
	TRY(vkAllocateDescriptorSets(sDev, &dsai, &set));
	c->nsets++;
	*out = set;
	VkWriteDescriptorSet w[33];
	VkDescriptorImageInfo img[32];
	VkDescriptorBufferInfo dbi;
	unsigned n = 0;
	if (l->ubo) {
		unsigned count = a ? a->count : 0;
		smv_buffer *args = smv_buffer_new(count ? count * 8ull : 8, count ? a->addresses : NULL);
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
		dbi = (VkDescriptorBufferInfo){ args->buf, 0, VK_WHOLE_SIZE };
		w[n++] = (VkWriteDescriptorSet){ .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set,
			.dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
			.pBufferInfo = &dbi };
	}
	for (unsigned i = 0; a && i < a->nres && i < 32; ++i) {
		const struct smv_bind *r = &a->res[i];
		if (r->type == SMV_DESC_SAMPLER) {
			if (!r->sampler) {
				return fail("binding %u: no sampler bound", r->binding);
			}
			img[i] = (VkDescriptorImageInfo){ .sampler = r->sampler->sampler };
		} else if (r->type == SMV_DESC_SAMPLED_IMAGE || r->type == SMV_DESC_STORAGE_IMAGE ||
		    r->type == SMV_DESC_INPUT_ATTACHMENT) {
			if (!r->texture) {
				return fail("binding %u: no texture bound", r->binding);
			}
			img[i] = (VkDescriptorImageInfo){ .imageView = r->texture->view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL };
		} else {
			return fail("binding %u: bad resource type", r->binding);
		}
		w[n++] = (VkWriteDescriptorSet){ .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set,
			.dstBinding = r->binding, .descriptorCount = 1, .descriptorType = kDescType[r->type],
			.pImageInfo = &img[i] };
	}
	if (n) {
		vkUpdateDescriptorSets(sDev, n, w, 0, NULL);
	}
	return 1;
}

int
smv_cmd_dispatch(smv_cmd *c, smv_kernel *k, const struct smv_args *args, const uint32_t groups[3],
    const uint32_t local[3])
{
	VkPipeline pipe = kernel_pipeline(k, local);
	if (!pipe) {
		return 0;
	}
	VkDescriptorSet set;
	if (!stage_set(c, &k->stage, args, &set)) {
		return 0;
	}
	vkCmdBindPipeline(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
	vkCmdBindDescriptorSets(c->cb, VK_PIPELINE_BIND_POINT_COMPUTE, k->layout, 0, 1, &set, 0, NULL);
	vkCmdDispatch(c->cb, groups[0], groups[1], groups[2]);
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
		    VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
	    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0, 1,
	    &mb, 0, NULL, 0, NULL);
	return 1;
}

/* ---- textures ---- */

static int
memory_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < sMem.memoryTypeCount; ++i) {
		if ((bits & (1u << i)) && (sMem.memoryTypes[i].propertyFlags & want) == want) {
			return (int)i;
		}
	}
	return -1;
}

static void
full_barrier(VkCommandBuffer cb)
{
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT };
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb,
	    0, NULL, 0, NULL);
}

smv_texture *
smv_texture_new(uint32_t width, uint32_t height, uint32_t format, uint32_t texel_bytes)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	smv_texture *t = calloc(1, sizeof(*t));
	if (!t) {
		fail("out of memory");
		return NULL;
	}
	t->format = (VkFormat)format;
	t->width = width;
	t->height = height;
	t->texel = texel_bytes;
	VkImageCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = t->format, .extent = { width, height, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
		    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	VkResult r = vkCreateImage(sDev, &ici, NULL, &t->image);
	if (r != VK_SUCCESS) {
		fail("vkCreateImage %ux%u format %u: %d", width, height, format, r);
		goto bad;
	}
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(sDev, t->image, &req);
	int type = memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	if (type < 0) {
		type = memory_type(req.memoryTypeBits, 0);
	}
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
		.memoryTypeIndex = (uint32_t)type };
	if ((r = vkAllocateMemory(sDev, &mai, NULL, &t->mem)) != VK_SUCCESS ||
	    (r = vkBindImageMemory(sDev, t->image, t->mem, 0)) != VK_SUCCESS) {
		fail("image memory %llu: %d", (unsigned long long)req.size, r);
		goto bad;
	}
	VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = t->image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = t->format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	if ((r = vkCreateImageView(sDev, &vci, NULL, &t->view)) != VK_SUCCESS) {
		fail("vkCreateImageView: %d", r);
		goto bad;
	}
	/* to GENERAL once, for good */
	smv_cmd *c = smv_cmd_new();
	if (!c) {
		goto bad;
	}
	VkImageMemoryBarrier ib = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0,
		.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.image = t->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL,
	    0, NULL, 1, &ib);
	int ok = smv_cmd_run(c, 5000);
	smv_cmd_free(c);
	if (!ok) {
		goto bad;
	}
	return t;
bad:
	smv_texture_free(t);
	return NULL;
}

/* An image on host memory the caller owns (an IOSurface's pages): linear,
 * ROW_BYTES per row, contents kept. HOST and BYTES must be 4 KiB aligned. */
smv_texture *
smv_texture_new_host(void *host, uint64_t bytes, uint32_t width, uint32_t height, uint32_t row_bytes,
    uint32_t format, uint32_t texel_bytes)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	if (((uintptr_t)host | bytes) & 4095 || (uint64_t)row_bytes * height > bytes || row_bytes % 64 ||
	    row_bytes < width * texel_bytes) {
		fail("host image: pointer/size not page aligned or row pitch %u unusable (64-byte multiple needed)",
		    row_bytes);
		return NULL;
	}
	smv_texture *t = calloc(1, sizeof(*t));
	if (!t) {
		fail("out of memory");
		return NULL;
	}
	t->format = (VkFormat)format;
	t->width = width;
	t->height = height;
	t->texel = texel_bytes;
	VkSubresourceLayout plane = { .offset = 0, .size = (VkDeviceSize)row_bytes * height, .rowPitch = row_bytes };
	VkImageDrmFormatModifierExplicitCreateInfoEXT mod = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
		.drmFormatModifier = 0 /* DRM_FORMAT_MOD_LINEAR */, .drmFormatModifierPlaneCount = 1, .pPlaneLayouts = &plane };
	VkExternalMemoryImageCreateInfo ext = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .pNext = &mod,
		.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	VkImageCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &ext,
		.imageType = VK_IMAGE_TYPE_2D, .format = t->format, .extent = { width, height, 1 }, .mipLevels = 1,
		.arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
		.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
		    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	VkResult r = vkCreateImage(sDev, &ici, NULL, &t->image);
	if (r != VK_SUCCESS) {
		fail("vkCreateImage (host, pitch %u): %d", row_bytes, r);
		goto bad;
	}
	VkMemoryHostPointerPropertiesEXT hp = { .sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
	if ((r = vkGetMemoryHostPointerPropertiesEXT(sDev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, host,
	    &hp)) != VK_SUCCESS) {
		fail("host pointer properties: %d", r);
		goto bad;
	}
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(sDev, t->image, &req);
	int type = memory_type(req.memoryTypeBits & hp.memoryTypeBits, 0);
	if (type < 0 || req.size > bytes) {
		fail("host image: no memory type (bits 0x%x/0x%x) or %llu > %llu bytes", req.memoryTypeBits,
		    hp.memoryTypeBits, (unsigned long long)req.size, (unsigned long long)bytes);
		goto bad;
	}
	VkImportMemoryHostPointerInfoEXT imp = { .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
		.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, .pHostPointer = host };
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &imp,
		.allocationSize = bytes, .memoryTypeIndex = (uint32_t)type };
	if ((r = vkAllocateMemory(sDev, &mai, NULL, &t->mem)) != VK_SUCCESS ||
	    (r = vkBindImageMemory(sDev, t->image, t->mem, 0)) != VK_SUCCESS) {
		fail("host image import/bind of %llu bytes: %d", (unsigned long long)bytes, r);
		goto bad;
	}
	VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = t->image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = t->format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	if ((r = vkCreateImageView(sDev, &vci, NULL, &t->view)) != VK_SUCCESS) {
		fail("vkCreateImageView: %d", r);
		goto bad;
	}
	/* to GENERAL; on a linear image the layout change keeps the bytes */
	smv_cmd *c = smv_cmd_new();
	if (!c) {
		goto bad;
	}
	VkImageMemoryBarrier ib = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0,
		.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.image = t->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL,
	    0, NULL, 1, &ib);
	int ok = smv_cmd_run(c, 5000);
	smv_cmd_free(c);
	if (!ok) {
		goto bad;
	}
	return t;
bad:
	smv_texture_free(t);
	return NULL;
}

void
smv_texture_free(smv_texture *t)
{
	if (!t) {
		return;
	}
	if (t->view) {
		vkDestroyImageView(sDev, t->view, NULL);
	}
	if (t->image) {
		vkDestroyImage(sDev, t->image, NULL);
	}
	if (t->mem) {
		vkFreeMemory(sDev, t->mem, NULL);
	}
	free(t);
}

int
smv_cmd_copy_texture_buffer(smv_cmd *c, smv_texture *t, const uint32_t region[4], smv_buffer *b, uint64_t offset,
    uint32_t row_bytes, int to_texture)
{
	if (!t->texel || row_bytes % t->texel || region[0] + region[2] > t->width || region[1] + region[3] > t->height) {
		return fail("texture copy: bad region or row length");
	}
	if (!in_range(b, offset, (uint64_t)row_bytes * (region[3] ? region[3] - 1 : 0) + (uint64_t)region[2] * t->texel)) {
		return fail("texture copy: buffer too small");
	}
	VkBufferImageCopy r = { .bufferOffset = offset, .bufferRowLength = row_bytes / t->texel,
		.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
		.imageOffset = { (int32_t)region[0], (int32_t)region[1], 0 }, .imageExtent = { region[2], region[3], 1 } };
	full_barrier(c->cb);
	if (to_texture) {
		vkCmdCopyBufferToImage(c->cb, b->buf, t->image, VK_IMAGE_LAYOUT_GENERAL, 1, &r);
	} else {
		vkCmdCopyImageToBuffer(c->cb, t->image, VK_IMAGE_LAYOUT_GENERAL, b->buf, 1, &r);
	}
	full_barrier(c->cb);
	return 1;
}

/* CPU access (replaceRegion / getBytes): through a staging buffer, now. */
int
smv_texture_access(smv_texture *t, const uint32_t region[4], void *bytes, uint32_t row_bytes, int write)
{
	uint32_t tight = region[2] * t->texel;
	smv_buffer *b = smv_buffer_new((uint64_t)tight * (region[3] ? region[3] : 1), NULL);
	if (!b) {
		return 0;
	}
	if (write) {
		for (uint32_t y = 0; y < region[3]; ++y) {
			memcpy((char *)b->map + (size_t)y * tight, (const char *)bytes + (size_t)y * row_bytes, tight);
		}
	}
	smv_cmd *c = smv_cmd_new();
	int ok = c && smv_cmd_copy_texture_buffer(c, t, region, b, 0, tight, write) && smv_cmd_run(c, 5000);
	if (ok && !write) {
		for (uint32_t y = 0; y < region[3]; ++y) {
			memcpy((char *)bytes + (size_t)y * row_bytes, (const char *)b->map + (size_t)y * tight, tight);
		}
	}
	smv_cmd_free(c);
	smv_buffer_free(b);
	return ok;
}

/* ---- render pipelines and passes ---- */

smv_render_pipeline *
smv_render_pipeline_new(const void *vertex_spirv, size_t vertex_bytes, const char *vertex,
    const void *fragment_spirv, size_t fragment_bytes, const char *fragment,
    const struct smv_stage *vertex_bindings, const struct smv_stage *fragment_bindings,
    const struct smv_color_target *targets, unsigned count)
{
	if (!sDev) {
		fail("no device");
		return NULL;
	}
	if (count > SMV_MAX_TARGETS) {
		fail("%u color targets", count);
		return NULL;
	}
	smv_render_pipeline *p = calloc(1, sizeof(*p));
	if (!p) {
		fail("out of memory");
		return NULL;
	}
	if (!stage_layout_new(vertex_bindings, &p->stage[0]) || !stage_layout_new(fragment_bindings, &p->stage[1]) ||
	    !pipeline_layout_new(p->stage, 2, &p->layout)) {
		smv_render_pipeline_free(p);
		return NULL;
	}
	VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = vertex_bytes, .pCode = vertex_spirv };
	VkResult r = vkCreateShaderModule(sDev, &smci, NULL, &p->vs);
	if (r == VK_SUCCESS) {
		smci.codeSize = fragment_bytes;
		smci.pCode = fragment_spirv;
		r = vkCreateShaderModule(sDev, &smci, NULL, &p->fs);
	}
	if (r != VK_SUCCESS) {
		fail("vkCreateShaderModule: %d", r);
		smv_render_pipeline_free(p);
		return NULL;
	}
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		    .module = p->vs, .pName = vertex },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		    .module = p->fs, .pName = fragment },
	};
	VkFormat formats[SMV_MAX_TARGETS];
	VkPipelineColorBlendAttachmentState blend[SMV_MAX_TARGETS];
	for (unsigned i = 0; i < count; ++i) {
		formats[i] = (VkFormat)targets[i].format;
		blend[i] = (VkPipelineColorBlendAttachmentState){ .blendEnable = targets[i].blend,
			.srcColorBlendFactor = (VkBlendFactor)targets[i].src_rgb,
			.dstColorBlendFactor = (VkBlendFactor)targets[i].dst_rgb,
			.colorBlendOp = (VkBlendOp)targets[i].op_rgb,
			.srcAlphaBlendFactor = (VkBlendFactor)targets[i].src_alpha,
			.dstAlphaBlendFactor = (VkBlendFactor)targets[i].dst_alpha,
			.alphaBlendOp = (VkBlendOp)targets[i].op_alpha,
			.colorWriteMask = targets[i].write_mask };
	}
	VkPipelineRenderingCreateInfo rci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = count, .pColorAttachmentFormats = formats };
	VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
	VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
	VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .lineWidth = 1.0f };
	VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT, .minSampleShading = 1.0f };
	VkPipelineDepthStencilStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
	VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.flags = p->stage[1].reads_targets ? VK_PIPELINE_COLOR_BLEND_STATE_CREATE_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_BIT_EXT : 0,
		.attachmentCount = count, .pAttachments = blend };
	const VkDynamicState dyn[] = { VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT, VK_DYNAMIC_STATE_SCISSOR_WITH_COUNT,
		VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY, VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE };
	VkPipelineDynamicStateCreateInfo dy = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		.dynamicStateCount = sizeof(dyn) / sizeof(dyn[0]), .pDynamicStates = dyn };
	VkGraphicsPipelineCreateInfo gp = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rci,
		.stageCount = 2, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
		.pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .pDepthStencilState = &ds,
		.pColorBlendState = &cb, .pDynamicState = &dy, .layout = p->layout };
	const VkPrimitiveTopology classes[3] = { VK_PRIMITIVE_TOPOLOGY_POINT_LIST, VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
		VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	for (int i = 0; i < 3; ++i) {
		ia.topology = classes[i];
		if ((r = vkCreateGraphicsPipelines(sDev, VK_NULL_HANDLE, 1, &gp, NULL, &p->pipe[i])) != VK_SUCCESS) {
			fail("vkCreateGraphicsPipelines (%s/%s, class %d): %d", vertex, fragment, i, r);
			smv_render_pipeline_free(p);
			return NULL;
		}
	}
	return p;
}

void
smv_render_pipeline_free(smv_render_pipeline *p)
{
	if (!p) {
		return;
	}
	for (int i = 0; i < 3; ++i) {
		if (p->pipe[i]) {
			vkDestroyPipeline(sDev, p->pipe[i], NULL);
		}
	}
	if (p->vs) {
		vkDestroyShaderModule(sDev, p->vs, NULL);
	}
	if (p->fs) {
		vkDestroyShaderModule(sDev, p->fs, NULL);
	}
	if (p->layout) {
		vkDestroyPipelineLayout(sDev, p->layout, NULL);
	}
	stage_layout_free(&p->stage[0]);
	stage_layout_free(&p->stage[1]);
	free(p);
}

int
smv_cmd_begin_render(smv_cmd *c, const struct smv_attachment *a, unsigned count, uint32_t width, uint32_t height)
{
	if (count == 0 || count > SMV_MAX_TARGETS) {
		return fail("render pass with %u color attachments", count);
	}
	VkRenderingAttachmentInfo att[SMV_MAX_TARGETS];
	for (unsigned i = 0; i < count; ++i) {
		att[i] = (VkRenderingAttachmentInfo){ .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
			.imageView = a[i].texture->view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
			.loadOp = (VkAttachmentLoadOp)a[i].load, .storeOp = (VkAttachmentStoreOp)a[i].store };
		memcpy(att[i].clearValue.color.float32, a[i].clear, sizeof(a[i].clear));
	}
	VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { width, height } },
		.layerCount = 1, .colorAttachmentCount = count, .pColorAttachments = att };
	full_barrier(c->cb);
	vkCmdBeginRendering(c->cb, &ri);
	/* Metal's defaults: the whole attachment, no culling, clockwise front faces */
	smv_cmd_viewport(c, 0, 0, width, height, 0, 1);
	VkRect2D sc = { { 0, 0 }, { width, height } };
	vkCmdSetScissorWithCount(c->cb, 1, &sc);
	vkCmdSetCullMode(c->cb, VK_CULL_MODE_NONE);
	vkCmdSetFrontFace(c->cb, VK_FRONT_FACE_CLOCKWISE);
	return 1;
}

void
smv_cmd_viewport(smv_cmd *c, double x, double y, double w, double h, double znear, double zfar)
{
	VkViewport v = { (float)x, (float)(y + h), (float)w, (float)-h, (float)znear, (float)zfar };
	vkCmdSetViewportWithCount(c->cb, 1, &v);
}

void
smv_cmd_raster(smv_cmd *c, uint32_t cull_mode, uint32_t front_face)
{
	vkCmdSetCullMode(c->cb, (VkCullModeFlags)cull_mode);
	vkCmdSetFrontFace(c->cb, (VkFrontFace)front_face);
}

int
smv_cmd_draw(smv_cmd *c, smv_render_pipeline *p, uint32_t topology, const struct smv_args *vertex_args,
    const struct smv_args *fragment_args, uint32_t first_vertex, uint32_t vertices, uint32_t instances,
    uint32_t first_instance)
{
	VkDescriptorSet sets[2];
	if (!stage_set(c, &p->stage[0], vertex_args, &sets[0]) || !stage_set(c, &p->stage[1], fragment_args, &sets[1])) {
		return 0;
	}
	int cls = topology == VK_PRIMITIVE_TOPOLOGY_POINT_LIST ? 0 :
	    (topology == VK_PRIMITIVE_TOPOLOGY_LINE_LIST || topology == VK_PRIMITIVE_TOPOLOGY_LINE_STRIP) ? 1 : 2;
	if (p->stage[1].reads_targets) {
		/* earlier draws' color writes, visible to this draw's input attachment reads */
		VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
			.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_INPUT_ATTACHMENT_READ_BIT };
		vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
		    VK_DEPENDENCY_BY_REGION_BIT, 1, &mb, 0, NULL, 0, NULL);
	}
	vkCmdBindPipeline(c->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, p->pipe[cls]);
	vkCmdSetPrimitiveTopology(c->cb, (VkPrimitiveTopology)topology);
	vkCmdBindDescriptorSets(c->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, p->layout, 0, 2, sets, 0, NULL);
	vkCmdDraw(c->cb, vertices, instances, first_vertex, first_instance);
	return 1;
}

void
smv_cmd_end_render(smv_cmd *c)
{
	vkCmdEndRendering(c->cb);
	full_barrier(c->cb);
}

int
smv_cmd_run(smv_cmd *c, uint32_t timeout_ms)
{
	/* and what the GPU wrote must reach memory for the CPU: everything ->
	 * host reads (Turnip flushes its color and L2 caches for this) */
	VkMemoryBarrier done = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &done, 0, NULL,
	    0, NULL);
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
