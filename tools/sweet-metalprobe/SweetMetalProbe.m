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
#include <unistd.h>
#include "turnip-job.h"

#define TURNIP_ICD "/var/jb/usr/lib/libvulkan_freedreno.dylib"

extern const char *getprogname(void);

static void
probe_log(const char *what, unsigned port)
{
	static int lines;
	if (lines++ >= 32) {
		return;
	}
	char line[384];
	int n = snprintf(line, sizeof(line), "%s[%d] uid %u: %s port 0x%x\n",
	    getprogname(), getpid(), getuid(), what, port);
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
	char msg[256], line[300];
	int ok = sweet_turnip_job(TURNIP_ICD, msg, sizeof(msg));
	snprintf(line, sizeof(line), "turnip %s: %s", ok ? "OK" : "FAILED", msg);
	probe_log(line, 0);
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
		probe_log("turnip thread started", 0);
	} else {
		probe_log("turnip thread not started", 0);
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
	turnip_start();
	return nil;
}
@end
