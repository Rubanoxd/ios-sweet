/*
 * sweet-netconfig: tells configd about the phone's USB Ethernet (ue0), which
 * the kernel creates outside IOKit, so neither InterfaceNamer nor
 * addNetworkInterface ever see it. It publishes a service in the dynamic
 * store, the way a VPN or PPP controller does:
 *   State:/Network/Service/sweet-usb/IPv4  Addresses, SubnetMasks, Router,
 *                                          InterfaceName
 *   State:/Network/Service/sweet-usb/DNS   ServerAddresses
 * IPMonitor then makes it primary (default route, reachability) and hands
 * the DNS servers to mDNSResponder. Run as root (configd grants root write
 * access); the keys live until configd restarts.
 *
 *   sweet-netconfig [ROUTER [DNS ...]]     default 192.168.7.1 1.1.1.1 8.8.8.8
 *   sweet-netconfig -d                     remove the service
 *
 * Built without an iOS SDK (tools/sweet-netconfig/build.sh): CoreFoundation
 * and SystemConfiguration are reached through dlopen/dlsym.
 */
typedef const void *CFTypeRef;
typedef unsigned char Boolean;
typedef long CFIndex;
typedef unsigned int CFStringEncoding;

extern void *dlopen(const char *path, int mode);
extern void *dlsym(void *handle, const char *symbol);
extern char *dlerror(void);
extern int printf(const char *fmt, ...);
extern int strcmp(const char *a, const char *b);

#define RTLD_NOW 0x2
#define kCFStringEncodingUTF8 0x08000100u

static CFTypeRef (*CFStringCreateWithCString)(CFTypeRef, const char *, CFStringEncoding);
static CFTypeRef (*CFArrayCreate)(CFTypeRef, const void **, CFIndex, const void *);
static CFTypeRef (*CFDictionaryCreate)(CFTypeRef, const void **, const void **, CFIndex,
    const void *, const void *);
static void (*CFRelease)(CFTypeRef);
static void (*CFShow)(CFTypeRef);
static const void *kCFTypeArrayCallBacks, *kCFTypeDictionaryKeyCallBacks,
    *kCFTypeDictionaryValueCallBacks;
static CFTypeRef (*SCDynamicStoreCreate)(CFTypeRef, CFTypeRef, void *, void *);
static Boolean (*SCDynamicStoreSetValue)(CFTypeRef, CFTypeRef, CFTypeRef);
static Boolean (*SCDynamicStoreRemoveValue)(CFTypeRef, CFTypeRef);
static CFTypeRef (*SCDynamicStoreCopyValue)(CFTypeRef, CFTypeRef);
static int (*SCError)(void);
static const char *(*SCErrorString)(int);

static void *
sym(void *lib, const char *name)
{
	void *p = dlsym(lib, name);
	if (!p) {
		printf("sweet-netconfig: missing %s\n", name);
	}
	return p;
}

static int
load(void)
{
	void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
	void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	if (!cf || !sc) {
		printf("sweet-netconfig: dlopen: %s\n", dlerror());
		return -1;
	}
	CFStringCreateWithCString = sym(cf, "CFStringCreateWithCString");
	CFArrayCreate = sym(cf, "CFArrayCreate");
	CFDictionaryCreate = sym(cf, "CFDictionaryCreate");
	CFRelease = sym(cf, "CFRelease");
	CFShow = sym(cf, "CFShow");
	kCFTypeArrayCallBacks = sym(cf, "kCFTypeArrayCallBacks");
	kCFTypeDictionaryKeyCallBacks = sym(cf, "kCFTypeDictionaryKeyCallBacks");
	kCFTypeDictionaryValueCallBacks = sym(cf, "kCFTypeDictionaryValueCallBacks");
	SCDynamicStoreCreate = sym(sc, "SCDynamicStoreCreate");
	SCDynamicStoreSetValue = sym(sc, "SCDynamicStoreSetValue");
	SCDynamicStoreRemoveValue = sym(sc, "SCDynamicStoreRemoveValue");
	SCDynamicStoreCopyValue = sym(sc, "SCDynamicStoreCopyValue");
	SCError = sym(sc, "SCError");
	SCErrorString = sym(sc, "SCErrorString");
	if (!CFStringCreateWithCString || !CFArrayCreate || !CFDictionaryCreate || !CFRelease ||
	    !CFShow || !kCFTypeArrayCallBacks || !kCFTypeDictionaryKeyCallBacks ||
	    !kCFTypeDictionaryValueCallBacks || !SCDynamicStoreCreate || !SCDynamicStoreSetValue ||
	    !SCDynamicStoreRemoveValue || !SCDynamicStoreCopyValue || !SCError || !SCErrorString) {
		return -1;
	}
	return 0;
}

static CFTypeRef
str(const char *s)
{
	return CFStringCreateWithCString(0, s, kCFStringEncodingUTF8);
}

static CFTypeRef
strs(const char **v, int n)
{
	const void *items[8];
	for (int i = 0; i < n && i < 8; ++i) {
		items[i] = str(v[i]);
	}
	return CFArrayCreate(0, items, n < 8 ? n : 8, kCFTypeArrayCallBacks);
}

static int
put(CFTypeRef store, const char *key, const void **keys, const void **vals, int n)
{
	CFTypeRef k = str(key);
	CFTypeRef d = CFDictionaryCreate(0, keys, vals, n, kCFTypeDictionaryKeyCallBacks,
	    kCFTypeDictionaryValueCallBacks);
	if (!SCDynamicStoreSetValue(store, k, d)) {
		printf("sweet-netconfig: set %s: %s\n", key, SCErrorString(SCError()));
		return -1;
	}
	return 0;
}

int
main(int argc, const char **argv)
{
	const char *router = "192.168.7.1";
	const char *dns_default[] = { "1.1.1.1", "8.8.8.8" };
	const char **dns = dns_default;
	int ndns = 2;
	if (load()) {
		return 1;
	}
	CFTypeRef store = SCDynamicStoreCreate(0, str("sweet-netconfig"), 0, 0);
	if (!store) {
		printf("sweet-netconfig: no dynamic store: %s\n", SCErrorString(SCError()));
		return 1;
	}
	if (argc > 1 && !strcmp(argv[1], "-d")) {
		SCDynamicStoreRemoveValue(store, str("State:/Network/Service/sweet-usb/IPv4"));
		SCDynamicStoreRemoveValue(store, str("State:/Network/Service/sweet-usb/DNS"));
		printf("sweet-netconfig: service removed\n");
		return 0;
	}
	if (argc > 1) {
		router = argv[1];
	}
	if (argc > 2) {
		dns = argv + 2;
		ndns = argc - 2;
	}
	const char *addr[] = { "192.168.7.2" }, *mask[] = { "255.255.255.0" };
	const void *ik[] = { str("Addresses"), str("SubnetMasks"), str("Router"), str("InterfaceName") };
	const void *iv[] = { strs(addr, 1), strs(mask, 1), str(router), str("ue0") };
	const void *dk[] = { str("ServerAddresses") };
	const void *dv[] = { strs(dns, ndns) };
	if (put(store, "State:/Network/Service/sweet-usb/IPv4", ik, iv, 4) ||
	    put(store, "State:/Network/Service/sweet-usb/DNS", dk, dv, 1)) {
		return 1;
	}
	CFTypeRef g = SCDynamicStoreCopyValue(store, str("State:/Network/Global/IPv4"));
	printf("sweet-netconfig: ue0 via %s; State:/Network/Global/IPv4 is now:\n", router);
	if (g) {
		CFShow(g);
	}
	return 0;
}
