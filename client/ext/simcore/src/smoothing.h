#ifndef VECTORWAKE_SMOOTHING_H
#define VECTORWAKE_SMOOTHING_H

#include <math.h>

namespace vw_smoothing {

const double LOCAL_POS_SNAP = 64.0;
const double REMOTE_POS_SNAP = 48.0;
const double LOCAL_POS_MAX = 40.0;
const double REMOTE_POS_MAX = 16.0;
const double REPEL_POS_SNAP = 192.0;
const double REPEL_POS_MAX = 128.0;
const double REPEL_HALF_LIFE = 0.045;

struct Position {
    double x;
    double y;
    bool snapped;
    bool limited;
};

inline bool authoritative_repel(unsigned before, unsigned after) {
    return after > before;
}

inline Position settle_position(double x, double y, bool local, bool repel) {
    const double snap = repel ? REPEL_POS_SNAP
                              : (local ? LOCAL_POS_SNAP : REMOTE_POS_SNAP);
    const double limit = repel ? REPEL_POS_MAX
                               : (local ? LOCAL_POS_MAX : REMOTE_POS_MAX);
    const double d2 = x * x + y * y;
    Position out = {x, y, false, false};
    if (d2 > snap * snap) {
        out.x = out.y = 0.0;
        out.snapped = true;
        out.limited = true;
    } else if (d2 > limit * limit) {
        const double k = limit / sqrt(d2);
        out.x *= k;
        out.y *= k;
        out.limited = true;
    }
    return out;
}

inline double decay_factor(double dt, double half_life) {
    return pow(0.5, dt / half_life);
}

}  // namespace vw_smoothing

#endif
