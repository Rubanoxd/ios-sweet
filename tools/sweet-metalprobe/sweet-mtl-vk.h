/*
 * The Vulkan (Turnip) side of the SweetMetalProbe device: one device per
 * process, buffers in host-visible coherent memory, and one-shot command
 * lists with transfer commands. All calls return 0/NULL on failure and
 * leave the reason in smv_error().
 */
#include <stddef.h>
#include <stdint.h>

typedef struct smv_buffer smv_buffer;
typedef struct smv_cmd smv_cmd;
typedef struct smv_kernel smv_kernel;
typedef struct smv_texture smv_texture;
typedef struct smv_render_pipeline smv_render_pipeline;
typedef struct smv_sampler smv_sampler;

/* Descriptor bindings of one stage (Iridium's layout, sweet-iridium.h). */
enum { SMV_DESC_UBO, SMV_DESC_SAMPLED_IMAGE, SMV_DESC_STORAGE_IMAGE, SMV_DESC_SAMPLER, SMV_DESC_INPUT_ATTACHMENT };
struct smv_binding {
	uint32_t binding, type;
};
struct smv_stage {
	const struct smv_binding *bindings;
	unsigned count;
};
/* What one stage gets at a draw or dispatch: the addresses for the UBO and
 * the texture or sampler for each other binding. */
struct smv_bind {
	uint32_t binding, type;
	smv_texture *texture;
	smv_sampler *sampler;
};
struct smv_args {
	const uint64_t *addresses;
	unsigned count;
	const struct smv_bind *res;
	unsigned nres;
};
/* Vulkan values (VkFilter, VkSamplerMipmapMode, VkSamplerAddressMode,
 * VkCompareOp, VkBorderColor). */
struct smv_sampler_desc {
	uint32_t mag, min, mip, address[3], unnormalized, compare_enable, compare_op, border;
	float lod_min, lod_max, anisotropy;
};

enum { SMV_MAX_TARGETS = 8 };

/* Values are Vulkan's (VkFormat, VkBlendFactor, VkBlendOp, VkAttachment*Op,
 * VkPrimitiveTopology, VkCullModeFlags, VkFrontFace): the Objective-C side
 * maps Metal's enums. */
struct smv_color_target {
	uint32_t format, blend, src_rgb, dst_rgb, op_rgb, src_alpha, dst_alpha, op_alpha, write_mask;
};
struct smv_attachment {
	smv_texture *texture;
	uint32_t load, store;
	float clear[4];
};

const char *smv_error(void);

/* Loads the ICD and opens its first device; NAME gets the device name. */
int smv_open(const char *icd, char *name, size_t len);
uint64_t smv_max_buffer_length(void);

smv_buffer *smv_buffer_new(uint64_t length, const void *bytes);
void smv_buffer_free(smv_buffer *b);
void *smv_buffer_contents(smv_buffer *b);
uint64_t smv_buffer_length(smv_buffer *b);
uint64_t smv_buffer_address(smv_buffer *b);

smv_sampler *smv_sampler_new(const struct smv_sampler_desc *d);
void smv_sampler_free(smv_sampler *s);

/* A compute kernel: Iridium SPIR-V, its entry point name and bindings. */
smv_kernel *smv_kernel_new(const void *spirv, size_t bytes, const char *entry, const struct smv_stage *bindings);
void smv_kernel_free(smv_kernel *k);

/* 2D textures (one mip level), always in the GENERAL layout. REGION is
 * x, y, width, height in texels. */
smv_texture *smv_texture_new(uint32_t width, uint32_t height, uint32_t format, uint32_t texel_bytes);
/* A linear image on host memory the caller owns (an IOSurface's pages, 4 KiB
 * aligned; ROW_BYTES a multiple of 64). The caller keeps it coherent. */
smv_texture *smv_texture_new_host(void *host, uint64_t bytes, uint32_t width, uint32_t height, uint32_t row_bytes,
    uint32_t format, uint32_t texel_bytes);
void smv_texture_free(smv_texture *t);
int smv_texture_access(smv_texture *t, const uint32_t region[4], void *bytes, uint32_t row_bytes, int write);

/* A vertex and a fragment function, each its own SPIR-V module. */
smv_render_pipeline *smv_render_pipeline_new(const void *vertex_spirv, size_t vertex_bytes, const char *vertex,
    const void *fragment_spirv, size_t fragment_bytes, const char *fragment,
    const struct smv_stage *vertex_bindings, const struct smv_stage *fragment_bindings,
    const struct smv_color_target *targets, unsigned count);
void smv_render_pipeline_free(smv_render_pipeline *p);

/* A command list in recording state. */
smv_cmd *smv_cmd_new(void);
int smv_cmd_fill(smv_cmd *c, smv_buffer *b, uint64_t offset, uint64_t length, uint8_t value);
int smv_cmd_copy(smv_cmd *c, smv_buffer *src, uint64_t src_offset, smv_buffer *dst, uint64_t dst_offset,
    uint64_t length);
/* Dispatches GROUPS threadgroups of LOCAL threads. */
int smv_cmd_dispatch(smv_cmd *c, smv_kernel *k, const struct smv_args *args, const uint32_t groups[3],
    const uint32_t local[3]);
int smv_cmd_copy_texture_buffer(smv_cmd *c, smv_texture *t, const uint32_t region[4], smv_buffer *b,
    uint64_t offset, uint32_t row_bytes, int to_texture);
/* A render pass: begin, any number of draws (with viewport/raster state
 * changes in between), end. Arguments per stage. */
int smv_cmd_begin_render(smv_cmd *c, const struct smv_attachment *a, unsigned count, uint32_t width,
    uint32_t height);
void smv_cmd_viewport(smv_cmd *c, double x, double y, double w, double h, double znear, double zfar);
void smv_cmd_raster(smv_cmd *c, uint32_t cull_mode, uint32_t front_face);
int smv_cmd_draw(smv_cmd *c, smv_render_pipeline *p, uint32_t topology, const struct smv_args *vertex_args,
    const struct smv_args *fragment_args, uint32_t first_vertex, uint32_t vertices, uint32_t instances,
    uint32_t first_instance);
void smv_cmd_end_render(smv_cmd *c);
/* Ends, submits and waits (at most TIMEOUT_MS); then the list is spent. */
int smv_cmd_run(smv_cmd *c, uint32_t timeout_ms);
void smv_cmd_free(smv_cmd *c);
