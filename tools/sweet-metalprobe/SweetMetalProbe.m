/*
 * SweetMetalProbe.bundle: the diagnostic Metal plugin of xnu patch 0096.
 * With sweetmetal=1 the kernel's IOAcceleratorES names this bundle in
 * MetalPluginName, Metal.framework loads it from /System/Library/Extensions
 * and calls -[SweetMetalProbe initWithAcceleratorPort:]. The probe appends
 * one line per load and per call to /var/tmp/sweetmetal.log (process, pid,
 * uid, port) and returns nil, so Metal reports no device and every process
 * keeps the CPU renderer it uses today.
 *
 * Built without ARC: Metal allocates the object before calling the
 * initializer, and returning nil under ARC would run _MTLDevice's dealloc
 * on an object its own init never set up. The few bytes are leaked instead.
 */
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern const char *getprogname(void);

static void
probe_log(const char *what, unsigned port)
{
	static int lines;
	if (lines++ >= 32) {
		return;
	}
	char line[256];
	int n = snprintf(line, sizeof(line), "%s[%d] uid %u: %s port 0x%x\n",
	    getprogname(), getpid(), getuid(), what, port);
	int fd = open("/var/tmp/sweetmetal.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		(void)fchmod(fd, 0666);
		(void)write(fd, line, n > 0 && n < (int)sizeof(line) ? (size_t)n : strlen(line));
		close(fd);
	}
}

__attribute__((constructor)) static void
probe_loaded(void)
{
	probe_log("bundle loaded", 0);
}

@interface _MTLDevice : NSObject
@end

@interface SweetMetalProbe : _MTLDevice
- (id)initWithAcceleratorPort:(unsigned)port;
@end

@implementation SweetMetalProbe
- (id)initWithAcceleratorPort:(unsigned)port
{
	probe_log("initWithAcceleratorPort: (returns nil)", port);
	return nil;
}
@end
