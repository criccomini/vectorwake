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
pub const MAX_CLASSES: usize = 8;
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

pub const EV_FIRE: u8 = 1;
pub const EV_BOUNCE: u8 = 2;
pub const EV_HIT: u8 = 3;
pub const EV_DEATH: u8 = 4;
pub const EV_SPAWN: u8 = 5;
pub const EV_FLAG_TAKE: u8 = 7;
pub const EV_FLAG_DROP: u8 = 8;

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

/// Mirrors `sim_map`. A tile is its behaviour -- see the enum in sim.h -- and
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
    pub trigger: i32,
    pub expire_ends: u8,
    pub splinter: u8,
    pub damage: i32,
    pub blast: i32,
    pub push: i32,
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
    pub delay: u16,
    pub recoil: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
#[allow(dead_code)]
pub struct sim_ship_class {
    pub max_speed: i32, pub init_speed: i32, pub up_speed: i32,
    pub thrust: i32, pub init_thrust: i32, pub up_thrust: i32,
    pub rot: i32, pub init_rot: i32, pub up_rot: i32,
    pub max_energy: i32, pub init_energy: i32, pub up_energy: i32,
    pub recharge: i32, pub init_recharge: i32, pub up_recharge: i32,
    pub radius: i32,
    /// A ladder of patterns per trigger, climbed by the pilot's level, with
    /// 255 ending it. The ladder's length is the hull's ceiling for that
    /// weapon; a hull with no bomb rack has 255 at rung zero.
    pub trigger: [[u8; MAX_RUNGS]; TRIG_COUNT],
    /// Which add-ons this hull may ever hold on each trigger, packed two bits
    /// each exactly as the pilot's are. This is what keeps the roster a
    /// roster once greens are flying.
    pub mod_max: [u16; TRIG_COUNT],
    /// How many of each charge kind this hull may carry.
    pub charge_max: [u8; MAX_CHARGES],
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
    /// Odds a green turns out to be each thing, over the flat prize space.
    pub prize_weight: [u16; PRIZE_COUNT],
    /// What a kill adds to the killer's own bounty.
    pub bounty_per_kill: u16,
    /// Points on top of the victim's bounty per flag they were carrying.
    pub points_per_flag: u16,
    /// Out of a thousand, how often a green corrodes instead of granting.
    pub rust_chance: u16,
    /// Greens a ship is handed the moment it spawns.
    pub spawn_prizes: u16,
    /// What one rung of each add-on is worth, in the units of the field it
    /// moves.
    pub mod_step: [i32; MOD_COUNT],
    pub mod_spread: u16,
    /// Percent a rung of multifire adds to the shot's energy and cooldown.
    pub mod_multi_energy: u16,
    pub mod_multi_delay: u16,
    /// What each rung of shrapnel breaks into.
    pub mod_splinter: [u8; MAX_RUNGS],
    pub bounce: i32,
    pub friction: i32,
    pub respawn_delay: u16,
    pub prize_delay: u16,
    pub prize_max: u16,
    pub prize_life: u16,
    pub door_period: u16,
    pub door_open: u16,
    pub wormhole_pull: i32,
    pub wormhole_range: i32,
    pub prize_radius: i32,
    pub prize_lo: i32,
    pub prize_hi: i32,
    pub flag_radius: i32,
    pub flag_drop_cooldown: u16,
    pub max_ships: u8,
    pub map: *const sim_map,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_ship {
    pub active: u8,
    pub alive: u8,
    pub cls: u8,
    pub team: u8,
    pub x: i32,
    pub y: i32,
    pub vx: i32,
    pub vy: i32,
    pub heading: u16,
    pub energy: i32,
    pub fire_cooldown: u16,
    /// Ticks of suppressed recharge: what a stall round leaves behind.
    pub stall: u16,
    pub respawn_at: u16,
    pub spawn_x: i32,
    pub spawn_y: i32,
    pub kills: u16,
    pub deaths: u16,
    pub up: [u8; UP_COUNT],
    /// The rung each trigger is on, and the add-ons held on each.
    pub level: [u8; TRIG_COUNT],
    pub mods: [u16; TRIG_COUNT],
    /// Charges in hand, spent one at a time.
    pub charge: [u8; MAX_CHARGES],
    /// Bounty earned by killing, as opposed to bounty carried.
    pub earned: u16,
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
pub struct sim_prize {
    pub active: u8,
    pub x: i32,
    pub y: i32,
    pub life: u16,
}

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
    pub x: i32,
    pub y: i32,
    pub vx: i32,
    pub vy: i32,
    pub life: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct sim_state {
    pub tick: u32,
    pub rng: u32,
    pub ship_count: u8,
    pub weapon_count: u16,
    pub prize_timer: u16,
    pub ships: [sim_ship; MAX_SHIPS],
    pub weapons: [sim_weapon; MAX_WEAPONS],
    pub prizes: [sim_prize; MAX_PRIZES],
    pub flags: [sim_flag; MAX_FLAGS],
    pub flag_count: u8,
}

/// Must match `SIM_MAX_PRIZES`. The C core writes `sim_state` through this
/// mirror, so a smaller number here is not a smaller array -- it is a buffer
/// overrun into whatever the allocator put next, which is exactly how raising
/// it from 64 announced itself: a glibc malloc assertion, in every test.
pub const MAX_PRIZES: usize = 255;

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
    pub fn sim_set_ship_class(s: *mut sim_state, cfg: *const sim_settings, i: u8,
                              cls: u8) -> c_int;
    pub fn sim_hash(s: *const sim_state) -> u64;
    /// What a pilot is worth to whoever kills them: a sum over what they hold
    /// plus what killing has earned. Derived, never stored.
    pub fn sim_bounty(sh: *const sim_ship) -> i32;
    pub fn sim_pack_around(s: *const sim_state, out: *mut u8, cap: c_int,
                           cx: i32, cy: i32, radius: i32) -> c_int;
    pub fn sim_sizeof_state() -> u32;
    pub fn sim_offsetof_settings_max_ships() -> u32;
    pub fn sim_eff_max_ships(cfg: *const sim_settings) -> u8;
    pub fn sim_sizeof_settings() -> u32;
    pub fn sim_sizeof_ship() -> u32;
    pub fn sim_settings_baseline(cfg: *mut sim_settings, map: *const sim_map);
    /// The arenas live in the core so this and the client cannot disagree
    /// about the shape of the same room.
    pub fn sim_in_safe(map: *const sim_map, x: i32, y: i32) -> i32;
    pub fn sim_map_pack(map: *const sim_map, out: *mut u8, cap: i32) -> i32;
    pub fn sim_map_unpack(map: *mut sim_map, inp: *const u8, len: i32) -> i32;
    pub fn sim_map_spawn(map: *const sim_map, team: u8, nth: u32,
                         tx: *mut u16, ty: *mut u16) -> i32;
    pub fn sim_map_arena(map: *mut sim_map);
    pub fn sim_map_pit(map: *mut sim_map);
    pub fn sim_eff_max_energy(c: *const sim_ship_class, s: *const sim_ship) -> i32;
    pub fn sim_pack(s: *const sim_state, out: *mut u8, cap: c_int) -> c_int;
    pub fn sim_settings_pack(cfg: *const sim_settings, out: *mut u8, cap: c_int) -> c_int;
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
pub const SETTINGS_PACK_MAX: usize = 8192;
pub const UP_COUNT: usize = 5;
pub const TRIG_COUNT: usize = 2;
pub const MOD_COUNT: usize = 6;
pub const MAX_RUNGS: usize = 4;
pub const MOD_MAX: u8 = 3;
pub const MAX_CHARGES: usize = 4;
pub const PRIZE_COUNT: usize =
    UP_COUNT + TRIG_COUNT + TRIG_COUNT * MOD_COUNT + MAX_CHARGES;
pub const MOD_PROX: usize = 2;
pub const MOD_PUSH: usize = 5;

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

// Safety: the only raw pointer in the graph is `sim_settings.map`, which
// points at the map this World owns and which the core only ever reads.
unsafe impl Send for World {}

pub struct World {
    pub map: Box<sim_map>,
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
fn zeroed_box<T>() -> Box<T> {
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

    /// Build from a packed map file. Errors carry the reason rather than a
    /// number, because the only person who sees one is an operator holding a
    /// file they believed was a map.
    pub fn from_packed(seed: u32, bytes: &[u8]) -> Result<Self, String> {
        let mut w = Self::with_map(seed, |_| {});
        let r = unsafe {
            sim_map_unpack(&mut *w.map as *mut sim_map, bytes.as_ptr(), bytes.len() as i32)
        };
        match r {
            0 => Ok(w),
            -2 => Err("the tiles do not match the hash in its header".into()),
            _ => Err("not a map file, or truncated".into()),
        }
    }

    /// A blank weapon, appended to both tables, and the pattern index that
    /// reaches it. The skeleton is a projectile that does nothing for a
    /// second and stops at walls, because a zeroed row would splinter into
    /// pattern zero -- a real weapon, and never the one anybody meant.
    pub fn add_weapon(&mut self) -> Option<u8> {
        let spec = sim_weapon_spec { life: 100, splinter: NO_PATTERN, ..Default::default() };
        let s = unsafe { sim_add_spec(&mut *self.cfg, &spec) };
        if s < 0 { return None }
        let pattern = sim_fire_pattern { spec: s as u8, count: 1, delay: 25, ..Default::default() };
        let p = unsafe { sim_add_pattern(&mut *self.cfg, &pattern) };
        if p < 0 { None } else { Some(p as u8) }
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
            sim_settings_pack(&*self.cfg as *const sim_settings,
                              buf.as_mut_ptr(), buf.len() as i32)
        };
        buf.truncate(if n > 0 { n as usize } else { 0 });
        buf
    }

    /// The map, packed, ready to hand a joining client.
    pub fn packed_map(&self) -> Vec<u8> {
        let mut buf = vec![0u8; MAP_PACK_MAX];
        let n = unsafe {
            sim_map_pack(&*self.map as *const sim_map, buf.as_mut_ptr(), buf.len() as i32)
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
        let ok = unsafe {
            sim_map_spawn(&*self.map as *const sim_map, team, nth, &mut tx, &mut ty)
        };
        if ok != 0 { Some((tx as i32, ty as i32)) } else { None }
    }

    /// Spawn at the map's own start when it names one, and at the position
    /// the caller had in mind when it does not. A map that carries its starts
    /// can be dropped into any zone; one that does not leaves the zone's
    /// configuration in charge, which is how every map worked before.
    pub fn spawn_on_map(&mut self, cls: u8, team: u8, nth: u32,
                        tile_x: i32, tile_y: i32, heading: u16) -> i32 {
        let (x, y) = self.map_spawn(team, nth).unwrap_or((tile_x, tile_y));
        self.spawn(cls, team, x, y, heading)
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

    /// Put a pilot in a different hull, keeping their team and their seat.
    /// The core refuses unless they are alive and at a full bar, so this is
    /// the whole of the rule and both sides get it from the same place.
    pub fn set_ship_class(&mut self, i: u8, cls: u8) -> bool {
        unsafe { sim_set_ship_class(&mut *self.state, &*self.cfg, i, cls.min(7)) == 0 }
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

    /// A snapshot carrying only the prizes within `radius` of a point. See
    /// the note on `sim_pack_around` in sim/include/sim/pack.h.
    pub fn pack_around(&self, out: &mut [u8], cx: i32, cy: i32, radius: i32) -> i32 {
        unsafe {
            sim_pack_around(&*self.state, out.as_mut_ptr(), out.len() as c_int,
                            cx, cy, radius)
        }
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
            assert_eq!(std::mem::size_of::<sim_state>(), sim_sizeof_state() as usize,
                       "sim_state mirror is the wrong size");
            assert_eq!(std::mem::size_of::<sim_settings>(), sim_sizeof_settings() as usize,
                       "sim_settings mirror is the wrong size");
            assert_eq!(std::mem::size_of::<sim_ship>(), sim_sizeof_ship() as usize,
                       "sim_ship mirror is the wrong size");
        }
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
        assert_eq!(unsafe { sim_eff_max_ships(&*w.cfg) }, 64,
                   "the baseline ships a 64-pilot room");
        w.cfg.max_ships = 200;
        assert_eq!(unsafe { sim_eff_max_ships(&*w.cfg) }, 200);
        w.cfg.max_ships = 0;
        assert_eq!(unsafe { sim_eff_max_ships(&*w.cfg) }, MAX_SHIPS as u8,
                   "unset means the ceiling");
    }
}
