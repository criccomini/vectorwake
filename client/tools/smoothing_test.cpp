#include "../ext/simcore/src/smoothing.h"

#include <math.h>
#include <stdio.h>

static int failures = 0;

static void check(const char* name, bool ok) {
    printf("%-58s %s\n", name, ok ? "ok" : "FAIL");
    if (!ok) failures++;
}

int main() {
    check("a newly authoritative repel is recognized",
          vw_smoothing::authoritative_repel(0, 210));
    check("an active repel counting down is not new",
          !vw_smoothing::authoritative_repel(210, 208));
    check("a second shove restarts repel smoothing",
          vw_smoothing::authoritative_repel(80, 220));

    vw_smoothing::Position ordinary =
        vw_smoothing::settle_position(91.0, 0.0, true, false);
    check("an ordinary 91 px correction still snaps",
          ordinary.snapped && ordinary.limited && ordinary.x == 0.0);

    vw_smoothing::Position repel =
        vw_smoothing::settle_position(91.0, 0.0, true, true);
    check("a confirmed 91 px repel becomes presentation debt",
          !repel.snapped && !repel.limited
              && fabs(repel.x - 91.0) < 0.001);

    vw_smoothing::Position capped =
        vw_smoothing::settle_position(150.0, 0.0, true, true);
    check("repel debt has a bounded allowance",
          !capped.snapped && capped.limited
              && fabs(capped.x - 128.0) < 0.001);

    vw_smoothing::Position teleport =
        vw_smoothing::settle_position(193.0, 0.0, true, true);
    check("an implausible repel correction still snaps",
          teleport.snapped && teleport.limited && teleport.x == 0.0);

    check("repel debt halves in 45 ms",
          fabs(vw_smoothing::decay_factor(0.045,
                                          vw_smoothing::REPEL_HALF_LIFE)
               - 0.5) < 0.000001);

    return failures == 0 ? 0 : 1;
}
