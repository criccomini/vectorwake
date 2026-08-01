//! Game modes.
//!
//! A mode owns rules the simulation does not: when a round starts, what ends
//! it, where ships respawn, and what the scoreboard says. It sees the events
//! a tick produced and may act on them, which is the adviser shape from
//! docs/architecture/server.md.
//!
//! These are compiled in rather than sandboxed WebAssembly. The trait is the
//! same surface a WASM host would expose, so moving them out later is a host
//! implementation rather than a redesign; see decision 6.

use crate::sim::{self, World};

pub struct ModeCtx<'a> {
    pub world: &'a mut World,
    /// Ships in this arena, and whether each is a bot.
    pub seats: &'a [(u8, bool)],
    /// Lines the client shows above the scoreboard.
    pub banner: String,
    /// Set when the mode is finished and the arena should be torn down.
    pub finished: bool,
}

pub trait Mode: Send {
    fn tick(&mut self, ctx: &mut ModeCtx);
    fn on_death(&mut self, ctx: &mut ModeCtx, victim: u8, killer: u8);
    fn name(&self) -> &'static str;
}

/// The default arena: everybody against everybody, forever.
pub struct FreeForAll;

impl Mode for FreeForAll {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        ctx.banner = String::new();
    }
    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}
    fn name(&self) -> &'static str {
        "arena"
    }
}

/// One on one, first to N kills, per docs/design/duel-mode.md.
///
/// Ten seconds of warmup with weapons disabled, a three second countdown,
/// then live. Eight minute cap. A pilot who leaves forfeits, which the arena
/// reports by dropping their seat.
pub struct Duel {
    pub a: u8,
    pub b: u8,
    pub target: u16,
    pub score: (u16, u16),
    phase: Phase,
    timer: u32,
    pub winner: Option<u8>,
}

#[derive(PartialEq)]
enum Phase {
    Warmup,
    Countdown,
    Live,
    Over,
}

const WARMUP_TICKS: u32 = 400;
const COUNTDOWN_TICKS: u32 = 300;
const TIME_LIMIT: u32 = 48_000; // 8 minutes

impl Duel {
    pub fn new(a: u8, b: u8, target: u16) -> Self {
        Duel {
            a,
            b,
            target,
            score: (0, 0),
            phase: Phase::Warmup,
            timer: 0,
            winner: None,
        }
    }

    fn freeze_weapons(&self, ctx: &mut ModeCtx, frozen: bool) {
        // Warmup disarms by draining the fire cooldown forward, which costs
        // no new simulation state: a ship that cannot fire is a ship whose
        // cooldown never reaches zero.
        for id in [self.a, self.b] {
            let sh = &mut ctx.world.state.ships[id as usize];
            if frozen {
                sh.fire_cooldown = 60;
            }
        }
    }
}

impl Mode for Duel {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        self.timer += 1;
        match self.phase {
            Phase::Warmup => {
                self.freeze_weapons(ctx, true);
                let left = (WARMUP_TICKS.saturating_sub(self.timer)) / 100 + 1;
                ctx.banner = format!("warmup {left}");
                if self.timer >= WARMUP_TICKS {
                    self.phase = Phase::Countdown;
                    self.timer = 0;
                }
            }
            Phase::Countdown => {
                self.freeze_weapons(ctx, true);
                let left = (COUNTDOWN_TICKS.saturating_sub(self.timer)) / 100 + 1;
                ctx.banner = format!("{left}");
                if self.timer >= COUNTDOWN_TICKS {
                    self.phase = Phase::Live;
                    self.timer = 0;
                    ctx.banner = "fight".into();
                }
            }
            Phase::Live => {
                ctx.banner = format!("{} - {}   first to {}", self.score.0, self.score.1, self.target);
                if self.timer >= TIME_LIMIT {
                    // Time out: the higher score wins, equal scores draw.
                    self.winner = match self.score.0.cmp(&self.score.1) {
                        std::cmp::Ordering::Greater => Some(self.a),
                        std::cmp::Ordering::Less => Some(self.b),
                        std::cmp::Ordering::Equal => None,
                    };
                    self.phase = Phase::Over;
                    self.timer = 0;
                }
            }
            Phase::Over => {
                let who = match self.winner {
                    Some(w) if w == self.a => "left",
                    Some(_) => "right",
                    None => "nobody",
                };
                ctx.banner = format!("{} - {}   {} wins", self.score.0, self.score.1, who);
                if self.timer > 500 {
                    ctx.finished = true;
                }
            }
        }
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, victim: u8, _killer: u8) {
        if self.phase != Phase::Live {
            return;
        }
        if victim == self.a {
            self.score.1 += 1;
        } else if victim == self.b {
            self.score.0 += 1;
        }
        if self.score.0 >= self.target {
            self.winner = Some(self.a);
            self.phase = Phase::Over;
            self.timer = 0;
        } else if self.score.1 >= self.target {
            self.winner = Some(self.b);
            self.phase = Phase::Over;
            self.timer = 0;
        }
    }

    fn name(&self) -> &'static str {
        "duel"
    }
}

/// Duel arenas are small and closed: a room a fight cannot leave.
pub fn build_duel_map(map: &mut sim::sim_map) {
    const LO: usize = 496;
    const HI: usize = 528;
    for ty in 0..sim::MAP_TILES {
        for tx in 0..sim::MAP_TILES {
            map.solid[ty * sim::MAP_TILES + tx] = 0;
        }
    }
    let mut fill = |x0: usize, y0: usize, x1: usize, y1: usize| {
        for ty in y0..=y1 {
            for tx in x0..=x1 {
                map.solid[ty * sim::MAP_TILES + tx] = 1;
            }
        }
    };
    fill(LO, LO, HI, LO + 1);
    fill(LO, HI - 1, HI, HI);
    fill(LO, LO, LO + 1, HI);
    fill(HI - 1, LO, HI, HI);
    // Two pillars, so the room rewards positioning rather than pure aim.
    fill(505, 505, 509, 509);
    fill(515, 515, 519, 519);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A duel harness that skips the clock forward rather than waiting.
    fn live_duel() -> (Duel, World) {
        let world = World::with_map(1, build_duel_map);
        let mut d = Duel::new(0, 1, 5);
        d.phase = Phase::Live;
        (d, world)
    }

    fn ctx(world: &mut World) -> ModeCtx<'_> {
        ModeCtx { world, seats: &[], banner: String::new(), finished: false }
    }

    #[test]
    fn kills_score_for_the_other_pilot() {
        let (mut d, mut w) = live_duel();
        d.on_death(&mut ctx(&mut w), 0, 1);   // ship 0 died
        assert_eq!(d.score, (0, 1), "the survivor scores");
        d.on_death(&mut ctx(&mut w), 1, 0);
        assert_eq!(d.score, (1, 1));
    }

    #[test]
    fn reaching_the_target_ends_it() {
        let (mut d, mut w) = live_duel();
        for _ in 0..5 {
            d.on_death(&mut ctx(&mut w), 1, 0);
        }
        assert_eq!(d.winner, Some(0), "first to five wins");
        // Further deaths after the match cannot move the score.
        d.on_death(&mut ctx(&mut w), 0, 1);
        assert_eq!(d.score, (5, 0), "the score is final once the match ends");
    }

    #[test]
    fn deaths_during_warmup_do_not_count() {
        let world = World::with_map(1, build_duel_map);
        let mut w = world;
        let mut d = Duel::new(0, 1, 5);
        d.on_death(&mut ctx(&mut w), 0, 1);
        assert_eq!(d.score, (0, 0), "warmup is not the match");
    }

    #[test]
    fn the_room_is_torn_down_after_the_result() {
        let (mut d, mut w) = live_duel();
        for _ in 0..5 {
            d.on_death(&mut ctx(&mut w), 1, 0);
        }
        let mut finished = false;
        for _ in 0..600 {
            let mut c = ctx(&mut w);
            d.tick(&mut c);
            if c.finished {
                finished = true;
                break;
            }
        }
        assert!(finished, "a finished duel asks to be cleaned up");
    }

    #[test]
    fn a_timeout_is_decided_on_score() {
        let (mut d, mut w) = live_duel();
        d.on_death(&mut ctx(&mut w), 1, 0);       // 1 - 0
        d.timer = TIME_LIMIT;
        d.tick(&mut ctx(&mut w));
        assert_eq!(d.winner, Some(0), "ahead on kills when time runs out");
    }

    #[test]
    fn a_level_timeout_is_a_draw() {
        let (mut d, mut w) = live_duel();
        d.timer = TIME_LIMIT;
        d.tick(&mut ctx(&mut w));
        assert_eq!(d.winner, None, "equal scores draw");
    }
}
