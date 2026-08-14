# Host builds of the client's C, for looking at it outside a browser.
#
# The synth is the client's own, compiled here as C rather than as the C++ that
# Defold's build server makes of it. Both dialects have to keep working, and
# building it this way is what catches the drift.

CFLAGS ?= -O2 -Wall -Wextra -std=c99
CXXFLAGS ?= -O2 -Wall -Wextra -Werror -std=c++11
LDLIBS ?= -lm

sfx: sfxdump

sfxdump: sfxdump.c ../ext/simcore/src/sfx.c ../ext/simcore/src/sfx.h
	$(CC) $(CFLAGS) -o $@ sfxdump.c ../ext/simcore/src/sfx.c $(LDLIBS)

sfxladder: sfxladder.c ../ext/simcore/src/sfx.c ../ext/simcore/src/sfx.h
	$(CC) $(CFLAGS) -o $@ sfxladder.c ../ext/simcore/src/sfx.c $(LDLIBS)

# Native behavior the Lua tests cannot reach: the synth's rendered samples and
# the extension's correction envelope.
smoothcheck: smoothing_test.cpp ../ext/simcore/src/smoothing.h
	$(CXX) $(CXXFLAGS) -o $@ smoothing_test.cpp $(LDLIBS)

check: sfxladder smoothcheck
	./sfxladder
	./smoothcheck

clean:
	rm -f sfxdump sfxladder smoothcheck

.PHONY: sfx check clean
