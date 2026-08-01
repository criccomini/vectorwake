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
    }

    w16(&w, s->weapon_count);
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *p = &s->weapons[i];
        w8(&w, p->spec);
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
        w8(&w, p->type);
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
    }

    uint32_t weapons = r16(&r);
    if (weapons > SIM_MAX_WEAPONS) return -1;
    s->weapon_count = (uint16_t)weapons;
    for (uint32_t i = 0; i < weapons; i++) {
        sim_weapon *p = &s->weapons[i];
        p->spec = (uint8_t)r8(&r);
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
        p->type = (uint8_t)r8(&r);
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
