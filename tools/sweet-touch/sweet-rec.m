/*
 * sweet-rec: records the screen from inside iOS, for looking at transitions without a camera.
 *
 *   sweet-rec SECONDS [FPS] > out.raw
 *
 * Every 1/FPS s, each screen-sized IOSurface (1125x2436 or 1080x2400, plane 0 read as BGRA) is
 * sampled 4x smaller and written as a record: "SREC" id(u32) w(u32) h(u32) t_ms(u32) then w*h*3
 * bytes of RGB; bit 31 of id is set when the surface was in use by the GPU (being drawn). tools/sweet-touch/rec2png.py turns the stream into PNG frames.
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* The Adreno does not snoop the CPU caches: drop the lines over what the GPU wrote before reading it. */
static void invalidate(const void *base, size_t len)
{
	for (uintptr_t a = (uintptr_t)base & ~63UL; a < (uintptr_t)base + len; a += 64) {
		__asm__ volatile("dc civac, %0" : : "r"(a) : "memory");
	}
	__asm__ volatile("dsb sy" : : : "memory");
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		double secs = argc > 1 ? atof(argv[1]) : 3, fps = argc > 2 ? atof(argv[2]) : 10;
		IOSurfaceRef surf[16];
		int n = 0;
		for (uint32_t id = 1; id <= 4000 && n < 16; id++) {
			IOSurfaceRef s = IOSurfaceLookup(id);
			if (!s) {
				continue;
			}
			size_t pc = IOSurfaceGetPlaneCount(s);
			size_t w = pc ? IOSurfaceGetWidthOfPlane(s, 0) : IOSurfaceGetWidth(s);
			size_t h = pc ? IOSurfaceGetHeightOfPlane(s, 0) : IOSurfaceGetHeight(s);
			/* the composited 1125x2436 display surfaces (two planes on the GPU path; SWEET_REC_ALL=1: any) */
			if (w >= 1100 && h >= 2400 && (pc == 2 || getenv("SWEET_REC_ALL"))) {
				surf[n++] = s;
			} else {
				CFRelease(s);
			}
		}
		mach_timebase_info_data_t tb;
		mach_timebase_info(&tb);
		uint64_t start = mach_absolute_time();
		uint8_t *row = malloc(4096 * 3);
		for (int f = 0; f < (int)(secs * fps); f++) {
			uint64_t now = mach_absolute_time();
			uint32_t ms = (uint32_t)((now - start) * tb.numer / tb.denom / 1000000);
			for (int i = 0; i < n; i++) {
				IOSurfaceRef s = surf[i];
				size_t pc = IOSurfaceGetPlaneCount(s);
				uint32_t w = (uint32_t)(pc ? IOSurfaceGetWidthOfPlane(s, 0) : IOSurfaceGetWidth(s)) / 4;
				uint32_t h = (uint32_t)(pc ? IOSurfaceGetHeightOfPlane(s, 0) : IOSurfaceGetHeight(s)) / 4;
				size_t rb = pc ? IOSurfaceGetBytesPerRowOfPlane(s, 0) : IOSurfaceGetBytesPerRow(s);
				if (rb == 0) {
					rb = IOSurfaceGetBytesPerRow(s);	/* 2-plane XR10 display surfaces report rows of 0 */
				}
				const uint8_t *b = pc ? IOSurfaceGetBaseAddressOfPlane(s, 0) : IOSurfaceGetBaseAddress(s);
				/* Bit 31 of the id: the GPU was using the surface (being drawn: not what is on screen). */
				int busy = IOSurfaceIsInUse(s);
				invalidate(b, rb * h * 4);
				uint32_t hdr[5] = { 0x43455253, IOSurfaceGetID(s) | (busy ? 0x80000000u : 0), w, h, ms };
				fwrite(hdr, 4, 5, stdout);
				for (uint32_t y = 0; y < h; y++) {
					const uint8_t *p = b + (size_t)y * 4 * rb;
					for (uint32_t x = 0; x < w; x++, p += 16) {
						row[x * 3] = p[2];
						row[x * 3 + 1] = p[1];
						row[x * 3 + 2] = p[0];
					}
					fwrite(row, 3, w, stdout);
				}
			}
			uint64_t target = start + (uint64_t)((f + 1) / fps * 1e9) * tb.denom / tb.numer;
			uint64_t t = mach_absolute_time();
			if (target > t) {
				usleep((useconds_t)((target - t) * tb.numer / tb.denom / 1000));
			}
		}
		fflush(stdout);
		fprintf(stderr, "%d surfaces\n", n);
	}
	return 0;
}
