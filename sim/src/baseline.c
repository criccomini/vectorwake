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
/* How far apart a multi-barrel hull's rounds leave, at 65536 to the turn:
 * seven and a half degrees, half the baseline's fifteen-degree `mod_spread`,
 * so a second barrel reads as a barrel rather than as a free rung of
 * multifire. That ratio is the baseline's own; a zone that tightens its
 * multifire fan can walk right past it, and one that cares sets `spread` on
 * the facet-gun patterns too.
 *
 * It has to be nonzero. A pattern of many at spacing zero is the shrapnel
 * encoding, and scatters. */
#define BARREL_SPREAD (65536 / 48)
#define BOMB_DAMAGE     750   /* BombDamageLevel, "for all bomb levels" */
#define BOMB_DELAY      150   /* BombFireDelay */
#define BOMB_ENERGY     300   /* BombFireEnergy */
#define BOMB_ENERGY_UP   50   /* BombFireEnergyUpgrade, per level */
#define BOMB_THRUST     400   /* BombThrust: the recoil of letting one go */
#define BOMB_BLAST       80   /* BombExplodePixels, for an L1 bomb */
/* Laying one, against the 300 and 150 throwing one costs. A mine is a little
 * cheaper and a little quicker than the bomb it is, which is the original's
 * own arrangement rather than a lever of ours. The upgrade is steeper than the
 * bomb's 50: a rung 3 mine costs 570 where a rung 3 bomb costs 400, which is
 * what stops the rung being free on the weapon that does not have to be
 * aimed. */
#define MINE_ENERGY     270   /* LandmineFireEnergy */
#define MINE_ENERGY_UP  150   /* LandmineFireEnergyUpgrade, per level */
#define MINE_DELAY      125   /* LandmineFireDelay */

/* The charge slots the baseline uses. A zone can fill the other two. */
#define CH_REPEL 0
#define CH_BURST 1

/* Two bits per add-on, so a row reads as a list rather than a number. */
#define M1(a) ((uint16_t)(1u << ((a) * 2)))
#define M2(a) ((uint16_t)(2u << ((a) * 2)))
#define M3(a) ((uint16_t)(3u << ((a) * 2)))

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

/* What an arena lets a kit hold, and how far each weapon climbs.
 *
 * One row, for the whole zone. This was seven rows, one per hull, and every
 * number in it was something a pilot could want and not be allowed: the
 * second barrel was the Facet's, the third bomb rung was the Anvil's, six
 * mines were the Lattice's, and a deep rung of shrapnel belonged to whichever
 * two hulls the table called bombers. None of it could ever be sold, because
 * a shop cannot sell a trait that exists on one hull, and a pilot who bought
 * a rung anyway would find the hull they wanted to fly refused it.
 *
 * So the roster stopped carrying a tech tree. What is left of a hull is the
 * shape it presents to a bullet, in `hull_extent` above, and that is the one
 * difference no shop could sell even if it wanted to. Everything else is
 * here, the same for everybody, and on the shelf.
 *
 * These numbers are the union of what the seven rows allowed, each at its
 * deepest. Nothing new is granted and nothing is taken away: a Wedge could
 * always hold three rungs of shrapnel, and now anyone who buys them can.
 *
 * Availability still follows the original, which gates none of this per ship:
 * its add-ons are entries in [PrizeWeight] and any ship can be handed any of
 * them. What it varies is the ceiling, and the ceiling is the arena's now.
 */

/* MaxGuns is 3 on every ship the original ships. MaxBombs is 2 on seven of
 * them and 3 on the Leviathan, and three is what everybody climbs to here:
 * the shop sells the rung rather than the roster handing it to one hull. */
#define GUN_RUNGS  3
#define BOMB_RUNGS 3

/* Guns fan, freeze and come in pairs. They carry no fuse and do not break up,
 * which no hull's gun ever did: a bullet with a proximity fuse is a bomb, and
 * that weapon already exists.
 *
 * Bullet bouncing is one rung and stays one. A bounced bullet lives out its
 * whole clock either way -- 69 tiles of reach against a life it cannot spend
 * -- so a second rung would buy literally nothing.
 *
 * Multifire at two is what the Chord and the Facet had. Barrels at two is a
 * choice of ours: the original's DoubleBarrel is a flag with no second step
 * to copy, and two rungs makes it a ladder the shop can sell twice rather
 * than a switch it sells once. */
#define GUN_MODS  (M2(SIM_MOD_MULTI) | M1(SIM_MOD_BOUNCE) \
                   | M1(SIM_MOD_FREEZE) | M2(SIM_MOD_BARREL))

/* Bombs bounce, sense, shatter and freeze. They do not fan and they do not
 * come in pairs, which is the other combination no hull ever had: a rack that
 * throws three at a pull is not a bomber, it is a different game.
 *
 * Bounce at two was the Lattice's alone. Shrapnel at three was the two
 * bombers'.
 *
 * Freeze is on both triggers rather than the gun alone. Stalling a recharge is
 * a thing a hit does, and the core has always applied it off whichever
 * trigger's add-ons carried it, so this is a flag rather than a weapon.
 *
 * Push is off the shelf for now. It was two rungs of the Lattice's shove, and
 * a shove welded onto a bomb wants its own look before it is sold. */
#define BOMB_MODS (M2(SIM_MOD_BOUNCE) | M1(SIM_MOD_PROX) \
                   | M3(SIM_MOD_SHRAPNEL) | M1(SIM_MOD_FREEZE))

/* Repels and bursts are three, which is RepelMax and BurstMax on all eight of
 * the original's ships. Mines are six, which was the Lattice's row and is the
 * arena's now: MaxMines was five on every ship there, where carrying one cost
 * nothing, and as slots in a thirty point kit six mines is most of a build.
 * What made one hull the mining hull is a purchase. */
#define CHARGE_REPEL_MAX 3
#define CHARGE_BURST_MAX 3
#define CHARGE_MINE_MAX  6

/* The above, over the flat slot space: the most this arena will let a kit put
 * in each slot, and zero for a slot it does not have at all. */
static void fill_kit_ceiling(sim_settings *cfg) {
    memset(cfg->kit_ceiling, 0, sizeof cfg->kit_ceiling);
    for (int u = 0; u < SIM_UP_COUNT; u++)
        cfg->kit_ceiling[SIM_SLOT_STAT(u)] = SIM_UP_STEPS;
    /* A ladder of N rungs is N-1 steps to buy: rung zero is what the trigger
     * already fires. */
    cfg->kit_ceiling[SIM_SLOT_LEVEL(SIM_TRIG_GUN)] = GUN_RUNGS - 1;
    cfg->kit_ceiling[SIM_SLOT_LEVEL(SIM_TRIG_BOMB)] = BOMB_RUNGS - 1;
    for (int m = 0; m < SIM_MOD_COUNT; m++) {
        cfg->kit_ceiling[SIM_SLOT_MOD(SIM_TRIG_GUN, m)] = sim_mod_get(GUN_MODS, m);
        cfg->kit_ceiling[SIM_SLOT_MOD(SIM_TRIG_BOMB, m)] = sim_mod_get(BOMB_MODS, m);
    }
    cfg->kit_ceiling[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = CHARGE_REPEL_MAX;
    cfg->kit_ceiling[SIM_SLOT_CHARGE(SIM_CHARGE_BURST)] = CHARGE_BURST_MAX;
    cfg->kit_ceiling[SIM_SLOT_CHARGE(SIM_CHARGE_MINE)] = CHARGE_MINE_MAX;
}

const char *const sim_class_names[SIM_MAX_CLASSES] = {
    "Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet", "Lattice"};

void sim_settings_baseline(sim_settings *cfg, const sim_map *map) {
    cfg->class_count = SIM_MAX_CLASSES;
    cfg->spec_count = 0;
    cfg->pattern_count = 0;
    /* Every death is real, which is the server's answer and the safe one:
     * callers hand this function uninitialized structs, and a garbage byte
     * here would be a server that quietly stopped killing anybody. The
     * prediction client overrides both after every baseline (decision 40). */
    cfg->deathless = 0;
    cfg->mortal_ship = 255;
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
    /* Spawn on the map's own tiles. Every map we ship carries them, and a
     * baseline that scattered ships round the middle instead would be the
     * baseline overruling the map. A zone that wants the scatter sets a
     * radius, which spreads arrivals around the point rather than moving
     * them off it. Size it against the crowd that will share it, measured as
     * seconds of bullet flight to the nearest enemy: Alpha runs 60 for a bit
     * over three seconds at the 51 ships one of its rooms holds. */
    cfg->spawn_radius = 0;
    /* And a client marks those tiles, because a pilot who cannot see where
     * they are about to arrive cannot decide anything about it. */
    cfg->show_spawns = 1;
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
    /* A fresh pilot is worth one and each kill adds one, so the number over
     * a ship is the length of its current run and nothing else. Killing
     * somebody who just spawned pays almost nothing, which is the free
     * anti-farming property bounty.md wants: no repeat-kill decay, no timer,
     * no rule about camping, just a price that starts at the floor. */
    cfg->bounty_base = 1;
    cfg->bounty_per_kill = 1;
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
    cfg->mod_step[SIM_MOD_BARREL] = 1;             /* one more barrel abreast */
    cfg->mod_spread = 65536 / 24;                  /* fifteen degrees */
    /* Straight from the original: 20 energy a bullet against 30 for multifire,
     * and 25 ticks of cooldown against 50. Three rounds for half again the
     * energy and twice the wait. */
    cfg->mod_multi_energy = 50;
    cfg->mod_multi_delay = 100;
    /* A barrel is half a rung of multifire in rounds, so it is half of one in
     * energy too, and it costs no cooldown at all. That is the trade the two
     * add-ons are: multifire throws more and throws it slower, barrels throw
     * fewer at the rate you already had.
     *
     * The original priced DoubleBarrel at nothing, which was defensible when
     * exactly one hull had it and could not choose otherwise. As something a
     * pilot buys, free rounds would make every other gun add-on pointless. */
    cfg->mod_barrel_energy = 25;
    cfg->mod_barrel_spread = BARREL_SPREAD;
    fill_kit_ceiling(cfg);

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
     * Neither uses a firing delay. Inventory and energy are the limits, and a
     * repel or burst remains available while the gun or bomb clock is shut. */
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
        cfg->charge[1] = (uint8_t)sim_add_pattern(cfg, &bf);

        cfg->charge[3] = SIM_NO_PATTERN;
    }

    /* The mine: the bomb you leave behind you.
     *
     * A charge, in the slot beside repel and burst, so how many you bring is
     * a loadout decision priced against everything else in the kit. It was
     * the bomb trigger's other posture for a long time, which is faithful to
     * the original -- a mine there is not a weapon type at all, the two bytes
     * a shot travels in have five bits of type with no code for one and a
     * single `alternate` bit that turns a bomb into a mine, and the inventory
     * beside it lists bursts, repels, thors, bricks and portals and no mines.
     * What that arrangement could not do is let a pilot trade for it: the
     * limit sat on the hull rather than in their hands.
     *
     * Every field is one the model already had. Speed zero and `still` is a round that stays where it was
     * let go. Two minutes of life with `expire_ends` is a timer that goes off
     * rather than a round that quietly stops existing. A trigger is the fuse.
     * A blast is what it does when either of those finds somebody. Nothing in
     * the update loop knows a mine from a bomb.
     *
     * MineAliveTime in the original, whose own help file bounds it at 200 to
     * 60000 hundredths -- two seconds to ten minutes -- and neither that file
     * nor the settings template carries a default, so two minutes is ours. A
     * mine's clock is how long the ground it denies stays denied, which is why
     * it is not the bomb's alive time: a bomb's minute means "until it hits
     * something".
     *
     * Two tiles of fuse, against the three a proximity bomb senses at. A mine
     * is already the round you cannot see coming and does not have to be
     * dodged in the air first, so it reaches less far than the bomb whose
     * whole cost is being thrown accurately. The proximity add-on brings it up
     * to that bomb's reach and no further; see `compose`.
     *
     * It costs what a bomb costs to let go of, which is LandmineFireEnergy
     * sitting beside BombFireEnergy in the original rather than a number of
     * ours. Free would make it the round you lay while waiting for your bar. */
    {
        sim_weapon_spec mn;
        memset(&mn, 0, sizeof mn);
        mn.speed = 0;
        mn.still = 1;
        mn.life = 12000;
        mn.on_wall = SIM_WALL_END;
        mn.expire_ends = 1;
        mn.trigger = 2 * 16 * 256;
        mn.damage = sim_units_energy(BOMB_DAMAGE);
        /* One hole for everybody. A mine used to wear the layer's bomb rung,
         * which is what a bomb-trigger posture meant; a charge fires one
         * pattern for every pilot who carries it, so a mine is a mine. */
        mn.blast = BOMB_BLAST * 256;
        mn.splinter = SIM_NO_PATTERN;
        sim_fire_pattern mf;
        memset(&mf, 0, sizeof mf);
        mf.spec = (uint8_t)sim_add_spec(cfg, &mn);
        mf.count = 1;
        mf.energy = sim_units_energy(MINE_ENERGY);
        mf.energy_up = sim_units_energy(MINE_ENERGY_UP);
        mf.delay = MINE_DELAY;
        cfg->charge[SIM_CHARGE_MINE] = (uint8_t)sim_add_pattern(cfg, &mf);
    }

    /* Every hull, built the same way. What differs between them is three
     * numbers of footprint and nothing else: they fly alike, they climb alike
     * and they hold alike, and the shape each one presents to a bullet is the
     * whole of the roster. See docs/design/ships.md. */
    for (int i = 0; i < SIM_MAX_CLASSES; i++) {
        sim_ship_class *c = &cfg->classes[i];
        sim_class_from_units(c, &flight);
        c->fore = (int32_t)hull_extent[i][0] * 256;
        c->aft = (int32_t)hull_extent[i][1] * 256;
        c->halfw = (int32_t)hull_extent[i][2] * 256;

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
         * them all. A gun rung also multiplies BulletFireEnergy by its level,
         * which is the original's `(weapon level + 1)` rule. */
        for (int k = 0; k < GUN_RUNGS && k < SIM_MAX_RUNGS; k++) {
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
            /* One round, and the spacing an add-on will want if a pilot
             * buys barrels. DoubleBarrel used to be baked in here, because it
             * was a property of the hull the pattern belonged to; it is a
             * transform applied when the trigger is pulled now, so every
             * hull's rung zero fires one round and what leaves the barrel is
             * the pilot's business. */
            gun.count = 1;
            gun.spacing = 0;
            gun.energy = sim_units_energy(BULLET_ENERGY * (k + 1));
            gun.delay = BULLET_DELAY;
            c->trigger[SIM_TRIG_GUN][k] = (uint8_t)sim_add_pattern(cfg, &gun);
        }

        /* Every hull has a rack, because every one of the original's ships
         * does: MaxBombs is 2 or 3 on all eight. The empty-ladder case is
         * still handled -- a zone may take a rack away -- and the trigger
         * simply goes dead when it does. */
        for (int k = 0; k < BOMB_RUNGS && k < SIM_MAX_RUNGS; k++) {
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
             * is what a bomb level buys, since the damage at the center does
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

/* The ring goes round the map's own rect, so a 144-tile room is walled at 144
 * rather than a thousand tiles away with a field of nothing in between. */
static void enclose(sim_map *m) {
    const int lastx = (int)m->w - 1, lasty = (int)m->h - 1;
    uint8_t t = SIM_TILE(SIM_TILE_SOLID, VARIANT_BORDER);
    for (int i = 0; i < BORDER_TILES; i++) {
        for (int k = 0; k < (int)m->w; k++) {
            SIM_MAP_AT(m, k, i) = t;
            SIM_MAP_AT(m, k, lasty - i) = t;
        }
        for (int k = 0; k < (int)m->h; k++) {
            SIM_MAP_AT(m, i, k) = t;
            SIM_MAP_AT(m, lastx - i, k) = t;
        }
    }
}

/* A map with no size has no inside, and every caller that draws one has to say
 * how big it is before drawing. Refusing anything the boundary would swallow
 * whole is the one bound worth checking here: below it the ring drawn above
 * meets itself and there is nowhere to stand. */
void sim_map_size(sim_map *m, int w, int h) {
    if (w > SIM_MAP_TILES) w = SIM_MAP_TILES;
    if (h > SIM_MAP_TILES) h = SIM_MAP_TILES;
    if (w < BORDER_TILES * 2 + 1) w = BORDER_TILES * 2 + 1;
    if (h < BORDER_TILES * 2 + 1) h = BORDER_TILES * 2 + 1;
    m->w = (uint16_t)w;
    m->h = (uint16_t)h;
    for (int ty = 0; ty < h; ty++)
        for (int tx = 0; tx < w; tx++) SIM_MAP_AT(m, tx, ty) = SIM_TILE_EMPTY;
    m->feature_count = 0;
}

void sim_map_index(sim_map *m) {
    enclose(m);
    m->feature_count = 0;
    for (int ty = 0; ty < (int)m->h; ty++) {
        for (int tx = 0; tx < (int)m->w; tx++) {
            uint8_t t = SIM_MAP_AT(m, tx, ty);
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
        for (int tx = x0; tx <= x1; tx++) SIM_MAP_AT(m, tx, ty) = t;
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
 * The old room survives at the center, minus its enclosing box: the pillars,
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
    sim_map_size(m, SIM_MAP_TILES, SIM_MAP_TILES);

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
     * The first version of this map kept every spawn in the center room, on
     * the reasoning that pilots scattered over 1024 tiles would never find
     * each other. That reasoning made the map decorative: a full-size arena
     * whose players are all inside one 84-tile box is an 84-tile arena with a
     * lot of unused address space around it.
     *
     * So each side gets a home band -- team 1 across the north, team 0 across
     * the south -- eight starts apiece, 256 tiles apart, with the old center
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
    /* Left at the full square, and drawn where it always was. It is the only
     * room the offline ladder measures against, so moving its walls would put
     * every number ever recorded on a different map. */
    sim_map_size(m, SIM_MAP_TILES, SIM_MAP_TILES);
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
