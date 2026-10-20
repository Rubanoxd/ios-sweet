/*
 * sweet-vktest: GPU work through Turnip on the phone, checked on the CPU.
 *  1. compute: a 64-wide compute shader writes out[i] = i*i + 7 for 1M
 *     uints (16384 workgroups); every word is checked.
 *  2. render pass: a colored triangle (red/green/blue corners) drawn into a
 *     256x256 RGBA8 image with a clear to dark gray, copied to a buffer;
 *     some pixels are checked and the image is written as a PPM file.
 * Shaders: compute.comp, triangle.vert, triangle.frag, compiled to SPIR-V
 * headers by build.sh. Loads the ICD without a loader, like sweet-vkinfo.
 *
 *   sweet-vktest [LIB [OUT.ppm]]
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define VK_NO_PROTOTYPES 1  /* the entry points below are loaded from the ICD */
#include <vulkan/vulkan.h>
#include "compute_comp.h"
#include "triangle_vert.h"
#include "triangle_frag.h"

#define CHECK(call) do { \
	VkResult r_ = (call); \
	if (r_ != VK_SUCCESS) { \
		printf("%s: %d\n", #call, r_); \
		exit(1); \
	} \
} while (0)

typedef PFN_vkVoidFunction (*PFN_icdGetInstanceProcAddr)(VkInstance, const char *);
static PFN_icdGetInstanceProcAddr gipa;
static PFN_vkGetDeviceProcAddr gdpa;
static VkDevice dev;
static VkPhysicalDeviceMemoryProperties mp;

#define IFN(name) static PFN_##name name
IFN(vkCreateInstance); IFN(vkEnumeratePhysicalDevices); IFN(vkGetPhysicalDeviceMemoryProperties);
IFN(vkCreateDevice); IFN(vkGetDeviceQueue); IFN(vkCreateBuffer); IFN(vkGetBufferMemoryRequirements);
IFN(vkAllocateMemory); IFN(vkBindBufferMemory); IFN(vkMapMemory); IFN(vkCreateImage);
IFN(vkGetImageMemoryRequirements); IFN(vkBindImageMemory); IFN(vkCreateImageView);
IFN(vkCreateShaderModule); IFN(vkCreateDescriptorSetLayout); IFN(vkCreatePipelineLayout);
IFN(vkCreateComputePipelines); IFN(vkCreateGraphicsPipelines); IFN(vkCreateDescriptorPool);
IFN(vkAllocateDescriptorSets); IFN(vkUpdateDescriptorSets); IFN(vkCreateRenderPass);
IFN(vkCreateFramebuffer); IFN(vkCreateCommandPool); IFN(vkAllocateCommandBuffers);
IFN(vkBeginCommandBuffer); IFN(vkEndCommandBuffer); IFN(vkCmdBindPipeline);
IFN(vkCmdBindDescriptorSets); IFN(vkCmdDispatch); IFN(vkCmdBeginRenderPass); IFN(vkCmdEndRenderPass);
IFN(vkCmdDraw); IFN(vkCmdCopyImageToBuffer); IFN(vkCmdPipelineBarrier); IFN(vkQueueSubmit);
IFN(vkQueueWaitIdle); IFN(vkDestroyDevice);

static uint32_t
memtype(uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) {
			return i;
		}
	}
	printf("no memory type for bits 0x%x flags 0x%x\n", bits, want);
	exit(1);
}

static VkDeviceMemory
alloc(VkMemoryRequirements req, VkMemoryPropertyFlags want)
{
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = req.size, .memoryTypeIndex = memtype(req.memoryTypeBits, want) };
	VkDeviceMemory mem;
	CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
	return mem;
}

static VkBuffer
host_buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer buf;
	CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, buf, &req);
	VkDeviceMemory mem = alloc(req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	CHECK(vkBindBufferMemory(dev, buf, mem, 0));
	CHECK(vkMapMemory(dev, mem, 0, size, 0, map));
	return buf;
}

static VkShaderModule
shader(const uint32_t *code, size_t bytes)
{
	VkShaderModuleCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = bytes, .pCode = code };
	VkShaderModule m;
	CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
	return m;
}

static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void
run(VkQueue q, VkCommandBuffer cb)
{
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
	CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
	CHECK(vkQueueWaitIdle(q));
}

int
main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/var/jb/usr/lib/libvulkan_freedreno.dylib";
	const char *ppm = argc > 2 ? argv[2] : "/var/jb/var/tmp/sweet-vktest.ppm";
	setenv("TU_DARWIN_SERVICE", "NativeAdrenoGpuPublished", 0);
	void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!lib || !(gipa = (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr"))) {
		printf("cannot load %s: %s\n", path, dlerror());
		return 1;
	}
	vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "sweet-vktest",
		.apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CHECK(vkCreateInstance(&ici, NULL, &inst));
#define ILOAD(name) name = (PFN_##name)gipa(inst, #name)
	ILOAD(vkEnumeratePhysicalDevices); ILOAD(vkGetPhysicalDeviceMemoryProperties); ILOAD(vkCreateDevice);
	gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CHECK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0,
		.queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
#define DLOAD(name) name = (PFN_##name)gdpa(dev, #name)
	DLOAD(vkGetDeviceQueue); DLOAD(vkCreateBuffer); DLOAD(vkGetBufferMemoryRequirements); DLOAD(vkAllocateMemory);
	DLOAD(vkBindBufferMemory); DLOAD(vkMapMemory); DLOAD(vkCreateImage); DLOAD(vkGetImageMemoryRequirements);
	DLOAD(vkBindImageMemory); DLOAD(vkCreateImageView); DLOAD(vkCreateShaderModule);
	DLOAD(vkCreateDescriptorSetLayout); DLOAD(vkCreatePipelineLayout); DLOAD(vkCreateComputePipelines);
	DLOAD(vkCreateGraphicsPipelines); DLOAD(vkCreateDescriptorPool); DLOAD(vkAllocateDescriptorSets);
	DLOAD(vkUpdateDescriptorSets); DLOAD(vkCreateRenderPass); DLOAD(vkCreateFramebuffer);
	DLOAD(vkCreateCommandPool); DLOAD(vkAllocateCommandBuffers); DLOAD(vkBeginCommandBuffer);
	DLOAD(vkEndCommandBuffer); DLOAD(vkCmdBindPipeline); DLOAD(vkCmdBindDescriptorSets); DLOAD(vkCmdDispatch);
	DLOAD(vkCmdBeginRenderPass); DLOAD(vkCmdEndRenderPass); DLOAD(vkCmdDraw); DLOAD(vkCmdCopyImageToBuffer);
	DLOAD(vkCmdPipelineBarrier); DLOAD(vkQueueSubmit); DLOAD(vkQueueWaitIdle); DLOAD(vkDestroyDevice);
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 2 };
	VkCommandBuffer cbs[2];
	CHECK(vkAllocateCommandBuffers(dev, &cai, cbs));
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	int fails = 0;

	/* 1. compute */
	const uint32_t words = 1u << 20;
	uint32_t *out;
	VkBuffer obuf = host_buffer(words * 4ull, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&out);
	memset(out, 0, words * 4ull);
	VkDescriptorSetLayoutBinding b = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
	VkDescriptorSetLayoutCreateInfo dlci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &b };
	VkDescriptorSetLayout dsl;
	CHECK(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout cpl;
	CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &cpl));
	double t0 = now_ms();
	VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		    .module = shader(spv_compute_comp, sizeof(spv_compute_comp)), .pName = "main" },
		.layout = cpl };
	VkPipeline cpipe;
	CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &cpipe));
	printf("compute pipeline compiled by ir3 in %.1f ms\n", now_ms() - t0);
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
		.poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool dp;
	CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
	VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet ds;
	CHECK(vkAllocateDescriptorSets(dev, &dsai, &ds));
	VkDescriptorBufferInfo dbi = { obuf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0,
		.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
	CHECK(vkBeginCommandBuffer(cbs[0], &cbi));
	vkCmdBindPipeline(cbs[0], VK_PIPELINE_BIND_POINT_COMPUTE, cpipe);
	vkCmdBindDescriptorSets(cbs[0], VK_PIPELINE_BIND_POINT_COMPUTE, cpl, 0, 1, &ds, 0, NULL);
	vkCmdDispatch(cbs[0], words / 64, 1, 1);
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cbs[0], VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0,
	    NULL, 0, NULL);
	CHECK(vkEndCommandBuffer(cbs[0]));
	t0 = now_ms();
	run(q, cbs[0]);
	double t_compute = now_ms() - t0;
	uint32_t bad = 0;
	for (uint32_t i = 0; i < words; ++i) {
		bad += out[i] != i * i + 7u;
	}
	printf("compute: %u invocations in %.2f ms, %u wrong (out[1000] = %u, want %u): %s\n", words, t_compute, bad,
	    out[1000], 1000u * 1000u + 7u, bad ? "FAILED" : "OK");
	fails += bad != 0;

	/* 2. render pass */
	const uint32_t W = 256, H = 256;
	VkImageCreateInfo imci = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	VkImage img;
	CHECK(vkCreateImage(dev, &imci, NULL, &img));
	VkMemoryRequirements ireq;
	vkGetImageMemoryRequirements(dev, img, &ireq);
	CHECK(vkBindImageMemory(dev, img, alloc(ireq, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0));
	VkImageViewCreateInfo ivci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CHECK(vkCreateImageView(dev, &ivci, NULL, &view));
	VkAttachmentDescription att = { .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
	VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
		.pColorAttachments = &ref };
	VkRenderPassCreateInfo rpci = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
		.pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
	VkRenderPass rp;
	CHECK(vkCreateRenderPass(dev, &rpci, NULL, &rp));
	VkFramebufferCreateInfo fbci = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
		.attachmentCount = 1, .pAttachments = &view, .width = W, .height = H, .layers = 1 };
	VkFramebuffer fb;
	CHECK(vkCreateFramebuffer(dev, &fbci, NULL, &fb));
	VkPipelineLayoutCreateInfo gplci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout gpl;
	CHECK(vkCreatePipelineLayout(dev, &gplci, NULL, &gpl));
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = shader(spv_triangle_vert, sizeof(spv_triangle_vert)), .pName = "main" },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = shader(spv_triangle_frag, sizeof(spv_triangle_frag)), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, (float)W, (float)H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_CLOCKWISE,
		.lineWidth = 1.0f };
	VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cbs_ = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkGraphicsPipelineCreateInfo gpci = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.stageCount = 2, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
		.pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cbs_,
		.layout = gpl, .renderPass = rp };
	t0 = now_ms();
	VkPipeline gpipe;
	CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &gpipe));
	printf("graphics pipeline compiled by ir3 in %.1f ms\n", now_ms() - t0);
	uint8_t *pix;
	VkBuffer pbuf = host_buffer(W * H * 4ull, VK_BUFFER_USAGE_TRANSFER_DST_BIT, (void **)&pix);
	memset(pix, 0xcd, W * H * 4ull);
	CHECK(vkBeginCommandBuffer(cbs[1], &cbi));
	VkClearValue clear = { .color = { .float32 = { 0.2f, 0.2f, 0.2f, 1.0f } } };
	VkRenderPassBeginInfo rpbi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp,
		.framebuffer = fb, .renderArea = sc, .clearValueCount = 1, .pClearValues = &clear };
	vkCmdBeginRenderPass(cbs[1], &rpbi, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(cbs[1], VK_PIPELINE_BIND_POINT_GRAPHICS, gpipe);
	vkCmdDraw(cbs[1], 3, 1, 0, 0);
	vkCmdEndRenderPass(cbs[1]);
	VkBufferImageCopy bic = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(cbs[1], img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, pbuf, 1, &bic);
	VkMemoryBarrier hb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cbs[1], VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hb, 0, NULL, 0,
	    NULL);
	CHECK(vkEndCommandBuffer(cbs[1]));
	t0 = now_ms();
	run(q, cbs[1]);
	double t_render = now_ms() - t0;
	/* corner: clear color (51); center: a mix; near each vertex: its color */
	const uint8_t *c = pix + 4 * (2 * W + 2);
	const uint8_t *m = pix + 4 * (W / 2 * W + W / 2);
	const uint8_t *top = pix + 4 * ((uint32_t)(0.12 * H) * W + W / 2);
	const uint8_t *br = pix + 4 * ((uint32_t)(0.86 * H) * W + (uint32_t)(0.85 * W));
	const uint8_t *bl = pix + 4 * ((uint32_t)(0.86 * H) * W + (uint32_t)(0.15 * W));
	printf("render pass in %.2f ms: corner %u,%u,%u center %u,%u,%u top %u,%u,%u right %u,%u,%u left %u,%u,%u\n",
	    t_render, c[0], c[1], c[2], m[0], m[1], m[2], top[0], top[1], top[2], br[0], br[1], br[2], bl[0], bl[1], bl[2]);
	int ok = c[0] == 51 && c[1] == 51 && c[2] == 51 && top[0] > 200 && br[1] > 200 && bl[2] > 200 && m[3] == 255;
	printf("triangle: %s\n", ok ? "OK, THE GPU RENDERED IT" : "FAILED");
	fails += !ok;
	FILE *f = fopen(ppm, "wb");
	if (f) {
		fprintf(f, "P6\n%u %u\n255\n", W, H);
		for (uint32_t i = 0; i < W * H; ++i) {
			fwrite(pix + 4 * i, 1, 3, f);
		}
		fclose(f);
		printf("image written to %s\n", ppm);
	}
	vkDestroyDevice(dev, NULL);
	return fails ? 2 : 0;
}
