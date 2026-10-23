/*
 * sweet-fillbench: how long full-screen (1125x2436) render passes take on the GPU through our Metal stack,
 * into a texture of the GPU's own memory and into an IOSurface (imported host pages, like QuartzCore's
 * display surfaces). Per target: a pass that only clears and stores, and a pass that loads and blends
 * N full-screen quads. Uses sweet-mtltest.metallib's tri_vertex/tri_fragment.
 *   sweet-fillbench [QUADS] [REPEATS]
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach_time.h>

struct vtx { float x, y; float r, g, b, a; };

static double nowMs(void)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom) mach_timebase_info(&tb);
	return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6;
}

static void bench(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLRenderPipelineState> ps, id<MTLTexture> t, const char *name,
    int quads, int reps)
{
	struct vtx v[6 * 64];
	for (int i = 0; i < quads && i < 64; i++) {
		float c = (i % 3) / 3.0f;
		const struct vtx q6[6] = { {-1,-1,c,0.5,1-c,0.05}, {1,-1,c,0.5,1-c,0.05}, {-1,1,c,0.5,1-c,0.05},
		                           {1,-1,c,0.5,1-c,0.05}, {1,1,c,0.5,1-c,0.05}, {-1,1,c,0.5,1-c,0.05} };
		memcpy(&v[6 * i], q6, sizeof(q6));
	}
	for (int mode = 0; mode < 2; mode++) {
		double total = 0, worst = 0;
		for (int r = 0; r < reps + 1; r++) {
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = t;
			rp.colorAttachments[0].loadAction = mode == 0 ? MTLLoadActionClear : MTLLoadActionLoad;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
			if (mode == 1) {
				[e setRenderPipelineState:ps];
				for (int i = 0; i < quads; i++) {
					[e setVertexBytes:&v[6 * (i % 64)] length:6 * sizeof(struct vtx) atIndex:0];
					[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				}
			}
			[e endEncoding];
			double t0 = nowMs();
			[cb commit];
			[cb waitUntilCompleted];
			double dt = nowMs() - t0;
			if (r == 0) continue;                   /* the first one pays for setup */
			total += dt;
			if (dt > worst) worst = dt;
		}
		printf("%-10s %-22s %6.2f ms mean %6.2f ms worst\n", name, mode == 0 ? "clear+store" : "load+blend quads",
		    total / reps, worst);
	}
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		int quads = argc > 1 ? atoi(argv[1]) : 20, reps = argc > 2 ? atoi(argv[2]) : 20;
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		if (!dev) { printf("no Metal device\n"); return 1; }
		NSError *err = nil;
		id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@"/var/jb/usr/share/sweet-mtltest.metallib"] error:&err];
		if (!lib) { printf("no library: %s\n", err.description.UTF8String); return 1; }
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
		pd.fragmentFunction = [lib newFunctionWithName:@"tri_fragment"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
		if (!ps) { printf("no pipeline: %s\n", err.description.UTF8String); return 1; }
		id<MTLCommandQueue> q = [dev newCommandQueue];
		const NSUInteger W = 1125, H = 2436;
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModePrivate;
		id<MTLTexture> priv = [dev newTextureWithDescriptor:td];
		NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
			(id)kIOSurfaceBytesPerRow: @(4544), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		td.storageMode = MTLStorageModeShared;
		id<MTLTexture> surf = s ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : nil;
		printf("%d quads, %d repeats; private %s, iosurface %s\n", quads, reps, priv ? "ok" : "FAILED", surf ? "ok" : "FAILED");
		if (priv) bench(dev, q, ps, priv, "private", quads, reps);
		if (surf) bench(dev, q, ps, surf, "iosurface", quads, reps);
	}
	return 0;
}
