/*
 * sweet-carender: QuartzCore's own compositor on the SweetMetal device.
 * Builds a small layer tree (a background, rounded layers with opacity,
 * optionally a blurred one) and renders it with
 * +[CARenderer rendererWithMTLTexture:options:] into a texture of the
 * device MTLCreateSystemDefaultDevice returns; that is CA::OGL::MetalContext,
 * the code backboardd composites the screen with. Writes the frame to
 * /var/tmp/sweet-carender.ppm and checks a few pixels.
 *   sweet-carender [blur]
 * The process must be a SweetMetal client (/var/jb/etc/sweetmetal.clients).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#include <objc/runtime.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>

/* a crash inside QuartzCore: print where, then die as usual */
static void
crashed(int sig)
{
	void *frames[48];
	int n = backtrace(frames, 48);
	dprintf(2, "\n*** signal %d, backtrace:\n", sig);
	backtrace_symbols_fd(frames, n, 2);
	signal(sig, SIG_DFL);
	raise(sig);
}

static int fails;

static void
check(BOOL ok, const char *what)
{
	printf("%s: %s\n", what, ok ? "OK" : "FAILED");
	fails += !ok;
}

static CGColorRef
rgba(CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	const CGFloat c[4] = { r, g, b, a };
	CGColorRef color = CGColorCreate(cs, c);
	CGColorSpaceRelease(cs);
	return color;
}

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	signal(SIGSEGV, crashed);
	signal(SIGBUS, crashed);
	signal(SIGILL, crashed);
	signal(SIGTRAP, crashed);
	signal(SIGABRT, crashed);
	@autoreleasepool {
		BOOL blur = argc > 1 && !strcmp(argv[1], "blur");
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		printf("device: %s\n", device ? device.name.UTF8String : "nil");
		if (!device) {
			return 1;
		}
		const NSUInteger W = 400, H = 400;
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		    width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		id<MTLTexture> target = [device newTextureWithDescriptor:td];
		check(target != nil, "target texture");

		CALayer *root = [CALayer layer];
		root.frame = CGRectMake(0, 0, W, H);
		root.backgroundColor = rgba(0.0, 0.30, 0.55, 1.0);          /* blue */
		CALayer *card = [CALayer layer];                             /* red, rounded */
		card.frame = CGRectMake(40, 40, 200, 140);
		card.backgroundColor = rgba(0.65, 0.0, 0.27, 1.0);
		card.cornerRadius = 30;
		[root addSublayer:card];
		CALayer *veil = [CALayer layer];                             /* white at 50 % */
		veil.frame = CGRectMake(160, 120, 200, 200);
		veil.backgroundColor = rgba(1.0, 1.0, 1.0, 1.0);
		veil.opacity = 0.5;
		veil.cornerRadius = 100;                                     /* a circle */
		[root addSublayer:veil];
		if (blur) {
			Class filterClass = NSClassFromString(@"CAFilter");
			id filter = [filterClass performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"gaussianBlur"];
			[filter setValue:@12 forKey:@"inputRadius"];
			card.filters = filter ? @[ filter ] : nil;
			printf("blur filter: %s\n", filter ? "yes" : "no CAFilter");
		}

		CARenderer *renderer = [CARenderer rendererWithMTLTexture:target options:nil];
		printf("CARenderer: %s\n", renderer ? "yes" : "nil");
		check(renderer != nil, "CARenderer on the SweetMetal texture");
		if (!renderer) {
			return 1;
		}
		renderer.layer = root;
		renderer.bounds = CGRectMake(0, 0, W, H);
		/* no run loop here: commit the implicit transaction, or the renderer sees an empty tree */
		[CATransaction flush];
		CFTimeInterval t0 = CACurrentMediaTime();
		for (int frame = 0; frame < 2; ++frame) {
			[renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
			[renderer addUpdateRect:renderer.bounds];
			[renderer render];
			[renderer endFrame];
		}
		printf("two frames in %.1f ms\n", (CACurrentMediaTime() - t0) * 1e3);

		/* CARenderer commits its own command buffer; wait for the device to drain */
		id<MTLCommandQueue> q = [device newCommandQueue];
		id<MTLCommandBuffer> fence = [q commandBuffer];
		[fence commit];
		[fence waitUntilCompleted];
		usleep(100000);

		static uint8_t px[400 * 400 * 4];
		[target getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
		FILE *f = fopen("/var/tmp/sweet-carender.ppm", "wb");
		if (f) {
			fprintf(f, "P6 %lu %lu 255\n", (unsigned long)W, (unsigned long)H);
			for (NSUInteger i = 0; i < W * H; ++i) {
				fputc(px[i * 4 + 2], f);
				fputc(px[i * 4 + 1], f);
				fputc(px[i * 4 + 0], f);
			}
			fclose(f);
		}
#define AT(x, y) (&px[((y) * W + (x)) * 4])
		const uint8_t *bg = AT(380, 20), *cardc = AT(100, 100), *corner = AT(42, 42), *mix = AT(260, 220);
		printf("BGRA background %u,%u,%u card %u,%u,%u card corner %u,%u,%u veil over background %u,%u,%u\n",
		    bg[0], bg[1], bg[2], cardc[0], cardc[1], cardc[2], corner[0], corner[1], corner[2], mix[0], mix[1], mix[2]);
		check(abs(bg[0] - 140) <= 6 && abs(bg[1] - 77) <= 6 && bg[2] <= 6, "background layer");
		check(abs(cardc[2] - 166) <= 8 && cardc[1] <= 8 && abs(cardc[0] - 69) <= 8, "red card layer");
		check(abs(corner[0] - 140) <= 10 && corner[2] <= 20, "rounded corner shows the background");
		check(abs(mix[0] - 197) <= 8 && abs(mix[1] - 166) <= 8 && abs(mix[2] - 128) <= 8,
		    "50 % white circle blended over the background");
		printf("%s\n", fails ? "SOME CHECKS FAILED" : "ALL OK: QUARTZCORE COMPOSITES ON TURNIP");
		return fails != 0;
	}
}
