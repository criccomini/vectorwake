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
