/*
 * sweet-backdrop: QuartzCore's material path off screen, on an IOSurface target
 * like the render server's display. A blue background, a red card and, over
 * half of the card, a CABackdropLayer with a gaussian blur (the dock's and the
 * search pill's material). The backdrop region must show the blurred red/blue
 * underneath, not black: on the phone it came out as a dark box.
 *   sweet-backdrop [iosurface|private]   (default iosurface)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#include <stdio.h>
#include <string.h>

static CGColorRef rgba(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	const CGFloat c[4] = { r, g, b, a };
	CGColorRef color = CGColorCreate(cs, c);
	CGColorSpaceRelease(cs);
	return color;
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IONBF, 0);
	@autoreleasepool {
		BOOL onSurface = !(argc > 1 && !strcmp(argv[1], "private"));
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		printf("device: %s, target %s\n", device ? device.name.UTF8String : "nil", onSurface ? "IOSurface" : "private");
		if (!device) return 1;
		const NSUInteger W = 400, H = 400, row = 1600;
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		IOSurfaceRef surface = NULL;
		id<MTLTexture> target;
		if (onSurface) {
			NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
			    (id)kIOSurfaceBytesPerRow: @(row), (id)kIOSurfacePixelFormat: @('BGRA') };
			surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			td.storageMode = MTLStorageModeShared;
			target = [device newTextureWithDescriptor:td iosurface:surface plane:0];
		} else {
			target = [device newTextureWithDescriptor:td];
		}
		printf("target: %s\n", target ? "yes" : "nil");
		if (!target) return 1;

		CALayer *root = [CALayer layer];
		root.frame = CGRectMake(0, 0, W, H);
		root.backgroundColor = rgba(0.0, 0.30, 0.55, 1.0);
		CALayer *card = [CALayer layer];
		card.frame = CGRectMake(40, 40, 320, 160);
		card.backgroundColor = rgba(0.85, 0.10, 0.20, 1.0);
		[root addSublayer:card];
		Class backdropClass = NSClassFromString(@"CABackdropLayer");
		CALayer *backdrop = backdropClass ? [backdropClass layer] : nil;
		printf("CABackdropLayer: %s\n", backdrop ? "yes" : "no");
		if (!backdrop) return 1;
		backdrop.frame = CGRectMake(0, 120, W, 160);       /* covers the card's lower half and the blue below it */
		id blur = [NSClassFromString(@"CAFilter") performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"gaussianBlur"];
		[blur setValue:@20 forKey:@"inputRadius"];
		backdrop.filters = blur ? @[ blur ] : nil;
		[root addSublayer:backdrop];

		CARenderer *renderer = [CARenderer rendererWithMTLTexture:target options:nil];
		renderer.layer = root;
		renderer.bounds = CGRectMake(0, 0, W, H);
		[CATransaction flush];
		for (int frame = 0; frame < 3; ++frame) {
			[renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
			[renderer addUpdateRect:renderer.bounds];
			[renderer render];
			[renderer endFrame];
		}
		id<MTLCommandQueue> q = [device newCommandQueue];
		id<MTLCommandBuffer> fence = [q commandBuffer];
		[fence commit];
		[fence waitUntilCompleted];
		usleep(200000);

		static uint8_t px[400 * 1600];
		if (surface) {
			IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
			const uint8_t *base = IOSurfaceGetBaseAddress(surface);
			for (NSUInteger y = 0; y < H; ++y) memcpy(px + y * W * 4, base + y * row, W * 4);
			IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
		} else {
			[target getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
		}
		FILE *f = fopen("/var/tmp/sweet-backdrop.ppm", "wb");
		if (f) {
			fprintf(f, "P6 %lu %lu 255\n", (unsigned long)W, (unsigned long)H);
			for (NSUInteger i = 0; i < W * H; ++i) { fputc(px[i * 4 + 2], f); fputc(px[i * 4 + 1], f); fputc(px[i * 4], f); }
			fclose(f);
		}
#define AT(x, y) (&px[((y) * W + (x)) * 4])
		const uint8_t *cardTop = AT(200, 80), *underCard = AT(200, 160), *underBlue = AT(200, 260), *clear = AT(200, 350);
		printf("BGRA card %u,%u,%u | backdrop over card %u,%u,%u | backdrop over blue %u,%u,%u | blue %u,%u,%u\n",
		    cardTop[0], cardTop[1], cardTop[2], underCard[0], underCard[1], underCard[2], underBlue[0], underBlue[1], underBlue[2], clear[0], clear[1], clear[2]);
		int dark = underCard[2] < 60 && underBlue[0] < 60;
		printf("%s\n", dark ? "BACKDROP DARK: the material lost what lies under it" : "backdrop shows what lies under it");
		return dark;
	}
}
