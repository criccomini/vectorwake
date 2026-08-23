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

# Where a round is drawn, against the core that flew it. The simulation is
# built here as C++ for the same reason the extension gets it that way: Defold
# hands every .c in an extension to clang++, so this is the dialect the client
# actually runs.
SIMSRC := ../../sim/src/sim.c ../../sim/src/baseline.c ../../sim/src/pack.c \
          ../../sim/src/check.c

flightcheck: flight_test.cpp ../ext/simcore/src/flight.h $(SIMSRC)
	$(CXX) $(CXXFLAGS) -I../../sim/include -x c++ -o $@ flight_test.cpp \
	  $(SIMSRC) $(LDLIBS)

check: sfxladder smoothcheck flightcheck
	./sfxladder
	./smoothcheck
	./flightcheck

clean:
	rm -f sfxdump sfxladder smoothcheck flightcheck

.PHONY: sfx check clean
