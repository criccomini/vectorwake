# Host builds of the client's C, for looking at it outside a browser.
#
# The synth is the client's own, compiled here as C rather than as the C++ that
# Defold's build server makes of it. Both dialects have to keep working, and
# building it this way is what catches the drift.

CFLAGS ?= -O2 -Wall -Wextra -std=c99
LDLIBS ?= -lm

sfx: sfxdump

sfxdump: sfxdump.c ../ext/simcore/src/sfx.c ../ext/simcore/src/sfx.h
	$(CC) $(CFLAGS) -o $@ sfxdump.c ../ext/simcore/src/sfx.c $(LDLIBS)

clean:
	rm -f sfxdump

.PHONY: sfx clean
