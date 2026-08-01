CC ?= cc
# OPT and CFLAGS are yours to override; the flags the build cannot work
# without live in BASE. A command-line `CFLAGS=...` replaces the variable
# entirely, `+=` in a makefile included, which is how a CI job asking for
# -O0 once lost -Iinclude and -std=c99 along with it.
OPT ?= -O2
CFLAGS ?=
LDFLAGS ?=
BASE := -std=c99 -Wall -Wextra -Werror -Iinclude
ALL_CFLAGS = $(BASE) $(OPT) $(CFLAGS)
B := build

all: $(B)/libsim.a $(B)/replay $(B)/test_sim

$(B):
	mkdir -p $(B)

$(B)/sim.o: src/sim.c src/sintab.h include/sim/sim.h | $(B)
	$(CC) $(ALL_CFLAGS) -c src/sim.c -o $@

$(B)/baseline.o: src/baseline.c include/sim/baseline.h include/sim/sim.h | $(B)
	$(CC) $(ALL_CFLAGS) -c src/baseline.c -o $@

$(B)/pack.o: src/pack.c include/sim/pack.h include/sim/sim.h | $(B)
	$(CC) $(ALL_CFLAGS) -c src/pack.c -o $@

$(B)/libsim.a: $(B)/sim.o $(B)/baseline.o $(B)/pack.o
	$(AR) rcs $@ $^

$(B)/replay: tools/replay.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o
	$(CC) $(ALL_CFLAGS) $^ $(LDFLAGS) -o $@

$(B)/test_sim: tests/test_sim.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o
	$(CC) $(ALL_CFLAGS) $^ $(LDFLAGS) -o $@

# Regenerate the committed sine table. Deliberately not a file rule: a fresh
# checkout gives every file the same timestamp, so a rule would let make decide
# to rebuild the table on a machine that has no libm, or before build/ exists.
# The table is committed; run this only when changing the generator.
sintab: | $(B)
	$(CC) -O2 -std=c99 -o $(B)/gen_sintab tools/gen_sintab.c -lm
	$(B)/gen_sintab > src/sintab.h

test: $(B)/test_sim
	$(B)/test_sim

# Golden hashes: the committed reference output for the committed trace.
# `make golden` regenerates it (only after a deliberate sim change);
# `make check` fails if this platform's output differs by one byte.
golden: $(B)/replay
	$(B)/replay tests/trace_basic.txt > tests/golden.txt

check: $(B)/test_sim $(B)/replay
	$(B)/test_sim
	$(B)/replay tests/trace_basic.txt > $(B)/out.txt
	cmp tests/golden.txt $(B)/out.txt
	@echo determinism check passed

# WebAssembly build of the harness (requires emsdk). NODERAWFS lets node
# read the trace file directly.
wasm:
	mkdir -p $(B)
	emcc -O2 -std=c99 -Iinclude src/sim.c src/baseline.c src/pack.c tools/replay.c \
	  -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 -o $(B)/replay.js

check-wasm: wasm
	node $(B)/replay.js tests/trace_basic.txt > $(B)/out-wasm.txt
	cmp tests/golden.txt $(B)/out-wasm.txt
	@echo wasm determinism check passed

clean:
	rm -rf $(B)

.PHONY: all test golden check wasm check-wasm sintab clean
