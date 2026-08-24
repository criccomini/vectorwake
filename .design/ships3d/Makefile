# The mocks. `make` builds the tool, `make renders` redraws the pictures.
#
# Nothing here is part of the game or of any build the game ships. It reads the
# client's hull art and a recording made by `vectorwake-server battlecap`, and
# writes PNGs.

CC      ?= cc
CFLAGS  ?= -O2 -std=c99 -Wall -Wextra
LDLIBS   = -lm -lz
SRC      = main.c hull3d.c arena3d.c battle.c r3.c png.c
CAP     ?= battle.vwcap

mock3d: $(SRC) hulls_data.h r3.h hull3d.h arena3d.h battle.h png.h
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

# The hull geometry, lifted out of client/arena/world.lua. Run this after any
# change to a hull's drawing there.
hulls: hull_export.py
	python3 hull_export.py

# Every hull against the box sim/src/baseline.c collides it in.
check: mock3d
	./mock3d fit

meshes: mock3d
	mkdir -p meshes && ./mock3d obj meshes

.PHONY: hulls check meshes clean
clean:
	rm -f mock3d
