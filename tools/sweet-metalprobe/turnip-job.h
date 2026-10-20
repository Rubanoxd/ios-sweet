#include <stddef.h>

/* Runs one Turnip compute job and checks it; returns 1 when the GPU wrote
 * every word right. MSG gets a one-line summary or the failing call. */
int sweet_turnip_job(const char *icd, char *msg, size_t len);
