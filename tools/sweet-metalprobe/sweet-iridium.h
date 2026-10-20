/*
 * C interface to Darling's Iridium (AIR -> SPIR-V) for the Metal plugin.
 * Every function of a metallib has its own AIR module; each is translated
 * on its own into a SPIR-V module, so one function Iridium cannot handle
 * does not take the rest of the library with it.
 *
 * Iridium's ABI: one descriptor set per stage (compute and vertex: set 0,
 * fragment: set 1). If the function takes buffers, binding 0 is a uniform
 * buffer of their 64-bit GPU addresses, in the order listed here; textures
 * and samplers follow at their own bindings. A kernel's threadgroup size
 * comes from specialization constants 0, 1 and 2.
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { SWEET_AIR_MAX_BINDINGS = 31 };
enum sweet_air_kind { SWEET_AIR_VERTEX = 1, SWEET_AIR_FRAGMENT = 2, SWEET_AIR_KERNEL = 3 };
/* RENDER_TARGET: a fragment function's [[color(n)]] argument (iridium-patches
 * 0003), an input attachment reading color attachment n */
enum sweet_air_binding { SWEET_AIR_BUFFER, SWEET_AIR_TEXTURE, SWEET_AIR_SAMPLER, SWEET_AIR_VERTEX_INPUT,
	SWEET_AIR_RENDER_TARGET };

struct sweet_air_function {
	char name[128];
	void *spirv;            /* NULL: not translated, see error */
	size_t spirv_bytes;
	char error[192];
	int kind;               /* enum sweet_air_kind */
	unsigned bindings;
	struct {
		int type;       /* enum sweet_air_binding */
		unsigned index; /* Metal [[buffer(n)]] etc.; UINT32_MAX: embedded sampler */
		unsigned internal; /* Vulkan binding in the stage's set (buffers: all in binding 0) */
		int sampled;    /* textures: 1 sampled image, 0 storage image */
		int embedded;   /* samplers: index into sampler[], or -1 */
	} binding[SWEET_AIR_MAX_BINDINGS];
	unsigned samplers;
	/* constexpr samplers in the shader, Iridium's encoding: address modes
	 * 0 clamp-to-zero, 1 clamp-to-edge, 2 repeat, 3 mirror, 4 border;
	 * filters 0 nearest, 1 linear; mip 0 none, 1 nearest, 2 linear;
	 * compare 0 none, 1 less .. 8 never; border 0 transparent black,
	 * 1 opaque black, 2 opaque white */
	struct sweet_air_sampler {
		uint8_t address[3], mag, min, mip, normalized, compare, anisotropy, border;
		float lod_min, lod_max;
	} sampler[8];
};

/* Returns a malloc'ed array of *COUNT functions (free with sweet_air_free),
 * or NULL with the reason in ERR when METALLIB is no metallib. */
struct sweet_air_function *sweet_air_translate(const void *metallib, size_t length, size_t *count, char *err,
    size_t errlen);
void sweet_air_free(struct sweet_air_function *functions, size_t count);

#ifdef __cplusplus
}
#endif
