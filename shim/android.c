/*
 * The menu's Android entry: boot the Android ROM's own boot.img (header v2,
 * an uncompressed arm64 Image), kept unchanged in the GPT partition
 * "recoverybak" (ABL never boots it). Linux's arm64 boot protocol: the Image
 * at a 2 MiB-aligned base + text_offset, the ramdisk and the FDT anywhere in
 * RAM, MMU off, x0 = FDT. ABL already made the FDT (from this boot image's
 * dtb, which must be the ROM's, plus the ROM's dtbo partition) and its
 * androidboot.* command line; the copy gets the ROM's own cmdline in front
 * of ABL's and the ramdisk's place. All reads go through ufs.c (read-only).
 * Placement: the upper DDR bank (0x1_0000_0000, in the FDT's /memory),
 * where nothing of ABL lives.
 */
#include <stdint.h>
#include "android.h"
#include "console.h"
#include "fdt.h"
#include "ufs.h"

#define PART		"recoverybak"
#define KERNEL_BASE	0x100000000UL	/* 2 MiB aligned */
#define RAMDISK_BASE	0x106000000UL
#define FDT_BASE	0x108000000UL
#define FDT_MAX		0x200000u
#define PAGE		4096u
#define CMDLINE_MAX	4096u

static uint64_t part_lba;
static uint8_t hdr[PAGE] __attribute__((aligned(4096)));

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const uint8_t *p)
{
	return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}

int android_probe(void)
{
	uint64_t blocks = 0;
	if (ufs_open() || ufs_find(PART, &part_lba, &blocks) || ufs_read(part_lba, PAGE, (uintptr_t)hdr))
		return 0;
	static const char magic[] = "ANDROID!";
	for (int i = 0; i < 8; i++)
		if (hdr[i] != (uint8_t)magic[i])
			return 0;
	uint32_t ksize = le32(hdr + 8), rsize = le32(hdr + 16), page = le32(hdr + 36), version = le32(hdr + 40);
	uint64_t need = PAGE + ((uint64_t)ksize + PAGE - 1) / PAGE * PAGE + rsize;
	return version == 2 && page == PAGE && ksize > 0x10000 && ksize < 0x6000000 && rsize < 0x2000000 &&
	       need <= blocks * PAGE;
}

static unsigned append(char *dst, unsigned at, const char *src, unsigned n)
{
	for (unsigned i = 0; i < n && src[i] && at + 1 < CMDLINE_MAX; i++)
		dst[at++] = src[i];
	dst[at] = 0;
	return at;
}

typedef void (*linux_entry_t)(uint64_t fdt, uint64_t x1, uint64_t x2, uint64_t x3);

const char *android_boot(uintptr_t abl_fdt)
{
	if (!android_probe())
		return "no Android boot image in " PART;
	uint32_t ksize = le32(hdr + 8), rsize = le32(hdr + 16);
	uint64_t kpages = ((uint64_t)ksize + PAGE - 1) / PAGE;

	/* The Image header gives text_offset and the size it needs, bss included. */
	static uint8_t khdr[PAGE] __attribute__((aligned(4096)));
	if (ufs_read(part_lba + 1, PAGE, (uintptr_t)khdr))
		return "kernel header read error";
	if (khdr[56] != 'A' || khdr[57] != 'R' || khdr[58] != 'M' || khdr[59] != 0x64)
		return "kernel is not an uncompressed arm64 Image";
	uint64_t text_offset = le64(khdr + 8), image_size = le64(khdr + 16);
	uintptr_t entry = KERNEL_BASE + text_offset;
	if (image_size == 0 || entry + image_size > RAMDISK_BASE)
		return "kernel does not fit below the ramdisk";
	con_hex2("ANDROID", "kernel=", ksize, "ramdisk=", rsize);

	if (ufs_read(part_lba + 1, ksize, entry))
		return "kernel read error";
	if (ufs_read(part_lba + 1 + kpages, rsize, RAMDISK_BASE))
		return "ramdisk read error";

	/* ROM cmdline (+ extra_cmdline), then ABL's own arguments minus the shim's. */
	static char cmdline[CMDLINE_MAX];
	static char abl[CMDLINE_MAX];
	unsigned n = append(cmdline, 0, (const char *)hdr + 64, 512);
	n = append(cmdline, n, (const char *)hdr + 608, 1024);
	fdt_chosen_str(abl_fdt, "bootargs", abl, sizeof(abl));
	const char *a = abl;
	static const char shim_arg[] = "console=null";
	for (;;) {
		while (*a == ' ')
			a++;
		if (!*a)
			break;
		unsigned len = 0;
		while (a[len] && a[len] != ' ')
			len++;
		int is_shim = len == sizeof(shim_arg) - 1;
		for (unsigned i = 0; is_shim && i < len; i++)
			is_shim = a[i] == shim_arg[i];
		if (!is_shim) {
			n = append(cmdline, n, " ", 1);
			n = append(cmdline, n, a, len);
		}
		a += len;
	}

	if (!fdt_rewrite_chosen(abl_fdt, FDT_BASE, FDT_MAX, cmdline, RAMDISK_BASE, RAMDISK_BASE + rsize))
		return "FDT rewrite failed";
	con_hex("ENTRY", entry);
	con_str("ANDROID", "jumping to Linux");

	/* Written with the MMU and caches off; IRQs masked, stale I-cache dropped. */
	__asm__ volatile("msr daifset, #0xf; dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((linux_entry_t)entry)(FDT_BASE, 0, 0, 0);
	return "Linux returned";
}
