/*
 * sweet-mtlquery: asks Metal for its devices the way apps do and prints
 * the result, to drive the discovery of xnu patch 0096 from a shell.
 *   sweet-mtlquery [SECS]   (stay SECS seconds, e.g. for the plugin's
 *                            Turnip thread to finish)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		printf("MTLCreateSystemDefaultDevice: %s\n", device ? device.name.UTF8String : "nil");
		if (argc > 1) {
			sleep((unsigned)atoi(argv[1]));
		}
		return device ? 0 : 1;
	}
}
