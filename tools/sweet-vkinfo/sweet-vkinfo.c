/*
 * sweet-vkinfo: loads Turnip (libvulkan_freedreno.dylib, built by
 * tools/build-turnip-ios.sh) as a Vulkan ICD without a loader, creates an
 * instance and a device on the Adreno 618 through the kernel's user client,
 * prints what Turnip reports, then records and submits one command buffer
 * that fills a buffer with vkCmdFillBuffer and checks the result.
 *
 *   TU_DARWIN_SERVICE=NativeAdrenoGpuPublished sweet-vkinfo [LIB]
 *
 * The service variable makes the backend use the direct (unsandboxed)
 * form of the ABI; this program sets it itself when it is unset.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

typedef PFN_vkVoidFunction (*PFN_icdGetInstanceProcAddr)(VkInstance, const char *);

#define CHECK(call) do { \
	VkResult r_ = (call); \
	if (r_ != VK_SUCCESS) { \
		printf("%s: %d\n", #call, r_); \
		return 1; \
	} \
} while (0)

int
main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/var/jb/usr/lib/libvulkan_freedreno.dylib";
	setenv("TU_DARWIN_SERVICE", "NativeAdrenoGpuPublished", 0);
	void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		printf("dlopen %s: %s\n", path, dlerror());
		return 1;
	}
	PFN_icdGetInstanceProcAddr gipa = (PFN_icdGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
	if (!gipa) {
		printf("no vk_icdGetInstanceProcAddr\n");
		return 1;
	}
#define LOAD(inst, name) PFN_##name name = (PFN_##name)gipa(inst, #name)
	LOAD(NULL, vkCreateInstance);
	LOAD(NULL, vkEnumerateInstanceVersion);
	uint32_t api = 0;
	if (vkEnumerateInstanceVersion) {
		vkEnumerateInstanceVersion(&api);
	}
	printf("Turnip loaded from %s, instance version %u.%u.%u\n", path, VK_VERSION_MAJOR(api),
	    VK_VERSION_MINOR(api), VK_VERSION_PATCH(api));

	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "sweet-vkinfo", .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app };
	VkInstance inst;
	CHECK(vkCreateInstance(&ici, NULL, &inst));
	LOAD(inst, vkEnumeratePhysicalDevices);
	LOAD(inst, vkGetPhysicalDeviceProperties);
	LOAD(inst, vkGetPhysicalDeviceMemoryProperties);
	LOAD(inst, vkGetPhysicalDeviceQueueFamilyProperties);
	LOAD(inst, vkCreateDevice);
	LOAD(inst, vkGetDeviceProcAddr);
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CHECK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	if (n == 0) {
		printf("no physical device\n");
		return 1;
	}
	VkPhysicalDeviceProperties p;
	vkGetPhysicalDeviceProperties(pd, &p);
	printf("device: %s, Vulkan %u.%u.%u, driver 0x%x, vendor 0x%x device 0x%x\n", p.deviceName,
	    VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion),
	    p.driverVersion, p.vendorID, p.deviceID);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryHeapCount; ++i) {
		printf("heap %u: %llu MiB flags 0x%x\n", i, (unsigned long long)(mp.memoryHeaps[i].size >> 20),
		    mp.memoryHeaps[i].flags);
	}
	uint32_t host_type = UINT32_MAX;
	for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
		printf("memory type %u: heap %u flags 0x%x\n", i, mp.memoryTypes[i].heapIndex,
		    mp.memoryTypes[i].propertyFlags);
		VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
		if (host_type == UINT32_MAX && (mp.memoryTypes[i].propertyFlags & want) == want) {
			host_type = i;
		}
	}

	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
	printf("device created\n");
#define DLOAD(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(dev, #name)
	DLOAD(vkGetDeviceQueue);
	DLOAD(vkCreateBuffer);
	DLOAD(vkGetBufferMemoryRequirements);
	DLOAD(vkAllocateMemory);
	DLOAD(vkBindBufferMemory);
	DLOAD(vkMapMemory);
	DLOAD(vkCreateCommandPool);
	DLOAD(vkAllocateCommandBuffers);
	DLOAD(vkBeginCommandBuffer);
	DLOAD(vkCmdFillBuffer);
	DLOAD(vkEndCommandBuffer);
	DLOAD(vkQueueSubmit);
	DLOAD(vkQueueWaitIdle);
	DLOAD(vkDestroyDevice);
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);

	const VkDeviceSize size = 1 << 20;
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, buf, &req);
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = req.size, .memoryTypeIndex = host_type };
	VkDeviceMemory mem;
	CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CHECK(vkBindBufferMemory(dev, buf, mem, 0));
	uint32_t *ptr;
	CHECK(vkMapMemory(dev, mem, 0, size, 0, (void **)&ptr));
	memset(ptr, 0, size);

	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.queueFamilyIndex = 0 };
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cb;
	CHECK(vkAllocateCommandBuffers(dev, &cai, &cb));
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CHECK(vkBeginCommandBuffer(cb, &cbi));
	vkCmdFillBuffer(cb, buf, 0, size, 0x5eedf00d);
	CHECK(vkEndCommandBuffer(cb));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
		.pCommandBuffers = &cb };
	CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
	CHECK(vkQueueWaitIdle(q));
	uint32_t bad = 0;
	for (uint32_t i = 0; i < size / 4; ++i) {
		bad += ptr[i] != 0x5eedf00du;
	}
	printf("vkCmdFillBuffer of 1 MiB: %s (%u wrong words, first 0x%08x)\n",
	    bad ? "FAILED" : "OK, VULKAN RUNS ON THE ADRENO", bad, ptr[0]);
	vkDestroyDevice(dev, NULL);
	return bad ? 2 : 0;
}
