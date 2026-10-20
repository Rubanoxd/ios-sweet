/*
 * The phone's keys, polled over the SPMI arbiter (PMIC arbiter v5), read
 * only, as bsd/dev/sweet_keys.c does in the kernel: power and volume-down
 * are PM6150 PON real-time status bits (PPID 0x008, 0x810 bits 0 and 1),
 * volume-up is PM6150L GPIO2 (PPID 0x4c1, 0xc110 bit 0, active low). The
 * only write is the EXT_READL command on an observer channel. MMU off:
 * everything is Device memory, aligned 32-bit accesses only.
 */
#include <stdint.h>
#include "keys.h"

#define CORE		0x0c440000UL
#define OBS		0x0e600000UL
#define CNFG		0x0c40a000UL
#define PON_RT		0x0810
#define GPIO_RT		0xc110
#define NO_APID		0xffff

static uint16_t pon_apid = NO_APID, gpio_apid = NO_APID;

static uint32_t rd(uintptr_t a)
{
	uint32_t v = *(volatile uint32_t *)a;
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

/* v5 can map one PPID more than once; prefer the apps-owned entry. */
static uint16_t find_apid(uint16_t ppid, uint32_t count)
{
	uint16_t found = NO_APID;
	for (uint32_t i = 0; i < count; i++) {
		uint32_t map = rd(CORE + 0x900 + 4 * i);
		if (map == 0 || ((map >> 8) & 0xfff) != ppid)
			continue;
		if (found == NO_APID || (rd(CNFG + 0x700 + 4 * i) & 7) == 0)
			found = (uint16_t)i;
	}
	return found;
}

static int pmic_read(uint16_t apid, uint16_t addr, uint8_t *out)
{
	if (apid == NO_APID)
		return 0;
	uintptr_t ch = OBS + 0x80UL * apid;
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)ch = (1u << 27) | ((uint32_t)(addr & 0xff) << 4);	/* EXT_READL, 1 byte */
	__asm__ volatile("dsb osh" ::: "memory");
	for (int i = 0; i < 100000; i++) {
		uint32_t st = rd(ch + 0x08);
		if (st & 1) {
			if (st & 0x0e)
				return 0;
			*out = (uint8_t)rd(ch + 0x18);
			return 1;
		}
	}
	return 0;
}

int keys_init(void)
{
	uint32_t version = rd(CORE), count = rd(CORE + 4) & 0x7ff;
	if (version < 0x50000000u || version >= 0x70000000u || count == 0 || count > 512)
		return 0;
	pon_apid = find_apid(0x008, count);
	gpio_apid = find_apid(0x4c1, count);
	/* Volume-up only when firmware left GPIO2 enabled as an input. */
	uint8_t mode = 0, en = 0, subtype = 0;
	if (!pmic_read(gpio_apid, 0xc140, &mode) || !pmic_read(gpio_apid, 0xc146, &en) ||
	    !pmic_read(gpio_apid, 0xc105, &subtype)) {
		gpio_apid = NO_APID;
	} else {
		unsigned dir = subtype >= 0x10 && subtype <= 0x13 ? mode & 3 : (mode >> 4) & 7;
		if (!(en & 0x80) || (dir != 0 && dir != 2))
			gpio_apid = NO_APID;
	}
	return pon_apid != NO_APID;
}

unsigned keys_read(void)
{
	unsigned k = 0;
	uint8_t pon = 0, gpio = 0;
	if (pmic_read(pon_apid, PON_RT, &pon)) {
		if (pon & 1)
			k |= KEY_POWER;
		if (pon & 2)
			k |= KEY_VOLDOWN;
	}
	if (pmic_read(gpio_apid, GPIO_RT, &gpio) && !(gpio & 1))
		k |= KEY_VOLUP;
	return k;
}

int keys_have_volup(void)
{
	return gpio_apid != NO_APID;
}
