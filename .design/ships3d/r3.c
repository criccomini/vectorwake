#include "r3.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

v3 norm(v3 a) {
    float l = sqrtf(dot(a, a));
    if (l < 1e-9f) return vec(0, 0, 1);
    return mul(a, 1.0f / l);
}

/* --- matrices -------------------------------------------------------------
 *
 * Column-major: m[c * 4 + r]. */

mat4 mat_identity(void) {
    mat4 r;
    int i;
    for (i = 0; i < 16; i++) r.m[i] = (i % 5) ? 0.0f : 1.0f;
    return r;
}

mat4 mat_mul(mat4 a, mat4 b) {
    mat4 r;
    int c, k;
    for (c = 0; c < 4; c++) {
        for (k = 0; k < 4; k++) {
            r.m[c * 4 + k] = a.m[0 * 4 + k] * b.m[c * 4 + 0]
                           + a.m[1 * 4 + k] * b.m[c * 4 + 1]
                           + a.m[2 * 4 + k] * b.m[c * 4 + 2]
                           + a.m[3 * 4 + k] * b.m[c * 4 + 3];
        }
    }
    return r;
}

mat4 mat_perspective(float fov_deg, float aspect, float znear, float zfar) {
    mat4 r;
    float f = 1.0f / tanf((float)(fov_deg * M_PI / 360.0));
    memset(r.m, 0, sizeof r.m);
    r.m[0] = f / aspect;
    r.m[5] = f;
    r.m[10] = (zfar + znear) / (znear - zfar);
    r.m[11] = -1.0f;
    r.m[14] = 2.0f * zfar * znear / (znear - zfar);
    return r;
}

mat4 mat_ortho(float l, float r_, float b, float t, float n, float f) {
    mat4 r;
    memset(r.m, 0, sizeof r.m);
    r.m[0] = 2.0f / (r_ - l);
    r.m[5] = 2.0f / (t - b);
    r.m[10] = -2.0f / (f - n);
    r.m[12] = -(r_ + l) / (r_ - l);
    r.m[13] = -(t + b) / (t - b);
    r.m[14] = -(f + n) / (f - n);
    r.m[15] = 1.0f;
    return r;
}

mat4 mat_look(v3 eye, v3 at, v3 up) {
    v3 f = norm(sub(at, eye));
    v3 s = norm(cross(f, up));
    v3 u = cross(s, f);
    mat4 r = mat_identity();
    r.m[0] = s.x;  r.m[4] = s.y;  r.m[8] = s.z;
    r.m[1] = u.x;  r.m[5] = u.y;  r.m[9] = u.z;
    r.m[2] = -f.x; r.m[6] = -f.y; r.m[10] = -f.z;
    r.m[12] = -dot(s, eye);
    r.m[13] = -dot(u, eye);
    r.m[14] = dot(f, eye);
    return r;
}

/* Ship space into world space. A heading is turns clockwise from +y, which is
 * how the core stores one and how every hull in world.lua is drawn. */
mat4 mat_trs(v3 t, float yaw_turns, float scale) {
    float a = (float)(-yaw_turns * 2.0 * M_PI);
    float c = cosf(a), s = sinf(a);
    mat4 r = mat_identity();
    r.m[0] = c * scale;  r.m[1] = s * scale;
    r.m[4] = -s * scale; r.m[5] = c * scale;
    r.m[10] = scale;
    r.m[12] = t.x; r.m[13] = t.y; r.m[14] = t.z;
    return r;
}

v3 mat_apply(mat4 a, v3 p) {
    float x = a.m[0] * p.x + a.m[4] * p.y + a.m[8] * p.z + a.m[12];
    float y = a.m[1] * p.x + a.m[5] * p.y + a.m[9] * p.z + a.m[13];
    float z = a.m[2] * p.x + a.m[6] * p.y + a.m[10] * p.z + a.m[14];
    float w = a.m[3] * p.x + a.m[7] * p.y + a.m[11] * p.z + a.m[15];
    if (w != 0.0f && w != 1.0f) { x /= w; y /= w; z /= w; }
    return vec(x, y, z);
}

v3 mat_apply_dir(mat4 a, v3 d) {
    return vec(a.m[0] * d.x + a.m[4] * d.y + a.m[8] * d.z,
               a.m[1] * d.x + a.m[5] * d.y + a.m[9] * d.z,
               a.m[2] * d.x + a.m[6] * d.y + a.m[10] * d.z);
}

/* --- meshes --------------------------------------------------------------- */

void mesh_init(mesh *m) { memset(m, 0, sizeof *m); }

void mesh_free(mesh *m) {
    free(m->pos);
    free(m->nrm);
    free(m->idx);
    free(m->tri_mat);
    free(m->mats);
    memset(m, 0, sizeof *m);
}

static void grow_v(mesh *m, int want) {
    if (want <= m->vcap) return;
    m->vcap = m->vcap ? m->vcap * 2 : 256;
    if (m->vcap < want) m->vcap = want;
    m->pos = realloc(m->pos, (size_t)m->vcap * sizeof *m->pos);
    m->nrm = realloc(m->nrm, (size_t)m->vcap * sizeof *m->nrm);
}

static void grow_t(mesh *m, int want) {
    if (want <= m->tcap) return;
    m->tcap = m->tcap ? m->tcap * 2 : 256;
    if (m->tcap < want) m->tcap = want;
    m->idx = realloc(m->idx, (size_t)m->tcap * 3 * sizeof *m->idx);
    m->tri_mat = realloc(m->tri_mat, (size_t)m->tcap * sizeof *m->tri_mat);
}

int mesh_material(mesh *m, material mat) {
    if (m->mn + 1 > m->mcap) {
        m->mcap = m->mcap ? m->mcap * 2 : 16;
        m->mats = realloc(m->mats, (size_t)m->mcap * sizeof *m->mats);
    }
    m->mats[m->mn] = mat;
    return m->mn++;
}

int mesh_vertex(mesh *m, v3 p, v3 n) {
    grow_v(m, m->vn + 1);
    m->pos[m->vn] = p;
    m->nrm[m->vn] = n;
    return m->vn++;
}

void mesh_tri(mesh *m, int a, int b, int c, int mat) {
    grow_t(m, m->tn + 1);
    m->idx[m->tn * 3 + 0] = a;
    m->idx[m->tn * 3 + 1] = b;
    m->idx[m->tn * 3 + 2] = c;
    m->tri_mat[m->tn] = mat;
    m->tn++;
}

void mesh_face(mesh *m, v3 a, v3 b, v3 c, int mat) {
    v3 raw = cross(sub(b, a), sub(c, a));
    v3 n;
    int i, j, k;
    /* A triangle with no area has no normal, only noise, and welding spreads
     * that noise into every vertex around it. Ear clipping leaves slivers and
     * subdividing a sliver leaves more of them, so drop them here rather than
     * finding them later as scratches down a hull. */
    if (dot(raw, raw) < 1e-12f) return;
    n = norm(raw);
    i = mesh_vertex(m, a, n);
    j = mesh_vertex(m, b, n);
    k = mesh_vertex(m, c, n);
    mesh_tri(m, i, j, k, mat);
}

void mesh_quad(mesh *m, v3 a, v3 b, v3 c, v3 d, int mat) {
    mesh_face(m, a, b, c, mat);
    mesh_face(m, a, c, d, mat);
}

void mesh_append(mesh *dst, const mesh *src, mat4 xf) {
    int base = dst->vn;
    int mbase = dst->mn;
    int i;
    for (i = 0; i < src->mn; i++) mesh_material(dst, src->mats[i]);
    grow_v(dst, dst->vn + src->vn);
    for (i = 0; i < src->vn; i++) {
        dst->pos[base + i] = mat_apply(xf, src->pos[i]);
        dst->nrm[base + i] = norm(mat_apply_dir(xf, src->nrm[i]));
    }
    dst->vn += src->vn;
    grow_t(dst, dst->tn + src->tn);
    for (i = 0; i < src->tn; i++) {
        mesh_tri(dst, src->idx[i * 3] + base, src->idx[i * 3 + 1] + base,
                 src->idx[i * 3 + 2] + base, src->tri_mat[i] + mbase);
    }
}

/* Weld normals between faces that meet gently, and leave a crease where they
 * do not. Positions go into a hash on a quarter-pixel grid: the pairwise
 * version of this was fine on a few hundred vertices and quadratic on the
 * twenty thousand a subdivided hull carries. */
void mesh_smooth(mesh *m, float max_angle_deg) {
    float lim = cosf((float)(max_angle_deg * M_PI / 180.0));
    int i, j, buckets = 1;
    int *head, *next, *map;
    v3 *acc;
    while (buckets < m->vn * 2) buckets <<= 1;
    head = malloc((size_t)buckets * sizeof *head);
    next = malloc((size_t)m->vn * sizeof *next);
    map = malloc((size_t)m->vn * sizeof *map);
    acc = calloc((size_t)m->vn, sizeof *acc);
    if (!head || !next || !map || !acc) {
        free(head); free(next); free(map); free(acc);
        return;
    }
    for (i = 0; i < buckets; i++) head[i] = -1;
    for (i = 0; i < m->vn; i++) {
        int qx = (int)floorf(m->pos[i].x * 256.0f + 0.5f);
        int qy = (int)floorf(m->pos[i].y * 256.0f + 0.5f);
        int qz = (int)floorf(m->pos[i].z * 256.0f + 0.5f);
        unsigned k = (unsigned)(qx * 73856093) ^ (unsigned)(qy * 19349663)
                   ^ (unsigned)(qz * 83492791);
        k &= (unsigned)(buckets - 1);
        map[i] = i;
        for (j = head[k]; j >= 0; j = next[j]) {
            v3 d = sub(m->pos[i], m->pos[j]);
            if (dot(d, d) < 1e-6f && dot(m->nrm[i], m->nrm[j]) > lim) {
                map[i] = map[j];
                break;
            }
        }
        next[i] = head[k];
        head[k] = i;
    }
    for (i = 0; i < m->vn; i++) acc[map[i]] = add(acc[map[i]], m->nrm[i]);
    for (i = 0; i < m->vn; i++) {
        v3 n = acc[map[i]];
        if (dot(n, n) > 1e-9f) m->nrm[i] = norm(n);
    }
    free(head);
    free(next);
    free(map);
    free(acc);
}

int mesh_write_obj(const mesh *m, const char *path, const char *name) {
    FILE *f = fopen(path, "w");
    int i;
    if (!f) return 0;
    fprintf(f, "# vectorwake hull, generated from client/arena/world.lua\n");
    fprintf(f, "o %s\n", name);
    for (i = 0; i < m->vn; i++)
        fprintf(f, "v %.5f %.5f %.5f\n", m->pos[i].x, m->pos[i].y, m->pos[i].z);
    for (i = 0; i < m->vn; i++)
        fprintf(f, "vn %.5f %.5f %.5f\n", m->nrm[i].x, m->nrm[i].y, m->nrm[i].z);
    for (i = 0; i < m->tn; i++) {
        int a = m->idx[i * 3] + 1, b = m->idx[i * 3 + 1] + 1, c = m->idx[i * 3 + 2] + 1;
        fprintf(f, "f %d//%d %d//%d %d//%d\n", a, a, b, b, c, c);
    }
    fclose(f);
    return 1;
}

/* --- the frame ------------------------------------------------------------ */

target *target_new(int w, int h, int shadow_size) {
    target *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    t->w = w;
    t->h = h;
    t->col = malloc((size_t)w * h * 3 * sizeof *t->col);
    t->depth = malloc((size_t)w * h * sizeof *t->depth);
    t->sm = shadow_size;
    if (shadow_size > 0)
        t->shadow = malloc((size_t)shadow_size * shadow_size * sizeof *t->shadow);
    t->light_vp = mat_identity();
    return t;
}

void target_free(target *t) {
    if (!t) return;
    free(t->col);
    free(t->depth);
    free(t->shadow);
    free(t);
}

void target_clear(target *t, v3 col) {
    int i, n = t->w * t->h;
    for (i = 0; i < n; i++) {
        t->col[i * 3 + 0] = col.x;
        t->col[i * 3 + 1] = col.y;
        t->col[i * 3 + 2] = col.z;
        t->depth[i] = 1e30f;
    }
}

/* --- rasterizer -----------------------------------------------------------
 *
 * One triangle at a time, clipped against the near plane and then walked with
 * edge functions. Attributes are interpolated over 1/w, which is the only part
 * of this worth being careful about: interpolating world position linearly in
 * screen space puts the shading on a surface the geometry does not have. */

typedef struct {
    float x, y;   /* screen pixels */
    float iw;     /* 1/w */
    float depth;  /* view distance, for the z-buffer */
    float ndc;    /* clip z over w, mapped to 0..1, for the shadow map */
    v3 wp;        /* world position */
    v3 n;         /* world normal */
} vout;

/* Clip space before the divide, so the near plane can be cut at w = eps. */
typedef struct {
    float x, y, z, w;
    v3 wp, n;
} vclip;

static vclip clerp(vclip a, vclip b, float t) {
    vclip r;
    r.x = a.x + (b.x - a.x) * t;
    r.y = a.y + (b.y - a.y) * t;
    r.z = a.z + (b.z - a.z) * t;
    r.w = a.w + (b.w - a.w) * t;
    r.wp = add(a.wp, mul(sub(b.wp, a.wp), t));
    r.n = add(a.n, mul(sub(b.n, a.n), t));
    return r;
}

static int clip_near(vclip *in, int n, vclip *out) {
    const float eps = 1e-3f;
    int i, m = 0;
    for (i = 0; i < n; i++) {
        vclip a = in[i], b = in[(i + 1) % n];
        int ina = a.w > eps, inb = b.w > eps;
        if (ina) out[m++] = a;
        if (ina != inb) out[m++] = clerp(a, b, (eps - a.w) / (b.w - a.w));
    }
    return m;
}

static vout project(vclip c, int w, int h) {
    vout o;
    float iw = 1.0f / c.w;
    o.x = (c.x * iw * 0.5f + 0.5f) * (float)w;
    o.y = (0.5f - c.y * iw * 0.5f) * (float)h;
    o.iw = iw;
    o.depth = c.w;
    o.ndc = c.z * iw * 0.5f + 0.5f;
    o.wp = c.wp;
    o.n = c.n;
    return o;
}

static float shadow_at(const target *t, v3 wp, v3 n, float ndl) {
    float bias, sum = 0.0f;
    v3 lp;
    int i, j, s = t->sm;
    if (!t->shadow) return 1.0f;
    /* Offset the lookup along the surface normal rather than only along the
     * light. A depth bias big enough to stop a raised deck shadowing itself
     * is a depth bias big enough to lift every shadow off its own caster. */
    lp = mat_apply(t->light_vp, add(wp, mul(n, 0.55f)));
    if (lp.x < -1.0f || lp.x > 1.0f || lp.y < -1.0f || lp.y > 1.0f) return 1.0f;
    bias = 0.0012f + 0.004f * (1.0f - ndl);
    for (j = -1; j <= 1; j++) {
        for (i = -1; i <= 1; i++) {
            int sx = (int)((lp.x * 0.5f + 0.5f) * (float)s) + i;
            int sy = (int)((0.5f - lp.y * 0.5f) * (float)s) + j;
            float d;
            if (sx < 0 || sy < 0 || sx >= s || sy >= s) { sum += 1.0f; continue; }
            d = t->shadow[sy * s + sx];
            sum += (lp.z * 0.5f + 0.5f) - bias <= d ? 1.0f : 0.0f;
        }
    }
    return sum / 9.0f;
}

static v3 shade(const target *t, const material *mt, v3 wp, v3 n, v3 eye,
                const scene_light *lit) {
    v3 view = norm(sub(eye, wp));
    v3 out = mt->emit;
    float ndl, spec, sh, up;
    v3 h;
    int i;
    if (lit->flat) return add(mt->albedo, mt->emit);
    if (dot(n, view) < 0.0f) n = mul(n, -1.0f);
    /* Hemisphere ambient: a cold sky over a darker floor, so a top face is
     * never the same value as the one under it even out of the key light. */
    up = 0.5f + 0.5f * n.z;
    out = add(out, had(mt->albedo, add(mul(lit->sky, up), mul(lit->ground, 1.0f - up))));
    ndl = dot(n, lit->dir);
    if (ndl > 0.0f) {
        sh = shadow_at(t, wp, n, ndl);
        out = add(out, mul(had(mt->albedo, lit->col), ndl * sh * (1.0f - mt->metal * 0.55f)));
        h = norm(add(lit->dir, view));
        spec = powf(fmaxf(dot(n, h), 0.0f), 2.0f + 220.0f * (1.0f - mt->rough));
        spec *= (0.04f + 0.75f * mt->metal) * sh;
        out = add(out, mul(lit->col, spec));
    }
    /* Rim, in the team's own color. A hull is identified by its edge in this
     * game and that has to survive the move off a flat plane. */
    {
        float r = 1.0f - fmaxf(dot(n, view), 0.0f);
        r = powf(r, lit->rim_power);
        out = add(out, mul(lit->rim, r));
    }
    for (i = 0; i < lit->light_n; i++) {
        v3 d = sub(lit->lights[i].pos, wp);
        float dd = dot(d, d);
        float reach = lit->lights[i].reach;
        float att, nl;
        if (dd > reach * reach) continue;
        att = 1.0f - sqrtf(dd) / reach;
        att *= att;
        d = norm(d);
        nl = fmaxf(dot(n, d), 0.0f);
        out = add(out, mul(had(mt->albedo, lit->lights[i].col), nl * att));
        {
            v3 hh = norm(add(d, view));
            float s = powf(fmaxf(dot(n, hh), 0.0f), 2.0f + 220.0f * (1.0f - mt->rough));
            out = add(out, mul(lit->lights[i].col, s * att * (0.05f + 0.8f * mt->metal)));
        }
    }
    return out;
}

static void raster(target *t, vout a, vout b, vout c, const material *mt,
                   v3 eye, const scene_light *lit, int depth_only) {
    float area, minx, maxx, miny, maxy;
    int x0, x1, y0, y1, x, y;
    area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (fabsf(area) < 1e-9f) return;
    if (area < 0.0f) { vout tmp = b; b = c; c = tmp; area = -area; }
    minx = fminf(a.x, fminf(b.x, c.x));
    maxx = fmaxf(a.x, fmaxf(b.x, c.x));
    miny = fminf(a.y, fminf(b.y, c.y));
    maxy = fmaxf(a.y, fmaxf(b.y, c.y));
    x0 = (int)floorf(minx); x1 = (int)ceilf(maxx);
    y0 = (int)floorf(miny); y1 = (int)ceilf(maxy);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > t->w - 1) x1 = t->w - 1;
    if (y1 > t->h - 1) y1 = t->h - 1;
    for (y = y0; y <= y1; y++) {
        float py = (float)y + 0.5f;
        for (x = x0; x <= x1; x++) {
            float px = (float)x + 0.5f;
            float w0 = (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
            float w1 = (c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x);
            float w2 = (a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x);
            float l0, l1, l2, iw, depth;
            int p;
            if (w0 < 0.0f || w1 < 0.0f || w2 < 0.0f) continue;
            l0 = w1 / area;  /* weight of a */
            l1 = w2 / area;  /* weight of b */
            l2 = w0 / area;  /* weight of c */
            iw = l0 * a.iw + l1 * b.iw + l2 * c.iw;
            depth = l0 * a.depth * a.iw + l1 * b.depth * b.iw + l2 * c.depth * c.iw;
            depth /= iw;
            p = y * t->w + x;
            if (depth_only) {
                /* Normalized device z, interpolated straight in screen space,
                 * which is the one attribute that is already linear there. An
                 * orthographic light has w = 1 everywhere, so storing view
                 * distance here stored the number one and shadowed nothing. */
                float nz = l0 * a.ndc + l1 * b.ndc + l2 * c.ndc;
                if (nz < t->depth[p]) t->depth[p] = nz;
                continue;
            }
            if (depth >= t->depth[p]) continue;
            t->depth[p] = depth;
            {
                v3 wp = mul(add(add(mul(a.wp, l0 * a.iw), mul(b.wp, l1 * b.iw)),
                                mul(c.wp, l2 * c.iw)), 1.0f / iw);
                v3 n = norm(add(add(mul(a.n, l0), mul(b.n, l1)), mul(c.n, l2)));
                v3 col = shade(t, mt, wp, n, eye, lit);
                t->col[p * 3 + 0] = col.x;
                t->col[p * 3 + 1] = col.y;
                t->col[p * 3 + 2] = col.z;
            }
        }
    }
}

static void draw_tris(target *t, const mesh *m, mat4 model, mat4 vp, v3 eye,
                      const scene_light *lit, int depth_only, int w, int h) {
    mat4 mvp = mat_mul(vp, model);
    int i, k;
    for (i = 0; i < m->tn; i++) {
        vclip in[3], out[8];
        int n;
        const material *mt = &m->mats[m->tri_mat[i]];
        for (k = 0; k < 3; k++) {
            int vi = m->idx[i * 3 + k];
            v3 p = m->pos[vi];
            in[k].x = mvp.m[0] * p.x + mvp.m[4] * p.y + mvp.m[8] * p.z + mvp.m[12];
            in[k].y = mvp.m[1] * p.x + mvp.m[5] * p.y + mvp.m[9] * p.z + mvp.m[13];
            in[k].z = mvp.m[2] * p.x + mvp.m[6] * p.y + mvp.m[10] * p.z + mvp.m[14];
            in[k].w = mvp.m[3] * p.x + mvp.m[7] * p.y + mvp.m[11] * p.z + mvp.m[15];
            in[k].wp = mat_apply(model, p);
            in[k].n = mat_apply_dir(model, m->nrm[vi]);
        }
        n = clip_near(in, 3, out);
        for (k = 2; k < n; k++) {
            raster(t, project(out[0], w, h), project(out[k - 1], w, h),
                   project(out[k], w, h), mt, eye, lit, depth_only);
        }
    }
}

void draw_mesh(target *t, const mesh *m, mat4 model, mat4 vp, v3 eye,
               const scene_light *lit) {
    draw_tris(t, m, model, vp, eye, lit, 0, t->w, t->h);
}

/* The shadow pass borrows the same rasterizer with a depth-only target laid
 * over the shadow map, which is why this swaps the buffers rather than
 * carrying a second copy of the triangle walk. */
static target shadow_view;

void shadow_begin(target *t, mat4 light_vp) {
    int i, n = t->sm * t->sm;
    t->light_vp = light_vp;
    for (i = 0; i < n; i++) t->shadow[i] = 1e30f;
}

void shadow_mesh(target *t, const mesh *m, mat4 model) {
    if (!t->shadow) return;
    shadow_view = *t;
    shadow_view.w = t->sm;
    shadow_view.h = t->sm;
    shadow_view.depth = t->shadow;
    shadow_view.shadow = NULL;
    draw_tris(&shadow_view, m, model, t->light_vp, vec(0, 0, 0), NULL, 1,
              t->sm, t->sm);
}

/* --- glowing lines and blobs ---------------------------------------------- */

static void add_px(target *t, int x, int y, v3 col, float a) {
    int p;
    if (x < 0 || y < 0 || x >= t->w || y >= t->h || a <= 0.0f) return;
    p = (y * t->w + x) * 3;
    t->col[p + 0] += col.x * a;
    t->col[p + 1] += col.y * a;
    t->col[p + 2] += col.z * a;
}

void draw_lines(target *t, const glow_line *ln, int n, mat4 vp, v3 eye,
                float px_per_unit) {
    int i;
    (void)eye;
    for (i = 0; i < n; i++) {
        vclip in[2], out[8];
        vout a, b;
        float dx, dy, len, r, step;
        int m, s, steps;
        int k;
        for (k = 0; k < 2; k++) {
            v3 p = k ? ln[i].b : ln[i].a;
            in[k].x = vp.m[0] * p.x + vp.m[4] * p.y + vp.m[8] * p.z + vp.m[12];
            in[k].y = vp.m[1] * p.x + vp.m[5] * p.y + vp.m[9] * p.z + vp.m[13];
            in[k].z = vp.m[2] * p.x + vp.m[6] * p.y + vp.m[10] * p.z + vp.m[14];
            in[k].w = vp.m[3] * p.x + vp.m[7] * p.y + vp.m[11] * p.z + vp.m[15];
            in[k].wp = p;
            in[k].n = vec(0, 0, 1);
        }
        /* A segment is not a loop, so clip it by hand rather than through the
         * polygon clipper. */
        if (in[0].w <= 1e-3f && in[1].w <= 1e-3f) continue;
        if (in[0].w <= 1e-3f)
            in[0] = clerp(in[0], in[1], (1e-3f - in[0].w) / (in[1].w - in[0].w));
        else if (in[1].w <= 1e-3f)
            in[1] = clerp(in[1], in[0], (1e-3f - in[1].w) / (in[0].w - in[1].w));
        (void)out;
        (void)m;
        a = project(in[0], t->w, t->h);
        b = project(in[1], t->w, t->h);
        dx = b.x - a.x;
        dy = b.y - a.y;
        len = sqrtf(dx * dx + dy * dy);
        steps = (int)(len * 2.0f) + 2;
        step = 1.0f / (float)(steps - 1);
        for (s = 0; s < steps; s++) {
            float u = (float)s * step;
            float px = a.x + dx * u;
            float py = a.y + dy * u;
            float depth = 1.0f / (a.iw + (b.iw - a.iw) * u);
            int ix, iy, rad;
            float unit;
            r = ln[i].width * px_per_unit / depth;
            if (r < 0.55f) r = 0.55f;
            /* Samples land every half pixel along the segment, so the brush
             * has to be divided by its own footprint or a fat line at close
             * range comes out proportionally brighter than a thin one far
             * away, which is not how light works. */
            unit = 0.62f / (r + 0.7f);
            rad = (int)r + 2;
            for (iy = -rad; iy <= rad; iy++) {
                for (ix = -rad; ix <= rad; ix++) {
                    int qx = (int)px + ix, qy = (int)py + iy;
                    float ddx = px - ((float)qx + 0.5f);
                    float ddy = py - ((float)qy + 0.5f);
                    float d = sqrtf(ddx * ddx + ddy * ddy);
                    float w, occ;
                    int p;
                    if (qx < 0 || qy < 0 || qx >= t->w || qy >= t->h) continue;
                    w = 1.0f - d / (r + 1.0f);
                    if (w <= 0.0f) continue;
                    w = w * w * w;
                    p = qy * t->w + qx;
                    /* Depth test with slack: a line lying on the hull it came
                     * off is exactly at the surface, and an exact test flickers
                     * it away half a pixel at a time. The slack has to stay
                     * well under how thick a hull is, or every edge on the far
                     * side shows through and the ship reads as glass. */
                    occ = depth <= t->depth[p] + 0.30f ? 1.0f : 0.0f;
                    if (occ == 0.0f) continue;
                    add_px(t, qx, qy, ln[i].col, w * unit);
                }
            }
        }
    }
}

void draw_sprite(target *t, v3 p, float radius, v3 col, float falloff,
                 mat4 vp, v3 eye, int depth_test) {
    vclip c;
    vout o;
    float r;
    int ix, iy, rad;
    (void)eye;
    c.x = vp.m[0] * p.x + vp.m[4] * p.y + vp.m[8] * p.z + vp.m[12];
    c.y = vp.m[1] * p.x + vp.m[5] * p.y + vp.m[9] * p.z + vp.m[13];
    c.z = vp.m[2] * p.x + vp.m[6] * p.y + vp.m[10] * p.z + vp.m[14];
    c.w = vp.m[3] * p.x + vp.m[7] * p.y + vp.m[11] * p.z + vp.m[15];
    if (c.w <= 1e-3f) return;
    c.wp = p;
    c.n = vec(0, 0, 1);
    o = project(c, t->w, t->h);
    r = radius / o.depth * ((float)t->h * 0.5f);
    if (r < 0.4f) r = 0.4f;
    if (r > 900.0f) r = 900.0f;
    rad = (int)r + 1;
    for (iy = -rad; iy <= rad; iy++) {
        for (ix = -rad; ix <= rad; ix++) {
            int qx = (int)o.x + ix, qy = (int)o.y + iy;
            float dx = o.x - ((float)qx + 0.5f);
            float dy = o.y - ((float)qy + 0.5f);
            float d = sqrtf(dx * dx + dy * dy) / r;
            float w;
            if (d >= 1.0f) continue;
            if (qx < 0 || qy < 0 || qx >= t->w || qy >= t->h) continue;
            if (depth_test && o.depth > t->depth[qy * t->w + qx] + 0.5f) continue;
            w = powf(1.0f - d, falloff);
            add_px(t, qx, qy, col, w);
        }
    }
}

/* --- resolve --------------------------------------------------------------
 *
 * Bright pass at a quarter, a couple of separable blurs, add it back, then a
 * filmic curve and a gamma. The dither is the last thing: a smooth dark sky
 * banded on an 8-bit ramp is the one artifact these pictures reliably show. */

static void blur(float *buf, float *tmp, int w, int h, int r) {
    int x, y, i, c;
    float *k = malloc((size_t)(2 * r + 1) * sizeof *k);
    float sum = 0.0f;
    float sigma = (float)r * 0.5f;
    for (i = -r; i <= r; i++) {
        k[i + r] = expf(-(float)(i * i) / (2.0f * sigma * sigma));
        sum += k[i + r];
    }
    for (i = 0; i < 2 * r + 1; i++) k[i] /= sum;
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            float acc[3] = {0, 0, 0};
            for (i = -r; i <= r; i++) {
                int sx = x + i;
                if (sx < 0) sx = 0;
                if (sx >= w) sx = w - 1;
                for (c = 0; c < 3; c++) acc[c] += buf[(y * w + sx) * 3 + c] * k[i + r];
            }
            for (c = 0; c < 3; c++) tmp[(y * w + x) * 3 + c] = acc[c];
        }
    }
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            float acc[3] = {0, 0, 0};
            for (i = -r; i <= r; i++) {
                int sy = y + i;
                if (sy < 0) sy = 0;
                if (sy >= h) sy = h - 1;
                for (c = 0; c < 3; c++) acc[c] += tmp[(sy * w + x) * 3 + c] * k[i + r];
            }
            for (c = 0; c < 3; c++) buf[(y * w + x) * 3 + c] = acc[c];
        }
    }
    free(k);
}

static unsigned rnd_state = 0x2545f491u;
static float rnd(void) {
    rnd_state ^= rnd_state << 13;
    rnd_state ^= rnd_state >> 17;
    rnd_state ^= rnd_state << 5;
    return (float)(rnd_state & 0xffffff) / (float)0x1000000;
}

unsigned char *resolve(target *t, float bloom, float bloom_radius, float gamma) {
    int w = t->w, h = t->h;
    int bw = w / 2, bh = h / 2;
    float *br = malloc((size_t)bw * bh * 3 * sizeof *br);
    float *tmp = malloc((size_t)bw * bh * 3 * sizeof *tmp);
    unsigned char *out = malloc((size_t)w * h * 3);
    int x, y, c;
    if (!br || !tmp || !out) { free(br); free(tmp); return out; }
    for (y = 0; y < bh; y++) {
        for (x = 0; x < bw; x++) {
            for (c = 0; c < 3; c++) {
                float v = 0.0f;
                int j, i;
                for (j = 0; j < 2; j++)
                    for (i = 0; i < 2; i++)
                        v += t->col[((y * 2 + j) * w + x * 2 + i) * 3 + c];
                v *= 0.25f;
                v -= 0.72f;
                br[(y * bw + x) * 3 + c] = v > 0.0f ? v : 0.0f;
            }
        }
    }
    blur(br, tmp, bw, bh, (int)bloom_radius);
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            int sx = x / 2, sy = y / 2;
            float d = rnd() - 0.5f;
            for (c = 0; c < 3; c++) {
                float v = t->col[(y * w + x) * 3 + c]
                        + br[(sy * bw + sx) * 3 + c] * bloom;
                float m;
                /* The usual filmic fit, so a canopy on top of a muzzle flash
                 * keeps some color instead of going to paper white. */
                v = v <= 0.0f ? 0.0f : v;
                m = v * (v * 2.51f + 0.03f) / (v * (v * 2.43f + 0.59f) + 0.14f);
                m = powf(m, 1.0f / gamma);
                m = m * 255.0f + d;
                out[(y * w + x) * 3 + c] =
                    (unsigned char)(m < 0.0f ? 0 : (m > 255.0f ? 255 : m));
            }
        }
    }
    free(br);
    free(tmp);
    return out;
}
