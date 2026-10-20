/*
 * sweet-air2spv: translates a metallib on the phone with the plugin's
 * Iridium build, one function at a time, and prints each function's
 * result and bindings; writes each SPIR-V module to OUTDIR/NAME.spv.
 *   sweet-air2spv IN.metallib [OUTDIR]
 */
#include <stdio.h>
#include <stdlib.h>
#include "sweet-iridium.h"

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s IN.metallib [OUTDIR]\n", argv[0]);
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f) {
		perror(argv[1]);
		return 1;
	}
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *lib = malloc(n);
	if (!lib || fread(lib, 1, n, f) != (size_t)n) {
		return 1;
	}
	fclose(f);
	char err[256];
	size_t count = 0, ok = 0;
	struct sweet_air_function *fn = sweet_air_translate(lib, n, &count, err, sizeof(err));
	if (!fn) {
		printf("translation failed: %s\n", err);
		return 1;
	}
	for (size_t i = 0; i < count; ++i) {
		if (!fn[i].spirv) {
			printf("  FAIL %s: %s\n", fn[i].name, fn[i].error);
			continue;
		}
		ok++;
		printf("  OK   %s kind %d, %zu bytes:", fn[i].name, fn[i].kind, fn[i].spirv_bytes);
		for (unsigned b = 0; b < fn[i].bindings; ++b) {
			static const char *const type[] = { "buffer", "texture", "sampler", "vertex-input", "render-target", "?", "?", "?" };
			printf(" %s%d@%u", type[fn[i].binding[b].type & 7], (int)fn[i].binding[b].index, fn[i].binding[b].internal);
		}
		printf("\n");
		if (argc > 2) {
			char path[512];
			snprintf(path, sizeof(path), "%s/%s.spv", argv[2], fn[i].name);
			FILE *o = fopen(path, "wb");
			if (o) {
				fwrite(fn[i].spirv, 1, fn[i].spirv_bytes, o);
				fclose(o);
			}
		}
	}
	printf("%zu of %zu functions translated\n", ok, count);
	sweet_air_free(fn, count);
	return ok ? 0 : 1;
}
