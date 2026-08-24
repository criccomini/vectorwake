/* The seven hulls, with a third dimension put under them.
 *
 * Every number these meshes are built from comes out of
 * client/arena/world.lua by way of hull_export.py, so a hull here has the
 * outline, the hardpoints, the lamps and the engine mouths the game already
 * draws, and sits inside the footprint sim/src/baseline.c gives its class.
 * What is invented is the height, and only the height.
 */
#ifndef HULL3D_H
#define HULL3D_H

#include "r3.h"

typedef struct {
    mesh body;
    glow_line *lines;
    int line_n;
    /* Where thrust leaves, and where a round leaves, in ship-local space, so
     * a scene can hang a plume or a muzzle flash off the model rather than
     * off a guess. */
    v3 jets[8];
    int jet_n;
    v3 muzzles[4];
    int muzzle_n;
    float nose, tail, beam, height;
    const char *name;
} hull3d;

/* `team` tints the rim strips, the canopy and the lamps. The body itself
 * stays gunmetal on both sides: shape carries class, color carries team, and
 * a hull cut out of one sheet of neon carries neither. */
void hull3d_build(hull3d *h, int cls, v3 team);
void hull3d_free(hull3d *h);
int hull3d_count(void);
const char *hull3d_name(int cls);

#endif
