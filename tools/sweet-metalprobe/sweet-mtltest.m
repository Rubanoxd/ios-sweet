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
 * blended over the top-left corner (written to /var/tmp/sweet-mtltest.ppm);
 * a texture test: an image (PNG, decoded with ImageIO) uploaded with
 * replaceRegion, drawn with a bound linear sampler and blended by its
 * alpha over a background, plus a small copy at 60 % with a constexpr
 * sampler (written to /var/tmp/sweet-mtltest-texture.ppm); a framebuffer
 * read: a cleared target, a triangle that writes 1 - the color it reads from
 * the attachment, and a second overlapping one that inverts again.
 * Every result is checked on the CPU.
 *   sweet-mtltest [LIB.metallib [IMAGE.png]]
 *   (defaults /var/jb/usr/share/sweet-mtltest.metallib and .png)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

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
static void textured(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib, const char *png);
static const char *gImage = "/var/jb/usr/share/sweet-mtltest.png";
static void framebufferRead(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib);

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
	textured(device, queue, lib, gImage);
	framebufferRead(device, queue, lib);
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

static void
writePPM(const char *path, const uint8_t *bgra, NSUInteger w, NSUInteger h)
{
	FILE *f = fopen(path, "wb");
	if (!f) {
		return;
	}
	fprintf(f, "P6 %lu %lu 255\n", (unsigned long)w, (unsigned long)h);
	for (NSUInteger i = 0; i < w * h; ++i) {
		fputc(bgra[i * 4 + 2], f);
		fputc(bgra[i * 4 + 1], f);
		fputc(bgra[i * 4 + 0], f);
	}
	fclose(f);
}

/* Premultiplied RGBA8 pixels of a PNG, scaled to W x H. */
static uint8_t *
loadImage(const char *path, size_t w, size_t h)
{
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	CGImageSourceRef src = url ? CGImageSourceCreateWithURL(url, NULL) : NULL;
	CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
	uint8_t *px = img ? calloc(w * h, 4) : NULL;
	if (px) {
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
		CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
		CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
		CGContextRelease(ctx);
		CGColorSpaceRelease(cs);
	}
	if (img) {
		CGImageRelease(img);
	}
	if (src) {
		CFRelease(src);
	}
	if (url) {
		CFRelease(url);
	}
	return px;
}

static void
textured(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib, const char *png)
{
	const NSUInteger TW = 480, TH = 487, W = 512, H = 512;
	uint8_t *img = loadImage(png, TW, TH);
	printf("image %s: %s\n", png, img ? "decoded 480x487" : "not loaded");
	check(img != NULL, "image decoded (ImageIO)");
	if (!img) {
		return;
	}
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
	    width:TW height:TH mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> tex = [device newTextureWithDescriptor:td];
	[tex replaceRegion:MTLRegionMake2D(0, 0, TW, TH) mipmapLevel:0 withBytes:img bytesPerRow:TW * 4];
	static uint8_t back[480 * 487 * 4];
	[tex getBytes:back bytesPerRow:TW * 4 fromRegion:MTLRegionMake2D(0, 0, TW, TH) mipmapLevel:0];
	check(tex && !memcmp(back, img, sizeof(back)), "texture upload and read-back (replaceRegion/getBytes)");
	td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H
	    mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> target = [device newTextureWithDescriptor:td];
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = MTLSamplerMinMagFilterLinear;
	sd.magFilter = MTLSamplerMinMagFilterLinear;
	id<MTLSamplerState> linear = [device newSamplerStateWithDescriptor:sd];
	check(linear != nil, "sampler state");
	NSError *error = nil;
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"quad_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"quad_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = YES;       /* premultiplied alpha */
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	id<MTLRenderPipelineState> bound = [device newRenderPipelineStateWithDescriptor:pd error:&error];
	pd.fragmentFunction = [lib newFunctionWithName:@"quad_fragment_faded"];
	id<MTLRenderPipelineState> faded = [device newRenderPipelineStateWithDescriptor:pd error:&error];
	printf("textured pipelines: %s\n", bound && faded ? "OK" : error.localizedDescription.UTF8String);
	check(target && bound && faded, "textured pipelines (bound and constexpr sampler)");
	if (!target || !bound || !faded || !linear) {
		free(img);
		return;
	}
	/* triangle strips: xy, uv (uv y down, like the image) */
	const float big[4][4] = { { -0.9f, 0.9f, 0, 0 }, { 0.9f, 0.9f, 1, 0 }, { -0.9f, -0.9f, 0, 1 },
		{ 0.9f, -0.9f, 1, 1 } };
	const float small[4][4] = { { 0.45f, -0.45f, 0, 0 }, { 0.95f, -0.45f, 1, 0 }, { 0.45f, -0.95f, 0, 1 },
		{ 0.95f, -0.95f, 1, 1 } };
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = target;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.30, 0.55, 1.0);
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	[e setRenderPipelineState:bound];
	[e setVertexBytes:big length:sizeof(big) atIndex:0];
	[e setFragmentTexture:tex atIndex:0];
	[e setFragmentSamplerState:linear atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[e setRenderPipelineState:faded];
	[e setVertexBytes:small length:sizeof(small) atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[e endEncoding];
	CFTimeInterval t0 = CACurrentMediaTime();
	[cb commit];
	[cb waitUntilCompleted];
	printf("textured render: status %lu, error %s, %.2f ms\n", (unsigned long)cb.status,
	    cb.error.localizedDescription.UTF8String ?: "none", (CACurrentMediaTime() - t0) * 1e3);
	static uint8_t px[512 * 512 * 4];
	[target getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	writePPM("/var/tmp/sweet-mtltest-texture.ppm", px, W, H);
	/* The big quad maps pixel (x, y) to texel ((x + .5 - 25.6) / 460.8 * TW, ...). Compare a grid of
	 * points whose 3x3 texel neighborhood is flat (edges blur under linear filtering) with the texel
	 * blended over the background: premultiplied, out = texel + background * (1 - alpha). */
	const uint8_t *corner = &px[(4 * W + 4) * 4];
	const int bgc[3] = { corner[2], corner[1], corner[0] };   /* RGB */
	unsigned flat = 0, good = 0;
	for (NSUInteger y = 40; y < 470; y += 7) {
		for (NSUInteger x = 40; x < 470; x += 7) {
			if (x >= 360 && y >= 360) {
				continue;       /* under the small faded copy */
			}
			int tx = (int)(((double)x + 0.5 - 25.6) / 460.8 * TW), ty = (int)(((double)y + 0.5 - 25.6) / 460.8 * TH);
			if (tx < 1 || ty < 1 || tx >= (int)TW - 1 || ty >= (int)TH - 1) {
				continue;
			}
			const uint8_t *t0 = &img[(ty * TW + tx) * 4];
			BOOL uniform = YES;
			for (int dy = -1; dy <= 1 && uniform; ++dy) {
				for (int dx = -1; dx <= 1 && uniform; ++dx) {
					const uint8_t *t = &img[((ty + dy) * TW + tx + dx) * 4];
					for (int k = 0; k < 4; ++k) {
						uniform &= abs(t[k] - t0[k]) <= 3;
					}
				}
			}
			if (!uniform) {
				continue;
			}
			flat++;
			const uint8_t *o = &px[(y * W + x) * 4];
			int diff = 0;
			for (int k = 0; k < 3; ++k) {
				int want = t0[k] + bgc[k] * (255 - t0[3]) / 255;
				diff = MAX(diff, abs((int)o[2 - k] - want));
			}
			good += diff <= 6;
		}
	}
	printf("texture compare: %u of %u flat points match the image over the background\n", good, flat);
	check(cb.status == MTLCommandBufferStatusCompleted && flat > 1000 && good * 100 >= flat * 98,
	    "texture sampled at the right places (98 % of flat points)");
	check(corner[0] > 130 && corner[0] < 150 && corner[1] > 70 && corner[1] < 85 && corner[2] < 5,
	    "background clear color");
	free(img);
}

static void
framebufferRead(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib)
{
	const NSUInteger W = 64, H = 64;
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
	    width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> tex = [device newTextureWithDescriptor:td];
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"invert_fragment"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	NSError *error = nil;
	id<MTLRenderPipelineState> invert = pd.fragmentFunction ? [device newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
	printf("framebuffer-read pipeline: %s\n", invert ? "OK" : (pd.fragmentFunction ? error.localizedDescription.UTF8String :
	    "invert_fragment not translated"));
	check(tex && invert, "framebuffer-read pipeline ([[color(0)]] argument)");
	if (!tex || !invert) {
		return;
	}
	/* left half and top-left quarter: one triangle covers x < 0 (whole height), the other y > 0 (whole width) */
	const struct vtx a[3] = { { { -1, -1 }, { 0, 0 }, { 0, 0, 0, 1 } }, { { 0, -1 }, { 0, 0 }, { 0, 0, 0, 1 } },
		{ { 0, 3 }, { 0, 0 }, { 0, 0, 0, 1 } } };
	const struct vtx b[3] = { { { -1, 0 }, { 0, 0 }, { 0, 0, 0, 1 } }, { { 3, 0 }, { 0, 0 }, { 0, 0, 0, 1 } },
		{ { -1, 1 }, { 0, 0 }, { 0, 0, 0, 1 } } };
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	[e setRenderPipelineState:invert];
	[e setVertexBytes:a length:sizeof(a) atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e setVertexBytes:b length:sizeof(b) atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	static uint8_t px[64 * 64 * 4];
	[tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	/* RGBA at (x, y), y from the top. Draw a covers the band right of the line (-1,-1)-(0,3) and left of
	 * x = 0; draw b the band above y = 0 and below the line (3,0)-(-1,1). (8,8): only b (inverted);
	 * (8,56): only a (inverted); (24,24): both (inverted twice: the clear color); (56,56): none */
	const uint8_t *onlyB = &px[(8 * W + 8) * 4], *onlyA = &px[(56 * W + 8) * 4], *both = &px[(24 * W + 24) * 4],
	    *none = &px[(56 * W + 56) * 4];
	printf("framebuffer read: status %lu %s; RGBA only-b %u,%u,%u only-a %u,%u,%u both %u,%u,%u none %u,%u,%u\n",
	    (unsigned long)cb.status, cb.error.localizedDescription.UTF8String ?: "", onlyB[0], onlyB[1], onlyB[2],
	    onlyA[0], onlyA[1], onlyA[2], both[0], both[1], both[2], none[0], none[1], none[2]);
#define NEAR(p, r, g, bb) (abs((p)[0] - (r)) <= 2 && abs((p)[1] - (g)) <= 2 && abs((p)[2] - (bb)) <= 2)
	check(cb.status == MTLCommandBufferStatusCompleted && NEAR(none, 64, 128, 191) && NEAR(onlyA, 191, 127, 64) &&
	    NEAR(onlyB, 191, 127, 64) && NEAR(both, 64, 128, 191),
	    "framebuffer read: inverted once where one draw covers, restored where both do");
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

		if (argc > 2) {
			gImage = argv[2];
		}
		kernels(device, queue, argc > 1 ? argv[1] : "/var/jb/usr/share/sweet-mtltest.metallib");
		printf("%s\n", fails ? "SOME CHECKS FAILED" : "ALL OK: METAL KERNELS AND RENDERING ON TURNIP");
		return fails != 0;
	}
}
