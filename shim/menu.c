/*
 * Boot menu on the ABL framebuffer: iOS or Android, chosen with the volume
 * keys and confirmed with power; iOS after a timeout or when no key can be
 * read. A key held when the menu appears (the power press that turned the
 * phone on) counts only once it has been released.
 */
#include <stdint.h>
#include "console.h"
#include "keys.h"
#include "menu.h"
#include "android.h"

#define BG		0xff101018U
#define BOX		0xff2a2a36U
#define SEL		0xff2a5bd7U
#define GREY		0xff8a8a99U

#define BOX_X		90
#define BOX_W		(FB_W - 2 * BOX_X)
#define BOX_H		260
#define BOX_Y0		820
#define BOX_Y1		1180

static uint64_t ticks(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	return t;
}

static uint64_t freq(void)
{
	uint64_t f;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	return f ? f : 19200000;
}

static void center(int y, const char *s, int scale, uint32_t fg, uint32_t bg)
{
	int n = 0;
	while (s[n])
		n++;
	con_text((FB_W - n * 8 * scale) / 2, y, s, scale, fg, bg);
}

static void draw_box(int y, const char *name, const char *note, int selected, int usable)
{
	uint32_t bg = selected ? SEL : BOX;
	con_rect(BOX_X, y, BOX_W, BOX_H, bg);
	con_text(BOX_X + 60, y + 50, name, 6, usable ? WHITE : GREY, bg);
	con_text(BOX_X + 64, y + 170, note, 3, selected ? WHITE : GREY, bg);
}

static void draw_options(int sel)
{
	draw_box(BOX_Y0, "iOS 16.7", "XNU sobre Snapdragon 720G", sel == 0, 1);
	draw_box(BOX_Y1, "Android 17", "RisingOS", sel == 1, 1);
}

static void draw_status(const char *s)
{
	con_rect(0, 1560, FB_W, 60, BG);
	center(1560, s, 3, YELLOW, BG);
}

static void draw_countdown(int left)
{
	char line[] = "Arranca iOS en 0 s";
	line[15] = (char)('0' + (left > 9 ? 9 : left < 0 ? 0 : left));
	con_rect(0, 1700, FB_W, 60, BG);
	if (left >= 0)
		center(1700, line, 3, GREY, BG);
}

int menu_choose(unsigned timeout_s)
{
	con_clear(BG);
	center(300, "ios-sweet", 6, WHITE, BG);
	center(450, "Redmi Note 9 Pro", 3, GREY, BG);
	center(640, "Elige el sistema", 3, WHITE, BG);
	int sel = 0;
	draw_options(sel);
	int have_keys = keys_init();
	if (!have_keys) {
		draw_status("Sin teclas: arranca iOS");
		timeout_s = timeout_s < 3 ? timeout_s : 3;
	} else {
		center(1900, keys_have_volup() ? "Vol+ / Vol-: elegir" : "Vol-: cambiar", 3, GREY, BG);
		center(1970, "Power: arrancar", 3, GREY, BG);
	}

#ifdef HOST_TEST
	return 0;	/* host render of the first frame (host_menu.c) */
#endif
	uint64_t hz = freq(), start = ticks(), last_poll = 0;
	unsigned held = have_keys ? keys_read() : 0;	/* ignored until released */
	int counting = 1, shown = -2;
	for (;;) {
		uint64_t now = ticks();
		if (counting) {
			int left = (int)timeout_s - (int)((now - start) / hz);
			if (left != shown) {
				draw_countdown(left);
				shown = left;
			}
			if (left <= 0)
				return 0;
		}
		if (!have_keys || now - last_poll < hz / 50)
			continue;
		last_poll = now;
		unsigned k = keys_read();
		unsigned pressed = k & ~held;
		held = k;
		if (!pressed)
			continue;
		if (counting) {
			counting = 0;
			draw_countdown(-1);
		}
		int next = sel;
		if (pressed & KEY_VOLUP)
			next = 0;
		if (pressed & KEY_VOLDOWN)
			next = keys_have_volup() ? 1 : !sel;
		if (next != sel) {
			sel = next;
			draw_options(sel);
			draw_status("");
		}
		if (pressed & KEY_POWER) {
			/* Android is looked for only when chosen: the iOS path never touches UFS. */
			if (sel == 1 && !android_probe()) {
				draw_status("No hay Android en recoverybak");
				continue;
			}
			draw_status(sel ? "Arrancando Android..." : "Arrancando iOS...");
			return sel;
		}
	}
}
