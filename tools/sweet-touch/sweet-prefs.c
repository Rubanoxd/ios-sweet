/*
 * sweet-prefs: read or set a preference through cfprefsd (there is no `defaults` on the phone).
 *   sweet-prefs DOMAIN KEY            prints the value
 *   sweet-prefs DOMAIN KEY bool|int|string VALUE
 * Run it as the user the domain belongs to (sudo -u mobile ... for com.apple.springboard).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: sweet-prefs DOMAIN KEY [bool|int|string VALUE]\n");
		return 2;
	}
	CFStringRef dom = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
	CFStringRef key = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
	if (argc >= 5) {
		CFPropertyListRef v = NULL;
		if (!strcmp(argv[3], "bool")) {
			v = (!strcmp(argv[4], "1") || !strcasecmp(argv[4], "yes") || !strcasecmp(argv[4], "true")) ? kCFBooleanTrue : kCFBooleanFalse;
		} else if (!strcmp(argv[3], "int")) {
			long long n = atoll(argv[4]);
			v = CFNumberCreate(NULL, kCFNumberLongLongType, &n);
		} else {
			v = CFStringCreateWithCString(NULL, argv[4], kCFStringEncodingUTF8);
		}
		CFPreferencesSetValue(key, v, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		CFPreferencesSynchronize(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	}
	CFPropertyListRef cur = CFPreferencesCopyValue(key, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (cur) {
		CFShow(cur);
	} else {
		printf("(unset)\n");
	}
	return 0;
}
