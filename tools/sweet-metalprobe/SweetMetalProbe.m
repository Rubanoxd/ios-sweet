/*
 * SweetMetalProbe.bundle: the diagnostic Metal plugin of xnu patch 0096.
 * With sweetmetal=1 the kernel's IOAcceleratorES names this bundle in
 * MetalPluginName, Metal.framework loads it from /System/Library/Extensions
 * and calls -[SweetMetalProbe initWithAcceleratorPort:]. The probe appends
 * one line per load and per call to /var/tmp/sweetmetal.log (process, pid,
 * uid, port) and returns nil, so Metal reports no device and every process
 * keeps the CPU renderer it uses today.
 *
 * Stage 2: in SpringBoard (and in sweet-mtlquery, for tests from a shell)
 * the first call also starts a thread that runs one Turnip compute job
 * through our GPU user client (turnip-job.c) and logs its result; the
 * thread keeps a GPU hang from blocking the host's main thread.
 *
 * Stage 3: client processes get a real device instead of nil (the plugin
 * object itself, see SweetMetalDevice.m). The clients are the process names
 * listed one per line in /var/jb/etc/sweetmetal.clients, or only
 * sweet-mtltest when that file is missing; backboardd is never one yet, so
 * the render server keeps compositing on the CPU.
 *
 * Built without ARC: Metal allocates the object before calling the
 * initializer, and returning nil under ARC would run _MTLDevice's dealloc
 * on an object its own init never set up. The few bytes are leaked instead.
 */
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <unistd.h>
#include "SweetMetalDevice.h"
#include "turnip-job.h"
#include <objc/runtime.h>

#define TURNIP_ICD "/var/jb/usr/lib/libvulkan_freedreno.dylib"

extern const char *getprogname(void);

void
sweet_metal_log(const char *fmt, ...)
{
	static int lines;
	if (__sync_fetch_and_add(&lines, 1) >= 64) {
		return;
	}
	char what[320], line[384];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(what, sizeof(what), fmt, ap);
	va_end(ap);
	int n = snprintf(line, sizeof(line), "%s[%d] uid %u: %s\n", getprogname(), getpid(), getuid(), what);
	int fd = open("/var/tmp/sweetmetal.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		(void)fchmod(fd, 0666);
		(void)write(fd, line, n > 0 && n < (int)sizeof(line) ? (size_t)n : strlen(line));
		close(fd);
	}
}

static void *
turnip_thread(void *arg)
{
	(void)arg;
	char msg[256];
	int ok = sweet_turnip_job(TURNIP_ICD, msg, sizeof(msg));
	sweet_metal_log("turnip %s: %s", ok ? "OK" : "FAILED", msg);
	return NULL;
}

static void
turnip_start(void)
{
	static int started;
	const char *name = getprogname();
	if (started || !name || (strcmp(name, "SpringBoard") != 0 && strcmp(name, "sweet-mtlquery") != 0)) {
		return;
	}
	started = 1;
	pthread_t t;
	if (pthread_create(&t, NULL, turnip_thread, NULL) == 0) {
		pthread_detach(t);
		sweet_metal_log("turnip thread started");
	} else {
		sweet_metal_log("turnip thread not started");
	}
}

__attribute__((constructor)) static void
probe_loaded(void)
{
	sweet_metal_log("bundle loaded");
}

static int
is_client(void)
{
	const char *name = getprogname();
	if (!name || strcmp(name, "backboardd") == 0) {
		return 0;
	}
	FILE *f = fopen("/var/jb/etc/sweetmetal.clients", "r");
	if (!f) {
		return strcmp(name, "sweet-mtltest") == 0;
	}
	char line[128];
	int found = 0;
	while (!found && fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\r\n")] = 0;
		found = strcmp(line, name) == 0;
	}
	fclose(f);
	return found;
}

@interface SweetMetalProbe (DeviceEntry)
- (void)sweetBecomeDevice;
@end

@implementation SweetMetalProbe
- (id)initWithAcceleratorPort:(unsigned)port
{
	if (!is_client()) {
		sweet_metal_log("initWithAcceleratorPort: port 0x%x, returns nil", port);
		turnip_start();
		return nil;
	}
	char err[256];
	if (!sweet_metal_open(port, err, sizeof(err))) {
		sweet_metal_log("initWithAcceleratorPort: port 0x%x, no device: %s", port, err);
		return nil;
	}
	if (!(self = [super init])) {
		sweet_metal_log("initWithAcceleratorPort: -[_MTLDevice init] returned nil");
		return nil;
	}
	[self sweetBecomeDevice];
	sweet_metal_log("initWithAcceleratorPort: port 0x%x, returns a device (_MTLDevice is %zu bytes)", port,
	    class_getInstanceSize(objc_getClass("_MTLDevice")));
	return self;
}
@end
