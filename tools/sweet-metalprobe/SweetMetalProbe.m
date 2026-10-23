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
 * sweet-mtltest when that file is missing. backboardd only gets a device
 * through /var/tmp/sweetmetal.backboardd (consumed on use) or
 * /var/tmp/sweetmetal.backboardd.always; otherwise it composites on the CPU.
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
#include <dlfcn.h>
#include "SweetMetalDevice.h"
#include "NativeBridgeMetalFrontend.h"
#include "turnip-job.h"
#include <objc/runtime.h>

#define TURNIP_ICD "/var/jb/usr/lib/libvulkan_freedreno.dylib"

extern const char *getprogname(void);
static char gCacheDir[512];

/* Tracing: always on for clients */
int
sweet_metal_tracing(void)
{
	return 1;
}

void
sweet_metal_log(const char *fmt, ...)
{
	static int lines;
	if (__sync_fetch_and_add(&lines, 1) >= 8000) {
		return;
	}
	char what[320], line[384];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(what, sizeof(what), fmt, ap);
	va_end(ap);
	int n = snprintf(line, sizeof(line), "%s[%d] uid %u: %s\n", getprogname(), getpid(), getuid(), what);
	if (n <= 0) return;
	size_t len = (n < (int)sizeof(line)) ? (size_t)n : strlen(line);

	int fd = open("/var/tmp/sweetmetal.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		(void)fchmod(fd, 0666);
		(void)write(fd, line, len);
		close(fd);
	}
	if (gCacheDir[0]) {
		char cpath[600];
		snprintf(cpath, sizeof(cpath), "%s/sweetmetal.log", gCacheDir);
		int cfd = open(cpath, O_WRONLY | O_APPEND | O_CREAT, 0666);
		if (cfd >= 0) {
			(void)write(cfd, line, len);
			close(cfd);
		}
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
	/* Only sweet-mtlquery: in SpringBoard this bring-up check held one of the kernel's few GPU address windows
	 * for the life of the process (xnu 0109 has three), and backboardd could be left without one. */
	if (started || !name || strcmp(name, "sweet-mtlquery") != 0) {
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
	if (!name) {
		return 0;
	}
	if (strcmp(name, "backboardd") == 0) {
		/* One shot: /var/tmp/sweetmetal.backboardd gives the render server a
		 * device once and is consumed, so a backboardd that dies on the GPU
		 * comes back on the CPU renderer. sweetmetal.backboardd.always keeps it. */
		if (access("/var/tmp/sweetmetal.backboardd.always", F_OK) == 0) {
			return 1;
		}
		if (unlink("/var/tmp/sweetmetal.backboardd") == 0) {
			sweet_metal_log("backboardd: one-shot GPU device (flag consumed)");
			return 1;
		}
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

static void (*orig_present)(id self, SEL _cmd);
static void my_present(id self, SEL _cmd) {
	static unsigned count;
	if (++count <= 20 || (count % 60) == 0) {
		sweet_metal_log("-[CAMetalDrawable present] #%u on %p", count, self);
	}
	if (orig_present) orig_present(self, _cmd);
}

static void swizzleDrawable(void) {
	static int done;
	if (!done) {
		done = 1;
		Class cls = objc_getClass("CAMetalDrawable");
		if (cls) {
			Method m = class_getInstanceMethod(cls, @selector(present));
			if (m) {
				orig_present = (void (*)(id, SEL))method_getImplementation(m);
				method_setImplementation(m, (IMP)my_present);
				sweet_metal_log("Swizzled -[CAMetalDrawable present]");
			}
		}
	}
}

/* The scanout (xnu 0083) shows 32-bit BGRA surfaces; QuartzCore's Metal path
 * would otherwise render the iPhone X display into two-plane RGB10A8_2P_XR10
 * surfaces. Telling it the display has no extended colors keeps BGRA8. */
static BOOL no_extended_colors(id self, SEL _cmd) { return NO; }
static void narrowDisplay(void) {
	Class cls = objc_getClass("CADisplay");
	Method m = cls ? class_getInstanceMethod(cls, @selector(supportsExtendedColors)) : NULL;
	if (m) {
		method_setImplementation(m, (IMP)no_extended_colors);
		sweet_metal_log("CADisplay supportsExtendedColors -> NO");
	}
}

/* Thread dump (kill -USR1 <pid>; the sandbox hides files from the render
 * server): a thread of the client wakes on the signal and each other
 * thread's user stack (pc, lr, then the frame-pointer chain; arm64 without
 * pointer authentication on the A11) is logged as image+offset, so a stalled
 * render server can be read without killing it. */
#include <mach/mach.h>
#include <mach-o/dyld.h>
static void dump_frame(unsigned t, unsigned i, uint64_t pc)
{
	Dl_info info;
	if (pc && dladdr((void *)pc, &info) && info.dli_fname) {
		const char *base = strrchr(info.dli_fname, '/');
		sweet_metal_log("dump t%u #%u %s+0x%llx %s+%llu", t, i, base ? base + 1 : info.dli_fname,
		    (unsigned long long)(pc - (uint64_t)info.dli_fbase), info.dli_sname ? info.dli_sname : "?",
		    info.dli_saddr ? (unsigned long long)(pc - (uint64_t)info.dli_saddr) : 0ULL);
	} else {
		sweet_metal_log("dump t%u #%u 0x%llx", t, i, (unsigned long long)pc);
	}
}
static int dump_pipe[2] = {-1, -1};
static void dump_signal(int sig) { char c = sig == SIGUSR2 ? 2 : 1; (void)write(dump_pipe[1], &c, 1); }

/* Profile (kill -USR2 <pid>): 300 samples, 10 ms apart, of every running or
 * runnable thread's pc (others are waiting); the 30 most frequent functions
 * (dladdr symbol, or image+offset) are logged with their sample counts. */
static void profile_run(void)
{
	enum { SAMPLES = 300, MAXPC = 8192 };
	static uint64_t pcs[MAXPC];
	static unsigned counts[MAXPC];
	unsigned npc = 0, total = 0;
	thread_t me = mach_thread_self();
	for (int s = 0; s < SAMPLES; s++) {
		thread_act_array_t th; mach_msg_type_number_t n = 0;
		if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) break;
		for (unsigned t = 0; t < n; t++) {
			struct thread_basic_info bi; mach_msg_type_number_t bn = THREAD_BASIC_INFO_COUNT;
			if (th[t] != me && thread_info(th[t], THREAD_BASIC_INFO, (thread_info_t)&bi, &bn) == KERN_SUCCESS &&
			    bi.run_state == TH_STATE_RUNNING && thread_suspend(th[t]) == KERN_SUCCESS) {
				arm_thread_state64_t st; mach_msg_type_number_t sn = ARM_THREAD_STATE64_COUNT;
				if (thread_get_state(th[t], ARM_THREAD_STATE64, (thread_state_t)&st, &sn) == KERN_SUCCESS) {
					unsigned i = 0;
					while (i < npc && pcs[i] != st.__pc) i++;
					if (i == npc && npc < MAXPC) { pcs[npc] = st.__pc; counts[npc] = 0; npc++; }
					if (i < MAXPC) counts[i]++;
					total++;
				}
				thread_resume(th[t]);
			}
			mach_port_deallocate(mach_task_self(), th[t]);
		}
		vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_t));
		usleep(10000);
	}
	mach_port_deallocate(mach_task_self(), me);
	/* fold pcs into functions */
	static const char *names[MAXPC]; static unsigned fcount[MAXPC]; static uint64_t fbase[MAXPC]; unsigned nf = 0;
	for (unsigned i = 0; i < npc; i++) {
		Dl_info info; uint64_t key = pcs[i]; const char *name = "?";
		if (dladdr((void *)pcs[i], &info)) { key = info.dli_saddr ? (uint64_t)info.dli_saddr : (uint64_t)info.dli_fbase; name = info.dli_sname ? info.dli_sname : info.dli_fname; }
		unsigned f = 0; while (f < nf && fbase[f] != key) f++;
		if (f == nf) { fbase[f] = key; names[f] = name; fcount[f] = 0; nf++; }
		fcount[f] += counts[i];
	}
	sweet_metal_log("profile: %u running-thread samples over %d ticks", total, SAMPLES);
	for (int k = 0; k < 30; k++) {
		unsigned best = 0, bi = ~0u;
		for (unsigned f = 0; f < nf; f++) if (fcount[f] > best) { best = fcount[f]; bi = f; }
		if (bi == ~0u) break;
		Dl_info info; const char *img = "?";
		if (dladdr((void *)fbase[bi], &info) && info.dli_fname) { const char *b = strrchr(info.dli_fname, '/'); img = b ? b + 1 : info.dli_fname; }
		sweet_metal_log("profile: %4u %5.1f%% %s %.120s", best, 100.0 * best / (total ? total : 1), img, names[bi]);
		fcount[bi] = 0;
	}
}
static void *dump_thread(void *arg)
{
	(void)arg;
	sweet_metal_log("dump thread up (kill -USR1 %d)", getpid());
	for (;;) {
		char c;
		if (read(dump_pipe[0], &c, 1) != 1) {
			sleep(1);
			continue;
		}
		if (c == 2) {
			profile_run();
			continue;
		}
		thread_act_array_t threads;
		mach_msg_type_number_t count = 0;
		if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
			continue;
		}
		thread_t me = mach_thread_self();
		/* Capture every stack with all other threads suspended and no locks taken
		 * (no malloc, no dladdr, no logging), then resume and symbolicate. */
		enum { MAXT = 64, MAXF = 40 };
		static uint64_t pcs[MAXT][MAXF];
		static unsigned nf[MAXT];
		unsigned nt = count < MAXT ? count : MAXT;
		/* Only waiting threads are read: a running or uninterruptible thread
		 * cannot be stopped (thread_get_state would wait for it), so it is only named. */
		static int stuck[MAXT];
		for (unsigned t = 0; t < nt; t++) {
			struct thread_basic_info bi;
			mach_msg_type_number_t bn = THREAD_BASIC_INFO_COUNT;
			stuck[t] = thread_info(threads[t], THREAD_BASIC_INFO, (thread_info_t)&bi, &bn) != KERN_SUCCESS ? -1 :
			    (bi.run_state == TH_STATE_WAITING || bi.run_state == TH_STATE_STOPPED) ? 0 : bi.run_state;
		}
		for (unsigned t = 0; t < nt; t++) if (threads[t] != me && !stuck[t]) thread_suspend(threads[t]);
		for (unsigned t = 0; t < nt; t++) {
			nf[t] = 0;
			if (threads[t] == me || stuck[t]) continue;
			arm_thread_state64_t st;
			mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
			if (thread_get_state(threads[t], ARM_THREAD_STATE64, (thread_state_t)&st, &n) != KERN_SUCCESS) continue;
			pcs[t][nf[t]++] = st.__pc;
			pcs[t][nf[t]++] = st.__lr;
			uint64_t fp = st.__fp;
			while (nf[t] < MAXF && fp && !(fp & 7)) {
				vm_size_t got = 0;
				uint64_t frame[2];
				if (vm_read_overwrite(mach_task_self(), fp, sizeof(frame), (vm_address_t)frame, &got) != KERN_SUCCESS || got != sizeof(frame)) break;
				if (!frame[1]) break;
				pcs[t][nf[t]++] = frame[1];
				if (frame[0] <= fp) break;
				fp = frame[0];
			}
		}
		for (unsigned t = 0; t < nt; t++) if (threads[t] != me && !stuck[t]) thread_resume(threads[t]);
		sweet_metal_log("dump: %u threads", count);
		for (unsigned t = 0; t < nt; t++) {
			if (stuck[t]) {
				char sname[64] = "";
				pthread_t sp = pthread_from_mach_thread_np(threads[t]);
				if (sp) pthread_getname_np(sp, sname, sizeof(sname));
				sweet_metal_log("dump t%u name '%s' not read: run state %d (1 running, 3 uninterruptible)", t, sname, stuck[t]);
				continue;
			}
			if (!nf[t]) continue;
			char name[64] = "";
			pthread_t pt = pthread_from_mach_thread_np(threads[t]);
			if (pt) pthread_getname_np(pt, name, sizeof(name));
			sweet_metal_log("dump t%u name '%s'", t, name);
			for (unsigned i = 0; i < nf[t]; i++) dump_frame(t, i, pcs[t][i]);
		}
		for (unsigned t = 0; t < count; t++) mach_port_deallocate(mach_task_self(), threads[t]);
		vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
		mach_port_deallocate(mach_task_self(), me);
		sweet_metal_log("dump: done");
	}
	return NULL;
}
static void start_dump_thread(void)
{
	static int started;
	if (started++) return;
	if (pipe(dump_pipe) != 0) return;
	signal(SIGUSR1, dump_signal);
	signal(SIGUSR2, dump_signal);
	pthread_t t;
	if (pthread_create(&t, NULL, dump_thread, NULL) == 0) pthread_detach(t);
}

@implementation SweetMetalProbe
- (id)initWithAcceleratorPort:(unsigned)port
{
	swizzleDrawable();
	if (!is_client()) {
		sweet_metal_log("initWithAcceleratorPort: port 0x%x, returns nil", port);
		turnip_start();
		return nil;
	}
	uint64_t registryID = 0;
	void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
	if (iokit) {
		int (*retain)(unsigned) = (int (*)(unsigned))dlsym(iokit, "IOObjectRetain");
		if (retain) retain(port);
		int (*entryID)(unsigned, uint64_t *) = (int (*)(unsigned, uint64_t *))dlsym(iokit, "IORegistryEntryGetRegistryEntryID");
		if (entryID) entryID(port, &registryID);
	}
	narrowDisplay();
	start_dump_thread();
	CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
	setenv("TU_DARWIN_SERVICE", "NativeAdrenoGpuPublished", 0);
	/* Textures over IOSurfaces (host pages) become linear images over the surface's own memory instead of
	 * shadows copied in and out on every use: what QuartzCore's layers and the display surfaces need. */
	setenv("M2V_ALIAS_HOST_PAGES", "1", 0);
	setenv("METAL2VULKAN_LOG_PIPELINES", "1", 0);
	/* Experiments without a rebuild: /var/tmp/sweetmetal.env holds KEY=VALUE lines (TU_DEBUG=sysmem,
	 * IR3_SHADER_DEBUG=nofp16, ...) put into this process's environment before Turnip loads. */
	FILE *envf = fopen("/var/tmp/sweetmetal.env", "r");
	if (envf) {
		char line[256];
		while (fgets(line, sizeof(line), envf)) {
			line[strcspn(line, "\r\n")] = 0;
			char *eq = strchr(line, '=');
			if (line[0] == '#' || !eq) continue;
			*eq = 0;
			setenv(line, eq + 1, 1);
			sweet_metal_log("env %s=%s", line, eq + 1);
		}
		fclose(envf);
	}
	/* Turnip's own disk cache of compiled shaders (NIR -> ir3), so a pipeline compiled once is not compiled again
	 * in the next process (pipelines took up to 965 ms the first time in the render server). */

	char candidates[4][512] = {};
	if (!confstr(_CS_DARWIN_USER_CACHE_DIR, candidates[0], sizeof(candidates[0]) - 32)) candidates[0][0] = 0;
	if (!confstr(_CS_DARWIN_USER_TEMP_DIR, candidates[1], sizeof(candidates[1]) - 32)) candidates[1][0] = 0;
	strlcpy(candidates[2], "/var/tmp/", sizeof(candidates[2]));
	strlcpy(candidates[3], "/tmp/", sizeof(candidates[3]));

	id device = nil;
	for (int i = 0; i < 4 && !device; ++i) {
		if (!candidates[i][0]) continue;
		char cacheDir[512];
		snprintf(cacheDir, sizeof(cacheDir), "%ssweet-m2v-cache-%u", candidates[i], (unsigned)getuid());
		mkdir(cacheDir, 0777);
		chmod(cacheDir, 0777);
		if (access(cacheDir, W_OK) != 0) continue;
		@try {
			char mesaDir[600];
			snprintf(mesaDir, sizeof(mesaDir), "%s/mesa", cacheDir);
			mkdir(mesaDir, 0777);
			setenv("MESA_SHADER_CACHE_DIR", mesaDir, 1);
			setenv("MESA_SHADER_CACHE_MAX_SIZE", "256M", 0);
			device = native_bridge_metal_open(TURNIP_ICD, cacheDir, registryID, NULL);
			if (device) {
				strlcpy(gCacheDir, cacheDir, sizeof(gCacheDir));
				char outLog[600];
				snprintf(outLog, sizeof(outLog), "%s/unity_stdout.log", cacheDir);
				int out_fd = open(outLog, O_WRONLY | O_CREAT | O_APPEND, 0666);
				if (out_fd >= 0) {
					dup2(out_fd, 1);
					dup2(out_fd, 2);
					setvbuf(stdout, NULL, _IONBF, 0);
					setvbuf(stderr, NULL, _IONBF, 0);
					printf("=== unity_stdout.log started for %s[%d] ===\n", getprogname(), getpid());
				}
			}
		} @catch (NSException *e) {
			sweet_metal_log("native_bridge_metal_open exception: %s", e.reason.UTF8String);
			device = nil;
		}
	}
	if (!device) {
		sweet_metal_log("initWithAcceleratorPort: port 0x%x, native_bridge_metal_open failed", port);
		return nil;
	}
	sweet_metal_log("initWithAcceleratorPort: port 0x%x, returns device %s (_MTLDevice is %zu bytes)", port,
	    class_getName(object_getClass(device)), class_getInstanceSize(objc_getClass("_MTLDevice")));
	return device;
}
@end
