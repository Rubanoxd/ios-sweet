/*
 * Shared by the plugin entry (SweetMetalProbe.m, built without ARC) and the
 * device (SweetMetalDevice.m, ARC).
 */
#import <Foundation/Foundation.h>
#include <stddef.h>

@interface _MTLDevice : NSObject
@end

@interface SweetMetalProbe : _MTLDevice
- (id)initWithAcceleratorPort:(unsigned)port;
@end

#ifdef __cplusplus
extern "C" {
#endif
/* Appends a line to /var/tmp/sweetmetal.log (process, pid, uid). */
void sweet_metal_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int sweet_metal_tracing(void);
#ifdef __cplusplus
}
#endif
#define sweet_metal_trace(...) do { if (sweet_metal_tracing()) sweet_metal_log(__VA_ARGS__); } while (0)

/* Opens Turnip for this process' device; PORT is the accelerator service. */
int sweet_metal_open(unsigned port, char *err, size_t len);
