# The probe is a shim over the real simulation core, so a harness written in
# another language checks snapshots with the same code the game does. Nothing
# here reimplements the wire format, which is the whole point: a harness with
# its own decoder tests its own decoder.
CC ?= cc
SIM := ../../sim
CFLAGS ?= -O2 -fPIC -Wall -Wextra
all: libvwprobe.so

libvwprobe.so: probe.c $(SIM)/src/sim.c $(SIM)/src/baseline.c $(SIM)/src/pack.c
	$(CC) $(CFLAGS) -shared -I$(SIM)/include -I$(SIM)/src -o $@ $^ -lm

clean:
	rm -f libvwprobe.so
.PHONY: all clean
