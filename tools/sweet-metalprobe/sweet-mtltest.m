/*
 * sweet-mtltest: the stage-3 client. Gets its MTLDevice from
 * MTLCreateSystemDefaultDevice (the plugin hands this process a real one),
 * then through the plain Metal API: a 16 MiB fill with a byte value over an
 * unaligned range, a copy into a second buffer, a second command buffer on
 * the same queue that must run after the first, completed handlers and
 * status; every byte is checked on the CPU. Prints one line per step.
 *   sweet-mtltest
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

int
main(void)
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

		id<MTLLibrary> lib = [device newLibraryWithSource:@"kernel void k() {}" options:nil error:nil];
		check(lib == nil, "libraries refused cleanly (not implemented yet)");
		printf("%s\n", fails ? "SOME CHECKS FAILED" : "ALL OK: METAL DEVICE ON TURNIP");
		return fails != 0;
	}
}
