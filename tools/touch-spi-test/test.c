/*
 * Host test for bsd/dev/sweet_touch_spi.c (patch 0082): the protocol half
 * of the driver against frame-level models of the joyeuse touch ICs.
 *
 * The models check what the vendor drivers' sequences imply and nothing
 * more: Novatek page/offset framing, SRAM contents, hw-CRC bank registers
 * and boot-ready; Focaltech framing, CRC-16, ROM boot, PRAM/DRAM contents
 * and ECC. They are not the real ICs: timing, the GENI layer and the real
 * chips' reactions to foreign frames are untested here.
 *
 *   tools/touch-spi-test/run.sh FT8756.bin NT36675.bin
 */
#define SWEET_TOUCH_SPI_HOST 1
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void sweet_hid_touch(int finger, int down, int x, int y);
#include "sweet_touch_spi.c"

static struct {
	int finger, down, x, y;
} ev[64];
static unsigned nev;

static void
sweet_hid_touch(int finger, int down, int x, int y)
{
	assert(nev < 64);
	ev[nev].finger = finger;
	ev[nev].down = down;
	ev[nev].x = x;
	ev[nev].y = y;
	++nev;
}

static int ic;                 /* JT_FTS or JT_NVT */
static unsigned frames, max_frame;
static bool reset_high = true;
static const uint8_t *ref;     /* firmware the model expects */
static size_t ref_len;

static void jt_msleep(unsigned ms) { (void)ms; }
static void jt_udelay(unsigned us) { (void)us; }

/* ---------------- NT36675 ---------------- */
static uint8_t *nm;            /* 8 MiB address space */
static uint32_t npage;
static bool n_boot_ok, n_running;

static void
n_boot_ready(void)
{
	struct nvt_part p[NVT_PARTS_MAX];
	unsigned n = 0;
	n_boot_ok = false;
	assert(!nvt_parse(ref, ref_len, p, &n));
	for (unsigned i = 0; i < n; ++i) {
		if (p[i].size && memcmp(nm + p[i].sram, ref + p[i].bin, p[i].size)) {
			printf("model nvt: partition %u differs\n", i);
			return;
		}
	}
	const uint32_t des[2] = {NVT_ILM_DES, NVT_DLM_DES}, len[2] = {NVT_ILM_LEN, NVT_DLM_LEN};
	const uint32_t sum[2] = {NVT_G_ILM_SUM, NVT_G_DLM_SUM};
	for (unsigned i = 0; i < 2; ++i) {
		uint32_t d = nm[des[i]] | (nm[des[i] + 1] << 8) | (nm[des[i] + 2] << 16);
		uint32_t l = nm[len[i]] | (nm[len[i] + 1] << 8) | ((nm[len[i] + 2] & 1u) << 16);
		if (d != p[i].sram || l != p[i].size || jt_le32(nm + sum[i]) != p[i].crc) {
			printf("model nvt: crc bank %u wrong (%#x %#x %#x)\n", i, d, l, jt_le32(nm + sum[i]));
			return;
		}
	}
	if (!(nm[NVT_BLD_CRC_EN] & 0x80u) || nm[NVT_EVENT_BUF + NVT_HOST_CMD] != 0xae) {
		printf("model nvt: crc enables missing\n");
		return;
	}
	n_boot_ok = n_running = true;
	nm[NVT_EVENT_BUF + NVT_RESET_COMPLETE] = 0xa0;
	uint8_t *fi = nm + NVT_EVENT_BUF + NVT_FWINFO;
	fi[0] = 0x12; fi[1] = 0xed; fi[2] = 16; fi[3] = 36;
	fi[4] = 0x04; fi[5] = 0x38; fi[6] = 0x09; fi[7] = 0x60; /* 1080 x 2400 */
}

static void
n_frame(const uint8_t *tx, uint8_t *rx, unsigned len)
{
	if (tx[0] & 0x80u) {
		if (tx[0] == 0xff) {
			assert(len == 3);
			npage = ((uint32_t)tx[1] << 15) | ((uint32_t)tx[2] << 7);
			return;
		}
		uint32_t a = npage + (tx[0] & 0x7fu);
		assert(a + len - 1 <= 0x800000u);
		memcpy(nm + a, tx + 1, len - 1);
		if (a == NVT_SWRST_N8 && tx[1] == 0x69) {
			n_running = false;
			memset(nm + NVT_EVENT_BUF, 0, 0x100);
		}
		if (a == NVT_BOOT_RDY && tx[1] == 1) {
			n_boot_ready();
		}
		if (rx) {
			memset(rx, 0, len);
		}
		return;
	}
	assert(rx);
	rx[0] = rx[1] = 0x5a; /* offset/dummy slots carry nothing */
	memcpy(rx + 2, nm + npage + tx[0], len - 2);
}

/* ---------------- FT8756 ---------------- */
static uint8_t fpram[128 * 1024], fdram[16 * 1024];
static uint32_t faddr, fecc_region;
static uint16_t fecc;
static enum { F_ROM, F_BOOT, F_APP } fstate;
static bool f_fresh_reset, f_flip_ecc;
static uint8_t freg[256];

static void
f_reply(uint8_t *rx, unsigned n, const uint8_t *data)
{
	memcpy(rx + 7, data, n);
	uint16_t c = fts_crc(rx + 7, n);
	rx[7 + n] = (uint8_t)c;
	rx[8 + n] = (uint8_t)(c >> 8);
}

static void
f_frame(const uint8_t *tx, uint8_t *rx, unsigned len)
{
	assert(rx && len >= 4);
	memset(rx, 0, len);
	uint8_t cmd = tx[0], ctrl = tx[1];
	unsigned n = ((unsigned)tx[2] << 8) | tx[3];
	if (ctrl == FTS_READ) {
		assert(len == 7 + n + 2);
		uint8_t d[256] = {0};
		assert(n <= sizeof(d));
		if (fstate == F_BOOT && cmd == FTS_READ_ID) {
			d[0] = 0x87; d[1] = 0x56;
		} else if (fstate == F_BOOT && cmd == FTS_ECC_FINISH) {
			d[0] = 0xa5;
		} else if (fstate == F_BOOT && cmd == FTS_ECC_READ) {
			d[0] = (uint8_t)(fecc >> 8); d[1] = (uint8_t)fecc;
		} else if (fstate == F_APP) {
			memcpy(d, freg + cmd, n);
		}
		f_reply(rx, n, d);
		return;
	}
	assert(ctrl == FTS_WRITE);
	assert(len == (n ? 7 + n : 4));
	const uint8_t *d = tx + 7;
	if (cmd == FTS_START1 && n == 0) {
		if (f_fresh_reset) {
			fstate = F_BOOT;
		}
		f_fresh_reset = false;
		return;
	}
	if (fstate != F_BOOT) {
		return;
	}
	switch (cmd) {
	case FTS_SET_PRAM_ADDR:
		assert(n == 3);
		faddr = ((uint32_t)d[0] << 16) | (d[1] << 8) | d[2];
		break;
	case FTS_ROM_WRITE:
		if (faddr >= FTS_DRAM_SADDR) {
			assert(faddr - FTS_DRAM_SADDR + n <= sizeof(fdram));
			memcpy(fdram + (faddr - FTS_DRAM_SADDR), d, n);
			fecc_region = 1;
		} else {
			assert(faddr + n <= sizeof(fpram));
			memcpy(fpram + faddr, d, n);
			fecc_region = 0;
		}
		faddr += n;
		break;
	case FTS_ECC_CALC: {
		assert(n == 6);
		uint32_t a = ((uint32_t)d[0] << 16) | (d[1] << 8) | d[2];
		uint32_t l = ((uint32_t)d[3] << 16) | (d[4] << 8) | d[5];
		const uint8_t *m = fecc_region ? fdram : fpram;
		fecc = fts_ecc_host(m + a, l) ^ (f_flip_ecc ? 1u : 0u);
		break;
	}
	case FTS_START_APP: {
		uint32_t pram = (((uint32_t)ref[0x100] << 8) | ref[0x101]) * 2u;
		uint32_t dram = (((uint32_t)ref[0x108] << 8) | ref[0x109]) * 2u;
		assert(!memcmp(fpram, ref, pram));
		assert(!memcmp(fdram, ref + pram, dram));
		fstate = F_APP;
		freg[0xa3] = 0x87;
		freg[0xa6] = 0x0e;
		freg[1] = 0x90;
		break;
	}
	default:
		printf("model fts: unexpected boot cmd %#x\n", cmd);
		assert(0);
	}
}

static int
jt_xfer(const uint8_t *tx, uint8_t *rx, unsigned len)
{
	assert(len && len <= JT_BUF);
	++frames;
	max_frame = len > max_frame ? len : max_frame;
	if (ic == JT_NVT) {
		n_frame(tx, rx, len);
	} else {
		f_frame(tx, rx, len);
	}
	return 0;
}

static void
jt_reset_pin(bool high)
{
	if (high && !reset_high && ic == JT_FTS) {
		fstate = F_ROM;
		f_fresh_reset = true;
	}
	reset_high = high;
}

static uint8_t *
slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	assert(f);
	fseek(f, 0, SEEK_END);
	*len = (size_t)ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc(*len);
	assert(fread(b, 1, *len, f) == *len);
	fclose(f);
	return b;
}

static void
expect(unsigned i, int finger, int down, int x, int y)
{
	if (i >= nev || ev[i].finger != finger || ev[i].down != down || ev[i].x != x || ev[i].y != y) {
		printf("event %u: want %d/%d %d,%d got %d/%d %d,%d (n=%u)\n", i, finger, down, x, y,
		    i < nev ? ev[i].finger : -1, i < nev ? ev[i].down : -1,
		    i < nev ? ev[i].x : -1, i < nev ? ev[i].y : -1, nev);
		exit(1);
	}
}

static void
test_fts(const char *path)
{
	size_t len;
	uint8_t *fw = slurp(path, &len);
	ic = JT_FTS;
	ref = fw; ref_len = len;
	assert(jt_detect(0) == JT_FTS);
	assert(!fts_download(fw, len));
	assert(fstate == F_APP);
	/* two fingers down, then finger 0 moves, then finger 1 lifts, then all up */
	nev = 0;
	memset(freg + 2, 0xff, 61);
	freg[2] = 2;
	uint8_t *p0 = freg + 3, *p1 = freg + 9;
	p0[0] = (0u << 6) | (540 >> 8); p0[1] = 540 & 0xff; p0[2] = (0u << 4) | (1200 >> 8); p0[3] = 1200 & 0xff;
	p1[0] = (0u << 6) | (100 >> 8); p1[1] = 100 & 0xff; p1[2] = (1u << 4) | (2000 >> 8); p1[3] = 2000 & 0xff;
	assert(!fts_poll());
	assert(!fts_poll()); /* unchanged frame: no events */
	p0[1] = 560 & 0xff; p0[0] = (2u << 6) | (560 >> 8);
	assert(!fts_poll());
	p1[0] = (1u << 6) | (100 >> 8); freg[2] = 1;
	assert(!fts_poll());
	freg[2] = 0; p0[0] = (1u << 6) | (560 >> 8);
	assert(!fts_poll());
	expect(0, 0, 1, 540, 1200);
	expect(1, 1, 1, 100, 2000);
	expect(2, 0, 1, 560, 1200);
	expect(3, 1, 0, 100, 2000);
	expect(4, 0, 0, 560, 1200);
	assert(nev == 5);
	freg[2] = freg[3] = freg[4] = 0xef;
	assert(fts_poll() == 1); /* firmware recovery */
	/* ECC mismatch: three attempts, then failure */
	f_flip_ecc = true;
	assert(fts_download(fw, len) == EIO);
	f_flip_ecc = false;
	/* broken app length */
	uint8_t *bad = malloc(len);
	memcpy(bad, fw, len);
	bad[0x103] ^= 1;
	assert(fts_download(bad, len) == EINVAL);
	free(bad);
	printf("FT8756: ok (%u frames, largest %u bytes)\n", frames, max_frame);
	free(fw);
}

static void
test_nvt(const char *path)
{
	size_t len;
	uint8_t *fw = slurp(path, &len);
	nm = calloc(1, 0x800000);
	memcpy(nm + NVT_TRIM_ID, (const uint8_t[]){0x00, 0x00, 0x00, 0x75, 0x66, 0x03}, 6);
	ic = JT_NVT;
	ref = fw; ref_len = len;
	frames = max_frame = 0;
	assert(jt_detect(0) == JT_NVT); /* Focaltech probe fails first, then trim id */
	assert(!nvt_download(fw, len));
	assert(n_boot_ok && jt.abs_x == 1080 && jt.abs_y == 2400);
	nev = 0;
	jt.active = 0;
	uint8_t *e = nm + NVT_EVENT_BUF;
	memset(e, 0, NVT_POINT_LEN);
	/* id 1 at 540,1200 (status 1 = enter), id 3 at 1079,2399 (status 2 = move) */
	e[0] = (1 << 3) | 1; e[1] = 540 >> 4; e[2] = 1200 >> 4; e[3] = ((540 & 15) << 4) | (1200 & 15);
	e[6] = (3 << 3) | 2; e[7] = 1079 >> 4; e[8] = 2399 >> 4; e[9] = ((1079 & 15) << 4) | (2399 & 15);
	assert(!nvt_poll());
	e[6] = (3 << 3) | 3; /* id 3 up */
	assert(!nvt_poll());
	memset(e, 0x77, 6);  /* handshake frame keeps contacts */
	assert(!nvt_poll());
	memset(e, 0, NVT_POINT_LEN);
	assert(!nvt_poll());
	expect(0, 0, 1, 540, 1200);
	expect(1, 2, 1, 1079, 2399);
	expect(2, 2, 0, 1079, 2399);
	expect(3, 0, 0, 540, 1200);
	assert(nev == 4);
	memset(e, 0xfe, 6);
	int st = 0;
	for (unsigned i = 0; i < 11; ++i) {
		st = nvt_poll();
	}
	assert(st == 1); /* watchdog recovery after > 10 frames */
	/* image checks */
	uint8_t *bad = malloc(len);
	memcpy(bad, fw, len);
	struct nvt_part p[NVT_PARTS_MAX];
	unsigned n;
	size_t need = 131072;
	bad[need - 4096 + 1] ^= 1;
	assert(nvt_parse(bad, len, p, &n) == EINVAL);
	free(bad);
	printf("NT36675: ok (%u frames, largest %u bytes)\n", frames, max_frame);
	free(fw);
	free(nm);
}

int
main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s focaltech_ts_fw_huaxing.bin novatek_ts_tianma_fw.bin\n", argv[0]);
		return 2;
	}
	test_fts(argv[1]);
	test_nvt(argv[2]);
	printf("all ok\n");
	return 0;
}
