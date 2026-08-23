#ifndef VECTORWAKE_FLIGHT_H
#define VECTORWAKE_FLIGHT_H

#include <stdint.h>

// Where a round is at the instant being drawn.
//
// Everything on screen is drawn between the last two ticks, so a round has to
// be too, or it arrives a tick ahead of the ship that fired it. A hull gets
// there by interpolating between its own two ticks, which works because a hull
// keeps its index for as long as it is in the arena.
//
// A round does not keep its index. The core retires one by moving the last
// round into its place, so a slot is a position in an array rather than a
// name, and the round in slot nine this tick may be a different round than the
// one that was there last tick. What used to stand in for a name was a guess:
// same spec, same owner, and near enough that a tick of flight explains the
// gap. Two rounds off a double barrel answer to all three. They leave the same
// muzzle seven and a half degrees apart, which is a quarter of a pixel a tick,
// so they stay inside the sixteen pixels that guess allowed for six tenths of
// a second. Every slot shuffle inside that window drew each of them at the
// other one's position, and the pair came apart on screen and went back
// together when they finally drew far enough apart to be told apart.
//
// There is nothing to guess. A round flies in a straight line at a constant
// speed, so where it was a fraction of a tick ago is where it is now less that
// fraction of its own velocity. That is read off the round in hand, so no
// slot, no pairing and no threshold comes into it.
//
// Two ticks it is not exact on. A round that bounced this tick did not fly
// here along the velocity it now carries, and one fired this tick was not
// anywhere a tick ago. Both are off by at most a tick of travel for one tick,
// which is what the interpolation did to them as well; the second is better
// than it was, since a new round now leaves the muzzle instead of appearing
// two pixels past it.
namespace vw_flight {

struct Point {
    double x;
    double y;
};

// Position is Q8 px and velocity is Q16 px per tick, both as the core holds
// them. `alpha` is the frame's place between the last two ticks: at 1 the
// round is where this tick put it, at 0 it is a whole tick back.
inline Point seen(int32_t x, int32_t y, int32_t vx, int32_t vy, double alpha) {
    const double back = 1.0 - alpha;
    Point p = {x / 256.0 - vx / 65536.0 * back,
               y / 256.0 - vy / 65536.0 * back};
    return p;
}

}  // namespace vw_flight

#endif
