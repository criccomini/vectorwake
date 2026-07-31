/* Baseline settings: the neutral tuning a zone starts from and overrides.
 *
 * These numbers are ours (see docs/design/identity.md). They exist so the
 * flight model has a reference feel to tune against, and they are
 * placeholders until a playtest replaces them.
 *
 * Class order matches docs/design/ships.md.
 */
#include "sim/baseline.h"

typedef struct {
    int32_t speed, thrust, rotation, energy, recharge, radius;
    int32_t bullet_damage, bullet_delay, bomb_damage, bomb_delay;
} class_row;

/* Energy per second is recharge/10, so 1500 refills a 1350-energy hull in
 * about nine seconds. Getting this wrong by a factor of ten makes ships that
 * can never shoot twice, which is what the first test run caught. */
static const class_row rows[SIM_MAX_CLASSES] = {
    /* speed thrust  rot  energy  rech  rad  bdmg bdly  bombdmg bombdly */
    {4900, 30, 420, 1350, 1500, 14, 200, 25, 400, 150},  /* Apex    */
    {4400, 22, 340, 1450, 1300, 14, 150, 30, 600, 80},   /* Wedge   */
    {4300, 26, 400, 1500, 1800, 14, 120, 15, 0, 0},      /* Chord   */
    {3200, 14, 240, 2600, 1000, 16, 150, 35, 900, 60},   /* Anvil   */
    {4600, 28, 380, 1200, 2200, 14, 100, 30, 0, 0},      /* Spire   */
    {4700, 24, 390, 1100, 1200, 12, 300, 40, 300, 200},  /* Cipher  */
    {4200, 27, 410, 1600, 1400, 14, 180, 20, 300, 180},  /* Facet   */
    {3800, 20, 330, 1900, 1250, 15, 150, 30, 500, 100},  /* Lattice */
};

const char *const sim_class_names[SIM_MAX_CLASSES] = {
    "Apex", "Wedge", "Chord", "Anvil", "Spire", "Cipher", "Facet", "Lattice"};

void sim_settings_baseline(sim_settings *cfg, const sim_map *map) {
    cfg->class_count = SIM_MAX_CLASSES;
    /* Walls are inelastic: a hit returns about 60% of the speed that went
     * into it and scrubs some of the speed along it. Clipping a wall should
     * hurt, which is what makes tight flying a skill. */
    cfg->bounce = 10;
    cfg->friction = 14;
    cfg->respawn_delay = 300; /* 3 s */
    cfg->prize_delay = 100;   /* a green every second until the map is full */
    cfg->prize_max = 20;
    cfg->prize_life = 3000;   /* 30 s */
    cfg->prize_radius = 16 * 256; /* generous: chasing a green should not be fiddly */
    cfg->prize_lo = 472;      /* inside the arena walls */
    cfg->prize_hi = 552;
    cfg->map = map;

    for (int i = 0; i < SIM_MAX_CLASSES; i++) {
        const class_row *r = &rows[i];
        sim_ship_class *c = &cfg->classes[i];
        sim_class_from_units(c, r->speed, r->thrust, r->rotation, r->energy,
                           r->recharge, r->radius);
        c->bullet_damage = sim_units_energy(r->bullet_damage);
        c->bullet_delay = (uint16_t)r->bullet_delay;
        c->bullet_energy = sim_units_energy(r->bullet_damage + 130);
        if (r->bomb_damage == 0) {
            /* No bomb for this class: an impossible cost and zero damage. */
            c->bomb_damage = 0;
            c->bomb_energy = sim_units_energy(1 << 20);
            c->bomb_delay = 1000;
        } else {
            c->bomb_damage = sim_units_energy(r->bomb_damage);
            c->bomb_delay = (uint16_t)r->bomb_delay;
            c->bomb_energy = sim_units_energy(r->bomb_damage + 200);
        }
    }
}
