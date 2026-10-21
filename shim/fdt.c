/*
 * Just enough flattened-device-tree parsing to find what ABL put in
 * /chosen (initrd location). Big-endian, 4-byte aligned tokens.
 */
#include "fdt.h"

#define FDT_MAGIC	0xd00dfeed
#define FDT_BEGIN_NODE	1
#define FDT_END_NODE	2
#define FDT_PROP	3
#define FDT_NOP		4
#define FDT_END		9

static uint32_t be32(uintptr_t a)
{
	return __builtin_bswap32(*(volatile uint32_t *)a);
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static uintptr_t align4(uintptr_t a)
{
	return (a + 3) & ~3UL;
}

static uintptr_t skip_str(uintptr_t p)
{
	/* byte loads are fine on Device memory as long as they are aligned to 1 */
	while (*(volatile char *)p)
		p++;
	return p + 1;
}

int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);		/* off_dt_struct */
	uintptr_t strings = fdt + be32(fdt + 12);	/* off_dt_strings */
	int depth = 0, in_chosen = 0;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			depth++;
			in_chosen = depth == 2 && streq(name, "chosen");
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			if (in_chosen)
				return 0;
			depth--;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (in_chosen && streq((const char *)(strings + nameoff), prop)) {
				if (len == 4)
					*out = be32(val);
				else if (len == 8)
					*out = (uint64_t)be32(val) << 32 | be32(val + 4);
				else
					return 0;
				return 1;
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:	/* FDT_END or garbage */
			return 0;
		}
	}
}

static void put_be32(uintptr_t a, uint32_t v)
{
	*(volatile uint32_t *)a = __builtin_bswap32(v);
}

static int prefix_eq(const char *a, const char *b)
{
	return streq(a, b);
}

int fdt_chosen_str(uintptr_t fdt, const char *prop, char *out, unsigned max)
{
	out[0] = 0;
	if (!fdt || be32(fdt) != FDT_MAGIC || !max)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8), strings = fdt + be32(fdt + 12);
	int depth = 0, in_chosen = 0;
	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		if (tok == FDT_BEGIN_NODE) {
			depth++;
			in_chosen = depth == 2 && streq((const char *)p, "chosen");
			p = align4(skip_str(p));
		} else if (tok == FDT_END_NODE) {
			if (in_chosen)
				return 0;
			depth--;
		} else if (tok == FDT_PROP) {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (in_chosen && streq((const char *)(strings + nameoff), prop)) {
				unsigned i = 0;
				for (; i + 1 < max && i < len && *(volatile char *)(val + i); i++)
					out[i] = *(volatile char *)(val + i);
				out[i] = 0;
				return 1;
			}
			p = align4(val + len);
		} else if (tok != FDT_NOP) {
			return 0;
		}
	}
}

/*
 * Copies the FDT at SRC to DST (at most MAX bytes) with /chosen's bootargs,
 * linux,initrd-start and linux,initrd-end replaced. Returns the new size, or
 * 0 if it does not fit or SRC is not an FDT.
 */
uint32_t fdt_rewrite_chosen(uintptr_t src, uintptr_t dst, uint32_t max, const char *bootargs,
    uint64_t rd_start, uint64_t rd_end)
{
	if (be32(src) != FDT_MAGIC || max < 0x1000)
		return 0;
	/* No pointer tables: the shim runs unrelocated (build.sh rejects ABS64). */
	const char *drop[3];
	drop[0] = "bootargs";
	drop[1] = "linux,initrd-start";
	drop[2] = "linux,initrd-end";
	uintptr_t s_struct = src + be32(src + 8), s_strings = src + be32(src + 12);
	uintptr_t s_rsv = src + be32(src + 16);
	uint32_t s_strings_size = be32(src + 32);

	/* Header, then the reserve map, struct block and strings block. */
	uintptr_t d = dst + 0x28, end = dst + max;
	uintptr_t d_rsv = d;
	for (;;) {
		uint64_t a = (uint64_t)be32(s_rsv) << 32 | be32(s_rsv + 4);
		uint64_t b = (uint64_t)be32(s_rsv + 8) << 32 | be32(s_rsv + 12);
		for (int i = 0; i < 4; i++)
			put_be32(d + 4 * i, be32(s_rsv + 4 * i));
		d += 16;
		s_rsv += 16;
		if (!a && !b)
			break;
		if (d + 16 > end)
			return 0;
	}
	uintptr_t d_struct = d;
	/* New property names go after the copied strings. */
	uint32_t name_off[3];
	uint32_t extra_strings = 0;
	for (int i = 0; i < 3; i++) {
		name_off[i] = s_strings_size + extra_strings;
		const char *n = drop[i];
		while (*n++)
			extra_strings++;
		extra_strings++;
	}

	uintptr_t p = s_struct;
	int depth = 0, in_chosen = 0;
	for (;;) {
		if (d + 64 > end)
			return 0;
		uint32_t tok = be32(p);
		p += 4;
		if (tok == FDT_BEGIN_NODE) {
			depth++;
			in_chosen = depth == 2 && streq((const char *)p, "chosen");
			uintptr_t name_end = align4(skip_str(p));
			put_be32(d, tok);
			d += 4;
			for (uintptr_t q = p; q < name_end; q++, d++)
				*(volatile uint8_t *)d = *(volatile uint8_t *)q;
			p = name_end;
		} else if (tok == FDT_END_NODE) {
			if (in_chosen) {
				/* bootargs (string), then the two 64-bit initrd cells. */
				uint32_t blen = 0;
				while (bootargs[blen])
					blen++;
				blen++;
				if (d + 12 + ((blen + 3) & ~3u) + 2 * 16 + 8 > end)
					return 0;
				put_be32(d, FDT_PROP);
				put_be32(d + 4, blen);
				put_be32(d + 8, name_off[0]);
				d += 12;
				for (uint32_t i = 0; i < ((blen + 3) & ~3u); i++)
					*(volatile uint8_t *)(d + i) = i < blen ? (uint8_t)bootargs[i] : 0;
				d += (blen + 3) & ~3u;
				uint64_t v[2] = { rd_start, rd_end };
				for (int i = 0; i < 2; i++) {
					put_be32(d, FDT_PROP);
					put_be32(d + 4, 8);
					put_be32(d + 8, name_off[1 + i]);
					put_be32(d + 12, (uint32_t)(v[i] >> 32));
					put_be32(d + 16, (uint32_t)v[i]);
					d += 20;
				}
				in_chosen = 0;
			}
			depth--;
			put_be32(d, tok);
			d += 4;
		} else if (tok == FDT_PROP) {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t next = align4(p + 8 + len);
			int skip = 0;
			if (in_chosen)
				for (int i = 0; i < 3; i++)
					skip |= prefix_eq((const char *)(s_strings + nameoff), drop[i]);
			if (!skip) {
				if (d + 4 + (next - p) > end)
					return 0;
				put_be32(d, tok);
				d += 4;
				for (uintptr_t q = p; q < next; q += 4, d += 4)
					*(volatile uint32_t *)d = *(volatile uint32_t *)q;
			}
			p = next;
		} else if (tok == FDT_NOP) {
			continue;
		} else if (tok == FDT_END) {
			put_be32(d, tok);
			d += 4;
			break;
		} else {
			return 0;
		}
	}
	uintptr_t d_strings = d;
	if (d_strings + s_strings_size + extra_strings > end)
		return 0;
	for (uint32_t i = 0; i < s_strings_size; i++)
		*(volatile uint8_t *)(d + i) = *(volatile uint8_t *)(s_strings + i);
	d += s_strings_size;
	for (int i = 0; i < 3; i++)
		for (const char *n = drop[i];; n++) {
			*(volatile uint8_t *)d++ = (uint8_t)*n;
			if (!*n)
				break;
		}
	uint32_t total = (uint32_t)(((d - dst) + 7) & ~7UL);
	put_be32(dst, FDT_MAGIC);
	put_be32(dst + 4, total);
	put_be32(dst + 8, (uint32_t)(d_struct - dst));
	put_be32(dst + 12, (uint32_t)(d_strings - dst));
	put_be32(dst + 16, (uint32_t)(d_rsv - dst));
	put_be32(dst + 20, 17);
	put_be32(dst + 24, 16);
	put_be32(dst + 28, be32(src + 28));
	put_be32(dst + 32, s_strings_size + extra_strings);
	put_be32(dst + 36, (uint32_t)(d_strings - d_struct));
	return total;
}
