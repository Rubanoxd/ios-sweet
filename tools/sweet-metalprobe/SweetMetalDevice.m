/*
 * Stage 3 of the Metal probe: a real MTLDevice over Turnip (sweet-mtl-vk.c)
 * for the client processes the plugin picks. The device is the plugin's own
 * _MTLDevice subclass (Metal requires one), with the methods below added as
 * a category; buffers, queues, command buffers and blit encoders are own
 * classes answering the Metal protocol methods implemented here. Shape after
 * UniXNU's NativeBridgeMetalFrontend.mm (MIT, github.com/UniXNU/UniXNU at
 * dec4c7b), written anew over a small C runtime instead of their Rust one.
 *
 * Implemented: buffers (shared memory, zeroed, with GPU addresses),
 * command queues, command buffers (commit order per queue, scheduled and
 * completed handlers, status, error, waitUntilCompleted), blit fillBuffer
 * and copyFromBuffer, libraries from metallibs (AIR translated to SPIR-V by
 * Darling's Iridium, sweet-iridium.h), kernel functions, compute pipelines
 * and compute encoders (buffers, setBytes, uniform dispatches), 2D
 * textures (getBytes/replaceRegion), render pipelines (vertex + fragment of
 * one library, blending) and render encoders (color attachments with
 * load/store/clear, buffers and bytes per stage, viewport, cull, winding,
 * drawPrimitives). Not yet: newLibraryWithSource (needs the on-device MSL
 * compiler), texture/sampler arguments, vertex descriptors, depth/stencil,
 * events, heaps, drawables. Those return nil, fail the
 * command buffer or, for selectors not implemented at all, are logged
 * through doesNotRecognizeSelector: before the usual exception.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include "SweetMetalDevice.h"
#include "sweet-mtl-vk.h"
#include "sweet-iridium.h"

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

/* ---- libraries, functions, compute pipelines ---- */
@interface SMLibrary : SMObject
@property (nonatomic, strong) NSData *spirv;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *functions; /* name -> index */
@property (nonatomic) struct sweet_air_function *table;
@end

@interface SMFunction : SMObject
@property (nonatomic, strong) SMLibrary *library;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) const struct sweet_air_function *info;
@end
@implementation SMFunction
- (NSString *)name
{
	return _name;
}
- (MTLFunctionType)functionType
{
	return (MTLFunctionType)_info->kind;    /* Iridium's kinds are Metal's values */
}
- (MTLFunctionOptions)options
{
	return MTLFunctionOptionNone;
}
- (NSDictionary *)functionConstantsDictionary
{
	return @{};
}
- (NSArray *)vertexAttributes
{
	return nil;
}
- (NSArray *)stageInputAttributes
{
	return nil;
}
- (NSInteger)patchControlPointCount
{
	return -1;
}
- (MTLPatchType)patchType
{
	return MTLPatchTypeNone;
}
@end

@implementation SMLibrary
- (void)dealloc
{
	free(_table);
}
- (NSArray<NSString *> *)functionNames
{
	return _functions.allKeys;
}
- (MTLLibraryType)type
{
	return MTLLibraryTypeExecutable;
}
- (NSString *)installName
{
	return nil;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	NSNumber *at = name ? _functions[name] : nil;
	if (!at) {
		return nil;
	}
	SMFunction *f = [SMFunction new];
	f.library = self;
	f.name = name;
	f.info = &_table[at.unsignedIntegerValue];
	return (id<MTLFunction>)f;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values
    error:(NSError **)error
{
	(void)values;
	id<MTLFunction> f = [self newFunctionWithName:name];
	if (!f && error) {
		*error = smError([NSString stringWithFormat:@"no function %@", name]);
	}
	return f;
}
@end

static SMLibrary *
newLibrary(NSData *data, NSError **error)
{
	char err[256];
	size_t bytes = 0, count = 0;
	struct sweet_air_function *table = NULL;
	void *spv = data ? sweet_air_translate(data.bytes, data.length, &bytes, &table, &count, err, sizeof(err)) : NULL;
	if (!spv) {
		if (!data) {
			snprintf(err, sizeof(err), "no library data");
		}
		sweet_metal_log("library refused: %s", err);
		if (error) {
			*error = smError([NSString stringWithUTF8String:err]);
		}
		return nil;
	}
	SMLibrary *lib = [SMLibrary new];
	lib.spirv = [NSData dataWithBytesNoCopy:spv length:bytes freeWhenDone:YES];
	lib.table = table;
	NSMutableDictionary *names = [NSMutableDictionary dictionary];
	for (size_t i = 0; i < count; ++i) {
		names[[NSString stringWithUTF8String:table[i].name]] = @(i);
	}
	lib.functions = names;
	sweet_metal_log("library: %zu functions, %zu bytes of SPIR-V", count, bytes);
	if (error) {
		*error = nil;
	}
	return lib;
}

@interface SMComputePipeline : SMObject
@property (nonatomic, strong) SMFunction *function;
@property (nonatomic) smv_kernel *kernel;
@end
@implementation SMComputePipeline
- (void)dealloc
{
	smv_kernel_free(_kernel);
}
- (NSUInteger)maxTotalThreadsPerThreadgroup
{
	return 1024;
}
- (NSUInteger)threadExecutionWidth
{
	return 64;
}
- (NSUInteger)staticThreadgroupMemoryLength
{
	return 0;
}
- (BOOL)supportIndirectCommandBuffers
{
	return NO;
}
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)dimensions
{
	(void)dimensions;
	return 0;
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
- (void)use:(id)resource;
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

/* ---- textures ---- */
struct pixel_format {
	MTLPixelFormat metal;
	VkFormat vk;
	uint32_t bytes;
};
static const struct pixel_format kFormats[] = {
	{ MTLPixelFormatR8Unorm, VK_FORMAT_R8_UNORM, 1 },
	{ MTLPixelFormatRG8Unorm, VK_FORMAT_R8G8_UNORM, 2 },
	{ MTLPixelFormatR16Float, VK_FORMAT_R16_SFLOAT, 2 },
	{ MTLPixelFormatRGBA8Unorm, VK_FORMAT_R8G8B8A8_UNORM, 4 },
	{ MTLPixelFormatRGBA8Unorm_sRGB, VK_FORMAT_R8G8B8A8_SRGB, 4 },
	{ MTLPixelFormatBGRA8Unorm, VK_FORMAT_B8G8R8A8_UNORM, 4 },
	{ MTLPixelFormatBGRA8Unorm_sRGB, VK_FORMAT_B8G8R8A8_SRGB, 4 },
	{ MTLPixelFormatRGB10A2Unorm, VK_FORMAT_A2B10G10R10_UNORM_PACK32, 4 },
	{ MTLPixelFormatBGR10A2Unorm, VK_FORMAT_A2R10G10B10_UNORM_PACK32, 4 },
	{ MTLPixelFormatR32Float, VK_FORMAT_R32_SFLOAT, 4 },
	{ MTLPixelFormatRGBA16Float, VK_FORMAT_R16G16B16A16_SFLOAT, 8 },
	{ MTLPixelFormatRGBA32Float, VK_FORMAT_R32G32B32A32_SFLOAT, 16 },
};
static const struct pixel_format *
pixelFormat(MTLPixelFormat f)
{
	for (size_t i = 0; i < sizeof(kFormats) / sizeof(kFormats[0]); ++i) {
		if (kFormats[i].metal == f) {
			return &kFormats[i];
		}
	}
	return NULL;
}

@interface SMTexture : SMObject
@property (nonatomic) smv_texture *handle;
@property (nonatomic) MTLPixelFormat pixelFormat;
@property (nonatomic) NSUInteger width, height;
@property (nonatomic) MTLTextureUsage usage;
@property (nonatomic) MTLResourceOptions options;
@end
@implementation SMTexture
- (void)dealloc
{
	smv_texture_free(_handle);
}
- (MTLTextureType)textureType
{
	return MTLTextureType2D;
}
- (NSUInteger)depth
{
	return 1;
}
- (NSUInteger)mipmapLevelCount
{
	return 1;
}
- (NSUInteger)arrayLength
{
	return 1;
}
- (NSUInteger)sampleCount
{
	return 1;
}
- (BOOL)isFramebufferOnly
{
	return NO;
}
- (BOOL)allowGPUOptimizedContents
{
	return YES;
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
	return MTLCPUCacheModeDefaultCache;
}
- (MTLHazardTrackingMode)hazardTrackingMode
{
	return MTLHazardTrackingModeTracked;
}
- (IOSurfaceRef)iosurface
{
	return NULL;
}
- (NSUInteger)iosurfacePlane
{
	return 0;
}
- (id<MTLBuffer>)buffer
{
	return nil;
}
- (id<MTLTexture>)parentTexture
{
	return nil;
}
- (MTLTextureSwizzleChannels)swizzle
{
	return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
	    MTLTextureSwizzleAlpha);
}
- (BOOL)access:(MTLRegion)region level:(NSUInteger)level bytes:(void *)bytes row:(NSUInteger)row write:(int)write
{
	if (level != 0 || region.size.depth != 1 || region.origin.z != 0) {
		sweet_metal_log("texture access: only level 0 of 2D textures");
		return NO;
	}
	const uint32_t r[4] = { (uint32_t)region.origin.x, (uint32_t)region.origin.y, (uint32_t)region.size.width,
		(uint32_t)region.size.height };
	if (!smv_texture_access(_handle, r, bytes, (uint32_t)row, write)) {
		sweet_metal_log("texture access: %s", smv_error());
		return NO;
	}
	return YES;
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level
{
	[self access:region level:level bytes:bytes row:row write:0];
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes
    bytesPerRow:(NSUInteger)row
{
	[self access:region level:level bytes:(void *)bytes row:row write:1];
}
@end

/* ---- render pipelines ---- */
static VkBlendFactor
blendFactor(MTLBlendFactor f)
{
	static const VkBlendFactor map[] = { VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_SRC_COLOR,
		VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR, VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
		VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_DST_ALPHA,
		VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA, VK_BLEND_FACTOR_SRC_ALPHA_SATURATE, VK_BLEND_FACTOR_CONSTANT_COLOR,
		VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR, VK_BLEND_FACTOR_CONSTANT_ALPHA,
		VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA, VK_BLEND_FACTOR_SRC1_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR,
		VK_BLEND_FACTOR_SRC1_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA };
	return (NSUInteger)f < sizeof(map) / sizeof(map[0]) ? map[f] : VK_BLEND_FACTOR_ONE;
}
static uint32_t
writeMask(MTLColorWriteMask m)
{
	return ((m & MTLColorWriteMaskRed) ? VK_COLOR_COMPONENT_R_BIT : 0) |
	    ((m & MTLColorWriteMaskGreen) ? VK_COLOR_COMPONENT_G_BIT : 0) |
	    ((m & MTLColorWriteMaskBlue) ? VK_COLOR_COMPONENT_B_BIT : 0) |
	    ((m & MTLColorWriteMaskAlpha) ? VK_COLOR_COMPONENT_A_BIT : 0);
}

@interface SMRenderPipeline : SMObject
@property (nonatomic) smv_render_pipeline *handle;
@property (nonatomic, strong) SMFunction *vertex, *fragment;
@end
@implementation SMRenderPipeline
- (void)dealloc
{
	smv_render_pipeline_free(_handle);
}
- (BOOL)supportIndirectCommandBuffers
{
	return NO;
}
- (NSUInteger)maxTotalThreadsPerThreadgroup
{
	return 0;
}
- (BOOL)threadgroupSizeMatchesTileSize
{
	return NO;
}
- (NSUInteger)imageblockSampleLength
{
	return 0;
}
@end

/* The argument table of one stage: the GPU addresses of its buffer
 * bindings, in Iridium's order. NO if the stage takes something else. */
static BOOL
stageAddresses(const struct sweet_air_function *f, const uint64_t *bound, uint64_t *out)
{
	for (unsigned i = 0; f && i < f->bindings; ++i) {
		if (f->binding[i].type != SWEET_AIR_BUFFER || f->binding[i].index >= SWEET_AIR_MAX_BINDINGS) {
			return NO;
		}
		out[i] = bound[f->binding[i].index];
	}
	return YES;
}

@interface SMComputeEncoder : SMObject
@property (nonatomic, strong) SMCommandBuffer *commandBuffer;
@end
@implementation SMComputeEncoder {
	SMComputePipeline *_pipeline;
	uint64_t _address[SWEET_AIR_MAX_BINDINGS];
}
- (MTLDispatchType)dispatchType
{
	return MTLDispatchTypeSerial;
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state
{
	if (![(id)state isKindOfClass:[SMComputePipeline class]]) {
		[_commandBuffer refuse:@"compute: foreign pipeline state"];
		return;
	}
	_pipeline = (SMComputePipeline *)state;
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index >= SWEET_AIR_MAX_BINDINGS) {
		[_commandBuffer refuse:@"compute: buffer index out of range"];
		return;
	}
	if (!buffer) {
		_address[index] = 0;
		return;
	}
	if (![(id)buffer isKindOfClass:[SMBuffer class]]) {
		[_commandBuffer refuse:@"compute: foreign buffer"];
		return;
	}
	SMBuffer *b = (SMBuffer *)buffer;
	[_commandBuffer use:b];
	_address[index] = smv_buffer_address(b.handle) + offset;
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	(void)offset;
	(void)index;
	[_commandBuffer refuse:@"compute: setBufferOffset is not implemented yet"];
}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained *)buffers offsets:(const NSUInteger *)offsets
    withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; ++i) {
		[self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}
/* setBytes: a small buffer of its own, kept by the command buffer. */
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	smv_buffer *h = smv_buffer_new(length ? length : 4, bytes);
	if (!h) {
		[_commandBuffer refuse:[NSString stringWithFormat:@"setBytes: %s", smv_error()]];
		return;
	}
	SMBuffer *b = [SMBuffer new];
	b.handle = h;
	[self setBuffer:(id<MTLBuffer>)b offset:0 atIndex:index];
}
- (void)dispatchGroups:(MTLSize)groups local:(MTLSize)local
{
	if (!_pipeline) {
		[_commandBuffer refuse:@"dispatch without a pipeline state"];
		return;
	}
	const struct sweet_air_function *f = _pipeline.function.info;
	uint64_t addresses[SWEET_AIR_MAX_BINDINGS];
	for (unsigned i = 0; i < f->bindings; ++i) {
		if (f->binding[i].type != SWEET_AIR_BUFFER || f->binding[i].index >= SWEET_AIR_MAX_BINDINGS) {
			[_commandBuffer refuse:@"compute: only buffer arguments are implemented yet"];
			return;
		}
		addresses[i] = _address[f->binding[i].index];
	}
	smv_cmd *c = [_commandBuffer cmd];
	const uint32_t g[3] = { (uint32_t)groups.width, (uint32_t)groups.height, (uint32_t)groups.depth };
	const uint32_t l[3] = { (uint32_t)local.width, (uint32_t)local.height, (uint32_t)local.depth };
	if (c && !smv_cmd_dispatch(c, _pipeline.kernel, addresses, f->bindings, g, l)) {
		[_commandBuffer refuse:[NSString stringWithFormat:@"dispatch: %s", smv_error()]];
	}
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)local
{
	[self dispatchGroups:groups local:local];
}
/* Iridium's kernels have no out-of-grid check yet: only grids that are a
 * whole number of threadgroups. */
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)local
{
	if (!local.width || !local.height || !local.depth || threads.width % local.width ||
	    threads.height % local.height || threads.depth % local.depth) {
		[_commandBuffer refuse:@"dispatchThreads: partial threadgroups are not implemented yet"];
		return;
	}
	[self dispatchGroups:MTLSizeMake(threads.width / local.width, threads.height / local.height,
	    threads.depth / local.depth) local:local];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope
{
	(void)scope;    /* every dispatch ends with a full barrier */
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage
{
	(void)usage;
	if ([(id)resource isKindOfClass:[SMBuffer class]]) {
		[_commandBuffer use:(SMBuffer *)resource];
	}
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
	_pipeline = nil;
}
@end

@interface SMRenderEncoder : SMObject
@property (nonatomic, strong) SMCommandBuffer *commandBuffer;
@end
@implementation SMRenderEncoder {
	SMRenderPipeline *_pipeline;
	MTLCullMode _cull;
	MTLWinding _winding;
	uint64_t _vertex[SWEET_AIR_MAX_BINDINGS], _fragment[SWEET_AIR_MAX_BINDINGS];
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state
{
	if (![(id)state isKindOfClass:[SMRenderPipeline class]]) {
		[_commandBuffer refuse:@"render: foreign pipeline state"];
		return;
	}
	_pipeline = (SMRenderPipeline *)state;
}
- (void)bind:(id<MTLBuffer>)buffer offset:(NSUInteger)offset index:(NSUInteger)index into:(uint64_t *)table
{
	if (index >= SWEET_AIR_MAX_BINDINGS) {
		[_commandBuffer refuse:@"render: buffer index out of range"];
		return;
	}
	if (!buffer) {
		table[index] = 0;
		return;
	}
	if (![(id)buffer isKindOfClass:[SMBuffer class]]) {
		[_commandBuffer refuse:@"render: foreign buffer"];
		return;
	}
	[_commandBuffer use:buffer];
	table[index] = smv_buffer_address(((SMBuffer *)buffer).handle) + offset;
}
- (void)bytes:(const void *)bytes length:(NSUInteger)length index:(NSUInteger)index into:(uint64_t *)table
{
	smv_buffer *h = smv_buffer_new(length ? length : 4, bytes);
	if (!h) {
		[_commandBuffer refuse:[NSString stringWithFormat:@"set*Bytes: %s", smv_error()]];
		return;
	}
	SMBuffer *b = [SMBuffer new];
	b.handle = h;
	[self bind:(id<MTLBuffer>)b offset:0 index:index into:table];
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	[self bind:buffer offset:offset index:index into:_vertex];
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	[self bind:buffer offset:offset index:index into:_fragment];
}
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	[self bytes:bytes length:length index:index into:_vertex];
}
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	[self bytes:bytes length:length index:index into:_fragment];
}
- (void)setViewport:(MTLViewport)v
{
	smv_cmd *c = [_commandBuffer cmd];
	if (c) {
		smv_cmd_viewport(c, v.originX, v.originY, v.width, v.height, v.znear, v.zfar);
	}
}
- (void)setCullMode:(MTLCullMode)mode
{
	_cull = mode;
	[self raster];
}
- (void)setFrontFacingWinding:(MTLWinding)winding
{
	_winding = winding;
	[self raster];
}
- (void)raster
{
	smv_cmd *c = [_commandBuffer cmd];
	if (c) {
		smv_cmd_raster(c, (uint32_t)_cull,
		    _winding == MTLWindingClockwise ? VK_FRONT_FACE_CLOCKWISE : VK_FRONT_FACE_COUNTER_CLOCKWISE);
	}
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)mode
{
	if (mode != MTLTriangleFillModeFill) {
		[_commandBuffer refuse:@"render: only filled triangles are implemented yet"];
	}
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state
{
	if (state) {
		[_commandBuffer refuse:@"render: depth/stencil is not implemented yet"];
	}
}
- (void)setScissorRect:(MTLScissorRect)rect
{
	(void)rect;
	sweet_metal_log("setScissorRect ignored (not implemented yet)");
}
- (void)setBlendColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha
{
	(void)red;
	(void)green;
	(void)blue;
	(void)alpha;
	sweet_metal_log("setBlendColor ignored (not implemented yet)");
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
    instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base
{
	if (!_pipeline) {
		[_commandBuffer refuse:@"draw without a pipeline state"];
		return;
	}
	uint64_t va[SWEET_AIR_MAX_BINDINGS], fa[SWEET_AIR_MAX_BINDINGS];
	const struct sweet_air_function *vf = _pipeline.vertex.info, *ff = _pipeline.fragment.info;
	if (!stageAddresses(vf, _vertex, va) || !stageAddresses(ff, _fragment, fa)) {
		[_commandBuffer refuse:@"render: only buffer arguments are implemented yet"];
		return;
	}
	smv_cmd *c = [_commandBuffer cmd];
	if (c && !smv_cmd_draw(c, _pipeline.handle, (uint32_t)type, va, vf->bindings, fa, ff ? ff->bindings : 0,
	    (uint32_t)start, (uint32_t)count, (uint32_t)instances, (uint32_t)base)) {
		[_commandBuffer refuse:[NSString stringWithFormat:@"draw: %s", smv_error()]];
	}
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
    instanceCount:(NSUInteger)instances
{
	[self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:instances baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
	[self drawPrimitives:type vertexStart:start vertexCount:count instanceCount:1 baseInstance:0];
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage
{
	(void)usage;
	[_commandBuffer use:resource];
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
	smv_cmd *c = [_commandBuffer cmd];
	if (c) {
		smv_cmd_end_render(c);
	}
	_commandBuffer = nil;
	_pipeline = nil;
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
- (void)use:(id)resource
{
	@synchronized (_resources) {
		[_resources addObject:resource];
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
	if (self.committed) {
		[self refuse:@"computeCommandEncoder after commit"];
		return nil;
	}
	SMComputeEncoder *e = [SMComputeEncoder new];
	e.commandBuffer = self;
	return (id<MTLComputeCommandEncoder>)e;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type
{
	(void)type;
	return [self computeCommandEncoder];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
	if (d.depthAttachment.texture || d.stencilAttachment.texture) {
		[self refuse:@"render: depth/stencil attachments are not implemented yet"];
		return nil;
	}
	struct smv_attachment a[SMV_MAX_TARGETS];
	unsigned n = 0;
	NSUInteger w = d.renderTargetWidth, h = d.renderTargetHeight;
	for (unsigned i = 0; i < SMV_MAX_TARGETS; ++i) {
		MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
		if (!c.texture) {
			continue;
		}
		if (![(id)c.texture isKindOfClass:[SMTexture class]] || c.level || c.slice || i != n) {
			[self refuse:@"render: color attachments must be this device's textures, level 0, in order"];
			return nil;
		}
		SMTexture *t = (SMTexture *)c.texture;
		[self use:t];
		static const uint32_t load[] = { VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_LOAD_OP_LOAD,
			VK_ATTACHMENT_LOAD_OP_CLEAR };
		a[n] = (struct smv_attachment){ .texture = t.handle,
			.load = c.loadAction <= MTLLoadActionClear ? load[c.loadAction] : VK_ATTACHMENT_LOAD_OP_LOAD,
			.store = c.storeAction == MTLStoreActionDontCare ? VK_ATTACHMENT_STORE_OP_DONT_CARE :
			    VK_ATTACHMENT_STORE_OP_STORE,
			.clear = { (float)c.clearColor.red, (float)c.clearColor.green, (float)c.clearColor.blue,
			    (float)c.clearColor.alpha } };
		if (!w || !h) {
			w = t.width;
			h = t.height;
		}
		n++;
	}
	smv_cmd *c = [self cmd];
	if (!c) {
		return nil;
	}
	if (!smv_cmd_begin_render(c, a, n, (uint32_t)w, (uint32_t)h)) {
		[self refuse:[NSString stringWithFormat:@"render pass: %s", smv_error()]];
		return nil;
	}
	SMRenderEncoder *e = [SMRenderEncoder new];
	e.commandBuffer = self;
	return (id<MTLRenderCommandEncoder>)e;
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
		{ [SMComputeEncoder class], "MTLComputeCommandEncoder" },
		{ [SMComputeEncoder class], "MTLComputeCommandEncoderSPI" },
		{ [SMLibrary class], "MTLLibrary" }, { [SMLibrary class], "MTLLibrarySPI" },
		{ [SMFunction class], "MTLFunction" }, { [SMFunction class], "MTLFunctionSPI" },
		{ [SMComputePipeline class], "MTLComputePipelineState" },
		{ [SMComputePipeline class], "MTLComputePipelineStateSPI" },
		{ [SMTexture class], "MTLTexture" }, { [SMTexture class], "MTLTextureSPI" },
		{ [SMRenderPipeline class], "MTLRenderPipelineState" },
		{ [SMRenderPipeline class], "MTLRenderPipelineStateSPI" },
		{ [SMRenderEncoder class], "MTLRenderCommandEncoder" },
		{ [SMRenderEncoder class], "MTLRenderCommandEncoderSPI" },
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
/* Source needs the on-device MSL front end (MTLCompilerService); only
 * compiled metallibs for now. */
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error
{
	(void)source;
	(void)options;
	if (error) {
		*error = smError(@"newLibraryWithSource is not implemented yet: use a metallib");
	}
	return nil;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	const void *bytes = NULL;
	size_t size = 0;
	dispatch_data_t mapped = data ? dispatch_data_create_map(data, &bytes, &size) : nil;
	NSData *copy = mapped ? [NSData dataWithBytes:bytes length:size] : nil;
	return (id<MTLLibrary>)newLibrary(copy, error);
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error
{
	NSData *data = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error] : nil;
	return data ? (id<MTLLibrary>)newLibrary(data, error) : nil;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	if (!url.isFileURL) {
		if (error) {
			*error = smError(@"a file URL is required");
		}
		return nil;
	}
	return [self newLibraryWithFile:url.path error:error];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error
{
	NSString *path = [bundle pathForResource:@"default" ofType:@"metallib"];
	if (!path) {
		if (error) {
			*error = smError(@"the bundle has no default.metallib");
		}
		return nil;
	}
	return [self newLibraryWithFile:path error:error];
}
- (id<MTLLibrary>)newDefaultLibrary
{
	return [self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:NULL];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error
{
	if (![(id)function isKindOfClass:[SMFunction class]] ||
	    ((SMFunction *)function).functionType != MTLFunctionTypeKernel) {
		if (error) {
			*error = smError(@"not a kernel function of this device");
		}
		return nil;
	}
	SMFunction *f = (SMFunction *)function;
	smv_kernel *k = smv_kernel_new(f.library.spirv.bytes, f.library.spirv.length, f.name.UTF8String);
	if (!k) {
		if (error) {
			*error = smError([NSString stringWithFormat:@"kernel %@: %s", f.name, smv_error()]);
		}
		return nil;
	}
	SMComputePipeline *p = [SMComputePipeline new];
	p.function = f;
	p.kernel = k;
	if (error) {
		*error = nil;
	}
	return (id<MTLComputePipelineState>)p;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function
    options:(MTLPipelineOption)options reflection:(MTLAutoreleasedComputePipelineReflection *)reflection
    error:(NSError **)error
{
	(void)options;
	if (reflection) {
		*reflection = nil;
	}
	return [self newComputePipelineStateWithFunction:function error:error];
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function
    completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLComputePipelineState> p = [self newComputePipelineStateWithFunction:function error:&error];
	handler(p, error);
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	const struct pixel_format *f = pixelFormat(d.pixelFormat);
	if (d.textureType != MTLTextureType2D || d.mipmapLevelCount != 1 || d.sampleCount != 1 ||
	    d.arrayLength != 1 || !f) {
		sweet_metal_log("texture refused: type %lu format %lu mips %lu samples %lu (2D, 1 level, 1 sample only)",
		    (unsigned long)d.textureType, (unsigned long)d.pixelFormat, (unsigned long)d.mipmapLevelCount,
		    (unsigned long)d.sampleCount);
		return nil;
	}
	smv_texture *h = smv_texture_new((uint32_t)d.width, (uint32_t)d.height, f->vk, f->bytes);
	if (!h) {
		sweet_metal_log("texture refused: %s", smv_error());
		return nil;
	}
	SMTexture *t = [SMTexture new];
	t.handle = h;
	t.pixelFormat = d.pixelFormat;
	t.width = d.width;
	t.height = d.height;
	t.usage = d.usage;
	t.options = d.resourceOptions;
	return (id<MTLTexture>)t;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
    error:(NSError **)error
{
	NSString *why = nil;
	SMFunction *vf = [(id)d.vertexFunction isKindOfClass:[SMFunction class]] ? (SMFunction *)d.vertexFunction : nil;
	SMFunction *ff = [(id)d.fragmentFunction isKindOfClass:[SMFunction class]] ?
	    (SMFunction *)d.fragmentFunction : nil;
	if (!vf || vf.functionType != MTLFunctionTypeVertex || !ff || ff.functionType != MTLFunctionTypeFragment) {
		why = @"a vertex and a fragment function of this device are required";
	} else if (vf.library != ff.library) {
		why = @"vertex and fragment functions from different libraries are not implemented yet";
	} else if (d.vertexDescriptor.attributes[0].format != MTLVertexFormatInvalid) {
		why = @"vertex descriptors (stage_in attributes) are not implemented yet";
	} else if (d.depthAttachmentPixelFormat != MTLPixelFormatInvalid ||
	    d.stencilAttachmentPixelFormat != MTLPixelFormatInvalid) {
		why = @"depth/stencil is not implemented yet";
	}
	struct smv_color_target targets[SMV_MAX_TARGETS];
	unsigned n = 0;
	for (unsigned i = 0; !why && i < SMV_MAX_TARGETS; ++i) {
		MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
		if (c.pixelFormat == MTLPixelFormatInvalid) {
			continue;
		}
		const struct pixel_format *f = pixelFormat(c.pixelFormat);
		if (!f || i != n) {
			why = [NSString stringWithFormat:@"color attachment %u: format %lu, or not in order", i,
			    (unsigned long)c.pixelFormat];
			break;
		}
		targets[n++] = (struct smv_color_target){ .format = f->vk, .blend = c.blendingEnabled,
			.src_rgb = blendFactor(c.sourceRGBBlendFactor), .dst_rgb = blendFactor(c.destinationRGBBlendFactor),
			.op_rgb = (uint32_t)c.rgbBlendOperation, .src_alpha = blendFactor(c.sourceAlphaBlendFactor),
			.dst_alpha = blendFactor(c.destinationAlphaBlendFactor), .op_alpha = (uint32_t)c.alphaBlendOperation,
			.write_mask = writeMask(c.writeMask) };
	}
	smv_render_pipeline *h = NULL;
	if (!why) {
		h = smv_render_pipeline_new(vf.library.spirv.bytes, vf.library.spirv.length, vf.name.UTF8String,
		    ff.name.UTF8String, targets, n);
		if (!h) {
			why = [NSString stringWithUTF8String:smv_error()];
		}
	}
	if (why) {
		sweet_metal_log("render pipeline refused: %s", why.UTF8String);
		if (error) {
			*error = smError(why);
		}
		return nil;
	}
	SMRenderPipeline *p = [SMRenderPipeline new];
	p.handle = h;
	p.vertex = vf;
	p.fragment = ff;
	p.label = d.label;
	if (error) {
		*error = nil;
	}
	return (id<MTLRenderPipelineState>)p;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
    options:(MTLPipelineOption)options reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection
    error:(NSError **)error
{
	(void)options;
	if (reflection) {
		*reflection = nil;
	}
	return [self newRenderPipelineStateWithDescriptor:d error:error];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
    completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&error];
	handler(p, error);
}
@end
