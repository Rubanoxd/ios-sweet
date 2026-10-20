/*
 * sweet-mtltest: the stage-3 client. Gets its MTLDevice from
 * MTLCreateSystemDefaultDevice (the plugin hands this process a real one),
 * then through the plain Metal API: a 16 MiB fill with a byte value over an
 * unaligned range, a copy into a second buffer, a second command buffer on
 * the same queue that must run after the first, completed handlers and
 * status; then two kernels from a metallib (Iridium translates the AIR):
 * add_arrays (float) and square_add (integers and a setBytes constant)
 * over 1M elements; a render pass into a 256x256 BGRA texture: a colored
 * triangle on a cleared background, then a half-transparent white triangle
 * blended over the top-left corner (written to /var/tmp/sweet-mtltest.ppm).
 * Every result is checked on the CPU.
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

static void render(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib);

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
	render(device, queue, lib);
}

struct vtx {
	float position[2], pad[2], color[4];   /* Metal's float2 + float4 layout */
};

static void
render(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib)
{
	const NSUInteger W = 256, H = 256;
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	    width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> tex = [device newTextureWithDescriptor:td];
	check(tex != nil, "256x256 BGRA8 texture");
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"tri_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	NSError *error = nil;
	id<MTLRenderPipelineState> plain = [device newRenderPipelineStateWithDescriptor:pd error:&error];
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	id<MTLRenderPipelineState> blended = [device newRenderPipelineStateWithDescriptor:pd error:&error];
	printf("render pipelines: %s\n", plain && blended ? "OK" : error.localizedDescription.UTF8String);
	check(plain && blended, "render pipelines (plain and blended)");
	if (!tex || !plain || !blended) {
		return;
	}
	const struct vtx tri[3] = {
		{ { -0.8f, -0.8f }, { 0, 0 }, { 1, 0, 0, 1 } },     /* bottom left: red */
		{ { 0.8f, -0.8f }, { 0, 0 }, { 0, 1, 0, 1 } },      /* bottom right: green */
		{ { 0.0f, 0.8f }, { 0, 0 }, { 0, 0, 1, 1 } },       /* top: blue */
	};
	const struct vtx veil[3] = {
		{ { -1, 1 }, { 0, 0 }, { 1, 1, 1, 0.5f } },
		{ { 0, 1 }, { 0, 0 }, { 1, 1, 1, 0.5f } },
		{ { -1, 0 }, { 0, 0 }, { 1, 1, 1, 0.5f } },
	};
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	[e setRenderPipelineState:plain];
	[e setVertexBytes:tri length:sizeof(tri) atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e setRenderPipelineState:blended];
	[e setVertexBytes:veil length:sizeof(veil) atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	CFTimeInterval t0 = CACurrentMediaTime();
	[cb commit];
	[cb waitUntilCompleted];
	printf("render: status %lu, error %s, %.2f ms\n", (unsigned long)cb.status,
	    cb.error.localizedDescription.UTF8String ?: "none", (CACurrentMediaTime() - t0) * 1e3);
	static uint8_t px[256 * 256 * 4];
	[tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	FILE *f = fopen("/var/tmp/sweet-mtltest.ppm", "wb");
	if (f) {
		fprintf(f, "P6 %lu %lu 255\n", (unsigned long)W, (unsigned long)H);
		for (NSUInteger i = 0; i < W * H; ++i) {
			fputc(px[i * 4 + 2], f);
			fputc(px[i * 4 + 1], f);
			fputc(px[i * 4 + 0], f);
		}
		fclose(f);
	}
	/* BGRA bytes at (x, y), y from the top */
#define AT(x, y) (&px[((y) * W + (x)) * 4])
	const uint8_t *bg = AT(250, 250), *top = AT(128, 40), *left = AT(40, 225), *right = AT(215, 225),
	    *veiled = AT(5, 5);
	printf("pixels BGRA: background %u,%u,%u  top %u,%u,%u  bottom-left %u,%u,%u  bottom-right %u,%u,%u  "
	    "veiled corner %u,%u,%u\n", bg[0], bg[1], bg[2], top[0], top[1], top[2], left[0], left[1], left[2],
	    right[0], right[1], right[2], veiled[0], veiled[1], veiled[2]);
	check(cb.status == MTLCommandBufferStatusCompleted && bg[2] > 20 && bg[2] < 32 && bg[0] == bg[2],
	    "clear color");
	check(top[0] > 150 && top[2] < 80, "top of the triangle is blue (y axis not flipped)");
	check(left[2] > 150 && left[0] < 80, "bottom left is red");
	check(right[1] > 150 && right[2] < 80, "bottom right is green");
	check(veiled[0] > 130 && veiled[0] < 150 && veiled[2] > 130 && veiled[2] < 150,
	    "half-transparent white blended over the corner");
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
		printf("%s\n", fails ? "SOME CHECKS FAILED" : "ALL OK: METAL KERNELS AND RENDERING ON TURNIP");
		return fails != 0;
	}
}
