/* Snapshot serialization. See src/pack.c. */
#ifndef SIM_PACK_H
#define SIM_PACK_H

#include "sim/sim.h"
#ifdef __cplusplus
extern "C" {
#endif


/* Largest owner-filtered network snapshot. */
#define SIM_PACK_MAX (64 * 1024)

/* Largest whole-state snapshot. Every visible ship carries its private tail,
 * so this is slightly larger than the network limit.
 *
 * It came down when ships stopped carrying a kit, and came part of the way
 * back when they carried one again. What a ship sends now is the slots its
 * pilot actually spent, one byte each, which seven credits caps at eight;
 * the twenty-three byte vector this used to be would not have fitted the
 * buffer at all. See the build in `sim_pack`.
 *
 * Greens add SIM_MAX_GREENS * 11 + 1 on top, which is 705 bytes for a room
 * running the full field. */
#define SIM_STATE_PACK_MAX 63588

/* A network snapshot carries one owner-only ship tail. The whole-state
 * replay path and trusted house bots ask for every tail instead.
 *
 * There used to be a second flag for server-private randomness, because the
 * prize stream was a decision the server made and the client was not allowed
 * to predict. Greens are back and it is still not needed: what a green grants
 * is decided when it is put out and travels in the snapshot with it, so a
 * client reading one is reading a fact rather than guessing a roll. */
#define SIM_PACK_PRIVATE_ALL 0x01u

/* Write s into out. SIM_STATE_PACK_MAX bytes always suffice. Returns bytes
 * written, or -1 if cap was too small. */
int sim_pack(const sim_state *s, uint8_t *out, int cap);

/* The same snapshot, carrying only what is within `radius` of a point.
 *
 * A client can act only on the ships and rounds inside its radar. Sending the
 * rest is bytes for something it has no way to see, and a snapshot that named
 * every hull on the map would make a maphack a rendering choice rather than an
 * exploit.
 *
 * Flags still travel whole, since a scoreboard names them all.
 *
 * Safe because an unpack replaces the state outright, so nothing goes stale,
 * and because a radius is chosen far enough out that no ship can cross into
 * the gap between one snapshot and the next. Prediction is unaffected: a
 * client steps the same core between authoritative replacements.
 *
 * Rounds are filtered by distance alone. Every round in the game is spent
 * within seconds and near the hull that fired it, so the radius is the only
 * rule they ever meet; a weapon left behind for a pilot to fly back to would
 * need an exception, and there is no longer one in the game.
 *
 * Energy and its capacity rung travel in every visible ship record because
 * together they are the public health bar. `owner` is the only ship whose
 * other upgrades, inventory, cooldowns and owner-only state travel, and it is
 * a seat rather than the camera because a spectator may borrow a pilot's
 * camera without becoming that pilot.
 * `SIM_PACK_PRIVATE_ALL` is reserved for trusted whole-room consumers.
 *
 * A negative radius means everything, which is what `sim_pack` passes.
 * SIM_PACK_MAX bytes suffice for the network shape with no private-all
 * option; SIM_STATE_PACK_MAX bytes suffice for every option. */
int sim_pack_around(const sim_state *s, uint8_t *out, int cap,
                    int32_t cx, int32_t cy, int32_t radius,
                    uint8_t owner, uint8_t options);

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
 * a two-byte count, so the ceiling is three bytes per tile plus the 14-byte
 * header. Real maps are far smaller. */
#define SIM_MAP_PACK_MAX (SIM_MAP_TILES * SIM_MAP_TILES * 3 + 14)

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
