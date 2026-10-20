#pragma once

/* Shows the boot menu; returns 0 for iOS, 1 for Android (only if ANDROID_OK). */
int menu_choose(int android_ok, unsigned timeout_s);
