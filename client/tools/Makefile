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

sfxladder: sfxladder.c ../ext/simcore/src/sfx.c ../ext/simcore/src/sfx.h
	$(CC) $(CFLAGS) -o $@ sfxladder.c ../ext/simcore/src/sfx.c $(LDLIBS)

# Whether a pilot can hear which rung fired. The client's Lua tests cannot
# reach this: the kit is C, and what it renders is the only honest evidence
# about what it sounds like.
check: sfxladder
	./sfxladder

clean:
	rm -f sfxdump sfxladder

.PHONY: sfx check clean
