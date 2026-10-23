/*
 * sweet-touch: synthetic touches on the iOS screen from a shell, for testing without hands.
 *
 *   sweet-touch tap X Y                     (X, Y from 0 to 1 of the screen, portrait)
 *   sweet-touch swipe X0 Y0 X1 Y1 [MS]      (default 300 ms)
 *   sweet-touch hold X Y MS
 *
 * Digitizer events (a hand with one finger, display-integrated) are dispatched through an
 * IOHIDEventSystemClient into backboardd, the way WebKit's HIDEventGenerator does it, with the
 * sender ID of the kernel's SweetHIDTouch service.
 */
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include <sys/sysctl.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t transducer, uint32_t index,
    uint32_t identity, uint32_t eventMask, uint32_t buttonMask, double x, double y, double z, double tipPressure,
    double barrelPressure, Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t index, uint32_t identity,
    uint32_t eventMask, double x, double y, double z, double tipPressure, double twist, Boolean range, Boolean touch,
    uint32_t options);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, long value);
extern void IOHIDEventSetIntegerValueWithOptions(IOHIDEventRef, uint32_t field, long value, uint32_t options);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t field, double value);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t, uint32_t page, uint32_t usage, Boolean down, uint32_t flags);

#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDDigitizerEventRange 0x1
#define kIOHIDDigitizerEventTouch 0x2
#define kIOHIDDigitizerEventPosition 0x4
#define kIOHIDDigitizerEventFromEdgeTip 0x800
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xB0019     /* (kIOHIDEventTypeDigitizer << 16) | 25 */
#define kIOHIDEventFieldDigitizerCollection 0xB0016
#define kIOHIDDigitizerEventIdentity 0x20
#define kIOHIDEventFieldDigitizerMajorRadius 0xB0014
#define kIOHIDEventFieldDigitizerMinorRadius 0xB0015

static IOHIDEventSystemClientRef client;
static uint64_t sender = 0x000000010000027FULL;
static uint32_t edge;
static double sx = 1, sy = 1;  /* SWEET_TOUCH_UNITS=points: send 375x812 points instead of 0..1 */  /* FromEdgeTip for a stroke that starts at an edge, as the kernel driver does */

/*
 * One report, built as the kernel's SweetHIDTouch::touch() builds it: a hand collection
 * (Collection=1, the finger's position, Range/Touch, ButtonMask, the finger's mask) with one
 * finger child (index 0, identity 2; Identity in the mask when it lands).
 */
/* xnu 0108: kern.sweet_touch takes a touch through the real driver path (panel pixels 1080x2400). */
static int kernelTouch = -1;
static bool sendKernel(double x, double y, int touching)
{
	if (kernelTouch < 0) {
		int v = 0;
		size_t len = sizeof(v);
		kernelTouch = sysctlbyname("kern.sweet_touch", &v, &len, NULL, 0) == 0 && !getenv("SWEET_TOUCH_HID");
	}
	if (!kernelTouch) {
		return false;
	}
	int px = (int)(x * 1079 + 0.5), py = (int)(y * 2399 + 0.5);
	px = px < 0 ? 0 : (px > 1079 ? 1079 : px);
	py = py < 0 ? 0 : (py > 2399 ? 2399 : py);
	int v = (touching ? 1 << 24 : 0) | (px << 12) | py;
	return sysctlbyname("kern.sweet_touch", NULL, NULL, &v, sizeof(v)) == 0;
}

static void send(double x, double y, int touching, uint32_t mask)
{
	if (sendKernel(x, y, touching)) {
		return;
	}
	uint64_t t = mach_absolute_time();
	x *= sx;
	y *= sy;
	mask |= edge;
	IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, t, kIOHIDDigitizerTransducerTypeHand,
	    0, 0, mask, touching ? 1 : 0, x, y, 0, 0, 0, touching, touching, 0);
	IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerCollection, 1);
	if (getenv("SWEET_TOUCH_DI")) {
		IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1, 0xf0000000);
	}
	IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, t, 0, 2, mask, x, y, 0,
	    touching ? 1 : 0, 0, touching, touching, 0);
	IOHIDEventAppendEvent(hand, finger, 0);
	IOHIDEventSetSenderID(hand, sender);
	IOHIDEventSystemClientDispatchEvent(client, hand);
	CFRelease(finger);
	CFRelease(hand);
}

static uint64_t service_id(const char *cls)
{
	uint64_t id = 0;
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls));
	if (svc) {
		IORegistryEntryGetRegistryEntryID(svc, &id);
		IOObjectRelease(svc);
	}
	return id;
}

/* xnu 0108: kern.sweet_key, the real buttons' path (0 power, 1 vol+, 2 vol-, 3 home). */
static bool keyKernel(uint32_t usage)
{
	int k = usage == 0x30 ? 0 : usage == 0xe9 ? 1 : usage == 0xea ? 2 : usage == 0x40 ? 3 : -1;
	if (k < 0 || getenv("SWEET_TOUCH_HID")) {
		return false;
	}
	for (int down = 1; down >= 0; down--) {
		int v = (k << 1) | down;
		if (sysctlbyname("kern.sweet_key", NULL, NULL, &v, sizeof(v)) != 0) {
			return false;
		}
		usleep(80000);
	}
	return true;
}

/* A consumer-page button (0x30 power, 0x40 menu/home, 0xe9 volume up, 0xea volume down) as SweetHIDButtons. */
static void key(uint32_t usage)
{
	if (keyKernel(usage)) {
		return;
	}
	uint64_t id = service_id("SweetHIDButtons");
	for (int down = 1; down >= 0; down--) {
		IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), 0x0c, usage, down, 0);
		if (id) {
			IOHIDEventSetSenderID(e, id);
		}
		IOHIDEventSystemClientDispatchEvent(client, e);
		CFRelease(e);
		usleep(80000);
	}
}

static void stroke(double x0, double y0, double x1, double y1, int ms)
{
	int steps = ms / 8 < 2 ? 2 : ms / 8;
	edge = (x0 < 0.04 || x0 > 0.96 || y0 < 0.02 || y0 > 0.98) ? kIOHIDDigitizerEventFromEdgeTip : 0;
	send(x0, y0, 1, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);
	for (int i = 1; i <= steps; i++) {
		usleep(8000);
		double f = (double)i / steps;
		send(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, 1, kIOHIDDigitizerEventPosition);
	}
	usleep(8000);
	send(x1, y1, 0, kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		/* Events carry the sender ID of the kernel's touch service, so backboardd treats them as its own. */
		io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("SweetHIDTouch"));
		if (getenv("SWEET_TOUCH_SENDER")) {
			sender = strtoull(getenv("SWEET_TOUCH_SENDER"), NULL, 0);
		} else if (svc) {
			IORegistryEntryGetRegistryEntryID(svc, &sender);
			IOObjectRelease(svc);
		}
		const char *units = getenv("SWEET_TOUCH_UNITS");
		if (units && !strcmp(units, "points")) {
			sx = 375;
			sy = 812;
		} else if (units && !strcmp(units, "pixels")) {
			sx = 1125;
			sy = 2436;
		}
		client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
		if (!client) {
			fprintf(stderr, "no IOHIDEventSystemClient\n");
			return 1;
		}
		if (argc >= 4 && !strcmp(argv[1], "tap")) {
			double x = atof(argv[2]), y = atof(argv[3]);
			stroke(x, y, x, y, 60);
		} else if (argc >= 6 && !strcmp(argv[1], "swipe")) {
			stroke(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]), argc > 6 ? atoi(argv[6]) : 300);
		} else if (argc >= 5 && !strcmp(argv[1], "hold")) {
			double x = atof(argv[2]), y = atof(argv[3]);
			stroke(x, y, x, y, atoi(argv[4]));
		} else if (argc >= 3 && !strcmp(argv[1], "key")) {
			key((uint32_t)strtoul(argv[2], NULL, 0));
		} else {
			fprintf(stderr, "usage: sweet-touch tap X Y | swipe X0 Y0 X1 Y1 [MS] | hold X Y MS | key USAGE\n");
			return 2;
		}
		usleep(50000);
	}
	return 0;
}
