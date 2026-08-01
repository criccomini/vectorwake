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

/// Duel arenas are small and closed: a room a fight cannot leave. The room
/// itself is the core's, so this and the client cannot disagree about it.
pub fn build_duel_map(map: &mut sim::sim_map) {
    sim::build_duel(map)
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

/// Warzone: a team wins the round by holding every flag at once.
///
/// The simulation moves flags; this decides what an arrangement of them
/// means, which is the split the original drew between flagcore and fg_wz.
pub struct Warzone {
    pub flags: u8,
    pub round: u16,
    pub wins: [u16; 4],
    hold: Option<(u8, u32)>,   // team and the tick they completed the set
    hold_ticks: u32,
    reset_at: Option<u32>,
    clock: u32,
}

impl Warzone {
    pub fn new(flags: u8) -> Self {
        Warzone {
            flags,
            round: 1,
            wins: [0; 4],
            hold: None,
            hold_ticks: 200, // two seconds holding the full set to win
            reset_at: None,
            clock: 0,
        }
    }
}

impl Mode for Warzone {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        self.clock += 1;

        if let Some(at) = self.reset_at {
            let left = at.saturating_sub(self.clock);
            if left == 0 {
                // New round: every flag neutral and back where it started.
                for i in 0..ctx.world.state.flag_count as usize {
                    let f = &mut ctx.world.state.flags[i];
                    f.team = sim::TEAM_NONE;
                    f.carried = 0;
                    f.cooldown = 0;
                }
                self.reset_at = None;
                self.hold = None;
                self.round += 1;
            }
            return;
        }

        // Who, if anybody, holds the whole set.
        let mut leader = None;
        for team in 0..4u8 {
            if ctx.world.flags_held(team) as u8 == self.flags && self.flags > 0 {
                leader = Some(team);
                break;
            }
        }

        match (leader, self.hold) {
            (Some(t), Some((held, since))) if held == t => {
                let left = self.hold_ticks.saturating_sub(self.clock - since);
                if left == 0 {
                    self.wins[t as usize % 4] += 1;
                    self.reset_at = Some(self.clock + 500);
                    ctx.banner = format!("team {t} wins round {}", self.round);
                } else {
                    ctx.banner = format!("team {t} holds all {} flags: {}", self.flags, left / 100 + 1);
                }
            }
            (Some(t), _) => {
                self.hold = Some((t, self.clock));
                ctx.banner = format!("team {t} holds all {} flags", self.flags);
            }
            (None, _) => {
                self.hold = None;
                let a = ctx.world.flags_held(0);
                let b = ctx.world.flags_held(1);
                let loose = self.flags as i32 - a - b;
                ctx.banner = format!("flags  {a} - {b}   {loose} loose");
            }
        }
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    fn name(&self) -> &'static str {
        "warzone"
    }
}

#[cfg(test)]
mod warzone_tests {
    use super::*;

    fn arena_with_flags(n: usize) -> World {
        let mut w = World::new(3);
        let spots = [(486, 486), (538, 486), (538, 538), (486, 538), (512, 512)];
        for i in 0..n {
            w.add_flag(spots[i].0, spots[i].1);
        }
        w
    }

    fn ctx(world: &mut World) -> ModeCtx<'_> {
        ModeCtx { world, seats: &[], banner: String::new(), finished: false }
    }

    #[test]
    fn holding_every_flag_wins_a_round() {
        let mut w = arena_with_flags(3);
        let mut m = Warzone::new(3);
        for i in 0..3 {
            w.state.flags[i].team = 1;
        }
        // The set has to be held, not merely touched.
        m.tick(&mut ctx(&mut w));
        assert_eq!(m.wins[1], 0, "the set must be held, not just completed");
        for _ in 0..250 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins[1], 1, "holding the set for the timer wins");
    }

    #[test]
    fn losing_one_flag_stops_the_clock() {
        let mut w = arena_with_flags(3);
        let mut m = Warzone::new(3);
        for i in 0..3 {
            w.state.flags[i].team = 0;
        }
        for _ in 0..100 {
            m.tick(&mut ctx(&mut w));
        }
        w.state.flags[2].team = 1;           // stolen back
        for _ in 0..250 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins[0], 0, "the countdown restarts when the set breaks");
    }

    #[test]
    fn a_round_resets_the_flags() {
        let mut w = arena_with_flags(2);
        let mut m = Warzone::new(2);
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        for _ in 0..900 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.round, 2, "a new round starts");
        assert_eq!(w.state.flags[0].team, sim::TEAM_NONE, "flags go neutral again");
    }
}
