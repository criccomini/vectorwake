/* Snapshot serialization. See src/pack.c. */
#ifndef SIM_PACK_H
#define SIM_PACK_H

#include "sim/sim.h"
#ifdef __cplusplus
extern "C" {
#endif


/* Largest snapshot a full arena can produce. */
#define SIM_PACK_MAX (64 * 1024)

/* Write s into out. Returns bytes written, or -1 if cap was too small. */
int sim_pack(const sim_state *s, uint8_t *out, int cap);

/* The same snapshot, carrying only the prizes within `radius` of a point.
 *
 * Prizes are most of a snapshot -- two hundred of them outweigh the ships and
 * every projectile in the air together -- and a client can only ever see the
 * handful inside its radar, sixty tiles out. Sending it the rest is bytes for
 * something it has no way to look at.
 *
 * Everything else still travels whole. Ships, weapons and flags are few and
 * all of them matter: a scoreboard names every pilot in the arena and a
 * client that was not told about a ship could not draw its name.
 *
 * Safe because an unpack replaces the state outright, so nothing goes stale,
 * and because a radius is chosen far enough out that no ship can cross into
 * the gap between one snapshot and the next. Prediction is unaffected: a
 * client steps the same core off the same rng and reaches the same prizes
 * inside the radius it was told about.
 *
 * A negative radius means everything, which is what `sim_pack` passes. */
int sim_pack_around(const sim_state *s, uint8_t *out, int cap,
                    int32_t cx, int32_t cy, int32_t radius);

/* Read a snapshot into s. Returns 0, or -1 on malformed input. */
int sim_unpack(sim_state *s, const uint8_t *in, int len);

/* ---- settings -----------------------------------------------------------
 *
 * A zone's tuning, including its whole weapon table. A client predicts by
 * stepping the core, so it has to be stepping the server's numbers rather
 * than the ones it happened to compile. */

/* Every table full, plus a header. Around three kilobytes; sent once at join
 * and again whenever an operator reloads the zone file. */
#define SIM_SETTINGS_PACK_MAX 8192

/* Write cfg into out. Returns bytes written, or -1 if cap was too small. */
int sim_settings_pack(const sim_settings *cfg, uint8_t *out, int cap);

/* Read settings into cfg. Returns 0, or -1 on malformed input. `cfg->map` is
 * left exactly as it was: geometry travels as a map, and arrives first. */
int sim_settings_unpack(sim_settings *cfg, const uint8_t *in, int len);

/* ---- maps ---------------------------------------------------------------
 *
 * A map is a megabyte of tiles that is almost all one value, so it travels
 * run-length encoded. The encoding lives here rather than in the server
 * because the client has to decode it identically or it predicts collisions
 * against a different room -- the same reason snapshots are packed here.
 *
 * The header carries a hash of the tiles. A client that decodes a map and
 * gets a different hash has a different map, and would rather know than
 * spend a match wondering why it keeps hitting nothing. */

/* Worst case: a map that alternates every tile. Runs are (count, value) with
 * a two-byte count, so the ceiling is three bytes per two tiles plus the
 * header, and a real map is a few hundred bytes. */
#define SIM_MAP_PACK_MAX (SIM_MAP_TILES * SIM_MAP_TILES * 3 / 2 + 32)

/* FNV-1a over the tile array. The wire and both ends agree on this or the
 * map is not the same map. */
uint32_t sim_map_hash(const sim_map *m);

/* Write m into out. Returns bytes written, or -1 if cap was too small. */
int sim_map_pack(const sim_map *m, uint8_t *out, int cap);

/* Read a map from in, index it, and check its hash. Returns 0, -1 on
 * malformed input, -2 if the tiles do not hash to what the header claims. */
int sim_map_unpack(sim_map *m, const uint8_t *in, int len);

#ifdef __cplusplus
}
#endif

#endif
