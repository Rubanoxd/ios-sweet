#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("=== Scanning IOSurfaces 1..300 ===\n");
        int found = 0;
        for (uint32_t id = 1; id <= 300; id++) {
            IOSurfaceRef s = IOSurfaceLookup(id);
            if (!s) continue;
            found++;
            size_t w = IOSurfaceGetWidth(s);
            size_t h = IOSurfaceGetHeight(s);
            size_t pitch = IOSurfaceGetBytesPerRow(s);
            OSType fmt = IOSurfaceGetPixelFormat(s);
            size_t alloc = IOSurfaceGetAllocSize(s);
            char fmtStr[5] = { (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, 0 };

            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s);
            
            size_t nonZero = 0;
            if (base) {
                // sample up to 1MB or alloc
                size_t checkLen = alloc < (1024*1024) ? alloc : (1024*1024);
                for (size_t i = 0; i < checkLen; i++) {
                    if (base[i] != 0) nonZero++;
                }
            }

            printf("Surface ID %u: %zux%zu pitch=%zu fmt='%s' (0x%08x) alloc=%zu base=%p nonZeroBytesIn1MB=%zu\n",
                   id, w, h, pitch, fmtStr, fmt, alloc, base, nonZero);

            if (base && w > 0 && h > 0 && nonZero > 1000) {
                printf("  Sample [0..3]: %u,%u,%u,%u | [100..103]: %u,%u,%u,%u\n",
                       base[0], base[1], base[2], base[3], base[100], base[101], base[102], base[103]);
                
                // If it's BGRA (or common formats) and display sized, dump a PPM
                if (w >= 1000 && h >= 1000 && (fmt == 'BGRA' || fmt == 0 || fmt == 'RGBA')) {
                    char path[128];
                    snprintf(path, sizeof(path), "/var/tmp/surface_%u_%zux%zu.ppm", id, w, h);
                    FILE *f = fopen(path, "wb");
                    if (f) {
                        fprintf(f, "P6 %zu %zu 255\n", w, h);
                        for (size_t y = 0; y < h; y++) {
                            const uint8_t *row = base + y * pitch;
                            for (size_t x = 0; x < w; x++) {
                                const uint8_t *px = row + x * 4;
                                if (fmt == 'BGRA') {
                                    fputc(px[2], f); // R
                                    fputc(px[1], f); // G
                                    fputc(px[0], f); // B
                                } else {
                                    fputc(px[0], f); // R
                                    fputc(px[1], f); // G
                                    fputc(px[2], f); // B
                                }
                            }
                        }
                        fclose(f);
                        printf("  Saved dump to %s\n", path);
                    }
                }
            }

            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
            CFRelease(s);
        }
        printf("=== Scan complete: found %d surfaces ===\n", found);
    }
    return 0;
}
