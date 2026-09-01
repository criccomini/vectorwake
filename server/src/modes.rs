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

use crate::sim::{self, World};

pub struct ModeCtx<'a> {
    pub world: &'a mut World,
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

/// Simulation ticks in one second, which is the unit every clock in here is
/// counted in and every clock out of here is reported in.
pub const TICKS_PER_SECOND: u32 = 100;

/// What a match game's clock is doing on this tick.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Beat {
    /// A fresh match starts here: the room is putting everybody home and the
    /// mode should start counting from nothing. Both the first tick of a room
    /// and the tick a podium ends on.
    Opening,
    /// An ordinary tick of a match being played.
    Playing,
    /// The whistle. The match is over and the podium is going up, and this
    /// tick is still part of the match that just ended.
    Ending,
    /// An ordinary tick of the podium, with nobody flying.
    Waiting,
}

/// The two-phase clock a match game runs on.
///
/// The room outlives the match: it plays one, puts up a podium, changes
/// ground and plays another. Three modes need exactly that and differ only in
/// what they count, so the phases live here and the score stays with the mode
/// that knows what it means.
pub struct Clock {
    match_ticks: u32,
    intermission_ticks: u32,
    /// Ticks left in whichever phase this is.
    left: u32,
    playing: bool,
    /// The first tick has not run yet, so the room has not opened a match.
    /// Set once, which is what makes a room that has just been built start
    /// playing rather than sit through an intermission it did not earn.
    opened: bool,
}

impl Clock {
    pub fn new(match_ticks: u32, intermission_ticks: u32) -> Self {
        Clock {
            match_ticks: match_ticks.max(1),
            intermission_ticks: intermission_ticks.max(1),
            left: match_ticks.max(1),
            playing: true,
            opened: false,
        }
    }

    /// Advance one tick and say what it was, telling the room to open or
    /// close a match where one is due.
    pub fn beat(&mut self, ctx: &mut ModeCtx) -> Beat {
        let mut beat = if self.playing {
            Beat::Playing
        } else {
            Beat::Waiting
        };
        if !self.opened {
            self.opened = true;
            self.left = self.match_ticks;
            self.playing = true;
            ctx.open_match = true;
            beat = Beat::Opening;
        }

        self.left = self.left.saturating_sub(1);
        if self.left == 0 {
            self.playing = !self.playing;
            if self.playing {
                self.left = self.match_ticks;
                ctx.open_match = true;
                beat = Beat::Opening;
            } else {
                self.left = self.intermission_ticks;
                ctx.close_match = true;
                beat = Beat::Ending;
            }
        }
        beat
    }

    pub fn playing(&self) -> bool {
        self.playing
    }

    /// Start a fresh match on the next tick, whatever this one is doing.
    ///
    /// The same path a room's first tick takes: the next beat is an
    /// `Opening`, the clock is put back to a whole match, and the room is
    /// asked to put everybody home. A room that has not opened yet is
    /// unchanged by this, which is what makes it safe to ask at the door.
    ///
    /// A duel asks for it. The match there is between the two seats, so a
    /// seat changing hands is a new match rather than a late arrival into
    /// somebody else's; see `Room::join_on`.
    pub fn reopen(&mut self) {
        self.opened = false;
    }

    /// Whole seconds left in this phase, rounded up so a clock reads 1 for
    /// the last second rather than sitting on 0 while there is still a second
    /// to play in.
    pub fn seconds_left(&self) -> u8 {
        self.left.div_ceil(TICKS_PER_SECOND).min(255) as u8
    }
}

/// Who is ahead on a score, and `None` for a tie at the top. A draw is a
/// real result in every game here and gets said rather than tie-broken.
fn leader(score: &[u16]) -> Option<u8> {
    let best = *score.iter().max()?;
    let mut who = None;
    for (t, n) in score.iter().enumerate() {
        if *n == best {
            if who.is_some() {
                return None;
            }
            who = Some(t as u8);
        }
    }
    who
}

/// What the podium says: who took it and by how much, or that nobody did.
fn result_banner(ctx: &ModeCtx, score: &[u16]) -> String {
    match leader(score) {
        Some(t) => format!(
            "{} takes it, {}",
            ctx.team_name(t),
            score
                .iter()
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
                .join(" to ")
        ),
        None => "a draw".to_string(),
    }
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
pub const NAMES: [&str; 4] = ["arena", "warzone", "melee", "turf"];

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
    /// Ticks between two turf payouts. Only Turf reads it.
    pub turf_period: u32,
}

/// Build the mode a zone asked for.
pub fn build(name: &str, s: &Setup) -> Box<dyn Mode> {
    let (flags, teams) = (s.flags.max(1), s.teams.max(1));
    match name {
        "warzone" => Box::new(Warzone::new(
            flags,
            teams,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
        )),
        "melee" => Box::new(Melee::new(
            teams,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
        )),
        "turf" => Box::new(Turf::new(
            teams,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
            s.turf_period.max(1),
        )),
        // An unknown name gets a free-for-all rather than a refusal, because
        // the catalog has already accepted the name and a running room beats
        // a dead one.
        _ => Box::new(FreeForAll),
    }
}

pub trait Mode: Send {
    fn tick(&mut self, ctx: &mut ModeCtx);
    /// One death, in the order the tick that produced it emitted them.
    fn on_death(&mut self, ctx: &mut ModeCtx, victim: u8, killer: u8);
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
    /// Start a fresh match on the next tick. A mode with no clock has
    /// nothing to reopen and ignores it.
    fn reopen(&mut self) {}
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
    clock: Clock,
    /// The score, live while playing and held through the intermission.
    score: Vec<u16>,
}

impl Melee {
    pub fn new(teams: u8, match_ticks: u32, intermission_ticks: u32) -> Self {
        Melee {
            teams,
            clock: Clock::new(match_ticks, intermission_ticks),
            score: vec![0; teams as usize],
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
}

impl Mode for Melee {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        match self.clock.beat(ctx) {
            // A fresh match counts from nothing. The kills on the field are
            // the score and `sim_restart` zeroes them, so all this has to do
            // is forget the match just played.
            Beat::Opening => self.score = vec![0; self.teams as usize],
            // The whistle tick is still part of the match it ended, which is
            // what makes a bomb already in the air count.
            Beat::Playing | Beat::Ending => self.score = self.tally(ctx),
            Beat::Waiting => {}
        }

        ctx.banner = if self.clock.playing() {
            String::new()
        } else {
            result_banner(ctx, &self.score)
        };
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "melee"
    }

    fn reopen(&mut self) {
        self.clock.reopen();
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.clock.playing(),
            seconds_left: self.clock.seconds_left(),
            score: self.score.clone(),
        })
    }
}

/// Turf: the stands pay whoever is holding them, over and over.
///
/// A turf flag cannot be carried, so there is nothing to bring home and no
/// arrangement of them to complete. What there is instead is a clock: every
/// `period` ticks each side is paid one point per stand it holds, and the
/// match is won by whoever has the most when time runs out. Holding two of
/// five is not a losing position, it is two points a period, which is the
/// whole reason the game spreads a fight over the map rather than collapsing
/// it onto one contested room.
///
/// It is a match game and reuses Melee's shape: three minutes, a podium, the
/// room opening a fresh one at each whistle. What it does not reuse is the
/// score, which is paid rather than tallied off the ships, so it is kept here.
pub struct Turf {
    teams: u8,
    clock: Clock,
    /// Ticks between payouts, and the count down to the next one.
    period: u32,
    until_pay: u32,
    score: Vec<u16>,
}

impl Turf {
    pub fn new(teams: u8, match_ticks: u32, intermission_ticks: u32, period: u32) -> Self {
        Turf {
            teams,
            clock: Clock::new(match_ticks, intermission_ticks),
            period,
            until_pay: period,
            score: vec![0; teams as usize],
        }
    }

    /// Stands held, per side. Saturating, because a long match on a wide map
    /// can pay a lot of periods and a side's total is a u16 on the wire.
    fn pay(&mut self, ctx: &ModeCtx) {
        for team in 0..self.teams {
            let held = ctx.world.flags_held(team) as u16;
            if let Some(n) = self.score.get_mut(team as usize) {
                *n = n.saturating_add(held);
            }
        }
    }
}

impl Mode for Turf {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        let beat = self.clock.beat(ctx);
        if beat == Beat::Opening {
            self.score = vec![0; self.teams as usize];
            self.until_pay = self.period;
        }
        // The payout clock runs on the same ticks the match clock does, both
        // ends included, so a three minute match on a five second period pays
        // exactly thirty-six times whatever else happens.
        if matches!(beat, Beat::Opening | Beat::Playing | Beat::Ending) {
            self.until_pay = self.until_pay.saturating_sub(1);
            if self.until_pay == 0 {
                self.pay(ctx);
                self.until_pay = self.period;
            }
        }

        // The pennants say who holds what, so the banner is left to the one
        // thing they cannot say: who took the match.
        ctx.banner = if self.clock.playing() {
            String::new()
        } else {
            result_banner(ctx, &self.score)
        };
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "turf"
    }

    fn reopen(&mut self) {
        self.clock.reopen();
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.clock.playing(),
            seconds_left: self.clock.seconds_left(),
            score: self.score.clone(),
        })
    }
}

/// Warzone: a side takes a round by holding every flag at once, and the match
/// by taking the most rounds before the clock runs out.
///
/// The simulation moves flags; this decides what an arrangement of them
/// means, which is the split the original drew between flagcore and fg_wz.
///
/// The round is the original's and the match around it is ours. A room that
/// ran rounds forever had no score to show, no clock beside the deploy key,
/// no ending board and no reason to change ground, so it was the one game in
/// the catalog a player could not read from the outside. Wrapping it puts War
/// on the same footing as Team Battle and Turf: three or four minutes, a
/// podium, next map.
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
    /// Rounds taken, per side. This is the match score.
    pub wins: Vec<u16>,
    clock: Clock,
    hold: Option<(u8, u32)>, // team and the tick they completed the set
    /// Where each flag belongs, learned on the first tick after a placement
    /// and put back on a reset. Flags travel: the core moves one with whoever
    /// is carrying it and drops it where they die, so a round that reset only
    /// their ownership left them lying wherever the winning side had gathered
    /// them. Measured: the first round took fifty seconds and every round
    /// after it took exactly seven, which is the reset delay plus the hold,
    /// the winners standing on all four when they went neutral.
    ///
    /// Forgotten at every whistle, because the room stands the flags back on
    /// the map's own tiles when it opens a match and the ground may have
    /// changed underneath them.
    homes: Vec<(i32, i32)>,
    hold_ticks: u32,
    reset_at: Option<u32>,
    elapsed: u32,
}

impl Warzone {
    pub fn new(flags: u8, teams: u8, match_ticks: u32, intermission_ticks: u32) -> Self {
        Warzone {
            flags,
            teams,
            round: 1,
            wins: vec![0; teams as usize],
            clock: Clock::new(match_ticks, intermission_ticks),
            hold: None,
            homes: Vec::new(),
            hold_ticks: 1_000, // ten seconds holding the full set to win
            reset_at: None,
            elapsed: 0,
        }
    }

    /// Every flag neutral and back on its stand, which is what a fresh round
    /// starts from.
    fn reset_flags(&mut self, ctx: &mut ModeCtx) {
        for i in 0..ctx.world.state.flag_count as usize {
            let home = self.homes.get(i).copied();
            let f = &mut ctx.world.state.flags[i];
            f.team = sim::TEAM_NONE;
            f.carried = 0;
            f.carrier = 0;
            f.cooldown = 0;
            f.held = 0;
            if let Some((x, y)) = home {
                f.x = x;
                f.y = y;
            }
        }
    }
}

impl Mode for Warzone {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        let beat = self.clock.beat(ctx);
        if beat == Beat::Opening {
            self.wins = vec![0; self.teams as usize];
            self.round = 1;
            self.hold = None;
            self.reset_at = None;
            // The room puts the flags back on the map's own stands after this
            // tick, and the map may be a different one, so where they belong
            // is worked out again from where they land.
            self.homes.clear();
        }
        // The whistle tick is still part of the match, so a round completed
        // on it is a round taken rather than one the clock stole.
        if beat != Beat::Waiting {
            self.round_tick(ctx);
        }
        if !self.clock.playing() {
            ctx.banner = result_banner(ctx, &self.wins);
        }
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "warzone"
    }

    fn reopen(&mut self) {
        self.clock.reopen();
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.clock.playing(),
            seconds_left: self.clock.seconds_left(),
            score: self.wins.clone(),
        })
    }
}

impl Warzone {
    /// One tick of the round inside the match: who holds the set, how long
    /// they have held it, and the reset that follows a win.
    fn round_tick(&mut self, ctx: &mut ModeCtx) {
        self.elapsed += 1;
        if self.homes.is_empty() {
            self.homes = (0..ctx.world.state.flag_count as usize)
                .map(|i| (ctx.world.state.flags[i].x, ctx.world.state.flags[i].y))
                .collect();
        }

        if let Some(at) = self.reset_at {
            let left = at.saturating_sub(self.elapsed);
            if left == 0 {
                self.reset_flags(ctx);
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
                let left = self.hold_ticks.saturating_sub(self.elapsed - since);
                if left == 0 {
                    if let Some(w) = self.wins.get_mut(t as usize) {
                        *w += 1;
                    }
                    self.reset_at = Some(self.elapsed + 500);
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
                self.hold = Some((t, self.elapsed));
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
            team_names: names,
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
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

    /// The first person into a room of bots joins the match on the clock.
    ///
    /// This used to open a fresh one for them, on the argument that a whole
    /// match beats the tail of a bot match. What it did instead was throw away
    /// the fight they had just chosen: the menu plays that room behind its
    /// panel and counts its clock down beside the deploy key, so the press
    /// means this match and no other. docs/design/match-game.md: "you join a
    /// room, not a match".
    #[test]
    fn a_person_arriving_mid_match_joins_the_one_being_played() {
        let names = sides();
        let mut w = world_with(&[(0, 3), (1, 1)]);
        let mut m = Melee::new(2, 300, 100);
        for _ in 0..175 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
        }
        assert_eq!(m.match_state().unwrap().seconds_left, 2);
        assert_eq!(m.match_state().unwrap().score, vec![3, 1]);

        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(!c.open_match, "nothing opens at the door");
        assert_eq!(m.match_state().unwrap().seconds_left, 2, "the same clock");
        assert_eq!(m.match_state().unwrap().score, vec![3, 1], "and score");
    }

    /// Unless the mode is told the door is the whistle, which is what a duel
    /// does: the next tick opens a fresh match, whole clock and nothing on
    /// the board.
    #[test]
    fn a_reopened_match_starts_from_nothing_on_the_next_tick() {
        let names = sides();
        let mut w = world_with(&[(0, 3), (1, 1)]);
        let mut m = Melee::new(2, 300, 100);
        for _ in 0..175 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
        }
        assert_eq!(m.match_state().unwrap().score, vec![3, 1]);

        m.reopen();
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(c.open_match, "the room is asked to put everybody home");
        assert!(!c.close_match, "and no podium goes up on the way");
        let state = m.match_state().unwrap();
        assert!(state.playing);
        assert_eq!(state.seconds_left, 3, "a whole clock again");
        assert_eq!(state.score, vec![0, 0], "and nothing on the board");
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
    /// The open arena is the only mode with no clock: it runs forever, sends
    /// no match message and never holds anybody's controls. Every game a zone
    /// ships is a match game, which is what gives each of them a score, an
    /// ending board and a reason to change ground.
    #[test]
    fn the_open_arena_is_the_one_mode_with_no_clock() {
        assert!(FreeForAll.match_state().is_none());
        assert!(Warzone::new(4, 2, 24_000, 1_500).match_state().is_some());
        assert!(Melee::new(2, 300, 100).match_state().is_some());
        assert!(Turf::new(2, 300, 100, 500).match_state().is_some());
    }

    #[test]
    fn a_zone_names_the_mode_and_gets_it() {
        let setup = Setup {
            flags: 0,
            teams: 2,
            match_ticks: 18_000,
            intermission_ticks: 2_500,
            turf_period: 500,
        };
        assert_eq!(build("melee", &setup).name(), "melee");
        assert_eq!(build("warzone", &setup).name(), "warzone");
        assert_eq!(build("turf", &setup).name(), "turf");
        assert_eq!(build("arena", &setup).name(), "arena");
        assert!(exists("melee"), "and the catalog will accept the name");
        assert!(exists("turf"));
    }
}

#[cfg(test)]
mod turf_tests {
    use super::*;

    /// A room with `n` stands in it, owned by nobody yet.
    fn stands(n: usize) -> World {
        let mut w = World::new(5);
        for i in 0..n {
            w.add_flag(500 + i as i32 * 8, 512);
        }
        w
    }

    fn ctx<'a>(world: &'a mut World, names: &'a [String]) -> ModeCtx<'a> {
        ModeCtx {
            world,
            team_names: names,
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
        }
    }

    fn sides() -> Vec<String> {
        vec!["Keel".into(), "Vantage".into()]
    }

    /// The clock pays a point per stand held, every period. Holding two of
    /// four is not a losing position, it is two points a period, which is
    /// what spreads a turf fight over the map.
    #[test]
    fn every_period_pays_a_point_for_each_stand_held() {
        let names = sides();
        let mut w = stands(4);
        w.state.flags[0].team = 0;
        w.state.flags[1].team = 0;
        w.state.flags[2].team = 1;
        // The fourth is loose, and pays nobody.
        let mut m = Turf::new(2, 10_000, 500, 100);

        for _ in 0..100 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().score, vec![2, 1], "one period");

        for _ in 0..200 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().score, vec![6, 3], "three of them");
    }

    /// Taking a stand off the other side is worth two points a period: one
    /// they stop earning and one you start.
    #[test]
    fn taking_a_stand_moves_what_the_next_period_pays() {
        let names = sides();
        let mut w = stands(2);
        w.state.flags[0].team = 0;
        w.state.flags[1].team = 0;
        let mut m = Turf::new(2, 10_000, 500, 100);
        for _ in 0..100 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().score, vec![2, 0]);

        w.state.flags[1].team = 1;
        for _ in 0..100 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().score, vec![3, 1]);
    }

    /// The podium is not a live scoreboard. A stand still held while nobody
    /// is flying must not keep paying under the result.
    #[test]
    fn the_clock_stops_paying_at_the_whistle() {
        let names = sides();
        let mut w = stands(1);
        w.state.flags[0].team = 0;
        let mut m = Turf::new(2, 250, 500, 100);
        for _ in 0..250 {
            m.tick(&mut ctx(&mut w, &names));
        }
        let at_whistle = m.match_state().unwrap();
        assert!(!at_whistle.playing, "the podium is up");
        assert_eq!(at_whistle.score, vec![2, 0]);

        for _ in 0..300 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().score, vec![2, 0], "and it holds");
    }

    /// A fresh match, on the whistle out of the podium, starts at nothing.
    #[test]
    fn the_next_match_starts_from_zero() {
        let names = sides();
        let mut w = stands(1);
        w.state.flags[0].team = 1;
        let mut m = Turf::new(2, 200, 100, 100);
        let mut opens = 0;
        for _ in 0..301 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            if c.open_match {
                opens += 1;
            }
        }
        assert_eq!(opens, 2, "one at the start and one at the whistle");
        let s = m.match_state().unwrap();
        assert!(s.playing);
        assert_eq!(s.score, vec![0, 0]);
    }

    #[test]
    fn the_banner_names_who_took_it_and_calls_a_tie_a_draw() {
        let names = sides();
        let mut w = stands(2);
        w.state.flags[0].team = 1;
        w.state.flags[1].team = 1;
        let mut m = Turf::new(2, 200, 500, 100);
        let mut banner = String::new();
        for _ in 0..201 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            banner = c.banner;
        }
        assert!(banner.contains("Vantage"), "who won: {banner:?}");
        assert!(banner.contains("0 to 4"), "and by what: {banner:?}");

        let mut w = stands(2);
        w.state.flags[0].team = 0;
        w.state.flags[1].team = 1;
        let mut m = Turf::new(2, 200, 500, 100);
        let mut banner = String::new();
        for _ in 0..201 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            banner = c.banner;
        }
        assert_eq!(banner, "a draw");
    }
}

#[cfg(test)]
mod warzone_tests {
    use super::*;

    /// A warzone whose match clock is long enough that the round under test
    /// finishes well inside it. What these are about is the round; the match
    /// wrapped around it has tests of its own.
    fn rounds(flags: u8, teams: u8) -> Warzone {
        Warzone::new(flags, teams, 100_000, 500)
    }

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
            team_names: &[],
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
        }
    }

    #[test]
    fn holding_every_flag_wins_a_round() {
        let mut w = arena_with_flags(3);
        let mut m = rounds(3, 2);
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
        let mut m = rounds(3, 2);
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
        let mut m = rounds(2, 2);
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
        let mut m = rounds(2, 2);
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
        let mut m = rounds(1, 2);
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
        let mut m = rounds(2, 8);
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
        let mut m = rounds(2, 2);
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

    /// Rounds are what a War match is scored in, so the wins are on the wire
    /// as the score and the podium reads them.
    #[test]
    fn the_match_score_is_rounds_taken() {
        let names = vec!["Keel".to_string(), "Vantage".to_string()];
        let mut w = arena_with_flags(2);
        // Long enough for one round to be taken and short enough to finish.
        let mut m = Warzone::new(2, 2, 1_500, 500);
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        let mut banner = String::new();
        for _ in 0..1_500 {
            let mut c = ModeCtx {
                world: &mut w,
                team_names: &names,
                banner: String::new(),
                finished: false,
                open_match: false,
                close_match: false,
            };
            m.tick(&mut c);
            banner = c.banner;
        }
        let state = m.match_state().expect("a war match has a clock");
        assert!(!state.playing, "the podium is up");
        assert_eq!(state.score, vec![0, 1], "one round to Vantage");
        assert!(banner.contains("Vantage takes it"), "{banner:?}");
    }

    /// The whistle out of the podium starts a fresh match: no rounds to
    /// anybody, and the round count back to one.
    #[test]
    fn a_new_match_starts_the_rounds_over() {
        let mut w = arena_with_flags(2);
        let mut m = Warzone::new(2, 2, 1_500, 100);
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        for _ in 0..1_550 {
            m.tick(&mut ctx(&mut w));
        }
        assert_eq!(m.wins, vec![0, 1], "the first match was taken");
        assert!(!m.match_state().unwrap().playing, "and the podium is up");

        // Through the rest of the podium and into the next match.
        let mut opened = false;
        for _ in 0..60 {
            let mut c = ctx(&mut w);
            m.tick(&mut c);
            opened |= c.open_match;
        }
        assert!(opened, "a fresh match opens");
        assert_eq!(m.wins, vec![0, 0], "counting from nothing");
        assert_eq!(m.round, 1);
        assert!(m.match_state().unwrap().playing);
    }
}
