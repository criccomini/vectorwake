//! Bindings to the C simulation core.
//!
//! The server does not reimplement a single game rule: it owns the authoritative
//! `sim_state` and calls `sim_step`, exactly as the client does for prediction.
//! One source, two callers, identical results.

#![allow(non_camel_case_types)]

use std::os::raw::c_int;

/* The array bound, matching SIM_MAX_SHIPS. What a zone actually allows is
 * sim_settings.max_ships, which the core clamps to this. */
pub const MAX_SHIPS: usize = 255;
pub const MAX_WEAPONS: usize = 1024;
pub const MAX_EVENTS: usize = 256;
pub const MAX_CLASSES: usize = 7;
pub const MAX_SPECS: usize = 64;
pub const MAX_PATTERNS: usize = 64;
pub const MAP_TILES: usize = 1024;
pub const TILE_PX: i32 = 16;

pub const BTN_LEFT: u16 = 1;
pub const BTN_RIGHT: u16 = 2;
pub const BTN_THRUST: u16 = 4;
pub const BTN_REVERSE: u16 = 8;
pub const BTN_FIRE: u16 = 16;
pub const BTN_BOMB: u16 = 32;
/// Spend one of the selected charge, and which slot that is. Two bits, because
/// which charge is ready is the client's business and not simulation state.
pub const BTN_USE: u16 = 64;
pub const BTN_SLOT_SHIFT: u16 = 7;
pub const BTN_MULTI: u16 = 0x0200;

/// Spend the mine slot, which is what laying one is now: 0x0400 used to be a
/// button of its own, because a mine was the bomb trigger's other posture.
pub const fn btn_charge(k: usize) -> u16 {
    BTN_USE | ((k as u16) << BTN_SLOT_SHIFT)
}

// Mirrored by hand from sim_event_type in sim/include/sim/sim.h, so the order
// there is the order here and a new one goes on the end.
//
// The whole enum is listed even where nothing here matches on it yet, because
// a partial mirror is what goes wrong: deleting SIM_EV_PRIZE from the core
// slid every event after it down by one, and with only the handled half
// written down there was nothing to notice that a charge had become an
// expiry. `the_event_numbers_are_the_ones_the_core_emits` reads the header and
// checks all of them now.
pub const EV_FIRE: u8 = 1;
pub const EV_BOUNCE: u8 = 2;
pub const EV_HIT: u8 = 3;
pub const EV_DEATH: u8 = 4;
pub const EV_SPAWN: u8 = 5;
pub const EV_EXPIRE: u8 = 6;
pub const EV_CHARGE: u8 = 7;
pub const EV_FLAG_TAKE: u8 = 8;
pub const EV_FLAG_DROP: u8 = 9;
pub const EV_GOAL: u8 = 10;
pub const EV_WARP: u8 = 11;
pub const EV_RICOCHET: u8 = 12;

pub const MAX_FEATURES: usize = 256;
pub const MAP_PACK_MAX: usize = MAP_TILES * MAP_TILES * 3 / 2 + 32;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct sim_feature {
    pub tx: u16,
    pub ty: u16,
    pub kind: u8,
    pub variant: u8,
}

/// Mirrors `sim_map`. A tile is its behavior -- see the enum in sim.h -- and
/// the feature list is what rules reach for so nothing walks a million tiles
/// a tick.
#[repr(C)]
pub struct sim_map {
    pub tile: [u8; MAP_TILES * MAP_TILES],
    pub feature_count: u16,
    pub features: [sim_feature; MAX_FEATURES],
}

/// One projectile: how it flies, what ends it, and what happens where it
/// ends. Mirrors `sim_weapon_spec`; the model is documented in
/// sim/include/sim/sim.h and docs/design/weapons.md.
#[repr(C)]
#[derive(Clone, Copy, Default)]
#[allow(dead_code)]
pub struct sim_weapon_spec {
    pub speed: i32,
    pub life: u16,
    pub on_wall: u8,
    pub bounces: u8,
    /// Whether the round is laid rather than thrown: it takes none of the
    /// firer's velocity and stays where it was let go. A mine, and nothing
    /// else, because everything that flies wants the ship's speed added.
    pub still: u8,
    pub trigger: i32,
    pub expire_ends: u8,
    pub splinter: u8,
    pub damage: i32,
    /// Damage a rung adds, which is BulletDamageUpgrade. Set on the shrapnel
    /// fragment, whose rung is its thrower's gun rather than a ladder.
    pub damage_up: i32,
    pub blast: i32,
    /// Blast a rung adds, for the weapon whose rung is not a ladder either: a
    /// mine is a charge, so it is one spec wearing the layer's bomb rung.
    pub blast_up: i32,
    pub push: i32,
    /// Ticks a shoved hull keeps the repel's speed ceiling. RepelTime.
    pub push_time: u16,
    pub stall: u16,
}

/// What pulling a trigger makes. Mirrors `sim_fire_pattern`.
#[repr(C)]
#[derive(Clone, Copy, Default)]
#[allow(dead_code)]
pub struct sim_fire_pattern {
    pub spec: u8,
    pub count: u8,
    pub spacing: u16,
    pub energy: i32,
    /// Energy a rung adds, for a trigger whose rungs are not separate
    /// patterns. LandmineFireEnergyUpgrade; a mine is one pattern wearing the
    /// pilot's bomb rung.
    pub energy_up: i32,
    pub delay: u16,
    pub recoil: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
#[allow(dead_code)]
pub struct sim_ship_class {
    pub max_speed: i32,
    pub init_speed: i32,
    pub up_speed: i32,
    pub thrust: i32,
    pub init_thrust: i32,
    pub up_thrust: i32,
    pub rot: i32,
    pub init_rot: i32,
    pub up_rot: i32,
    pub max_energy: i32,
    pub init_energy: i32,
    pub up_energy: i32,
    pub recharge: i32,
    pub init_recharge: i32,
    pub up_recharge: i32,
    /// The hull's footprint: reach past the nose, behind the tail, and to
    /// either side, Q8 px. The core builds the collision box from these at
    /// the ship's current heading.
    pub fore: i32,
    pub aft: i32,
    pub halfw: i32,
    /// A ladder of patterns per trigger, climbed by the pilot's level, with
    /// 255 ending it. The baseline builds the same ladders for every class;
    /// how far a weapon climbs is `sim_settings::kit_ceiling` now.
    pub trigger: [[u8; MAX_RUNGS]; TRIG_COUNT],
}

#[repr(C)]
pub struct sim_settings {
    pub classes: [sim_ship_class; MAX_CLASSES],
    pub class_count: u8,
    /// Every weapon in the zone, and every way of firing one.
    pub specs: [sim_weapon_spec; MAX_SPECS],
    pub patterns: [sim_fire_pattern; MAX_PATTERNS],
    pub spec_count: u8,
    pub pattern_count: u8,
    /// What each charge kind fires, as a pattern index.
    pub charge: [u8; MAX_CHARGES],
    /// The most a kit may put in each slot, over the flat slot space, and
    /// zero for a slot this arena does not have. Zone-wide: it was a row per
    /// hull, which meant an upgrade could be bought and then refused by the
    /// hull somebody wanted to fly it on.
    pub kit_ceiling: [u8; SLOT_COUNT],
    /// What a kill adds to the killer's own bounty. Bounty is a run rather
    /// than a loadout, so this is the whole of what makes one.
    pub bounty_per_kill: u16,
    /// What a pilot who has just spawned is worth. One, so killing one pays
    /// almost nothing and camping a pad is not a living.
    pub bounty_base: u16,
    /// Points on top of the victim's bounty per flag they were carrying.
    pub points_per_flag: u16,
    /// What one rung of each add-on is worth, in the units of the field it
    /// moves.
    pub mod_step: [i32; MOD_COUNT],
    pub mod_spread: u16,
    /// Percent a rung of multifire adds to the shot's energy and cooldown.
    pub mod_multi_energy: u16,
    pub mod_multi_delay: u16,
    /// Percent a rung of barrels adds to the shot's energy. There is no delay
    /// to match: barrels do not slow the gun, which is the trade against
    /// multifire, which does.
    pub mod_barrel_energy: u16,
    /// The angle a pair of barrels leaves at, tighter than `mod_spread`.
    pub mod_barrel_spread: u16,
    /// What each rung of shrapnel breaks into.
    pub mod_splinter: [u8; MAX_RUNGS],
    /// Q8 px a bomb level adds to the proximity fuse.
    pub prox_step: i32,
    /// BombExplodeDelay: how long an armed fuse waits for its target to
    /// start pulling away before going off regardless.
    pub prox_delay: u16,
    /// BombSafety: a proximity bomb will not fire with an enemy already
    /// inside the fuse's distance.
    pub bomb_safety: u8,
    /// BBombDamagePercent, per thousand, on a hull whose bombs may bounce.
    pub bbomb_damage: u16,
    /// BombExplodeDelay, in ticks after a proximity crossing.
    /// Q10 energy a fragment does while it is still inactive, and how long
    /// that lasts in ticks.
    pub shrap_inactive: i32,
    pub shrap_inactive_ticks: u16,
    pub bounce: i32,
    pub friction: i32,
    pub respawn_delay: u16,
    /// Zero spawns on the map's own tiles; above zero ignores them and drops a
    /// ship on a random tile within this many of the map's center. See
    /// `spawn_radius` in `sim.h` for which arrangement a zone is buying.
    pub spawn_radius: u16,
    /// Whether a client marks the map's spawn tiles. Render only, and ignored
    /// by the client when `spawn_radius` is set.
    pub show_spawns: u8,
    /// Ticks a ship may sit in a safe zone before the room takes its seat
    /// back, zero for never. The core neither counts it nor acts on it: it
    /// travels in the settings so the room and the client read one number.
    pub safe_limit: u16,
    pub door_period: u16,
    pub door_open: u16,
    pub wormhole_pull: i32,
    pub wormhole_range: i32,
    pub flag_radius: i32,
    pub flag_drop_cooldown: u16,
    pub max_ships: u8,
    /// Whose death this instance may conclude on its own. The server keeps
    /// both at zero, which `sim_settings_baseline` writes: every death is
    /// real here. The prediction client sets them; see sim.h (decision 40).
    pub deathless: u8,
    pub mortal_ship: u8,
    pub map: *const sim_map,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_ship {
    pub active: u8,
    pub alive: u8,
    /// One when a network snapshot carried only this ship's public record.
    pub public_only: u8,
    pub cls: u8,
    pub team: u8,
    pub x: i32,
    pub y: i32,
    pub vx: i32,
    pub vy: i32,
    pub heading: u16,
    pub energy: i32,
    /// One per trigger: the original keeps two and crosses them, so an
    /// EMP bomb can leave its own guns running.
    pub fire_cooldown: [u16; TRIG_COUNT],
    /// Ticks of suppressed recharge: what a stall round leaves behind.
    pub stall: u16,
    /// A shove in progress: ticks left, and the ceiling it lifts this hull to.
    pub repel: u16,
    pub repel_speed: i32,
    pub respawn_at: u16,
    pub spawn_x: i32,
    pub spawn_y: i32,
    pub kills: u16,
    pub deaths: u16,
    /// What this hull is, which is the kit dealt back at every spawn.
    pub up: [u8; UP_COUNT],
    pub level: [u8; TRIG_COUNT],
    pub mods: [u16; TRIG_COUNT],
    /// The kit itself, over the flat slot space, so a respawn can re-deal it.
    pub kit: [u8; SLOT_COUNT],
    /// Multifire declined: the add-on is still held, it is just not applied
    /// when the trigger is pulled.
    pub multi_off: u8,
    /// Last tick's buttons, for the toggles that fire on a press.
    pub btn_prev: u16,
    /// Charges in hand, and the one thing a death does not give back: the
    /// kit deals them once and the match spends them.
    pub charge: [u8; MAX_CHARGES],
    /// Kills since this hull last spawned, which is its whole bounty beyond
    /// the base. Cleared by death.
    pub run: u16,
    /// The score. Not cleared by death.
    pub points: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_flag {
    pub active: u8,
    pub carried: u8,
    pub carrier: u8,
    pub team: u8,
    pub x: i32,
    pub y: i32,
    pub cooldown: u16,
}

pub const MAX_FLAGS: usize = 16;
pub const TEAM_NONE: u8 = 255;
/// A trigger with nothing on it. Matches `SIM_NO_PATTERN`.
pub const NO_PATTERN: u8 = 255;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_weapon {
    /// Index into the settings' spec table: what this projectile *is*.
    pub spec: u8,
    pub owner: u8,
    pub team: u8,
    /// Bounces remaining, and splinter generations behind it. Both are per
    /// projectile rather than per spec, because both are spent as it flies.
    pub left: u8,
    pub depth: u8,
    /// The add-ons of the trigger that fired it: a shot is what it was when
    /// it left, not what its owner is carrying now.
    pub mods: u16,
    /// Nonzero rounds with the same link belong to one gun volley. A hull hit
    /// spends the remaining rounds in that volley, while a wall hit does not.
    pub link: u32,
    pub x: i32,
    pub y: i32,
    pub vx: i32,
    pub vy: i32,
    pub life: u16,
    /// A proximity fuse that has found somebody: the hull it latched (255
    /// while unarmed), BombExplodeDelay counting down, and the closest that
    /// hull has been as the larger of the two axis gaps, Q8 px.
    pub fuse_target: u8,
    pub fuse: u16,
    pub near: i32,
    /// The rung this round was fired at, carried because the spec is composed
    /// again where it lands and the rung is not recoverable there.
    pub level: u8,
    /// What its fragments will be, read off the thrower's *guns* at the
    /// throw: shrapnel is bullets in the original.
    pub shrap_level: u8,
    pub shrap_bounce: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct sim_state {
    pub tick: u32,
    pub rng: u32,
    pub ship_count: u8,
    pub weapon_count: u16,
    pub ships: [sim_ship; MAX_SHIPS],
    pub weapons: [sim_weapon; MAX_WEAPONS],
    pub flags: [sim_flag; MAX_FLAGS],
    pub flag_count: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct sim_input {
    pub ship: u8,
    pub buttons: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_event {
    pub etype: u8,
    pub a: u8,
    pub b: u8,
    pub v: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct sim_events {
    pub count: u16,
    pub dropped: u16,
    pub e: [sim_event; MAX_EVENTS],
    pub predicted_death_count: u16,
    pub predicted_death: [u8; MAX_SHIPS],
}

extern "C" {
    pub fn sim_init(s: *mut sim_state, seed: u32);
    pub fn sim_spawn(
        s: *mut sim_state,
        cls: u8,
        team: u8,
        x_px: i32,
        y_px: i32,
        heading: u16,
        cfg: *const sim_settings,
    ) -> c_int;
    pub fn sim_step(
        next: *mut sim_state,
        prev: *const sim_state,
        inputs: *const sim_input,
        input_count: u16,
        cfg: *const sim_settings,
        ev: *mut sim_events,
    );
    pub fn sim_set_ship_class(s: *mut sim_state, cfg: *const sim_settings, i: u8, cls: u8)
        -> c_int;
    pub fn sim_hash(s: *const sim_state) -> u64;
    /// What a pilot is worth to whoever kills them: a sum over what they hold
    /// plus what killing has earned. Derived, never stored.
    /// What a pilot is worth: the zone's base plus their run. It takes the
    /// settings now because the base is a zone number rather than a sum over
    /// what the hull is holding.
    pub fn sim_bounty(cfg: *const sim_settings, sh: *const sim_ship) -> i32;
    pub fn sim_pack_around(
        s: *const sim_state,
        out: *mut u8,
        cap: c_int,
        cx: i32,
        cy: i32,
        radius: i32,
        viewer: u8,
        owner: u8,
        options: u8,
    ) -> c_int;
    pub fn sim_sizeof_state() -> u32;
    pub fn sim_offsetof_settings_max_ships() -> u32;
    pub fn sim_eff_max_ships(cfg: *const sim_settings) -> u8;
    pub fn sim_sizeof_settings() -> u32;
    pub fn sim_sizeof_ship() -> u32;
    pub fn sim_sizeof_events() -> u32;
    pub fn sim_settings_baseline(cfg: *mut sim_settings, map: *const sim_map);
    /// The arenas live in the core so this and the client cannot disagree
    /// about the shape of the same room.
    pub fn sim_in_safe(map: *const sim_map, x: i32, y: i32) -> i32;
    pub fn sim_map_pack(map: *const sim_map, out: *mut u8, cap: i32) -> i32;
    pub fn sim_map_unpack(map: *mut sim_map, inp: *const u8, len: i32) -> i32;
    pub fn sim_set_ship_team(s: *mut sim_state, cfg: *const sim_settings, i: u8, team: u8)
        -> c_int;
    pub fn sim_map_spawn(
        map: *const sim_map,
        team: u8,
        nth: u32,
        tx: *mut u16,
        ty: *mut u16,
    ) -> i32;
    pub fn sim_spawn_point(
        s: *mut sim_state,
        cfg: *const sim_settings,
        team: u8,
        cls: u8,
        nth: u32,
        x: *mut i32,
        y: *mut i32,
    );
    pub fn sim_map_arena(map: *mut sim_map);
    pub fn sim_map_pit(map: *mut sim_map);
    pub fn sim_eff_max_energy(c: *const sim_ship_class, s: *const sim_ship) -> i32;
    pub fn sim_eff_speed(c: *const sim_ship_class, s: *const sim_ship) -> i32;
    pub fn sim_eff_thrust(c: *const sim_ship_class, s: *const sim_ship) -> i32;
    /// Per-slot ceilings for a hull, over the flat kit space. Zero is a slot
    /// the roster keeps from it.
    /// What a kit spends, which is its sum: every slot costs one.
    pub fn sim_kit_cost(kit: *const u8) -> c_int;
    /// Validate a kit against the hull and the budget, store it, deal it with
    /// ammunition. Returns 0 and changes nothing if it does not fit.
    pub fn sim_set_kit(sh: *mut sim_ship, cfg: *const sim_settings, kit: *const u8) -> c_int;
    /// Deal the stored kit. `ammunition` is the difference between arriving
    /// and respawning: a death re-deals only the frame.
    pub fn sim_deal_kit(sh: *mut sim_ship, cfg: *const sim_settings, ammunition: c_int);
    pub fn sim_restart(s: *mut sim_state, cfg: *const sim_settings);
    pub fn sim_base_entitlements(out: *mut u8);
    pub fn sim_starter_kit(ceiling: *const u8, out: *mut u8) -> c_int;
    /// One named slot, with the arena's ceilings enforced.
    pub fn sim_grant(sh: *mut sim_ship, cfg: *const sim_settings, ty: u8) -> c_int;
    pub fn sim_pack(s: *const sim_state, out: *mut u8, cap: c_int) -> c_int;
    /// The other end of a snapshot. Only a client needs this, and the bot
    /// server is a client: it learns the room the way a browser does rather
    /// than by reading the arena's memory, which is what makes "a bot knows no
    /// more than a player" a property of the transport.
    pub fn sim_unpack(s: *mut sim_state, inp: *const u8, len: c_int) -> c_int;
    pub fn sim_settings_pack(cfg: *const sim_settings, out: *mut u8, cap: c_int) -> c_int;
    /// Leaves `cfg->map` alone: geometry travels as a map and arrives first.
    pub fn sim_settings_unpack(cfg: *mut sim_settings, inp: *const u8, len: c_int) -> c_int;
    pub fn sim_add_spec(cfg: *mut sim_settings, spec: *const sim_weapon_spec) -> c_int;
    pub fn sim_add_pattern(cfg: *mut sim_settings, p: *const sim_fire_pattern) -> c_int;
    pub fn sim_add_flag(s: *mut sim_state, x_px: i32, y_px: i32) -> c_int;
    pub fn sim_flags_held(s: *const sim_state, team: u8) -> c_int;
    pub fn sim_units_speed(v: i32) -> i32;
    pub fn sim_units_thrust(v: i32) -> i32;
    pub fn sim_units_rotation(v: i32) -> i32;
    pub fn sim_units_energy(v: i32) -> i32;
    pub fn sim_units_recharge(v: i32) -> i32;
}

pub const PACK_MAX: usize = 64 * 1024;
pub const PACK_PRIVATE_ALL: u8 = 0x01;
pub const SETTINGS_PACK_MAX: usize = 8192;
pub const UP_COUNT: usize = 5;
/// The five stats a kit may put steps into, in `sim_up`'s own order, which is
/// the order the slot space and every panel that draws it use.
pub const UP_ENERGY: usize = 0;
pub const UP_RECHARGE: usize = 1;
pub const UP_SPEED: usize = 2;
pub const UP_THRUST: usize = 3;
pub const UP_ROTATION: usize = 4;
pub const TRIG_COUNT: usize = 2;
/// Which trigger is which, mirroring SIM_TRIG_GUN and SIM_TRIG_BOMB. The
/// index was written out as a bare 1 wherever a bomb was meant.
pub const TRIG_GUN: usize = 0;
pub const TRIG_BOMB: usize = 1;
pub const MOD_COUNT: usize = 7;
pub const MAX_RUNGS: usize = 4;
pub const MOD_MAX: u8 = 3;
pub const MAX_CHARGES: usize = 4;
pub const CHARGE_MAX: u8 = 15;
/// The flat kit space: a stat, a rung, an add-on or a charge, all one shape.
pub const SLOT_COUNT: usize = UP_COUNT + TRIG_COUNT + TRIG_COUNT * MOD_COUNT + MAX_CHARGES;
/// Steps a stat may climb, and what a kit may spend in total. Six over five
/// stats is exactly the budget; the last two of each are bought, and five
/// at eight is forty against thirty, so the budget always binds.
pub const UP_STEPS: u8 = 8;
pub const UP_STEPS_BASE: u8 = 6;
pub const KIT_BUDGET: u32 = 30;
/// Charge kinds. A mine is one: a count you carry and spend.
pub const CHARGE_REPEL: usize = 0;
pub const CHARGE_BURST: usize = 1;
pub const CHARGE_MINE: usize = 2;
pub const MOD_MULTI: usize = 0;
pub const MOD_BOUNCE: usize = 1;
pub const MOD_PROX: usize = 2;
pub const MOD_SHRAPNEL: usize = 3;
pub const MOD_FREEZE: usize = 4;
pub const MOD_PUSH: usize = 5;
/// More barrels, abreast rather than fanned. This was DoubleBarrel, a flag on
/// one hull; it is an add-on so that it can be bought.
pub const MOD_BARREL: usize = 6;

// Where a thing sits in the flat kit space, mirroring the SIM_SLOT_ macros.
// The space is one shape, a count with a ceiling, so a stat, a rung, an add-on
// and a charge are all addressed the same way, and anything that names a
// specific one goes through these rather than doing arithmetic at the call
// site.
pub const fn slot_stat(u: usize) -> u8 {
    u as u8
}
pub const fn slot_level(t: usize) -> u8 {
    (UP_COUNT + t) as u8
}
pub const fn slot_mod(t: usize, m: usize) -> u8 {
    (UP_COUNT + TRIG_COUNT + t * MOD_COUNT + m) as u8
}
pub const fn slot_charge(k: usize) -> u8 {
    (UP_COUNT + TRIG_COUNT + TRIG_COUNT * MOD_COUNT + k) as u8
}

/// How many rungs of one add-on a packed word holds. Two bits each, mirroring
/// `sim_mod_get`, which is a static inline and so has no symbol to link.
pub const fn mod_get(mods: u16, m: usize) -> u8 {
    ((mods >> (m * 2)) & 3) as u8
}

// Safe wrappers. The core has no globals and no allocation, so a state is a
// plain value a thread can own for the duration of a tick.

impl Default for sim_state {
    fn default() -> Self {
        // Safety: the core zeroes the struct itself, and the layout is POD.
        unsafe { std::mem::zeroed() }
    }
}

impl Default for sim_events {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

// Safety: the only raw pointer in the graph is `sim_settings.map`, which points
// at the map this World holds a reference to and which the core only ever reads.
// The `Arc` keeps that allocation alive for at least as long as the settings that
// point into it, and an `Arc`'s payload does not move when the `Arc` is cloned or
// the World is moved.
unsafe impl Send for World {}

pub struct World {
    /// Shared, because geometry is a megabyte and every room of a zone runs the
    /// same one. It is immutable once loaded: doors are computed from the tick
    /// rather than stored, so nothing in a step writes to it, and the core takes
    /// it as `const sim_map *`. This is what makes a room cost 79 KB instead of
    /// 1.1 MB, which is the whole basis of the per-room figure in
    /// docs/architecture/hosting.md.
    pub map: std::sync::Arc<sim_map>,
    pub cfg: Box<sim_settings>,
    pub state: Box<sim_state>,
    scratch: Box<sim_state>,
    pub events: Box<sim_events>,
}

/// Allocate a zeroed `T` straight onto the heap.
///
/// `Box::new(std::mem::zeroed())` builds the value on the stack and then moves
/// it, and `sim_map` alone is a megabyte: two of those in one call chain
/// overflow a default thread stack. These are `repr(C)` plain data from the
/// core, where all-zeroes is the same state `memset` would leave.
pub fn zeroed_box<T>() -> Box<T> {
    unsafe {
        let layout = std::alloc::Layout::new::<T>();
        let p = std::alloc::alloc_zeroed(layout) as *mut T;
        if p.is_null() {
            std::alloc::handle_alloc_error(layout);
        }
        Box::from_raw(p)
    }
}

impl World {
    pub fn new(seed: u32) -> Self {
        Self::with_map(seed, build_arena)
    }

    /// Build from a packed map file. The map is unpacked before anything
    /// shares it, so the settings that point into it are derived from the
    /// geometry they will actually be played on.
    pub fn from_packed(seed: u32, bytes: &[u8]) -> Result<Self, String> {
        unpack_map(bytes).map(|map| Self::on_map(seed, map))
    }

    /// Play the next match on different ground.
    ///
    /// The settings go back to the baseline over the new geometry, because a
    /// good deal of the baseline is derived from the map it was built against
    /// and `cfg.map` is a pointer into the old tiles either way. The caller
    /// re-applies the zone file afterwards, which is the same order a room
    /// takes when it opens.
    ///
    /// Ships keep their places, which is wrong for about one tick and right
    /// afterwards: a match starts by putting everybody on their own home
    /// anyway, and a mode that changes the ground mid-fight is not a thing
    /// this game has.
    pub fn set_map(&mut self, map: std::sync::Arc<sim_map>) {
        self.map = map;
        self.reset_settings();
        // Nothing in the old geometry survives the swap. A flag stands on a
        // tile of a map that is gone and a round in the air was fired down a
        // lane that no longer exists.
        self.state.flag_count = 0;
        self.state.weapon_count = 0;
    }

    /// Another simulation of the same geometry, for a second room of a zone.
    /// Settings come from the baseline again and the caller re-applies the zone
    /// file, which is the same path the first room took, so rooms cannot differ.
    pub fn sibling(&self, seed: u32) -> Self {
        Self::on_map(seed, std::sync::Arc::clone(&self.map))
    }

    /// A blank weapon, appended to both tables, and the pattern index that
    /// reaches it. The skeleton is a projectile that does nothing for a
    /// second and stops at walls, because a zeroed row would splinter into
    /// pattern zero -- a real weapon, and never the one anybody meant.
    pub fn add_weapon(&mut self) -> Option<u8> {
        let spec = sim_weapon_spec {
            life: 100,
            splinter: NO_PATTERN,
            ..Default::default()
        };
        let s = unsafe { sim_add_spec(&mut *self.cfg, &spec) };
        if s < 0 {
            return None;
        }
        let pattern = sim_fire_pattern {
            spec: s as u8,
            count: 1,
            delay: 25,
            ..Default::default()
        };
        let p = unsafe { sim_add_pattern(&mut *self.cfg, &pattern) };
        if p < 0 {
            None
        } else {
            Some(p as u8)
        }
    }

    /// Back to the numbers the core ships with, keeping the map. Applying a
    /// zone file starts here, so a reload means what the file says now
    /// rather than what it has ever said: a deleted line used to stay in
    /// force, and a weapon block appended a row every time it was read.
    pub fn reset_settings(&mut self) {
        unsafe { sim_settings_baseline(&mut *self.cfg, &*self.map) };
    }

    /// The tuning this arena is running, packed. A client predicts by
    /// stepping the core, so it steps these rather than whatever its own
    /// build compiled -- and a zone that has added a weapon has a spec table
    /// nothing else can guess.
    pub fn packed_settings(&self) -> Vec<u8> {
        let mut buf = vec![0u8; SETTINGS_PACK_MAX];
        let n = unsafe {
            sim_settings_pack(
                &*self.cfg as *const sim_settings,
                buf.as_mut_ptr(),
                buf.len() as i32,
            )
        };
        buf.truncate(if n > 0 { n as usize } else { 0 });
        buf
    }

    /// The map, packed, ready to hand a joining client.
    pub fn packed_map(&self) -> Vec<u8> {
        let mut buf = vec![0u8; MAP_PACK_MAX];
        let n = unsafe {
            sim_map_pack(
                &*self.map as *const sim_map,
                buf.as_mut_ptr(),
                buf.len() as i32,
            )
        };
        buf.truncate(if n > 0 { n as usize } else { 0 });
        buf
    }

    pub fn with_map(seed: u32, build: fn(&mut sim_map)) -> Self {
        let _ = build;
        Self::build(seed, build)
    }

    fn build(seed: u32, build: fn(&mut sim_map)) -> Self {
        let mut map: Box<sim_map> = zeroed_box();
        build(&mut map);
        Self::on_map(seed, std::sync::Arc::from(map))
    }

    /// Everything but the geometry: fresh settings from the baseline, a fresh
    /// state, and the scratch and event buffers a step needs. The one place a
    /// World is assembled, so a room built here and a room built by `sibling`
    /// start from the same numbers.
    pub fn on_map(seed: u32, map: std::sync::Arc<sim_map>) -> Self {
        let mut cfg: Box<sim_settings> = zeroed_box();
        unsafe { sim_settings_baseline(&mut *cfg, &*map) };
        let mut state: Box<sim_state> = zeroed_box();
        unsafe { sim_init(&mut *state, seed) };
        World {
            map,
            cfg,
            state,
            scratch: zeroed_box(),
            events: zeroed_box(),
        }
    }

    /// Where the map says a ship of this team starts, if it says anything.
    /// `nth` walks the map's starts and wraps, so a roster spreads out.
    pub fn map_spawn(&self, team: u8, nth: u32) -> Option<(i32, i32)> {
        let (mut tx, mut ty) = (0u16, 0u16);
        let ok =
            unsafe { sim_map_spawn(&*self.map as *const sim_map, team, nth, &mut tx, &mut ty) };
        if ok != 0 {
            Some((tx as i32, ty as i32))
        } else {
            None
        }
    }

    /// Where a ship of this team goes now, as a Q8 world position: the map's
    /// own tiles walked by `nth`, or a draw inside `spawn_radius` of the
    /// center when the zone set one. The core decides, so a seat handed out
    /// here lands where a death in the core would put the same pilot.
    pub fn spawn_point(&mut self, team: u8, cls: u8, nth: u32) -> (i32, i32) {
        let (mut x, mut y) = (0i32, 0i32);
        unsafe {
            sim_spawn_point(&mut *self.state, &*self.cfg, team, cls, nth, &mut x, &mut y);
        }
        (x, y)
    }

    /// Spawn wherever the core says a ship of this team currently starts.
    /// `tile_x`/`tile_y` are gone: a map that names no starts and a zone that
    /// sets no radius both land on the same fallback inside the core now,
    /// instead of on whatever tile each caller happened to have in mind.
    pub fn spawn_on_map(&mut self, cls: u8, team: u8, nth: u32, heading: u16) -> i32 {
        let (x, y) = self.spawn_point(team, cls, nth);
        self.spawn_at(cls, team, x, y, heading)
    }

    pub fn spawn(&mut self, cls: u8, team: u8, tile_x: i32, tile_y: i32, heading: u16) -> i32 {
        unsafe {
            sim_spawn(
                &mut *self.state,
                cls,
                team,
                tile_x * TILE_PX,
                tile_y * TILE_PX,
                heading,
                &*self.cfg,
            )
        }
    }

    /// The same, taking a Q8 world position rather than a tile, for callers
    /// that got theirs from `spawn_point` and would otherwise divide by the
    /// tile size only for `spawn` to multiply it straight back.
    pub fn spawn_at(&mut self, cls: u8, team: u8, x: i32, y: i32, heading: u16) -> i32 {
        unsafe {
            sim_spawn(
                &mut *self.state,
                cls,
                team,
                x / 256,
                y / 256,
                heading,
                &*self.cfg,
            )
        }
    }

    /// Put a pilot in a different hull, keeping their team and their seat.
    /// The core refuses unless they are alive and at a full bar, so this is
    /// the whole of the rule and both sides get it from the same place.
    pub fn set_ship_class(&mut self, i: u8, cls: u8) -> bool {
        if cls >= self.cfg.class_count {
            return false;
        }
        unsafe { sim_set_ship_class(&mut *self.state, &*self.cfg, i, cls) == 0 }
    }

    /// Cross a pilot to another side. Which sides exist and who may enter one
    /// is the room's business; this only asks the core to move somebody, and
    /// the core refuses anyone dead or short of a full bar.
    pub fn set_ship_team(&mut self, i: u8, team: u8) -> bool {
        unsafe { sim_set_ship_team(&mut *self.state, &*self.cfg, i, team) == 0 }
    }

    pub fn step(&mut self, inputs: &[sim_input]) {
        unsafe {
            sim_step(
                &mut *self.scratch,
                &*self.state,
                inputs.as_ptr(),
                inputs.len() as u16,
                &*self.cfg,
                &mut *self.events,
            );
        }
        std::mem::swap(&mut self.state, &mut self.scratch);
    }

    pub fn hash(&self) -> u64 {
        unsafe { sim_hash(&*self.state) }
    }

    pub fn pack(&self, out: &mut [u8]) -> i32 {
        unsafe { sim_pack(&*self.state, out.as_mut_ptr(), out.len() as c_int) }
    }

    /// A snapshot carrying only what is within `radius` of a point, plus
    /// `viewer`'s own rounds wherever they are. Pass 255 for nobody's. See the
    /// note on `sim_pack_around` in sim/include/sim/pack.h.
    pub fn pack_around(
        &self,
        out: &mut [u8],
        cx: i32,
        cy: i32,
        radius: i32,
        viewer: u8,
        owner: u8,
        options: u8,
    ) -> i32 {
        unsafe {
            sim_pack_around(
                &*self.state,
                out.as_mut_ptr(),
                out.len() as c_int,
                cx,
                cy,
                radius,
                viewer,
                owner,
                options,
            )
        }
    }

    /// Take a snapshot the server sent. Replaces the state outright, so
    /// whatever this world had predicted since the last one is discarded
    /// rather than reconciled: a bot flies on the arena's answer.
    pub fn apply_snapshot(&mut self, bytes: &[u8]) -> bool {
        unsafe { sim_unpack(&mut *self.state, bytes.as_ptr(), bytes.len() as c_int) == 0 }
    }

    /// Take the tuning the zone sent. The map is untouched, which is why it has
    /// to have arrived first.
    pub fn apply_settings(&mut self, bytes: &[u8]) -> bool {
        unsafe { sim_settings_unpack(&mut *self.cfg, bytes.as_ptr(), bytes.len() as c_int) == 0 }
    }

    /// A fresh simulation on geometry somebody else already unpacked. The bot
    /// server holds one map per zone and hands it to every bot flying there,
    /// which is the same Arc the arena uses to keep a room at 79 KB instead of
    /// 1.1 MB: fifty bots in one zone cost one map between them.
    pub fn on_shared_map(seed: u32, map: std::sync::Arc<sim_map>) -> Self {
        Self::on_map(seed, map)
    }

    pub fn add_flag(&mut self, tile_x: i32, tile_y: i32) -> i32 {
        unsafe { sim_add_flag(&mut *self.state, tile_x * TILE_PX, tile_y * TILE_PX) }
    }

    pub fn flags_held(&self, team: u8) -> i32 {
        unsafe { sim_flags_held(&*self.state, team) }
    }

    pub fn eff_max_energy(&self, ship: usize) -> i32 {
        let cls = self.state.ships[ship].cls as usize;
        unsafe { sim_eff_max_energy(&self.cfg.classes[cls], &self.state.ships[ship]) }
    }

    pub fn bounty(&self, ship: usize) -> i32 {
        unsafe { sim_bounty(&*self.cfg, &self.state.ships[ship]) }
    }

    /// The common gate for voluntarily replacing a hull or leaving it behind:
    /// the ship exists, is alive, and has a full bar.
    pub fn may_reset_ship(&self, ship: usize) -> bool {
        let sh = &self.state.ships[ship];
        sh.active != 0 && sh.alive != 0 && sh.energy >= self.eff_max_energy(ship)
    }

    /// Give a seat a kit, validated against the hull and the budget. False
    /// means it did not fit and nothing changed, so a refused kit leaves the
    /// pilot in what they were already flying rather than half dressed.
    ///
    /// This is what a seat is handed on arrival and what a hangar sends. The
    /// core deals it again at every respawn, minus the ammunition.
    /// Open a match: everybody home, whole, and reloaded. See `sim_restart`.
    pub fn restart(&mut self) {
        unsafe { sim_restart(&mut *self.state, &*self.cfg) }
    }

    pub fn set_kit(&mut self, ship: usize, kit: &[u8; SLOT_COUNT]) -> bool {
        let sh: *mut sim_ship = &mut self.state.ships[ship];
        unsafe { sim_set_kit(sh, &*self.cfg, kit.as_ptr()) != 0 }
    }

    /// Per-slot ceilings for a hull: how many of each a kit may ask for.
    /// Zero is a slot the roster keeps from that hull.
    /// What a kit costs, which is the sum of its slots: every one of them is
    /// worth exactly one. See `sim_kit_cost`.
    pub fn kit_cost(kit: &[u8; SLOT_COUNT]) -> u32 {
        unsafe { sim_kit_cost(kit.as_ptr()).max(0) as u32 }
    }

    /// What an account owns before it has bought anything. See
    /// `sim_base_entitlements`.
    pub fn base_entitlements() -> [u8; SLOT_COUNT] {
        let mut out = [0u8; SLOT_COUNT];
        unsafe { sim_base_entitlements(out.as_mut_ptr()) };
        out
    }

    /// A whole budget spent inside these ceilings, which is what a seat with
    /// no kit of its own flies. See `sim_starter_kit`.
    pub fn starter_kit(ceiling: &[u8; SLOT_COUNT]) -> [u8; SLOT_COUNT] {
        let mut out = [0u8; SLOT_COUNT];
        unsafe { sim_starter_kit(ceiling.as_ptr(), out.as_mut_ptr()) };
        out
    }

    /// What this arena lets a kit hold. No hull argument: the roster stopped
    /// having a say, so an upgrade that fits in one hangar fits in all of them.
    pub fn kit_ceilings(&self) -> [u8; SLOT_COUNT] {
        self.cfg.kit_ceiling
    }

    /// What the game itself has, before any zone tunes it: the baseline's own
    /// ceiling over the flat slot space.
    ///
    /// Upgrades need this and have no arena to ask. What is sold is entitlements,
    /// which are an account's property rather than a room's, so the question
    /// it can answer is "does this game have such a slot at all" rather than
    /// "does the room you are standing in". A zone that narrows its own
    /// ceiling can still leave a bought upgrade unslottable there, which is
    /// a zone's decision to make; what cannot happen any more is a sale
    /// selling something no arena anywhere could hold.
    ///
    /// Built once. It needs a whole settings block to read twenty-five bytes
    /// out of, and that block is a megabyte of specs and patterns.
    pub fn baseline_kit_ceiling() -> &'static [u8; SLOT_COUNT] {
        static CEILING: std::sync::OnceLock<[u8; SLOT_COUNT]> = std::sync::OnceLock::new();
        CEILING.get_or_init(|| {
            let map: Box<sim_map> = zeroed_box();
            let mut cfg: Box<sim_settings> = zeroed_box();
            unsafe { sim_settings_baseline(&mut *cfg, &*map) };
            cfg.kit_ceiling
        })
    }

    pub fn grant(&mut self, ship: usize, ty: u8) -> bool {
        let sh: *mut sim_ship = &mut self.state.ships[ship];
        unsafe { sim_grant(sh, &*self.cfg, ty) != 0 }
    }
}

/// Geometry from the bytes a zone sends at join, with nothing else attached.
///
/// `World::from_packed` builds a simulation around this. A client with many
/// pilots in one room wants the geometry once and a simulation each, and a
/// zone with several maps wants all of them and a room on one, so the two
/// halves are separable here.
///
/// The error is the reason rather than a number, because the only person who
/// ever reads one is an operator holding a file they believed was a map.
pub fn unpack_map(bytes: &[u8]) -> Result<std::sync::Arc<sim_map>, String> {
    let mut map: Box<sim_map> = zeroed_box();
    let r = unsafe {
        sim_map_unpack(
            &mut *map as *mut sim_map,
            bytes.as_ptr(),
            bytes.len() as i32,
        )
    };
    match r {
        0 => Ok(std::sync::Arc::from(map)),
        -2 => Err("the tiles do not match the hash in its header".into()),
        _ => Err("not a map file, or truncated".into()),
    }
}

/// The same arena the single-player client builds, so a player sees the same
/// room whether they are connected or not.
pub fn build_arena(map: &mut sim_map) {
    unsafe { sim_map_arena(map as *mut sim_map) }
}

pub fn build_pit(map: &mut sim_map) {
    unsafe { sim_map_pit(map as *mut sim_map) }
}

#[cfg(test)]
mod layout {
    use super::*;

    /// The mirrors above have to be the same size as the structs they mirror.
    ///
    /// Nothing else checks this. The core writes through these pointers, so a
    /// mirror one array bound behind is not a smaller struct -- it is a write
    /// past the end of the allocation, and what you see is a glibc malloc
    /// assertion in an unrelated test. That is how raising `SIM_MAX_PRIZES`
    /// from 64 to 255 announced itself, and how a field inserted in the middle
    /// of `sim_settings` announced itself before that.
    ///
    /// A size match does not prove the field *order* matches -- for that the
    /// config tests read a field either side of the one they set -- but every
    /// mismatch that has actually happened here would have been caught by it.
    #[test]
    fn mirrors_are_the_size_of_what_they_mirror() {
        unsafe {
            assert_eq!(
                std::mem::size_of::<sim_state>(),
                sim_sizeof_state() as usize,
                "sim_state mirror is the wrong size"
            );
            assert_eq!(
                std::mem::size_of::<sim_settings>(),
                sim_sizeof_settings() as usize,
                "sim_settings mirror is the wrong size"
            );
            assert_eq!(
                std::mem::size_of::<sim_ship>(),
                sim_sizeof_ship() as usize,
                "sim_ship mirror is the wrong size"
            );
            assert_eq!(
                std::mem::size_of::<sim_events>(),
                sim_sizeof_events() as usize,
                "sim_events mirror is the wrong size"
            );
        }
    }

    /// The event numbers are not sizes, so nothing above catches them drifting.
    ///
    /// They drifted. `SIM_EV_PRIZE` came out of the core with the prize,
    /// which slid `SIM_EV_CHARGE` from 8 to 7 and every event after it down by
    /// one, and the hand-written mirror stayed where it was. What the room
    /// then did was match a charge against 8, find an expiry there, and send
    /// nobody the repel that had just gone off in front of them.
    ///
    /// So this reads the header -- the actual source of truth, not a copy of
    /// it -- and numbers the enum the way a C compiler would.
    #[test]
    fn the_event_numbers_are_the_ones_the_core_emits() {
        let header = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../sim/include/sim/sim.h"
        ))
        .expect("the core header sits beside the server");
        let body = header
            .split_once("typedef enum {\n    SIM_EV_FIRE")
            .expect("sim_event_type starts at SIM_EV_FIRE")
            .1;
        let body = body.split_once("} sim_event_type;").expect("and ends").0;

        let mut next = 0i64;
        let mut found = std::collections::HashMap::new();
        for name in std::iter::once("SIM_EV_FIRE = 1").chain(
            body.lines()
                .map(|l| l.split("/*").next().unwrap_or("").trim())
                .filter(|l| l.starts_with("SIM_EV_")),
        ) {
            let (name, value) = match name.split_once('=') {
                Some((n, v)) => (n.trim(), v.trim_end_matches(',').trim().parse().unwrap()),
                None => (name.trim_end_matches(',').trim(), next),
            };
            next = value + 1;
            found.insert(name.to_string(), value);
        }

        for (name, mirrored) in [
            ("SIM_EV_FIRE", EV_FIRE),
            ("SIM_EV_BOUNCE", EV_BOUNCE),
            ("SIM_EV_HIT", EV_HIT),
            ("SIM_EV_DEATH", EV_DEATH),
            ("SIM_EV_SPAWN", EV_SPAWN),
            ("SIM_EV_EXPIRE", EV_EXPIRE),
            ("SIM_EV_CHARGE", EV_CHARGE),
            ("SIM_EV_FLAG_TAKE", EV_FLAG_TAKE),
            ("SIM_EV_FLAG_DROP", EV_FLAG_DROP),
            ("SIM_EV_GOAL", EV_GOAL),
            ("SIM_EV_WARP", EV_WARP),
            ("SIM_EV_RICOCHET", EV_RICOCHET),
        ] {
            assert_eq!(
                found.get(name).copied(),
                Some(mirrored as i64),
                "{name} is not where the mirror says it is"
            );
        }
        assert_eq!(
            found.len(),
            12,
            "the core has an event the mirror has never heard of"
        );
    }

    /// Size is not enough, and this is the test that proves why. `max_ships`
    /// was added to the end of `sim_settings` and landed inside padding the
    /// struct already had, so `sizeof` did not move by a byte. A mirror missing
    /// the field entirely, or carrying it in the wrong place, would pass the
    /// test above and then read a neighbour's bytes as a room size.
    ///
    /// Two blocks of this struct were genuinely in the wrong order when this
    /// was written, for the same reason: swapping equal-width neighbours is
    /// invisible to `sizeof`.
    #[test]
    fn the_room_size_is_where_c_keeps_it() {
        unsafe {
            assert_eq!(
                std::mem::offset_of!(sim_settings, max_ships),
                sim_offsetof_settings_max_ships() as usize,
                "max_ships is at a different offset than the core keeps it"
            );
        }
    }

    /// The zone's number wins, clamped to the array bound, and zero reads as
    /// the ceiling rather than as a room nobody can enter.
    #[test]
    fn a_zone_sets_its_own_room_size() {
        let mut w = World::new(0x5eed);
        assert_eq!(
            unsafe { sim_eff_max_ships(&*w.cfg) },
            64,
            "the baseline ships a 64-pilot room"
        );
        w.cfg.max_ships = 200;
        assert_eq!(unsafe { sim_eff_max_ships(&*w.cfg) }, 200);
        w.cfg.max_ships = 0;
        assert_eq!(
            unsafe { sim_eff_max_ships(&*w.cfg) },
            MAX_SHIPS as u8,
            "unset means the ceiling"
        );
    }
}
