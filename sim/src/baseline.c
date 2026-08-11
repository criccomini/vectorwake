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
 * add-ons it may ever hold and how many rungs of each, packed the same way the
 * pilot's are. Availability follows the original -- every hull may hold the
 * add-ons it had prizes for -- so what makes a bomber a bomber is the rack it
 * has and the ceiling it climbs to, not a list of things nobody else may
 * touch. See the table's own note. */
typedef struct {
    /* What still varies between hulls, which is everything the original
     * varies and nothing else. Its whole per-ship differentiation is ten
     * settings and two of them are here: MaxBombs, which is 3 on the
     * Leviathan and 2 elsewhere, and ShrapnelMax, which is 31 on the Shark
     * and 8 elsewhere. The rest are flags for weapons this core has no idea
     * about -- cloak, antiwarp, bricks, portals, thors, mines.
     *
     * `gun_rungs` and `bomb_rungs` are MaxGuns and MaxBombs: how many levels
     * of that weapon this hull climbs. `gun_mods` and `bomb_mods` are which
     * add-ons it may hold and how many rungs of each, packed two bits apiece
     * the way the pilot's are. */
    uint8_t gun_rungs, bomb_rungs;
    uint16_t gun_mods, bomb_mods;
    /* How many of each charge, by slot: repel, burst. RepelMax and BurstMax
     * are 3 on all eight of the original's ships and none of them starts
     * holding any. */
    uint8_t charges[SIM_MAX_CHARGES];
} class_row;

/* Flight, identical on every hull, straight off the original's ship files.
 * All eight of them carry the same numbers: a Warbird and a Leviathan fly
 * exactly alike there, and what tells them apart is the ten capability flags
 * and nothing else.
 *
 * The footprint is the exception and it is not here: those files carry no
 * ship size at all, so there is nothing to inherit and the extents are
 * measured off our own hulls in `hull_extent` below.
 *
 * The step counts fall out rather than being chosen: five greens take speed
 * from 2010 to its 3250 ceiling, seven take energy from 1000 to 1700, and one
 * is enough for thrust. `eff` clamps at the ceiling, so a sixth speed green
 * is simply worth nothing, which is what the original does with it too. */
static const sim_class_units flight = {
    2010, 250, 3250,      /* InitialSpeed, UpgradeSpeed, MaximumSpeed */
    15,     2,   17,      /* thrust */
    200,   40,  230,      /* rotation */
    1000, 100, 1700,      /* energy */
    400,  166, 1150,      /* recharge */
};

/* The weapons, also identical on every hull, from the same files and the
 * arena settings beside them. */
#define BULLET_DAMAGE   200   /* BulletDamageLevel: what an L1 bullet does */
#define BULLET_UPGRADE  100   /* BulletDamageUpgrade: and each level after */
#define BULLET_DELAY     25   /* BulletFireDelay */
#define BULLET_ENERGY    20   /* BulletFireEnergy */
#define BOMB_DAMAGE     750   /* BombDamageLevel, "for all bomb levels" */
#define BOMB_DELAY      150   /* BombFireDelay */
#define BOMB_ENERGY     300   /* BombFireEnergy */
#define BOMB_ENERGY_UP   50   /* BombFireEnergyUpgrade, per level */
#define BOMB_THRUST     400   /* BombThrust: the recoil of letting one go */
#define BOMB_BLAST       80   /* BombExplodePixels, for an L1 bomb */

/* The charge slots the baseline uses. A zone can fill the other two. */
#define CH_REPEL 0
#define CH_BURST 1

/* Two bits per add-on, so a row reads as a list rather than a number. */
#define M1(a) ((uint16_t)(1u << ((a) * 2)))
#define M2(a) ((uint16_t)(2u << ((a) * 2)))
#define M3(a) ((uint16_t)(3u << ((a) * 2)))

/* Every hull gets multifire and bouncing bullets on its gun, and proximity
 * and shrapnel on its bomb if it has one. That is the original's rule: those
 * are entries in [PrizeWeight] with no per-ship gate anywhere in its config,
 * so any ship can be handed any of them.
 *
 * What it varies is the *ceiling*, not the availability. Its whole per-ship
 * differentiation is nine settings, and the ones that matter here are
 * `MaxBombs` -- 3 on the Leviathan against 2 everywhere else -- `ShrapnelMax`
 * at 8 against the Shark's 31, and `BombBounceCount`, which is 1 on the
 * Lancaster alone. So a bomber is not the hull that *may* hold shrapnel, it
 * is the hull that holds more of it than anyone.
 *
 * Freeze and push have no setting to copy, because the original has no such
 * prize. They stay roster traits, which is a choice of ours and the only part
 * of this table that is.
 *
 * A hull with no rack (`bomb_rungs` 0) gets no bomb add-ons: an add-on is a
 * transform on a trigger, and a trigger that does not exist cannot be
 * transformed. That, not the add-on list, is what would keep a hull out of
 * the bombing business; every hull on this roster carries a rack.
 *
 * `GUN_ALL` and `BOMB_ALL` are the plain ceilings. A row that wants a
 * different one spells its whole field out rather than OR-ing over the macro:
 * the field is two bits per add-on, so `GUN_ALL | M2(MULTI)` is 1|2 = three
 * rungs, not two. OR builds a field, it does not override one.
 *
 * Energy per second is recharge/10, so 1500 refills a 1350-energy hull in
 * about nine seconds. Getting this wrong by a factor of ten makes ships that
 * can never shoot twice, which is what the first test run caught. */
#define GUN_ALL   (M1(SIM_MOD_MULTI) | M1(SIM_MOD_BOUNCE))
#define BOMB_ALL  (M1(SIM_MOD_PROX) | M2(SIM_MOD_SHRAPNEL))
/* Each hull's footprint, in pixels from the point it turns about: past the
   nose, behind the tail, to either side. client/tests/hull_fit_test.lua reads
   this table out of this file by name and measures the client's drawing
   against it, so the two cannot drift; renaming it breaks that test rather
   than silencing it.

   Measured, not chosen: each number is the reach of that hull's own drawing,
   less about a pixel. A single square radius stood here, and no square fits
   this roster -- one that covers an Apex's nose floats its flanks eleven
   pixels off every wall, and one that hugs the flanks buries the nose. The
   collision box is built from these at the ship's current heading, so a hull
   touches a wall where it is drawn touching it whichever way it points, and
   a bullet into a Cipher's flank has to reach the knife rather than a square
   drawn around it. That last part is the balance consequence worth saying
   out loud: thin hulls are now genuinely thin targets, from the side.

   The pixel of inset is not slack. It is what lets a long hull spin: at the
   worst diagonal the box reaches sqrt(fore^2 + halfw^2) from the ship, and
   holding that under 23 -- the ceiling the shipped maps were flood-filled
   and spawn-checked against -- is what keeps every room reachable, every
   spawn safe, and a full rotation possible in a three-tile corridor. A pixel
   of hull crossing a wall at the moment of contact is invisible; the old
   defect was seven and a half.

                                fore  aft  halfw */
static const uint8_t hull_extent[SIM_MAX_CLASSES][3] = {
    /* Apex:    a dart, nearly all of it nose */ {20, 11, 10},
    /* Wedge:   widest at the bomb bay        */ {13, 12, 15},
    /* Chord:   a bow, wider than it is long  */ {13,  5, 17},
    /* Anvil                                  */ {15, 11, 13},
    /* Cipher:  the knife, longest and thinnest */ {22, 12,  6},
    /* Facet:   squat, the smallest target    */ {14, 12, 11},
    /* Lattice: near square, near flush       */ {16, 14, 14},
};

static const class_row rows[SIM_MAX_CLASSES] = {
    /* MaxGuns is 3 on every ship the original ships and MaxBombs is 2 on
       seven of them, so that is what every row here says. The Anvil is the
       Leviathan, whose MaxBombs is 3 and is the only per-ship weapon number
       in the whole file.

       gun     bomb  gun add-ons  bomb add-ons                    charges */
    {3, 2, GUN_ALL, BOMB_ALL,                              {3, 3, 0, 0}},
    /* Wedge and Anvil are the bombers, so they are the hulls that hold the
       most shrapnel, which here is a deeper rung on the add-on rather than
       the count the original's ShrapnelMax is. */
    {3, 2, GUN_ALL,
     M1(SIM_MOD_PROX) | M3(SIM_MOD_SHRAPNEL),              {3, 3, 0, 0}},
    /* Spread is Chord's and freeze is ours: neither has a setting in the
       original, so add-on ceilings are where our roster still lives. */
    {3, 2, M2(SIM_MOD_MULTI) | M1(SIM_MOD_BOUNCE) | M1(SIM_MOD_FREEZE),
     BOMB_ALL,                                             {3, 3, 0, 0}},
    /* The Leviathan: MaxBombs 3. */
    {3, 3, GUN_ALL,
     M1(SIM_MOD_PROX) | M3(SIM_MOD_SHRAPNEL),              {3, 3, 0, 0}},
    {3, 2, GUN_ALL, BOMB_ALL,                              {3, 3, 0, 0}},
    /* Facet is the Terrier's DoubleBarrel: the hull whose spread is the
       point, so it climbs multifire a rung further than anyone. */
    {3, 2, M2(SIM_MOD_MULTI) | M1(SIM_MOD_BOUNCE), BOMB_ALL,
                                                           {3, 3, 0, 0}},
    /* Lattice is the Lancaster: BombBounceCount is 1 on that ship and 0 on
       every other, so bombs that come back off a wall are its alone. Push is
       ours and stays with it for the same reason. */
    {3, 2, GUN_ALL,
     BOMB_ALL | M2(SIM_MOD_BOUNCE) | M2(SIM_MOD_PUSH),     {3, 3, 0, 0}},
};
#undef GUN_ALL
#undef BOMB_ALL

const char *const sim_class_names[SIM_MAX_CLASSES] = {
    "Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet", "Lattice"};

void sim_settings_baseline(sim_settings *cfg, const sim_map *map) {
    cfg->class_count = SIM_MAX_CLASSES;
    cfg->spec_count = 0;
    cfg->pattern_count = 0;
    /* Walls are inelastic: a hit returns about 60% of the speed that went
     * into it and scrubs some of the speed along it. Clipping a wall should
     * hurt, which is what makes tight flying a skill. */
    cfg->bounce = 10;
    cfg->friction = 14;
    /* Four seconds dead, which is longer than the three this was and longer
     * than the original's own EnterDelay. The extra second is not a difficulty
     * knob: the wait carries a card explaining a thing in the arena, and the
     * longest of them runs to three rows, which is not readable in the time it
     * took to read DESTROYED and nothing else. A death is the one moment a
     * player has nothing to fly and a reason to care, and buying that moment
     * costs a second of a respawn nobody enjoyed anyway. */
    cfg->respawn_delay = 400; /* 4 s */
    /* No limit on sitting in a safe zone. The baseline is a translation of a
     * settings file that has no such rule, and a room that empties its own
     * stands is a deployment decision: a zone that wants one sets it. */
    cfg->safe_limit = 0;
    /* Two hundred greens at five a second was the number for placing them
     * uniformly over a map a thousand tiles across, where two hundred is one
     * green per five thousand tiles and a pilot sweeping the field meets one
     * every few minutes. Greens appear near a pilot now, so the same numbers
     * carpet the ground they are standing on: an offline arena reached
     * multifire, bounce, proximity and three of five energy steps inside a
     * minute, which is the whole tech tree handed over for flying in a circle.
     *
     * One a second to a field of two dozen is what the shipped zones already
     * ask for. Shared among a roster it is a green each every ten seconds or
     * so: worth turning for, not worth ignoring. */
    cfg->prize_delay = 100;
    cfg->prize_max = 24;
    cfg->prize_life = 3000;   /* 30 s */
    cfg->prize_radius = 16 * 256; /* generous: chasing a green should not be fiddly */
    cfg->flag_radius = 18 * 256;
    cfg->flag_drop_cooldown = 200;
    /* Sixty-four is four times what the original aimed a public room at:
     * General:DesiredPlaying defaults to 15 playing pilots and its whole job is
     * deciding when to open another arena. So this is the room size we think
     * plays, not the most the array can take, and a zone that wants more can
     * say so up to SIM_MAX_SHIPS. */
    cfg->max_ships = 64; /* 2 s before a dropped flag can be retaken */
    /* The green field is the whole map, because the players are spread over
     * the whole map. Two hundred of them is one per five thousand tiles, or
     * roughly one every seventy tiles in each direction -- close enough that
     * flying anywhere passes some.
     *
     * That costs the wire: a snapshot carries every live green at eleven
     * bytes, so two hundred is 2.2 KB a snapshot and about 44 KB/s at the
     * 20 Hz rate. Worth knowing before raising it further. The way out, when
     * it matters, is sending a client only the greens near it -- which is
     * interest management, a feature rather than a number, and the same
     * answer for every other thing a 1024-tile map has too many of. */
    cfg->prize_lo = 8;
    cfg->prize_hi = 1015;
    cfg->map = map;
    /* Doors breathe on a six second cycle, open for four of it: long enough
     * to commit to a crossing, short enough that the choice matters. */
    cfg->door_period = 600;
    cfg->door_open = 400;
    cfg->wormhole_pull = sim_units_speed(90);
    cfg->wormhole_range = 220 * 256;

    /* What a green turns out to be, on the original's odds.
     *
     * These are its [PrizeWeight] table, entry for entry, from the settings
     * shipped with the reference server: a stat is 40, a weapon level is 25,
     * multifire and shrapnel are 30, bouncing and proximity are 25, and a
     * charge is 70. They are relative -- doubling every number changes
     * nothing -- and read against the pool of the hull that took the green,
     * so what is written here is the shape of the tree rather than its
     * arithmetic.
     *
     * Two of our add-ons have no entry to copy, because the original has no
     * such prize: freeze and push exist as weapon effects there, never as
     * something a green hands you. They get 25, the band its comparable
     * add-ons sit in, and that is a number we chose rather than inherited.
     *
     * Everything in its table we do not have -- cloak, stealth, xradar,
     * antiwarp, warp, decoy, thor, brick, rocket, portal, shields,
     * allweapons, multiprize -- is simply absent from our space rather than
     * present at zero.
     *
     * Rust is the number to tune first. One green in a hundred takes
     * something back, and it can only take what you are holding, so it costs
     * a loaded pilot and never touches one who has just spawned. */
    cfg->prize_weight[SIM_PRIZE_STAT(SIM_UP_ENERGY)] = 40;    /* Energy */
    cfg->prize_weight[SIM_PRIZE_STAT(SIM_UP_RECHARGE)] = 40;  /* QuickCharge */
    cfg->prize_weight[SIM_PRIZE_STAT(SIM_UP_SPEED)] = 40;     /* TopSpeed */
    cfg->prize_weight[SIM_PRIZE_STAT(SIM_UP_THRUST)] = 40;    /* Thruster */
    cfg->prize_weight[SIM_PRIZE_STAT(SIM_UP_ROTATION)] = 40;  /* Rotation */
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        /* Gun=25, Bomb=25 */
        cfg->prize_weight[SIM_PRIZE_LEVEL(t)] = 25;
        cfg->prize_weight[SIM_PRIZE_MOD(t, SIM_MOD_MULTI)] = 30;    /* MultiFire */
        cfg->prize_weight[SIM_PRIZE_MOD(t, SIM_MOD_BOUNCE)] = 25;   /* BouncingBullets */
        cfg->prize_weight[SIM_PRIZE_MOD(t, SIM_MOD_PROX)] = 25;     /* Proximity */
        cfg->prize_weight[SIM_PRIZE_MOD(t, SIM_MOD_SHRAPNEL)] = 30; /* Shrapnel */
        cfg->prize_weight[SIM_PRIZE_MOD(t, SIM_MOD_FREEZE)] = 25;   /* ours */
        cfg->prize_weight[SIM_PRIZE_MOD(t, SIM_MOD_PUSH)] = 25;     /* ours */
    }
    cfg->rust_chance = 10;
    /* Thirty greens in hand the moment a ship spawns. A fight between two
     * empty ships is the least interesting fight in the game, and without
     * this it is the one every match opens with and the one every death
     * returns you to. A zone that wants pilots to earn it all sets zero. */
    cfg->spawn_prizes = 30;
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
    /* ProximityDistance=3, in tiles. Binary in the original: a bomb is a
     * contact bomb until the prize makes it a proximity one, and the radius
     * comes from the bomb's level rather than from how many of the prize you
     * have. This core hangs it on the add-on instead, so every row below
     * holds proximity at one rung and one rung is the L1 radius.
     *
     * What that does not reproduce is the widening: there, a level 2 bomb
     * senses at four tiles and a level 3 at five. Here the radius is what the
     * add-on says and the level does not reach it. */
    cfg->mod_step[SIM_MOD_PROX] = 3 * 16 * 256;    /* three tiles of fuse */
    /* And "each bomb level adds 1 to this amount", so a level 2 bomb senses
     * at four tiles and a level 3 at five. */
    cfg->prox_step = 16 * 256;
    /* BombExplodeDelay: how long a fuse that has found somebody will wait for
     * them to start pulling away before going off regardless. */
    cfg->prox_delay = 150;
    /* BombSafety=1: a proximity bomb will not leave the tube with an enemy
     * already inside the fuse's reach. */
    cfg->bomb_safety = 1;
    /* BBombDamagePercent, per thousand. The reference server leaves it whole,
     * so a bouncing bomb costs its hull nothing until a zone says otherwise. */
    cfg->bbomb_damage = 1000;
    /* InactiveShrapDamage=3, over the first quarter second of a fragment's
     * life. Shrapnel is born at the point of impact, which is inside the hull
     * the bomb just hit, so without this a bomb lands twice: once as a blast
     * and again as a ring of fragments already touching their victim. */
    cfg->shrap_inactive = sim_units_energy(3);
    cfg->shrap_inactive_ticks = 25;
    cfg->mod_step[SIM_MOD_SHRAPNEL] = 0;           /* a pattern, not a number */
    cfg->mod_step[SIM_MOD_FREEZE] = 100;           /* a second of no recharge */
    cfg->mod_step[SIM_MOD_PUSH] = sim_units_speed(1200);
    cfg->mod_spread = 65536 / 24;                  /* fifteen degrees */
    /* Straight from the original: 20 energy a bullet against 30 for multifire,
     * and 25 ticks of cooldown against 50. Three rounds for half again the
     * energy and twice the wait. */
    cfg->mod_multi_energy = 50;
    cfg->mod_multi_delay = 100;

    /* Shrapnel, one pattern per rung: four fragments, then eight, then
     * sixteen. The fragments themselves are one spec -- a rung of shrapnel
     * buys more of them rather than better ones, so the add-on reads as
     * "more" the way every other add-on does. */
    {
        sim_weapon_spec frag;
        memset(&frag, 0, sizeof frag);
        /* The original's numbers: ShrapnelSpeed=3000, and
         * ShrapnelDamagePercent=1000, which its own help text defines as
         * tenths of a percent "relative to bullets of same level" -- so a
         * fragment hits for a whole L1 bullet, which is 200 there. Life is
         * BulletAliveTime, since it has no shrapnel clock of its own.
         *
         * ShrapnelRate=2, which its help calls the shrapnel "gained by a
         * 'Shrapnel Upgrade' prize", so a rung buys two more fragments.
         *
         * The cap is where this stops matching. ShrapnelMax is 8 on seven of
         * the original's ships and 31 on the Shark, and an add-on here is two
         * bits, so three rungs and six fragments is the ceiling however many
         * prizes a pilot finds. Reaching eight would mean a fourth rung and a
         * wider field, which is a wire change rather than a number. */
        frag.speed = sim_units_speed(3000);
        frag.life = 550;
        /* A fragment is a bullet, which is the whole of what shrapnel is in
         * the original: the burst makes rounds of the thrower's *gun* rung,
         * bouncing if their bullets bounce, and its damage runs through the
         * bullet formula rather than one of its own. So the base here is an
         * L1 bullet and `damage_up` is BulletDamageUpgrade, and the rung the
         * bomb carried decides which bullet it turns out to be.
         *
         * Which also settles the bouncing, twice over. This bounced
         * unconditionally, because a bomb mostly goes off against a wall and
         * the half of a burst thrown wallward died inside a tick, so a rung of
         * shrapnel read as one fragment or none. That is real, and it is also
         * what the original does to a pilot who has not found bouncing
         * bullets: the fix was to the wrong end. Fragments end on walls unless
         * the guns lift them off, which is `on_wall` here and the add-on
         * carried from the guns.
         *
         * And then for as long as they live, which is `bounces`. See the gun
         * ladder below: the original counts a bomb's bounces and never a
         * bullet's, and a fragment is a bullet. The count is spent only once
         * `on_wall` is BOUNCE, so a base of 255 changes nothing for a pilot
         * without the add-on. */
        frag.on_wall = SIM_WALL_END;
        frag.bounces = 255;
        frag.damage = sim_units_energy(BULLET_DAMAGE);
        frag.damage_up = sim_units_energy(BULLET_UPGRADE);
        frag.splinter = SIM_NO_PATTERN;
        uint8_t frag_spec = (uint8_t)sim_add_spec(cfg, &frag);
        cfg->mod_splinter[0] = SIM_NO_PATTERN;   /* rung zero is no shrapnel */
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            sim_fire_pattern shell;
            memset(&shell, 0, sizeof shell);
            shell.spec = frag_spec;
            /* ShrapnelRate is two a prize and ShrapnelMax is eight, which is
             * four prizes. An add-on here is two bits, so three rungs have to
             * carry four prizes' worth: the first two are the rate and the
             * last one reaches the cap. */
            static const uint8_t frags[SIM_MAX_RUNGS] = {0, 2, 4, 8};
            shell.count = frags[k];
            /* Shrapnel:Random is 1 in the original's own arena file, so
             * fragments scatter rather than leaving on an even ring. Spacing
             * of zero is how a pattern asks for that. */
            shell.spacing = 0;
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
        /* RepelDistance=512, RepelSpeed=5000 and RepelTime=225, all three
         * of them now. The reach is a square of that half-width rather than
         * a circle, the shove sets a ship's velocity to exactly that speed
         * anywhere inside it rather than falling off with range, and the
         * time is how long the shoved hull may fly at it before its own
         * ceiling takes over again -- which matters because 5000 is half
         * again the fastest hull in the game. */
        rp.speed = 0;
        rp.life = 1;
        rp.on_wall = SIM_WALL_PASS;
        rp.expire_ends = 1;
        rp.blast = 512 * 256;
        rp.push = sim_units_speed(5000);
        rp.push_time = 225;
        rp.splinter = SIM_NO_PATTERN;
        sim_fire_pattern rf;
        memset(&rf, 0, sizeof rf);
        rf.spec = (uint8_t)sim_add_spec(cfg, &rp);
        rf.count = 1;
        rf.delay = 120;
        cfg->charge[0] = (uint8_t)sim_add_pattern(cfg, &rf);

        sim_weapon_spec bs;
        memset(&bs, 0, sizeof bs);
        /* BurstShrapnel=24 at BurstSpeed=3000 and BurstDamageLevel=700,
         * which its help calls the damage of a single burst bullet. Alive
         * time is the bullet clock again. This is a great deal more burst
         * than the sixteen rounds at 180 that were here, and it is meant to
         * be: in the original a burst at close range ends somebody. */
        bs.speed = sim_units_speed(3000);
        bs.life = 550;
        /* And they bounce, for the same reason shrapnel does and more so. A
         * burst is a rosette fired from wherever the ship is standing, which
         * in a fight is a corridor: two dozen rounds go out in every
         * direction and the ones aimed at the nearest wall are most of them.
         * Ending there spent the charge on the half of the circle that
         * happened to face open space. Bouncing, the whole rosette is in
         * play, which is what makes it the thing you fire when somebody has
         * you cornered rather than the thing you cannot use there. */
        bs.on_wall = SIM_WALL_BOUNCE;
        bs.bounces = 255;
        bs.damage = sim_units_energy(700);
        bs.splinter = SIM_NO_PATTERN;
        sim_fire_pattern bf;
        memset(&bf, 0, sizeof bf);
        bf.spec = (uint8_t)sim_add_spec(cfg, &bs);
        bf.count = 24;
        bf.spacing = 65536 / 24;
        bf.delay = 120;
        cfg->charge[1] = (uint8_t)sim_add_pattern(cfg, &bf);

        cfg->charge[2] = SIM_NO_PATTERN;
        cfg->charge[3] = SIM_NO_PATTERN;
        /* Repel=70 and Burst=70, and they are the two heaviest entries in the
         * original's table by a distance -- almost twice a stat. A charge is
         * the green you are pleased to see, which is a thing the odds say
         * rather than the item. The two slots this zone does not use are
         * zero; a weight is the only thing that keeps a prize out of a pool
         * the hull would otherwise accept. */
        cfg->prize_weight[SIM_PRIZE_CHARGE(0)] = 70;
        cfg->prize_weight[SIM_PRIZE_CHARGE(1)] = 70;
        cfg->prize_weight[SIM_PRIZE_CHARGE(2)] = 0;
        cfg->prize_weight[SIM_PRIZE_CHARGE(3)] = 0;
    }

    for (int i = 0; i < SIM_MAX_CLASSES; i++) {
        const class_row *r = &rows[i];
        sim_ship_class *c = &cfg->classes[i];
        sim_class_from_units(c, &flight);
        c->fore = (int32_t)hull_extent[i][0] * 256;
        c->aft = (int32_t)hull_extent[i][1] * 256;
        c->halfw = (int32_t)hull_extent[i][2] * 256;
        c->mod_max[SIM_TRIG_GUN] = r->gun_mods;
        c->mod_max[SIM_TRIG_BOMB] = r->bomb_mods;
        for (int k = 0; k < SIM_MAX_CHARGES; k++)
            c->charge_max[k] = r->charges[k];

        /* A ladder per trigger. A gun rung adds BulletDamageUpgrade, flat,
         * which is what the original's help says it is: "amount of extra
         * damage each bullet level will cause". Not a percentage -- that was
         * ours, and it made an L3 bullet 360 where the original makes it 400.
         *
         * A bomb rung adds no damage at all. BombDamageLevel is defined "for
         * all bomb levels" and there is no BombDamageUpgrade to go with it.
         * What a bomb level buys is BombFireEnergyUpgrade, which is to say it
         * costs more, and shrapnel, which is the add-on. So the rungs exist
         * to be climbed past rather than for themselves.
         *
         * Costs are absolute rather than a share of the bar, which they can
         * be now that every hull carries the same 1700 the original gives
         * them all. */
        for (int k = 0; k < r->gun_rungs && k < SIM_MAX_RUNGS; k++) {
            sim_weapon_spec bolt;
            memset(&bolt, 0, sizeof bolt);
            bolt.speed = sim_units_speed(2000);
            bolt.life = 550;    /* BulletAliveTime: 5.5 s, 69 tiles of reach */
            bolt.on_wall = SIM_WALL_END;
            /* A bouncing bullet bounces until its clock runs out, and 255 is
             * how this table spells that: a bullet reaches 69 tiles in its
             * whole life, so it cannot spend them.
             *
             * The original counts bombs and never bullets. `BombBounceCount`
             * is a per-ship setting, 1 on the Lancaster alone, and there is
             * `BBombDamagePercent` beside it for what a bounced bomb hits
             * for; bullets have no such pair, and on the wire bouncing is a
             * weapon *type* rather than a budget, 1 against 2 in the five
             * bits that name a round. A prize you either hold or do not.
             *
             * So the count belongs to the bomb, and one rung of the add-on
             * buying one more wall is right there and wrong here. It made a
             * bouncing bullet a trick shot when the original's is an area
             * weapon: a corridor full of ricochets is the whole reason
             * anybody picks the green up. Sitting in the spec rather than in
             * `mod_step` is what lets the two differ, since a step is one
             * number for every weapon that takes the add-on. */
            bolt.bounces = 255;
            bolt.damage = sim_units_energy(BULLET_DAMAGE + BULLET_UPGRADE * k);
            bolt.splinter = SIM_NO_PATTERN;

            sim_fire_pattern gun;
            memset(&gun, 0, sizeof gun);
            gun.spec = (uint8_t)sim_add_spec(cfg, &bolt);
            gun.count = 1;
            gun.energy = sim_units_energy(BULLET_ENERGY);
            gun.delay = BULLET_DELAY;
            c->trigger[SIM_TRIG_GUN][k] = (uint8_t)sim_add_pattern(cfg, &gun);
        }

        /* Every hull has a rack, because every one of the original's ships
         * does: MaxBombs is 2 or 3 on all eight. The empty-ladder case is
         * still handled -- a zone may take a rack away -- and the trigger
         * simply goes dead when it does. */
        for (int k = 0; k < r->bomb_rungs && k < SIM_MAX_RUNGS; k++) {
            sim_weapon_spec sh;
            memset(&sh, 0, sizeof sh);
            /* BombSpeed=2000, BombAliveTime=6000 and BombExplodePixels=80.
             * Sixty seconds is not a fuse, it is "until it hits something",
             * which is what the original means on a map this size.
             *
             * This said 8000, from the reference server's own config rather
             * than from VIE's, and both shipped zones then overrode it back to
             * 6000 while describing that as their own deviation. Two sources,
             * one of them the game we are actually copying. */
            sh.speed = sim_units_speed(2000);
            sh.life = 6000;
            sh.on_wall = SIM_WALL_END;
            sh.damage = sim_units_energy(BOMB_DAMAGE);
            /* BombExplodePixels is the L1 radius and its help spells the rest
             * out: "L2 bombs double this, L3 bombs triple this". So the blast
             * is what a bomb level buys, since the damage at the centre does
             * not move. */
            sh.blast = BOMB_BLAST * (k + 1) * 256;
            sh.splinter = SIM_NO_PATTERN;

            sim_fire_pattern bomb;
            memset(&bomb, 0, sizeof bomb);
            bomb.spec = (uint8_t)sim_add_spec(cfg, &sh);
            bomb.count = 1;
            bomb.energy = sim_units_energy(BOMB_ENERGY + BOMB_ENERGY_UP * k);
            bomb.delay = BOMB_DELAY;
            bomb.recoil = sim_units_speed(BOMB_THRUST);
            c->trigger[SIM_TRIG_BOMB][k] = (uint8_t)sim_add_pattern(cfg, &bomb);
        }
    }
}

/* ---- maps ---- */

/* Close the world.
 *
 * `sim_tile_at` already answers solid for anything outside the square, so this
 * looks redundant and is not. That answer only reaches the collision test for
 * tiles the ship's box actually covers, and a hull at full speed crosses more
 * than a tile in a tick: two tiles of wall is thin enough that the axis-by-axis
 * resolution has nothing to push it back out of, and the ship is through. Four
 * is what the reference arena has always used for the same reason, and this is
 * that fill, moved to where every map gets it.
 *
 * It is not in the map file. Every map wants it, so a map that had to carry it
 * is a map that can get it wrong, and none of the converted ones brought a
 * boundary of their own: a `.lvl` is drawn against a client that stops a ship
 * at the edge whatever the tiles say.
 *
 * The variant marks it as a boundary rather than a wall, which is what the
 * renderer draws its edge treatment from. Nothing else in the core reads it. */
#define BORDER_TILES 4
#define VARIANT_BORDER 1

static void enclose(sim_map *m) {
    const int LAST = SIM_MAP_TILES - 1;
    uint8_t t = SIM_TILE(SIM_TILE_SOLID, VARIANT_BORDER);
    for (int i = 0; i < BORDER_TILES; i++) {
        for (int k = 0; k <= LAST; k++) {
            m->tile[(size_t)i * SIM_MAP_TILES + (size_t)k] = t;
            m->tile[(size_t)(LAST - i) * SIM_MAP_TILES + (size_t)k] = t;
            m->tile[(size_t)k * SIM_MAP_TILES + (size_t)i] = t;
            m->tile[(size_t)k * SIM_MAP_TILES + (size_t)(LAST - i)] = t;
        }
    }
}

void sim_map_index(sim_map *m) {
    enclose(m);
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

/* A deterministic per-cell variant. Pure unsigned arithmetic, because this
 * decides terrain and terrain has to be identical on every machine that
 * builds the map -- the client meshes it, the server collides against it, and
 * a wall in a different place on one of them is a desync you see rather than
 * measure. */
static uint32_t cell_hash(uint32_t cx, uint32_t cy) {
    uint32_t h = cx * 73856093u ^ cy * 19349663u;
    h ^= h >> 13;
    h *= 2654435761u;
    h ^= h >> 16;
    return h;
}

/* The public arena, at the map's full size: 1024 tiles square, which is the
 * original's map size and 16384 pixels on a side.
 *
 * It used to be an 84-tile room in the middle of all that space, which is
 * about ten seconds to cross at a hull's top speed. That is a pit
 * wearing an arena's name: there is nowhere to go, no distance for a chase to
 * happen over, and no reason to ever choose a direction.
 *
 * The field is a lattice of 64-tile cells, each holding one of four
 * structures chosen by a hash of its coordinates. That is 256 landmarks, none
 * of them wider than twenty tiles, so the lanes between them are always at
 * least twice a cell's structure. A lattice rather than a hand-drawn map
 * because a hand-drawn 1024-tile map is a job for a map editor and a person,
 * and this has to be legible from a C file until that exists.
 *
 * The old room survives at the centre, minus its enclosing box: the pillars,
 * the baffles, the two safe zones and the pair of out-of-phase doors are
 * still there, and are still where every ship spawns. So the game that
 * existed before this is the middle of the game that exists now, and the rest
 * of the map is somewhere to take a fight rather than a second arena.
 *
 * No wormhole. One reaches 220 px, which is fourteen tiles, and the bot
 * ladder found what a well placed one does to a small room: pilots orbited it
 * instead of each other and a whole roster graded equal because nobody landed
 * a shot. A map this size can hold one now; placing it is a map-editor
 * decision rather than a C-file one. */
void sim_map_arena(sim_map *m) {
    memset(m->tile, SIM_TILE_EMPTY, sizeof m->tile);

    /* The boundary is not built here any more. `sim_map_index` closes every
     * map, this one included, with the same four tiles this used to fill. */

    const int CELL = 64;

    /* The field. */
    for (int cy = 0; cy < SIM_MAP_TILES / CELL; cy++) {
        for (int cx = 0; cx < SIM_MAP_TILES / CELL; cx++) {
            int ox = cx * CELL + CELL / 2;      /* the cell's middle */
            int oy = cy * CELL + CELL / 2;
            /* The middle four cells are the old room's, and it draws its own
             * furniture below. */
            if (ox > 460 && ox < 564 && oy > 460 && oy < 564) continue;
            uint32_t h = cell_hash((uint32_t)cx, (uint32_t)cy);
            switch (h & 3u) {
            case 0:                              /* a block to hide behind */
                fill(m, ox - 6, oy - 6, ox + 5, oy + 5, SIM_TILE_SOLID);
                break;
            case 1:                              /* a cross, so it has lanes */
                fill(m, ox - 10, oy - 2, ox + 9, oy + 1, SIM_TILE_SOLID);
                fill(m, ox - 2, oy - 10, ox + 1, oy + 9, SIM_TILE_SOLID);
                break;
            case 2:                              /* four pillars in a square */
                fill(m, ox - 9, oy - 9, ox - 5, oy - 5, SIM_TILE_SOLID);
                fill(m, ox + 5, oy - 9, ox + 9, oy - 5, SIM_TILE_SOLID);
                fill(m, ox - 9, oy + 5, ox - 5, oy + 9, SIM_TILE_SOLID);
                fill(m, ox + 5, oy + 5, ox + 9, oy + 9, SIM_TILE_SOLID);
                break;
            default:                             /* open, and marked so */
                fill(m, ox - 2, oy - 2, ox + 1, oy + 1, SIM_TILE_UNDER);
                break;
            }
            /* A refuge every fourth cell each way -- 256 tiles apart, so a
             * pilot anywhere in the field is inside a couple of hundred of
             * one. Without them the whole map outside the middle is a place
             * you cannot stop, and the two central zones are the only reason
             * to ever come back. */
            if ((cx & 3) == 2 && (cy & 3) == 2)
                fill(m, ox - 20, oy - 3, ox - 14, oy + 3, SIM_TILE_SAFE);
        }
    }

    /* --- the middle, which is the room this arena used to be entirely --- */
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

    /* Starts, eight a side, spread across the map rather than parked in the
     * middle of it.
     *
     * The first version of this map kept every spawn in the centre room, on
     * the reasoning that pilots scattered over 1024 tiles would never find
     * each other. That reasoning made the map decorative: a full-size arena
     * whose players are all inside one 84-tile box is an 84-tile arena with a
     * lot of unused address space around it.
     *
     * So each side gets a home band -- team 1 across the north, team 0 across
     * the south -- eight starts apiece, 256 tiles apart, with the old centre
     * room as the contested ground between them. Crossing takes about thirty
     * seconds at a hull's top speed, which is a journey rather than a walk,
     * and the bots fly it: their targeting has no range limit, only a
     * preference for what is close and expensive.
     *
     * Cell-local (52, 52) is the offset used. A cell's structure occupies
     * tiles 22 to 42 of it and a refuge 9 to 15, so 52 is clear of both
     * whatever the hash rolled for that cell -- which is the property that
     * matters, because a spawn inside a wall is a ship that cannot move. */
    for (int n = 0; n < 4; n++) {
        int cx = 2 + n * 4;
        int x = cx * CELL + 52;
        fill(m, x, 2 * CELL + 52, x, 2 * CELL + 52, SIM_TILE(SIM_TILE_SPAWN, 1));
        fill(m, x, 5 * CELL + 52, x, 5 * CELL + 52, SIM_TILE(SIM_TILE_SPAWN, 1));
        fill(m, x, 10 * CELL + 52, x, 10 * CELL + 52, SIM_TILE(SIM_TILE_SPAWN, 0));
        fill(m, x, 13 * CELL + 52, x, 13 * CELL + 52, SIM_TILE(SIM_TILE_SPAWN, 0));
    }
    sim_map_index(m);
}

/* The pit: small, symmetric, and bare, for measuring two pilots against each
 * other. No wormhole and no safe zone -- a room this size with somewhere
 * invulnerable in it settles nothing. The bot ladder found that the hard way:
 * a pilot that wandered into one stopped dead, could not be shot and could not
 * shoot, and the match ended with nobody having landed anything.
 *
 * Offline ladder calibration is the only caller. It was the duel room too,
 * until duels were taken out; see docs/design/duel-mode.md. */
void sim_map_pit(sim_map *m) {
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
