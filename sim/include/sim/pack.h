/* Snapshot serialization. See src/pack.c. */
#ifndef SIM_PACK_H
#define SIM_PACK_H

#include "sim/sim.h"

/* Largest snapshot a full arena can produce. */
#define SIM_PACK_MAX (64 * 1024)

/* Write s into out. Returns bytes written, or -1 if cap was too small. */
int sim_pack(const sim_state *s, uint8_t *out, int cap);

/* Read a snapshot into s. Returns 0, or -1 on malformed input. */
int sim_unpack(sim_state *s, const uint8_t *in, int len);

#endif
