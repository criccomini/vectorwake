/* Renders the mocks. See README.md for what each subcommand is for. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "arena3d.h"
#include "battle.h"
#include "hull3d.h"
#include "png.h"
#include "r3.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Straight out of client/arena/palette.lua, converted to linear light, since
 * a palette picked on a screen is in gamma space and shading is not. */
static v3 srgb(unsigned hex, float scale) {
    float c[3];
    int i;
    c[0] = (float)((hex >> 16) & 255) / 255.0f;
    c[1] = (float)((hex >> 8) & 255) / 255.0f;
    c[2] = (float)(hex & 255) / 255.0f;
    for (i = 0; i < 3; i++)
        c[i] = c[i] <= 0.04045f ? c[i] / 12.92f : powf((c[i] + 0.055f) / 1.055f, 2.4f);
    return mul(vec(c[0], c[1], c[2]), scale);
}

#define COL_FRIEND 0x4fd6ff
#define COL_ENEMY  0xffa552
#define COL_BG     0x05070c

static unsigned rng = 12345u;
static float frand(void) {
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xffffff) / (float)0x1000000;
}

/* A field of stars behind everything, drawn as additive points at the far
 * plane so they sit behind geometry without a depth test. */
static void stars(target *t, mat4 vp, int n, float spread, float dist) {
    int i;
    rng = 99173u;
    for (i = 0; i < n; i++) {
        float x = (frand() - 0.5f) * spread;
        float y = (frand() - 0.5f) * spread;
        float b = frand();
        v3 c = srgb(b > 0.93f ? 0x93a9c8 : (b > 0.6f ? 0x4a6089 : 0x2a3a58),
                    0.5f + b * 1.4f);
        draw_sprite(t, vec(x, y, -dist), 0.9f + b * 1.6f, c, 2.2f, vp, vec(0, 0, 0), 0);
    }
}

/* There is no light in this scene, and that is the point. The client draws
 * flat fills with the light baked into the face at build time, from the hull's
 * own nose, and a 3D hull that picks up a world light stops being a drawing of
 * this game. */
static void hero_light(scene_light *lit, v3 team) {
    (void)team;
    memset(lit, 0, sizeof *lit);
    lit->flat = 1;
}

/* The plume a running engine leaves, drawn off the model's own jet mouths. */
static void plume(target *t, const hull3d *h, mat4 model, mat4 vp, float power) {
    int i, s;
    for (i = 0; i < h->jet_n; i++) {
        for (s = 0; s < 26; s++) {
            float u = (float)s / 25.0f;
            v3 p = mat_apply(model, add(h->jets[i], vec(0, -u * 7.0f * power, 0)));
            float fade = (1.0f - u) * (1.0f - u) * 0.42f;
            v3 c = mul(srgb(0xffbe78, 1.0f), fade * 1.7f * power);
            if (u > 0.45f) c = add(mul(c, 0.6f), mul(srgb(0xff7a3c, 1.0f), fade * 0.8f));
            draw_sprite(t, p, 0.55f + u * 1.9f, c, 2.4f, vp, vec(0, 0, 0), 1);
        }
    }
}

static void draw_hull(target *t, const hull3d *h, mat4 model, mat4 vp, v3 eye,
                      const scene_light *lit, float focal) {
    glow_line *ln = malloc((size_t)h->line_n * sizeof *ln);
    int i;
    draw_mesh(t, &h->body, model, vp, eye, lit);
    for (i = 0; i < h->line_n; i++) {
        ln[i] = h->lines[i];
        ln[i].a = mat_apply(model, h->lines[i].a);
        ln[i].b = mat_apply(model, h->lines[i].b);
    }
    draw_lines(t, ln, h->line_n, vp, eye, focal);
    free(ln);
}

/* --- the roster sheet -----------------------------------------------------
 *
 * Seven tiles, each rendered with its own camera at its own distance, so a
 * Chord and a Cipher are the same size on the page whatever their plans are.
 * One camera for the lot put the wide hulls off the edge and the narrow ones
 * in the middle of nothing. */

static void blit(unsigned char *dst, int dw, int dh, const unsigned char *src,
                 int sw, int sh, int x0, int y0) {
    int x, y;
    for (y = 0; y < sh; y++) {
        int dy = y0 + y;
        if (dy < 0 || dy >= dh) continue;
        for (x = 0; x < sw; x++) {
            int dx = x0 + x;
            if (dx < 0 || dx >= dw) continue;
            memcpy(dst + ((size_t)dy * dw + dx) * 3, src + ((size_t)y * sw + x) * 3, 3);
        }
    }
}

/* One hull, framed to fill its tile. */
static unsigned char *tile(int cls, int tw, int th, float tilt, float yaw,
                           int enemy, float fill, int burn) {
    target *t = target_new(tw, th, 0);
    mat4 proj, view, vp, model;
    scene_light lit;
    v3 team = srgb(enemy ? COL_ENEMY : COL_FRIEND, 1.0f);
    hull3d h;
    unsigned char *rgb;
    float fov = 24.0f;
    float focal = (float)th * 0.5f / tanf((float)(fov * M_PI / 360.0));
    float span, dist;

    hull3d_build(&h, cls, team);
    span = fmaxf(h.beam, h.nose + h.tail);
    dist = span / fill * 0.5f / tanf((float)(fov * M_PI / 360.0));
    hero_light(&lit, team);
    target_clear(t, srgb(COL_BG, 1.0f));
    proj = mat_perspective(fov, (float)tw / (float)th, 1.0f, 4000.0f);
    {
        v3 eye = vec(0.0f, -dist * cosf(tilt), dist * sinf(tilt));
        view = mat_look(eye, vec(0, 0, 1.2f), vec(0, 0, 1));
        vp = mat_mul(proj, view);
        stars(t, vp, 420, dist * 4.0f, dist * 5.0f);
        model = mat_trs(vec(0, 0, 0), yaw, 1.0f);
        draw_hull(t, &h, model, vp, eye, &lit, focal);
        if (burn) plume(t, &h, model, vp, 0.9f);
    }
    rgb = resolve(t, 0.85f, 8.0f, 2.2f);
    hull3d_free(&h);
    target_free(t);
    return rgb;
}

static int cmd_sheet(const char *out, int width, int height, float tilt,
                     float yaw, int alt_team) {
    const int cols = 4, rows = 2;
    int tw = width / cols, th = height / rows;
    unsigned char *page = calloc((size_t)width * height * 3, 1);
    int i;
    /* The eighth tile of a seven hull roster: fill the page with the arena's
     * own black first so the gap is background rather than a hole. */
    {
        target *bg = target_new(4, 4, 0);
        unsigned char *px;
        target_clear(bg, srgb(COL_BG, 1.0f));
        px = resolve(bg, 0.0f, 2.0f, 2.2f);
        for (i = 0; i < width * height; i++) memcpy(page + (size_t)i * 3, px, 3);
        free(px);
        target_free(bg);
    }
    for (i = 0; i < hull3d_count(); i++) {
        unsigned char *px = tile(i, tw, th, tilt, yaw, alt_team && (i % 2), 0.74f, 1);
        blit(page, width, height, px, tw, th, (i % cols) * tw, (i / cols) * th);
        free(px);
    }
    png_write(out, page, width, height);
    free(page);
    return 0;
}

static int cmd_one(const char *out, int cls, int width, int height, float tilt,
                   float yaw, int enemy) {
    target *t = target_new(width, height, 0);
    mat4 proj, view, vp, model;
    scene_light lit;
    v3 eye, team = srgb(enemy ? COL_ENEMY : COL_FRIEND, 1.0f);
    hull3d h;
    unsigned char *rgb;
    float focal = (float)height * 0.5f / tanf((float)(26.0 * M_PI / 360.0));
    float dist = 96.0f;

    hull3d_build(&h, cls, team);
    hero_light(&lit, team);
    target_clear(t, srgb(COL_BG, 1.0f));
    proj = mat_perspective(26.0f, (float)width / (float)height, 1.0f, 4000.0f);
    eye = vec(0.0f, -dist * cosf(tilt), dist * sinf(tilt));
    view = mat_look(eye, vec(0, 0, 1.0f), vec(0, 0, 1));
    vp = mat_mul(proj, view);
    stars(t, vp, 700, 700.0f, 700.0f);
    model = mat_trs(vec(0, 0, 0), yaw, 1.0f);
    shadow_begin(t, mat_mul(mat_ortho(-40, 40, -40, 40, -80, 160),
                            mat_look(mul(lit.dir, 80.0f), vec(0, 0, 0), vec(0, 0, 1))));
    shadow_mesh(t, &h.body, model);
    draw_hull(t, &h, model, vp, eye, &lit, focal);
    plume(t, &h, model, vp, 0.9f);
    rgb = resolve(t, 0.85f, 9.0f, 2.2f);
    png_write(out, rgb, width, height);
    free(rgb);
    hull3d_free(&h);
    target_free(t);
    return 0;
}

static int cmd_obj(const char *dir) {
    int i;
    for (i = 0; i < hull3d_count(); i++) {
        char path[512];
        hull3d h;
        hull3d_build(&h, i, vec(1, 1, 1));
        snprintf(path, sizeof path, "%s/%s.obj", dir, hull3d_name(i));
        if (!mesh_write_obj(&h.body, path, hull3d_name(i))) {
            fprintf(stderr, "cannot write %s\n", path);
            return 1;
        }
        printf("%-8s %5d tris  %5.1f x %5.1f x %4.1f px\n", hull3d_name(i),
               h.body.tn, h.beam, h.nose + h.tail, h.height * 2.0f);
        hull3d_free(&h);
    }
    return 0;
}


/* --- battles --------------------------------------------------------------
 *
 * The capture is a real fight: `vectorwake-server battlecap` flies the arena's
 * own brains on one of the zone's own maps and writes down every tick. What is
 * chosen here is only where to point a camera. */

/* Where the fight is at this tick, and how good a picture it would make.
 *
 * The densest knot of hulls that has both sides in it, weighted by what is in
 * the air around it and by whether there is any architecture nearby: a
 * four-way in an empty room is a fight, and a fight in a corridor is a
 * picture. The centroid of everybody is the wrong answer, since the centroid
 * of two fights on opposite sides of a map is the corridor between them.
 */
typedef struct {
    float x, y;
    float spread;
    int ships, foes, shots, deaths;
    float walls;
    float score;
} moment;

static float wall_density(const capture *c, float wx, float wy, float px) {
    int tx0 = (int)((wx - px) / 16.0f), tx1 = (int)((wx + px) / 16.0f);
    int ty0 = (int)((-wy - px) / 16.0f), ty1 = (int)((-wy + px) / 16.0f);
    int solid = 0, all = 0, tx, ty;
    for (ty = ty0; ty <= ty1; ty++) {
        for (tx = tx0; tx <= tx1; tx++) {
            int t;
            if (tx < 0 || ty < 0 || tx >= c->mw || ty >= c->mh) continue;
            t = c->tile[ty * c->mw + tx] & 0x0f;
            all++;
            if (t == 1 || t == 3 || t == 10) solid++;
        }
    }
    return all ? (float)solid / (float)all : 0.0f;
}

static moment find_action(const capture *c, int f) {
    moment best;
    const cap_ship *s = c->ships[f];
    int i, j, k;
    memset(&best, 0, sizeof best);
    best.score = -1e9f;
    best.x = (float)c->mw * 8.0f;
    best.y = -(float)c->mh * 8.0f;
    best.spread = 200.0f;
    for (i = 0; i < c->ship_n[f]; i++) {
        moment m;
        float sx = 0.0f, sy = 0.0f;
        if (!s[i].alive) continue;
        memset(&m, 0, sizeof m);
        for (j = 0; j < c->ship_n[f]; j++) {
            float dx, dy, d;
            if (!s[j].alive) continue;
            dx = (float)(s[j].x - s[i].x) / 256.0f;
            dy = (float)(s[j].y - s[i].y) / 256.0f;
            d = sqrtf(dx * dx + dy * dy);
            if (d > 250.0f) continue;
            sx += (float)s[j].x / 256.0f;
            sy += -(float)s[j].y / 256.0f;
            if (d > m.spread) m.spread = d;
            if (s[j].team != s[i].team) m.foes++;
            m.ships++;
        }
        if (!m.ships) continue;
        m.x = sx / (float)m.ships;
        m.y = sy / (float)m.ships;
        for (j = 0; j < c->shot_n[f]; j++) {
            float dx = (float)c->shots[f][j].x / 256.0f - m.x;
            float dy = -(float)c->shots[f][j].y / 256.0f - m.y;
            if (dx * dx + dy * dy < 240.0f * 240.0f) m.shots++;
        }
        /* A death still coming apart is the frame worth having. */
        for (k = 0; k < 26 && f - k >= 0; k++) {
            int e;
            for (e = 0; e < c->ev_n[f - k]; e++) {
                const cap_ev *ev = &c->evs[f - k][e];
                float dx, dy;
                if (ev->type != EV_DEATH || ev->a >= c->ship_n[f - k]) continue;
                dx = (float)c->ships[f - k][ev->a].x / 256.0f - m.x;
                dy = -(float)c->ships[f - k][ev->a].y / 256.0f - m.y;
                if (dx * dx + dy * dy < 260.0f * 260.0f) m.deaths++;
            }
        }
        m.walls = wall_density(c, m.x, m.y, 190.0f);
        m.score = 34.0f * (float)m.ships + 46.0f * (float)(m.foes > 0)
                + 2.6f * (float)m.shots + 70.0f * (float)m.deaths
                + 190.0f * fminf(m.walls, 0.34f) - 0.32f * m.spread;
        if (m.score > best.score) best = m;
    }
    return best;
}

static int cmd_pick(const char *path, int top) {
    capture *c = cap_load(path);
    moment *mm;
    int f, i, *order;
    if (!c) { fprintf(stderr, "cannot read %s\n", path); return 1; }
    mm = malloc((size_t)c->frames * sizeof *mm);
    order = malloc((size_t)c->frames * sizeof *order);
    for (f = 0; f < c->frames; f++) {
        mm[f] = find_action(c, f);
        order[f] = f;
    }
    for (i = 0; i < top && i < c->frames; i++) {
        int b = i, j;
        for (j = i + 1; j < c->frames; j++)
            if (mm[order[j]].score > mm[order[b]].score) b = j;
        { int tmp = order[i]; order[i] = order[b]; order[b] = tmp; }
        /* Keep the list from being one moment listed twenty times. */
        for (j = i + 1; j < c->frames; j++)
            if (abs(order[j] - order[i]) < 90) mm[order[j]].score = -1e9f;
        {
            const moment *o = &mm[order[i]];
            printf("frame %5d  tick %5u  %6.0f  ships %d(%d foe)  shots %2d  "
                   "deaths %d  wall %.2f  spread %4.0f  at %6.0f %6.0f\n",
                   order[i], c->tick[order[i]], o->score, o->ships, o->foes,
                   o->shots, o->deaths, o->walls, o->spread, o->x, o->y);
        }
    }
    free(mm);
    free(order);
    cap_free(c);
    return 0;
}

/* Every kill in the record, with the frame a few ticks after it: a blast is
 * worth drawing while the front is still travelling, and by the time the
 * picker notices a death it is usually most of the way over. */
static int cmd_kills(const char *path, int lead) {
    capture *c = cap_load(path);
    int f, i;
    if (!c) { fprintf(stderr, "cannot read %s\n", path); return 1; }
    for (f = 0; f < c->frames; f++) {
        for (i = 0; i < c->ev_n[f]; i++) {
            const cap_ev *e = &c->evs[f][i];
            int at = f + lead;
            moment m;
            if (e->type != EV_DEATH) continue;
            if (at >= c->frames) at = c->frames - 1;
            m = find_action(c, at);
            printf("death at frame %5d  draw %5d  victim %2d killer %3d  "
                   "ships %d(%d foe)  wall %.2f  at %6.0f %6.0f\n",
                   f, at, e->a, e->b, m.ships, m.foes, m.walls, m.x, m.y);
        }
    }
    cap_free(c);
    return 0;
}

static int cmd_battle(int argc, char **argv) {
    const char *path = argv[2];
    int frame = atoi(argv[3]);
    const char *out = argv[4];
    int w = argc > 5 ? atoi(argv[5]) : 1600;
    int hgt = argc > 6 ? atoi(argv[6]) : 900;
    float tilt = argc > 7 ? (float)atof(argv[7]) : 1.15f;
    float dist = argc > 8 ? (float)atof(argv[8]) : 0.0f;
    float turn = argc > 9 ? (float)atof(argv[9]) : 0.0f;
    capture *c = cap_load(path);
    hull3d hulls[14];
    shot_opts o;
    unsigned char *rgb;
    moment act;
    float fx, fy, spread;
    int i;
    if (!c) { fprintf(stderr, "cannot read %s\n", path); return 1; }
    if (frame < 0 || frame >= c->frames) { fprintf(stderr, "frame out of range\n"); return 1; }
    for (i = 0; i < 7; i++) {
        hull3d_build(&hulls[i], i, srgb(COL_FRIEND, 1.0f));
        hull3d_build(&hulls[7 + i], i, srgb(COL_ENEMY, 1.0f));
    }
    act = find_action(c, frame);
    fx = act.x;
    fy = act.y;
    spread = act.spread;
    if (argc > 11) { fx = (float)atof(argv[10]); fy = (float)atof(argv[11]); }
    /* Frame the knot rather than a fixed distance: a duel and a four-way want
     * different rooms, and the spread is the record's own answer to which. */
    if (dist <= 0.0f) dist = 260.0f + spread * 1.15f;
    o.width = w;
    o.height = hgt;
    o.frame = frame;
    o.cam.x = fx;
    o.cam.y = fy;
    o.cam.dist = dist;
    o.cam.tilt = tilt;
    o.cam.turn = turn;
    o.cam.fov = 32.0f;
    o.trail_frames = 16;
    o.shadow = 1;
    rgb = battle_frame(c, hulls, o);
    png_write(out, rgb, w, hgt);
    free(rgb);
    for (i = 0; i < 14; i++) hull3d_free(&hulls[i]);
    cap_free(c);
    return 0;
}


/* --- the footprint --------------------------------------------------------
 *
 * Every hull spends exactly 625 square pixels of target area, and the drawing
 * has to sit on the box the core collides it in. That contract belongs to
 * sim/src/baseline.c and is measured for the flat client by
 * client/tests/hull_fit_test.lua; a third dimension is not a licence to
 * escape it, so this is the same measurement taken on the meshes.
 *
 * Height is the only thing invented here. Nothing in hull3d.c moves a vertex
 * in x or y, and this is what says so out loud. */

#define FIT_OVERLAP 1.7f   /* the box may sit this far inside the drawing */
#define FIT_CEILING 23.0f  /* what the shipped maps were flood filled against */
#define FIT_AREA 625.0f

static int read_extents(float ext[7][3]) {
    FILE *f = fopen("../../sim/src/baseline.c", "r");
    char *src;
    long n;
    char *body, *q;
    int rows = 0;
    if (!f) f = fopen("sim/src/baseline.c", "r");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    src = malloc((size_t)n + 1);
    n = (long)fread(src, 1, (size_t)n, f);
    src[n] = 0;
    fclose(f);
    body = strstr(src, "hull_extent[SIM_MAX_CLASSES][3]");
    if (!body) { free(src); return 0; }
    q = strchr(body, '{');
    while (q && rows < 7) {
        char *row = strchr(q + 1, '{');
        char *end;
        int k = 0;
        if (!row) break;
        end = strchr(row, '}');
        if (!end) break;
        for (q = row + 1; q < end && k < 3; ) {
            while (q < end && (*q < '0' || *q > '9')) q++;
            if (q >= end) break;
            ext[rows][k++] = (float)strtol(q, &q, 10) / 256.0f;
        }
        if (k == 3) rows++;
        q = end;
    }
    free(src);
    return rows;
}

/* How far the mesh reaches on each face, over every vertex of every part:
 * body, hardpoints, lamps, canopy, engines and the drawn lines with them. The
 * furthest thing on a ship is not always on its outline. */
static void mesh_reach(const hull3d *h, float *fwd, float *aft, float *side) {
    int i;
    *fwd = *aft = *side = 0.0f;
    for (i = 0; i < h->body.vn; i++) {
        v3 p = h->body.pos[i];
        float ax = p.x < 0.0f ? -p.x : p.x;
        if (p.y > *fwd) *fwd = p.y;
        if (-p.y > *aft) *aft = -p.y;
        if (ax > *side) *side = ax;
    }
    for (i = 0; i < h->line_n; i++) {
        v3 e[2];
        int k;
        e[0] = h->lines[i].a;
        e[1] = h->lines[i].b;
        for (k = 0; k < 2; k++) {
            float ax = e[k].x < 0.0f ? -e[k].x : e[k].x;
            if (e[k].y > *fwd) *fwd = e[k].y;
            if (-e[k].y > *aft) *aft = -e[k].y;
            if (ax > *side) *side = ax;
        }
    }
}

static int cmd_fit(void) {
    float ext[7][3];
    int rows = read_extents(ext);
    int i, bad = 0;
    if (rows != 7) {
        fprintf(stderr, "cannot read hull_extent from sim/src/baseline.c\n");
        return 1;
    }
    printf("%-8s %-22s %-22s %-22s %9s %7s\n", "hull", "nose  box / drawn",
           "tail  box / drawn", "flank box / drawn", "area px^2", "diag");
    for (i = 0; i < 7; i++) {
        hull3d h;
        float fore = ext[i][0], aft = ext[i][1], halfw = ext[i][2];
        float df, da, ds, area, diag;
        int fail = 0;
        hull3d_build(&h, i, srgb(COL_FRIEND, 1.0f));
        mesh_reach(&h, &df, &da, &ds);
        area = (fore + aft) * halfw * 2.0f;
        diag = sqrtf(fore * fore + halfw * halfw);
        if (sqrtf(aft * aft + halfw * halfw) > diag) diag = sqrtf(aft * aft + halfw * halfw);
        if (df - fore < -1e-3f || df - fore > FIT_OVERLAP) fail = 1;
        if (da - aft < -1e-3f || da - aft > FIT_OVERLAP) fail = 1;
        if (ds - halfw < -1e-3f || ds - halfw > FIT_OVERLAP) fail = 1;
        if (fabsf(area - FIT_AREA) > 1e-3f) fail = 1;
        if (diag > FIT_CEILING) fail = 1;
        printf("%-8s %8.4g / %-11.2f %8.4g / %-11.2f %8.4g / %-11.2f %9.3f %7.2f  %s\n",
               hull3d_name(i), fore, df, aft, da, halfw, ds, area, diag,
               fail ? "FAIL" : "ok");
        bad += fail;
        hull3d_free(&h);
    }
    printf(bad ? "%d hull(s) outside the box\n" : "every hull spends the same 625 px^2 and stays on its box\n", bad);
    return bad ? 1 : 0;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "";
    if (!strcmp(cmd, "sheet") && argc > 2)
        return cmd_sheet(argv[2], argc > 3 ? atoi(argv[3]) : 1800,
                         argc > 4 ? atoi(argv[4]) : 900,
                         argc > 5 ? (float)atof(argv[5]) : 1.05f,
                         argc > 6 ? (float)atof(argv[6]) : 0.0f, 1);
    if (!strcmp(cmd, "hull") && argc > 3)
        return cmd_one(argv[3], atoi(argv[2]), argc > 4 ? atoi(argv[4]) : 900,
                       argc > 5 ? atoi(argv[5]) : 900,
                       argc > 6 ? (float)atof(argv[6]) : 0.95f,
                       argc > 7 ? (float)atof(argv[7]) : 0.0f, 0);
    if (!strcmp(cmd, "obj") && argc > 2) return cmd_obj(argv[2]);
    if (!strcmp(cmd, "fit")) return cmd_fit();
    if (!strcmp(cmd, "kills") && argc > 2)
        return cmd_kills(argv[2], argc > 3 ? atoi(argv[3]) : 8);
    if (!strcmp(cmd, "pick") && argc > 2)
        return cmd_pick(argv[2], argc > 3 ? atoi(argv[3]) : 12);
    if (!strcmp(cmd, "battle") && argc > 4) return cmd_battle(argc, argv);
    fprintf(stderr,
            "usage:\n"
            "  %s sheet <out.png> [w h tilt yaw]   the roster on one page\n"
            "  %s hull <cls> <out.png> [w h tilt yaw]\n"
            "  %s obj <dir>                        write the meshes out\n"
            "  %s fit                              meshes against the collision boxes\n"
            "  %s pick <cap> [n]                   the frames worth drawing\n"
            "  %s battle <cap> <frame> <out.png> [w h tilt dist turn fx fy]\n",
            argv[0], argv[0], argv[0], argv[0], argv[0], argv[0]);
    return 2;
}
