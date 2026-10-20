/* Render the boot menu's first frame on the host: ./out/host_menu && view out/menu.ppm */
#include <stdio.h>
#include "console.h"
#include "keys.h"
#include "menu.h"

static uint32_t host_fb[FB_H * FB_STRIDE / 4];

int keys_init(void) { return 1; }
unsigned keys_read(void) { return 0; }
int keys_have_volup(void) { return 1; }

int main(void)
{
	con_fb = host_fb;
	menu_choose(0, 5);
	FILE *f = fopen("out/menu.ppm", "wb");
	fprintf(f, "P6 %d %d 255\n", FB_W, FB_H);
	for (int i = 0; i < FB_W * FB_H; i++) {
		unsigned char px[3] = { host_fb[i] >> 16, host_fb[i] >> 8, host_fb[i] };
		fwrite(px, 1, 3, f);
	}
	fclose(f);
	return 0;
}
