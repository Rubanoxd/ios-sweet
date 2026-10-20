/*
 * C interface to Darling's Iridium (AIR -> SPIR-V) for the Metal plugin.
 * One call translates a whole metallib into one SPIR-V module with an entry
 * point per function, plus each function's argument bindings.
 *
 * Iridium's kernel ABI: descriptor set 0 binding 0 is a uniform buffer of
 * 64-bit GPU addresses, one per buffer binding in the order listed here;
 * the threadgroup size comes from specialization constants 0, 1 and 2.
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { SWEET_AIR_MAX_BINDINGS = 31 };
enum sweet_air_kind { SWEET_AIR_VERTEX = 1, SWEET_AIR_FRAGMENT = 2, SWEET_AIR_KERNEL = 3 };
enum sweet_air_binding { SWEET_AIR_BUFFER, SWEET_AIR_TEXTURE, SWEET_AIR_SAMPLER, SWEET_AIR_VERTEX_INPUT };

struct sweet_air_function {
	char name[128];
	int kind;               /* enum sweet_air_kind */
	unsigned bindings;
	struct {
		int type;       /* enum sweet_air_binding */
		unsigned index; /* Metal [[buffer(n)]] etc. */
	} binding[SWEET_AIR_MAX_BINDINGS];
};

/* Returns malloc'ed SPIR-V (*SPV_BYTES long) and a malloc'ed array of
 * *COUNT functions, or NULL with the reason in ERR. */
void *sweet_air_translate(const void *metallib, size_t length, size_t *spv_bytes,
    struct sweet_air_function **functions, size_t *count, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
