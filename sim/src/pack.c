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

int sim_pack(const sim_state *s, uint8_t *out, int cap) {
    wr w = {out, out + cap, 0};

    w32(&w, s->tick);
    w32(&w, s->rng);
    w16(&w, s->prize_timer);

    w8(&w, s->ship_count);
    for (int i = 0; i < s->ship_count; i++) {
        const sim_ship *sh = &s->ships[i];
        w8(&w, (uint32_t)(sh->active | (sh->alive << 1)));
        w8(&w, sh->cls);
        w8(&w, sh->team);
        w32(&w, (uint32_t)sh->x);
        w32(&w, (uint32_t)sh->y);
        w32(&w, (uint32_t)sh->vx);
        w32(&w, (uint32_t)sh->vy);
        w16(&w, sh->heading);
        w32(&w, (uint32_t)sh->energy);
        w16(&w, sh->fire_cooldown);
        w16(&w, sh->respawn_at);
        w32(&w, (uint32_t)sh->spawn_x);
        w32(&w, (uint32_t)sh->spawn_y);
        w16(&w, sh->kills);
        w16(&w, sh->deaths);
        for (int u = 0; u < SIM_UP_COUNT; u++) w8(&w, sh->up[u]);
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            w8(&w, sh->level[t]);
            w16(&w, sh->mods[t]);
        }
    }

    w16(&w, s->weapon_count);
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *p = &s->weapons[i];
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
    }

    uint8_t live = 0;
    for (int i = 0; i < SIM_MAX_PRIZES; i++) live += s->prizes[i].active ? 1 : 0;
    w8(&w, live);
    for (int i = 0; i < SIM_MAX_PRIZES; i++) {
        const sim_prize *p = &s->prizes[i];
        if (!p->active) continue;
        w8(&w, (uint32_t)i);
        w32(&w, (uint32_t)p->x);
        w32(&w, (uint32_t)p->y);
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
    s->prize_timer = (uint16_t)r16(&r);

    uint32_t ships = r8(&r);
    if (ships > SIM_MAX_SHIPS) return -1;
    s->ship_count = (uint8_t)ships;
    for (uint32_t i = 0; i < ships; i++) {
        sim_ship *sh = &s->ships[i];
        uint32_t flags = r8(&r);
        sh->active = (uint8_t)(flags & 1);
        sh->alive = (uint8_t)((flags >> 1) & 1);
        sh->cls = (uint8_t)r8(&r);
        sh->team = (uint8_t)r8(&r);
        sh->x = (int32_t)r32(&r);
        sh->y = (int32_t)r32(&r);
        sh->vx = (int32_t)r32(&r);
        sh->vy = (int32_t)r32(&r);
        sh->heading = (uint16_t)r16(&r);
        sh->energy = (int32_t)r32(&r);
        sh->fire_cooldown = (uint16_t)r16(&r);
        sh->respawn_at = (uint16_t)r16(&r);
        sh->spawn_x = (int32_t)r32(&r);
        sh->spawn_y = (int32_t)r32(&r);
        sh->kills = (uint16_t)r16(&r);
        sh->deaths = (uint16_t)r16(&r);
        for (int u = 0; u < SIM_UP_COUNT; u++) sh->up[u] = (uint8_t)r8(&r);
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            sh->level[t] = (uint8_t)r8(&r);
            sh->mods[t] = (uint16_t)r16(&r);
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
    }

    uint32_t prizes = r8(&r);
    if (prizes > SIM_MAX_PRIZES) return -1;
    for (uint32_t i = 0; i < prizes; i++) {
        uint32_t idx = r8(&r);
        if (idx >= SIM_MAX_PRIZES) return -1;
        sim_prize *p = &s->prizes[idx];
        p->active = 1;
        p->x = (int32_t)r32(&r);
        p->y = (int32_t)r32(&r);
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

    return r.underflow ? -1 : 0;
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
#define CFG_VERSION 3

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
        w32(&w, (uint32_t)c->radius);
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            for (int r = 0; r < SIM_MAX_RUNGS; r++) w8(&w, c->trigger[t][r]);
            w16(&w, c->mod_max[t]);
        }
    }

    w8(&w, cfg->spec_count);
    for (int i = 0; i < cfg->spec_count; i++) {
        const sim_weapon_spec *sp = &cfg->specs[i];
        w32(&w, (uint32_t)sp->speed);
        w16(&w, sp->life);
        w8(&w, sp->on_wall);
        w8(&w, sp->bounces);
        w32(&w, (uint32_t)sp->trigger);
        w8(&w, sp->expire_ends);
        w8(&w, sp->splinter);
        w32(&w, (uint32_t)sp->damage);
        w32(&w, (uint32_t)sp->blast);
        w32(&w, (uint32_t)sp->push);
        w16(&w, sp->stall);
    }

    w8(&w, cfg->pattern_count);
    for (int i = 0; i < cfg->pattern_count; i++) {
        const sim_fire_pattern *p = &cfg->patterns[i];
        w8(&w, p->spec);
        w8(&w, p->count);
        w16(&w, p->spacing);
        w32(&w, (uint32_t)p->energy);
        w16(&w, p->delay);
        w32(&w, (uint32_t)p->recoil);
    }

    for (int i = 0; i < SIM_PRIZE_COUNT; i++) w16(&w, cfg->prize_weight[i]);
    w16(&w, cfg->rust_chance);
    for (int m = 0; m < SIM_MOD_COUNT; m++) w32(&w, (uint32_t)cfg->mod_step[m]);
    w16(&w, cfg->mod_spread);
    for (int r = 0; r < SIM_MAX_RUNGS; r++) w8(&w, cfg->mod_splinter[r]);
    w32(&w, (uint32_t)cfg->bounce);
    w32(&w, (uint32_t)cfg->friction);
    w16(&w, cfg->respawn_delay);
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
        c->radius = (int32_t)r32(&r);
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            for (int k = 0; k < SIM_MAX_RUNGS; k++)
                c->trigger[t][k] = (uint8_t)r8(&r);
            c->mod_max[t] = (uint16_t)r16(&r);
        }
    }

    uint32_t specs = r8(&r);
    if (specs > SIM_MAX_SPECS) return -1;
    cfg->spec_count = (uint8_t)specs;
    for (uint32_t i = 0; i < specs; i++) {
        sim_weapon_spec *sp = &cfg->specs[i];
        sp->speed = (int32_t)r32(&r);
        sp->life = (uint16_t)r16(&r);
        sp->on_wall = (uint8_t)r8(&r);
        sp->bounces = (uint8_t)r8(&r);
        sp->trigger = (int32_t)r32(&r);
        sp->expire_ends = (uint8_t)r8(&r);
        sp->splinter = (uint8_t)r8(&r);
        sp->damage = (int32_t)r32(&r);
        sp->blast = (int32_t)r32(&r);
        sp->push = (int32_t)r32(&r);
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
        p->delay = (uint16_t)r16(&r);
        p->recoil = (int32_t)r32(&r);
    }

    for (int i = 0; i < SIM_PRIZE_COUNT; i++)
        cfg->prize_weight[i] = (uint16_t)r16(&r);
    cfg->rust_chance = (uint16_t)r16(&r);
    for (int m = 0; m < SIM_MOD_COUNT; m++) cfg->mod_step[m] = (int32_t)r32(&r);
    cfg->mod_spread = (uint16_t)r16(&r);
    for (int k = 0; k < SIM_MAX_RUNGS; k++)
        cfg->mod_splinter[k] = (uint8_t)r8(&r);
    cfg->bounce = (int32_t)r32(&r);
    cfg->friction = (int32_t)r32(&r);
    cfg->respawn_delay = (uint16_t)r16(&r);
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

    return r.underflow ? -1 : 0;
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
