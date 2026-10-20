/*
 * sweet-mtltest: the stage-3 client. Gets its MTLDevice from
 * MTLCreateSystemDefaultDevice (the plugin hands this process a real one),
 * then through the plain Metal API: a 16 MiB fill with a byte value over an
 * unaligned range, a copy into a second buffer, a second command buffer on
 * the same queue that must run after the first, completed handlers and
 * status; then two kernels from a metallib (Iridium translates the AIR):
 * add_arrays (float) and square_add (integers and a setBytes constant)
 * over 1M elements. Every result is checked on the CPU.
 *   sweet-mtltest [LIB.metallib]   (default /var/jb/usr/share/sweet-mtltest.metallib)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static int fails;

static void
check(BOOL ok, const char *what)
{
	printf("%s: %s\n", what, ok ? "OK" : "FAILED");
	fails += !ok;
}

static id<MTLComputePipelineState>
kernel(id<MTLDevice> device, id<MTLLibrary> lib, NSString *name)
{
	id<MTLFunction> f = [lib newFunctionWithName:name];
	NSError *error = nil;
	id<MTLComputePipelineState> p = f ? [device newComputePipelineStateWithFunction:f error:&error] : nil;
	printf("kernel %s: function %s, pipeline %s%s\n", name.UTF8String, f ? "yes" : "no", p ? "yes" : "no ",
	    p ? "" : error.localizedDescription.UTF8String ?: "");
	return p;
}

static void
kernels(id<MTLDevice> device, id<MTLCommandQueue> queue, const char *path)
{
	NSError *error = nil;
	CFTimeInterval t0 = CACurrentMediaTime();
	id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&error];
	printf("library %s: %s (%.1f ms), functions %s\n", path, lib ? "OK" : error.localizedDescription.UTF8String,
	    (CACurrentMediaTime() - t0) * 1e3, lib ? [lib.functionNames componentsJoinedByString:@" "].UTF8String : "-");
	check(lib != nil, "metallib loaded and translated");
	if (!lib) {
		return;
	}
	const NSUInteger n = 1u << 20;
	id<MTLComputePipelineState> add = kernel(device, lib, @"add_arrays");
	id<MTLComputePipelineState> sq = kernel(device, lib, @"square_add");
	check(add && sq, "compute pipelines");
	if (!add || !sq) {
		return;
	}
	id<MTLBuffer> fa = [device newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> fb = [device newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> fr = [device newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> ui = [device newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> uo = [device newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
	float *a = fa.contents, *b = fb.contents;
	uint32_t *in = ui.contents;
	for (NSUInteger i = 0; i < n; ++i) {
		a[i] = (float)i * 0.5f;
		b[i] = 1000.0f - (float)i;
		in[i] = (uint32_t)i;
	}
	const uint32_t k = 12345;
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
	[e setComputePipelineState:add];
	[e setBuffer:fa offset:0 atIndex:0];
	[e setBuffer:fb offset:0 atIndex:1];
	[e setBuffer:fr offset:0 atIndex:2];
	[e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
	[e setComputePipelineState:sq];
	[e setBuffer:ui offset:0 atIndex:0];
	[e setBuffer:uo offset:0 atIndex:1];
	[e setBytes:&k length:sizeof(k) atIndex:2];
	[e dispatchThreadgroups:MTLSizeMake(n / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[e endEncoding];
	t0 = CACurrentMediaTime();
	[cb commit];
	[cb waitUntilCompleted];
	printf("kernels: status %lu, error %s, %.2f ms\n", (unsigned long)cb.status,
	    cb.error.localizedDescription.UTF8String ?: "none", (CACurrentMediaTime() - t0) * 1e3);
	const float *r = fr.contents;
	const uint32_t *out = uo.contents;
	size_t bad_f = 0, bad_u = 0;
	for (NSUInteger i = 0; i < n; ++i) {
		bad_f += r[i] != a[i] + b[i];
		bad_u += out[i] != (uint32_t)i * (uint32_t)i + k;
	}
	printf("wrong: add_arrays %zu, square_add %zu of %lu (r[7] = %g, out[7] = %u)\n", bad_f, bad_u,
	    (unsigned long)n, r[7], out[7]);
	check(cb.status == MTLCommandBufferStatusCompleted && bad_f == 0, "add_arrays (float) on the GPU");
	check(cb.status == MTLCommandBufferStatusCompleted && bad_u == 0, "square_add (integers, setBytes) on the GPU");
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (!device) {
			printf("MTLCreateSystemDefaultDevice: nil\n");
			return 1;
		}
		printf("device: %s, registryID 0x%llx, unified %d, maxBufferLength %lu\n", device.name.UTF8String,
		    device.registryID, device.hasUnifiedMemory, (unsigned long)device.maxBufferLength);
		const NSUInteger size = 16u << 20;
		id<MTLBuffer> a = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
		id<MTLBuffer> b = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
		check(a && b && a.length == size && a.contents, "two 16 MiB shared buffers");
		if (!a || !b) {
			return 1;
		}
		memset(a.contents, 0x11, size);
		id<MTLCommandQueue> queue = [device newCommandQueue];
		check(queue != nil, "command queue");

		/* 1: fill an unaligned range of a, copy all of a into b */
		const NSRange fill = NSMakeRange(3, size - 9);
		id<MTLCommandBuffer> one = [queue commandBuffer];
		__block int handled = 0;
		[one addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			(void)cb;
			__sync_fetch_and_add(&handled, 1);
		}];
		id<MTLBlitCommandEncoder> blit = [one blitCommandEncoder];
		[blit fillBuffer:a range:fill value:0xa5];
		[blit copyFromBuffer:a sourceOffset:0 toBuffer:b destinationOffset:0 size:size];
		[blit endEncoding];

		/* 2: on the same queue, must see 1's result: copy b[0..1M) to a's end */
		id<MTLCommandBuffer> two = [queue commandBuffer];
		blit = [two blitCommandEncoder];
		[blit copyFromBuffer:b sourceOffset:(1u << 20) toBuffer:a destinationOffset:size - (1u << 20) size:(1u << 20)];
		[blit endEncoding];
		[two addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			(void)cb;
			__sync_fetch_and_add(&handled, 10);
		}];

		CFTimeInterval t0 = CACurrentMediaTime();
		[one commit];
		[two commit];
		[two waitUntilCompleted];
		[one waitUntilCompleted];
		CFTimeInterval t1 = CACurrentMediaTime();
		printf("status %lu/%lu, errors %s / %s, %.2f ms for both\n", (unsigned long)one.status,
		    (unsigned long)two.status, one.error.localizedDescription.UTF8String ?: "none",
		    two.error.localizedDescription.UTF8String ?: "none", (t1 - t0) * 1e3);
		check(one.status == MTLCommandBufferStatusCompleted && two.status == MTLCommandBufferStatusCompleted,
		    "both command buffers completed");
		check(handled == 11, "completed handlers ran once each");

		const uint8_t *pa = a.contents, *pb = b.contents;
		size_t bad_b = 0, bad_a = 0;
		for (size_t i = 0; i < size; ++i) {
			uint8_t want = (i >= fill.location && i < NSMaxRange(fill)) ? 0xa5 : 0x11;
			bad_b += pb[i] != want;
			uint8_t want_a = i >= size - (1u << 20) ? 0xa5 : want;
			bad_a += pa[i] != want_a;
		}
		printf("bytes wrong: b %zu, a %zu (GPU time one %.2f ms)\n", bad_b, bad_a,
		    (one.GPUEndTime - one.GPUStartTime) * 1e3);
		check(bad_b == 0, "fill (unaligned head and tail) + copy");
		check(bad_a == 0, "second command buffer ran after the first");

		kernels(device, queue, argc > 1 ? argv[1] : "/var/jb/usr/share/sweet-mtltest.metallib");
		printf("%s\n", fails ? "SOME CHECKS FAILED" : "ALL OK: METAL KERNELS ON TURNIP");
		return fails != 0;
	}
}
