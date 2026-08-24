//! Game modes.
//!
//! A mode owns rules the simulation does not: when a round starts, what ends
//! it, where ships respawn, and what the scoreboard says. It sees the events
//! a tick produced and may act on them, which is the adviser shape from
//! docs/architecture/server.md.
//!
//! These are compiled in rather than sandboxed WebAssembly. `ModeCtx` passes
//! direct Rust state, strings, and slices, so it is an internal surface and not
//! a module ABI; see decision 6.

use crate::{
    pilots,
    sim::{self, World},
};

pub struct ModeCtx<'a> {
    pub world: &'a mut World,
    /// Active seats as `(ship, is_bot)`. Match modes use this snapshot to
    /// decide whether the required opponents are actually ready.
    pub seats: &'a [(u8, bool)],
    /// The zone's own sides, by name, in the order it scores them. A mode
    /// writes banners about the game, and a side is a name to everybody
    /// reading one: "Vantage holds all four flags" is news, "team 1 holds all
    /// four flags" is a log line. Private sides are not in here and cannot
    /// win, which is what stops a pair of friends founding their way to a
    /// round victory in a flag game.
    pub team_names: &'a [String],
    /// Lines the client shows above the scoreboard.
    pub banner: String,
    /// Set when the mode is finished and the arena should be torn down.
    pub finished: bool,
    /// Set when the mode wants a fresh match opened: everybody home, kits
    /// re-dealt with their ammunition. The mode says when, the room does it,
    /// because the map and the sockets are the room's.
    pub open_match: bool,
    /// And set on the whistle the other way, when a match has just ended and
    /// the podium is going up. The room clears the arena and moves to the next
    /// map on this, so the wait happens on the ground the next match is played
    /// on rather than on the one that just finished.
    pub close_match: bool,
    /// Stop an invalidated match without filing a result or paying completion
    /// rewards. Ladder uses this when its opponent disappears during a life.
    pub abort_match: bool,
}

/// What a match game is doing right now.
///
/// A mode that is not one has no answer, which is what `Mode::match_state`
/// returning `None` means: the room sends no clock, and the controls are
/// never held.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct MatchState {
    /// False during the intermission, when the podium is up and nobody is
    /// flying.
    pub playing: bool,
    /// Seconds left in whichever of the two this is. A match is three minutes
    /// and an intermission is fifteen, so a byte is plenty and
    /// the client only ever draws whole seconds of it.
    pub seconds_left: u8,
    /// Kills per public side, in the order the zone named them.
    pub score: Vec<u16>,
}

pub const DEFAULT_LADDER_FIRST_TO: u16 = 1;
pub const DEFAULT_LADDER_LOSS_DROP: u32 = 2;
pub const DEFAULT_LADDER_CHECKPOINT_INTERVAL: u32 = 5;

/// The rules that turn one completed Ladder series into run progress.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LadderRules {
    /// Points needed to take one opponent. Clamped to one when the mode starts.
    pub first_to: u16,
    /// Rungs lost after a defeat in the ordinary mode.
    pub loss_drop: u32,
    /// A checkpoint is unlocked at each multiple. Zero disables new checkpoints.
    pub checkpoint_interval: u32,
}

impl Default for LadderRules {
    fn default() -> Self {
        Self {
            first_to: DEFAULT_LADDER_FIRST_TO,
            loss_drop: DEFAULT_LADDER_LOSS_DROP,
            checkpoint_interval: DEFAULT_LADDER_CHECKPOINT_INTERVAL,
        }
    }
}

/// Pure Ladder progression. Rung zero is the base opponent, and the rung is
/// also the roster slot requested for the next series.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LadderProgression {
    rung: u32,
    streak: u32,
    checkpoint: u32,
    best: u32,
    rules: LadderRules,
}

impl LadderProgression {
    pub fn new(rules: LadderRules) -> Self {
        Self {
            rung: 0,
            streak: 0,
            checkpoint: 0,
            best: 0,
            rules,
        }
    }

    /// Restore persisted progress while keeping its floor internally valid.
    pub fn restore(rules: LadderRules, rung: u32, streak: u32, checkpoint: u32, best: u32) -> Self {
        let rung_count = pilots::PROVISIONAL_LADDER_RUNG_COUNT as u32;
        let last_rung = rung_count.saturating_sub(1);
        let rung = rung.min(last_rung);
        Self {
            rung,
            streak,
            checkpoint: checkpoint.min(rung),
            best: best.max(rung).min(rung_count),
            rules,
        }
    }

    pub fn rung(&self) -> u32 {
        self.rung
    }

    pub fn streak(&self) -> u32 {
        self.streak
    }

    pub fn checkpoint(&self) -> u32 {
        self.checkpoint
    }

    pub fn best(&self) -> u32 {
        self.best
    }

    /// Advance once, returning true when that win cleared the finite roster.
    /// A clear starts the next run at the durable floor instead of silently
    /// repeating the strongest band under a larger rung number.
    pub fn win(&mut self) -> bool {
        let rung_count = pilots::PROVISIONAL_LADDER_RUNG_COUNT as u32;
        let next = self.rung.saturating_add(1);
        self.best = self.best.max(next).min(rung_count);
        if next >= rung_count {
            self.rung = self.checkpoint.min(rung_count.saturating_sub(1));
            self.streak = 0;
            return true;
        }

        self.rung = next;
        self.streak = self.streak.saturating_add(1);
        let interval = self.rules.checkpoint_interval;
        if interval != 0 && self.rung.is_multiple_of(interval) {
            self.checkpoint = self.rung;
        }
        false
    }

    pub fn loss(&mut self) {
        self.streak = 0;
        self.rung = self
            .rung
            .saturating_sub(self.rules.loss_drop)
            .max(self.checkpoint);
    }
}

/// A structured Ladder snapshot for the room, bot assignment, and future
/// client message. Scores are always `[human, bot]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LadderState {
    pub playing: bool,
    /// The room is holding for the requested rival rather than counting down.
    pub waiting: bool,
    pub rung: u32,
    pub streak: u32,
    pub checkpoint: u32,
    pub best: u32,
    pub score: [u16; 2],
    pub first_to: u16,
    /// The roster slot locked for the series currently on the field.
    pub active_opponent_slot: u32,
    /// The slot wanted next. It changes only after the current series ends.
    pub desired_opponent_slot: u32,
    /// Whether the mode currently sees exactly one person and one bot.
    pub opponent_ready: bool,
    /// The result on the podium completed the finite provisional roster.
    pub cleared: bool,
}

impl ModeCtx<'_> {
    /// What to call a side in a sentence. A zone that named none, or a side
    /// above the ones it named, still has to read as something.
    pub fn team_name(&self, team: u8) -> String {
        self.team_names
            .get(team as usize)
            .cloned()
            .unwrap_or_else(|| format!("team {team}"))
    }
}

/// Every mode a zone may name. The catalog checks against this rather than
/// falling back to warzone, which is exactly how `arena.mode` came to be a key
/// that parsed and did nothing for months.
pub const NAMES: [&str; 5] = ["arena", "warzone", "duel", "melee", "ladder"];

pub fn exists(name: &str) -> bool {
    NAMES.contains(&name)
}

/// Everything a mode is built from, which is all of it a zone's own. A
/// two-team warzone with three flags, or a four-a-side melee on a two minute
/// clock, is configuration rather than a rebuild.
pub struct Setup {
    pub flags: u8,
    pub teams: u8,
    /// Ticks a match runs, and ticks of podium between two of them. Only a
    /// match game reads these.
    pub match_ticks: u32,
    pub intermission_ticks: u32,
    pub ladder: LadderRules,
}

/// Build the mode a zone asked for.
pub fn build(name: &str, s: &Setup) -> Box<dyn Mode> {
    let (flags, teams) = (s.flags.max(1), s.teams.max(1));
    match name {
        "warzone" => Box::new(Warzone::new(flags, teams)),
        "melee" => Box::new(Melee::new(
            teams,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
        )),
        "ladder" => Box::new(Ladder::new(
            s.ladder,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
        )),
        // Duel is deferred; see docs/design/duel-mode.md. Naming it in a zone
        // gets a free-for-all rather than a refusal, because the catalog has
        // already accepted the name and a running room beats a dead one.
        _ => Box::new(FreeForAll),
    }
}

pub trait Mode: Send {
    fn tick(&mut self, ctx: &mut ModeCtx);
    fn on_death(&mut self, ctx: &mut ModeCtx, victim: u8, killer: u8);
    /// Every death emitted by one simulation tick. Most modes can consume
    /// them in order. A mode where one life is the whole result overrides
    /// this so simultaneous deaths cannot be decided by event ordering.
    fn on_deaths(&mut self, ctx: &mut ModeCtx, deaths: &[(u8, u8)]) {
        for &(victim, killer) in deaths {
            self.on_death(ctx, victim, killer);
        }
    }
    /// A seat left while the room still holds its mutex. Match modes that
    /// cannot fairly replace a life may invalidate it before a new seat can
    /// arrive.
    fn on_departure(&mut self, _ctx: &mut ModeCtx, _ship: u8, _bot: bool) {}
    /// What the zone file calls this mode. Read by the tests that build one
    /// from a name, which is the only caller that has to check it came back
    /// with what it asked for.
    #[cfg(test)]
    fn name(&self) -> &'static str;
    /// The clock and the score, for a mode that has them. The room sends this
    /// to its clients and holds their controls while it says nobody is
    /// flying; a mode that answers `None` is a room that runs forever and
    /// draws no clock.
    fn match_state(&self) -> Option<MatchState> {
        None
    }
    /// Structured Ladder state. Other modes return none, so callers can ask
    /// through the common trait without downcasting a mode object.
    fn ladder_state(&self) -> Option<LadderState> {
        None
    }
    /// Restore the durable part of a Ladder run. Returns false for modes that
    /// do not own Ladder progression.
    fn restore_ladder(&mut self, _checkpoint: u32, _best: u32) -> bool {
        false
    }
    /// A room went from bots only to holding a person. Match modes reset their
    /// opening edge so that person's clock starts at the full length instead
    /// of wherever the bot-only attract fight happened to be.
    fn first_human(&mut self) {}
}

/// The default arena: everybody against everybody, forever.
pub struct FreeForAll;

impl Mode for FreeForAll {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        ctx.banner = String::new();
    }
    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}
    #[cfg(test)]
    fn name(&self) -> &'static str {
        "arena"
    }
}

/// Melee: four a side, three minutes, kills.
///
/// The room outlives the match. This owns the clock that says which of the
/// two things the room is doing, and the score, which is read off the ships
/// rather than kept a second time: `sim_restart` zeroes every tally at the
/// whistle, so the kills on the field *are* the match.
///
/// Frozen at the whistle, though, because the intermission still ticks and a
/// score that kept climbing under the podium would be a lie about the match
/// just played. Nobody is flying then either -- see `match_state` -- so in
/// practice it only ever moves by a bomb already in the air, which is exactly
/// the case worth being right about.
pub struct Melee {
    teams: u8,
    match_ticks: u32,
    intermission_ticks: u32,
    /// Ticks left in whichever phase this is.
    left: u32,
    playing: bool,
    /// The score, live while playing and held through the intermission.
    score: Vec<u16>,
    /// The first tick has not run yet, so the room has not opened a match.
    /// Set once, which is what makes a room that has just been built start
    /// playing rather than sit through an intermission it did not earn.
    opened: bool,
}

impl Melee {
    pub fn new(teams: u8, match_ticks: u32, intermission_ticks: u32) -> Self {
        Melee {
            teams,
            match_ticks,
            intermission_ticks,
            left: match_ticks,
            playing: true,
            score: vec![0; teams as usize],
            opened: false,
        }
    }

    /// Kills by side, over everybody on the field.
    ///
    /// Summed signed and reported unsigned. A pilot's own count goes under
    /// zero when they keep killing themselves or their wingmen, and the side
    /// carries that: a teamkill is a point the other side does not have to
    /// take. What a side cannot do is go below nothing, because the score is a
    /// pair of numbers on a wire and a bar drawn as a share of their sum, and
    /// neither has an answer for a negative. It takes four misfires against
    /// nothing at all to reach the floor, so the clamp is a guard rather than
    /// a rule anybody will play against.
    fn tally(&self, ctx: &ModeCtx) -> Vec<u16> {
        let mut score = vec![0i32; self.teams as usize];
        for sh in ctx.world.state.ships.iter() {
            if sh.active == 0 {
                continue;
            }
            if let Some(n) = score.get_mut(sh.team as usize) {
                *n += sh.kills as i32;
            }
        }
        score
            .into_iter()
            .map(|n| n.clamp(0, u16::MAX as i32) as u16)
            .collect()
    }

    /// Who took it, and by how much. `None` for a draw, which at four a side
    /// over three minutes happens often enough to be worth a sentence of its
    /// own rather than an arbitrary tiebreak.
    fn winner(&self) -> Option<u8> {
        let best = *self.score.iter().max()?;
        let mut who = None;
        for (t, n) in self.score.iter().enumerate() {
            if *n == best {
                if who.is_some() {
                    return None;
                }
                who = Some(t as u8);
            }
        }
        who
    }
}

impl Mode for Melee {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        // A room that has just opened plays rather than waiting out a phase
        // it was built in the middle of.
        if !self.opened {
            self.opened = true;
            ctx.open_match = true;
            self.left = self.match_ticks;
            self.playing = true;
            self.score = vec![0; self.teams as usize];
        } else if self.playing {
            self.score = self.tally(ctx);
        }

        self.left = self.left.saturating_sub(1);
        if self.left == 0 {
            self.playing = !self.playing;
            if self.playing {
                self.left = self.match_ticks;
                self.score = vec![0; self.teams as usize];
                ctx.open_match = true;
            } else {
                self.left = self.intermission_ticks.max(1);
                ctx.close_match = true;
            }
        }

        ctx.banner = if self.playing {
            String::new()
        } else {
            match self.winner() {
                Some(t) => format!(
                    "{} takes it, {}",
                    ctx.team_name(t),
                    self.score
                        .iter()
                        .map(|n| n.to_string())
                        .collect::<Vec<_>>()
                        .join(" to ")
                ),
                None => "a draw".to_string(),
            }
        };
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "melee"
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.playing,
            // Rounded up, so a clock reads 1 for the last second rather than
            // sitting on 0 while there is still a second to play in.
            seconds_left: self.left.div_ceil(100).min(255) as u8,
            score: self.score.clone(),
        })
    }

    fn first_human(&mut self) {
        if !self.playing {
            return;
        }
        self.opened = false;
        self.left = self.match_ticks;
        self.playing = true;
        self.score = vec![0; self.teams as usize];
    }
}

/// Ladder: one person against one house pilot, first to a configured score.
///
/// A series is the indivisible difficulty step. The active opponent slot is
/// copied from the run when the series opens and cannot move while it is being
/// played. A result changes only the desired slot, giving the room's future bot
/// assignment path the whole intermission to seat the next opponent.
pub struct Ladder {
    rules: LadderRules,
    run: LadderProgression,
    match_ticks: u32,
    intermission_ticks: u32,
    left: u32,
    playing: bool,
    opened: bool,
    score: [u16; 2],
    active_opponent_slot: u32,
    result: Option<bool>,
    cleared: bool,
    interrupted: bool,
    opponent_ready: bool,
    /// A changed slot is not accepted until the old seat has gone away once.
    replacement_vacated: bool,
}

impl Ladder {
    pub fn new(mut rules: LadderRules, match_ticks: u32, intermission_ticks: u32) -> Self {
        rules.first_to = rules.first_to.max(1);
        Self {
            rules,
            run: LadderProgression::new(rules),
            match_ticks: match_ticks.max(1),
            intermission_ticks: intermission_ticks.max(1),
            left: match_ticks.max(1),
            playing: false,
            opened: false,
            score: [0, 0],
            active_opponent_slot: 0,
            result: None,
            cleared: false,
            interrupted: false,
            opponent_ready: false,
            replacement_vacated: false,
        }
    }

    fn begin_series(&mut self) {
        self.playing = true;
        self.left = self.match_ticks;
        self.score = [0, 0];
        self.active_opponent_slot = self.run.rung();
        self.result = None;
        self.cleared = false;
        self.interrupted = false;
        self.opponent_ready = true;
        self.replacement_vacated = false;
    }

    fn finish_series(&mut self, human_won: bool, ctx: &mut ModeCtx) {
        if !self.playing {
            return;
        }
        self.cleared = if human_won {
            self.run.win()
        } else {
            self.run.loss();
            false
        };
        self.playing = false;
        self.left = self.intermission_ticks;
        self.result = Some(human_won);
        self.interrupted = false;
        self.replacement_vacated = false;
        ctx.close_match = true;
    }

    fn draw_series(&mut self, ctx: &mut ModeCtx) {
        if !self.playing {
            return;
        }
        self.playing = false;
        self.left = self.intermission_ticks;
        self.result = None;
        self.cleared = false;
        self.interrupted = false;
        self.replacement_vacated = false;
        ctx.close_match = true;
    }

    fn interrupt_series(&mut self, ctx: &mut ModeCtx) {
        if !self.playing {
            return;
        }
        self.playing = false;
        self.left = self.intermission_ticks;
        self.score = [0, 0];
        self.result = None;
        self.cleared = false;
        self.interrupted = true;
        self.opponent_ready = false;
        self.replacement_vacated = true;
        ctx.abort_match = true;
    }

    /// The only supported field shape is one person and one bot. An accidental
    /// extra seat must not turn an unrelated death into Ladder progress.
    fn opponents(seats: &[(u8, bool)]) -> Option<(u8, u8)> {
        let mut humans = seats.iter().filter(|(_, bot)| !bot).map(|(ship, _)| *ship);
        let mut bots = seats.iter().filter(|(_, bot)| *bot).map(|(ship, _)| *ship);
        let pair = (humans.next()?, bots.next()?);
        (humans.next().is_none() && bots.next().is_none()).then_some(pair)
    }

    fn banner(&self) -> String {
        if !self.opened {
            format!(
                "Waiting for Ladder opponent at rung {}",
                self.run.rung().saturating_add(1)
            )
        } else if self.playing && !self.opponent_ready {
            format!(
                "Waiting for Ladder opponent at rung {}",
                self.active_opponent_slot.saturating_add(1)
            )
        } else if self.playing {
            if self.left == 0 {
                format!(
                    "Ladder rung {}: sudden death, {} to {}",
                    self.active_opponent_slot.saturating_add(1),
                    self.score[0],
                    self.score[1]
                )
            } else {
                format!(
                    "Ladder rung {}: first to {}, {} to {}",
                    self.active_opponent_slot.saturating_add(1),
                    self.rules.first_to,
                    self.score[0],
                    self.score[1]
                )
            }
        } else if self.interrupted {
            format!(
                "Rival disconnected. Replaying rung {}",
                self.active_opponent_slot.saturating_add(1)
            )
        } else if self.cleared {
            format!(
                "Ladder cleared. New run starts at checkpoint {}",
                self.run.checkpoint().saturating_add(1)
            )
        } else if self.result == Some(true) {
            format!(
                "Rung {} cleared. Next rung {}, streak {}",
                self.active_opponent_slot.saturating_add(1),
                self.run.rung().saturating_add(1),
                self.run.streak()
            )
        } else if self.result == Some(false) {
            format!(
                "Run stopped at rung {}. Next rung {}, checkpoint {}",
                self.active_opponent_slot.saturating_add(1),
                self.run.rung().saturating_add(1),
                self.run.checkpoint().saturating_add(1)
            )
        } else {
            format!(
                "Rung {} drawn. Replay after the reset",
                self.active_opponent_slot.saturating_add(1)
            )
        }
    }
}

impl Mode for Ladder {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        let was_ready = self.opponent_ready;
        let opponent_ready = Self::opponents(ctx.seats).is_some();
        self.opponent_ready = opponent_ready;
        if !self.opened {
            self.playing = false;
            self.left = self.match_ticks;
            if opponent_ready {
                self.opened = true;
                self.begin_series();
                ctx.open_match = true;
            }
        } else if self.playing {
            if was_ready && !opponent_ready {
                self.interrupt_series(ctx);
            } else if opponent_ready {
                self.left = self.left.saturating_sub(1);
                if self.left == 0 && self.score[0] != self.score[1] {
                    self.finish_series(self.score[0] > self.score[1], ctx);
                }
            }
        } else {
            self.left = self.left.saturating_sub(1);
            if !opponent_ready {
                self.replacement_vacated = true;
            }
            let desired_changed = self.active_opponent_slot != self.run.rung();
            let replacement_ready = !desired_changed || self.replacement_vacated;
            if self.left == 0 && opponent_ready && replacement_ready {
                self.begin_series();
                ctx.open_match = true;
            }
        }
        ctx.banner = self.banner();
    }

    fn on_death(&mut self, ctx: &mut ModeCtx, victim: u8, _killer: u8) {
        if !self.playing {
            return;
        }
        let Some((human, bot)) = Self::opponents(ctx.seats) else {
            return;
        };
        let side = if victim == bot {
            0
        } else if victim == human {
            1
        } else {
            return;
        };
        self.score[side] = self.score[side].saturating_add(1);
        let reached_target = self.score[side] >= self.rules.first_to;
        let won_overtime = self.left == 0 && self.score[0] != self.score[1];
        if reached_target || won_overtime {
            self.finish_series(side == 0, ctx);
        }
        ctx.banner = self.banner();
    }

    fn on_deaths(&mut self, ctx: &mut ModeCtx, deaths: &[(u8, u8)]) {
        if !self.playing {
            return;
        }
        let Some((human, bot)) = Self::opponents(ctx.seats) else {
            return;
        };
        let human_died = deaths.iter().any(|(victim, _)| *victim == human);
        let bot_died = deaths.iter().any(|(victim, _)| *victim == bot);
        if human_died && bot_died {
            self.score[0] = self.score[0].saturating_add(1);
            self.score[1] = self.score[1].saturating_add(1);
            self.draw_series(ctx);
            ctx.banner = self.banner();
            return;
        }
        for &(victim, killer) in deaths {
            self.on_death(ctx, victim, killer);
        }
    }

    fn on_departure(&mut self, ctx: &mut ModeCtx, _ship: u8, _bot: bool) {
        self.interrupt_series(ctx);
        ctx.banner = self.banner();
    }

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "ladder"
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.playing,
            seconds_left: self.left.div_ceil(100).min(255) as u8,
            score: self.score.to_vec(),
        })
    }

    fn ladder_state(&self) -> Option<LadderState> {
        let desired_changed = self.active_opponent_slot != self.run.rung();
        let waiting = !self.playing
            && (!self.opened
                || (self.left == 0
                    && (!self.opponent_ready || (desired_changed && !self.replacement_vacated))));
        Some(LadderState {
            playing: self.playing,
            waiting,
            rung: self.run.rung(),
            streak: self.run.streak(),
            checkpoint: self.run.checkpoint(),
            best: self.run.best(),
            score: self.score,
            first_to: self.rules.first_to,
            active_opponent_slot: self.active_opponent_slot,
            desired_opponent_slot: self.run.rung(),
            opponent_ready: self.opponent_ready,
            cleared: self.cleared,
        })
    }

    fn first_human(&mut self) {
        self.run = LadderProgression::new(self.rules);
        self.playing = false;
        self.left = self.match_ticks;
        self.score = [0, 0];
        self.active_opponent_slot = 0;
        self.result = None;
        self.cleared = false;
        self.interrupted = false;
        self.opponent_ready = false;
        self.replacement_vacated = false;
        self.opened = false;
    }

    fn restore_ladder(&mut self, checkpoint: u32, best: u32) -> bool {
        self.run = LadderProgression::restore(self.rules, checkpoint, 0, checkpoint, best);
        self.playing = false;
        self.left = self.match_ticks;
        self.score = [0, 0];
        self.active_opponent_slot = checkpoint;
        self.result = None;
        self.cleared = false;
        self.interrupted = false;
        self.opponent_ready = false;
        self.replacement_vacated = false;
        self.opened = false;
        true
    }
}

/// Warzone: a team wins the round by holding every flag at once.
///
/// The simulation moves flags; this decides what an arrangement of them
/// means, which is the split the original drew between flagcore and fg_wz.
pub struct Warzone {
    pub flags: u8,
    /// How many sides there are to win. Four was hardcoded here, in the leader
    /// search, in the win tally and in the banner, which is fine for the two the
    /// shipped zone has and silently wrong for anything else: a side above three
    /// could never be found holding the set, and its win was tallied against
    /// `team % 4`, somebody else's row. A one-team zone gives every pilot their
    /// own side, so that ceiling became reachable the day free-for-all was
    /// fixed.
    pub teams: u8,
    pub round: u16,
    pub wins: Vec<u16>,
    hold: Option<(u8, u32)>, // team and the tick they completed the set
    /// Where each flag belongs, learned on the first tick and put back on a
    /// reset. Flags travel: the core moves one with whoever is carrying it and
    /// drops it where they die, so a round that reset only their ownership left
    /// them lying wherever the winning side had gathered them. Measured: the
    /// first round took fifty seconds and every round after it took exactly
    /// seven, which is the reset delay plus the hold -- the winners were standing
    /// on all four when they went neutral. The comment on this reset already
    /// promised they went back where they started.
    homes: Vec<(i32, i32)>,
    hold_ticks: u32,
    reset_at: Option<u32>,
    clock: u32,
}

impl Warzone {
    pub fn new(flags: u8, teams: u8) -> Self {
        Warzone {
            flags,
            teams,
            round: 1,
            wins: vec![0; teams as usize],
            hold: None,
            homes: Vec::new(),
            hold_ticks: 1_000, // ten seconds holding the full set to win
            reset_at: None,
            clock: 0,
        }
    }
}

impl Mode for Warzone {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        self.clock += 1;
        if self.homes.is_empty() {
            self.homes = (0..ctx.world.state.flag_count as usize)
                .map(|i| (ctx.world.state.flags[i].x, ctx.world.state.flags[i].y))
                .collect();
        }

        if let Some(at) = self.reset_at {
            let left = at.saturating_sub(self.clock);
            if left == 0 {
                // New round: every flag neutral and back where it started.
                for i in 0..ctx.world.state.flag_count as usize {
                    let home = self.homes.get(i).copied();
                    let f = &mut ctx.world.state.flags[i];
                    f.team = sim::TEAM_NONE;
                    f.carried = 0;
                    f.carrier = 0;
                    f.cooldown = 0;
                    if let Some((x, y)) = home {
                        f.x = x;
                        f.y = y;
                    }
                }
                self.reset_at = None;
                self.hold = None;
                self.round += 1;
            }
            return;
        }

        // Who, if anybody, holds the whole set.
        let mut leader = None;
        for team in 0..self.teams {
            if ctx.world.flags_held(team) as u8 == self.flags && self.flags > 0 {
                leader = Some(team);
                break;
            }
        }

        match (leader, self.hold) {
            (Some(t), Some((held, since))) if held == t => {
                let left = self.hold_ticks.saturating_sub(self.clock - since);
                if left == 0 {
                    if let Some(w) = self.wins.get_mut(t as usize) {
                        *w += 1;
                    }
                    self.reset_at = Some(self.clock + 500);
                    ctx.banner = format!("{} wins round {}", ctx.team_name(t), self.round);
                } else {
                    ctx.banner = format!(
                        "{} holds all {} flags: {}",
                        ctx.team_name(t),
                        self.flags,
                        left / 100 + 1
                    );
                }
            }
            (Some(t), _) => {
                self.hold = Some((t, self.clock));
                ctx.banner = format!("{} holds all {} flags", ctx.team_name(t), self.flags);
            }
            (None, _) => {
                self.hold = None;
                // Nothing. The HUD draws a pennant per flag, colored yours,
                // theirs or loose, twenty-five points above where this line
                // lands, so a tally here was the same answer written out
                // longhand under the picture of itself. The banner is for what
                // the pennants cannot show: the countdown and the win.
                ctx.banner = String::new();
            }
        }
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "warzone"
    }
}

#[cfg(test)]
mod melee_tests {
    use super::*;

    fn world_with(sides: &[(u8, i16)]) -> World {
        let mut w = World::new(11);
        for (team, kills) in sides.iter().copied() {
            let i = w.spawn(0, team, 500, 500, 0);
            assert!(i >= 0, "a seat");
            w.state.ships[i as usize].kills = kills;
        }
        w
    }

    fn ctx<'a>(world: &'a mut World, names: &'a [String]) -> ModeCtx<'a> {
        ModeCtx {
            world,
            seats: &[],
            team_names: names,
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
            abort_match: false,
        }
    }

    fn sides() -> Vec<String> {
        vec!["Pylon".into(), "Caisson".into()]
    }

    /// The first tick of a fresh room opens a match rather than dropping the
    /// pilots into whatever phase the constructor happened to leave. A room
    /// grown mid-evening would otherwise open on a podium for a match nobody
    /// played.
    #[test]
    fn a_new_room_opens_a_match_on_its_first_tick() {
        let names = sides();
        let mut w = world_with(&[(0, 0)]);
        let mut m = Melee::new(2, 300, 100);
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(c.open_match, "the room is asked to open one");
        let s = m.match_state().expect("a match game has a clock");
        assert!(s.playing);
        assert_eq!(s.seconds_left, 3);
    }

    #[test]
    fn the_first_human_gets_a_whole_match_after_the_bot_clock() {
        let names = sides();
        let mut w = world_with(&[(0, 0), (1, 0)]);
        let mut m = Melee::new(2, 300, 100);
        for _ in 0..175 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
        }
        assert_eq!(m.match_state().unwrap().seconds_left, 2);

        m.first_human();
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(c.open_match);
        assert_eq!(m.match_state().unwrap().seconds_left, 3);
        assert_eq!(m.match_state().unwrap().score, vec![0, 0]);
    }

    /// Three minutes, a podium, and another three minutes, with the room asked
    /// to open a match at each whistle and never in between.
    #[test]
    fn the_clock_runs_down_into_an_intermission_and_out_again() {
        let names = sides();
        let mut w = world_with(&[(0, 0)]);
        let mut m = Melee::new(2, 300, 100);
        let mut opens = 0;
        let mut phases = Vec::new();
        for _ in 0..800 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            if c.open_match {
                opens += 1;
            }
            let playing = m.match_state().unwrap().playing;
            if phases.last() != Some(&playing) {
                phases.push(playing);
            }
        }
        assert_eq!(
            phases,
            vec![true, false, true, false, true],
            "match, podium, match, podium, match"
        );
        assert_eq!(opens, 3, "one at the start and one at every whistle");
    }

    /// The score is the kills on the field while a match is being played, and
    /// the kills it ended on for as long as the podium is up. A bomb still in
    /// the air at the whistle must not rewrite the result underneath it.
    #[test]
    fn the_podium_shows_the_score_the_match_ended_on() {
        let names = sides();
        let mut w = world_with(&[(0, 3), (1, 5)]);
        let mut m = Melee::new(2, 20, 100);
        for _ in 0..19 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().score, vec![3, 5], "live");

        m.tick(&mut ctx(&mut w, &names)); // the whistle
        assert!(!m.match_state().unwrap().playing);
        w.state.ships[0].kills = 99;
        for _ in 0..20 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(
            m.match_state().unwrap().score,
            vec![3, 5],
            "the podium is not a live scoreboard"
        );
    }

    #[test]
    fn the_banner_names_who_took_it_and_calls_a_tie_a_draw() {
        let names = sides();
        let mut w = world_with(&[(0, 2), (1, 7)]);
        let mut m = Melee::new(2, 5, 100);
        let mut banner = String::new();
        for _ in 0..6 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            banner = c.banner;
        }
        assert!(banner.contains("Caisson"), "who won: {banner:?}");
        assert!(banner.contains("2 to 7"), "and by what: {banner:?}");

        let mut w = world_with(&[(0, 4), (1, 4)]);
        let mut m = Melee::new(2, 5, 100);
        let mut banner = String::new();
        for _ in 0..6 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            banner = c.banner;
        }
        assert_eq!(banner, "a draw");
    }

    /// A mode that is not a match game has no clock, and the room reads that
    /// as "nothing to send and nobody to hold still".
    #[test]
    fn every_other_mode_has_no_clock() {
        assert!(FreeForAll.match_state().is_none());
        assert!(Warzone::new(4, 2).match_state().is_none());
    }

    #[test]
    fn a_zone_names_the_mode_and_gets_it() {
        let setup = Setup {
            flags: 0,
            teams: 2,
            match_ticks: 18_000,
            intermission_ticks: 2_500,
            ladder: LadderRules::default(),
        };
        assert_eq!(build("melee", &setup).name(), "melee");
        assert_eq!(build("warzone", &setup).name(), "warzone");
        assert_eq!(build("arena", &setup).name(), "arena");
        assert_eq!(build("ladder", &setup).name(), "ladder");
        assert!(exists("melee"), "and the catalog will accept the name");
        assert!(exists("ladder"), "and the catalog will accept Ladder");
    }
}

#[cfg(test)]
mod ladder_tests {
    use super::*;

    fn ctx<'a>(world: &'a mut World, seats: &'a [(u8, bool)]) -> ModeCtx<'a> {
        ModeCtx {
            world,
            seats,
            team_names: &[],
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
            abort_match: false,
        }
    }

    #[test]
    fn wins_advance_the_rung_and_streak() {
        let mut run = LadderProgression::new(LadderRules::default());
        run.win();
        run.win();
        assert_eq!(run.rung(), 2);
        assert_eq!(run.streak(), 2);
        assert_eq!(run.checkpoint(), 0);
    }

    #[test]
    fn a_loss_resets_the_streak_and_drops_the_configured_rungs() {
        let rules = LadderRules {
            loss_drop: 3,
            ..LadderRules::default()
        };
        let mut run = LadderProgression::restore(rules, 6, 6, 0, 6);
        run.loss();
        assert_eq!(run.rung(), 3);
        assert_eq!(run.streak(), 0);
        assert_eq!(run.checkpoint(), 0);
    }

    #[test]
    fn an_unlocked_checkpoint_is_a_loss_floor() {
        let rules = LadderRules {
            loss_drop: 2,
            checkpoint_interval: 3,
            ..LadderRules::default()
        };
        let mut run = LadderProgression::new(rules);
        for _ in 0..3 {
            run.win();
        }
        assert_eq!(run.checkpoint(), 3, "the third rung unlocks its floor");
        run.win();
        run.win();
        assert_eq!(run.rung(), 5);
        run.loss();
        assert_eq!(run.rung(), 3, "the configured drop reaches the floor");
        run.loss();
        assert_eq!(run.rung(), 3, "another loss cannot cross the floor");
        assert_eq!(run.streak(), 0);
    }

    #[test]
    fn a_zero_interval_disables_new_checkpoints() {
        let rules = LadderRules {
            checkpoint_interval: 0,
            ..LadderRules::default()
        };
        let mut run = LadderProgression::new(rules);
        for _ in 0..20 {
            run.win();
        }
        assert_eq!(run.checkpoint(), 0);
    }

    #[test]
    fn clearing_the_top_starts_the_next_run_at_the_floor() {
        let last = pilots::PROVISIONAL_LADDER_RUNG_COUNT as u32 - 1;
        let mut run = LadderProgression::restore(LadderRules::default(), last, 9, 5, last);
        assert!(run.win(), "the last opponent completes the finite roster");
        assert_eq!(run.rung(), 5, "the next run starts at its saved floor");
        assert_eq!(run.streak(), 0);
        assert_eq!(
            run.best(),
            pilots::PROVISIONAL_LADDER_RUNG_COUNT as u32,
            "the record includes the final cleared opponent"
        );
    }

    #[test]
    fn restore_cannot_put_a_checkpoint_above_the_run() {
        let run = LadderProgression::restore(LadderRules::default(), 4, 2, 9, 0);
        assert_eq!(run.rung(), 4);
        assert_eq!(run.checkpoint(), 4);
    }

    #[test]
    fn configured_first_to_three_changes_the_slot_only_after_the_series() {
        let seats = [(3, false), (9, true)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(
            LadderRules {
                first_to: 3,
                ..LadderRules::default()
            },
            1_000,
            2,
        );

        let mut opening = ctx(&mut world, &seats);
        ladder.tick(&mut opening);
        assert!(opening.open_match);

        for expected in 1..3 {
            let mut point = ctx(&mut world, &seats);
            ladder.on_death(&mut point, 9, 3);
            assert!(!point.close_match);
            let state = ladder.ladder_state().unwrap();
            assert_eq!(state.score, [expected, 0]);
            assert_eq!(state.active_opponent_slot, 0);
            assert_eq!(state.desired_opponent_slot, 0);
        }

        let mut winning_point = ctx(&mut world, &seats);
        ladder.on_death(&mut winning_point, 9, 3);
        assert!(winning_point.close_match);
        let state = ladder.ladder_state().unwrap();
        assert!(!state.playing);
        assert_eq!(state.rung, 1);
        assert_eq!(state.streak, 1);
        assert_eq!(state.score, [3, 0]);
        assert_eq!(
            state.active_opponent_slot, 0,
            "the finished foe stays named"
        );
        assert_eq!(
            state.desired_opponent_slot, 1,
            "the next foe is now requested"
        );

        let human_only = [(3, false)];
        let mut waiting = ctx(&mut world, &human_only);
        ladder.tick(&mut waiting);
        assert!(!waiting.open_match);
        let mut next = ctx(&mut world, &seats);
        ladder.tick(&mut next);
        assert!(next.open_match);
        let state = ladder.ladder_state().unwrap();
        assert!(state.playing);
        assert_eq!(state.score, [0, 0]);
        assert_eq!(state.active_opponent_slot, 1);
        assert_eq!(state.desired_opponent_slot, 1);
    }

    #[test]
    fn an_extra_seat_cannot_score_ladder_progress() {
        let seats = [(3, false), (9, true), (10, true)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(LadderRules::default(), 1_000, 2);
        ladder.tick(&mut ctx(&mut world, &seats));
        ladder.on_death(&mut ctx(&mut world, &seats), 9, 3);
        assert_eq!(ladder.ladder_state().unwrap().score, [0, 0]);
    }

    #[test]
    fn first_human_starts_a_new_run() {
        let seats = [(3, false), (9, true)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(
            LadderRules {
                first_to: 1,
                ..LadderRules::default()
            },
            1_000,
            2,
        );
        ladder.tick(&mut ctx(&mut world, &seats));
        ladder.on_death(&mut ctx(&mut world, &seats), 9, 3);
        assert_eq!(ladder.ladder_state().unwrap().rung, 1);

        ladder.first_human();
        ladder.tick(&mut ctx(&mut world, &seats));
        let state = ladder.ladder_state().unwrap();
        assert_eq!(state.rung, 0);
        assert_eq!(state.streak, 0);
        assert_eq!(state.score, [0, 0]);
        assert_eq!(state.active_opponent_slot, 0);
    }

    #[test]
    fn default_ladder_is_single_life() {
        assert_eq!(LadderRules::default().first_to, 1);
        let seats = [(3, false), (9, true)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(LadderRules::default(), 1_000, 2);
        ladder.tick(&mut ctx(&mut world, &seats));

        let mut point = ctx(&mut world, &seats);
        ladder.on_death(&mut point, 9, 3);
        assert!(point.close_match);
        assert_eq!(ladder.ladder_state().unwrap().rung, 1);
    }

    #[test]
    fn the_top_opponent_produces_a_clear_instead_of_a_plateau() {
        let seats = [(3, false), (9, true)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(LadderRules::default(), 1_000, 2);
        let last = pilots::PROVISIONAL_LADDER_RUNG_COUNT as u32 - 1;
        ladder.run = LadderProgression::restore(LadderRules::default(), last, 9, 5, last);
        ladder.tick(&mut ctx(&mut world, &seats));

        let mut point = ctx(&mut world, &seats);
        ladder.on_death(&mut point, 9, 3);
        assert!(point.close_match);
        let state = ladder.ladder_state().unwrap();
        assert!(state.cleared);
        assert_eq!(state.active_opponent_slot, last);
        assert_eq!(state.desired_opponent_slot, 5);
        assert_eq!(state.best, last + 1);
        assert_eq!(state.rung, 5);

        let human_only = [(3, false)];
        ladder.tick(&mut ctx(&mut world, &human_only));
        let mut replacement = ctx(&mut world, &seats);
        ladder.tick(&mut replacement);
        assert!(replacement.open_match);
        let next = ladder.ladder_state().unwrap();
        assert!(!next.cleared);
        assert_eq!(next.active_opponent_slot, 5);
    }

    #[test]
    fn restore_starts_at_the_saved_checkpoint_with_no_streak() {
        let mut ladder = Ladder::new(LadderRules::default(), 1_000, 2);
        assert!(ladder.restore_ladder(5, 7));
        let state = ladder.ladder_state().unwrap();
        assert!(!state.playing);
        assert_eq!(state.rung, 5);
        assert_eq!(state.checkpoint, 5);
        assert_eq!(state.streak, 0);
        assert_eq!(state.best, 7);
        assert_eq!(state.score, [0, 0]);
        assert_eq!(state.active_opponent_slot, 5);
        assert_eq!(state.desired_opponent_slot, 5);
        assert!(!FreeForAll.restore_ladder(5, 7));
    }

    #[test]
    fn a_series_waits_at_full_time_until_both_opponents_arrive() {
        let human_only = [(3, false)];
        let pair = [(3, false), (9, true)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(LadderRules::default(), 500, 20);
        ladder.first_human();

        for _ in 0..300 {
            let mut waiting = ctx(&mut world, &human_only);
            ladder.tick(&mut waiting);
            assert!(!waiting.open_match);
        }
        assert_eq!(ladder.left, 500, "the match clock has not burned");
        assert!(!ladder.ladder_state().unwrap().opponent_ready);

        let mut ready = ctx(&mut world, &pair);
        ladder.tick(&mut ready);
        assert!(ready.open_match);
        assert_eq!(ladder.left, 500, "the series opens at full length");
        assert!(ladder.ladder_state().unwrap().opponent_ready);
    }

    #[test]
    fn a_departed_opponent_invalidates_and_replays_the_life() {
        let pair = [(3, false), (9, true)];
        let human_only = [(3, false)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(LadderRules::default(), 500, 20);
        ladder.tick(&mut ctx(&mut world, &pair));
        ladder.tick(&mut ctx(&mut world, &pair));
        assert_eq!(ladder.left, 499);

        let before = ladder.ladder_state().unwrap();
        let mut interrupted = ctx(&mut world, &human_only);
        ladder.tick(&mut interrupted);
        assert!(interrupted.abort_match);
        assert!(!interrupted.close_match);
        assert!(interrupted.banner.contains("disconnected"));
        let stopped = ladder.ladder_state().unwrap();
        assert!(!stopped.playing);
        assert_eq!(stopped.score, [0, 0]);
        assert_eq!(stopped.rung, before.rung);
        assert_eq!(stopped.streak, before.streak);
        assert_eq!(stopped.checkpoint, before.checkpoint);
        assert_eq!(stopped.best, before.best);

        for _ in 0..20 {
            ladder.tick(&mut ctx(&mut world, &human_only));
        }
        let mut replacement = ctx(&mut world, &pair);
        ladder.tick(&mut replacement);
        assert!(replacement.open_match);
        let replay = ladder.ladder_state().unwrap();
        assert!(replay.playing);
        assert_eq!(replay.active_opponent_slot, before.active_opponent_slot);
        assert_eq!(replay.rung, before.rung);
        assert_eq!(ladder.left, 500, "the replay starts with a fresh clock");
    }

    #[test]
    fn opponent_change_waits_at_zero_for_the_replacement() {
        let pair = [(3, false), (9, true)];
        let human_only = [(3, false)];
        let mut world = World::new(7);
        let mut ladder = Ladder::new(LadderRules::default(), 500, 2);
        ladder.tick(&mut ctx(&mut world, &pair));
        ladder.on_death(&mut ctx(&mut world, &pair), 9, 3);

        ladder.tick(&mut ctx(&mut world, &pair));
        let mut zero = ctx(&mut world, &pair);
        ladder.tick(&mut zero);
        assert!(!zero.open_match, "the old pair cannot open the next rung");
        assert_eq!(ladder.left, 0);

        ladder.tick(&mut ctx(&mut world, &human_only));
        assert_eq!(ladder.left, 0, "the wait stays at zero");
        let mut replacement = ctx(&mut world, &pair);
        ladder.tick(&mut replacement);
        assert!(replacement.open_match);
        assert_eq!(ladder.ladder_state().unwrap().active_opponent_slot, 1);
    }

    #[test]
    fn a_mutual_kill_is_a_draw_in_either_event_order() {
        let seats = [(3, false), (9, true)];
        for deaths in [[(3, 9), (9, 3)], [(9, 3), (3, 9)]] {
            let mut world = World::new(7);
            let mut ladder = Ladder::new(LadderRules::default(), 500, 2);
            ladder.tick(&mut ctx(&mut world, &seats));

            let mut same_tick = ctx(&mut world, &seats);
            ladder.on_deaths(&mut same_tick, &deaths);
            assert!(same_tick.close_match);
            let state = ladder.ladder_state().unwrap();
            assert!(!state.playing);
            assert_eq!(state.score, [1, 1]);
            assert_eq!(state.rung, 0, "a draw does not move the run");
            assert_eq!(state.streak, 0);
            assert_eq!(state.desired_opponent_slot, 0);
        }
    }
}

#[cfg(test)]
mod warzone_tests {
    use super::*;

    fn arena_with_flags(n: usize) -> World {
        let mut w = World::new(3);
        let spots = [(486, 486), (538, 486), (538, 538), (486, 538), (512, 512)];
        for spot in spots.iter().take(n) {
            w.add_flag(spot.0, spot.1);
        }
        w
    }

    fn ctx(world: &mut World) -> ModeCtx<'_> {
        ModeCtx {
            world,
            seats: &[],
            team_names: &[],
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
            abort_match: false,
        }
    }

    #[test]
    fn holding_every_flag_wins_a_round() {
        let mut w = arena_with_flags(3);
        let mut m = Warzone::new(3, 2);
        for i in 0..3 {
            w.state.flags[i].team = 1;
        }
        // The set has to be held, not merely touched.
        m.tick(&mut ctx(&mut w));
        assert_eq!(m.wins[1], 0, "the set must be held, not just completed");
        for _ in 0..1_100 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins[1], 1, "holding the set for the timer wins");
    }

    #[test]
    fn losing_one_flag_stops_the_clock() {
        let mut w = arena_with_flags(3);
        let mut m = Warzone::new(3, 2);
        for i in 0..3 {
            w.state.flags[i].team = 0;
        }
        for _ in 0..100 {
            m.tick(&mut ctx(&mut w));
        }
        w.state.flags[2].team = 1; // stolen back
        for _ in 0..1_100 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins[0], 0, "the countdown restarts when the set breaks");
    }

    #[test]
    fn a_reset_puts_the_flags_back_where_they_were() {
        // Ownership alone is not a reset. Flags travel with whoever carries them,
        // so a round that only neutralised them left them lying wherever the
        // winning side had gathered them -- and the winners were standing on all
        // four when the next round began. Measured before: the first round took
        // fifty seconds and every one after it took exactly seven, the reset
        // delay plus the hold. After: 58, 118, 241, 179 seconds, won by both
        // sides.
        let mut w = arena_with_flags(2);
        let mut m = Warzone::new(2, 2);
        m.tick(&mut ctx(&mut w)); // learns where they belong
        let home: Vec<(i32, i32)> = (0..2)
            .map(|i| (w.state.flags[i].x, w.state.flags[i].y))
            .collect();

        // Carried across the map and held to a win.
        for i in 0..2 {
            w.state.flags[i].team = 1;
            w.state.flags[i].carried = 1;
            w.state.flags[i].carrier = 7;
            w.state.flags[i].x += 300 * 16 * 256;
            w.state.flags[i].y += 120 * 16 * 256;
        }
        for _ in 0..1_800 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.round, 2, "the round ended");
        for (i, was) in home.iter().enumerate() {
            assert_eq!(
                (w.state.flags[i].x, w.state.flags[i].y),
                *was,
                "flag {i} did not go home"
            );
            assert_eq!(w.state.flags[i].team, sim::TEAM_NONE);
            assert_eq!(w.state.flags[i].carried, 0);
            assert_eq!(w.state.flags[i].carrier, 0);
        }
    }

    #[test]
    fn a_simultaneous_change_of_flag_owner_restarts_the_hold() {
        let mut w = arena_with_flags(2);
        let mut m = Warzone::new(2, 2);
        for i in 0..2 {
            w.state.flags[i].team = 0;
        }
        m.tick(&mut ctx(&mut w));
        for _ in 0..500 {
            m.tick(&mut ctx(&mut w));
        }

        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        m.tick(&mut ctx(&mut w));
        for _ in 0..999 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins, vec![0, 0], "the new side gets its own full hold");
        m.tick(&mut ctx(&mut w));
        assert_eq!(m.wins, vec![0, 1]);
    }

    #[test]
    fn a_disconnected_carrier_drops_the_flag_before_scoring() {
        let mut w = arena_with_flags(1);
        w.spawn(0, 0, 512, 512, 0);
        let ship = w.state.ships[0];
        let flag = &mut w.state.flags[0];
        flag.team = 0;
        flag.carried = 1;
        flag.carrier = 0;
        flag.x = ship.x;
        flag.y = ship.y;
        w.state.ships[0].active = 0;

        w.step(&[]);
        let mut m = Warzone::new(1, 2);
        m.tick(&mut ctx(&mut w));

        assert_eq!(w.state.flags[0].carried, 0);
        assert_eq!(w.state.flags[0].carrier, 0);
        assert_eq!(m.wins, vec![0, 0]);
    }

    #[test]
    fn a_side_above_three_can_win() {
        // Four sides were hardcoded here. A free-for-all gives every pilot their
        // own side, so a zone with flags and `teams = 1` had rounds that only
        // ships zero to three could ever win, and a win by ship five was tallied
        // against ship one's row.
        let mut w = arena_with_flags(2);
        let mut m = Warzone::new(2, 8);
        for i in 0..2 {
            w.state.flags[i].team = 5;
        }
        for _ in 0..1_100 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins[5], 1, "side five holding the set wins");
        assert_eq!(m.wins[1], 0, "and it is not credited to side one");
    }

    #[test]
    fn a_round_resets_the_flags() {
        let mut w = arena_with_flags(2);
        let mut m = Warzone::new(2, 2);
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        for _ in 0..1_800 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.round, 2, "a new round starts");
        assert_eq!(
            w.state.flags[0].team,
            sim::TEAM_NONE,
            "flags go neutral again"
        );
    }
}
