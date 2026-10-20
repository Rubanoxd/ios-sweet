#pragma once

#define KEY_POWER	1u
#define KEY_VOLUP	2u
#define KEY_VOLDOWN	4u

/* Finds the PMIC channels; 0 if the SPMI arbiter or the PON block is missing. */
int keys_init(void);
/* KEY_* bits of the keys held now. */
unsigned keys_read(void);
int keys_have_volup(void);
