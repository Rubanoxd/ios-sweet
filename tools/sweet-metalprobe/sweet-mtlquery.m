/*
 * sweet-mtlquery: asks Metal for its devices the way apps do and prints
 * the result, to drive the discovery of xnu patch 0096 from a shell.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int
main(void)
{
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		printf("MTLCreateSystemDefaultDevice: %s\n", device ? device.name.UTF8String : "nil");
		return device ? 0 : 1;
	}
}
