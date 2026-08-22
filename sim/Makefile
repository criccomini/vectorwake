CC ?= cc
# OPT and CFLAGS are yours to override; the flags the build cannot work
# without live in BASE. A command-line `CFLAGS=...` replaces the variable
# entirely, `+=` in a makefile included, which is how a CI job asking for
# -O0 once lost -Iinclude and -std=c99 along with it.
OPT ?= -O2
CFLAGS ?=
LDFLAGS ?=
FUZZ_CC ?= clang
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

$(B)/check.o: src/check.c include/sim/sim.h | $(B)
	$(CC) $(ALL_CFLAGS) -c src/check.c -o $@

$(B)/libsim.a: $(B)/sim.o $(B)/baseline.o $(B)/pack.o $(B)/check.o
	$(AR) rcs $@ $^

$(B)/replay: tools/replay.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o $(B)/check.o
	$(CC) $(ALL_CFLAGS) $^ $(LDFLAGS) -o $@

$(B)/mapdump: tools/mapdump.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o $(B)/check.o
	$(CC) $(ALL_CFLAGS) $^ $(LDFLAGS) -o $@

$(B)/lvl2vw: tools/lvl2vw.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o $(B)/check.o
	$(CC) $(ALL_CFLAGS) $^ $(LDFLAGS) -o $@

$(B)/mapgen: tools/mapgen.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o $(B)/check.o
	$(CC) $(ALL_CFLAGS) $^ $(LDFLAGS) -o $@

$(B)/test_sim: tests/test_sim.c $(B)/sim.o $(B)/baseline.o $(B)/pack.o $(B)/check.o
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

check: $(B)/test_sim $(B)/replay $(B)/lvl2vw $(B)/mapgen cxx
	$(B)/test_sim
	$(B)/replay tests/trace_basic.txt > $(B)/out.txt
	cmp tests/golden.txt $(B)/out.txt
	@echo determinism check passed
	$(B)/lvl2vw --selftest
	$(B)/mapgen --selftest

# The same sources again, in the dialect the client compiles them in.
#
# client/build.sh copies sim.c, baseline.c and pack.c into the Defold
# extension, and Defold's build server hands every .c in an extension to
# clang++. So these three are C here and C++ there, and a name that is only a
# name in C -- `private`, `class`, `new`, `template` -- builds clean, passes
# every test in this directory, and then fails on somebody else's machine four
# minutes into a bundle. That is exactly how it went: `int private` for the
# owner-only fields reached main, and the first anyone knew was a red client
# build with three parse errors in a file the sim's own checks were happy with.
#
# Syntax only, because the object is not wanted and the C build above is what
# proves the code runs. CXX is whatever this platform calls a C++ compiler; the
# check is skipped rather than failed where there is none, since a machine
# without one can still do everything else here.
cxx:
	@if command -v $(CXX) >/dev/null 2>&1; then \
	  $(CXX) -std=c++11 -Wall -Wextra -Werror -Iinclude -x c++ -fsyntax-only \
	    src/sim.c src/baseline.c src/pack.c src/check.c \
	  && echo "the client's dialect accepts these too"; \
	else \
	  echo "no $(CXX); skipping the C++ dialect check"; \
	fi

# Undefined behavior is a determinism bug in this core specifically.
#
# Everything else here checks that one platform agrees with a committed hash.
# UB is the thing that can make two platforms disagree while both look right
# locally: the compiler is entitled to render it differently at a different
# optimisation level, let alone a different target. So this is not a
# nice-to-have alongside `check`, it is the same property from the other side.
#
# It earned its place: a signed overflow in the recharge clamp shipped to a live
# server and was found by watching a real client's energy bar read INT32_MIN.
# This target reproduces that class of fault in under a second.
#
# -fno-sanitize-recover makes the first finding fatal, so a runtime error cannot
# scroll past in a green build.
ubsan: | $(B)
	$(CC) $(BASE) -O1 -g -fsanitize=undefined,signed-integer-overflow \
	  -fno-sanitize-recover=all \
	  tests/test_sim.c src/sim.c src/baseline.c src/pack.c src/check.c $(LDFLAGS) -lm \
	  -o $(B)/test_sim_ubsan
	$(B)/test_sim_ubsan
	$(CC) $(BASE) -O1 -g -fsanitize=undefined,signed-integer-overflow \
	  -fno-sanitize-recover=all \
	  tools/replay.c src/sim.c src/baseline.c src/pack.c src/check.c $(LDFLAGS) -lm \
	  -o $(B)/replay_ubsan
	$(B)/replay_ubsan tests/trace_basic.txt > $(B)/out-ubsan.txt
	cmp tests/golden.txt $(B)/out-ubsan.txt
	@echo no undefined behavior, and the same hashes under a sanitizer

# Build a libFuzzer entry point for every decoder. Accepted snapshots are
# stepped once, so the target covers the boundary between valid bytes and a
# safe simulation state as well as the parser itself.
fuzz: | $(B)
	$(FUZZ_CC) $(BASE) -O1 -g -fsanitize=fuzzer,address,undefined \
	  -fno-sanitize-recover=all \
	  fuzz/fuzz_unpack.c src/sim.c src/baseline.c src/pack.c src/check.c $(LDFLAGS) -lm \
	  -o $(B)/fuzz_unpack

# Every input that ever crashed replays first, so a fixed bug stays fixed
# whatever the random exploration finds this time. libFuzzer run on files
# executes each one and exits rather than fuzzing.
fuzz-smoke: fuzz
	$(B)/fuzz_unpack fuzz/crashes/*
	$(B)/fuzz_unpack -runs=10000

# WebAssembly build of the harness (requires emsdk). NODERAWFS lets node
# read the trace file directly.
wasm:
	mkdir -p $(B)
	emcc -O2 -std=c99 -Iinclude src/sim.c src/baseline.c src/pack.c src/check.c tools/replay.c \
	  -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 -o $(B)/replay.js

check-wasm: wasm
	node $(B)/replay.js tests/trace_basic.txt > $(B)/out-wasm.txt
	cmp tests/golden.txt $(B)/out-wasm.txt
	@echo wasm determinism check passed

clean:
	rm -rf $(B)

.PHONY: all test golden check cxx ubsan fuzz fuzz-smoke wasm check-wasm sintab clean
