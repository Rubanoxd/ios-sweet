/*
 * The Vulkan (Turnip) side of the SweetMetalProbe device: one device per
 * process, buffers in host-visible coherent memory, and one-shot command
 * lists with transfer commands. All calls return 0/NULL on failure and
 * leave the reason in smv_error().
 */
#include <stddef.h>
#include <stdint.h>

typedef struct smv_buffer smv_buffer;
typedef struct smv_cmd smv_cmd;

const char *smv_error(void);

/* Loads the ICD and opens its first device; NAME gets the device name. */
int smv_open(const char *icd, char *name, size_t len);
uint64_t smv_max_buffer_length(void);

smv_buffer *smv_buffer_new(uint64_t length, const void *bytes);
void smv_buffer_free(smv_buffer *b);
void *smv_buffer_contents(smv_buffer *b);
uint64_t smv_buffer_length(smv_buffer *b);

/* A command list in recording state. */
smv_cmd *smv_cmd_new(void);
int smv_cmd_fill(smv_cmd *c, smv_buffer *b, uint64_t offset, uint64_t length, uint8_t value);
int smv_cmd_copy(smv_cmd *c, smv_buffer *src, uint64_t src_offset, smv_buffer *dst, uint64_t dst_offset,
    uint64_t length);
/* Ends, submits and waits (at most TIMEOUT_MS); then the list is spent. */
int smv_cmd_run(smv_cmd *c, uint32_t timeout_ms);
void smv_cmd_free(smv_cmd *c);
