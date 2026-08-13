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

int sim_pack(const sim_state *s, uint8_t *out, int cap) {
    return sim_pack_around(s, out, cap, 0, 0, -1, 255, 255,
                           SIM_PACK_PRIVATE_ALL | SIM_PACK_SECRET);
}

int sim_pack_around(const sim_state *s, uint8_t *out, int cap,
                    int32_t cx, int32_t cy, int32_t radius, uint8_t viewer,
                    uint8_t owner, uint8_t options) {
    wr w = {out, out + cap, 0};
    int64_t r2 = (int64_t)radius * radius;

    w32(&w, s->tick);
    w32(&w, s->rng);
    w8(&w, options & SIM_PACK_SECRET);
    if (options & SIM_PACK_SECRET) {
        w32(&w, s->prize_rng);
        w16(&w, s->prize_timer);
    }

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
        w16(&w, sh->kills);
        w16(&w, sh->deaths);
        int32_t bounty = sim_bounty(sh);
        if (bounty < 0) bounty = 0;
        if (bounty > UINT16_MAX) bounty = UINT16_MAX;
        w16(&w, (uint32_t)bounty);
        w32(&w, sh->points);
        w8(&w, sh->carrier);
        if (personal) {
            w32(&w, (uint32_t)sh->energy);
            w16(&w, sh->fire_cooldown[SIM_TRIG_GUN]);
            w16(&w, sh->fire_cooldown[SIM_TRIG_BOMB]);
            w16(&w, sh->stall);
            w16(&w, sh->respawn_at);
            w32(&w, (uint32_t)sh->spawn_x);
            w32(&w, (uint32_t)sh->spawn_y);
            for (int u = 0; u < SIM_UP_COUNT; u++) w8(&w, sh->up[u]);
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
            w16(&w, sh->earned);
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

    /* A prize is always at the center of a tile -- `spawn_prize` puts it
     * there and nothing moves it -- so its position is two tile indices
     * rather than two Q8 pixel coordinates. Four bytes each way instead of
     * eight, and the unpacked state is bit-identical: the arithmetic below is
     * the same expression `spawn_prize` used to place it.
     *
     * This is worth its own note because prizes are most of a snapshot. At
     * two hundred on the map they were 1651 bytes of a 3048-byte packet --
     * more than the ships and every projectile in the air put together. */
    uint8_t live = 0;
    for (int i = 0; i < SIM_MAX_PRIZES; i++)
        live += (s->prizes[i].active
                 && within(s->prizes[i].x, s->prizes[i].y, cx, cy, radius, r2))
                ? 1 : 0;
    w8(&w, live);
    for (int i = 0; i < SIM_MAX_PRIZES; i++) {
        const sim_prize *p = &s->prizes[i];
        if (!p->active) continue;
        if (!within(p->x, p->y, cx, cy, radius, r2)) continue;
        w8(&w, (uint32_t)i);
        w16(&w, (uint32_t)(p->x / (SIM_TILE_PX * 256)));
        w16(&w, (uint32_t)(p->y / (SIM_TILE_PX * 256)));
        w16(&w, p->life);
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

int sim_unpack(sim_state *s, const uint8_t *in, int len) {
    rd r = {in, in + len, 0};
    memset(s, 0, sizeof *s);

    s->tick = r32(&r);
    s->rng = r32(&r);
    uint32_t options = r8(&r);
    if (options & ~SIM_PACK_SECRET) return -1;
    if (options & SIM_PACK_SECRET) {
        s->prize_rng = r32(&r);
        s->prize_timer = (uint16_t)r16(&r);
    } else {
        s->prize_rng = 1;
    }

    uint32_t ships = r8(&r);
    if (ships > SIM_MAX_SHIPS) return -1;
    s->ship_count = (uint8_t)ships;
    /* The presence bitmap. A seat whose bit is clear keeps the zeroes the
     * memset above left, which is an inactive seat: nothing draws it, nothing
     * steps it, and its index still means what it means everywhere else. */
    uint8_t here[(SIM_MAX_SHIPS + 7) / 8];
    for (uint32_t b = 0; b < (ships + 7) / 8; b++) here[b] = (uint8_t)r8(&r);
    for (uint32_t i = 0; i < ships; i++) {
        if (!((here[i >> 3] >> (i & 7)) & 1)) continue;
        sim_ship *sh = &s->ships[i];
        uint32_t flags = r8(&r);
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
        sh->vx = (int32_t)r32(&r);
        sh->vy = (int32_t)r32(&r);
        sh->heading = (uint16_t)r16(&r);
        sh->repel = (uint16_t)r16(&r);
        sh->repel_speed = (int32_t)r32(&r);
        sh->kills = (uint16_t)r16(&r);
        sh->deaths = (uint16_t)r16(&r);
        uint16_t bounty = (uint16_t)r16(&r);
        sh->points = r32(&r);
        sh->carrier = (uint8_t)r8(&r);
        if (personal) {
            sh->energy = (int32_t)r32(&r);
            sh->fire_cooldown[SIM_TRIG_GUN] = (uint16_t)r16(&r);
            sh->fire_cooldown[SIM_TRIG_BOMB] = (uint16_t)r16(&r);
            sh->stall = (uint16_t)r16(&r);
            sh->respawn_at = (uint16_t)r16(&r);
            sh->spawn_x = (int32_t)r32(&r);
            sh->spawn_y = (int32_t)r32(&r);
            for (int u = 0; u < SIM_UP_COUNT; u++) sh->up[u] = (uint8_t)r8(&r);
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                sh->level[t] = (uint8_t)r8(&r);
                sh->mods[t] = (uint16_t)r16(&r);
            }
            for (int k = 0; k < SIM_MAX_CHARGES; k++)
                sh->charge[k] = (uint8_t)r8(&r);
            sh->multi_off = (uint8_t)r8(&r);
            sh->btn_prev = (uint16_t)r16(&r);
            sh->earned = (uint16_t)r16(&r);
        } else {
            /* `sim_bounty` remains useful to rendering code without exposing
             * which upgrades make up the number. With every private count at
             * zero, the public bounty is exactly `earned`. */
            sh->earned = bounty;
        }
    }

    uint32_t weapons = r16(&r);
    if (weapons > SIM_MAX_WEAPONS) return -1;
    s->weapon_count = (uint16_t)weapons;
    for (uint32_t i = 0; i < weapons; i++) {
        sim_weapon *p = &s->weapons[i];
        p->spec = (uint8_t)r8(&r);
        p->left = (uint8_t)r8(&r);
        p->depth = (uint8_t)r8(&r);
        p->mods = (uint16_t)r16(&r);
        p->owner = (uint8_t)r8(&r);
        p->team = (uint8_t)r8(&r);
        p->x = (int32_t)r32(&r);
        p->y = (int32_t)r32(&r);
        p->vx = (int32_t)r32(&r);
        p->vy = (int32_t)r32(&r);
        p->life = (uint16_t)r16(&r);
        p->fuse_target = (uint8_t)r8(&r);
        p->fuse = (uint16_t)r16(&r);
        p->near = (int32_t)r32(&r);
        p->level = (uint8_t)r8(&r);
        p->shrap_level = (uint8_t)r8(&r);
        p->shrap_bounce = (uint8_t)r8(&r);
    }

    uint32_t prizes = r8(&r);
    if (prizes > SIM_MAX_PRIZES) return -1;
    for (uint32_t i = 0; i < prizes; i++) {
        uint32_t idx = r8(&r);
        if (idx >= SIM_MAX_PRIZES) return -1;
        sim_prize *p = &s->prizes[idx];
        p->active = 1;
        /* The same expression spawn_prize places a prize with, so the state
         * that comes off the wire is the state that went on it. */
        p->x = (int32_t)((int32_t)r16(&r) * SIM_TILE_PX + SIM_TILE_PX / 2) * 256;
        p->y = (int32_t)((int32_t)r16(&r) * SIM_TILE_PX + SIM_TILE_PX / 2) * 256;
        p->life = (uint16_t)r16(&r);
    }

    uint32_t flags = r8(&r);
    if (flags > SIM_MAX_FLAGS) return -1;
    s->flag_count = (uint8_t)flags;
    for (uint32_t i = 0; i < flags; i++) {
        sim_flag *f = &s->flags[i];
        uint32_t bits = r8(&r);
        f->active = (uint8_t)(bits & 1);
        f->carried = (uint8_t)((bits >> 1) & 1);
        f->carrier = (uint8_t)r8(&r);
        f->team = (uint8_t)r8(&r);
        f->x = (int32_t)r32(&r);
        f->y = (int32_t)r32(&r);
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
 * than the room allows and watches the server delete them. */
#define CFG_VERSION 14

int sim_settings_pack(const sim_settings *cfg, uint8_t *out, int cap) {
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
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            for (int r = 0; r < SIM_MAX_RUNGS; r++) w8(&w, c->trigger[t][r]);
            w16(&w, c->mod_max[t]);
        }
        for (int k = 0; k < SIM_MAX_CHARGES; k++) w8(&w, c->charge_max[k]);
        w8(&w, c->mine_max);
    }

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
    w8(&w, cfg->mine);
    for (int i = 0; i < SIM_PRIZE_COUNT; i++) w16(&w, cfg->prize_weight[i]);
    w16(&w, cfg->rust_chance);
    w16(&w, cfg->spawn_prizes);
    w16(&w, cfg->bounty_per_kill);
    w16(&w, cfg->points_per_flag);
    for (int m = 0; m < SIM_MOD_COUNT; m++) w32(&w, (uint32_t)cfg->mod_step[m]);
    w16(&w, cfg->mod_spread);
    w16(&w, cfg->mod_multi_energy);
    w16(&w, cfg->mod_multi_delay);
    for (int r = 0; r < SIM_MAX_RUNGS; r++) w8(&w, cfg->mod_splinter[r]);
    w32(&w, (uint32_t)cfg->bounce);
    w32(&w, (uint32_t)cfg->friction);
    w16(&w, cfg->respawn_delay);
    w16(&w, cfg->spawn_radius);
    w8(&w, cfg->show_spawns);
    w16(&w, cfg->safe_limit);
    w16(&w, cfg->prize_delay);
    w16(&w, cfg->prize_max);
    w16(&w, cfg->prize_life);
    w16(&w, cfg->door_period);
    w16(&w, cfg->door_open);
    w32(&w, (uint32_t)cfg->wormhole_pull);
    w32(&w, (uint32_t)cfg->wormhole_range);
    w32(&w, (uint32_t)cfg->prize_radius);
    w32(&w, (uint32_t)cfg->prize_lo);
    w32(&w, (uint32_t)cfg->prize_hi);
    w32(&w, (uint32_t)cfg->flag_radius);
    w16(&w, cfg->flag_drop_cooldown);
    w8(&w, cfg->max_ships);

    return w.overflow ? -1 : (int)(w.p - out);
}

int sim_settings_unpack(sim_settings *cfg, const uint8_t *in, int len) {
    rd r = {in, in + len, 0};
    if (r32(&r) != CFG_MAGIC) return -1;
    if (r8(&r) != CFG_VERSION) return -1;

    /* Geometry is not in here and is not ours to clear. */
    const sim_map *map = cfg->map;
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
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            for (int k = 0; k < SIM_MAX_RUNGS; k++)
                c->trigger[t][k] = (uint8_t)r8(&r);
            c->mod_max[t] = (uint16_t)r16(&r);
        }
        for (int k = 0; k < SIM_MAX_CHARGES; k++)
            c->charge_max[k] = (uint8_t)r8(&r);
        c->mine_max = (uint8_t)r8(&r);
    }

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
    cfg->mine = (uint8_t)r8(&r);
    for (int i = 0; i < SIM_PRIZE_COUNT; i++)
        cfg->prize_weight[i] = (uint16_t)r16(&r);
    cfg->rust_chance = (uint16_t)r16(&r);
    cfg->spawn_prizes = (uint16_t)r16(&r);
    cfg->bounty_per_kill = (uint16_t)r16(&r);
    cfg->points_per_flag = (uint16_t)r16(&r);
    for (int m = 0; m < SIM_MOD_COUNT; m++) cfg->mod_step[m] = (int32_t)r32(&r);
    cfg->mod_spread = (uint16_t)r16(&r);
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
    cfg->prize_delay = (uint16_t)r16(&r);
    cfg->prize_max = (uint16_t)r16(&r);
    cfg->prize_life = (uint16_t)r16(&r);
    cfg->door_period = (uint16_t)r16(&r);
    cfg->door_open = (uint16_t)r16(&r);
    cfg->wormhole_pull = (int32_t)r32(&r);
    cfg->wormhole_range = (int32_t)r32(&r);
    cfg->prize_radius = (int32_t)r32(&r);
    cfg->prize_lo = (int32_t)r32(&r);
    cfg->prize_hi = (int32_t)r32(&r);
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
    if (r.underflow || r.p != r.end) return -1;
    return 0;
}

/* ---- maps ---- */

#define MAP_MAGIC 0x564d4150u /* "VMAP" */
#define MAP_VERSION 1

uint32_t sim_map_hash(const sim_map *m) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < sizeof m->tile; i++) {
        h ^= m->tile[i];
        h *= 16777619u;
    }
    return h;
}

int sim_map_pack(const sim_map *m, uint8_t *out, int cap) {
    if (cap < 12) return -1;
    int n = 0;
    uint32_t magic = MAP_MAGIC;
    for (int b = 0; b < 4; b++) out[n++] = (uint8_t)(magic >> (b * 8));
    out[n++] = MAP_VERSION;
    out[n++] = 0; /* reserved */
    uint32_t h = sim_map_hash(m);
    for (int b = 0; b < 4; b++) out[n++] = (uint8_t)(h >> (b * 8));

    size_t total = sizeof m->tile;
    size_t i = 0;
    while (i < total) {
        uint8_t v = m->tile[i];
        size_t run = 1;
        /* 65535 is the longest a run can say, and an empty map is one tile
         * short of 1048576 of them, so long runs simply repeat. */
        while (i + run < total && m->tile[i + run] == v && run < 65535) run++;
        if (n + 3 > cap) return -1;
        out[n++] = (uint8_t)(run & 0xff);
        out[n++] = (uint8_t)(run >> 8);
        out[n++] = v;
        i += run;
    }
    return n;
}

int sim_map_unpack(sim_map *m, const uint8_t *in, int len) {
    if (len < 12) return -1;
    int n = 0;
    uint32_t magic = 0;
    for (int b = 0; b < 4; b++) magic |= (uint32_t)in[n++] << (b * 8);
    if (magic != MAP_MAGIC) return -1;
    if (in[n++] != MAP_VERSION) return -1;
    n++; /* reserved */
    uint32_t want = 0;
    for (int b = 0; b < 4; b++) want |= (uint32_t)in[n++] << (b * 8);

    size_t total = sizeof m->tile;
    size_t i = 0;
    while (n + 3 <= len && i < total) {
        size_t run = (size_t)in[n] | ((size_t)in[n + 1] << 8);
        uint8_t v = in[n + 2];
        n += 3;
        if (run == 0 || i + run > total) return -1;
        memset(m->tile + i, v, run);
        i += run;
    }
    /* A map that stops early is a truncated map, not an empty tail. */
    if (i != total) return -1;
    if (sim_map_hash(m) != want) return -2;
    sim_map_index(m);
    return 0;
}
