/* Snapshot serialization.
 *
 * Written in the core, not in the server or the client, so there is exactly
 * one definition of what a snapshot is. The server packs, the client
 * unpacks, and neither can drift from the other.
 *
 * Every field is written byte by byte in little-endian order, so the format
 * does not depend on struct layout, alignment, or host endianness: an x86-64
 * server and a WebAssembly client agree by construction.
 *
 * Only live entities are sent. A quiet arena costs a few hundred bytes.
 */
#include "sim/pack.h"

#include <string.h>

typedef struct {
    uint8_t *p;
    const uint8_t *end;
    int overflow;
} wr;

typedef struct {
    const uint8_t *p;
    const uint8_t *end;
    int underflow;
} rd;

static void w8(wr *w, uint32_t v) {
    if (w->p + 1 > w->end) { w->overflow = 1; return; }
    *w->p++ = (uint8_t)v;
}
static void w16(wr *w, uint32_t v) { w8(w, v); w8(w, v >> 8); }
static void w32(wr *w, uint32_t v) { w16(w, v); w16(w, v >> 16); }

static uint32_t r8(rd *r) {
    if (r->p + 1 > r->end) { r->underflow = 1; return 0; }
    return *r->p++;
}
static uint32_t r16(rd *r) { uint32_t a = r8(r); return a | (r8(r) << 8); }
static uint32_t r32(rd *r) { uint32_t a = r16(r); return a | (r16(r) << 16); }

/* Is this point inside the interest radius? A negative radius is "everything",
 * which keeps `sim_pack` and the replay tool packing whole states. */
static int within(int32_t x, int32_t y, int32_t cx, int32_t cy,
                  int32_t radius, int64_t r2) {
    if (radius < 0) return 1;
    int64_t dx = (int64_t)x - cx, dy = (int64_t)y - cy;
    return dx * dx + dy * dy <= r2;
}

static int world_point(int32_t x, int32_t y) {
    return x >= 0 && y >= 0 && x < SIM_MAP_MAX_Q8 && y < SIM_MAP_MAX_Q8;
}

static int world_velocity(int32_t v) {
    const int32_t bound = SIM_MAP_MAX_Q8 * 256;
    return v >= -bound && v <= bound;
}

int sim_pack(const sim_state *s, uint8_t *out, int cap) {
    return sim_pack_around(s, out, cap, 0, 0, -1, 255, 255,
                           SIM_PACK_PRIVATE_ALL);
}

int sim_pack_around(const sim_state *s, uint8_t *out, int cap,
                    int32_t cx, int32_t cy, int32_t radius, uint8_t viewer,
                    uint8_t owner, uint8_t options) {
    if (!s || !out || cap < 0) return -1;
    if (s->weapon_count > SIM_MAX_WEAPONS || s->flag_count > SIM_MAX_FLAGS)
        return -1;
    wr w = {out, out + cap, 0};
    int64_t r2 = (int64_t)radius * radius;

    w32(&w, s->tick);
    w32(&w, s->rng);

    /* Which ships this viewer is told about, as a bitmap ahead of the records.
     *
     * A bitmap rather than a shorter array because a ship index is identity
     * everywhere else: the roster names seat 12, the kill feed credits seat
     * 12, and a team list holds seat 12. Renumbering to close the gaps would
     * make every one of those wrong. So the count stays the arena's, the bits
     * say which records follow, and `sim_unpack` leaves the rest zeroed, which
     * is to say inactive: nothing draws them, nothing steps them, and nothing
     * is stale because there is nothing there.
     *
     * Present means active and inside the radius. An inactive seat has
     * nothing to say and is never worth a bit's worth of record.
     *
     * Always written, with every bit set when the radius is negative, so there
     * is one wire format rather than two and the whole-state path is the same
     * code carrying the same bytes. */
    uint8_t here[SIM_MAX_SHIPS];
    for (int i = 0; i < s->ship_count; i++) {
        const sim_ship *sh = &s->ships[i];
        here[i] = (uint8_t)(sh->active &&
                            within(sh->x, sh->y, cx, cy, radius, r2));
    }
    w8(&w, s->ship_count);
    for (int b = 0; b < (s->ship_count + 7) / 8; b++) {
        uint32_t bits = 0;
        for (int k = 0; k < 8; k++) {
            int i = b * 8 + k;
            if (i < s->ship_count && here[i]) bits |= 1u << k;
        }
        w8(&w, bits);
    }
    for (int i = 0; i < s->ship_count; i++) {
        const sim_ship *sh = &s->ships[i];
        if (!here[i]) continue;
        /* `personal` rather than the obvious word: this file is compiled as
         * C++ inside the client's native extension, where `private` is a
         * keyword and not a name. See the note above sim_unpack. */
        int personal = (options & SIM_PACK_PRIVATE_ALL) || i == owner;
        w8(&w, (uint32_t)(sh->active | (sh->alive << 1) | (personal << 2)));
        w8(&w, sh->cls);
        w8(&w, sh->team);
        w32(&w, (uint32_t)sh->x);
        w32(&w, (uint32_t)sh->y);
        w32(&w, (uint32_t)sh->vx);
        w32(&w, (uint32_t)sh->vy);
        w16(&w, sh->heading);
        w16(&w, sh->repel);
        w32(&w, (uint32_t)sh->repel_speed);
        w16(&w, (uint16_t)sh->kills);
        w16(&w, sh->deaths);
        w16(&w, sh->assists);
        w16(&w, sh->run);
        w32(&w, sh->points);
        /* Energy is the fight's health bar. Anyone who can see the hull can
         * see how close it is to dying, which requires its capacity rung as
         * well as its current value. Other inventory and weapon state remain
         * in the owner-only tail below. */
        w32(&w, (uint32_t)sh->energy);
        w8(&w, sh->up[SIM_UP_ENERGY]);
        if (personal) {
            w16(&w, sh->fire_cooldown[SIM_TRIG_GUN]);
            w16(&w, sh->fire_cooldown[SIM_TRIG_BOMB]);
            w16(&w, sh->stall);
            w16(&w, sh->respawn_at);
            w32(&w, (uint32_t)sh->spawn_x);
            w32(&w, (uint32_t)sh->spawn_y);
            for (int u = 0; u < SIM_UP_COUNT; u++)
                if (u != SIM_UP_ENERGY) w8(&w, sh->up[u]);
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                w8(&w, sh->level[t]);
                w16(&w, sh->mods[t]);
            }
            for (int k = 0; k < SIM_MAX_CHARGES; k++) w8(&w, sh->charge[k]);
            /* These are needed only by the owner prediction. The edge state
             * prevents a held toggle from becoming a fresh press after every
             * snapshot. */
            w8(&w, sh->multi_off);
            w16(&w, sh->btn_prev);
            /* The kit, because a respawn re-deals from it and the client
             * predicts that: without this a pilot comes back flying a
             * different ship on the client than on the server. */
            for (int k = 0; k < SIM_SLOT_COUNT; k++) w8(&w, sh->kit[k]);
        }
    }

    /* Rounds in the air, near ones only, plus this viewer's own wherever they
     * are.
     *
     * Measured on the live arena, four fifths of them belong to fights nobody
     * here can see: 20.9% of 191,115 weapon-snapshots fell inside the radius.
     * They are 78% of the wire, so this is the whole of the bandwidth answer.
     *
     * No bitmap, because a weapon index is not identity. The array is rebuilt
     * from the wire every snapshot, nothing refers to a round across ticks,
     * and the count is simply how many were sent.
     *
     * The margin is the same one the ships get and larger in practice: the
     * radius is 256 tiles, a client can draw about thirty, and the quickest
     * round crosses well under a hundred pixels in the fifty milliseconds
     * before the next snapshot. Nothing arrives from outside the radius
     * without a snapshot in between announcing it.
     *
     * That argument holds for a round and not for a minefield, which is what
     * the owner test is doing here. A bullet is spent in a second or two and
     * never leaves the pilot who fired it; a mine sits for two minutes while
     * the pilot flies off, and measured on alpha every mine laid dropped out
     * of its own layer's snapshot inside seven seconds. See the note in
     * pack.h. Costing at most a pilot's five mines a snapshot, so the
     * bandwidth answer above is untouched. */
    uint16_t sent = 0;
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *p = &s->weapons[i];
        sent = (uint16_t)(sent + ((p->owner == viewer
                                   || within(p->x, p->y, cx, cy, radius, r2))
                                  ? 1 : 0));
    }
    w16(&w, sent);
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *p = &s->weapons[i];
        if (p->owner != viewer
            && !within(p->x, p->y, cx, cy, radius, r2)) continue;
        w8(&w, p->spec);
        w8(&w, p->left);
        w8(&w, p->depth);
        w16(&w, p->mods);
        w32(&w, p->link);
        w8(&w, p->owner);
        w8(&w, p->team);
        w32(&w, (uint32_t)p->x);
        w32(&w, (uint32_t)p->y);
        w32(&w, (uint32_t)p->vx);
        w32(&w, (uint32_t)p->vy);
        w16(&w, p->life);
        /* A proximity fuse that has latched a seat this viewer is not being
         * sent travels unarmed.
         *
         * It has to, and finding out why is the one sharp edge in filtering
         * ships. The fuse holds a ship index, and `sim_step` reads
         * `next->ships[fuse_target]` and ends the round the moment that seat
         * is inactive. An absent seat is a zeroed seat, so a client would
         * detonate the bomb immediately while the server flew it on: a
         * phantom explosion at the edge of the view, every time a round
         * inside the radius latched somebody just outside it.
         *
         * Unarmed is the honest thing to say rather than a workaround. The
         * client is being told it does not know what this round is tracking,
         * which is true, and the fuse is the server's to resolve anyway. It
         * costs the client nothing: an unarmed round flies straight, and the
         * next snapshot is fifty milliseconds away. */
        int blind = p->fuse_target != 255
                    && (p->fuse_target >= s->ship_count || !here[p->fuse_target]);
        w8(&w, blind ? 255 : p->fuse_target);
        w16(&w, blind ? 0 : p->fuse);
        w32(&w, blind ? 0 : (uint32_t)p->near);
        w8(&w, p->level);
        w8(&w, p->shrap_level);
        w8(&w, p->shrap_bounce);
    }

    w8(&w, s->flag_count);
    for (int i = 0; i < s->flag_count; i++) {
        const sim_flag *f = &s->flags[i];
        w8(&w, (uint32_t)(f->active | (f->carried << 1)));
        w8(&w, f->carrier);
        w8(&w, f->team);
        w32(&w, (uint32_t)f->x);
        w32(&w, (uint32_t)f->y);
        w16(&w, f->cooldown);
    }

    return w.overflow ? -1 : (int)(w.p - out);
}

int sim_unpack(sim_state *out, const uint8_t *in, int len) {
    if (!out || !in || len < 0) return -1;
    /* Decode away from the live state. A rejected snapshot must not replace a
     * good one with a half-read message, especially for callers that report
     * the error and wait for the next snapshot rather than disconnecting. */
    sim_state decoded;
    sim_state *s = &decoded;
    rd r = {in, in + len, 0};
    memset(s, 0, sizeof *s);

    s->tick = r32(&r);
    s->rng = r32(&r);

    uint32_t ships = r8(&r);
    if (ships > SIM_MAX_SHIPS) return -1;
    s->ship_count = (uint8_t)ships;
    /* The presence bitmap. A seat whose bit is clear keeps the zeroes the
     * memset above left, which is an inactive seat: nothing draws it, nothing
     * steps it, and its index still means what it means everywhere else. */
    uint8_t here[(SIM_MAX_SHIPS + 7) / 8];
    uint32_t here_bytes = (ships + 7) / 8;
    for (uint32_t b = 0; b < here_bytes; b++) here[b] = (uint8_t)r8(&r);
    if (ships % 8 && (here[here_bytes - 1] >> (ships % 8)) != 0) return -1;
    for (uint32_t i = 0; i < ships; i++) {
        if (!((here[i >> 3] >> (i & 7)) & 1)) continue;
        sim_ship *sh = &s->ships[i];
        uint32_t flags = r8(&r);
        if ((flags & ~7u) != 0 || (flags & 1u) == 0) return -1;
        sh->active = (uint8_t)(flags & 1);
        sh->alive = (uint8_t)((flags >> 1) & 1);
        /* Not `private`, which is a keyword in the dialect the client's
         * extension compiles this file in. Defold's build server hands every
         * .c in an extension to clang++, so a name that is only a name in C
         * builds here, passes every test, and fails on their machine. */
        int personal = (int)((flags >> 2) & 1);
        sh->public_only = (uint8_t)!personal;
        sh->cls = (uint8_t)r8(&r);
        /* A hull index off the wire is an array index everywhere it lands:
         * settings->classes is SIM_MAX_CLASSES wide, and both the stepping
         * core and the client's accessors subscript it with this byte and no
         * bound of their own. Refusing it here is the only place that covers
         * all of them, and a sender with a class this build does not have is
         * talking about a game this build cannot play anyway. */
        if (sh->cls >= SIM_MAX_CLASSES) return -1;
        sh->team = (uint8_t)r8(&r);
        sh->x = (int32_t)r32(&r);
        sh->y = (int32_t)r32(&r);
        if (!world_point(sh->x, sh->y)) return -1;
        sh->vx = (int32_t)r32(&r);
        sh->vy = (int32_t)r32(&r);
        if (!world_velocity(sh->vx) || !world_velocity(sh->vy)) return -1;
        sh->heading = (uint16_t)r16(&r);
        sh->repel = (uint16_t)r16(&r);
        sh->repel_speed = (int32_t)r32(&r);
        if (!world_velocity(sh->repel_speed)) return -1;
        sh->kills = (int16_t)(uint16_t)r16(&r);
        sh->deaths = (uint16_t)r16(&r);
        sh->assists = (uint16_t)r16(&r);
        sh->run = (uint16_t)r16(&r);
        sh->points = r32(&r);
        sh->energy = (int32_t)r32(&r);
        if ((sh->alive && sh->energy <= 0) || (!sh->alive && sh->energy != 0))
            return -1;
        sh->up[SIM_UP_ENERGY] = (uint8_t)r8(&r);
        if (personal) {
            sh->fire_cooldown[SIM_TRIG_GUN] = (uint16_t)r16(&r);
            sh->fire_cooldown[SIM_TRIG_BOMB] = (uint16_t)r16(&r);
            sh->stall = (uint16_t)r16(&r);
            sh->respawn_at = (uint16_t)r16(&r);
            sh->spawn_x = (int32_t)r32(&r);
            sh->spawn_y = (int32_t)r32(&r);
            if (!world_point(sh->spawn_x, sh->spawn_y)) return -1;
            for (int u = 0; u < SIM_UP_COUNT; u++)
                if (u != SIM_UP_ENERGY) sh->up[u] = (uint8_t)r8(&r);
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                sh->level[t] = (uint8_t)r8(&r);
                sh->mods[t] = (uint16_t)r16(&r);
                if (sh->level[t] >= SIM_MAX_RUNGS
                    || !sim_mods_wellformed(sh->mods[t]))
                    return -1;
            }
            for (int k = 0; k < SIM_MAX_CHARGES; k++) {
                sh->charge[k] = (uint8_t)r8(&r);
                if (sh->charge[k] > SIM_CHARGE_MAX) return -1;
            }
            sh->multi_off = (uint8_t)r8(&r);
            if (sh->multi_off > 1) return -1;
            sh->btn_prev = (uint16_t)r16(&r);
            for (int k = 0; k < SIM_SLOT_COUNT; k++)
                sh->kit[k] = (uint8_t)r8(&r);
        }
    }

    uint32_t weapons = r16(&r);
    if (weapons > SIM_MAX_WEAPONS) return -1;
    s->weapon_count = (uint16_t)weapons;
    for (uint32_t i = 0; i < weapons; i++) {
        sim_weapon *p = &s->weapons[i];
        p->spec = (uint8_t)r8(&r);
        if (p->spec >= SIM_MAX_SPECS) return -1;
        p->left = (uint8_t)r8(&r);
        p->depth = (uint8_t)r8(&r);
        if (p->depth > SIM_MAX_SPLINTER_DEPTH) return -1;
        p->mods = (uint16_t)r16(&r);
        if (!sim_mods_wellformed(p->mods)) return -1;
        p->link = r32(&r);
        p->owner = (uint8_t)r8(&r);
        if (p->owner >= ships) return -1;
        p->team = (uint8_t)r8(&r);
        p->x = (int32_t)r32(&r);
        p->y = (int32_t)r32(&r);
        if (!world_point(p->x, p->y)) return -1;
        p->vx = (int32_t)r32(&r);
        p->vy = (int32_t)r32(&r);
        if (!world_velocity(p->vx) || !world_velocity(p->vy)) return -1;
        p->life = (uint16_t)r16(&r);
        p->fuse_target = (uint8_t)r8(&r);
        if (p->fuse_target != 255 && p->fuse_target >= ships) return -1;
        p->fuse = (uint16_t)r16(&r);
        p->near = (int32_t)r32(&r);
        if (p->near < 0) return -1;
        p->level = (uint8_t)r8(&r);
        p->shrap_level = (uint8_t)r8(&r);
        p->shrap_bounce = (uint8_t)r8(&r);
        if (p->level >= SIM_MAX_RUNGS || p->shrap_level >= SIM_MAX_RUNGS
            || p->shrap_bounce > 1)
            return -1;
    }


    uint32_t flags = r8(&r);
    if (flags > SIM_MAX_FLAGS) return -1;
    s->flag_count = (uint8_t)flags;
    for (uint32_t i = 0; i < flags; i++) {
        sim_flag *f = &s->flags[i];
        uint32_t bits = r8(&r);
        if ((bits & ~3u) != 0 || !(bits & 1u)) return -1;
        f->active = (uint8_t)(bits & 1);
        f->carried = (uint8_t)((bits >> 1) & 1);
        f->carrier = (uint8_t)r8(&r);
        if (f->carried && f->carrier >= ships) return -1;
        f->team = (uint8_t)r8(&r);
        f->x = (int32_t)r32(&r);
        f->y = (int32_t)r32(&r);
        if (!world_point(f->x, f->y)) return -1;
        f->cooldown = (uint16_t)r16(&r);
    }

    /* Read short is as wrong as read long.
     *
     * `underflow` catches a reader running past the end, which is a new build
     * reading an old message. The other direction was silent: an old build
     * reading a new message stops before the fields it does not know about, the
     * trailing bytes go unread, and this returned success on a message it had
     * misread from the first added field onward.
     *
     * That shipped. Three fields were added here for repel; the browser bundle
     * was not rebuilt; the server wrote the new layout, the deployed client read
     * the old one, and a player joining Chaos was shown DESTROYED for as long as
     * they cared to watch -- because the garbage it unpacked said their ship was
     * dead. The protocol number that exists to prevent this is a constant
     * somebody has to remember to bump, and the same lapse that skips the
     * rebuild skips the bump.
     *
     * Requiring the reader to land exactly on the end needs nobody to remember
     * anything: any field added on one side and not the other changes the length
     * and is refused. Both callers already pass an exact slice, so there are no
     * legitimate trailing bytes to tolerate. The client turns a refusal into
     * "the zone sent settings this client cannot read" and disconnects saying
     * so, which is the whole difference between a bug report and a diagnosis. */
    if (r.underflow || r.p != r.end) return -1;
    *out = decoded;
    return 0;
}

/* ---- settings ----
 *
 * The tuning a zone runs on, on the wire for the same reason the map is: a
 * client predicts by stepping the core itself, so it has to be stepping the
 * server's numbers. Before this the two ends agreed by both compiling
 * `sim_settings_baseline`, which held right up until a zone file overrode
 * something -- and would have held a lot less well once a zone starts adding
 * weapons, because a spec is an index into a table and two different tables
 * do not even agree on what an index means.
 *
 * The map pointer is not on the wire. Geometry travels as a map, arrives
 * first, and is left alone here.
 */

#define CFG_MAGIC 0x56434647u /* "VCFG" */
/* 11: `still` and `blast_up` joined the spec. The version is the whole of the
 * compatibility story -- a mismatch is refused, and CI ships both ends of the
 * wire from the same commit -- but the fields still have to be *here*: this
 * file is a hand-written mirror of the spec struct, and a field it does not
 * carry arrives at every client as zero. For these two that is a mine that
 * flies off at its layer's speed in the client's predicted world and wears a
 * blast the ladder never grew, while the server plays the weapon correctly,
 * which is the exact drift this message exists to prevent.
 *
 * 12: `spawn_radius` and `show_spawns`. Two branches both called themselves 11
 * and both changed the layout, which is what a merge of them has to notice: a
 * client built from either one would have read this format's bytes in the
 * wrong order while agreeing about the number that says it cannot. The radius
 * has to travel because the client predicts a respawn's position, and the mark
 * because the client is what draws it.
 *
 * 13: `mine` and `mine_max`. Mines stopped being a charge, so the pattern is
 * no longer reachable through `charge[]` and the ceiling is no longer a
 * count in hand. Both travel because the client predicts laying one: without
 * them it either cannot find the weapon at all or lets a pilot put down more
 * than the room allows and watches the server delete them.
 *
 * 14: public energy state and the capacity rung returned to ship records.
 *
 * 15: gunner limits plus the carrier thrust and speed penalties.
 *
 * 16: the match game. Greens are gone, so every weight, rate, bound and
 * lifetime that placed or priced one leaves with them; a mine is a charge
 * again, so `mine` and `mine_max` go back to `charge[]` and the hull's
 * charge row; gunners are gone, so their three fields go; and `bounty_base`
 * arrives, because bounty is a run rather than a sum over what is held and
 * the client derives the price from it. */
#define CFG_VERSION 17

static int settings_valid(const sim_settings *cfg) {
    if (cfg->class_count == 0 || cfg->class_count > SIM_MAX_CLASSES
        || cfg->spec_count > SIM_MAX_SPECS
        || cfg->pattern_count > SIM_MAX_PATTERNS)
        return 0;

    for (int i = 0; i < cfg->class_count; i++) {
        const sim_ship_class *c = &cfg->classes[i];
        for (int t = 0; t < SIM_TRIG_COUNT; t++)
            for (int rung = 0; rung < SIM_MAX_RUNGS; rung++)
                if (c->trigger[t][rung] != SIM_NO_PATTERN
                    && c->trigger[t][rung] >= cfg->pattern_count)
                    return 0;
    }
    for (int i = 0; i < cfg->spec_count; i++) {
        const sim_weapon_spec *sp = &cfg->specs[i];
        if (sp->on_wall > SIM_WALL_PASS) return 0;
        if (sp->splinter != SIM_NO_PATTERN && sp->splinter >= cfg->pattern_count)
            return 0;
    }
    for (int i = 0; i < cfg->pattern_count; i++)
        if (cfg->patterns[i].spec >= cfg->spec_count) return 0;
    for (int i = 0; i < SIM_MAX_CHARGES; i++)
        if (cfg->charge[i] != SIM_NO_PATTERN
            && cfg->charge[i] >= cfg->pattern_count)
            return 0;
    for (int i = 0; i < SIM_MAX_RUNGS; i++)
        if (cfg->mod_splinter[i] != SIM_NO_PATTERN
            && cfg->mod_splinter[i] >= cfg->pattern_count)
            return 0;
    return 1;
}

int sim_settings_pack(const sim_settings *cfg, uint8_t *out, int cap) {
    if (!cfg || !out || cap < 0) return -1;
    if (!settings_valid(cfg)) return -1;
    wr w = {out, out + cap, 0};
    w32(&w, CFG_MAGIC);
    w8(&w, CFG_VERSION);

    w8(&w, cfg->class_count);
    for (int i = 0; i < cfg->class_count; i++) {
        const sim_ship_class *c = &cfg->classes[i];
        w32(&w, (uint32_t)c->max_speed);
        w32(&w, (uint32_t)c->init_speed);
        w32(&w, (uint32_t)c->up_speed);
        w32(&w, (uint32_t)c->thrust);
        w32(&w, (uint32_t)c->init_thrust);
        w32(&w, (uint32_t)c->up_thrust);
        w32(&w, (uint32_t)c->rot);
        w32(&w, (uint32_t)c->init_rot);
        w32(&w, (uint32_t)c->up_rot);
        w32(&w, (uint32_t)c->max_energy);
        w32(&w, (uint32_t)c->init_energy);
        w32(&w, (uint32_t)c->up_energy);
        w32(&w, (uint32_t)c->recharge);
        w32(&w, (uint32_t)c->init_recharge);
        w32(&w, (uint32_t)c->up_recharge);
        w32(&w, (uint32_t)c->fore);
        w32(&w, (uint32_t)c->aft);
        w32(&w, (uint32_t)c->halfw);
        for (int t = 0; t < SIM_TRIG_COUNT; t++)
            for (int r = 0; r < SIM_MAX_RUNGS; r++) w8(&w, c->trigger[t][r]);
    }
    /* Once for the arena, where it used to be twice per hull. */
    for (int i = 0; i < SIM_SLOT_COUNT; i++) w8(&w, cfg->kit_ceiling[i]);

    w32(&w, (uint32_t)cfg->prox_step);
    w16(&w, cfg->prox_delay);
    w8(&w, cfg->bomb_safety);
    w16(&w, cfg->bbomb_damage);
    w32(&w, (uint32_t)cfg->shrap_inactive);
    w16(&w, cfg->shrap_inactive_ticks);

    w8(&w, cfg->spec_count);
    for (int i = 0; i < cfg->spec_count; i++) {
        const sim_weapon_spec *sp = &cfg->specs[i];
        w32(&w, (uint32_t)sp->speed);
        w16(&w, sp->life);
        w8(&w, sp->on_wall);
        w8(&w, sp->bounces);
        w8(&w, sp->still);
        w32(&w, (uint32_t)sp->trigger);
        w8(&w, sp->expire_ends);
        w8(&w, sp->splinter);
        w32(&w, (uint32_t)sp->damage);
        w32(&w, (uint32_t)sp->damage_up);
        w32(&w, (uint32_t)sp->blast);
        w32(&w, (uint32_t)sp->blast_up);
        w32(&w, (uint32_t)sp->push);
        w16(&w, sp->push_time);
        w16(&w, sp->stall);
    }

    w8(&w, cfg->pattern_count);
    for (int i = 0; i < cfg->pattern_count; i++) {
        const sim_fire_pattern *p = &cfg->patterns[i];
        w8(&w, p->spec);
        w8(&w, p->count);
        w16(&w, p->spacing);
        w32(&w, (uint32_t)p->energy);
        w32(&w, (uint32_t)p->energy_up);
        w16(&w, p->delay);
        w32(&w, (uint32_t)p->recoil);
    }

    for (int k = 0; k < SIM_MAX_CHARGES; k++) w8(&w, cfg->charge[k]);
    w16(&w, cfg->bounty_base);
    w16(&w, cfg->bounty_per_kill);
    w16(&w, cfg->points_per_flag);
    for (int m = 0; m < SIM_MOD_COUNT; m++) w32(&w, (uint32_t)cfg->mod_step[m]);
    w16(&w, cfg->mod_spread);
    w16(&w, cfg->mod_pair_spread);
    w16(&w, cfg->mod_multi_energy);
    w16(&w, cfg->mod_multi_delay);
    for (int r = 0; r < SIM_MAX_RUNGS; r++) w8(&w, cfg->mod_splinter[r]);
    w32(&w, (uint32_t)cfg->bounce);
    w32(&w, (uint32_t)cfg->friction);
    w16(&w, cfg->respawn_delay);
    w16(&w, cfg->spawn_radius);
    w8(&w, cfg->show_spawns);
    w16(&w, cfg->safe_limit);
    w16(&w, cfg->door_period);
    w16(&w, cfg->door_open);
    w32(&w, (uint32_t)cfg->wormhole_pull);
    w32(&w, (uint32_t)cfg->wormhole_range);
    w32(&w, (uint32_t)cfg->flag_radius);
    w16(&w, cfg->flag_drop_cooldown);
    w8(&w, cfg->max_ships);

    return w.overflow ? -1 : (int)(w.p - out);
}

int sim_settings_unpack(sim_settings *out, const uint8_t *in, int len) {
    if (!out || !in || len < 0) return -1;
    sim_settings decoded;
    sim_settings *cfg = &decoded;
    rd r = {in, in + len, 0};
    if (r32(&r) != CFG_MAGIC) return -1;
    if (r8(&r) != CFG_VERSION) return -1;

    /* Geometry is not in here and is not ours to clear. Decode away from the
     * live settings so a malformed reload leaves the prior tuning intact. */
    const sim_map *map = out->map;
    memset(cfg, 0, sizeof *cfg);
    cfg->map = map;

    uint32_t classes = r8(&r);
    if (classes > SIM_MAX_CLASSES) return -1;
    cfg->class_count = (uint8_t)classes;
    for (uint32_t i = 0; i < classes; i++) {
        sim_ship_class *c = &cfg->classes[i];
        c->max_speed = (int32_t)r32(&r);
        c->init_speed = (int32_t)r32(&r);
        c->up_speed = (int32_t)r32(&r);
        c->thrust = (int32_t)r32(&r);
        c->init_thrust = (int32_t)r32(&r);
        c->up_thrust = (int32_t)r32(&r);
        c->rot = (int32_t)r32(&r);
        c->init_rot = (int32_t)r32(&r);
        c->up_rot = (int32_t)r32(&r);
        c->max_energy = (int32_t)r32(&r);
        c->init_energy = (int32_t)r32(&r);
        c->up_energy = (int32_t)r32(&r);
        c->recharge = (int32_t)r32(&r);
        c->init_recharge = (int32_t)r32(&r);
        c->up_recharge = (int32_t)r32(&r);
        c->fore = (int32_t)r32(&r);
        c->aft = (int32_t)r32(&r);
        c->halfw = (int32_t)r32(&r);
        for (int t = 0; t < SIM_TRIG_COUNT; t++)
            for (int k = 0; k < SIM_MAX_RUNGS; k++)
                c->trigger[t][k] = (uint8_t)r8(&r);
    }
    for (int i = 0; i < SIM_SLOT_COUNT; i++)
        cfg->kit_ceiling[i] = (uint8_t)r8(&r);

    cfg->prox_step = (int32_t)r32(&r);
    cfg->prox_delay = (uint16_t)r16(&r);
    cfg->bomb_safety = (uint8_t)r8(&r);
    cfg->bbomb_damage = (uint16_t)r16(&r);
    cfg->shrap_inactive = (int32_t)r32(&r);
    cfg->shrap_inactive_ticks = (uint16_t)r16(&r);

    uint32_t specs = r8(&r);
    if (specs > SIM_MAX_SPECS) return -1;
    cfg->spec_count = (uint8_t)specs;
    for (uint32_t i = 0; i < specs; i++) {
        sim_weapon_spec *sp = &cfg->specs[i];
        sp->speed = (int32_t)r32(&r);
        sp->life = (uint16_t)r16(&r);
        sp->on_wall = (uint8_t)r8(&r);
        sp->bounces = (uint8_t)r8(&r);
        sp->still = (uint8_t)r8(&r);
        sp->trigger = (int32_t)r32(&r);
        sp->expire_ends = (uint8_t)r8(&r);
        sp->splinter = (uint8_t)r8(&r);
        sp->damage = (int32_t)r32(&r);
        sp->damage_up = (int32_t)r32(&r);
        sp->blast = (int32_t)r32(&r);
        sp->blast_up = (int32_t)r32(&r);
        sp->push = (int32_t)r32(&r);
        sp->push_time = (uint16_t)r16(&r);
        sp->stall = (uint16_t)r16(&r);
    }

    uint32_t patterns = r8(&r);
    if (patterns > SIM_MAX_PATTERNS) return -1;
    cfg->pattern_count = (uint8_t)patterns;
    for (uint32_t i = 0; i < patterns; i++) {
        sim_fire_pattern *p = &cfg->patterns[i];
        p->spec = (uint8_t)r8(&r);
        p->count = (uint8_t)r8(&r);
        p->spacing = (uint16_t)r16(&r);
        p->energy = (int32_t)r32(&r);
        p->energy_up = (int32_t)r32(&r);
        p->delay = (uint16_t)r16(&r);
        p->recoil = (int32_t)r32(&r);
    }

    for (int k = 0; k < SIM_MAX_CHARGES; k++) cfg->charge[k] = (uint8_t)r8(&r);
    cfg->bounty_base = (uint16_t)r16(&r);
    cfg->bounty_per_kill = (uint16_t)r16(&r);
    cfg->points_per_flag = (uint16_t)r16(&r);
    for (int m = 0; m < SIM_MOD_COUNT; m++) cfg->mod_step[m] = (int32_t)r32(&r);
    cfg->mod_spread = (uint16_t)r16(&r);
    cfg->mod_pair_spread = (uint16_t)r16(&r);
    cfg->mod_multi_energy = (uint16_t)r16(&r);
    cfg->mod_multi_delay = (uint16_t)r16(&r);
    for (int k = 0; k < SIM_MAX_RUNGS; k++)
        cfg->mod_splinter[k] = (uint8_t)r8(&r);
    cfg->bounce = (int32_t)r32(&r);
    cfg->friction = (int32_t)r32(&r);
    cfg->respawn_delay = (uint16_t)r16(&r);
    cfg->spawn_radius = (uint16_t)r16(&r);
    cfg->show_spawns = (uint8_t)r8(&r);
    cfg->safe_limit = (uint16_t)r16(&r);
    cfg->door_period = (uint16_t)r16(&r);
    cfg->door_open = (uint16_t)r16(&r);
    cfg->wormhole_pull = (int32_t)r32(&r);
    cfg->wormhole_range = (int32_t)r32(&r);
    cfg->flag_radius = (int32_t)r32(&r);
    cfg->flag_drop_cooldown = (uint16_t)r16(&r);
    cfg->max_ships = r8(&r);

    /* Read short is as wrong as read long.
     *
     * `underflow` catches a reader running past the end, which is a new build
     * reading an old message. The other direction was silent: an old build
     * reading a new message stops before the fields it does not know about, the
     * trailing bytes go unread, and this returned success on a message it had
     * misread from the first added field onward.
     *
     * That shipped. Three fields were added here for repel; the browser bundle
     * was not rebuilt; the server wrote the new layout, the deployed client read
     * the old one, and a player joining Chaos was shown DESTROYED for as long as
     * they cared to watch -- because the garbage it unpacked said their ship was
     * dead. The protocol number that exists to prevent this is a constant
     * somebody has to remember to bump, and the same lapse that skips the
     * rebuild skips the bump.
     *
     * Requiring the reader to land exactly on the end needs nobody to remember
     * anything: any field added on one side and not the other changes the length
     * and is refused. Both callers already pass an exact slice, so there are no
     * legitimate trailing bytes to tolerate. The client turns a refusal into
     * "the zone sent settings this client cannot read" and disconnects saying
     * so, which is the whole difference between a bug report and a diagnosis. */
    if (r.underflow || r.p != r.end || !settings_valid(cfg)) return -1;
    *out = decoded;
    return 0;
}

/* ---- maps ---- */

#define MAP_MAGIC 0x564d4150u /* "VMAP" */
/* Version 2 carries the map's size. Version 1 was always a thousand tiles
 * square and there is no reading one as the other, which is the whole reason
 * the version byte is here. */
#define MAP_VERSION 2
/* magic, version, reserved, width, height, hash. Version 1's was ten, and the
 * reader's bound has to be this one exactly: short by two and a truncated file
 * gets past the length check and the size is read off the end of it. */
#define MAP_HEADER 14

/* The tiles a map actually has, row by row, which is not the array they sit
 * in. The size goes in first so two maps with the same drawing at different
 * sizes cannot hash alike. */
uint32_t sim_map_hash(const sim_map *m) {
    uint32_t h = 2166136261u;
    uint8_t dim[4] = {(uint8_t)(m->w & 0xff), (uint8_t)(m->w >> 8),
                      (uint8_t)(m->h & 0xff), (uint8_t)(m->h >> 8)};
    for (int b = 0; b < 4; b++) {
        h ^= dim[b];
        h *= 16777619u;
    }
    for (uint32_t ty = 0; ty < m->h; ty++)
        for (uint32_t tx = 0; tx < m->w; tx++) {
            h ^= SIM_MAP_AT(m, tx, ty);
            h *= 16777619u;
        }
    return h;
}

/* A size the reader will accept: inside the array, and big enough to hold the
 * boundary the index paints with something left over. */
static int map_dim_ok(uint32_t w, uint32_t h) {
    return w >= 9 && h >= 9 && w <= SIM_MAP_TILES && h <= SIM_MAP_TILES;
}

int sim_map_pack(const sim_map *m, uint8_t *out, int cap) {
    if (!m || !out || cap < 0) return -1;
    if (cap < MAP_HEADER) return -1;
    if (!map_dim_ok(m->w, m->h)) return -1;
    int n = 0;
    uint32_t magic = MAP_MAGIC;
    for (int b = 0; b < 4; b++) out[n++] = (uint8_t)(magic >> (b * 8));
    out[n++] = MAP_VERSION;
    out[n++] = 0; /* reserved */
    out[n++] = (uint8_t)(m->w & 0xff);
    out[n++] = (uint8_t)(m->w >> 8);
    out[n++] = (uint8_t)(m->h & 0xff);
    out[n++] = (uint8_t)(m->h >> 8);
    uint32_t h = sim_map_hash(m);
    for (int b = 0; b < 4; b++) out[n++] = (uint8_t)(h >> (b * 8));

    /* Run length over the map's own tiles, read in row order. The array's
     * stride is not in the file: a 144-tile map that carried it would spend
     * every row saying "and then eight hundred and eighty tiles of nothing",
     * and be a different file at a different stride. */
    size_t total = (size_t)m->w * (size_t)m->h;
    size_t i = 0;
    while (i < total) {
        uint8_t v = SIM_MAP_AT(m, i % m->w, i / m->w);
        size_t run = 1;
        /* 65535 is the longest a run can say, and a full empty map is more
         * tiles than that, so long runs simply repeat. */
        while (i + run < total
               && SIM_MAP_AT(m, (i + run) % m->w, (i + run) / m->w) == v
               && run < 65535)
            run++;
        if (n + 3 > cap) return -1;
        out[n++] = (uint8_t)(run & 0xff);
        out[n++] = (uint8_t)(run >> 8);
        out[n++] = v;
        i += run;
    }
    return n;
}

int sim_map_unpack(sim_map *m, const uint8_t *in, int len) {
    if (!m || !in || len < 0) return -1;
    if (len < MAP_HEADER) return -1;
    int n = 0;
    uint32_t magic = 0;
    for (int b = 0; b < 4; b++) magic |= (uint32_t)in[n++] << (b * 8);
    if (magic != MAP_MAGIC) return -1;
    if (in[n++] != MAP_VERSION) return -1;
    if (in[n++] != 0) return -1;
    uint32_t w = (uint32_t)in[n] | ((uint32_t)in[n + 1] << 8);
    uint32_t h = (uint32_t)in[n + 2] | ((uint32_t)in[n + 3] << 8);
    n += 4;
    if (!map_dim_ok(w, h)) return -1;
    uint32_t want = 0;
    for (int b = 0; b < 4; b++) want |= (uint32_t)in[n++] << (b * 8);

    sim_map_size(m, (int)w, (int)h);
    size_t total = (size_t)w * (size_t)h;
    size_t i = 0;
    while (n + 3 <= len && i < total) {
        size_t run = (size_t)in[n] | ((size_t)in[n + 1] << 8);
        uint8_t v = in[n + 2];
        n += 3;
        if (run == 0 || i + run > total) return -1;
        for (size_t k = 0; k < run; k++, i++)
            SIM_MAP_AT(m, i % w, i / w) = v;
    }
    /* A map that stops early is a truncated map, not an empty tail. */
    if (i != total) return -1;
    if (n != len) return -1;
    if (sim_map_hash(m) != want) return -2;
    sim_map_index(m);
    return 0;
}
