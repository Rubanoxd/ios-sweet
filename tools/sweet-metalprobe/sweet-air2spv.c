/*
 * sweet-air2spv: translates a metallib on the phone with the plugin's
 * Iridium build and prints each function's bindings; writes the SPIR-V.
 *   sweet-air2spv IN.metallib [OUT.spv]
 */
#include <stdio.h>
#include <stdlib.h>
#include "sweet-iridium.h"

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s IN.metallib [OUT.spv]\n", argv[0]);
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
	size_t bytes = 0, count = 0;
	struct sweet_air_function *fn;
	void *spv = sweet_air_translate(lib, n, &bytes, &fn, &count, err, sizeof(err));
	if (!spv) {
		printf("translation failed: %s\n", err);
		return 1;
	}
	printf("SPIR-V %zu bytes, %zu functions\n", bytes, count);
	for (size_t i = 0; i < count; ++i) {
		printf("  %s kind %d:", fn[i].name, fn[i].kind);
		for (unsigned b = 0; b < fn[i].bindings; ++b) {
			printf(" %s%u", fn[i].binding[b].type == SWEET_AIR_BUFFER ? "buffer" : "other", fn[i].binding[b].index);
		}
		printf("\n");
	}
	if (argc > 2 && (f = fopen(argv[2], "wb"))) {
		fwrite(spv, 1, bytes, f);
		fclose(f);
	}
	return 0;
}
