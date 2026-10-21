#pragma once
#include <stdint.h>

void test_ufs(void);
/* Takes over the host's transfer request list (read-only use); 0 on success. */
int ufs_open(void);
/* LUN 0 GPT entry named WANT: first block and size in 4 KiB blocks. */
int ufs_find(const char *want, uint64_t *first, uint64_t *blocks);
/* Reads BYTES from block LBA to physical DST (any address; 8-byte copies). */
int ufs_read(uint64_t lba, uint64_t bytes, uintptr_t dst);
