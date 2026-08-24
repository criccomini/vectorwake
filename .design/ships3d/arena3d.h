/* Drawing a recorded fight: the map as real geometry, the hulls in it, and
 * what was in the air at that tick. */
#ifndef ARENA3D_H
#define ARENA3D_H

#include "battle.h"
#include "hull3d.h"
#include "r3.h"

/* How far a wall reaches above and below the plane the ships fly in. There is
 * no floor in this game and there is not one here either: a wall is a slab
 * hanging in the dark, and a ship threads between slabs. */
#define WALL_TOP 7.0f

typedef struct {
    float x, y;      /* where the camera looks, in world units */
    float dist;      /* how far the eye is from that point */
    float tilt;      /* radians up from the plane; near half pi is top down */
    float turn;      /* radians the eye is swung around the focus */
    float fov;
} shot_cam;

typedef struct {
    int width, height;
    int frame;
    shot_cam cam;
    int trail_frames;
    int shadow;
    /* How much of each attitude to draw. Bank is the client's own rule and
     * ships at 1; slip is a proposal and ships at 0. Both are here as knobs
     * because the point of the picture is the comparison. */
    float bank;
    float slip;
} shot_opts;

/* Radians of bank this ship is holding at this frame, worked out the way
 * arena.script works it out: off the heading, smoothed, clamped. Exposed so a
 * still can be drawn of one hull at a known lean. */
float ship_bank(const capture *c, int ship, int frame, float slip_gain);

/* `hulls` is fourteen meshes, a roster per side: the team color is mixed into
 * every fill at build time the way world.lua mixes it at draw time, so a hull
 * is not a mesh plus a tint. Index it team * 7 + class. */
unsigned char *battle_frame(const capture *c, const hull3d *hulls, shot_opts o);

#endif
