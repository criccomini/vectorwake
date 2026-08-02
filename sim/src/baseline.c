/* Baseline settings: the neutral tuning a zone starts from and overrides.
 *
 * These numbers are ours (see docs/design/identity.md). They exist so the
 * flight model has a reference feel to tune against, and they are
 * placeholders until a playtest replaces them.
 *
 * Class order matches docs/design/ships.md.
 */
#include <stddef.h>
#include <string.h>
#include "sim/baseline.h"

/* A hull's whole tech tree, in one row.
 *
 * `gun_rungs` and `bomb_rungs` are the ladders: how many levels of that
 * weapon this hull can climb, where one is a hull that never levels and zero
 * is a hull without the rack at all. `gun_mods` and `bomb_mods` are which
 * add-ons it may ever hold and how many rungs of each -- packed the same way
 * the pilot's are, and the reason the roster stays a roster once greens are
 * flying: shrapnel belongs to bombers and spread belongs to brawlers, and no
 * amount of luck with the prize table changes that. */
typedef struct {
    int32_t speed, thrust, rotation, energy, recharge, radius;
    int32_t bullet_damage, bullet_delay, bomb_damage, bomb_delay;
    uint8_t gun_rungs, bomb_rungs;
    uint16_t gun_mods, bomb_mods;
    /* How many of each charge this hull may carry, by slot: repel, burst. */
    uint8_t charges[SIM_MAX_CHARGES];
} class_row;

/* The charge slots the baseline uses. A zone can fill the other two. */
#define CH_REPEL 0
#define CH_BURST 1

/* Two bits per add-on, so a row reads as a list rather than a number. */
#define M1(a) ((uint16_t)(1u << ((a) * 2)))
#define M2(a) ((uint16_t)(2u << ((a) * 2)))
#define M3(a) ((uint16_t)(3u << ((a) * 2)))

/* Energy per second is recharge/10, so 1500 refills a 1350-energy hull in
 * about nine seconds. Getting this wrong by a factor of ten makes ships that
 * can never shoot twice, which is what the first test run caught. */
static const class_row rows[SIM_MAX_CLASSES] = {
    /* speed thrust  rot  energy  rech  rad  bdmg bdly  bombdmg bombdly
       gun  bomb  gun add-ons                 bomb add-ons        charges */
    {4900, 30, 420, 1350, 1500, 14, 200, 25, 400, 150,
     2, 1, M1(SIM_MOD_MULTI), 0,                        {0, 3, 0, 0}},
    {4400, 22, 340, 1450, 1300, 14, 150, 30, 600, 80,
     1, 2, 0, M1(SIM_MOD_PROX) | M1(SIM_MOD_SHRAPNEL),  {1, 0, 0, 0}},
    {4300, 26, 400, 1500, 1800, 14, 120, 15, 0, 0,
     2, 0, M2(SIM_MOD_MULTI) | M1(SIM_MOD_FREEZE), 0,   {0, 2, 0, 0}},
    {3200, 14, 240, 2600, 1000, 16, 150, 35, 900, 60,
     1, 3, 0, M2(SIM_MOD_SHRAPNEL) | M1(SIM_MOD_PROX),  {2, 0, 0, 0}},
    {4600, 28, 380, 1200, 2200, 14, 100, 30, 0, 0,
     1, 0, M2(SIM_MOD_FREEZE), 0,                       {3, 0, 0, 0}},
    {4700, 24, 390, 1100, 1200, 12, 300, 40, 300, 200,
     3, 1, M1(SIM_MOD_BOUNCE), 0,                       {0, 4, 0, 0}},
    {4200, 27, 410, 1600, 1400, 14, 180, 20, 300, 180,
     2, 1, M2(SIM_MOD_MULTI), M1(SIM_MOD_PROX),         {0, 3, 0, 0}},
    {3800, 20, 330, 1900, 1250, 15, 150, 30, 500, 100,
     1, 2, 0, M2(SIM_MOD_PUSH) | M2(SIM_MOD_BOUNCE),    {4, 0, 0, 0}},
};

const char *const sim_class_names[SIM_MAX_CLASSES] = {
    "Apex", "Wedge", "Chord", "Anvil", "Spire", "Cipher", "Facet", "Lattice"};

void sim_settings_baseline(sim_settings *cfg, const sim_map *map) {
    cfg->class_count = SIM_MAX_CLASSES;
    cfg->spec_count = 0;
    cfg->pattern_count = 0;
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
    cfg->flag_radius = 18 * 256;
    cfg->flag_drop_cooldown = 200; /* 2 s before a dropped flag can be retaken */
    cfg->prize_lo = 472;      /* inside the arena walls */
    cfg->prize_hi = 552;
    cfg->map = map;
    /* Doors breathe on a six second cycle, open for four of it: long enough
     * to commit to a crossing, short enough that the choice matters. */
    cfg->door_period = 600;
    cfg->door_open = 400;
    cfg->wormhole_pull = sim_units_speed(90);
    cfg->wormhole_range = 220 * 256;

    /* What a green turns out to be. Stats are the bread of the tree, levels
     * are the thing worth crossing a map for, and add-ons sit between them.
     * These are relative and read against one hull's pool, so an Apex -- five
     * stats, one level, one add-on -- sees a level about one green in twenty.
     *
     * Rust is the number to tune first. One green in ten takes something
     * back, and it can only take what you are holding, so it costs a loaded
     * pilot and never touches one who has just spawned. */
    for (int i = 0; i < SIM_UP_COUNT; i++) cfg->prize_weight[i] = 100;
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        cfg->prize_weight[SIM_PRIZE_LEVEL(t)] = 30;
        for (int m = 0; m < SIM_MOD_COUNT; m++)
            cfg->prize_weight[SIM_PRIZE_MOD(t, m)] = 20;
    }
    cfg->rust_chance = 100;
    /* A kill is worth three bounty to the killer, so a pilot on a streak
     * becomes a target without having touched a green -- and a flag carrier
     * is worth crossing the map for. The original's reference zone used six
     * and a hundred; three keeps the number over a ship mostly a readout of
     * what they are carrying, which is what the tech tree made it. */
    cfg->bounty_per_kill = 3;
    cfg->points_per_flag = 100;

    /* What one rung of each add-on is worth, in the units of the field it
     * moves. These are the numbers that decide whether an add-on is a nice
     * surprise or the thing everyone chases, so they live here in the open
     * rather than inside the transform that applies them. */
    cfg->mod_step[SIM_MOD_MULTI] = 2;              /* a pair of extra barrels */
    cfg->mod_step[SIM_MOD_BOUNCE] = 1;             /* one more wall survived */
    cfg->mod_step[SIM_MOD_PROX] = 24 * 256;        /* 24 px of fuse */
    cfg->mod_step[SIM_MOD_SHRAPNEL] = 0;           /* a pattern, not a number */
    cfg->mod_step[SIM_MOD_FREEZE] = 100;           /* a second of no recharge */
    cfg->mod_step[SIM_MOD_PUSH] = sim_units_speed(1200);
    cfg->mod_spread = 65536 / 24;                  /* fifteen degrees */

    /* Shrapnel, one pattern per rung: four fragments, then eight, then
     * sixteen. The fragments themselves are one spec -- a rung of shrapnel
     * buys more of them rather than better ones, so the add-on reads as
     * "more" the way every other add-on does. */
    {
        sim_weapon_spec frag;
        memset(&frag, 0, sizeof frag);
        frag.speed = sim_units_speed(1100);
        frag.life = 45;
        frag.on_wall = SIM_WALL_END;
        frag.damage = sim_units_energy(60);
        frag.splinter = SIM_NO_PATTERN;
        uint8_t frag_spec = (uint8_t)sim_add_spec(cfg, &frag);
        cfg->mod_splinter[0] = SIM_NO_PATTERN;   /* rung zero is no shrapnel */
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            sim_fire_pattern shell;
            memset(&shell, 0, sizeof shell);
            shell.spec = frag_spec;
            shell.count = (uint8_t)(4 << (k - 1));
            shell.spacing = (uint16_t)(65536 / shell.count);
            cfg->mod_splinter[k] = (uint8_t)sim_add_pattern(cfg, &shell);
        }
    }

    /* The two charges the roster uses. A charge is a pattern plus an
     * inventory and nothing else: the repel is `push` with no damage at all,
     * which the weapon model has been able to express since the day it was
     * written, and the burst is sixteen rounds at a full turn's spacing --
     * the rosette that motivated `count` and `spacing` in the first place.
     *
     * Both are deliberately expensive to fire and slow to follow up. A charge
     * is a thing you spend, and spending it should be a decision. */
    {
        sim_weapon_spec rp;
        memset(&rp, 0, sizeof rp);
        rp.speed = 0;
        rp.life = 1;
        rp.on_wall = SIM_WALL_PASS;
        rp.expire_ends = 1;
        rp.blast = 260 * 256;
        rp.push = sim_units_speed(3400);
        rp.splinter = SIM_NO_PATTERN;
        sim_fire_pattern rf;
        memset(&rf, 0, sizeof rf);
        rf.spec = (uint8_t)sim_add_spec(cfg, &rp);
        rf.count = 1;
        rf.delay = 120;
        cfg->charge[0] = (uint8_t)sim_add_pattern(cfg, &rf);

        sim_weapon_spec bs;
        memset(&bs, 0, sizeof bs);
        bs.speed = sim_units_speed(1800);
        bs.life = 70;
        bs.on_wall = SIM_WALL_END;
        bs.damage = sim_units_energy(180);
        bs.splinter = SIM_NO_PATTERN;
        sim_fire_pattern bf;
        memset(&bf, 0, sizeof bf);
        bf.spec = (uint8_t)sim_add_spec(cfg, &bs);
        bf.count = 16;
        bf.spacing = 65536 / 16;
        bf.delay = 120;
        cfg->charge[1] = (uint8_t)sim_add_pattern(cfg, &bf);

        cfg->charge[2] = SIM_NO_PATTERN;
        cfg->charge[3] = SIM_NO_PATTERN;
        for (int k = 0; k < SIM_MAX_CHARGES; k++)
            cfg->prize_weight[SIM_PRIZE_CHARGE(k)] = 25;
    }

    for (int i = 0; i < SIM_MAX_CLASSES; i++) {
        const class_row *r = &rows[i];
        sim_ship_class *c = &cfg->classes[i];
        sim_class_from_units(c, r->speed, r->thrust, r->rotation, r->energy,
                           r->recharge, r->radius);
        c->mod_max[SIM_TRIG_GUN] = r->gun_mods;
        c->mod_max[SIM_TRIG_BOMB] = r->bomb_mods;
        for (int k = 0; k < SIM_MAX_CHARGES; k++)
            c->charge_max[k] = r->charges[k];

        /* A ladder per trigger, built from the roster row. A rung is the same
         * weapon harder -- 40% more damage each -- and nothing else: an
         * add-on is what changes a weapon's character, and keeping the two
         * apart is what stops the table needing a row per combination.
         *
         * The cost does not climb with the rung. A level is a straight
         * upgrade, which is what makes it worth crossing the map for; what
         * stops it running away with a match is that the pilot holding it is
         * carrying a bounty everyone can see.
         *
         * Firing costs are a fraction of the ship's own energy, taken from
         * the original's numbers: it gave every ship 1700 maximum energy and
         * charged 20 for a bullet and 300 for a bomb. Pricing a shot off its
         * damage instead -- which is what this did -- made a bullet cost 35%
         * of a full bar and a bomb 63%, so the bomb key did nothing at all
         * unless you had been left alone to recharge, and silently. */
        for (int k = 0; k < r->gun_rungs && k < SIM_MAX_RUNGS; k++) {
            sim_weapon_spec bolt;
            memset(&bolt, 0, sizeof bolt);
            bolt.speed = sim_units_speed(2000);
            bolt.life = 200;
            bolt.on_wall = SIM_WALL_END;
            bolt.damage = sim_units_energy(r->bullet_damage * (5 + 2 * k) / 5);
            bolt.splinter = SIM_NO_PATTERN;

            sim_fire_pattern gun;
            memset(&gun, 0, sizeof gun);
            gun.spec = (uint8_t)sim_add_spec(cfg, &bolt);
            gun.count = 1;
            gun.energy = (int32_t)((int64_t)c->max_energy * 20 / 1700);
            gun.delay = (uint16_t)r->bullet_delay;
            c->trigger[SIM_TRIG_GUN][k] = (uint8_t)sim_add_pattern(cfg, &gun);
        }

        /* A hull with no bomb rack has an empty ladder rather than an
         * unaffordable pattern. The trigger is simply dead, and a bomb level
         * green passes it by. */
        for (int k = 0; k < r->bomb_rungs && k < SIM_MAX_RUNGS; k++) {
            sim_weapon_spec sh;
            memset(&sh, 0, sizeof sh);
            sh.speed = sim_units_speed(1500);
            sh.life = 500;
            sh.on_wall = SIM_WALL_END;
            sh.damage = sim_units_energy(r->bomb_damage * (5 + 2 * k) / 5);
            sh.blast = 48 * 256;
            sh.splinter = SIM_NO_PATTERN;

            sim_fire_pattern bomb;
            memset(&bomb, 0, sizeof bomb);
            bomb.spec = (uint8_t)sim_add_spec(cfg, &sh);
            bomb.count = 1;
            bomb.energy = (int32_t)((int64_t)c->max_energy * 300 / 1700);
            bomb.delay = (uint16_t)r->bomb_delay;
            bomb.recoil = sim_units_speed(200);
            c->trigger[SIM_TRIG_BOMB][k] = (uint8_t)sim_add_pattern(cfg, &bomb);
        }
    }
}

/* ---- maps ---- */

void sim_map_index(sim_map *m) {
    m->feature_count = 0;
    for (int ty = 0; ty < SIM_MAP_TILES; ty++) {
        for (int tx = 0; tx < SIM_MAP_TILES; tx++) {
            uint8_t t = m->tile[(size_t)ty * SIM_MAP_TILES + (size_t)tx];
            int cls = SIM_TILE_CLASS(t);
            if (cls != SIM_TILE_WORMHOLE && cls != SIM_TILE_GOAL
                && cls != SIM_TILE_TURF && cls != SIM_TILE_SPAWN)
                continue;
            if (m->feature_count >= SIM_MAX_FEATURES) return;
            sim_feature *f = &m->features[m->feature_count++];
            f->tx = (uint16_t)tx;
            f->ty = (uint16_t)ty;
            f->kind = (uint8_t)cls;
            f->variant = SIM_TILE_VARIANT(t);
        }
    }
}

int sim_map_spawn(const sim_map *m, uint8_t team, uint32_t nth,
                  uint16_t *tx, uint16_t *ty) {
    /* Two passes: this team's own spawns first, and if it has none, anybody's.
     * A map that only marks neutral starts still works, and a team with no
     * marked start is better off inside the walls than correct. */
    for (int pass = 0; pass < 2; pass++) {
        uint32_t n = 0;
        for (uint16_t f = 0; f < m->feature_count; f++)
            if (m->features[f].kind == SIM_TILE_SPAWN
                && (pass == 1 || m->features[f].variant == team))
                n++;
        if (n == 0) continue;
        uint32_t want = nth % n, seen = 0;
        for (uint16_t f = 0; f < m->feature_count; f++) {
            const sim_feature *ft = &m->features[f];
            if (ft->kind != SIM_TILE_SPAWN) continue;
            if (pass == 0 && ft->variant != team) continue;
            if (seen++ != want) continue;
            *tx = ft->tx;
            *ty = ft->ty;
            return 1;
        }
    }
    return 0;
}

static void fill(sim_map *m, int x0, int y0, int x1, int y1, uint8_t t) {
    for (int ty = y0; ty <= y1; ty++)
        for (int tx = x0; tx <= x1; tx++)
            m->tile[(size_t)ty * SIM_MAP_TILES + (size_t)tx] = t;
}

/* The public arena: a wall around the outside, four pillars, and baffles that
 * break line of sight through the middle. Two safe zones on the long axis to
 * spawn into and to stop in, a pair of doors on the short one that open and
 * shut out of phase.
 *
 * No wormhole. One reaches 220 px, which is fourteen tiles of an arena that
 * is eighty-four across, so a single well placed anywhere near the middle
 * bends every crossing in the room. The bot ladder found this before a
 * player would have: pilots spawned eight tiles from one stopped fighting
 * each other entirely and orbited it instead, and the tournament graded a
 * whole roster as equal because nobody ever landed a shot. The feature is
 * real and tested; a map big enough to hold one should place it. */
void sim_map_arena(sim_map *m) {
    const int LO = 470, HI = 554;
    memset(m->tile, SIM_TILE_EMPTY, sizeof m->tile);
    fill(m, LO, LO, HI, LO + 1, SIM_TILE_SOLID);
    fill(m, LO, HI - 1, HI, HI, SIM_TILE_SOLID);
    fill(m, LO, LO, LO + 1, HI, SIM_TILE_SOLID);
    fill(m, HI - 1, LO, HI, HI, SIM_TILE_SOLID);
    fill(m, 489, 489, 495, 495, SIM_TILE_SOLID);
    fill(m, 529, 489, 535, 495, SIM_TILE_SOLID);
    fill(m, 489, 529, 495, 535, SIM_TILE_SOLID);
    fill(m, 529, 529, 535, 535, SIM_TILE_SOLID);
    fill(m, 505, 480, 519, 483, SIM_TILE_SOLID);
    fill(m, 505, 541, 519, 544, SIM_TILE_SOLID);
    fill(m, 480, 505, 483, 519, SIM_TILE_SOLID);
    fill(m, 541, 505, 544, 519, SIM_TILE_SOLID);

    /* In the open channels between the pillars, clear of everything by four
     * tiles or more, so every way out of a zone continues somewhere.
     *
     * The first placement was a pocket against the boundary wall, and the
     * second still funnelled west into one. A traced flight showed the zone
     * itself transparent -- full clamp speed across every safe tile -- and
     * then a bounce-thrust trap in the slot beyond it: held thrust against
     * an inelastic wall converges to a tenth of a pixel per tick, which a
     * pilot reports as the zone being sticky. The zone was never sticky.
     * The cul-de-sac behind it was. */
    fill(m, 488, 508, 494, 516, SIM_TILE_SAFE);
    fill(m, 530, 508, 536, 516, SIM_TILE_SAFE);

    fill(m, 505, 484, 519, 485, SIM_TILE(SIM_TILE_DOOR, 0));
    fill(m, 505, 539, 519, 540, SIM_TILE(SIM_TILE_DOOR, 4));

    fill(m, 500, 500, 502, 502, SIM_TILE_UNDER);
    fill(m, 522, 522, 524, 524, SIM_TILE_UNDER);

    /* Starts, four a side, in the corners the roster already used. Carried by
     * the map so a zone can be pointed at a different one without knowing
     * anything about its geometry -- which is what went wrong the first time
     * a custom map was loaded: every ship began outside its walls and drifted
     * off at twenty tiles a second. */
    fill(m, 486, 486, 486, 486, SIM_TILE(SIM_TILE_SPAWN, 1));
    fill(m, 538, 486, 538, 486, SIM_TILE(SIM_TILE_SPAWN, 1));
    fill(m, 538, 538, 538, 538, SIM_TILE(SIM_TILE_SPAWN, 1));
    fill(m, 486, 538, 486, 538, SIM_TILE(SIM_TILE_SPAWN, 1));
    fill(m, 512, 478, 512, 478, SIM_TILE(SIM_TILE_SPAWN, 0));
    fill(m, 478, 512, 478, 512, SIM_TILE(SIM_TILE_SPAWN, 0));
    fill(m, 546, 512, 546, 512, SIM_TILE(SIM_TILE_SPAWN, 0));
    fill(m, 512, 546, 512, 546, SIM_TILE(SIM_TILE_SPAWN, 0));
    sim_map_index(m);
}

/* The duel arena: small, symmetric, and bare. No wormhole and no safe zone --
 * a duel is decided by the two pilots and nothing else, and a room this size
 * with somewhere invulnerable in it is not a duel. The bot ladder found that
 * too: a pilot that wandered into one stopped dead, could not be shot and
 * could not shoot, and the match ended with nobody having landed anything. */
void sim_map_duel(sim_map *m) {
    const int LO = 496, HI = 528;
    memset(m->tile, SIM_TILE_EMPTY, sizeof m->tile);
    fill(m, LO, LO, HI, LO + 1, SIM_TILE_SOLID);
    fill(m, LO, HI - 1, HI, HI, SIM_TILE_SOLID);
    fill(m, LO, LO, LO + 1, HI, SIM_TILE_SOLID);
    fill(m, HI - 1, LO, HI, HI, SIM_TILE_SOLID);
    fill(m, 505, 505, 509, 509, SIM_TILE_SOLID);
    fill(m, 515, 515, 519, 519, SIM_TILE_SOLID);
    fill(m, 512, 522, 512, 522, SIM_TILE(SIM_TILE_SPAWN, 0));
    fill(m, 512, 502, 512, 502, SIM_TILE(SIM_TILE_SPAWN, 1));
    sim_map_index(m);
}
