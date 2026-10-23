/*
 * sweet-shot: dumps every screen-sized IOSurface (plane 0 as BGRA) to /var/tmp/shot-ID.ppm,
 * 4x smaller, after invalidating the CPU cache over it (the GPU does not snoop it).
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <stdio.h>

static void invalidate(const void *base, size_t len)
{
	for (uintptr_t a = (uintptr_t)base & ~63UL; a < (uintptr_t)base + len; a += 64) {
		__asm__ volatile("dc civac, %0" : : "r"(a) : "memory");
	}
	__asm__ volatile("dsb sy" : : : "memory");
}

int main(void)
{
	@autoreleasepool {
		for (uint32_t id = 1; id <= 4000; id++) {
			IOSurfaceRef s = IOSurfaceLookup(id);
			if (!s) {
				continue;
			}
			size_t pc = IOSurfaceGetPlaneCount(s);
			size_t w = pc ? IOSurfaceGetWidthOfPlane(s, 0) : IOSurfaceGetWidth(s);
			size_t h = pc ? IOSurfaceGetHeightOfPlane(s, 0) : IOSurfaceGetHeight(s);
			if (w < 1000 || h < 2000) {
				CFRelease(s);
				continue;
			}
			size_t row = pc ? IOSurfaceGetBytesPerRowOfPlane(s, 0) : IOSurfaceGetBytesPerRow(s);
			if (row == 0) {
				row = IOSurfaceGetBytesPerRow(s);	/* the display's 2-plane XR10 surfaces report rows of 0 */
			}
			OSType f = IOSurfaceGetPixelFormat(s);
			IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
			const uint8_t *b = pc ? IOSurfaceGetBaseAddressOfPlane(s, 0) : IOSurfaceGetBaseAddress(s);
			if (!b) {
				b = IOSurfaceGetBaseAddress(s);
			}
			if (b) {
				invalidate(b, row * h);
				char p[64];
				snprintf(p, sizeof(p), "/var/tmp/shot-%u.ppm", id);
				FILE *o = fopen(p, "wb");
				fprintf(o, "P6\n%zu %zu\n255\n", w / 4, h / 4);
				for (size_t y = 0; y < h / 4; y++) {
					for (size_t x = 0; x < w / 4; x++) {
						const uint8_t *q = b + (y * 4) * row + (x * 4) * 4;
						uint8_t px[3] = { q[2], q[1], q[0] };
						fwrite(px, 1, 3, o);
					}
				}
				fclose(o);
				printf("%u %zux%zu fmt %c%c%c%c planes %zu -> %s\n", id, w, h, (char)(f >> 24), (char)(f >> 16),
				    (char)(f >> 8), (char)f, pc, p);
			}
			IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
			CFRelease(s);
		}
	}
	return 0;
}
