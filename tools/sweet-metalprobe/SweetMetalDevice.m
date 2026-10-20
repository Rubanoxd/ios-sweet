/*
 * Stage 3 of the Metal probe: a real MTLDevice over Turnip (sweet-mtl-vk.c)
 * for the client processes the plugin picks. The device is the plugin's own
 * _MTLDevice subclass (Metal requires one), with the methods below added as
 * a category; buffers, queues, command buffers and blit encoders are own
 * classes answering the Metal protocol methods implemented here. Shape after
 * UniXNU's NativeBridgeMetalFrontend.mm (MIT, github.com/UniXNU/UniXNU at
 * dec4c7b), written anew over a small C runtime instead of their Rust one.
 *
 * Implemented: buffers (shared memory, zeroed), command queues, command
 * buffers (commit order per queue, scheduled/completed handlers, status,
 * error, waitUntilCompleted), blit fillBuffer and copyFromBuffer. Not yet:
 * libraries and pipelines (AIR has no lowering yet), textures, render and
 * compute encoders, events, heaps, drawables. Those return nil, fail the
 * command buffer or, for selectors not implemented at all, are logged
 * through doesNotRecognizeSelector: before the usual exception.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include "SweetMetalDevice.h"
#include "sweet-mtl-vk.h"

#define TURNIP_ICD "/var/jb/usr/lib/libvulkan_freedreno.dylib"
enum { kGpuTimeoutMs = 5000 };

static id gDevice;
static NSString *gName;
static uint64_t gRegistryID;

static NSError *
smError(NSString *why)
{
	return [NSError errorWithDomain:@"org.sweet.metal" code:-1
	    userInfo:@{ NSLocalizedDescriptionKey: why ?: @"refused" }];
}

@interface SMObject : NSObject
@property (atomic, copy) NSString *label;
@end
@implementation SMObject
- (id<MTLDevice>)device
{
	return gDevice;
}
- (void)doesNotRecognizeSelector:(SEL)selector
{
	sweet_metal_log("missing %s -%s", class_getName(object_getClass(self)), sel_getName(selector));
	[super doesNotRecognizeSelector:selector];
}
@end

/* ---- buffers ---- */
@interface SMBuffer : SMObject
@property (nonatomic) smv_buffer *handle;
@property (nonatomic) MTLResourceOptions options;
@end
@implementation SMBuffer
- (void)dealloc
{
	smv_buffer_free(_handle);
}
- (NSUInteger)length
{
	return (NSUInteger)smv_buffer_length(_handle);
}
- (NSUInteger)allocatedSize
{
	return self.length;
}
- (void *)contents
{
	return smv_buffer_contents(_handle);
}
- (uint64_t)gpuAddress
{
	return 0;
}
- (MTLResourceOptions)resourceOptions
{
	return _options;
}
- (MTLStorageMode)storageMode
{
	return (MTLStorageMode)((_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift);
}
- (MTLCPUCacheMode)cpuCacheMode
{
	return (MTLCPUCacheMode)((_options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift);
}
- (MTLHazardTrackingMode)hazardTrackingMode
{
	return MTLHazardTrackingModeTracked;
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state
{
	(void)state;
	return MTLPurgeableStateNonVolatile;
}
- (BOOL)isAliasable
{
	return NO;
}
- (void)makeAliasable
{
}
- (void)didModifyRange:(NSRange)range
{
	(void)range;    /* coherent memory */
}
@end

/* ---- command buffers and encoders ---- */
@class SMQueue;
@interface SMCommandBuffer : SMObject
@property (nonatomic, strong) SMQueue *queue;
@property (atomic) MTLCommandBufferStatus status;
@property (atomic, strong) NSError *error;
@property (atomic) CFTimeInterval GPUStartTime, GPUEndTime;
@property (atomic, copy) NSString *encodeFailure;
@property (atomic) BOOL committed;
- (smv_cmd *)cmd;
- (void)use:(SMBuffer *)buffer;
- (void)refuse:(NSString *)what;
@end

@interface SMQueue : SMObject
@property (nonatomic, strong) dispatch_queue_t serial;
@end

@interface SMBlitEncoder : SMObject
@property (nonatomic, strong) SMCommandBuffer *commandBuffer;
@end
@implementation SMBlitEncoder
- (SMBuffer *)own:(id<MTLBuffer>)b
{
	if (![(id)b isKindOfClass:[SMBuffer class]]) {
		[_commandBuffer refuse:@"blit: foreign buffer"];
		return nil;
	}
	[_commandBuffer use:(SMBuffer *)b];
	return (SMBuffer *)b;
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value
{
	SMBuffer *b = [self own:buffer];
	smv_cmd *c = [_commandBuffer cmd];
	if (b && c && !smv_cmd_fill(c, b.handle, range.location, range.length, value)) {
		[_commandBuffer refuse:[NSString stringWithFormat:@"fillBuffer: %s", smv_error()]];
	}
}
- (void)copyFromBuffer:(id<MTLBuffer>)source sourceOffset:(NSUInteger)sourceOffset toBuffer:(id<MTLBuffer>)destination
    destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size
{
	SMBuffer *s = [self own:source], *d = [self own:destination];
	smv_cmd *c = [_commandBuffer cmd];
	if (s && d && c && !smv_cmd_copy(c, s.handle, sourceOffset, d.handle, destinationOffset, size)) {
		[_commandBuffer refuse:[NSString stringWithFormat:@"copyFromBuffer: %s", smv_error()]];
	}
}
- (void)synchronizeResource:(id<MTLResource>)resource
{
	(void)resource;
}
- (void)pushDebugGroup:(NSString *)string
{
	(void)string;
}
- (void)popDebugGroup
{
}
- (void)insertDebugSignpost:(NSString *)string
{
	(void)string;
}
- (void)endEncoding
{
	_commandBuffer = nil;
}
@end

@implementation SMCommandBuffer {
	smv_cmd *_list;
	NSMutableSet *_resources;
	NSMutableArray *_scheduled, *_completed;
	dispatch_group_t _done;
}
- (instancetype)init
{
	if ((self = [super init])) {
		_resources = [NSMutableSet set];
		_scheduled = [NSMutableArray array];
		_completed = [NSMutableArray array];
		_done = dispatch_group_create();
	}
	return self;
}
- (void)dealloc
{
	smv_cmd_free(_list);
}
- (smv_cmd *)cmd
{
	if (self.committed) {
		[self refuse:@"encoding after commit"];
		return NULL;
	}
	if (!_list && !(_list = smv_cmd_new())) {
		[self refuse:[NSString stringWithFormat:@"command list: %s", smv_error()]];
	}
	return _list;
}
- (void)use:(SMBuffer *)buffer
{
	@synchronized (_resources) {
		[_resources addObject:buffer];
	}
}
- (void)refuse:(NSString *)what
{
	if (!self.encodeFailure) {
		self.encodeFailure = what;
		sweet_metal_log("command buffer refused: %s", what.UTF8String);
	}
}
- (id<MTLCommandQueue>)commandQueue
{
	return (id<MTLCommandQueue>)_queue;
}
- (BOOL)retainedReferences
{
	return YES;
}
- (MTLCommandBufferErrorOption)errorOptions
{
	return MTLCommandBufferErrorOptionNone;
}
- (CFTimeInterval)kernelStartTime
{
	return self.GPUStartTime;
}
- (CFTimeInterval)kernelEndTime
{
	return self.GPUEndTime;
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder
{
	if (self.committed) {
		[self refuse:@"blitCommandEncoder after commit"];
		return nil;
	}
	SMBlitEncoder *e = [SMBlitEncoder new];
	e.commandBuffer = self;
	return (id<MTLBlitCommandEncoder>)e;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder
{
	[self refuse:@"compute encoders are not implemented yet"];
	return nil;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type
{
	(void)type;
	return [self computeCommandEncoder];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor
{
	(void)descriptor;
	[self refuse:@"render encoders are not implemented yet"];
	return nil;
}
- (void)presentDrawable:(id<MTLDrawable>)drawable
{
	(void)drawable;
	[self refuse:@"drawables are not implemented yet"];
}
- (void)addScheduledHandler:(MTLCommandBufferHandler)block
{
	if (block) {
		@synchronized (self) {
			[_scheduled addObject:[block copy]];
		}
	}
}
- (void)addCompletedHandler:(MTLCommandBufferHandler)block
{
	if (block) {
		@synchronized (self) {
			[_completed addObject:[block copy]];
		}
	}
}
- (void)enqueue
{
	if (self.status == MTLCommandBufferStatusNotEnqueued) {
		self.status = MTLCommandBufferStatusEnqueued;
	}
}
- (void)run:(NSArray *)handlers
{
	for (MTLCommandBufferHandler block in handlers) {
		block((id<MTLCommandBuffer>)self);
	}
}
- (void)commit
{
	if (self.committed) {
		sweet_metal_log("commit twice");
		return;
	}
	self.committed = YES;
	self.status = MTLCommandBufferStatusCommitted;
	dispatch_group_enter(_done);
	/* The queue's serial dispatch queue keeps commit order; the block owns
	 * the command buffer until it completes. */
	dispatch_async(_queue.serial, ^{
		NSArray *scheduled, *completed;
		@synchronized (self) {
			scheduled = [self->_scheduled copy];
			[self->_scheduled removeAllObjects];
		}
		self.status = MTLCommandBufferStatusScheduled;
		[self run:scheduled];
		BOOL ok = NO;
		self.GPUStartTime = CACurrentMediaTime();
		if (self.encodeFailure) {
			self.error = smError(self.encodeFailure);
		} else if (!self->_list) {
			ok = YES;       /* nothing encoded */
		} else if (smv_cmd_run(self->_list, kGpuTimeoutMs)) {
			ok = YES;
		} else {
			self.error = smError([NSString stringWithUTF8String:smv_error()]);
			sweet_metal_log("command buffer failed: %s", smv_error());
		}
		self.GPUEndTime = CACurrentMediaTime();
		if (!ok && self->_list) {
			/* After a timeout the GPU may still use the buffers. */
			for (id r in self->_resources) {
				CFBridgingRetain(r);
			}
		}
		self.status = ok ? MTLCommandBufferStatusCompleted : MTLCommandBufferStatusError;
		@synchronized (self) {
			completed = [self->_completed copy];
			[self->_completed removeAllObjects];
		}
		[self run:completed];
		dispatch_group_leave(self->_done);
	});
}
- (void)waitUntilScheduled
{
	[self waitUntilCompleted];
}
- (void)waitUntilCompleted
{
	if (self.committed) {
		dispatch_group_wait(_done, DISPATCH_TIME_FOREVER);
	}
}
- (void)pushDebugGroup:(NSString *)string
{
	(void)string;
}
- (void)popDebugGroup
{
}
@end

@implementation SMQueue
- (id<MTLCommandBuffer>)commandBuffer
{
	SMCommandBuffer *c = [SMCommandBuffer new];
	c.queue = self;
	return (id<MTLCommandBuffer>)c;
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences
{
	return [self commandBuffer];
}
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)descriptor
{
	(void)descriptor;
	return [self commandBuffer];
}
- (void)insertDebugCaptureBoundary
{
}
@end

/* ---- the device ---- */
int
sweet_metal_open(unsigned port, char *err, size_t len)
{
	char name[256];
	if (!smv_open(TURNIP_ICD, name, sizeof(name))) {
		snprintf(err, len, "%s", smv_error());
		return 0;
	}
	gName = [NSString stringWithFormat:@"%s (SweetMetal)", name];
	/* MTLAddDevice asserts conformsToProtocol:MTLDevice; the classes are
	 * declared without the protocols so the compiler does not demand every
	 * method, and get them here. */
	struct { Class cls; const char *protocol; } const conform[] = {
		{ [SweetMetalProbe class], "MTLDevice" }, { [SweetMetalProbe class], "MTLDeviceSPI" },
		{ [SMBuffer class], "MTLBuffer" }, { [SMBuffer class], "MTLBufferSPI" },
		{ [SMQueue class], "MTLCommandQueue" }, { [SMQueue class], "MTLCommandQueueSPI" },
		{ [SMCommandBuffer class], "MTLCommandBuffer" }, { [SMCommandBuffer class], "MTLCommandBufferSPI" },
		{ [SMBlitEncoder class], "MTLBlitCommandEncoder" }, { [SMBlitEncoder class], "MTLBlitCommandEncoderSPI" },
	};
	for (size_t i = 0; i < sizeof(conform) / sizeof(conform[0]); ++i) {
		Protocol *p = objc_getProtocol(conform[i].protocol);
		if (p) {
			class_addProtocol(conform[i].cls, p);
		}
	}
	void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
	int (*entryID)(unsigned, uint64_t *) = iokit ? (int (*)(unsigned, uint64_t *))dlsym(iokit,
	    "IORegistryEntryGetRegistryEntryID") : NULL;
	if (entryID) {
		(void)entryID(port, &gRegistryID);
	}
	return 1;
}

@interface SweetMetalProbe (Device)
@end
@implementation SweetMetalProbe (Device)
- (void)sweetBecomeDevice
{
	gDevice = self;
}
- (NSString *)name
{
	return gName;
}
- (uint64_t)registryID
{
	return gRegistryID;
}
- (NSUInteger)maxBufferLength
{
	return (NSUInteger)smv_max_buffer_length();
}
- (uint64_t)recommendedMaxWorkingSetSize
{
	return 1ull << 30;
}
- (NSUInteger)currentAllocatedSize
{
	return 0;
}
/* MTLAddDevice -> -[_MTLDevice initLimits] sizes every limit table from
 * these two, which the AGX plugins implement; the A11's answers (5 and 1)
 * pick limits within what this device can be made to honour. */
- (NSUInteger)featureProfile
{
	return 5;
}
- (NSUInteger)indirectArgumentBufferCapabilities
{
	return 1;
}
- (BOOL)hasUnifiedMemory
{
	return YES;
}
- (BOOL)isLowPower
{
	return NO;
}
- (BOOL)isHeadless
{
	return NO;
}
- (BOOL)isRemovable
{
	return NO;
}
- (MTLSize)maxThreadsPerThreadgroup
{
	return MTLSizeMake(1024, 1024, 64);
}
/* No GPU family or feature set is claimed: the base class answers from
 * Apple tables, and nothing beyond buffers and blits works yet. */
- (BOOL)supportsFamily:(MTLGPUFamily)family
{
	(void)family;
	return NO;
}
- (BOOL)supportsFeatureSet:(NSUInteger)set
{
	(void)set;
	return NO;
}
- (BOOL)supportsTextureSampleCount:(NSUInteger)count
{
	return count == 1;
}
- (void)doesNotRecognizeSelector:(SEL)selector
{
	sweet_metal_log("missing device -%s", sel_getName(selector));
	[super doesNotRecognizeSelector:selector];
}
- (id<MTLCommandQueue>)newCommandQueue
{
	SMQueue *q = [SMQueue new];
	q.serial = dispatch_queue_create("org.sweet.metal.queue", DISPATCH_QUEUE_SERIAL);
	return (id<MTLCommandQueue>)q;
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count
{
	(void)count;
	return [self newCommandQueue];
}
- (id<MTLBuffer>)sweetBuffer:(NSUInteger)length bytes:(const void *)bytes options:(MTLResourceOptions)options
{
	smv_buffer *h = smv_buffer_new(length, bytes);
	if (!h) {
		sweet_metal_log("buffer of %lu refused: %s", (unsigned long)length, smv_error());
		return nil;
	}
	SMBuffer *b = [SMBuffer new];
	b.handle = h;
	b.options = options;
	return (id<MTLBuffer>)b;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [self sweetBuffer:length bytes:NULL options:options];
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
{
	return bytes ? [self sweetBuffer:length bytes:bytes options:options] : nil;
}
- (id<MTLLibrary>)sweetNoLibrary:(NSError **)error
{
	if (error) {
		*error = smError(@"shader libraries are not implemented yet (no AIR lowering)");
	}
	return nil;
}
- (id<MTLLibrary>)newDefaultLibrary
{
	return [self sweetNoLibrary:NULL];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error
{
	(void)bundle;
	return [self sweetNoLibrary:error];
}
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error
{
	(void)source;
	(void)options;
	return [self sweetNoLibrary:error];
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	(void)data;
	return [self sweetNoLibrary:error];
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	(void)url;
	return [self sweetNoLibrary:error];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	(void)descriptor;
	sweet_metal_log("textures are not implemented yet");
	return nil;
}
@end
