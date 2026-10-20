/*
 * sweet-gputest: exercises the Adreno user client (NativeAdrenoGpuPublished,
 * UniXNU's NativeAdreno ABI v1) the way Turnip's darwin backend does, without
 * Mesa: query and device info, two buffer objects mapped at client-chosen GPU
 * addresses and write-combined in this process, an indirect buffer with one
 * CP_MEM_WRITE, submit, wait for the fence, check the value; then a burst of
 * submissions to time the fences. Run as root on the phone.
 *
 *   sweet-gputest [JOBS [notime] [slow] [hang]]   default 200 jobs in the
 *       burst; notime skips GetTimestamp, slow announces every call and
 *       pauses 1 s, hang then submits a job that never ends and checks the
 *       kernel recovers the GPU (fault count moves, a new job runs)
 *
 * Built without an iOS SDK (tools/sweet-gputest/build.sh): IOKit is reached
 * through dlopen/dlsym; the ABI header is the kernel's
 * (iokit/Kernel/arm/NativeAdrenoABI.h, MIT, from UniXNU).
 */
#include <stdint.h>
#include <stddef.h>
/* The ABI header is C++; C needs the struct names as typedefs first. */
typedef struct NativeAdrenoAbiParams NativeAdrenoAbiParams;
typedef struct NativeAdrenoAbiBoAlloc NativeAdrenoAbiBoAlloc;
typedef struct NativeAdrenoAbiBoAllocReply NativeAdrenoAbiBoAllocReply;
typedef struct NativeAdrenoAbiBoImport NativeAdrenoAbiBoImport;
typedef struct NativeAdrenoAbiBoMap NativeAdrenoAbiBoMap;
typedef struct NativeAdrenoAbiBoMapReply NativeAdrenoAbiBoMapReply;
typedef struct NativeAdrenoAbiBoFree NativeAdrenoAbiBoFree;
typedef struct NativeAdrenoAbiSubmitBuffer NativeAdrenoAbiSubmitBuffer;
typedef struct NativeAdrenoAbiSubmit NativeAdrenoAbiSubmit;
typedef struct NativeAdrenoAbiMetadata NativeAdrenoAbiMetadata;
typedef struct NativeAdrenoAbiSubmitReply NativeAdrenoAbiSubmitReply;
typedef struct NativeAdrenoAbiWaitFence NativeAdrenoAbiWaitFence;
typedef struct NativeAdrenoAbiTimestamp NativeAdrenoAbiTimestamp;
typedef struct NativeAdrenoAbiBoCpuMap NativeAdrenoAbiBoCpuMap;
typedef struct NativeAdrenoAbiBoCpuMapReply NativeAdrenoAbiBoCpuMapReply;
typedef struct NativeAdrenoAbiBoCpuUnmap NativeAdrenoAbiBoCpuUnmap;
typedef struct NativeAdrenoAbiQueue NativeAdrenoAbiQueue;
typedef struct NativeAdrenoAbiQueueReply NativeAdrenoAbiQueueReply;
typedef struct NativeAdrenoAbiStatus NativeAdrenoAbiStatus;
typedef struct NativeAdrenoAbiDeviceInfo NativeAdrenoAbiDeviceInfo;
#include "../../xnu/out-abi/NativeAdrenoABI.h"

typedef uint32_t mach_port_t;
typedef int kern_return_t;
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;

extern void *dlopen(const char *path, int mode);
extern void *dlsym(void *handle, const char *symbol);
extern char *dlerror(void);
extern int dprintf(int fd, const char *fmt, ...);
/* unbuffered: the output must survive a hang of the phone */
#define printf(...) dprintf(1, __VA_ARGS__)
extern int atoi(const char *s);
extern void *memset(void *p, int c, size_t n);
extern void *memcpy(void *d, const void *s, size_t n);
extern uint64_t mach_absolute_time(void);

#define RTLD_NOW 0x2
#define kIOMapAnywhere 0x1u
#define kIOMapWriteCombineCache 0x400u

static void *(*IOServiceMatching)(const char *);
static mach_port_t (*IOServiceGetMatchingService)(mach_port_t, void *);
static kern_return_t (*IOServiceOpen)(mach_port_t, mach_port_t, uint32_t, mach_port_t *);
static kern_return_t (*IOServiceClose)(mach_port_t);
static kern_return_t (*IOConnectCallStructMethod)(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
static kern_return_t (*IOConnectMapMemory64)(mach_port_t, uint32_t, mach_port_t, mach_vm_address_t *,
    mach_vm_size_t *, uint32_t);
static mach_port_t *task_self;
static mach_port_t conn;

extern int usleep(unsigned us);
static int slow;                /* "slow": announce every call, pause 1 s after it */

static kern_return_t
call(uint32_t method, const void *in, size_t in_size, void *out, size_t out_size)
{
	size_t got = out_size;
	if (slow) {
		printf("> method %u\n", method);
	}
	kern_return_t kr = IOConnectCallStructMethod(conn, method, in, in_size, out_size ? out : 0,
	    out_size ? &got : 0);
	if (slow) {
		printf("< method %u: 0x%x\n", method, kr);
		usleep(1000000);
	}
	return kr;
}

static uint32_t
parity(uint32_t v)
{
	return (0x9669u >> (0xfu & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^
	    (v >> 20) ^ (v >> 24) ^ (v >> 28)))) & 1u;
}

static uint32_t
pkt7(uint32_t opcode, uint32_t cnt)
{
	return 0x70000000u | cnt | (parity(cnt) << 15) | ((opcode & 0x7f) << 16) | (parity(opcode) << 23);
}

struct bo {
	uint64_t handle, iova, bytes;
	volatile uint32_t *cpu;
};

static int
bo_new(struct bo *b, uint64_t bytes, uint64_t iova)
{
	NativeAdrenoAbiBoAlloc a = { bytes, 12, 0 };
	NativeAdrenoAbiBoAllocReply r = { 0 };
	kern_return_t kr = call(NativeAdrenoMethodBoAlloc, &a, sizeof(a), &r, sizeof(r));
	if (kr) {
		printf("BoAlloc: 0x%x\n", kr);
		return -1;
	}
	NativeAdrenoAbiBoMap m = { r.handle, iova, 3, 0, 2, 0 };
	NativeAdrenoAbiBoMapReply mr = { 0 };
	kr = call(NativeAdrenoMethodBoMap, &m, sizeof(m), &mr, sizeof(mr));
	if (kr) {
		printf("BoMap(0x%llx): 0x%x\n", iova, kr);
		return -1;
	}
	NativeAdrenoAbiBoCpuMap c = { r.handle };
	NativeAdrenoAbiBoCpuMapReply cr;
	memset(&cr, 0, sizeof(cr));
	kr = call(NativeAdrenoMethodBoCpuMap, &c, sizeof(c), &cr, sizeof(cr));
	mach_vm_address_t addr = 0;
	mach_vm_size_t len = 0;
	if (!kr) {
		if (slow) {
			printf("> IOConnectMapMemory64 token %u\n", cr.token);
		}
		kr = IOConnectMapMemory64(conn, cr.token, *task_self, &addr, &len,
		    kIOMapAnywhere | kIOMapWriteCombineCache);
		if (slow) {
			printf("< IOConnectMapMemory64: 0x%x at 0x%llx\n", kr, addr);
			usleep(1000000);
		}
	}
	if (kr || len < bytes) {
		printf("BoCpuMap: 0x%x (len 0x%llx)\n", kr, len);
		return -1;
	}
	b->handle = r.handle;
	b->iova = mr.iova;
	b->bytes = bytes;
	b->cpu = (volatile uint32_t *)addr;
	printf("bo %llu: %llu bytes, gpu 0x%llx, cpu 0x%llx\n", b->handle, bytes, b->iova, addr);
	return 0;
}

int
main(int argc, const char **argv)
{
	unsigned jobs = argc > 1 ? (unsigned)atoi(argv[1]) : 200;
	int timestamps = 1, hang = 0;
	for (int i = 2; i < argc; ++i) {
		if (argv[i][0] == 'n') {
			timestamps = 0;          /* notime */
		} else if (argv[i][0] == 's') {
			slow = 1;                /* slow */
		} else if (argv[i][0] == 'h') {
			hang = 1;                /* hang */
		}
	}
	void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
	void *sys = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);
	if (!iokit || !sys) {
		printf("dlopen: %s\n", dlerror());
		return 1;
	}
	IOServiceMatching = dlsym(iokit, "IOServiceMatching");
	IOServiceGetMatchingService = dlsym(iokit, "IOServiceGetMatchingService");
	IOServiceOpen = dlsym(iokit, "IOServiceOpen");
	IOServiceClose = dlsym(iokit, "IOServiceClose");
	IOConnectCallStructMethod = dlsym(iokit, "IOConnectCallStructMethod");
	IOConnectMapMemory64 = dlsym(iokit, "IOConnectMapMemory64");
	task_self = dlsym(sys, "mach_task_self_");
	if (!IOServiceMatching || !IOServiceGetMatchingService || !IOServiceOpen || !IOServiceClose ||
	    !IOConnectCallStructMethod || !IOConnectMapMemory64 || !task_self) {
		printf("missing IOKit symbols\n");
		return 1;
	}
	mach_port_t svc = IOServiceGetMatchingService(0, IOServiceMatching("NativeAdrenoGpuPublished"));
	if (!svc) {
		printf("no NativeAdrenoGpuPublished service\n");
		return 1;
	}
	kern_return_t kr = IOServiceOpen(svc, *task_self, 0, &conn);
	if (kr) {
		printf("IOServiceOpen: 0x%x\n", kr);
		return 1;
	}

	NativeAdrenoAbiParams p;
	NativeAdrenoAbiDeviceInfo d;
	memset(&p, 0, sizeof(p));
	memset(&d, 0, sizeof(d));
	kr = call(NativeAdrenoMethodQuery, 0, 0, &p, sizeof(p));
	if (kr) {
		printf("Query: 0x%x (not ready: is sweetgpu=7 set?)\n", kr);
		return 1;
	}
	call(NativeAdrenoMethodGetDeviceInfo, 0, 0, &d, sizeof(d));
	printf("abi %u, gpu va %u bits, pa %u bits, max bo 0x%llx, flags 0x%x\n", p.abi_version,
	    p.input_bits, p.output_bits, p.max_bo_bytes, p.flags);
	printf("chip 0x%08x gmem %u KiB at 0x%llx, va 0x%llx+0x%llx, hbb %u swizzle 0x%x\n", d.chip_id,
	    d.gmem_bytes / 1024, d.gmem_base, d.va_start, d.va_size, d.highest_bank_bit, d.ubwc_swizzle);
	NativeAdrenoAbiTimestamp t0 = { 0 }, t1 = { 0 };
	if (timestamps) {
		call(NativeAdrenoMethodGetTimestamp, 0, 0, &t0, sizeof(t0));
	}

	struct bo ib, data;
	if (bo_new(&ib, 0x4000, d.va_start) || bo_new(&data, 0x4000, d.va_start + 0x100000)) {
		return 1;
	}
	data.cpu[0] = 0;
	ib.cpu[0] = pkt7(0x3d, 3);                /* CP_MEM_WRITE */
	ib.cpu[1] = (uint32_t)data.iova;
	ib.cpu[2] = (uint32_t)(data.iova >> 32);
	ib.cpu[3] = 0x600df00du;
	__asm__ volatile ("dsb sy" ::: "memory");
	NativeAdrenoAbiSubmit s;
	memset(&s, 0, sizeof(s));
	s.buffer_count = 1;
	s.buffers[0].handle = ib.handle;
	s.buffers[0].iova = ib.iova;
	s.buffers[0].bytes = 16;
	NativeAdrenoAbiSubmitReply sr = { 0 };
	kr = call(NativeAdrenoMethodSubmit, &s, sizeof(s), &sr, sizeof(sr));
	printf("submit: 0x%x, fence %llu\n", kr, sr.fence);
	NativeAdrenoAbiWaitFence w = { sr.fence, 1000000000ull };
	kr = call(NativeAdrenoMethodWaitFence, &w, sizeof(w), 0, 0);
	__asm__ volatile ("dsb sy" ::: "memory");
	uint32_t got = data.cpu[0];
	printf("wait: 0x%x; GPU wrote 0x%08x (want 0x600df00d): %s\n", kr, got,
	    got == 0x600df00du ? "OK, A USER PROCESS DROVE THE GPU" : "FAILED");

	/* Burst: one job per counter value, each writing it to data[1]. */
	uint64_t start = mach_absolute_time();
	uint32_t last = 0, busy = 0;
	for (unsigned i = 1; i <= jobs; ++i) {
		uint32_t at = 64 + 4 * (i % 16);
		ib.cpu[at] = pkt7(0x3d, 3);
		ib.cpu[at + 1] = (uint32_t)(data.iova + 4);
		ib.cpu[at + 2] = (uint32_t)((data.iova + 4) >> 32);
		ib.cpu[at + 3] = i;
		__asm__ volatile ("dsb sy" ::: "memory");
		s.buffers[0].iova = ib.iova + 4 * at;
		for (;;) {
			kr = call(NativeAdrenoMethodSubmit, &s, sizeof(s), &sr, sizeof(sr));
			if (kr != (kern_return_t)0xe00002d5) {      /* kIOReturnBusy */
				break;
			}
			busy++;
			NativeAdrenoAbiWaitFence ow = { last - 6, 1000000000ull };
			call(NativeAdrenoMethodWaitFence, &ow, sizeof(ow), 0, 0);
		}
		if (kr) {
			printf("burst submit %u: 0x%x\n", i, kr);
			break;
		}
		last = (uint32_t)sr.fence;
	}
	w.fence = last;
	kr = call(NativeAdrenoMethodWaitFence, &w, sizeof(w), 0, 0);
	uint64_t ticks = mach_absolute_time() - start;
	if (timestamps) {
		call(NativeAdrenoMethodGetTimestamp, 0, 0, &t1, sizeof(t1));
	}
	NativeAdrenoAbiStatus st = { 0, 0 };
	call(NativeAdrenoMethodGetStatus, 0, 0, &st, sizeof(st));
	uint32_t last_value = data.cpu[1];       /* before the close unmaps it */
	int recovered = 1;
	if (hang) {
		/* CP_WAIT_MEM_GTE on data[2] (0) for 0x7fffffff: the CP waits forever. */
		data.cpu[2] = 0;
		ib.cpu[128] = pkt7(0x14, 4);
		ib.cpu[129] = 0;
		ib.cpu[130] = (uint32_t)(data.iova + 8);
		ib.cpu[131] = (uint32_t)((data.iova + 8) >> 32);
		ib.cpu[132] = 0x7fffffffu;
		__asm__ volatile ("dsb sy" ::: "memory");
		NativeAdrenoAbiStatus s0 = { 0, 0 }, s1 = { 0, 0 };
		call(NativeAdrenoMethodGetStatus, 0, 0, &s0, sizeof(s0));
		s.buffers[0].iova = ib.iova + 4 * 128;
		s.buffers[0].bytes = 20;
		kr = call(NativeAdrenoMethodSubmit, &s, sizeof(s), &sr, sizeof(sr));
		uint64_t h0 = mach_absolute_time();
		NativeAdrenoAbiWaitFence hw = { sr.fence, 10000000000ull };
		kern_return_t hk = call(NativeAdrenoMethodWaitFence, &hw, sizeof(hw), 0, 0);
		uint64_t h1 = mach_absolute_time();
		call(NativeAdrenoMethodGetStatus, 0, 0, &s1, sizeof(s1));
		printf("hang: submit 0x%x fence %llu, wait 0x%x after %llu ms, faults %llu -> %llu\n", kr, sr.fence,
		    hk, (h1 - h0) / 19200, s0.faults, s1.faults);
		/* and the GPU works again */
		data.cpu[0] = 0;
		ib.cpu[0] = pkt7(0x3d, 3);
		ib.cpu[1] = (uint32_t)data.iova;
		ib.cpu[2] = (uint32_t)(data.iova >> 32);
		ib.cpu[3] = 0x0bacf00du;
		__asm__ volatile ("dsb sy" ::: "memory");
		s.buffers[0].iova = ib.iova;
		s.buffers[0].bytes = 16;
		kr = call(NativeAdrenoMethodSubmit, &s, sizeof(s), &sr, sizeof(sr));
		w.fence = sr.fence;
		kern_return_t ak = call(NativeAdrenoMethodWaitFence, &w, sizeof(w), 0, 0);
		recovered = hk == 0 && s1.faults > s0.faults && ak == 0 && data.cpu[0] == 0x0bacf00du;
		printf("after recovery: submit 0x%x wait 0x%x, GPU wrote 0x%08x (want 0x0bacf00d): %s\n", kr, ak,
		    data.cpu[0], recovered ? "RECOVERED" : "NOT RECOVERED");
	}
	printf("burst: %u jobs, wait 0x%x, last value %u, %u busy retries, %llu us; gpu clock %llu -> %llu, "
	    "faults %llu\n", jobs, kr, last_value, busy, ticks * 10 / 192, t0.ticks, t1.ticks, st.faults);
	IOServiceClose(conn);
	return got == 0x600df00du && last_value == jobs && recovered ? 0 : 2;
}
