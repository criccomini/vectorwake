/* A small offline renderer: triangles, a z-buffer, one shadow map and a
 * bloom, which is everything these pictures need and nothing they do not.
 *
 * Nothing here runs in the game. The client draws five mesh layers of flat
 * vector art and is going to keep drawing them; this is for looking at what
 * the same hulls would be with a third dimension under them.
 */
#ifndef R3_H
#define R3_H

typedef struct {
    float x, y, z;
} v3;

static inline v3 vec(float x, float y, float z) {
    v3 r;
    r.x = x;
    r.y = y;
    r.z = z;
    return r;
}
static inline v3 add(v3 a, v3 b) { return vec(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline v3 sub(v3 a, v3 b) { return vec(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline v3 mul(v3 a, float s) { return vec(a.x * s, a.y * s, a.z * s); }
static inline v3 had(v3 a, v3 b) { return vec(a.x * b.x, a.y * b.y, a.z * b.z); }
static inline float dot(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline v3 cross(v3 a, v3 b) {
    return vec(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
v3 norm(v3 a);

/* Column-major 4x4, the same order OpenGL uses, because half of these were
 * checked against a shader before they were checked against anything else. */
typedef struct {
    float m[16];
} mat4;

mat4 mat_identity(void);
mat4 mat_mul(mat4 a, mat4 b);
mat4 mat_perspective(float fov_deg, float aspect, float znear, float zfar);
mat4 mat_ortho(float l, float r, float b, float t, float n, float f);
mat4 mat_look(v3 eye, v3 at, v3 up);
mat4 mat_trs(v3 t, float yaw_turns, float scale);
v3 mat_apply(mat4 a, v3 p);        /* point, w divided out */
v3 mat_apply_dir(mat4 a, v3 d);    /* direction, no translation */

/* What a triangle is made of. Emissive is added straight into the frame and
 * into the bloom, which is how a canopy and an engine mouth carry the light
 * the game's glow layer carries in two dimensions. */
typedef struct {
    v3 albedo;
    v3 emit;
    float rough;
    float metal;
    /* Emissive strokes ignore the shadow map: a lamp inside a hull is not
     * lit by the sun and should not go dark when the hull shades it. */
} material;

typedef struct {
    v3 *pos;
    v3 *nrm;
    int vn, vcap;
    int *idx;      /* three vertex indices per triangle */
    int *tri_mat;  /* one material index per triangle */
    int tn, tcap;
    material *mats;
    int mn, mcap;
} mesh;

void mesh_init(mesh *m);
void mesh_free(mesh *m);
int mesh_material(mesh *m, material mat);
int mesh_vertex(mesh *m, v3 p, v3 n);
void mesh_tri(mesh *m, int a, int b, int c, int mat);
/* A flat-shaded triangle: three fresh vertices carrying the face normal. */
void mesh_face(mesh *m, v3 a, v3 b, v3 c, int mat);
void mesh_quad(mesh *m, v3 a, v3 b, v3 c, v3 d, int mat);
void mesh_append(mesh *dst, const mesh *src, mat4 xf);
/* Sum of the normals of every face touching a vertex, normalized: what turns
 * a faceted loft into a smooth one where the two want smoothing. */
void mesh_smooth(mesh *m, float max_angle_deg);
int mesh_write_obj(const mesh *m, const char *path, const char *name);

/* A glowing line, drawn after the solid pass and added rather than replaced.
 * The game's whole look is an outline with light coming off it, so a 3D hull
 * without these is a 3D hull from a different game. */
typedef struct {
    v3 a, b;
    v3 col;
    float width;
} glow_line;

typedef struct {
    v3 pos;
    v3 col;
    float reach;
} point_light;

typedef struct {
    int w, h;
    float *col;    /* linear rgb, three floats a pixel */
    float *depth;  /* view depth, smaller is nearer */
    /* The shadow map, its own little depth-only pass. */
    int sm;
    float *shadow;
    mat4 light_vp;
} target;

typedef struct {
    /* Flat, in the sense the client is flat: a face is its own fill color and
     * nothing else, with the form carried by the outline and by what occludes
     * what. `world.lua` lights a hull from its own nose rather than from the
     * world, so a facet's brightness is baked into the material it was given
     * at build time and no light in this struct touches it. */
    int flat;
    v3 dir;        /* toward the light */
    v3 col;
    v3 sky;        /* hemisphere above */
    v3 ground;     /* hemisphere below */
    v3 rim;
    float rim_power;
    float exposure;
    const point_light *lights;
    int light_n;
} scene_light;

target *target_new(int w, int h, int shadow_size);
void target_free(target *t);
void target_clear(target *t, v3 col);

void shadow_begin(target *t, mat4 light_vp);
void shadow_mesh(target *t, const mesh *m, mat4 model);

void draw_mesh(target *t, const mesh *m, mat4 model, mat4 vp, v3 eye,
               const scene_light *lit);
void draw_lines(target *t, const glow_line *ln, int n, mat4 vp, v3 eye,
                float px_per_unit);
/* A soft additive blob in world space: a muzzle flash, a blast front, a star. */
void draw_sprite(target *t, v3 p, float radius, v3 col, float falloff,
                 mat4 vp, v3 eye, int depth_test);

/* Bright pass, blur, add, tonemap, dither, and out as 8-bit rgb. */
unsigned char *resolve(target *t, float bloom, float bloom_radius, float gamma);

#endif
