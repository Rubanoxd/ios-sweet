#pragma once

/* Shows the boot menu; returns 0 for iOS, 1 for Android (checked by android_probe). */
int menu_choose(unsigned timeout_s);
