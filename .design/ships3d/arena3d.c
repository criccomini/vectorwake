#include "arena3d.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define TILE 16.0f

#define T_EMPTY 0
#define T_SOLID 1
#define T_SAFE 2
#define T_DOOR 3
#define T_GOAL 4
#define T_WORMHOLE 5
#define T_TURF 8
#define T_SPAWN 9
#define T_SLOPE 10

#define S_WALL 0
#define S_BORDER 1
#define S_ROCK_A 2
#define S_ROCK_BODY 5
#define S_STATION 6
#define S_STATION_BODY 7

static v3 srgb3(unsigned hex, float scale) {
    float c[3];
    int i;
    c[0] = (float)((hex >> 16) & 255) / 255.0f;
    c[1] = (float)((hex >> 8) & 255) / 255.0f;
    c[2] = (float)(hex & 255) / 255.0f;
    for (i = 0; i < 3; i++)
        c[i] = c[i] <= 0.04045f ? c[i] / 12.92f : powf((c[i] + 0.055f) / 1.055f, 2.4f);
    return mul(vec(c[0], c[1], c[2]), scale);
}

/* The four rungs a round climbs, from palette.lua. Guns and bombs share the
 * ramp; what tells them apart on screen is size and what they do when they
 * stop, which is also how the game tells them apart. */
static v3 rung(int lvl, float s) {
    static const unsigned R[4] = {0x62cc35, 0xf7dd0b, 0xff7000, 0xf42e3d};
    if (lvl < 0) lvl = 0;
    if (lvl > 3) lvl = 3;
    return srgb3(R[lvl], s);
}

static int tile_at(const capture *c, int tx, int ty) {
    if (tx < 0 || ty < 0 || tx >= c->mw || ty >= c->mh) return T_SOLID;
    return c->tile[ty * c->mw + tx];
}

static int cls_at(const capture *c, int tx, int ty) { return tile_at(c, tx, ty) & 0x0f; }

/* Does this tile stop a hull, and so need a face drawn against open ground?
 * A slope stops one too, but only over half its square, so it is not allowed
 * to hide its neighbor's face. */
static int blocks(const capture *c, int tx, int ty) {
    int k = cls_at(c, tx, ty);
    return k == T_SOLID || k == T_DOOR;
}

typedef struct {
    int body, top, rim, door;
} terrain_mats;

static terrain_mats terrain_palette(mesh *m) {
    terrain_mats t;
    material mt;
    /* Flat fills, straight out of palette.lua. A wall's body is darker than it
     * looks and the light near an open face brings it back up: one slate all
     * the way through has no thickness in it, near black at the core with a
     * lit rim does. That rule was written for the flat client and it is the
     * same rule here, with the rim now an edge somebody can be behind. */
    mt.rough = 0.9f;
    mt.metal = 0.0f;
    mt.emit = vec(0, 0, 0);
    mt.albedo = srgb3(0x080d16, 1.0f);
    t.body = mesh_material(m, mt);
    mt.albedo = srgb3(0x141f31, 1.0f);
    t.top = mesh_material(m, mt);
    mt.albedo = srgb3(0x22344f, 0.6f);
    t.rim = mesh_material(m, mt);
    mt.albedo = srgb3(0x081611, 1.0f);
    mt.emit = srgb3(0x35e0a0, 0.16f);
    t.door = mesh_material(m, mt);
    return t;
}

/* A box, with only the faces that face open ground. Drawing all six of every
 * tile in a wall twenty tiles long is a hundred thousand triangles nobody can
 * see, and the inside faces z-fight each other besides. */
static void wall_tile(mesh *m, const capture *c, int tx, int ty, terrain_mats mt,
                      glow_line **ln, int *lnn, int *lncap) {
    float x0 = (float)tx * TILE, x1 = x0 + TILE;
    float y1 = -(float)ty * TILE, y0 = y1 - TILE;
    float zt = WALL_TOP, zb = -WALL_TOP;
    int door = cls_at(c, tx, ty) == T_DOOR;
    int side = door ? mt.door : mt.body;
    int face = door ? mt.door : mt.top;
    v3 lit = srgb3(0x5b82b8, door ? 0.0f : 1.9f);
    if (door) lit = srgb3(0x35e0a0, 2.2f);

    mesh_quad(m, vec(x0, y0, zt), vec(x1, y0, zt), vec(x1, y1, zt), vec(x0, y1, zt), face);
    mesh_quad(m, vec(x0, y1, zb), vec(x1, y1, zb), vec(x1, y0, zb), vec(x0, y0, zb), side);
    if (!blocks(c, tx, ty - 1)) {  /* north face, toward +y in world */
        mesh_quad(m, vec(x0, y1, zb), vec(x1, y1, zb), vec(x1, y1, zt), vec(x0, y1, zt), side);
        if (*lnn + 1 > *lncap) { *lncap = *lncap ? *lncap * 2 : 256;
            *ln = realloc(*ln, (size_t)*lncap * sizeof **ln); }
        (*ln)[*lnn].a = vec(x0, y1, zt); (*ln)[*lnn].b = vec(x1, y1, zt);
        (*ln)[*lnn].col = lit; (*ln)[(*lnn)++].width = 0.13f;
    }
    if (!blocks(c, tx, ty + 1)) {
        mesh_quad(m, vec(x1, y0, zb), vec(x0, y0, zb), vec(x0, y0, zt), vec(x1, y0, zt), side);
        if (*lnn + 1 > *lncap) { *lncap = *lncap ? *lncap * 2 : 256;
            *ln = realloc(*ln, (size_t)*lncap * sizeof **ln); }
        (*ln)[*lnn].a = vec(x0, y0, zt); (*ln)[*lnn].b = vec(x1, y0, zt);
        (*ln)[*lnn].col = lit; (*ln)[(*lnn)++].width = 0.13f;
    }
    if (!blocks(c, tx - 1, ty)) {
        mesh_quad(m, vec(x0, y0, zb), vec(x0, y1, zb), vec(x0, y1, zt), vec(x0, y0, zt), side);
        if (*lnn + 1 > *lncap) { *lncap = *lncap ? *lncap * 2 : 256;
            *ln = realloc(*ln, (size_t)*lncap * sizeof **ln); }
        (*ln)[*lnn].a = vec(x0, y0, zt); (*ln)[*lnn].b = vec(x0, y1, zt);
        (*ln)[*lnn].col = lit; (*ln)[(*lnn)++].width = 0.13f;
    }
    if (!blocks(c, tx + 1, ty)) {
        mesh_quad(m, vec(x1, y1, zb), vec(x1, y0, zb), vec(x1, y0, zt), vec(x1, y1, zt), side);
        if (*lnn + 1 > *lncap) { *lncap = *lncap ? *lncap * 2 : 256;
            *ln = realloc(*ln, (size_t)*lncap * sizeof **ln); }
        (*ln)[*lnn].a = vec(x1, y0, zt); (*ln)[*lnn].b = vec(x1, y1, zt);
        (*ln)[*lnn].col = lit; (*ln)[(*lnn)++].width = 0.13f;
    }
}

/* Half a wall, cut corner to corner. The variant names the corner that stays
 * solid, so the face is the diagonal opposite it, and that face is the whole
 * reason slopes exist: it turns a velocity instead of reversing one. */
static void slope_tile(mesh *m, int tx, int ty, int var, terrain_mats mt,
                       glow_line **ln, int *lnn, int *lncap) {
    float x0 = (float)tx * TILE, x1 = x0 + TILE;
    float y1 = -(float)ty * TILE, y0 = y1 - TILE;
    v3 nw = vec(x0, y1, 0), ne = vec(x1, y1, 0), se = vec(x1, y0, 0), sw = vec(x0, y0, 0);
    v3 a, b, cc;
    int i;
    v3 lit = srgb3(0x5b82b8, 1.9f);
    switch (var) {
        case 0: a = nw; b = ne; cc = sw; break;
        case 1: a = ne; b = se; cc = nw; break;
        case 2: a = se; b = sw; cc = ne; break;
        default: a = sw; b = nw; cc = se; break;
    }
    {
        v3 at = vec(a.x, a.y, WALL_TOP), bt = vec(b.x, b.y, WALL_TOP);
        v3 ct = vec(cc.x, cc.y, WALL_TOP);
        v3 ab = vec(a.x, a.y, -WALL_TOP), bb = vec(b.x, b.y, -WALL_TOP);
        v3 cb = vec(cc.x, cc.y, -WALL_TOP);
        v3 tri[3];
        mesh_face(m, at, bt, ct, mt.top);
        mesh_face(m, ab, cb, bb, mt.body);
        mesh_quad(m, ab, bb, bt, at, mt.body);
        mesh_quad(m, bb, cb, ct, bt, mt.body);
        mesh_quad(m, cb, ab, at, ct, mt.body);
        tri[0] = at; tri[1] = bt; tri[2] = ct;
        for (i = 0; i < 3; i++) {
            if (*lnn + 1 > *lncap) { *lncap = *lncap ? *lncap * 2 : 256;
                *ln = realloc(*ln, (size_t)*lncap * sizeof **ln); }
            (*ln)[*lnn].a = tri[i];
            (*ln)[*lnn].b = tri[(i + 1) % 3];
            (*ln)[*lnn].col = lit;
            (*ln)[(*lnn)++].width = 0.13f;
        }
    }
}

/* Ground that is not a wall but is still a place: a safe zone, a spawn, a
 * wormhole. Drawn as a plate under the ships, since a mark on nothing has
 * nowhere to be. */
static void ground_mark(mesh *m, int tx, int ty, int kind, int var, int mat) {
    float x0 = (float)tx * TILE + 1.0f, x1 = x0 + TILE - 2.0f;
    float y1 = -(float)ty * TILE - 1.0f, y0 = y1 - TILE + 2.0f;
    float z = -WALL_TOP + 0.6f;
    (void)kind;
    (void)var;
    mesh_quad(m, vec(x0, y0, z), vec(x1, y0, z), vec(x1, y1, z), vec(x0, y1, z), mat);
}

static int mark_material(mesh *m, unsigned hex, float emit) {
    material mt;
    mt.albedo = srgb3(hex, 0.25f);
    mt.emit = srgb3(hex, emit);
    mt.rough = 0.8f;
    mt.metal = 0.1f;
    return mesh_material(m, mt);
}

static void build_arena(const capture *c, mesh *m, glow_line **ln, int *lnn,
                        float cx, float cy, float half) {
    terrain_mats mt = terrain_palette(m);
    int safe_m = mark_material(m, 0x1d5f63, 0.30f);
    int spawn_m = mark_material(m, 0x2a3a58, 0.16f);
    int hole_m = mark_material(m, 0xa06bff, 0.40f);
    int turf_m = mark_material(m, 0xc78346, 0.22f);
    int lncap = 0, tx, ty;
    int tx0 = (int)((cx - half) / TILE) - 1, tx1 = (int)((cx + half) / TILE) + 1;
    int ty0 = (int)((-cy - half) / TILE) - 1, ty1 = (int)((-cy + half) / TILE) + 1;
    *ln = NULL;
    *lnn = 0;
    if (tx0 < 0) tx0 = 0;
    if (ty0 < 0) ty0 = 0;
    if (tx1 > c->mw - 1) tx1 = c->mw - 1;
    if (ty1 > c->mh - 1) ty1 = c->mh - 1;
    for (ty = ty0; ty <= ty1; ty++) {
        for (tx = tx0; tx <= tx1; tx++) {
            int t = tile_at(c, tx, ty);
            int k = t & 0x0f, var = t >> 4;
            switch (k) {
                case T_SOLID:
                case T_DOOR: wall_tile(m, c, tx, ty, mt, ln, lnn, &lncap); break;
                case T_SLOPE: slope_tile(m, tx, ty, var, mt, ln, lnn, &lncap); break;
                case T_SAFE: ground_mark(m, tx, ty, k, var, safe_m); break;
                case T_SPAWN: ground_mark(m, tx, ty, k, var, spawn_m); break;
                case T_WORMHOLE: ground_mark(m, tx, ty, k, var, hole_m); break;
                case T_TURF:
                case T_GOAL: ground_mark(m, tx, ty, k, var, turf_m); break;
                default: break;
            }
        }
    }
}

/* --- the frame ------------------------------------------------------------ */

static v3 ship_pos(const cap_ship *s) {
    return vec((float)s->x / 256.0f, -(float)s->y / 256.0f, 0.0f);
}

static unsigned srng = 7u;
static float sfrand(void) {
    srng = srng * 1664525u + 1013904223u;
    return (float)((srng >> 8) & 0xffffff) / (float)0x1000000;
}

unsigned char *battle_frame(const capture *c, const hull3d *hulls, shot_opts o) {
    target *t = target_new(o.width, o.height, 0);
    mesh arena;
    glow_line *arena_lines = NULL, *lines = NULL;
    int arena_ln = 0, line_n = 0, line_cap = 0;
    point_light lights[48];
    int light_n = 0;
    scene_light lit;
    mat4 proj, view, vp;
    v3 eye, focus;
    unsigned char *rgb;
    float focal, half;
    int i, k;
    const cap_ship *ships = c->ships[o.frame];
    const cap_shot *shots = c->shots[o.frame];

    focus = vec(o.cam.x, o.cam.y, 0.0f);
    half = o.cam.dist * tanf(o.cam.fov * (float)M_PI / 360.0f) * 1.7f
         + 0.5f * (float)o.width / (float)o.height * o.cam.dist
           * tanf(o.cam.fov * (float)M_PI / 360.0f);
    mesh_init(&arena);
    build_arena(c, &arena, &arena_lines, &arena_ln, focus.x, focus.y, half);
    mesh_smooth(&arena, 20.0f);

    focal = (float)o.height * 0.5f / tanf(o.cam.fov * (float)M_PI / 360.0f);
    proj = mat_perspective(o.cam.fov, (float)o.width / (float)o.height, 2.0f, 6000.0f);
    eye = add(focus, vec(o.cam.dist * cosf(o.cam.tilt) * sinf(o.cam.turn),
                         -o.cam.dist * cosf(o.cam.tilt) * cosf(o.cam.turn),
                         o.cam.dist * sinf(o.cam.tilt)));
    view = mat_look(eye, focus, vec(0, 0, 1));
    vp = mat_mul(proj, view);

    memset(&lit, 0, sizeof lit);
    lit.flat = 1;

    /* What is on fire this tick, as light. A bomb going off should light the
     * wall beside it, and a tracer should put a moving spot on the floor of a
     * corridor, or the arena is a diagram with sprites on top. */
    for (i = 0; i < c->shot_n[o.frame] && light_n < 40; i++) {
        const cap_shot *w = &shots[i];
        v3 p = vec((float)w->x / 256.0f, -(float)w->y / 256.0f, 0.0f);
        int kind = c->spec_kind[w->spec];
        if (fabsf(p.x - focus.x) > half || fabsf(p.y - focus.y) > half) continue;
        lights[light_n].pos = add(p, vec(0, 0, 1.5f));
        lights[light_n].col = rung(w->level, kind == 1 ? 0.85f : 0.42f);
        lights[light_n].reach = kind == 1 ? 46.0f : 26.0f;
        light_n++;
    }

    target_clear(t, srgb3(0x05070c, 1.0f));
    /* Stars, behind everything, at the depth the walls hang in. */
    srng = 4919u;
    for (i = 0; i < 1400; i++) {
        float sx = focus.x + (sfrand() - 0.5f) * half * 6.0f;
        float sy = focus.y + (sfrand() - 0.5f) * half * 6.0f;
        float b = sfrand();
        v3 col = srgb3(b > 0.94f ? 0x93a9c8 : (b > 0.62f ? 0x4a6089 : 0x2a3a58),
                       0.35f + b * 1.1f);
        draw_sprite(t, vec(sx, sy, -260.0f - b * 420.0f), 2.0f + b * 3.0f, col,
                    2.4f, vp, eye, 1);
    }

    draw_mesh(t, &arena, mat_identity(), vp, eye, &lit);

    for (i = 0; i < c->ship_n[o.frame]; i++) {
        const cap_ship *s = &ships[i];
        const hull3d *h = &hulls[(s->team & 1) * 7 + s->cls % 7];
        mat4 model;
        if (!s->alive) continue;
        model = mat_trs(ship_pos(s), (float)s->heading / 65536.0f, 1.0f);
        draw_mesh(t, &h->body, model, vp, eye, &lit);
        for (k = 0; k < h->line_n; k++) {
            if (line_n + 1 > line_cap) {
                line_cap = line_cap ? line_cap * 2 : 512;
                lines = realloc(lines, (size_t)line_cap * sizeof *lines);
            }
            lines[line_n] = h->lines[k];
            lines[line_n].a = mat_apply(model, h->lines[k].a);
            lines[line_n].b = mat_apply(model, h->lines[k].b);
            line_n++;
        }
    }
    draw_lines(t, arena_lines, arena_ln, vp, eye, focal);
    draw_lines(t, lines, line_n, vp, eye, focal);

    /* Engine trails, read back off the record rather than simulated here: the
     * ship was at these places on these ticks and the plume left from its own
     * jets each time. */
    for (k = 1; k <= o.trail_frames && o.frame - k >= 0; k++) {
        int f = o.frame - k;
        float fade = 1.0f - (float)k / (float)(o.trail_frames + 1);
        for (i = 0; i < c->ship_n[f] && i < c->ship_n[o.frame]; i++) {
            const cap_ship *s = &c->ships[f][i];
            const hull3d *h = &hulls[(s->team & 1) * 7 + s->cls % 7];
            mat4 model;
            int j;
            if (!s->alive || !s->thrust) continue;
            model = mat_trs(ship_pos(s), (float)s->heading / 65536.0f, 1.0f);
            for (j = 0; j < h->jet_n; j++) {
                v3 p = mat_apply(model, add(h->jets[j], vec(0, -1.2f, 0)));
                v3 q = p;
                v3 col = mul(srgb3(0xffbe78, 1.0f), fade * fade * 0.42f);
                int step;
                if (k > o.trail_frames / 3)
                    col = mul(srgb3(0xff7a3c, 1.0f), fade * fade * 0.38f);
                if (f + 1 <= o.frame && i < c->ship_n[f + 1]
                    && c->ships[f + 1][i].alive) {
                    const cap_ship *nx = &c->ships[f + 1][i];
                    q = mat_apply(mat_trs(ship_pos(nx),
                                          (float)nx->heading / 65536.0f, 1.0f),
                                  add(h->jets[j], vec(0, -1.2f, 0)));
                }
                for (step = 0; step < 3; step++) {
                    v3 r2 = add(p, mul(sub(q, p), (float)step / 3.0f));
                    draw_sprite(t, r2, 1.15f + (float)k * 0.30f, mul(col, 0.62f),
                                2.4f, vp, eye, 1);
                }
            }
        }
    }

    /* Rounds in the air. A bullet is drawn as the length it covers in a couple
     * of ticks, because that is what it looks like and because a dot moving at
     * thirty pixels a tick is a dot nobody can follow. */
    for (i = 0; i < c->shot_n[o.frame]; i++) {
        const cap_shot *w = &shots[i];
        v3 p = vec((float)w->x / 256.0f, -(float)w->y / 256.0f, 0.0f);
        /* Velocity is Q16 px per tick, unlike the Q8 positions beside it:
         * a weapon takes its speed from its spec, and a spec's speed is
         * Q16. Reading it as Q8 drew every tracer as a streak two hundred
         * and fifty pixels long. */
        v3 v = vec((float)w->vx / 65536.0f, -(float)w->vy / 65536.0f, 0.0f);
        int kind = c->spec_kind[w->spec];
        /* A round has to be findable at the distance the game is played
         * from, so these are drawn nearer the size the flat client draws
         * them than the size the collision box says. */
        float sz = kind == 1 ? 3.4f : (kind == 2 ? 3.0f : 2.0f);
        v3 col = rung(w->level, kind == 1 ? 3.0f : 2.4f);
        int s;
        if (fabsf(p.x - focus.x) > half * 1.2f || fabsf(p.y - focus.y) > half * 1.2f)
            continue;
        if (kind == 2) {
            /* A mine sits still and blinks; it is the one round that is a
             * place rather than a line. */
            draw_sprite(t, p, sz * 2.4f, mul(col, 0.35f), 2.6f, vp, eye, 1);
            draw_sprite(t, p, sz, col, 2.0f, vp, eye, 1);
            continue;
        }
        for (s = 0; s < 10; s++) {
            float u = (float)s / 9.0f;
            v3 q = add(p, mul(v, -u * 3.2f));
            draw_sprite(t, q, sz * (1.0f - u * 0.6f),
                        mul(col, (1.0f - u) * (1.0f - u) * 1.3f), 2.2f, vp, eye, 1);
        }
        draw_sprite(t, p, sz * 3.4f, mul(col, 0.30f), 3.0f, vp, eye, 1);
    }

    /* Explosions. Every one of these is an event the core raised: a bomb that
     * stopped existing, or a pilot who did. The age is how many ticks ago,
     * which is what decides how far the front has travelled. */
    for (k = 0; k <= 46 && o.frame - k >= 0; k++) {
        int f = o.frame - k;
        float age = (float)k;
        for (i = 0; i < c->ev_n[f]; i++) {
            const cap_ev *e = &c->evs[f][i];
            float blast, u, r;
            v3 p, col;
            int s;
            if (e->type == EV_EXPIRE) {
                blast = (float)c->spec_blast[e->a] / 256.0f;
                if (blast < 1.0f) {
                    if (k > 4) continue;
                    p = vec((float)(e->v >> 14), -(float)(e->v & 0x3fff), 0.0f);
                    draw_sprite(t, p, 2.6f - (float)k * 0.5f,
                                srgb3(0xffd9a0, 1.6f - (float)k * 0.3f), 2.2f, vp, eye, 1);
                    continue;
                }
                p = vec((float)(e->v >> 14), -(float)(e->v & 0x3fff), 0.0f);
            } else if (e->type == EV_DEATH) {
                if (e->a >= c->ship_n[f]) continue;
                p = ship_pos(&c->ships[f][e->a]);
                blast = 26.0f;
            } else {
                continue;
            }
            u = age / 30.0f;
            if (u > 1.0f) continue;
            r = blast * (0.30f + 0.85f * powf(u, 0.55f));
            col = add(mul(srgb3(0xfff2d0, 1.0f), (1.0f - u) * (1.0f - u) * 7.0f),
                      mul(srgb3(0xff5a28, 1.0f), (1.0f - u) * 2.6f));
            draw_sprite(t, p, r * 0.34f, col, 1.7f, vp, eye, 0);
            draw_sprite(t, p, r * 0.95f, mul(col, 0.30f), 3.4f, vp, eye, 0);
            /* The front, as a ring of light rather than a filled ball: the
             * blast in this game is a radius, and a radius has an edge. Drawn
             * as segments rather than as a necklace of sprites, which is what
             * a ring of blobs actually looks like. */
            {
                glow_line ring[32];
                int e;
                for (e = 0; e < 32; e++) {
                    float a0 = (float)e / 32.0f * 6.2831853f;
                    float a1 = (float)(e + 1) / 32.0f * 6.2831853f;
                    ring[e].a = add(p, vec(cosf(a0) * r, sinf(a0) * r, 0.0f));
                    ring[e].b = add(p, vec(cosf(a1) * r, sinf(a1) * r, 0.0f));
                    ring[e].col = mul(srgb3(0xffc478, 1.0f),
                                      (1.0f - u) * (1.0f - u) * 3.2f);
                    ring[e].width = 0.10f + 0.5f * (1.0f - u);
                }
                draw_lines(t, ring, 32, vp, eye, focal);
                for (e = 0; e < 32; e++) {
                    float a0 = (float)e / 32.0f * 6.2831853f;
                    float a1 = (float)(e + 1) / 32.0f * 6.2831853f;
                    float rr = r * 0.62f;
                    ring[e].a = add(p, vec(cosf(a0) * rr, sinf(a0) * rr, 0.0f));
                    ring[e].b = add(p, vec(cosf(a1) * rr, sinf(a1) * rr, 0.0f));
                    ring[e].col = mul(srgb3(0xff7a3c, 1.0f), (1.0f - u) * 2.2f);
                    ring[e].width = 0.08f + 0.7f * (1.0f - u);
                }
                draw_lines(t, ring, 32, vp, eye, focal);
            }
        }
    }

    rgb = resolve(t, 0.9f, 10.0f, 2.2f);
    mesh_free(&arena);
    free(arena_lines);
    free(lines);
    target_free(t);
    return rgb;
}
