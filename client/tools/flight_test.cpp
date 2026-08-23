// Where a round is drawn, checked against the core that flew it.
//
// The extension cannot run here, but the arithmetic it does can, and the
// simulation it reads is next door. So this flies real rounds and asks whether
// `vw_flight::seen` puts each one where the tick before actually had it.
//
// The case that matters is a double barrel. Its two rounds leave the same
// muzzle a quarter of a pixel a tick apart, which used to be close enough that
// the renderer could not tell them apart and drew each at the other's
// position whenever the core moved one between slots.
#include "../ext/simcore/src/flight.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "sim/baseline.h"
#include "sim/sim.h"

static int failures = 0;

static void ok(bool cond, const char* what) {
    printf("%-58s %s\n", what, cond ? "ok" : "FAILED");
    if (!cond) failures++;
}

static sim_map MAP;
static sim_settings CFG;
static sim_state CUR, PREV, NXT;

static void walled_map(void) {
    sim_map_size(&MAP, SIM_MAP_TILES, SIM_MAP_TILES);
    for (int i = 0; i < SIM_MAP_TILES; i++) {
        SIM_MAP_AT(&MAP, i, 0) = SIM_TILE_SOLID;
        SIM_MAP_AT(&MAP, i, SIM_MAP_TILES - 1) = SIM_TILE_SOLID;
        SIM_MAP_AT(&MAP, 0, i) = SIM_TILE_SOLID;
        SIM_MAP_AT(&MAP, SIM_MAP_TILES - 1, i) = SIM_TILE_SOLID;
    }
    sim_map_index(&MAP);
}

static void step(uint16_t buttons) {
    sim_input in;
    memset(&in, 0, sizeof in);
    in.ship = 0;
    in.buttons = buttons;
    sim_events ev;
    sim_step(&NXT, &CUR, &in, 1, &CFG, &ev);
    PREV = CUR;
    CUR = NXT;
}

// A hull with the spray rung the double barrel became, pointing up, firing.
static void fire_a_pair(void) {
    sim_init(&CUR, 1);
    sim_spawn(&CUR, 0, 0, 8192, 8192, 0, &CFG);
    CUR.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
    step(SIM_BTN_FIRE);
}

int main(void) {
    walled_map();
    memset(&CFG, 0, sizeof CFG);
    sim_settings_baseline(&CFG, &MAP);

    fire_a_pair();
    ok(CUR.weapon_count == 2, "one rung of spray puts two rounds in the air");

    // What the pair is: close enough together that nothing about a position
    // can name which is which. This is the geometry the old renderer tried to
    // read an identity out of, so it is worth stating rather than implying.
    {
        double dx = (CUR.weapons[0].x - CUR.weapons[1].x) / 256.0;
        double dy = (CUR.weapons[0].y - CUR.weapons[1].y) / 256.0;
        ok(sqrt(dx * dx + dy * dy) < 1.0,
           "and they leave under a pixel apart");
    }

    // A whole tick back is the tick before, exactly, for as long as a round is
    // simply flying. Both rounds of the pair, every tick, to a hundredth of a
    // pixel: the arithmetic is in doubles either side, so the only slack here
    // is the rounding the core does when it walks a tick in samples.
    {
        double worst = 0.0;
        int checked = 0;
        for (int t = 0; t < 200; t++) {
            step(0);
            if (CUR.weapon_count != 2 || PREV.weapon_count != 2) break;
            for (int k = 0; k < 2; k++) {
                const sim_weapon* c = &CUR.weapons[k];
                const sim_weapon* p = &PREV.weapons[k];
                vw_flight::Point at =
                    vw_flight::seen(c->x, c->y, c->vx, c->vy, 0.0);
                double ex = fabs(at.x - p->x / 256.0);
                double ey = fabs(at.y - p->y / 256.0);
                if (ex > worst) worst = ex;
                if (ey > worst) worst = ey;
                checked++;
            }
        }
        ok(checked > 300, "the pair flies long enough to be worth checking");
        printf("   worst miss over %d readings: %.4f px\n", checked, worst);
        ok(worst < 0.01, "a round at alpha 0 is where the tick before had it");
    }

    // And at the far end of the frame it is where this tick put it, which is
    // what a hull's interpolation gives at alpha 1 as well.
    {
        const sim_weapon* c = &CUR.weapons[0];
        vw_flight::Point at = vw_flight::seen(c->x, c->y, c->vx, c->vy, 1.0);
        ok(at.x == c->x / 256.0 && at.y == c->y / 256.0,
           "and at alpha 1 it is where this tick put it");
    }

    // Half a frame is half a tick of flight, so the drawing moves at the speed
    // the round moves at rather than in tick-sized jumps.
    {
        const sim_weapon* c = &CUR.weapons[0];
        vw_flight::Point a = vw_flight::seen(c->x, c->y, c->vx, c->vy, 0.0);
        vw_flight::Point b = vw_flight::seen(c->x, c->y, c->vx, c->vy, 0.5);
        vw_flight::Point d = vw_flight::seen(c->x, c->y, c->vx, c->vy, 1.0);
        double first = hypot(b.x - a.x, b.y - a.y);
        double second = hypot(d.x - b.x, d.y - b.y);
        ok(fabs(first - second) < 1e-9 && first > 0.0,
           "and it crosses the frame at an even speed");
    }

    // The point of all of it: what a round is drawn at owes nothing to any
    // other round. Read the pair, swap the two rounds between their slots the
    // way the core does when one ahead of them retires, and read it again.
    {
        fire_a_pair();
        for (int t = 0; t < 30; t++) step(0);
        vw_flight::Point before[2];
        for (int k = 0; k < 2; k++) {
            const sim_weapon* c = &CUR.weapons[k];
            before[k] = vw_flight::seen(c->x, c->y, c->vx, c->vy, 0.35);
        }
        sim_weapon swap = CUR.weapons[0];
        CUR.weapons[0] = CUR.weapons[1];
        CUR.weapons[1] = swap;
        bool held = true;
        for (int k = 0; k < 2; k++) {
            const sim_weapon* c = &CUR.weapons[k];
            vw_flight::Point at =
                vw_flight::seen(c->x, c->y, c->vx, c->vy, 0.35);
            const vw_flight::Point& was = before[1 - k];
            if (at.x != was.x || at.y != was.y) held = false;
        }
        ok(held, "a round moving slots is still drawn where it is");
    }

    if (failures) {
        printf("\n%d flight check(s) failed\n", failures);
        return 1;
    }
    printf("\nall flight position checks pass\n");
    return 0;
}
