#include "hull3d.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "hulls_data.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* The vertical face at the outline itself: what gives a hull an edge to draw
 * rather than a top surface that fades into its own silhouette. */
#define EDGE 0.62f

/* There is no underside. A hull is mirrored about its own plane, and the
 * reason is the bank: a ship holding 54 degrees of roll shows a viewer from
 * above most of one face, and if that face is a flat dark belly then the
 * hull stops being the hull halfway through every turn. It is also just true
 * of this game, which has no floor and no up. Whatever the crown does above
 * the waterline it does below it. */
#define BELLY 1.0f

/* How far in the one inset ring sits, as a fraction of how far that vertex
 * could travel before leaving the hull, and how deep the crown height under
 * it is read from. One ring, not four: the whole point of this shape is that
 * you can see its edges, and a hull with two hundred of them is a hull with
 * none.
 *
 * The two numbers are different on purpose. Put the ring where its own height
 * is read from and the Anvil turns into a wheel of spokes: eighteen vertices
 * all collapsing toward one point in the middle. Keeping the ring near the
 * outline and taking the height from deeper in makes the same fold a bevel,
 * which is a shape with two edges rather than a hub with eighteen. */
#define INSET 0.34f
#define CROWN_AT 0.80f

/* --- how a color is written down ------------------------------------------
 *
 * palette.lua is in display space, since that is where somebody picked it.
 * Everything here shades in linear light. */
static v3 lin(unsigned hex, float scale) {
    float c[3];
    int i;
    c[0] = (float)((hex >> 16) & 255) / 255.0f;
    c[1] = (float)((hex >> 8) & 255) / 255.0f;
    c[2] = (float)(hex & 255) / 255.0f;
    for (i = 0; i < 3; i++)
        c[i] = c[i] <= 0.04045f ? c[i] / 12.92f : powf((c[i] + 0.055f) / 1.055f, 2.4f);
    return mul(vec(c[0], c[1], c[2]), scale);
}

static v3 to_linear(v3 c) {
    int i;
    float v[3] = {c.x, c.y, c.z};
    for (i = 0; i < 3; i++)
        v[i] = v[i] <= 0.04045f ? v[i] / 12.92f : powf((v[i] + 0.055f) / 1.055f, 2.4f);
    return vec(v[0], v[1], v[2]);
}

/* --- the distance field ---------------------------------------------------
 *
 * How far inside the outline a point is. The crown is read off this, so it is
 * tall where the hull is wide and low where it is a wingtip or a nose. A cross
 * like the Lattice gets a ridge down each arm out of the same rule that gives
 * the Anvil a dome. */

typedef struct {
    float x0, y0, cell;
    int w, h;
    float *d;
    float dmax;
} field;

static float seg_dist(float px, float py, float ax, float ay, float bx, float by) {
    float dx = bx - ax, dy = by - ay;
    float l2 = dx * dx + dy * dy;
    float t = l2 > 1e-12f ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0.0f;
    float qx, qy;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    qx = ax + dx * t;
    qy = ay + dy * t;
    return sqrtf((px - qx) * (px - qx) + (py - qy) * (py - qy));
}

static int inside(const float *p, int n, float x, float y) {
    int i, j, c = 0;
    for (i = 0, j = n - 1; i < n; j = i++) {
        float yi = p[i * 2 + 1], yj = p[j * 2 + 1];
        if ((yi > y) != (yj > y)) {
            float t = (y - yi) / (yj - yi);
            if (x < p[i * 2] + t * (p[j * 2] - p[i * 2])) c = !c;
        }
    }
    return c;
}

static void field_build(field *f, const float *p, int n) {
    float lo_x = p[0], hi_x = p[0], lo_y = p[1], hi_y = p[1];
    int i, x, y;
    for (i = 1; i < n; i++) {
        if (p[i * 2] < lo_x) lo_x = p[i * 2];
        if (p[i * 2] > hi_x) hi_x = p[i * 2];
        if (p[i * 2 + 1] < lo_y) lo_y = p[i * 2 + 1];
        if (p[i * 2 + 1] > hi_y) hi_y = p[i * 2 + 1];
    }
    f->cell = 0.18f;
    f->x0 = lo_x - f->cell;
    f->y0 = lo_y - f->cell;
    f->w = (int)((hi_x - lo_x) / f->cell) + 3;
    f->h = (int)((hi_y - lo_y) / f->cell) + 3;
    f->d = malloc((size_t)f->w * f->h * sizeof *f->d);
    f->dmax = 0.0f;
    for (y = 0; y < f->h; y++) {
        for (x = 0; x < f->w; x++) {
            float px = f->x0 + ((float)x + 0.5f) * f->cell;
            float py = f->y0 + ((float)y + 0.5f) * f->cell;
            float best = 1e9f;
            if (!inside(p, n, px, py)) {
                f->d[y * f->w + x] = 0.0f;
                continue;
            }
            for (i = 0; i < n; i++) {
                int j = (i + 1) % n;
                float dd = seg_dist(px, py, p[i * 2], p[i * 2 + 1],
                                    p[j * 2], p[j * 2 + 1]);
                if (dd < best) best = dd;
            }
            f->d[y * f->w + x] = best;
            if (best > f->dmax) f->dmax = best;
        }
    }
    if (f->dmax < 1e-4f) f->dmax = 1.0f;
}

static float field_at(const field *f, float x, float y) {
    float fx = (x - f->x0) / f->cell - 0.5f;
    float fy = (y - f->y0) / f->cell - 0.5f;
    int ix = (int)floorf(fx), iy = (int)floorf(fy);
    float tx = fx - (float)ix, ty = fy - (float)iy;
    float a, b, c, d;
    if (ix < 0) { ix = 0; tx = 0.0f; }
    if (iy < 0) { iy = 0; ty = 0.0f; }
    if (ix > f->w - 2) { ix = f->w - 2; tx = 1.0f; }
    if (iy > f->h - 2) { iy = f->h - 2; ty = 1.0f; }
    a = f->d[iy * f->w + ix];
    b = f->d[iy * f->w + ix + 1];
    c = f->d[(iy + 1) * f->w + ix];
    d = f->d[(iy + 1) * f->w + ix + 1];
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
}

/* Where the top surface is at a point inside the outline. A roof cannot be
 * taller than the room it stands on, which is what the second clamp is for:
 * without it the Apex's neck and the Lattice's arms come out as fins, three
 * pixels wide and five tall, a shape the plan view never promised. */
static float crown(const field *f, float x, float y, float cap) {
    float d = field_at(f, x, y);
    float u = d / f->dmax;
    float z;
    if (u <= 0.0f) return EDGE;
    z = cap * powf(u, 0.62f);
    if (z > 0.85f * d) z = 0.85f * d;
    return EDGE + z;
}

/* --- ear clipping ---------------------------------------------------------
 *
 * Ported from the same routine in client/arena/world.lua, and there for the
 * same reason: a fan from the centroid covers a hull only if the centroid can
 * see all of it, and the Chord is a crescent. */
static int ear_clip(const float *p, int n, int *out) {
    int *idx = malloc((size_t)n * sizeof *idx);
    int left = n, guard = 0, m = 0, i;
    for (i = 0; i < n; i++) idx[i] = i;
    while (left > 3 && guard++ < 4096) {
        int cut = -1;
        for (i = 0; i < left; i++) {
            int a = idx[(i + left - 1) % left], b = idx[i], c = idx[(i + 1) % left];
            float cr = (p[b * 2] - p[a * 2]) * (p[c * 2 + 1] - p[a * 2 + 1])
                     - (p[b * 2 + 1] - p[a * 2 + 1]) * (p[c * 2] - p[a * 2]);
            int clear = 1, k;
            if (cr <= 0.0f) continue;
            for (k = 0; k < left; k++) {
                int q = idx[k];
                float d, s, t;
                if (q == a || q == b || q == c) continue;
                d = (p[b * 2 + 1] - p[c * 2 + 1]) * (p[a * 2] - p[c * 2])
                  + (p[c * 2] - p[b * 2]) * (p[a * 2 + 1] - p[c * 2 + 1]);
                if (fabsf(d) < 1e-12f) continue;
                s = ((p[b * 2 + 1] - p[c * 2 + 1]) * (p[q * 2] - p[c * 2])
                   + (p[c * 2] - p[b * 2]) * (p[q * 2 + 1] - p[c * 2 + 1])) / d;
                t = ((p[c * 2 + 1] - p[a * 2 + 1]) * (p[q * 2] - p[c * 2])
                   + (p[a * 2] - p[c * 2]) * (p[q * 2 + 1] - p[c * 2 + 1])) / d;
                if (s > 1e-9f && t > 1e-9f && 1.0f - s - t > 1e-9f) { clear = 0; break; }
            }
            if (clear) {
                cut = i;
                out[m * 3] = a;
                out[m * 3 + 1] = b;
                out[m * 3 + 2] = c;
                m++;
                break;
            }
        }
        if (cut < 0) break;
        for (i = cut; i + 1 < left; i++) idx[i] = idx[i + 1];
        left--;
    }
    if (left == 3) {
        out[m * 3] = idx[0];
        out[m * 3 + 1] = idx[1];
        out[m * 3 + 2] = idx[2];
        m++;
    }
    free(idx);
    return m;
}

/* --- fills ----------------------------------------------------------------
 *
 * The two passes world.lua draws a hull body in, kept exactly: an opaque base
 * dark enough to be a hole in the starfield and tinted toward the team so it
 * is never a black one, and an additive wash over it that is brightest at the
 * bow and gone at the stern.
 *
 * The wash is a light fixed to the hull's own nose. Fixed to the world
 * instead, the same ship would look like a different ship depending on which
 * way it was pointing, and the silhouette is the entire identity system. In
 * two dimensions that light has one input, the outward normal of an edge; in
 * three it is the same normal with the crown's slope in it. */

#define FILL_BINS 10

typedef struct {
    int fill[FILL_BINS];   /* body, by how much of the nose light it takes */
    int belly;
    int glass, lamp, burn, flame, steel, deck;
} palette;

static float nose_light(v3 n) {
    /* The formula in world.lua, generalized: a face pointing at the bow is
     * lit, one pointing at the stern is not, and a face pointing straight up
     * sits where a flat drawing's edges sat.
     *
     * The crown's slope enters as its magnitude rather than its sign, which is
     * what keeps a mirrored hull mirrored: signed, the deck and the face under
     * it take different fills and the symmetry is geometry only. */
    float z = n.z < 0.0f ? -n.z : n.z;
    float y = n.y * 0.82f + z * 0.18f;
    return 0.40f + 0.60f * (0.5f + 0.5f * y);
}

/* The body, and the wash over it, both worked out where palette.lua works:
 * on the screen. The client adds its wash as an alpha over the fill, so doing
 * the same sum in linear light adds several times as much of it, and the hulls
 * came out as holograms. Convert once, at the end. */
static int fill_material(mesh *m, v3 body, v3 team, float wash, float dim) {
    material mt;
    mt.rough = 0.9f;
    mt.metal = 0.0f;
    mt.emit = vec(0, 0, 0);
    mt.albedo = mul(to_linear(add(body, mul(team, wash))), dim);
    return mesh_material(m, mt);
}

static palette build_palette(mesh *m, v3 team, float dim) {
    palette p;
    v3 body = vec(team.x * 0.055f + 0.018f, team.y * 0.055f + 0.026f,
                  team.z * 0.055f + 0.042f);
    int i;
    material mt;
    mt.rough = 0.9f;
    mt.metal = 0.0f;
    mt.emit = vec(0, 0, 0);
    for (i = 0; i < FILL_BINS; i++) {
        float light = (float)i / (float)(FILL_BINS - 1);
        p.fill[i] = fill_material(m, body, team, 0.20f * light, dim);
    }
    p.belly = fill_material(m, mul(body, 0.7f), team, 0.02f, dim);
    p.deck = fill_material(m, mul(body, 1.35f), team, 0.10f, dim);
    /* A canopy is the one bright cell every hull carries forward of center. */
    mt.albedo = to_linear(mul(add(mul(body, 0.5f), mul(team, 0.62f)), 1.0f));
    mt.emit = mul(to_linear(team), 0.16f * dim);
    p.glass = mesh_material(m, mt);
    mt.albedo = to_linear(add(mul(body, 0.5f), mul(team, 0.78f)));
    mt.emit = mul(to_linear(team), 0.30f * dim);
    p.lamp = mesh_material(m, mt);
    /* Hardpoints draw hot: where a hull's damage comes out of is worth knowing
     * at a glance. */
    mt.albedo = to_linear(add(mul(team, 0.55f), vec(0.30f, 0.30f, 0.30f)));
    mt.emit = mul(to_linear(team), 0.34f * dim);
    p.burn = mesh_material(m, mt);
    /* An engine mouth is thrust colored, not team colored: palette.lua gives
     * THRUST to the flame and nothing on a hull borrows it. */
    mt.albedo = lin(0xffbe78, 0.30f);
    mt.emit = lin(0xffbe78, 0.55f * dim);
    p.flame = mesh_material(m, mt);
    mt.albedo = to_linear(vec(0.10f, 0.12f, 0.15f));
    mt.emit = vec(0, 0, 0);
    p.steel = mesh_material(m, mt);
    return p;
}

static int fill_of(const palette *p, v3 n) {
    float l = nose_light(n);
    int b = (int)((l - 0.40f) / 0.60f * (float)(FILL_BINS - 1) + 0.5f);
    if (b < 0) b = 0;
    if (b > FILL_BINS - 1) b = FILL_BINS - 1;
    return p->fill[b];
}

/* A quad whose fill is chosen by the way it faces on the hull. */
static void lit_quad(mesh *m, const palette *p, v3 a, v3 b, v3 c, v3 d) {
    v3 n = norm(cross(sub(b, a), sub(c, a)));
    mesh_quad(m, a, b, c, d, fill_of(p, n));
}

static void lit_tri(mesh *m, const palette *p, v3 a, v3 b, v3 c) {
    v3 n = norm(cross(sub(b, a), sub(c, a)));
    mesh_face(m, a, b, c, fill_of(p, n));
}

/* --- pieces --------------------------------------------------------------- */

static void add_line(hull3d *h, int *cap, v3 a, v3 b, v3 col, float width) {
    if (h->line_n + 1 > *cap) {
        *cap = *cap ? *cap * 2 : 128;
        h->lines = realloc(h->lines, (size_t)*cap * sizeof *h->lines);
    }
    h->lines[h->line_n].a = a;
    h->lines[h->line_n].b = b;
    h->lines[h->line_n].col = col;
    h->lines[h->line_n].width = width;
    h->line_n++;
}

/* A prism along the segment a to b: a barrel, a nacelle. Six sided, because
 * these are drawn as much by their edges as by their faces. */
static void prism(mesh *m, v3 a, v3 b, float r, int sides, int mat,
                  hull3d *h, int *lcap, v3 edge_col, float edge_w) {
    v3 axis = sub(b, a);
    v3 u, w;
    float len = sqrtf(dot(axis, axis));
    int i;
    if (len < 1e-6f) return;
    axis = mul(axis, 1.0f / len);
    u = fabsf(axis.z) < 0.9f ? norm(cross(axis, vec(0, 0, 1)))
                             : norm(cross(axis, vec(1, 0, 0)));
    w = cross(axis, u);
    for (i = 0; i < sides; i++) {
        float t0 = (float)i / (float)sides * 2.0f * (float)M_PI;
        float t1 = (float)(i + 1) / (float)sides * 2.0f * (float)M_PI;
        v3 o0 = add(mul(u, cosf(t0) * r), mul(w, sinf(t0) * r));
        v3 o1 = add(mul(u, cosf(t1) * r), mul(w, sinf(t1) * r));
        mesh_quad(m, add(a, o0), add(b, o0), add(b, o1), add(a, o1), mat);
        mesh_face(m, b, add(b, o0), add(b, o1), mat);
        mesh_face(m, a, add(a, o1), add(a, o0), mat);
        if (h) add_line(h, lcap, add(b, o0), add(b, o1), edge_col, edge_w);
    }
}

/* The lit face at the end of a barrel or a nozzle. A second prism pushed
 * inside the first shares its end cap and z-fights across the whole of it,
 * which came out as a checkerboard on every engine. */
static void disc(mesh *m, v3 c, v3 axis, float r, int sides, int mat,
                 hull3d *h, int *lcap, v3 col) {
    v3 u = fabsf(axis.z) < 0.9f ? norm(cross(axis, vec(0, 0, 1)))
                                : norm(cross(axis, vec(1, 0, 0)));
    v3 w = cross(axis, u);
    int i;
    for (i = 0; i < sides; i++) {
        float t0 = (float)i / (float)sides * 2.0f * (float)M_PI;
        float t1 = (float)(i + 1) / (float)sides * 2.0f * (float)M_PI;
        v3 a = add(c, add(mul(u, cosf(t0) * r), mul(w, sinf(t0) * r)));
        v3 b = add(c, add(mul(u, cosf(t1) * r), mul(w, sinf(t1) * r)));
        mesh_face(m, c, a, b, mat);
        if (h) add_line(h, lcap, a, b, col, 0.055f);
    }
}

/* A faceted dome, for a lamp or a dispenser head. Eight sided and two rings,
 * so it reads as a cut jewel rather than a sphere. */
static void dome(mesh *m, v3 c, float r, int mat, hull3d *h, int *lcap, v3 col) {
    const int seg = 8, rings = 2;
    int i, j;
    for (j = 0; j < rings; j++) {
        float p0 = (float)j / (float)rings * (float)M_PI * 0.5f;
        float p1 = (float)(j + 1) / (float)rings * (float)M_PI * 0.5f;
        for (i = 0; i < seg; i++) {
            float a0 = (float)i / (float)seg * 2.0f * (float)M_PI;
            float a1 = (float)(i + 1) / (float)seg * 2.0f * (float)M_PI;
            v3 p00 = add(c, vec(cosf(a0) * cosf(p0) * r, sinf(a0) * cosf(p0) * r, sinf(p0) * r));
            v3 p01 = add(c, vec(cosf(a1) * cosf(p0) * r, sinf(a1) * cosf(p0) * r, sinf(p0) * r));
            v3 p10 = add(c, vec(cosf(a0) * cosf(p1) * r, sinf(a0) * cosf(p1) * r, sinf(p1) * r));
            v3 p11 = add(c, vec(cosf(a1) * cosf(p1) * r, sinf(a1) * cosf(p1) * r, sinf(p1) * r));
            if (j == rings - 1) mesh_face(m, p00, p01, p10, mat);
            else mesh_quad(m, p00, p01, p11, p10, mat);
            if (h && j == rings - 1) add_line(h, lcap, p00, p01, col, 0.055f);
        }
    }
}

/* Copy every triangle added since `tri0` to the other face. Winding is
 * reversed with the copy, or the mirrored half draws its normals inward and
 * takes the fill of a surface pointing the wrong way. */
static void mirror_faces(mesh *m, int tri0) {
    int n = m->tn, i;
    for (i = tri0; i < n; i++) {
        v3 a = m->pos[m->idx[i * 3 + 0]];
        v3 b = m->pos[m->idx[i * 3 + 1]];
        v3 c = m->pos[m->idx[i * 3 + 2]];
        a.z = -a.z;
        b.z = -b.z;
        c.z = -c.z;
        mesh_face(m, a, c, b, m->tri_mat[i]);
    }
}

static void mirror_lines(hull3d *h, int *cap, int line0) {
    int n = h->line_n, i;
    for (i = line0; i < n; i++) {
        v3 a = h->lines[i].a, b = h->lines[i].b;
        a.z = -a.z;
        b.z = -b.z;
        add_line(h, cap, a, b, h->lines[i].col, h->lines[i].width);
    }
}

/* --- the hull ------------------------------------------------------------- */

void hull3d_build(hull3d *h, int cls, v3 team) {
    const hull_art *art = &HULLS[cls % HULL_COUNT];
    int n = art->poly_n;
    float *p = malloc((size_t)n * 2 * sizeof *p);
    float *inner = malloc((size_t)n * 2 * sizeof *inner);
    float *deep = malloc((size_t)n * 2 * sizeof *deep);
    float *reach = malloc((size_t)n * sizeof *reach);
    v3 *rim_lo = malloc((size_t)n * sizeof *rim_lo);
    v3 *rim_hi = malloc((size_t)n * sizeof *rim_hi);
    v3 *top = malloc((size_t)n * sizeof *top);
    v3 *bot = malloc((size_t)n * sizeof *bot);
    field f;
    palette pal;
    float area = 0.0f, cy = 0.0f;
    float lo_x = 1e9f, hi_x = -1e9f, lo_y = 1e9f, hi_y = -1e9f;
    float cap;
    int i, q, lcap = 0, face0_tri, face0_line;
    v3 wash = to_linear(team);

    memset(h, 0, sizeof *h);
    h->name = art->name;
    for (i = 0; i < n * 2; i++) p[i] = art->poly[i];
    for (i = 0; i < n; i++) {
        int k = (i + 1) % n;
        area += p[i * 2] * p[k * 2 + 1] - p[k * 2] * p[i * 2 + 1];
    }
    /* Counter-clockwise seen from above, so every face built off the outline
     * ends up with its normal pointing out of the hull rather than into it. */
    if (area < 0.0f) {
        for (i = 0; i < n / 2; i++) {
            float tx = p[i * 2], ty = p[i * 2 + 1];
            p[i * 2] = p[(n - 1 - i) * 2];
            p[i * 2 + 1] = p[(n - 1 - i) * 2 + 1];
            p[(n - 1 - i) * 2] = tx;
            p[(n - 1 - i) * 2 + 1] = ty;
        }
    }
    for (i = 0; i < n; i++) {
        cy += p[i * 2 + 1];
        if (p[i * 2] < lo_x) lo_x = p[i * 2];
        if (p[i * 2] > hi_x) hi_x = p[i * 2];
        if (p[i * 2 + 1] < lo_y) lo_y = p[i * 2 + 1];
        if (p[i * 2 + 1] > hi_y) hi_y = p[i * 2 + 1];
    }
    cy /= (float)n;
    h->nose = hi_y;
    h->tail = -lo_y;
    h->beam = hi_x - lo_x;

    field_build(&f, p, n);
    /* The tallest a hull is allowed to stand, off its own plan. A dart as tall
     * as it is wide is a missile; a slab that is flat is a decal. */
    cap = 0.235f * fminf(h->beam, hi_y - lo_y);
    if (cap > 5.0f) cap = 5.0f;
    h->height = EDGE + cap;

    /* How far each vertex may travel inward before it leaves its own hull.
     * Doing this per vertex is what makes the ring survive a crescent and a
     * cross: at a notch the bisector points outward, the march goes nowhere,
     * and the ring simply stays on the outline there. */
    for (i = 0; i < n; i++) {
        int prev = (i + n - 1) % n, next = (i + 1) % n;
        float ax = p[i * 2] - p[prev * 2], ay = p[i * 2 + 1] - p[prev * 2 + 1];
        float bx = p[next * 2] - p[i * 2], by = p[next * 2 + 1] - p[i * 2 + 1];
        float la = sqrtf(ax * ax + ay * ay), lb = sqrtf(bx * bx + by * by);
        float mx, my, ml, t = 0.0f;
        float lim = 2.0f * f.dmax;
        if (la < 1e-6f) la = 1.0f;
        if (lb < 1e-6f) lb = 1.0f;
        /* Inward normal of an edge, for counter-clockwise winding, is its
         * direction turned left. */
        mx = -ay / la + -by / lb;
        my = ax / la + bx / lb;
        ml = sqrtf(mx * mx + my * my);
        if (ml < 1e-6f) { mx = 0.0f; my = 0.0f; }
        else { mx /= ml; my /= ml; }
        while (t + 0.12f < lim
               && inside(p, n, p[i * 2] + mx * (t + 0.12f),
                         p[i * 2 + 1] + my * (t + 0.12f)))
            t += 0.12f;
        reach[i] = t;
        inner[i * 2] = p[i * 2] + mx * t * INSET;
        inner[i * 2 + 1] = p[i * 2 + 1] + my * t * INSET;
        deep[i * 2] = p[i * 2] + mx * t * CROWN_AT;
        deep[i * 2 + 1] = p[i * 2 + 1] + my * t * CROWN_AT;
    }

    mesh_init(&h->body);
    pal = build_palette(&h->body, team, art->dim);

    for (i = 0; i < n; i++) {
        rim_lo[i] = vec(p[i * 2], p[i * 2 + 1], -EDGE);
        rim_hi[i] = vec(p[i * 2], p[i * 2 + 1], EDGE);
        {
            float z = crown(&f, deep[i * 2], deep[i * 2 + 1], cap);
            top[i] = vec(inner[i * 2], inner[i * 2 + 1], z);
            bot[i] = vec(inner[i * 2], inner[i * 2 + 1], -(EDGE + (z - EDGE) * BELLY));
        }
    }

    /* The waterline band, then the crown up to the inset ring, then the ring
     * capped flat. Three bands of quads is the whole hull. */
    for (i = 0; i < n; i++) {
        int k = (i + 1) % n;
        lit_quad(&h->body, &pal, rim_lo[i], rim_lo[k], rim_hi[k], rim_hi[i]);
        lit_quad(&h->body, &pal, rim_hi[i], rim_hi[k], top[k], top[i]);
        lit_quad(&h->body, &pal, rim_lo[k], rim_lo[i], bot[i], bot[k]);
    }
    {
        int *tri = malloc((size_t)n * 3 * sizeof *tri);
        int tn = ear_clip(inner, n, tri);
        for (i = 0; i < tn; i++) {
            int a = tri[i * 3], b = tri[i * 3 + 1], c = tri[i * 3 + 2];
            lit_tri(&h->body, &pal, top[a], top[b], top[c]);
            lit_tri(&h->body, &pal, bot[a], bot[c], bot[b]);
        }
        free(tri);
    }

    /* Everything from here to the mirror below is built on one face and then
     * copied to the other. */
    face0_tri = h->body.tn;
    face0_line = h->line_n;

    /* Plates: interior loops in the drawing, raised into decks here. One
     * height for the whole deck, taken from the highest ground it covers, so
     * a plate never fights the surface it sits on. */
    for (i = 0; i < art->plate_n; i++) {
        int off = 0, m;
        float deck = 0.0f;
        v3 *ring, mid = vec(0, 0, 0);
        for (q = 0; q < i; q++) off += art->plate_len[q];
        m = art->plate_len[i] / 2;
        ring = malloc((size_t)m * sizeof *ring);
        for (q = 0; q < m; q++) {
            float z = crown(&f, art->plate_pts[off + q * 2],
                            art->plate_pts[off + q * 2 + 1], cap);
            if (z > deck) deck = z;
        }
        deck += 0.30f;
        for (q = 0; q < m; q++) {
            ring[q] = vec(art->plate_pts[off + q * 2],
                          art->plate_pts[off + q * 2 + 1], deck);
            mid = add(mid, ring[q]);
        }
        mid = mul(mid, 1.0f / (float)m);
        for (q = 0; q < m; q++) {
            int r = (q + 1) % m;
            mesh_face(&h->body, mid, ring[q], ring[r], pal.deck);
            mesh_quad(&h->body, vec(ring[q].x, ring[q].y, deck - 1.4f),
                      vec(ring[r].x, ring[r].y, deck - 1.4f), ring[r], ring[q],
                      pal.steel);
            add_line(h, &lcap, ring[q], ring[r], lin(0x9fb6d4, 0.42f), 0.06f);
        }
        free(ring);
    }

    /* Panel lines, in a neutral instrument gray. The team read belongs on the
     * silhouette; a hull whose every line is one color looks cut from a single
     * sheet of neon rather than built out of parts. */
    for (i = 0; i < art->line_n; i++) {
        int off = 0, m;
        for (q = 0; q < i; q++) off += art->line_len[q];
        m = art->line_len[i] / 2;
        for (q = 0; q + 1 < m; q++) {
            float ax = art->line_pts[off + q * 2], ay = art->line_pts[off + q * 2 + 1];
            float bx = art->line_pts[off + q * 2 + 2], by = art->line_pts[off + q * 2 + 3];
            add_line(h, &lcap, vec(ax, ay, crown(&f, ax, ay, cap) + 0.05f),
                     vec(bx, by, crown(&f, bx, by, cap) + 0.05f),
                     lin(0x9fb6d4, 0.22f), 0.045f);
        }
    }

    /* Lamps and dispenser heads. */
    for (i = 0; i < art->pod_n; i++) {
        float x = art->pods[i * 3], y = art->pods[i * 3 + 1];
        float r = art->pods[i * 3 + 2] * 0.8f;
        dome(&h->body, vec(x, y, crown(&f, x, y, cap) - r * 0.4f), r, pal.lamp,
             h, &lcap, mul(wash, 0.9f));
    }

    /* The canopy: the one thing on a hull that says which end is the front. */
    if (art->canopy_n >= 3) {
        int m = art->canopy_n;
        v3 *base = malloc((size_t)m * sizeof *base);
        v3 mid = vec(0, 0, 0);
        float apex = 0.0f;
        for (i = 0; i < m; i++) {
            float x = art->canopy[i * 2], y = art->canopy[i * 2 + 1];
            base[i] = vec(x, y, crown(&f, x, y, cap) - 0.10f);
            mid = add(mid, base[i]);
            if (base[i].z > apex) apex = base[i].z;
        }
        mid = mul(mid, 1.0f / (float)m);
        mid.z = apex + 1.0f;
        for (i = 0; i < m; i++) {
            int k = (i + 1) % m;
            mesh_face(&h->body, base[i], base[k], mid, pal.glass);
            add_line(h, &lcap, base[i], base[k], mul(wash, 1.15f), 0.06f);
            add_line(h, &lcap, base[i], mid, mul(wash, 0.75f), 0.05f);
        }
        free(base);
    }

    /* Hardpoints: where a round actually leaves the ship, per ships.md. On the
     * deck rather than on the waterline, and so mirrored onto both decks. Sunk
     * into the equator they vanish inside the hulls whose tubes run down the
     * spine, which is most of them: the Wedge's bomb tube is the brightest
     * thing on that ship and it disappeared entirely. */
    for (i = 0; i < art->tube_n; i++) {
        float x0 = art->tubes[i * 5 + 0], y0 = art->tubes[i * 5 + 1];
        float x1 = art->tubes[i * 5 + 2], y1 = art->tubes[i * 5 + 3];
        float r = art->tubes[i * 5 + 4] * 0.5f;
        float xf = y1 >= y0 ? x1 : x0, yf = y1 >= y0 ? y1 : y0;
        float xa = y1 >= y0 ? x0 : x1, ya = y1 >= y0 ? y0 : y1;
        float zc = crown(&f, xa, ya, cap) - r * 0.5f;
        v3 aft = vec(xa, ya, zc), fwd = vec(xf, yf, zc);
        v3 dir = norm(sub(fwd, aft));
        /* Drawn hot, which is the client's rule for these: where a hull's
         * damage comes out of is worth knowing at a glance, and it is the same
         * element at every size. The barrel takes the brightest fill on the
         * ship and carries a lit core down its length. */
        prism(&h->body, add(aft, mul(dir, -0.3f)), fwd, r, 6,
              fill_of(&pal, vec(0, 1, 0)), h, &lcap, mul(wash, 1.5f), 0.07f);
        disc(&h->body, add(fwd, mul(dir, 0.06f)), dir, r * 0.82f, 6, pal.burn,
             h, &lcap, mul(wash, 1.4f));
        add_line(h, &lcap, add(aft, vec(0, 0, r * 0.92f)),
                 add(fwd, vec(0, 0, r * 0.92f)),
                 add(mul(wash, 0.9f), lin(0xffffff, 0.35f)), 0.09f);
        if (h->muzzle_n < 4) h->muzzles[h->muzzle_n++] = add(fwd, mul(dir, 0.4f));
    }

    mirror_faces(&h->body, face0_tri);
    mirror_lines(h, &lcap, face0_line);

    /* Engines. The mouths are where world.lua puts them, so a plume drawn off
     * this model leaves the ship where the flat game's does. */
    for (i = 0; i < art->jets_n; i++) {
        float x = art->jets[i * 2], y = art->jets[i * 2 + 1];
        float r = fminf(1.45f, EDGE + cap * 0.24f);
        v3 mouth = vec(x, y - 0.1f, 0.0f);
        prism(&h->body, add(mouth, vec(0, 1.9f, 0)), mouth, r, 6, pal.steel,
              h, &lcap, mul(wash, 0.4f), 0.05f);
        disc(&h->body, add(mouth, vec(0, -0.06f, 0)), vec(0, -1, 0), r * 0.7f, 6,
             pal.flame, h, &lcap, lin(0xffbe78, 0.9f));
        if (h->jet_n < 8) h->jets[h->jet_n++] = mouth;
    }

    /* The wireframe. This is the drawing: the outline at its own brightness
     * per edge, the ring the crown folds along, the spars between the two, and
     * the vertical the waterline stands on. Hidden ones are cut by the depth
     * buffer rather than by a hidden-line pass, which is the one thing three
     * dimensions makes cheaper than two. */
    for (i = 0; i < n; i++) {
        int k = (i + 1) % n;
        float dx = p[k * 2] - p[i * 2], dy = p[k * 2 + 1] - p[i * 2 + 1];
        float len = sqrtf(dx * dx + dy * dy);
        float ny = len > 1e-6f ? -dx / len : 0.0f;
        float light = 0.40f + 0.60f * (0.5f + 0.5f * ny);
        add_line(h, &lcap, rim_hi[i], rim_hi[k], mul(wash, light * 2.3f), 0.15f);
        add_line(h, &lcap, rim_lo[i], rim_lo[k], mul(wash, light * 2.3f), 0.15f);
        add_line(h, &lcap, rim_lo[i], rim_hi[i], mul(wash, light * 0.60f), 0.06f);
        if (reach[i] > 0.9f) {
            add_line(h, &lcap, rim_hi[i], top[i], mul(wash, light * 0.45f), 0.05f);
            add_line(h, &lcap, top[i], top[k], mul(wash, light * 0.85f), 0.08f);
            add_line(h, &lcap, rim_lo[i], bot[i], mul(wash, light * 0.45f), 0.05f);
            add_line(h, &lcap, bot[i], bot[k], mul(wash, light * 0.85f), 0.08f);
        }
    }
    free(rim_lo);
    free(rim_hi);
    free(top);
    free(bot);
    free(reach);
    free(deep);
    free(inner);
    free(f.d);
    free(p);
}

void hull3d_free(hull3d *h) {
    mesh_free(&h->body);
    free(h->lines);
    memset(h, 0, sizeof *h);
}

int hull3d_count(void) { return HULL_COUNT; }

const char *hull3d_name(int cls) { return HULL_NAME[cls % HULL_COUNT]; }
