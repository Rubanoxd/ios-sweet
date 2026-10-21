#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);
/* Copy a string property of /chosen into OUT (MAX bytes with the NUL). Returns 0 if absent. */
int fdt_chosen_str(uintptr_t fdt, const char *prop, char *out, unsigned max);
/* Copy the FDT at SRC to DST with /chosen bootargs and linux,initrd-start/end
 * replaced; returns the new total size or 0. */
uint32_t fdt_rewrite_chosen(uintptr_t src, uintptr_t dst, uint32_t max, const char *bootargs,
    uint64_t rd_start, uint64_t rd_end);
