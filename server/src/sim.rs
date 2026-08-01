//! Bindings to the C simulation core.
//!
//! The server does not reimplement a single game rule: it owns the authoritative
//! `sim_state` and calls `sim_step`, exactly as the client does for prediction.
//! One source, two callers, identical results.

#![allow(non_camel_case_types)]

use std::os::raw::c_int;

pub const MAX_SHIPS: usize = 64;
pub const MAX_WEAPONS: usize = 1024;
pub const MAX_EVENTS: usize = 256;
pub const MAX_CLASSES: usize = 8;
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

#[repr(C)]
pub struct sim_map {
    pub solid: [u8; MAP_TILES * MAP_TILES],
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
    pub bullet_speed: i32,
    pub bullet_energy: i32,
    pub bullet_delay: u16,
    pub bullet_life: u16,
    pub bullet_damage: i32,
    pub bomb_speed: i32,
    pub bomb_energy: i32,
    pub bomb_delay: u16,
    pub bomb_life: u16,
    pub bomb_damage: i32,
    pub bomb_radius: i32,
    pub bomb_thrust: i32,
}

#[repr(C)]
pub struct sim_settings {
    pub classes: [sim_ship_class; MAX_CLASSES],
    pub class_count: u8,
    pub bounce: i32,
    pub friction: i32,
    pub respawn_delay: u16,
    pub prize_delay: u16,
    pub prize_max: u16,
    pub prize_life: u16,
    pub prize_radius: i32,
    pub prize_lo: i32,
    pub prize_hi: i32,
    pub flag_radius: i32,
    pub flag_drop_cooldown: u16,
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
    pub respawn_at: u16,
    pub spawn_x: i32,
    pub spawn_y: i32,
    pub kills: u16,
    pub deaths: u16,
    pub up: [u8; UP_COUNT],
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

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_prize {
    pub active: u8,
    pub ptype: u8,
    pub x: i32,
    pub y: i32,
    pub life: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sim_weapon {
    pub wtype: u8,
    pub owner: u8,
    pub team: u8,
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

pub const MAX_PRIZES: usize = 64;

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
    pub fn sim_hash(s: *const sim_state) -> u64;
    pub fn sim_settings_baseline(cfg: *mut sim_settings, map: *const sim_map);
    pub fn sim_eff_max_energy(c: *const sim_ship_class, s: *const sim_ship) -> i32;
    pub fn sim_pack(s: *const sim_state, out: *mut u8, cap: c_int) -> c_int;
    pub fn sim_add_flag(s: *mut sim_state, x_px: i32, y_px: i32) -> c_int;
    pub fn sim_flags_held(s: *const sim_state, team: u8) -> c_int;
    pub fn sim_units_speed(v: i32) -> i32;
    pub fn sim_units_thrust(v: i32) -> i32;
    pub fn sim_units_rotation(v: i32) -> i32;
    pub fn sim_units_energy(v: i32) -> i32;
    pub fn sim_units_recharge(v: i32) -> i32;
}

pub const PACK_MAX: usize = 64 * 1024;
pub const UP_COUNT: usize = 5;

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
    const LO: usize = 470;
    const HI: usize = 554;
    let mut fill = |x0: usize, y0: usize, x1: usize, y1: usize| {
        for ty in y0..=y1 {
            for tx in x0..=x1 {
                map.solid[ty * MAP_TILES + tx] = 1;
            }
        }
    };
    fill(LO, LO, HI, LO + 1);
    fill(LO, HI - 1, HI, HI);
    fill(LO, LO, LO + 1, HI);
    fill(HI - 1, LO, HI, HI);
    fill(489, 489, 495, 495);
    fill(529, 489, 535, 495);
    fill(489, 529, 495, 535);
    fill(529, 529, 535, 535);
    fill(505, 480, 519, 483);
    fill(505, 541, 519, 544);
    fill(480, 505, 483, 519);
    fill(541, 505, 544, 519);
}

