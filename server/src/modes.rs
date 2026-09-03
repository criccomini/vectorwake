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

use crate::sim::World;

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
    /// Set when a duel's round has closed and the next one is due: everybody
    /// back on their own start with a full bar and a full rack, and nothing
    /// left in the air. The room does it, because the arena is the room's,
    /// and it is deliberately not `open_match`: the score is the rounds
    /// already taken and those live on the ships, so a round may not zero a
    /// tally the way a whistle does.
    pub round_reset: bool,
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
    /// Seconds left on whatever the room is counting, and `None` where it is
    /// counting nothing. A match is at most four minutes and an intermission
    /// is fifteen, so a byte is plenty and the client only ever draws whole
    /// seconds of it.
    ///
    /// A flag game spends most of a match with nothing here. It runs until
    /// somebody holds the set, so there is no length for a clock to read
    /// against, and the fifteen seconds that decide it are the only thing up
    /// there worth counting.
    pub seconds_left: Option<u8>,
    /// Kills, rounds or stands per public side, in the order the zone named
    /// them. This is the ledger: the whistle is rated off it, the podium
    /// names its leader, and the pilot log files it.
    pub score: Vec<u16>,
    /// Whether the band reads that score out.
    ///
    /// A flag game says no. Its ledger is a one and a zero, since holding the
    /// set is the whole result, and a pair of numbers saying so at the top of
    /// the window would be the pennants' own answer written out longhand
    /// under the picture of itself.
    pub scored: bool,
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
/// ground and plays another. Every match game needs exactly that and they
/// differ only in what they count, so the phases live here and the score
/// stays with the mode that knows what it means.
///
/// The match phase has a length or does not. A kill game and a duel are
/// played against a clock; a flag game is played until somebody holds the
/// set, and gives the room no answer for how long that will take. Both put
/// up the same podium afterwards.
pub struct Clock {
    /// Ticks a match runs, and `None` where it runs until the mode blows the
    /// whistle itself.
    match_ticks: Option<u32>,
    intermission_ticks: u32,
    /// Ticks left in whichever phase this is, and `None` in a match with no
    /// length: there is nothing to count down.
    left: Option<u32>,
    playing: bool,
    /// The first tick has not run yet, so the room has not opened a match.
    /// Set once, which is what makes a room that has just been built start
    /// playing rather than sit through an intermission it did not earn.
    opened: bool,
}

impl Clock {
    pub fn new(match_ticks: u32, intermission_ticks: u32) -> Self {
        Clock {
            match_ticks: Some(match_ticks.max(1)),
            intermission_ticks: intermission_ticks.max(1),
            left: Some(match_ticks.max(1)),
            playing: true,
            opened: false,
        }
    }

    /// A match with no length, over when the mode says so.
    ///
    /// The podium still runs on a clock, because what it is counting is a
    /// fixed wait rather than a game.
    pub fn open_ended(intermission_ticks: u32) -> Self {
        Clock {
            match_ticks: None,
            intermission_ticks: intermission_ticks.max(1),
            left: None,
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

        if let Some(left) = self.left.as_mut() {
            *left = left.saturating_sub(1);
            if *left == 0 {
                self.playing = !self.playing;
                if self.playing {
                    self.left = self.match_ticks;
                    ctx.open_match = true;
                    beat = Beat::Opening;
                } else {
                    self.left = Some(self.intermission_ticks);
                    ctx.close_match = true;
                    beat = Beat::Ending;
                }
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

    /// Blow the whistle now, with time still on the clock.
    ///
    /// A duel asks for this too, from the other end: a match played to a
    /// number of rounds is over when somebody reaches it, and the clock is
    /// the backstop rather than the referee. A flag game has no backstop at
    /// all and this is the only way its match ever ends. The podium goes up
    /// for its full length either way, exactly as it does when regulation
    /// runs out.
    pub fn finish(&mut self, ctx: &mut ModeCtx) {
        if !self.playing {
            return;
        }
        self.playing = false;
        self.left = Some(self.intermission_ticks);
        ctx.close_match = true;
    }

    /// Whole seconds left in this phase, rounded up so a clock reads 1 for
    /// the last second rather than sitting on 0 while there is still a second
    /// to play in, and `None` in a match with no length.
    pub fn seconds_left(&self) -> Option<u8> {
        self.left
            .map(|left| left.div_ceil(TICKS_PER_SECOND).min(255) as u8)
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

/// And what it says about a game with no numbers in it. A flag match is taken
/// by holding every one of them, so the result is a side and nothing else.
fn won_banner(ctx: &ModeCtx, winner: Option<u8>) -> String {
    match winner {
        Some(t) => format!("{} takes it", ctx.team_name(t)),
        None => String::new(),
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
/// falling back to a default, which is exactly how `arena.mode` came to be a
/// key that parsed and did nothing for months.
pub const NAMES: [&str; 4] = ["arena", "flags", "melee", "duel"];

/// Whether a mode's zone rates the match rather than the death.
///
/// The kill games rate kills: a melee, a duel and free roam are decided by
/// who shot whom, and their ladders stay as they were. A flag game is decided
/// by ground held, so its ladder is moved by the whistle and not by the
/// wreck. See decision 157.
pub fn rated_by_match(name: &str) -> bool {
    name == "flags"
}

pub fn exists(name: &str) -> bool {
    NAMES.contains(&name)
}

/// Everything a mode is built from, which is all of it a zone's own. A
/// two-team flag game with three flags, or a four-a-side melee on a two
/// minute clock, is configuration rather than a rebuild.
pub struct Setup {
    pub flags: u8,
    pub teams: u8,
    /// Ticks a match runs, and ticks of podium between two of them. A flag
    /// game reads only the second: its match has no length.
    pub match_ticks: u32,
    pub intermission_ticks: u32,
    /// Rounds that take a duel. Only Duel reads it.
    pub first_to: u16,
}

/// Rounds a duel is played to where the zone names no number.
///
/// Two, so a match is three rounds at most and a pilot who loses the opening
/// exchange is one round from level rather than watching the rest of a
/// decided fight. See docs/design/zones.md.
pub const DEFAULT_FIRST_TO: u16 = 2;

/// Ticks a round stays open after the death that decided it.
///
/// Two seconds, which is a bomb's flight and is also the respawn delay every
/// zone in the catalog runs, so the loser is still down when the round is
/// filed. It is the whole of the trade rule: a bomb already in the air when
/// its thrower died still lands, still kills, and the round goes to both
/// sides rather than to whichever death the core reported first.
pub const ROUND_CLOSE_TICKS: u32 = 2 * TICKS_PER_SECOND;

/// Build the mode a zone asked for.
pub fn build(name: &str, s: &Setup) -> Box<dyn Mode> {
    let (flags, teams) = (s.flags.max(1), s.teams.max(1));
    match name {
        "flags" => Box::new(Flags::new(flags, teams, s.intermission_ticks.max(1))),
        "melee" => Box::new(Melee::new(
            teams,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
        )),
        "duel" => Box::new(Duel::new(
            teams,
            s.first_to,
            s.match_ticks.max(1),
            s.intermission_ticks.max(1),
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
            scored: true,
        })
    }
}

/// Duel: rounds, and the match goes to the first side to take enough of them.
///
/// A death ends the round rather than the match. Two seconds later both
/// pilots are back on their own starts with a full bar and a full rack, so
/// every round opens as a fair fight instead of handing the survivor a
/// half-hurt opponent. That window is also the trade rule, and it is
/// `ROUND_CLOSE_TICKS` rather than anything this mode decides.
///
/// The score is rounds taken, read off the other side's deaths rather than
/// off your own kills. Both of the cases a player has an opinion about come
/// out right that way: fly into a wall and the round goes across the arena
/// instead of coming off your own tally, and trade, and both sides take one.
/// A kills tally answers neither, which is what melee in a two seat room was
/// doing before this mode existed.
///
/// The match ends when a side reaches `first_to` with nobody level with it,
/// or at the whistle, where the leader takes it and level is a draw. Level at
/// the target plays on, so two rounds each is not a win for either of them.
pub struct Duel {
    teams: u8,
    first_to: u16,
    clock: Clock,
    /// Rounds taken, live while playing and held through the intermission.
    score: Vec<u16>,
    /// The score the round that is closing started from, so the banner can
    /// name who took it without asking the core what just happened.
    from: Vec<u16>,
    /// Ticks left in the window a death opened, and `None` between rounds.
    closing: Option<u32>,
}

impl Duel {
    pub fn new(teams: u8, first_to: u16, match_ticks: u32, intermission_ticks: u32) -> Self {
        Duel {
            teams,
            // A duel to no rounds at all would be decided before anybody
            // flew, so the floor is one rather than a refusal.
            first_to: first_to.max(1),
            clock: Clock::new(match_ticks, intermission_ticks),
            score: vec![0; teams as usize],
            from: vec![0; teams as usize],
            closing: None,
        }
    }

    /// Rounds by side, which is every other side's deaths.
    ///
    /// Summed unsigned, unlike melee's kills, because a death is a death:
    /// there is no self-inflicted one that takes a round off somebody. The
    /// worst a pilot can do to their own score here is nothing.
    fn tally(&self, ctx: &ModeCtx) -> Vec<u16> {
        let mut deaths = vec![0u32; self.teams as usize];
        for sh in ctx.world.state.ships.iter() {
            if sh.active == 0 {
                continue;
            }
            if let Some(n) = deaths.get_mut(sh.team as usize) {
                *n += sh.deaths as u32;
            }
        }
        let all: u32 = deaths.iter().sum();
        deaths
            .into_iter()
            .map(|mine| (all - mine).min(u16::MAX as u32) as u16)
            .collect()
    }

    /// Whether this score ends the match: somebody has the rounds, and
    /// nobody is level with them.
    fn decided(&self) -> bool {
        self.score.iter().any(|n| *n >= self.first_to) && leader(&self.score).is_some()
    }

    /// What the round that is closing did. Both sides took one where they
    /// traded, which is the case the window is held open for.
    fn round_banner(&self, ctx: &ModeCtx) -> String {
        let took: Vec<u8> = (0..self.teams)
            .filter(|t| self.score.get(*t as usize) > self.from.get(*t as usize))
            .collect();
        match took.len() {
            1 => format!("{} takes the round", ctx.team_name(took[0])),
            0 => String::new(),
            _ => "the round is traded".to_string(),
        }
    }
}

impl Mode for Duel {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        let beat = self.clock.beat(ctx);
        match beat {
            // A fresh match counts from nothing. `sim_restart` zeroes the
            // deaths the score is read off, and the room runs it after this
            // returns, so all this has to do is forget the last match.
            Beat::Opening => {
                self.score = vec![0; self.teams as usize];
                self.from = vec![0; self.teams as usize];
                self.closing = None;
            }
            // The whistle tick is still part of the match it ended, which is
            // what makes a bomb already in the air count.
            Beat::Playing | Beat::Ending => self.score = self.tally(ctx),
            Beat::Waiting => {}
        }

        // The window a death opened, run down inside the match only. At the
        // whistle the score already counts every death the window was being
        // held open for, and there is no next round to put anybody back on
        // the ground for, so it lapses rather than firing.
        if beat == Beat::Playing {
            if let Some(left) = self.closing.map(|n| n.saturating_sub(1)) {
                if left > 0 {
                    self.closing = Some(left);
                } else {
                    self.closing = None;
                    if self.decided() {
                        self.clock.finish(ctx);
                    } else {
                        ctx.round_reset = true;
                        self.from = self.score.clone();
                    }
                }
            }
        }

        ctx.banner = if !self.clock.playing() {
            result_banner(ctx, &self.score)
        } else if self.closing.is_some() {
            self.round_banner(ctx)
        } else {
            // Nothing. The band over the top of the screen carries the rounds
            // for both sides, which is the whole score in this room.
            String::new()
        };
    }

    /// The first death of a round opens the window. Every death after it
    /// inside the window is part of the same round, which is what makes a
    /// trade one round rather than two.
    fn on_death(&mut self, ctx: &mut ModeCtx, _victim: u8, _killer: u8) {
        if !self.clock.playing() {
            return;
        }
        // Only the first death of a round opens the window. A second one
        // inside it still scores, which is the whole of what a trade is.
        if self.closing.is_none() {
            self.closing = Some(ROUND_CLOSE_TICKS);
        }
        // Read now rather than on the next tick, so the band and the banner
        // agree about what just happened for the whole of the window.
        self.score = self.tally(ctx);
    }

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "duel"
    }

    fn reopen(&mut self) {
        self.clock.reopen();
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.clock.playing(),
            seconds_left: self.clock.seconds_left(),
            score: self.score.clone(),
            scored: true,
        })
    }
}

/// Flags: hold every one of them at once for fifteen seconds and the match is
/// yours. Then the room stands them back up and deals another.
///
/// The simulation moves flags; this decides what an arrangement of them
/// means, which is the split the original drew between flagcore and fg_wz.
///
/// There is no clock. A flag game runs until somebody holds the set, so the
/// only number worth putting at the top of the window is the fifteen seconds
/// that decide it, and that number is not there most of the time. Losing one
/// flag during the hold takes it away and the next completed set starts it
/// again from fifteen.
///
/// One mode covers both flag zones. Whether a flag can be picked up is
/// `flag_carry`, a byte in the zone file, and it is the entire difference
/// between Capture the Flag, where four flags are gathered and carried home,
/// and Turf, where six stands change hands where they stand. Neither is a
/// different rule about winning. See decision 165, which replaced Turf's
/// payout and Capture the Flag's rounds with this.
pub struct Flags {
    flags: u8,
    /// How many sides there are to win. Four was hardcoded in the leader
    /// search, in the win tally and in the banner, which is fine for the two
    /// the shipped zones have and silently wrong for anything else: a side
    /// above three could never be found holding the set. A one-team zone
    /// gives every pilot their own side, so that ceiling is reachable.
    teams: u8,
    clock: Clock,
    /// The side holding every flag and the ticks they have held them for, and
    /// `None` whenever nobody holds the set.
    hold: Option<(u8, u32)>,
    /// Ticks of unbroken hold that take the match.
    hold_ticks: u32,
    /// Who took the match, kept through the podium so the whistle can be
    /// rated and filed. Forgotten when the next one opens.
    winner: Option<u8>,
}

/// Seconds a side must hold every flag to take the match.
///
/// Long enough that a set completed by one lucky pass across the map is not a
/// match won, short enough to be a thing the other side can be seen racing.
/// It is also the length of the podium that follows, which is a coincidence
/// of two comfortable numbers rather than a rule.
pub const HOLD_SECONDS: u32 = 15;

impl Flags {
    pub fn new(flags: u8, teams: u8, intermission_ticks: u32) -> Self {
        Flags {
            flags,
            teams,
            clock: Clock::open_ended(intermission_ticks),
            hold: None,
            hold_ticks: HOLD_SECONDS * TICKS_PER_SECOND,
            winner: None,
        }
    }

    /// The side holding every flag, if there is one.
    fn holder(&self, ctx: &ModeCtx) -> Option<u8> {
        if self.flags == 0 {
            return None;
        }
        (0..self.teams).find(|&team| ctx.world.flags_held(team) as u8 == self.flags)
    }

    /// One tick of the hold: who has the set, how long they have had it, and
    /// the whistle at the end of it.
    fn hold_tick(&mut self, ctx: &mut ModeCtx) {
        let holder = self.holder(ctx);
        self.hold = match (holder, self.hold) {
            // The same side, one tick longer. A side that completes the set,
            // loses a flag and takes it straight back is a fresh hold: the
            // arm below only survives while `flags_held` says the set is
            // whole on every tick between.
            (Some(t), Some((held, ticks))) if held == t => Some((t, ticks + 1)),
            (Some(t), _) => Some((t, 0)),
            (None, _) => None,
        };
        let Some((team, ticks)) = self.hold else {
            // The pennants say who holds what and there is nothing else to
            // report, so the banner is empty until somebody has the set.
            ctx.banner = String::new();
            return;
        };
        if ticks >= self.hold_ticks {
            self.winner = Some(team);
            self.clock.finish(ctx);
            ctx.banner = won_banner(ctx, self.winner);
            return;
        }
        ctx.banner = format!("{} holds all {} flags", ctx.team_name(team), self.flags);
    }

    /// Seconds left on the hold, which is the only clock this game has and is
    /// there only while somebody has the whole set.
    fn countdown(&self) -> Option<u8> {
        let (_, ticks) = self.hold?;
        let left = self.hold_ticks.saturating_sub(ticks);
        Some(left.div_ceil(TICKS_PER_SECOND).min(255) as u8)
    }

    /// The ledger: a one against the side that took it and a zero against
    /// everybody else. Nobody is shown this. It is what the whistle is rated
    /// off and what the pilot log files, and a flag match has exactly one
    /// thing to say to either.
    fn ledger(&self) -> Vec<u16> {
        (0..self.teams)
            .map(|t| u16::from(self.winner == Some(t)))
            .collect()
    }
}

impl Mode for Flags {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        match self.clock.beat(ctx) {
            // Nothing is read off an opening tick. The room puts everybody
            // home and the flags back on their stands *after* this one, and
            // the ground may be a different map, so what is on the field here
            // is still the match that just ended: reading it started the next
            // match on a countdown the last one had earned.
            Beat::Opening => {
                self.hold = None;
                self.winner = None;
                ctx.banner = String::new();
            }
            // The whistle tick is still part of the match it ended, and the
            // podium's are not: a flag taken while nobody is flying would
            // start a hold against a match that is over.
            Beat::Playing | Beat::Ending => self.hold_tick(ctx),
            Beat::Waiting => ctx.banner = won_banner(ctx, self.winner),
        }
    }

    fn on_death(&mut self, _ctx: &mut ModeCtx, _victim: u8, _killer: u8) {}

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "flags"
    }

    fn reopen(&mut self) {
        self.clock.reopen();
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.clock.playing(),
            // The podium's own clock while it is up, and the hold's while a
            // match is on. They are never both there: the match has no length
            // of its own, so `Clock::seconds_left` answers nothing until the
            // whistle has gone.
            seconds_left: self.clock.seconds_left().or_else(|| self.countdown()),
            score: self.ledger(),
            scored: false,
        })
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
            round_reset: false,
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
        assert_eq!(s.seconds_left, Some(3));
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
        assert_eq!(m.match_state().unwrap().seconds_left, Some(2));
        assert_eq!(m.match_state().unwrap().score, vec![3, 1]);

        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(!c.open_match, "nothing opens at the door");
        assert_eq!(
            m.match_state().unwrap().seconds_left,
            Some(2),
            "the same clock"
        );
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
        assert_eq!(state.seconds_left, Some(3), "a whole clock again");
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

    /// The open arena is the only mode the room sends no match message for:
    /// it runs forever and never holds anybody's controls. Every game a zone
    /// ships is a match game, which is what gives each of them an ending
    /// board and a reason to change ground. A flag game is one of them and
    /// still answers, with a state that spends most of a match saying there
    /// is nothing to count.
    #[test]
    fn the_open_arena_is_the_one_mode_with_no_match() {
        assert!(FreeForAll.match_state().is_none());
        assert!(Melee::new(2, 300, 100).match_state().is_some());
        assert!(Duel::new(2, 2, 300, 100).match_state().is_some());
        let flags = Flags::new(4, 2, 1_500).match_state().expect("a match");
        assert!(flags.playing);
        assert_eq!(flags.seconds_left, None, "and no clock on it");
    }

    #[test]
    fn a_zone_names_the_mode_and_gets_it() {
        let setup = Setup {
            flags: 0,
            teams: 2,
            match_ticks: 18_000,
            intermission_ticks: 2_500,
            first_to: 2,
        };
        assert_eq!(build("melee", &setup).name(), "melee");
        assert_eq!(build("flags", &setup).name(), "flags");
        assert_eq!(build("duel", &setup).name(), "duel");
        assert_eq!(build("arena", &setup).name(), "arena");
        assert!(exists("melee"), "and the catalog will accept the name");
        assert!(exists("flags"));
        assert!(exists("duel"));
    }
}

#[cfg(test)]
mod duel_tests {
    use super::*;

    /// Two seats, a side each, nobody dead yet.
    fn arena() -> World {
        let mut w = World::new(11);
        for team in 0..2u8 {
            let i = w.spawn(0, team, 400 + team as i32 * 200, 500, 0);
            assert!(i >= 0, "a seat");
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
            round_reset: false,
            close_match: false,
        }
    }

    fn sides() -> Vec<String> {
        vec!["Pilot".into(), "Rival".into()]
    }

    /// One tick, answering what the mode asked the room for.
    fn tick(m: &mut Duel, w: &mut World, names: &[String]) -> (bool, bool, String) {
        let mut c = ctx(w, names);
        m.tick(&mut c);
        (c.round_reset, c.close_match, c.banner)
    }

    /// A death on the field, reported to the mode the way the room reports
    /// one: the core has already written the tally.
    fn kill(m: &mut Duel, w: &mut World, names: &[String], victim: u8) {
        w.state.ships[victim as usize].deaths += 1;
        w.state.ships[1 - victim as usize].kills += 1;
        let mut c = ctx(w, names);
        m.on_death(&mut c, victim, 1 - victim);
    }

    /// Run the window out and hand back what the closing tick asked for.
    fn close_round(m: &mut Duel, w: &mut World, names: &[String]) -> (bool, bool) {
        for _ in 0..=ROUND_CLOSE_TICKS {
            let (reset, closed, _) = tick(m, w, names);
            if reset || closed {
                return (reset, closed);
            }
        }
        panic!("the round never closed");
    }

    /// Both pilots dying inside one window, which is one round to each side.
    fn trade(m: &mut Duel, w: &mut World, names: &[String]) {
        kill(m, w, names, 1);
        for _ in 0..50 {
            tick(m, w, names);
        }
        kill(m, w, names, 0);
    }

    fn duel(first_to: u16) -> (Duel, World, Vec<String>) {
        let (mut m, mut w, names) = (Duel::new(2, first_to, 18_000, 1_500), arena(), sides());
        // The opening tick, which is the one that starts the match.
        tick(&mut m, &mut w, &names);
        (m, w, names)
    }

    #[test]
    fn a_death_ends_the_round_two_seconds_later_and_the_round_goes_across() {
        let (mut m, mut w, names) = duel(2);
        kill(&mut m, &mut w, &names, 1);
        assert_eq!(
            m.match_state().unwrap().score,
            vec![1, 0],
            "the round is the other side's death, counted at once"
        );
        let (_, _, banner) = tick(&mut m, &mut w, &names);
        assert_eq!(banner, "Pilot takes the round");

        let (reset, closed) = close_round(&mut m, &mut w, &names);
        assert!(reset, "the room is asked to put both pilots back");
        assert!(!closed, "and the match is not over at one round");
        assert!(m.match_state().unwrap().playing);
    }

    #[test]
    fn a_trade_inside_the_window_gives_both_sides_the_round() {
        let (mut m, mut w, names) = duel(2);
        // A bomb already in the air when its thrower died, landing half a
        // second later. The window is what makes this one round rather than
        // a clean win for whoever the core reported first.
        trade(&mut m, &mut w, &names);
        assert_eq!(m.match_state().unwrap().score, vec![1, 1]);
        let (_, _, banner) = tick(&mut m, &mut w, &names);
        assert_eq!(banner, "the round is traded");

        let (reset, closed) = close_round(&mut m, &mut w, &names);
        assert!(reset && !closed, "level at one, so it plays on");
    }

    #[test]
    fn the_second_round_takes_the_match() {
        let (mut m, mut w, names) = duel(2);
        kill(&mut m, &mut w, &names, 1);
        let (reset, closed) = close_round(&mut m, &mut w, &names);
        assert!(reset && !closed);

        kill(&mut m, &mut w, &names, 1);
        assert_eq!(m.match_state().unwrap().score, vec![2, 0]);
        let (reset, closed) = close_round(&mut m, &mut w, &names);
        assert!(closed, "two rounds and a lead is the match");
        assert!(!reset, "so nobody is put back on the ground for another");
        let state = m.match_state().unwrap();
        assert!(!state.playing, "the podium is up");
        assert_eq!(state.seconds_left, Some(15), "for its whole length");
    }

    /// The shipped duel, per decision 146. One round is the match, and the
    /// intermission that follows is where a rival is dealt.
    #[test]
    fn one_clean_kill_takes_a_duel() {
        let (mut m, mut w, names) = duel(1);
        kill(&mut m, &mut w, &names, 1);
        assert_eq!(m.match_state().unwrap().score, vec![1, 0]);
        let (reset, closed) = close_round(&mut m, &mut w, &names);
        assert!(closed, "one round and a lead is the whole match");
        assert!(!reset, "so nobody is put back on the ground for another");
        assert!(!m.match_state().unwrap().playing);
    }

    /// The freak exchange decision 142 raised against a duel to one round.
    /// `decided` wants a leader rather than a number, so a trade costs a round
    /// and the match goes on, whatever `first_to` is set to.
    #[test]
    fn a_trade_does_not_take_a_duel_to_one_round() {
        let (mut m, mut w, names) = duel(1);
        trade(&mut m, &mut w, &names);
        assert_eq!(m.match_state().unwrap().score, vec![1, 1]);
        let (reset, closed) = close_round(&mut m, &mut w, &names);
        assert!(reset && !closed, "level at one, so it plays on");

        kill(&mut m, &mut w, &names, 0);
        let (_, closed) = close_round(&mut m, &mut w, &names);
        assert!(closed, "and the next clean kill settles it");
        assert_eq!(m.match_state().unwrap().score, vec![1, 2]);
    }

    #[test]
    fn level_at_the_target_plays_on_until_somebody_leads() {
        let (mut m, mut w, names) = duel(2);
        // Two traded rounds reaches the target on both sides at once, which
        // is the only way to get there without somebody leading on the way.
        for _ in 0..2 {
            trade(&mut m, &mut w, &names);
            let (reset, closed) = close_round(&mut m, &mut w, &names);
            assert!(reset && !closed, "level, so nothing is settled");
        }
        assert_eq!(m.match_state().unwrap().score, vec![2, 2]);

        kill(&mut m, &mut w, &names, 1);
        let (_, closed) = close_round(&mut m, &mut w, &names);
        assert!(closed, "three to two is a lead at the target");
        assert_eq!(m.match_state().unwrap().score, vec![3, 2]);
    }

    #[test]
    fn the_whistle_gives_it_to_whoever_leads_and_calls_level_a_draw() {
        // One round taken, and then a clock that runs out on the second.
        let (mut m, mut w, names) = (Duel::new(2, 2, 400, 1_500), arena(), sides());
        tick(&mut m, &mut w, &names);
        kill(&mut m, &mut w, &names, 1);
        close_round(&mut m, &mut w, &names);
        let mut banner = String::new();
        while m.match_state().unwrap().playing {
            let (_, _, said) = tick(&mut m, &mut w, &names);
            banner = said;
        }
        assert_eq!(m.match_state().unwrap().score, vec![1, 0]);
        assert_eq!(banner, "Pilot takes it, 1 to 0");

        // And the same clock over a match nobody scored in.
        let (mut m, mut w, names) = (Duel::new(2, 2, 400, 1_500), arena(), sides());
        tick(&mut m, &mut w, &names);
        let mut banner = String::new();
        while m.match_state().unwrap().playing {
            let (_, _, said) = tick(&mut m, &mut w, &names);
            banner = said;
        }
        assert_eq!(banner, "a draw");
    }

    /// A death landing in the last second of a match is counted, and the
    /// window it opened does not put anybody back on the ground under the
    /// podium that is going up.
    #[test]
    fn a_death_on_the_whistle_scores_and_opens_no_round() {
        let (mut m, mut w, names) = (Duel::new(2, 5, 300, 1_500), arena(), sides());
        tick(&mut m, &mut w, &names);
        while m.match_state().unwrap().seconds_left > Some(1) {
            tick(&mut m, &mut w, &names);
        }
        kill(&mut m, &mut w, &names, 1);
        let mut reset_asked = false;
        for _ in 0..ROUND_CLOSE_TICKS + 10 {
            let (reset, _, _) = tick(&mut m, &mut w, &names);
            reset_asked |= reset;
        }
        assert!(!reset_asked, "no round opens under a podium");
        assert_eq!(
            m.match_state().unwrap().score,
            vec![1, 0],
            "and the death still counted"
        );
    }

    #[test]
    fn a_fresh_match_forgets_the_rounds_and_the_window() {
        let (mut m, mut w, names) = duel(2);
        kill(&mut m, &mut w, &names, 1);
        assert_eq!(m.match_state().unwrap().score, vec![1, 0]);

        // What a seat changing hands does, per decision 141.
        m.reopen();
        // The room runs `sim_restart` after the opening tick, so the tallies
        // the score is read off go with it.
        for sh in w.state.ships.iter_mut() {
            sh.kills = 0;
            sh.deaths = 0;
        }
        let (reset, closed, _) = tick(&mut m, &mut w, &names);
        assert!(!reset && !closed);
        let state = m.match_state().unwrap();
        assert!(state.playing);
        assert_eq!(state.score, vec![0, 0]);
        assert_eq!(state.seconds_left, Some(180), "a whole clock");

        // And the window the old match's death opened does not fire into it.
        let mut reset_asked = false;
        for _ in 0..ROUND_CLOSE_TICKS + 10 {
            let (reset, _, _) = tick(&mut m, &mut w, &names);
            reset_asked |= reset;
        }
        assert!(!reset_asked);
    }

    /// Flying into a wall is a round for the pilot across the arena rather
    /// than a point off your own tally, which is the case a kills score gets
    /// backwards in a room of two.
    #[test]
    fn a_pilot_who_kills_themselves_hands_the_round_across() {
        let (mut m, mut w, names) = duel(2);
        w.state.ships[0].deaths += 1;
        w.state.ships[0].kills -= 1;
        let mut c = ctx(&mut w, &names);
        m.on_death(&mut c, 0, 0);
        drop(c);
        assert_eq!(m.match_state().unwrap().score, vec![0, 1]);
    }
}

#[cfg(test)]
mod flag_tests {
    use super::*;

    /// A room with `n` flags in it, on stands, owned by nobody yet.
    fn stands(n: usize) -> World {
        let mut w = World::new(3);
        let spots = [
            (486, 486),
            (538, 486),
            (538, 538),
            (486, 538),
            (512, 512),
            (512, 486),
        ];
        for spot in spots.iter().take(n) {
            w.add_flag(spot.0, spot.1);
        }
        w
    }

    /// A game with a short podium, so a test can run through one and into the
    /// match after it without a thousand ticks of waiting.
    fn game(flags: u8, teams: u8) -> Flags {
        Flags::new(flags, teams, 100)
    }

    fn ctx<'a>(world: &'a mut World, names: &'a [String]) -> ModeCtx<'a> {
        ModeCtx {
            world,
            team_names: names,
            banner: String::new(),
            finished: false,
            open_match: false,
            round_reset: false,
            close_match: false,
        }
    }

    fn sides() -> Vec<String> {
        vec!["Keel".into(), "Vantage".into()]
    }

    /// Ticks of hold that take a match, which is what every count in here is
    /// measured against.
    const HOLD: usize = (HOLD_SECONDS * TICKS_PER_SECOND) as usize;

    /// One tick to open the match, which reads nothing off the field: in a
    /// room the flags are stood back up after it. Every count below starts
    /// from the tick after this one.
    fn open(m: &mut Flags, w: &mut World, names: &[String]) {
        m.tick(&mut ctx(w, names));
    }

    #[test]
    fn a_match_has_no_clock_until_somebody_holds_the_set() {
        let names = sides();
        let mut w = stands(3);
        let mut m = game(3, 2);
        for _ in 0..1_000 {
            m.tick(&mut ctx(&mut w, &names));
        }
        let s = m.match_state().unwrap();
        assert!(s.playing, "and it is still going");
        assert_eq!(s.seconds_left, None, "nothing is being counted");
        assert!(!s.scored, "and there is no score to read");
    }

    #[test]
    fn holding_every_flag_for_fifteen_seconds_takes_the_match() {
        let names = sides();
        let mut w = stands(3);
        let mut m = game(3, 2);
        open(&mut m, &mut w, &names);
        for i in 0..3 {
            w.state.flags[i].team = 1;
        }
        // The set has to be held, not merely completed.
        m.tick(&mut ctx(&mut w, &names));
        assert!(m.match_state().unwrap().playing, "not on the first tick");
        for _ in 0..HOLD - 1 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert!(m.match_state().unwrap().playing, "nor a tick early");
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(c.close_match, "the whistle goes on the fifteenth second");
        let s = m.match_state().unwrap();
        assert!(!s.playing, "and the podium is up");
        assert_eq!(s.score, vec![0, 1], "with the match against Vantage");
    }

    /// The countdown is the whole clock this game has: it appears when the
    /// set is completed, reads fifteen, and runs down to the whistle.
    #[test]
    fn the_countdown_starts_at_fifteen_and_runs_out() {
        let names = sides();
        let mut w = stands(2);
        let mut m = game(2, 2);
        open(&mut m, &mut w, &names);
        for i in 0..2 {
            w.state.flags[i].team = 0;
        }
        m.tick(&mut ctx(&mut w, &names));
        assert_eq!(m.match_state().unwrap().seconds_left, Some(15));
        for _ in 0..TICKS_PER_SECOND {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().seconds_left, Some(14));
        for _ in 0..HOLD - TICKS_PER_SECOND as usize - 2 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert_eq!(m.match_state().unwrap().seconds_left, Some(1), "the last");
    }

    /// Taking one flag back during the countdown takes the countdown away.
    #[test]
    fn losing_one_flag_stops_the_countdown() {
        let names = sides();
        let mut w = stands(3);
        let mut m = game(3, 2);
        for i in 0..3 {
            w.state.flags[i].team = 0;
        }
        for _ in 0..500 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert!(m.match_state().unwrap().seconds_left.is_some());

        w.state.flags[2].team = 1; // stolen back
        m.tick(&mut ctx(&mut w, &names));
        assert_eq!(
            m.match_state().unwrap().seconds_left,
            None,
            "no clock while the set is broken"
        );

        // And the hold that was five seconds in does not resume where it was:
        // retaking the flag starts the whole fifteen again.
        w.state.flags[2].team = 0;
        m.tick(&mut ctx(&mut w, &names));
        assert_eq!(m.match_state().unwrap().seconds_left, Some(15));
        for _ in 0..HOLD - 2 {
            m.tick(&mut ctx(&mut w, &names));
        }
        assert!(
            m.match_state().unwrap().playing,
            "a whole hold from scratch"
        );
    }

    #[test]
    fn a_simultaneous_change_of_flag_owner_restarts_the_hold() {
        let names = sides();
        let mut w = stands(2);
        let mut m = game(2, 2);
        for i in 0..2 {
            w.state.flags[i].team = 0;
        }
        for _ in 0..HOLD / 2 {
            m.tick(&mut ctx(&mut w, &names));
        }
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        assert_eq!(m.match_state().unwrap().seconds_left, Some(8), "halfway");
        m.tick(&mut ctx(&mut w, &names));
        assert_eq!(
            m.match_state().unwrap().seconds_left,
            Some(15),
            "the new side gets its own full hold"
        );
    }

    #[test]
    fn a_side_above_three_can_win() {
        // Four sides were hardcoded in the leader search. A free-for-all
        // gives every pilot their own side, so a zone with flags and
        // `teams = 1` had matches only ships zero to three could ever take,
        // and a win by ship five was tallied against ship one's row.
        let names = sides();
        let mut w = stands(2);
        let mut m = game(2, 8);
        open(&mut m, &mut w, &names);
        for i in 0..2 {
            w.state.flags[i].team = 5;
        }
        for _ in 0..HOLD + 1 {
            m.tick(&mut ctx(&mut w, &names));
        }
        let s = m.match_state().unwrap();
        assert!(!s.playing, "side five holding the set takes it");
        assert_eq!(s.score[5], 1);
        assert_eq!(s.score[1], 0, "and it is not credited to side one");
    }

    #[test]
    fn a_disconnected_carrier_drops_the_flag_before_it_counts() {
        let names = sides();
        let mut w = stands(1);
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
        let mut m = game(1, 2);
        open(&mut m, &mut w, &names);
        m.tick(&mut ctx(&mut w, &names));

        assert_eq!(w.state.flags[0].carried, 0);
        assert_eq!(w.state.flags[0].carrier, 0);
        // Still theirs, and still on the fifteen seconds it has just started:
        // a flag put down by a disconnect is not a flag taken back.
        assert_eq!(w.state.flags[0].team, 0);
        assert_eq!(m.match_state().unwrap().seconds_left, Some(15));
    }

    /// The podium is not a live board. A set still gathered while nobody is
    /// flying must not start a hold against a match that is over.
    #[test]
    fn the_podium_counts_itself_down_and_nothing_else() {
        let names = sides();
        let mut w = stands(2);
        let mut m = game(2, 2);
        open(&mut m, &mut w, &names);
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        for _ in 0..HOLD + 1 {
            m.tick(&mut ctx(&mut w, &names));
        }
        let s = m.match_state().unwrap();
        assert!(!s.playing, "the podium is up");
        assert_eq!(s.seconds_left, Some(1), "counting to the next match");
        assert_eq!(s.score, vec![0, 1], "and the result holds");
    }

    /// A fresh match, on the whistle out of the podium, starts from nothing.
    #[test]
    fn the_next_match_starts_from_nothing() {
        let names = sides();
        let mut w = stands(2);
        let mut m = game(2, 2);
        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        let mut opens = 0;
        for _ in 0..HOLD + 102 {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            opens += u32::from(c.open_match);
        }
        assert_eq!(opens, 2, "one at the start and one out of the podium");
        let s = m.match_state().unwrap();
        assert!(s.playing);
        assert_eq!(s.score, vec![0, 0], "nobody has taken this one");
        // And nothing carried across the whistle, though the flags in this
        // world are still gathered: an opening tick reads nothing, because
        // the room stands them back up after it. That half is
        // `a_flag_match_ends_on_the_hold_and_the_next_one_opens_neutral` in
        // main.rs, which has a room to do it.
        assert_eq!(
            s.seconds_left, None,
            "the hold that took the last match is not still running"
        );
    }

    #[test]
    fn the_banner_names_the_side_holding_the_set_and_the_one_that_took_it() {
        let names = sides();
        let mut w = stands(2);
        let mut m = game(2, 2);
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert_eq!(c.banner, "", "nothing to say while the set is loose");

        for i in 0..2 {
            w.state.flags[i].team = 1;
        }
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert_eq!(c.banner, "Vantage holds all 2 flags");

        let mut banner = String::new();
        for _ in 0..HOLD {
            let mut c = ctx(&mut w, &names);
            m.tick(&mut c);
            banner = c.banner;
        }
        assert_eq!(banner, "Vantage takes it");
    }
}
