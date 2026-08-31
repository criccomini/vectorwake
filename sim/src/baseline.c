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

/* Flight, identical on every hull. The starter resolves to the original's
 * familiar 3250 speed, 17 thrust, 230 rotation, 1600 energy and 1150 recharge,
 * but those values no longer double as the edge of the build space.
 *
 * The footprint is the exception and it is not here: those files carry no
 * ship size at all. `hull_extent` below gives every hull a fixed target budget,
 * and the client fits each drawing around that collision rectangle.
 *
 * A row per hull, and the row is the ship. Nobody spends points on these, so
 * the step is zero and the ceiling is the floor: what a hull flies at is the
 * first number, full stop, and this table is the roster in
 * docs/design/ships.md read straight off the file.
 *
 * One shared row stood here, because a kit was thirty points and thirty
 * points had to buy the same ship whatever you were sitting in. There is no
 * kit to be fair about now, so the constraint went with it and the hulls got
 * their engines back. The spread is deliberate and anti-correlated: Cipher is
 * the fastest and the thinnest, Anvil the slowest and the deepest, and
 * nothing is at the top of two rows at once.
 *
 * The pair that pays for the bar is energy against recharge. A deep bar
 * refills slowly and a shallow one refills fast, so the Anvil wins the long
 * fight and is slow to be ready for the next, and the Cipher loses any fight
 * it stays in and is full again in nine seconds if it can break away. That is
 * also the one thing in this table that makes speed worth anything: a fast
 * refill only pays to a hull that can leave.
 *
 * Those two columns ran the same way round for a while, which is what
 * `calibrate bodies` found. The Anvil held the deepest bar and nearly the
 * fastest refill at once and took 60% of its seats in a team match and 69% in
 * a duel; the Cipher, thin and no better at recovering, took 42%. Fitting win
 * rate against the two columns over 99,600 seats explains 94% of the roster's
 * spread, which is what these numbers were then solved off: the three bodies
 * already inside the margin are untouched, and the three outside it sit on the
 * line the fit draws through even. See docs/design/ships.md.
 *
 * The triplet stays because a zone may still want a hull whose stat climbs,
 * and `eff` reads it the same way whether the step is zero or not. */
static const sim_class_units flight[SIM_MAX_CLASSES] = {
    /*        speed        thrust        rotation       energy      recharge */
    /* Apex    */ {3600,0,3600, 205,0,205, 250,0,250, 1500,0,1500, 1150,0,1150},
    /* Wedge   */ {2900,0,2900, 155,0,155, 205,0,205, 1900,0,1900, 1020,0,1020},
    /* Chord   */ {2800,0,2800, 215,0,215, 310,0,310, 1550,0,1550, 1200,0,1200},
    /* Anvil   */ {2650,0,2650, 145,0,145, 195,0,195, 2100,0,2100,  875,0, 875},
    /* Cipher  */ {3900,0,3900, 200,0,200, 235,0,235, 1300,0,1300, 1450,0,1450},
    /* Facet   */ {3050,0,3050, 175,0,175, 265,0,265, 1450,0,1450, 1225,0,1225},
    /* Lattice */ {3100,0,3100, 165,0,165, 240,0,240, 1750,0,1750, 1050,0,1050},
};

/* The weapons, and they belong to nobody.
 *
 * One gun and one bomb, three rungs each, and every hull fires both. A hull is
 * a flight row and a footprint; what leaves it is the pilot's build. The two
 * do not meet anywhere in this file, so a Cipher throws the same bomb an Anvil
 * does and what separates them is how fast it arrives and how much it can
 * afford to be hit on the way.
 *
 * That is the original's arrangement as well. All eight of its ships carry
 * identical weapon numbers, and what its per-ship section actually says is
 * how a ship flies. A Warbird's bullet is a Javelin's bullet.
 *
 * So the ladder is the original's too, and each half of it climbs the way that
 * settings file climbs rather than by a fraction invented here:
 *
 *   BulletDamageLevel 200, and a level adds 100
 *   BulletFireEnergy 20, times the level
 *   BulletFireDelay 25, whatever the level
 *   BombDamageLevel 750, at every level
 *   BombExplodePixels 80, doubled at L2 and tripled at L3
 *   BombFireEnergy 300, and a level adds 50
 *   BombFireDelay 150, whatever the level
 *
 * A gun rung therefore sells the size of one arriving hit and charges for it
 * twice over, in energy and in nothing else: the rate never moves, so a rung
 * is a heavier round rather than a second gun. A bomb rung sells reach, since
 * 750 is 750 at every level, and the tripled blast at the top is wide enough
 * that the thrower is inside it. */

/* How many rungs the gun and the bomb hold, counting the one a pilot arrives
 * on. Three, which is what the original gives both, and two credits is what
 * climbing to the top of one costs out of seven.
 *
 * `SIM_MAX_RUNGS` is four and this is deliberately one short of it. The
 * fourth rung stays for a zone that wants a weapon that climbs further, and
 * there is room either way: two ladders of three fill 6 of the 64 specs and 6
 * of the 64 patterns, where a ladder per hull filled 42 and 44. */
#define ROSTER_RUNGS 3

/* Gun: what one round does, what one pull costs, and the ticks between pulls.
 *
 * What a pull actually throws is this times the pilot's spray, so the row is
 * one round and the build says how many. The extra rounds cost energy and
 * cooldown on top, off `mod_multi_energy` and `mod_multi_delay`. */
#define GUN_DAMAGE     200   /* BulletDamageLevel */
#define GUN_DAMAGE_UP  100   /* a level adds this much */
#define GUN_ENERGY      20   /* BulletFireEnergy, times the level */
#define GUN_DELAY       25   /* BulletFireDelay, at every level */

/* Bomb: the same four, and a radius, since what a bomb level buys is reach. */
#define BOMB_DAMAGE    750   /* BombDamageLevel, at every level */
#define BOMB_BLAST      80   /* BombExplodePixels, times the level */
#define BOMB_ENERGY    300   /* BombFireEnergy */
#define BOMB_ENERGY_UP  50   /* a level adds this much */
#define BOMB_DELAY     150   /* BombFireDelay, at every level */

#define BULLET_LIFE     550   /* BulletAliveTime: 5.5 s, 69 tiles of reach */
#define BOMB_THRUST     400   /* BombThrust: the recoil of letting one go */

/* How far apart a pair of rounds leave, at 65536 to the turn.
 *
 * Two and a quarter degrees, which is tight enough that both rounds land on
 * one hull out to about three hundred pixels and start to straddle beyond it.
 * At the fifteen degrees this was, the two rounds are twenty-six pixels either
 * side of the line at two hundred, so a pair aimed dead at a dart went past it
 * on both sides and the first rung of spray bought nothing anybody could land.
 *
 * Three rounds and up open out to the zone's own `mod_spread`, so the fan is
 * still a fan. What this sets is what two abreast means.
 *
 * It has to be nonzero. A pattern of many at spacing zero is the shrapnel
 * encoding, and scatters. */
#define BARREL_SPREAD (65536 / 160)

/* Each hull's footprint, in Q8 pixels from the point it turns about: past the
   nose, behind the tail, to either side. client/tests/hull_fit_test.lua reads
   this table out of this file by name and measures the client's drawing
   against it, so the two cannot drift; renaming it breaks that test rather
   than silencing it.

   Every row has exactly 625 square pixels of target area:

       (fore + aft) * (2 * halfw) = 625 px^2

   Shape spends that fixed budget. Cipher puts it into length, Chord into
   beam, and the square hulls expose nearly the same cross-section at every
   heading. Before this contract, Cipher occupied 408 square pixels while
   Lattice occupied 840, which was a free advantage rather than a trade.

   The collision box is built from these at the ship's current heading, so a
   hull touches a wall where it is drawn touching it whichever way it points.
   The client drawing sits about a pixel outside each face of its box.

   The pixel of inset is not slack. It is what lets a long hull spin: at the
   worst diagonal the box reaches sqrt(fore^2 + halfw^2) from the ship, and
   holding that under 23 -- the ceiling the shipped maps were flood-filled
   and spawn-checked against -- is what keeps every room reachable, every
   spawn safe, and a full rotation possible in a three-tile corridor. A pixel
   of hull crossing a wall at the moment of contact is invisible; the old
   defect was seven and a half.

                                      fore  aft  halfw */
static const uint16_t hull_extent[SIM_MAX_CLASSES][3] = {
    /* Apex:    31.25 long by 20 wide        */ {5120, 2880, 2560},
    /* Wedge:   20 long by 31.25 wide        */ {2816, 2304, 4000},
    /* Chord:   16 long by 39.0625 wide      */ {2304, 1792, 5000},
    /* Anvil:   25 long by 25 wide           */ {3328, 3072, 3200},
    /* Cipher:  39.0625 long by 16 wide      */ {5376, 4624, 2048},
    /* Facet:   25 long by 25 wide           */ {3328, 3072, 3200},
    /* Lattice: 25 long by 25 wide           */ {3328, 3072, 3200},
};

/* ---- what a pilot may hold ----
 *
 * A ceiling a hull, then a ceiling a zone, and now neither: one row of
 * ceilings for everybody, because a slot a hull cannot reach is the hull
 * deciding what a pilot flies. See `fill_slot_caps` below for the row.
 */

/* Repels and bursts are three, which is RepelMax and BurstMax on all eight of
 * the original's ships. */
#define CHARGE_REPEL_MAX 3
#define CHARGE_BURST_MAX 3

/* How long a burst shuts its own key for. A second and a half, which is the
 * longest wait any weapon in this game asks for.
 *
 * The original has no such setting and did not need one: a burst is loot
 * there, and a pilot holding three has had a good afternoon. Here a rack is
 * bought once and refilled at every spawn, so the only thing between the first
 * press and the third was how fast a thumb moves. Three at once is three
 * rosettes from one standing position, and at 700 a round it takes three of
 * the seventy-two to end anybody. What that asked of the pilot was one
 * approach.
 *
 * This prices the cadence rather than the fight. Emptying the rack takes
 * three seconds now, which is long enough that the second and third bursts
 * are flown between and aimed separately, and short enough that both are
 * still available in the fight the first one was thrown into.
 *
 * The repel keeps none of this. It does no damage, chaining it only wastes
 * it, and it is the answer to a round already in the air. */
#define CHARGE_BURST_DELAY 150

/* ---- the row a pilot arrives on ----
 *
 * One build, dealt to whoever sends none of their own, and the same one in
 * every hull. It used to be seven rows, one a hull, and that was the ship
 * deciding the loadout: a Facet fired five rounds because it was a Facet and a
 * Cipher had no rack at all. Now the hull is how it flies and this is what it
 * carries until a pilot says otherwise.
 *
 * A whole ship rather than a bare one: the second rung of both weapons, a gun
 * that comes off walls, a fuse so a near miss counts, four fragments off the
 * blast, and one of each charge to get out with. Seven credits, which is all
 * of them, so a pilot who wants something else trades for it.
 *
 * `client/arena/menu.lua` holds the same list written as slot names, and the
 * two have to agree: that one is what a pilot who has never opened the hangar
 * sends, and this one is what anybody who sends nothing gets.
 *
 * The stat slots are zero. Flight is the `flight` table above, where the step
 * is zero and the ceiling is the floor, so a stat step here would buy nothing.
 * They stay in the space for a zone that writes a climbing hull. */
static void fill_default_kit(sim_ship_class *c) {
    memset(c->kit, 0, sizeof c->kit);
    c->kit[SIM_SLOT_LEVEL(SIM_TRIG_GUN)] = 1;
    c->kit[SIM_SLOT_LEVEL(SIM_TRIG_BOMB)] = 1;
    c->kit[SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_BOUNCE)] = 1;
    c->kit[SIM_SLOT_MOD(SIM_TRIG_BOMB, SIM_MOD_PROX)] = 1;
    c->kit[SIM_SLOT_MOD(SIM_TRIG_BOMB, SIM_MOD_SHRAPNEL)] = 1;
    c->kit[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = 1;
    c->kit[SIM_SLOT_CHARGE(SIM_CHARGE_BURST)] = 1;
}

/* How high a pilot may take each slot. One row for the arena, and the only
 * thing in this file that says what a build may contain.
 *
 * A slot's ceiling is the whole of the balance lever. Every step costs one
 * credit, so a slot that turns out too strong cannot be made dearer and has to
 * be made shallower; `calibrate builds` is what finds them.
 *
 * Two things it found, and both are written down here. Seven of one charge
 * beat everything else on every hull: a rack is capped by the budget alone
 * otherwise, and seven bursts is not a build, it is an artillery piece. And an
 * add-on that belongs on a bomb wins outright on a gun: rounds with a
 * proximity fuse do not need to hit, and rounds that bounce fill a room. So a
 * fuse and shrapnel are the bomb's and spray is the gun's.
 *
 * Where a ceiling is zero the slot is not a slot: the client draws no row for
 * it and a build naming it is fitted down. A zone that wants one raises it.
 * The stat rows keep their full ladder rather than being shut off, because
 * their step is zero in this roster and a zone that writes a climbing hull
 * would otherwise have to remember to raise two numbers instead of one. */
static void fill_slot_caps(sim_settings *cfg) {
    for (int u = 0; u < SIM_UP_COUNT; u++) {
        cfg->slot_cap[SIM_SLOT_STAT(u)] = SIM_UP_STEPS;
    }
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        /* The ladder itself caps this again, whichever is lower, and both
         * ladders are ROSTER_RUNGS long. */
        cfg->slot_cap[SIM_SLOT_LEVEL(t)] = SIM_MAX_RUNGS - 1;
    }
    /*                                  spray  bounce  prox  shrap  freeze  push */
    static const uint8_t gun[SIM_MOD_COUNT]  = {5, 1, 0, 0, 1, 0};
    static const uint8_t bomb[SIM_MOD_COUNT] = {0, 1, 1, 3, 1, 0};
    for (int m = 0; m < SIM_MOD_COUNT; m++) {
        cfg->slot_cap[SIM_SLOT_MOD(SIM_TRIG_GUN, m)] = gun[m];
        cfg->slot_cap[SIM_SLOT_MOD(SIM_TRIG_BOMB, m)] = bomb[m];
    }
    /* Both racks are the original's. The burst stood at two while the deepest
     * rack in the roster was a Lattice's, and that reason went with the
     * per-hull rows: seven credits is what stops a pilot carrying three of
     * each now. */
    cfg->slot_cap[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = CHARGE_REPEL_MAX;
    cfg->slot_cap[SIM_SLOT_CHARGE(SIM_CHARGE_BURST)] = CHARGE_BURST_MAX;
    for (int k = 2; k < SIM_MAX_CHARGES; k++) {
        cfg->slot_cap[SIM_SLOT_CHARGE(k)] = SIM_CHARGE_MAX;
    }
}

const char *const sim_class_names[SIM_MAX_CLASSES] = {
    "Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet", "Lattice"};

void sim_settings_baseline(sim_settings *cfg, const sim_map *map) {
    cfg->class_count = SIM_MAX_CLASSES;
    fill_slot_caps(cfg);
    cfg->spec_count = 0;
    cfg->pattern_count = 0;
    /* Every death is real, which is the server's answer and the safe one:
     * callers hand this function uninitialized structs, and a garbage byte
     * here would be a server that quietly stopped killing anybody. The
     * prediction client overrides both after every baseline (decision 40). */
    cfg->deathless = 0;
    cfg->mortal_ship = 255;
    /* Misc:BounceFactor, where 16 is the whole of the speed given back. Walls
     * are elastic, as the original's are: nothing in that model takes energy
     * out of a ship except a wall, and its wall takes none, so a shot that
     * carries you into one carries you out again at the speed you arrived.
     *
     * This was 10, on the argument that clipping a wall should hurt and that
     * paying for it is what makes tight flying a skill. What it actually
     * bought was a brake that a pilot who never touches anything is not
     * paying, which is a difficulty knob rather than a rule about the world.
     *
     * `friction` is the speed kept along the face, and the original has no
     * term for it at all: a wall there reverses what hit it and leaves the
     * slide alone. Ours still scrubs an eighth of it, so a wall is lossless
     * head on and not quite lossless at an angle. */
    cfg->bounce = 16;
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
    /* A hull takes a flag once it reaches eighteen pixels past its own edge. */
    cfg->flag_radius = 18 * 256;
    /* A dropped flag stays put for two seconds before another hull can take it. */
    cfg->flag_drop_cooldown = 200;
    /* Sixty-four is four times what the original aimed a public room at:
     * General:DesiredPlaying defaults to 15 playing pilots and its whole job is
     * deciding when to open another arena. So this is the room size we think
     * plays, not the most the array can take, and a zone that wants more can
     * say so up to SIM_MAX_SHIPS. */
    cfg->max_ships = 64;
    cfg->map = map;
    /* Doors breathe on a six second cycle, open for four of it: long enough
     * to commit to a crossing, short enough that the choice matters. */
    cfg->door_period = 600;
    cfg->door_open = 400;
    /* A wormhole, on the original's own field.
     *
     * The pull is quoted one tile from the center and falls off as the square
     * of the distance, so a well is nearly nothing across most of its reach
     * and overwhelming in the last few tiles. 5859 is what the original's
     * arithmetic produces at one tile from a Gravity of 1500, which is what
     * every ship in the Alpha Zone settings carries: its `gravity * 1000 /
     * distance^2` comes to 5859 at sixteen pixels, and one of ours is the
     * same number in the file's own speed units.
     *
     * The reach is 38 tiles, half of where the original's field ends, and it
     * is a number here rather than a consequence: there, the range falls out
     * of the strength, so a zone cannot make a well that is strong and small
     * or weak and wide. Ours can, which is the whole reason it can be turned
     * down. The original's 76 was sized for a 1024-tile map and our melee
     * maps are 160 across, so a well that wide is the weather over the entire
     * room. At half of it a wormhole is a landmark to fly around, and the
     * pull that matters is still the last few tiles, where it always was.
     *
     * The ceiling lift is the original's too, and it is small on purpose. It
     * applies anywhere in the field, and the field is most of a small map, so
     * a large one would be a speed bonus for standing near a landmark rather
     * than the kick of being thrown by it. */
    cfg->wormhole_pull = sim_units_speed(5859);
    cfg->wormhole_range = 38 * 16 * 256;
    cfg->wormhole_top_speed = sim_units_speed(100);
    /* GravityBombs. On, as the Alpha Zone settings have it: a bomb thrown
     * across a well bends, which is most of what makes one worth building a
     * room around. */
    cfg->gravity_bombs = 1;

    /* Three kills without dying. The shortest run that cannot be an accident
     * and is still reachable inside a three-minute match, and the only thing
     * this game says about how a pilot is doing right now: the room is told,
     * the hull goes gold, and somebody comes to end it. */
    cfg->streak_kills = 3;

    /* What one rung of each add-on is worth, in the units of the field it
     * moves. These values live here rather than inside the transform that
     * applies them. */
    cfg->mod_step[SIM_MOD_MULTI] = 1;              /* one more round abreast */
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
    cfg->mod_step[SIM_MOD_FREEZE] = 50;            /* half a second without recharge */
    cfg->mod_step[SIM_MOD_PUSH] = sim_units_speed(1200);
    cfg->mod_spread = 65536 / 24;                  /* fifteen degrees */
    /* What one more round costs, as a percentage of the shot's own energy and
     * cooldown.
     *
     * The original charged 20 energy a bullet against 30 for multifire, and 25
     * ticks of cooldown against 50: three rounds for half again the energy and
     * twice the wait. That is 25 and 50 a round over two rounds, and it is
     * what these are, so a spray of three still lands where the original put
     * it and the ladder above it keeps climbing at the same rate rather than
     * at a rate invented for the top of it. Six rounds is two and a quarter
     * times the energy and three and a half times the wait, which is a build
     * rather than an upgrade. */
    cfg->mod_multi_energy = 25;
    cfg->mod_multi_delay = 50;
    cfg->mod_pair_spread = BARREL_SPREAD;

    /* Shrapnel, one pattern per rung: two fragments, then four, then eight.
     * The fragments themselves are one spec, so a rung of shrapnel
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
         * 'Shrapnel Upgrade' prize". Two, four, eight: the rate is the first
         * rung and each one after doubles, so the third lands on ShrapnelMax.
         *
         * The Shark is where this stops matching. ShrapnelMax is 8 on seven of
         * the original's ships and 31 on that one, and an add-on here is two
         * bits, so three rungs and eight fragments are the ceiling. */
        frag.speed = sim_units_speed(3000);
        frag.life = 550;
        /* A fragment is a bullet, which is the whole of what shrapnel is in
         * the original: the burst makes rounds of the thrower's *gun* rung,
         * bouncing if their bullets bounce, and its damage runs through the
         * bullet formula rather than one of its own. So the base here is an
         * L1 bullet and `damage_up` is what a gun level adds, which makes a
         * fragment exactly the bullet the thrower's guns were firing: an L2
         * gun breaks a bomb into L2 rounds.
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
         * The gun's bounce add-on changes `on_wall` and adds one to
         * `bounces`, so a fragment wearing it survives one wall. */
        frag.on_wall = SIM_WALL_END;
        frag.bounces = 0;
        /* ShrapnelDamagePercent=1000, which the original's help defines as
         * tenths of a percent "relative to bullets of same level". The gun
         * above is that bullet and its ladder is that ladder, so these are
         * the same two numbers rather than a copy of them. */
        frag.damage = sim_units_energy(GUN_DAMAGE);
        frag.damage_up = sim_units_energy(GUN_DAMAGE_UP);
        frag.splinter = SIM_NO_PATTERN;
        uint8_t frag_spec = (uint8_t)sim_add_spec(cfg, &frag);
        cfg->mod_splinter[0] = SIM_NO_PATTERN;   /* rung zero is no shrapnel */
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            sim_fire_pattern shell;
            memset(&shell, 0, sizeof shell);
            shell.spec = frag_spec;
            static const uint8_t frags[SIM_MAX_RUNGS] = {0, 2, 4, 8};
            shell.count = frags[k];
            /* Shrapnel:Random is 1 in the original's own arena file, so
             * fragments scatter rather than leaving on an even ring. Spacing
             * of zero is how a pattern asks for that. */
            shell.spacing = 0;
            cfg->mod_splinter[k] = (uint8_t)sim_add_pattern(cfg, &shell);
        }
    }

    /* The two charges this arena ships. A charge is a pattern plus an
     * inventory and nothing else: the repel is `push` with no damage at all,
     * which the weapon model has been able to express since the day it was
     * written, and the burst is sixteen rounds at a full turn's spacing --
     * the rosette that motivated `count` and `spacing` in the first place.
     *
     * Neither shares the gun and bomb clock: a repel or burst remains
     * available while either trigger is shut, which is what makes a repel an
     * answer to anything. The burst keeps a clock of its own instead, which is
     * CHARGE_BURST_DELAY above and the reason it is there. */
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
        bf.delay = CHARGE_BURST_DELAY;
        cfg->charge[1] = (uint8_t)sim_add_pattern(cfg, &bf);

        /* The rack is wider than the two kinds that fill it, and a slot with
         * no pattern is a slot nothing can be dealt from. */
        for (int k = 2; k < SIM_MAX_CHARGES; k++) cfg->charge[k] = SIM_NO_PATTERN;
    }

    /* The two ladders, built once. Every hull is handed the same pattern
     * indices below, so there is one gun in this game and one bomb, and a
     * rung of either is the same round whoever is holding it. */
    uint8_t gun_rung[SIM_MAX_RUNGS], bomb_rung[SIM_MAX_RUNGS];
    for (int r = 0; r < SIM_MAX_RUNGS; r++) {
        gun_rung[r] = SIM_NO_PATTERN;
        bomb_rung[r] = SIM_NO_PATTERN;
    }
    for (int r = 0; r < ROSTER_RUNGS; r++) {
        sim_weapon_spec bolt;
        memset(&bolt, 0, sizeof bolt);
        bolt.speed = sim_units_speed(2000);
        bolt.life = BULLET_LIFE;
        bolt.on_wall = SIM_WALL_END;
        /* The add-on buys one wall, as its single rung says. Infinite
         * ricochets made that one point dominate whole corridors. */
        bolt.bounces = 0;
        /* BulletDamageLevel plus what a level adds. */
        bolt.damage = sim_units_energy(GUN_DAMAGE + r * GUN_DAMAGE_UP);
        bolt.splinter = SIM_NO_PATTERN;

        sim_fire_pattern gun;
        memset(&gun, 0, sizeof gun);
        gun.spec = (uint8_t)sim_add_spec(cfg, &bolt);
        /* One round. What actually leaves the barrel is this times the
         * pilot's spray, applied when the trigger is pulled. */
        gun.count = 1;
        gun.spacing = 0;
        /* BulletFireEnergy times the level, which is the original's own
         * arrangement: a harder bullet asks for more of the same bar it is
         * trying to take from its target. */
        gun.energy = sim_units_energy(GUN_ENERGY * (r + 1));
        /* The rate does not move. BulletFireDelay is one number whatever the
         * level, and a rung that fired faster as well as harder would be the
         * whole gun bought twice. */
        gun.delay = GUN_DELAY;
        gun_rung[r] = (uint8_t)sim_add_pattern(cfg, &gun);

        sim_weapon_spec sh;
        memset(&sh, 0, sizeof sh);
        /* BombSpeed=2000 and BombAliveTime=6000. Sixty seconds is not a
         * fuse, it is "until it hits something", which is what the
         * original means on a map this size.
         *
         * This said 8000, from the reference server's own config rather
         * than from VIE's, and both shipped zones then overrode it back
         * to 6000 while describing that as their own deviation. Two
         * sources, one of them the game we are actually copying. */
        sh.speed = sim_units_speed(2000);
        sh.life = 6000;
        sh.on_wall = SIM_WALL_END;
        /* BombDamageLevel is 750 at every level and BombExplodePixels is what
         * a level buys: 80, doubled, then tripled. */
        sh.damage = sim_units_energy(BOMB_DAMAGE);
        sh.blast = BOMB_BLAST * (r + 1) * 256;
        sh.splinter = SIM_NO_PATTERN;

        sim_fire_pattern bomb;
        memset(&bomb, 0, sizeof bomb);
        bomb.spec = (uint8_t)sim_add_spec(cfg, &sh);
        bomb.count = 1;
        bomb.energy = sim_units_energy(BOMB_ENERGY + r * BOMB_ENERGY_UP);
        bomb.delay = BOMB_DELAY;
        bomb.recoil = sim_units_speed(BOMB_THRUST);
        bomb_rung[r] = (uint8_t)sim_add_pattern(cfg, &bomb);
    }

    /* Every hull, and every one of them a different ship. Flight comes off
     * `flight` and the footprint off `hull_extent`, which is the whole of what
     * a hull is: two tables, one row each, and no weapon in either. */
    for (int i = 0; i < SIM_MAX_CLASSES; i++) {
        sim_ship_class *c = &cfg->classes[i];
        sim_class_from_units(c, &flight[i]);
        c->fore = (int32_t)hull_extent[i][0];
        c->aft = (int32_t)hull_extent[i][1];
        c->halfw = (int32_t)hull_extent[i][2];
        fill_default_kit(c);
        for (int r = 0; r < SIM_MAX_RUNGS; r++) {
            c->trigger[SIM_TRIG_GUN][r] = gun_rung[r];
            c->trigger[SIM_TRIG_BOMB][r] = bomb_rung[r];
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
     * a wall that gave back ten sixteenths converged to a tenth of a pixel a
     * tick, which a pilot reports as the zone being sticky. The zone was
     * never sticky. The cul-de-sac behind it was, and a wall that gives
     * everything back does not converge like that at all; the placement rule
     * stands on its own either way. */
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
 * Offline pilot calibration is the only caller. */
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
