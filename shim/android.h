#pragma once
#include <stdint.h>

/* 1 if "recoverybak" holds a header-v2 Android boot image the shim can start. */
int android_probe(void);
/* Starts it with ABL's FDT rewritten for it; returns only on error. */
const char *android_boot(uintptr_t abl_fdt);
