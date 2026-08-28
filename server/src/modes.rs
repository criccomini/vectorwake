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
use std::collections::HashMap;

pub struct ModeCtx<'a> {
    pub world: &'a mut World,
    /// The seats a mode may count this tick: every occupied ship, less any
    /// the room does not consider ready yet. Match modes use this snapshot to
    /// decide whether the opponents a life needs are actually on the field.
    pub seats: &'a [u8],
    /// What each of those seats is called, in no particular order. A duel
    /// files a leg naming whoever was across the arena, and cannot ask the
    /// room for a name after the fact: the fight is over in seconds and the
    /// seat goes to whoever is next.
    pub seat_names: &'a [(u8, &'a str)],
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

/// Simulation ticks in one second, which is the unit every clock in here is
/// counted in and every clock out of here is reported in.
pub const TICKS_PER_SECOND: u32 = 100;

pub const DEFAULT_DUEL_FIRST_TO: u16 = 1;

/// How long a duel keeps flying after the death that decides it.
///
/// Two seconds is a bomb's flight, and the pilot who fired one is not safe
/// from it: a kill that opens this window and a death inside it are a draw
/// rather than a win. It is also the zone's respawn delay, so the pilot who
/// went down is still down when the fight is filed.
pub const DUEL_DEATH_PAUSE_TICKS: u32 = 2 * TICKS_PER_SECOND;

/// How long a duel room holds its second seat open for a person before the
/// arena settles for a house pilot.
///
/// Ten seconds. Long enough that two people pressing play within a breath of
/// each other meet, short enough that somebody alone on the zone is not left
/// looking at an empty room wondering whether it is broken.
///
/// It lives here rather than beside the door that acts on it because two
/// things read it. The arena decides when to ask for a bot, and the room says
/// how much of the wait is left, which is the number a pilot watching an empty
/// arena is owed.
///
/// It is not the only chance at a person. A human arriving later takes the
/// seat from the bot, which is what `Room::join` already does when a room is
/// full of AI and somebody is at the door.
pub const DUEL_HOLD_TICKS: u32 = 10 * TICKS_PER_SECOND;

/// The rules one completed duel is settled under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DuelRules {
    /// Deaths needed to take a fight. Clamped to one when the mode starts.
    pub first_to: u16,
}

impl Default for DuelRules {
    fn default() -> Self {
        Self {
            first_to: DEFAULT_DUEL_FIRST_TO,
        }
    }
}

/// How one finished fight ended, from the side of the pilot whose card it is.
/// The byte is what rides the wire, so the values are pinned rather than
/// derived from the declaration order.
///
/// `Won` is spelled `Cleared` on the wire for no reason worth keeping; the
/// byte has been 1 since the first Ladder and renaming it here would be a
/// protocol change for a word.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LegResult {
    Lost,
    Cleared,
    Drawn,
}

impl LegResult {
    pub fn to_byte(self) -> u8 {
        match self {
            LegResult::Lost => 0,
            LegResult::Cleared => 1,
            LegResult::Drawn => 2,
        }
    }
}

/// A call sign as a leg keeps it.
///
/// Fixed width rather than a `String`, because `DuelState` is a snapshot the
/// room copies whole out of the mode for every pilot it sends a clock to. A
/// heap string in it would make each of those a clone, and the widest thing
/// that can land here is a name the meta-layer already caps at `MAX` bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct CallSign {
    bytes: [u8; Self::MAX],
    len: u8,
}

impl CallSign {
    pub const MAX: usize = 24;

    /// Truncated on a character boundary, so a name too long for the buffer
    /// loses its tail rather than becoming bytes nothing can decode.
    pub fn new(name: &str) -> Self {
        let mut end = name.len().min(Self::MAX);
        while end > 0 && !name.is_char_boundary(end) {
            end -= 1;
        }
        let mut bytes = [0u8; Self::MAX];
        bytes[..end].copy_from_slice(&name.as_bytes()[..end]);
        Self {
            bytes,
            len: end as u8,
        }
    }

    pub fn as_str(&self) -> &str {
        // Written only through `new`, which cuts on a boundary of a string
        // that was already valid.
        std::str::from_utf8(&self.bytes[..self.len as usize]).unwrap_or("")
    }
}

/// One finished fight on one pilot's card.
///
/// An evening here is a string of ten second fights, so the thing a pilot
/// wants back is the shape of how it went: who they took, who took them, how
/// long each one ran. The room is the only thing that sees all of that, so it
/// keeps it.
///
/// The opponent's name is captured here rather than looked up when the board
/// draws, because by then they may have left: a fight is over in seconds and
/// the seat across the arena is handed to whoever is next.
///
/// Void fights are not legs. An opponent who leaves mid-fight files no result,
/// and a log that recorded it would be a log of things that did not count.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DuelLeg {
    /// Who was across the arena. Empty only for a leg filed with nobody
    /// seated there, which the mode does not do.
    pub rival: CallSign,
    pub result: LegResult,
    /// How long the fight lasted, in whole seconds, rounded the way the clock
    /// rounds. Bounded by the match timer, which a drawn leg reads exactly.
    pub seconds: u16,
}

impl Default for DuelLeg {
    fn default() -> Self {
        Self {
            rival: CallSign::default(),
            result: LegResult::Lost,
            seconds: 0,
        }
    }
}

/// How many finished legs a pilot's card carries. The log rides in every clock
/// packet, so it is a fixed window rather than a growing list: a long evening
/// is bounded at the most recent fights and the total count says what fell off
/// the end.
///
/// Five, because five is what the board draws.
pub const DUEL_LOG_LEGS: usize = 5;

/// What one pilot has done in this room, which is what their card is about.
///
/// Held per seat rather than per room, because a duel has two pilots in it and
/// each of them has their own evening. The room used to hold exactly one of
/// these, which worked only while the other seat was guaranteed to be a bot
/// nobody was drawing a card for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DuelRun {
    pub streak: u32,
    /// The longest streak this pilot has had here, which is the reading that
    /// survives a broken one.
    pub best_streak: u32,
    /// Fights finished in total, which is larger than `logged` once an evening
    /// outlives the window.
    pub legs: u32,
    /// Finished fights, oldest first, most recent last.
    pub log: [DuelLeg; DUEL_LOG_LEGS],
    /// How many of `log` are filled.
    pub logged: u8,
}

impl Default for DuelRun {
    fn default() -> Self {
        Self {
            streak: 0,
            best_streak: 0,
            legs: 0,
            log: [DuelLeg::default(); DUEL_LOG_LEGS],
            logged: 0,
        }
    }
}

impl DuelRun {
    /// File a finished fight. The window keeps the most recent legs, so an
    /// evening long enough to fill it drops its oldest rather than its newest:
    /// what a pilot is looking back at is the stretch they are in.
    fn file(&mut self, result: LegResult, rival: &str, seconds: u16) {
        let leg = DuelLeg {
            rival: CallSign::new(rival),
            result,
            seconds,
        };
        self.legs = self.legs.saturating_add(1);
        let logged = self.logged as usize;
        if logged == DUEL_LOG_LEGS {
            self.log.rotate_left(1);
            self.log[DUEL_LOG_LEGS - 1] = leg;
        } else {
            self.log[logged] = leg;
            self.logged += 1;
        }
        match result {
            LegResult::Cleared => {
                self.streak = self.streak.saturating_add(1);
                self.best_streak = self.best_streak.max(self.streak);
            }
            // A draw moves no rung and, now that there are no rungs, still
            // breaks nothing: nobody won it, so nobody's run ended on it.
            LegResult::Drawn => {}
            LegResult::Lost => self.streak = 0,
        }
    }
}

/// A structured duel snapshot for one viewer: what the room is doing, and the
/// card of whichever seat is reading it.
///
/// Per viewer rather than per room, because the two halves answer to different
/// people. A watcher gets the room's half and an empty card.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DuelState {
    pub playing: bool,
    /// The room is holding for a second pilot rather than counting down.
    pub waiting: bool,
    /// The reader's own evening in this room.
    pub run: DuelRun,
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
pub const NAMES: [&str; 4] = ["arena", "warzone", "duel", "melee"];

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
    pub duel: DuelRules,
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
        "duel" => Box::new(Duel::new(
            s.duel,
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
    /// One death, in the order the tick that produced it emitted them. A mode
    /// that decides a whole result on a death has to be indifferent to that
    /// order, because two ships killing each other is one exchange and the
    /// core reports it as two events: a duel answers by holding the fight
    /// open for a window rather than filing it on the first of the two.
    fn on_death(&mut self, ctx: &mut ModeCtx, victim: u8, killer: u8);
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
    /// Structured duel state for one viewer, or for a watcher when no seat is
    /// named. Other modes return none, so callers can ask through the common
    /// trait without downcasting a mode object.
    fn duel_state(&self, _viewer: Option<u8>) -> Option<DuelState> {
        None
    }
    /// A room went from bots only to holding a person. A mode whose contest is
    /// that person's own starts it over for them and answers true, which is
    /// the room's cue to drop the result its podium is holding: the match that
    /// produced it is not the one anybody is about to play.
    ///
    /// Melee answers false, and that is the rule rather than an omission. A
    /// player deploys from a menu that is playing the fight they are about to
    /// be in, and starting another one at the door throws away the one they
    /// chose. docs/design/match-game.md: "you join a room, not a match".
    fn first_human(&mut self) -> bool {
        false
    }
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
            seconds_left: self.left.div_ceil(TICKS_PER_SECOND).min(255) as u8,
            score: self.score.clone(),
        })
    }
}

/// A duel in its last two seconds: decided, and still being flown.
///
/// The fight belongs to whoever the deciding death named, unless the other
/// ship goes down before the window runs out, in which case it belongs to
/// nobody. Killing somebody and dying to the shot they had already fired is a
/// trade, and it used to be scored as a clean win because the fight was filed
/// on the first of the two deaths, in a room that stopped listening before the
/// second one landed.
#[derive(Clone, Copy, Debug)]
struct Settling {
    /// The side the fight goes to if nothing else happens.
    winner: usize,
    /// Ticks left before that is filed.
    left: u32,
}

/// Who a fight is between, captured when it opens.
///
/// Held rather than read back off the seats, because a fight outlives them: a
/// pilot who leaves a decided fight has still lost it, and the card the winner
/// keeps has to name somebody who is no longer in the room. Reading the seats
/// at filing time meant a fight abandoned inside its own draw window was filed
/// against nobody, on nobody's card.
#[derive(Clone, Copy, Debug)]
struct Bout {
    /// Each side's ship, indexed by the side it is on.
    ships: [u8; 2],
    /// And what that pilot is called.
    names: [CallSign; 2],
}

/// Duel: two pilots, one life each, first to a configured score.
///
/// Both seats are the same kind of thing. Whoever is in them is whoever the
/// door sent: a person paired against another person of about their rating
/// where one was available, and a house pilot of about their rating where one
/// was not. Nothing in here can tell those apart, and nothing in here should:
/// a duel is two ships and a clock, and which of them has somebody breathing
/// behind it is the door's business.
///
/// That is the whole of what replaced the Ladder. This mode used to be a solo
/// climb through eight authored opponents in a fixed order, seated by rung,
/// with a run that persisted per account. See decision 92.
///
/// A fight is not filed on the death that decides it. The arena keeps running
/// for `DUEL_DEATH_PAUSE_TICKS` first, and a second death inside that window
/// draws it: see `Settling`.
pub struct Duel {
    rules: DuelRules,
    match_ticks: u32,
    intermission_ticks: u32,
    left: u32,
    playing: bool,
    opened: bool,
    /// Deaths by side, in the order the zone names its two.
    score: [u16; 2],
    /// The death that ended the fight, waiting out its draw window. `None`
    /// during an ordinary fight and from the whistle onwards.
    settling: Option<Settling>,
    interrupted: bool,
    /// Both seats were filled on the last tick, which is what a departure is
    /// measured against.
    paired: bool,
    /// Who the fight on the field is between. `None` between fights.
    bout: Option<Bout>,
    /// Each seat's own evening. Keyed by ship, and dropped when that ship
    /// leaves: an evening belongs to the pilot who flew it, and the next
    /// person into the seat is not standing where they were.
    runs: HashMap<u8, DuelRun>,
}

impl Duel {
    pub fn new(mut rules: DuelRules, match_ticks: u32, intermission_ticks: u32) -> Self {
        rules.first_to = rules.first_to.max(1);
        Self {
            rules,
            match_ticks: match_ticks.max(1),
            intermission_ticks: intermission_ticks.max(1),
            left: match_ticks.max(1),
            playing: false,
            opened: false,
            score: [0, 0],
            settling: None,
            interrupted: false,
            paired: false,
            bout: None,
            runs: HashMap::new(),
        }
    }

    /// The two ships in the fight, and which side each is on.
    ///
    /// The only supported field shape is exactly two occupied seats on two
    /// different sides. An accidental third seat must not turn an unrelated
    /// death into somebody's result, and two ships that the room has put on
    /// one side are not opponents.
    fn opponents(ctx: &ModeCtx) -> Option<[(u8, usize); 2]> {
        let mut seats = ctx.seats.iter().copied();
        let first = seats.next()?;
        let second = seats.next()?;
        if seats.next().is_some() {
            return None;
        }
        let side_of = |ship: u8| {
            ctx.world
                .state
                .ships
                .get(ship as usize)
                .map(|s| s.team as usize)
                .filter(|team| *team < 2)
        };
        let (a, b) = (side_of(first)?, side_of(second)?);
        (a != b).then_some([(first, a), (second, b)])
    }

    fn name_of<'a>(ctx: &ModeCtx<'a>, ship: u8) -> &'a str {
        ctx.seat_names
            .iter()
            .find_map(|(seat, name)| (*seat == ship).then_some(*name))
            .unwrap_or_default()
    }

    /// Take the room back to the edge a fight starts from: nothing flying, the
    /// full clock, and both seats waited on.
    fn reopen(&mut self) {
        self.playing = false;
        self.left = self.match_ticks;
        self.score = [0, 0];
        self.settling = None;
        self.interrupted = false;
        self.paired = false;
        self.bout = None;
        self.opened = false;
    }

    fn begin_fight(&mut self, ctx: &ModeCtx) {
        let Some(pair) = Self::opponents(ctx) else {
            return;
        };
        let mut bout = Bout {
            ships: [0; 2],
            names: [CallSign::default(); 2],
        };
        for (ship, side) in pair {
            bout.ships[side] = ship;
            bout.names[side] = CallSign::new(Self::name_of(ctx, ship));
        }
        self.bout = Some(bout);
        self.playing = true;
        self.left = self.match_ticks;
        self.score = [0, 0];
        self.settling = None;
        self.interrupted = false;
        self.paired = true;
    }

    /// File the fight on both cards, each from its own side.
    ///
    /// `winner` is a side, or `None` for a draw. The seconds come off the
    /// clock rather than being counted beside it: `left` moves only while both
    /// seats are filled, and this runs while the fight is still live, before
    /// the intermission clock takes `left` over, so the difference is exactly
    /// what was flown. That includes the window a decided fight is held open
    /// for, because the room is live through it and the pilots are still
    /// flying. A fight drawn at the whistle files the whole match timer.
    fn file_fight(&mut self, winner: Option<usize>, ctx: &mut ModeCtx) {
        if !self.playing {
            return;
        }
        let flown = self.match_ticks.saturating_sub(self.left);
        let seconds = flown.div_ceil(TICKS_PER_SECOND).min(u16::MAX as u32) as u16;
        if let Some(bout) = self.bout {
            for side in 0..2 {
                let result = match winner {
                    None => LegResult::Drawn,
                    Some(w) if w == side => LegResult::Cleared,
                    Some(_) => LegResult::Lost,
                };
                self.runs.entry(bout.ships[side]).or_default().file(
                    result,
                    bout.names[1 - side].as_str(),
                    seconds,
                );
            }
        }
        self.playing = false;
        self.left = self.intermission_ticks;
        self.settling = None;
        self.interrupted = false;
        self.bout = None;
        ctx.close_match = true;
    }

    /// A seat has gone. File the fight if the window already decided it, and
    /// void it if it did not.
    ///
    /// Whoever left a decided fight had lost it before they went, and the only
    /// thing its window could still have changed is a draw, which needs both
    /// pilots on the field. Voiding it instead would hand a win back on an
    /// opponent that dropped in the two seconds after it, and would let a
    /// pilot who has just died dodge the loss by pulling the plug.
    fn seat_gone(&mut self, ctx: &mut ModeCtx) {
        match self.settling {
            Some(settling) => self.file_fight(Some(settling.winner), ctx),
            None => self.void_fight(ctx),
        }
    }

    fn void_fight(&mut self, ctx: &mut ModeCtx) {
        if !self.playing {
            return;
        }
        self.playing = false;
        self.left = self.intermission_ticks;
        self.score = [0, 0];
        self.settling = None;
        self.interrupted = true;
        self.paired = false;
        self.bout = None;
        ctx.abort_match = true;
    }

    /// The one line the client puts under the band, and only what the board
    /// behind the band cannot already say.
    ///
    /// An ordinary fight gets no banner: the score is on either side of the
    /// clock and first-to is a rule of the mode that never moves. Nor does an
    /// ordinary result, which is the top row of the card, saying who and won,
    /// lost or drew.
    ///
    /// What is left is what nothing else says: that the fight was voided
    /// because the other seat emptied under it.
    fn banner(&self) -> String {
        if self.interrupted && !self.playing && self.opened {
            "Opponent left. Replaying that fight".to_string()
        } else {
            String::new()
        }
    }
}

impl Mode for Duel {
    fn tick(&mut self, ctx: &mut ModeCtx) {
        let was_paired = self.paired;
        let paired = Self::opponents(ctx).is_some();
        self.paired = paired;
        if !self.opened {
            self.playing = false;
            self.left = self.match_ticks;
            if paired {
                self.opened = true;
                self.begin_fight(ctx);
                ctx.open_match = true;
            }
        } else if self.playing {
            if was_paired && !paired {
                self.seat_gone(ctx);
            } else if paired {
                self.left = self.left.saturating_sub(1);
                if let Some(settling) = self.settling {
                    // A fight that has already been decided plays its window
                    // out before it is filed, and the whistle does not reach
                    // past it: the death named the winner, and the only thing
                    // that can still change the answer is the other pilot
                    // dying too.
                    let left = settling.left.saturating_sub(1);
                    if left == 0 {
                        self.file_fight(Some(settling.winner), ctx);
                    } else {
                        self.settling = Some(Settling { left, ..settling });
                    }
                } else if self.left == 0 {
                    // The whistle settles a fight the pilots did not: whoever
                    // is ahead takes it, and a fight nobody has scored in is a
                    // draw, which breaks no streak.
                    let winner = match self.score[0].cmp(&self.score[1]) {
                        std::cmp::Ordering::Greater => Some(0),
                        std::cmp::Ordering::Less => Some(1),
                        std::cmp::Ordering::Equal => None,
                    };
                    self.file_fight(winner, ctx);
                }
            }
        } else {
            self.left = self.left.saturating_sub(1);
            if self.left == 0 && paired {
                self.begin_fight(ctx);
                ctx.open_match = true;
            }
        }
        ctx.banner = self.banner();
    }

    fn on_death(&mut self, ctx: &mut ModeCtx, victim: u8, _killer: u8) {
        if !self.playing {
            return;
        }
        let Some(bout) = self.bout else {
            return;
        };
        let Some(down) = (0..2).find(|side| bout.ships[*side] == victim) else {
            return;
        };
        // A death scores for the other side, which is the side that is still
        // flying. Ships, not kills: a duel is decided by who is left.
        let scored = 1 - down;
        self.score[scored] = self.score[scored].saturating_add(1);
        if let Some(settling) = self.settling {
            // The other ship went down inside the window the deciding death
            // opened. Neither pilot came out of the fight, so neither of them
            // took it, and that holds whichever order the two deaths arrive
            // in, including both on one tick.
            if settling.winner != scored {
                self.file_fight(None, ctx);
            }
        } else if self.score[scored] >= self.rules.first_to {
            self.settling = Some(Settling {
                winner: scored,
                left: DUEL_DEATH_PAUSE_TICKS,
            });
        }
        ctx.banner = self.banner();
    }

    /// A departure voids the fight unless it was already decided: see
    /// `seat_gone`. The leaver's card goes with them, because an evening
    /// belongs to the pilot who flew it and the next person into that seat is
    /// not standing where they were. Whoever is left keeps theirs and fights
    /// whoever the door sends next.
    fn on_departure(&mut self, ctx: &mut ModeCtx, ship: u8, _bot: bool) {
        self.seat_gone(ctx);
        self.runs.remove(&ship);
        ctx.banner = self.banner();
    }

    #[cfg(test)]
    fn name(&self) -> &'static str {
        "duel"
    }

    fn match_state(&self) -> Option<MatchState> {
        Some(MatchState {
            playing: self.playing,
            seconds_left: self.left.div_ceil(TICKS_PER_SECOND).min(255) as u8,
            score: self.score.to_vec(),
        })
    }

    /// A room that was two bots keeping the zone playing has just been given
    /// to somebody. Their fight starts now rather than partway through one
    /// they did not join, and the podium the room is holding is about a match
    /// they were not in.
    fn first_human(&mut self) -> bool {
        self.runs.clear();
        self.reopen();
        true
    }

    fn duel_state(&self, viewer: Option<u8>) -> Option<DuelState> {
        Some(DuelState {
            playing: self.playing,
            // Waiting rather than counting down: the room has not opened, or
            // it has and the seat across the arena is empty. The client draws
            // dashes for the clock through it, because there is no fight for
            // one to be about.
            waiting: !self.playing && (!self.opened || !self.paired),
            run: viewer
                .and_then(|ship| self.runs.get(&ship).copied())
                .unwrap_or_default(),
        })
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
            seat_names: &[],
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

        assert!(!m.first_human(), "melee has no fresh start to make");
        let mut c = ctx(&mut w, &names);
        m.tick(&mut c);
        assert!(!c.open_match, "nothing opens at the door");
        assert_eq!(m.match_state().unwrap().seconds_left, 2, "the same clock");
        assert_eq!(m.match_state().unwrap().score, vec![3, 1], "and score");
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
            duel: DuelRules::default(),
        };
        assert_eq!(build("melee", &setup).name(), "melee");
        assert_eq!(build("warzone", &setup).name(), "warzone");
        assert_eq!(build("arena", &setup).name(), "arena");
        assert_eq!(build("duel", &setup).name(), "duel");
        assert!(exists("melee"), "and the catalog will accept the name");
        assert!(exists("duel"), "and the catalog will accept a duel");
    }
}

#[cfg(test)]
mod duel_tests {
    use super::*;

    /// The two seats every test in here fights over, one to a side.
    const LEFT: u8 = 3;
    const RIGHT: u8 = 9;
    const LEFT_NAME: &str = "Climber";
    const RIGHT_NAME: &str = "Tessellate 0001";

    /// A room with both seats taken, one on each side. Which of them is a
    /// person is not something the mode can see, and that is the point of it.
    fn paired_world() -> World {
        let mut w = World::new(7);
        for (ship, team) in [(LEFT, 0u8), (RIGHT, 1u8)] {
            let seat = w.spawn(0, team, 500, 500, 0);
            assert!(seat >= 0, "a seat");
            // `spawn` hands out the lowest free ship, and these tests name
            // theirs, so the row is moved to the number they use.
            let row = w.state.ships[seat as usize];
            w.state.ships[ship as usize] = row;
            if seat as u8 != ship {
                w.state.ships[seat as usize].team = 0;
            }
        }
        w
    }

    fn names() -> Vec<(u8, &'static str)> {
        vec![(LEFT, LEFT_NAME), (RIGHT, RIGHT_NAME)]
    }

    fn ctx<'a>(
        world: &'a mut World,
        seats: &'a [u8],
        seat_names: &'a [(u8, &'a str)],
    ) -> ModeCtx<'a> {
        ModeCtx {
            world,
            seats,
            seat_names,
            team_names: &[],
            banner: String::new(),
            finished: false,
            open_match: false,
            close_match: false,
            abort_match: false,
        }
    }

    /// Run one fight to its end: open it, kill `victim`, and tick out the
    /// window the result waits in. Returns the mode with the fight filed.
    fn one_fight(duel: &mut Duel, world: &mut World, seats: &[u8], victim: u8) {
        let names = names();
        duel.tick(&mut ctx(world, seats, &names));
        let mut point = ctx(world, seats, &names);
        duel.on_death(&mut point, victim, 0);
        for _ in 0..=DUEL_DEATH_PAUSE_TICKS {
            duel.tick(&mut ctx(world, seats, &names));
        }
    }

    fn run_of(duel: &Duel, ship: u8) -> DuelRun {
        duel.duel_state(Some(ship)).expect("a duel").run
    }

    /// Nothing opens until both seats are taken, and the clock does not burn
    /// while one of them is empty.
    #[test]
    fn a_fight_waits_for_a_second_pilot() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 500, 20);
        let alone = [LEFT];
        let names = names();

        for _ in 0..300 {
            let mut waiting = ctx(&mut world, &alone, &names);
            duel.tick(&mut waiting);
            assert!(!waiting.open_match);
        }
        assert_eq!(duel.left, 500, "the match clock has not burned");
        let state = duel.duel_state(Some(LEFT)).expect("a duel");
        assert!(state.waiting, "and it says so");
        assert!(!state.playing);

        let mut arrived = ctx(&mut world, &[LEFT, RIGHT], &names);
        duel.tick(&mut arrived);
        assert!(arrived.open_match);
        assert!(duel.duel_state(Some(LEFT)).expect("a duel").playing);
    }

    /// A third ship is not a duel. Nothing about the room is a fight the mode
    /// will score while one is in it.
    #[test]
    fn a_third_seat_is_not_a_duel() {
        let mut world = paired_world();
        let extra = world.spawn(0, 0, 400, 400, 0);
        assert!(extra >= 0);
        let mut duel = Duel::new(DuelRules::default(), 500, 20);
        let crowd = [LEFT, RIGHT, extra as u8];
        let names = names();
        let mut c = ctx(&mut world, &crowd, &names);
        duel.tick(&mut c);
        assert!(!c.open_match, "three ships never opened a fight");
    }

    /// Both seats on one side are not opponents either, whatever the room
    /// thinks it did when it seated them.
    #[test]
    fn two_pilots_on_one_side_are_not_opponents() {
        let mut world = paired_world();
        world.state.ships[RIGHT as usize].team = 0;
        let mut duel = Duel::new(DuelRules::default(), 500, 20);
        let names = names();
        let mut c = ctx(&mut world, &[LEFT, RIGHT], &names);
        duel.tick(&mut c);
        assert!(!c.open_match);
    }

    /// One death takes the fight, after the window it is held open for. Both
    /// cards are written, each from its own side.
    #[test]
    fn one_death_settles_the_fight_on_both_cards() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        one_fight(&mut duel, &mut world, &[LEFT, RIGHT], RIGHT);

        let won = run_of(&duel, LEFT);
        assert_eq!(won.streak, 1);
        assert_eq!(won.legs, 1);
        assert_eq!(won.log[0].result, LegResult::Cleared);
        assert_eq!(
            won.log[0].rival.as_str(),
            RIGHT_NAME,
            "a card names who was across the arena, not who is reading it"
        );

        let lost = run_of(&duel, RIGHT);
        assert_eq!(lost.streak, 0);
        assert_eq!(lost.legs, 1);
        assert_eq!(lost.log[0].result, LegResult::Lost);
        assert_eq!(lost.log[0].rival.as_str(), LEFT_NAME);
    }

    /// The deciding death does not file the fight. Two seconds of arena
    /// follow it, and the pilot who fired the bomb already in the air is not
    /// safe from it: a death inside the window is a trade, and a trade is a
    /// draw on both cards.
    #[test]
    fn a_death_inside_the_window_draws_the_fight() {
        for order in [[RIGHT, LEFT], [LEFT, RIGHT]] {
            let mut world = paired_world();
            let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
            let seats = [LEFT, RIGHT];
            let names = names();
            duel.tick(&mut ctx(&mut world, &seats, &names));

            let mut first = ctx(&mut world, &seats, &names);
            duel.on_death(&mut first, order[0], 0);
            assert!(!first.close_match, "not filed on the deciding death");
            duel.tick(&mut ctx(&mut world, &seats, &names));

            let mut second = ctx(&mut world, &seats, &names);
            duel.on_death(&mut second, order[1], 0);
            assert!(second.close_match, "the trade files it at once");

            for ship in seats {
                let run = run_of(&duel, ship);
                assert_eq!(run.log[0].result, LegResult::Drawn, "ship {ship}");
                assert_eq!(run.streak, 0, "a draw is nobody's win");
            }
        }
    }

    /// Both pilots dying on one tick is the same rule read at zero seconds,
    /// and it holds whichever order the core reports them in.
    #[test]
    fn two_deaths_on_one_tick_are_a_draw() {
        for order in [[LEFT, RIGHT], [RIGHT, LEFT]] {
            let mut world = paired_world();
            let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
            let seats = [LEFT, RIGHT];
            let names = names();
            duel.tick(&mut ctx(&mut world, &seats, &names));
            let mut both = ctx(&mut world, &seats, &names);
            for &(victim, killer) in &[(order[0], 0), (order[1], 0)] {
                Mode::on_death(&mut duel, &mut both, victim, killer);
            }
            assert!(both.close_match);
            assert_eq!(run_of(&duel, LEFT).log[0].result, LegResult::Drawn);
            assert_eq!(run_of(&duel, RIGHT).log[0].result, LegResult::Drawn);
        }
    }

    /// The whistle settles a fight the pilots did not. Nobody scoring in it is
    /// a draw; anybody ahead takes it.
    #[test]
    fn the_whistle_draws_a_fight_nobody_won() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 3, 20);
        let seats = [LEFT, RIGHT];
        let names = names();
        for _ in 0..5 {
            duel.tick(&mut ctx(&mut world, &seats, &names));
        }
        assert_eq!(run_of(&duel, LEFT).log[0].result, LegResult::Drawn);
        assert_eq!(run_of(&duel, RIGHT).log[0].result, LegResult::Drawn);
        assert_eq!(
            run_of(&duel, LEFT).log[0].seconds,
            1,
            "a drawn fight files the whole match timer"
        );
    }

    /// A departure voids the fight rather than handing it to whoever is left,
    /// and the pilot who stayed keeps their card.
    #[test]
    fn a_departure_mid_fight_voids_it() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 500, 20);
        let seats = [LEFT, RIGHT];
        let names = names();
        duel.tick(&mut ctx(&mut world, &seats, &names));
        duel.tick(&mut ctx(&mut world, &seats, &names));

        let mut gone = ctx(&mut world, &[LEFT], &names);
        duel.on_departure(&mut gone, RIGHT, false);
        assert!(gone.abort_match);
        assert!(!gone.close_match, "a voided fight files nothing");
        assert!(gone.banner.contains("Opponent left"));
        assert_eq!(run_of(&duel, LEFT).legs, 0, "and lands on no card");
    }

    /// Except when the window already decided it. Whoever left had lost, and
    /// pulling the plug is not a way out of the loss.
    #[test]
    fn leaving_a_decided_fight_still_files_it() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        let seats = [LEFT, RIGHT];
        let names = names();
        duel.tick(&mut ctx(&mut world, &seats, &names));
        let mut point = ctx(&mut world, &seats, &names);
        duel.on_death(&mut point, RIGHT, 0);

        let mut gone = ctx(&mut world, &[LEFT], &names);
        duel.on_departure(&mut gone, RIGHT, false);
        assert!(gone.close_match, "the fight was already decided");
        assert_eq!(run_of(&duel, LEFT).log[0].result, LegResult::Cleared);
    }

    /// A card belongs to the pilot who flew it. The next person into that seat
    /// is not standing where they were.
    #[test]
    fn a_leaving_pilot_takes_their_card_with_them() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        one_fight(&mut duel, &mut world, &[LEFT, RIGHT], RIGHT);
        assert_eq!(run_of(&duel, LEFT).legs, 1);

        let names = names();
        let mut gone = ctx(&mut world, &[RIGHT], &names);
        duel.on_departure(&mut gone, LEFT, false);
        assert_eq!(run_of(&duel, LEFT).legs, 0, "the seat starts empty");
        assert_eq!(
            run_of(&duel, RIGHT).legs,
            1,
            "and the pilot still here keeps theirs"
        );
    }

    /// Wins in a row are the reading the mode is played for. A loss breaks the
    /// streak and a draw leaves it alone, because nobody won a draw.
    #[test]
    fn the_streak_counts_wins_in_a_row() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        let seats = [LEFT, RIGHT];
        for _ in 0..3 {
            one_fight(&mut duel, &mut world, &seats, RIGHT);
        }
        assert_eq!(run_of(&duel, LEFT).streak, 3);
        assert_eq!(run_of(&duel, LEFT).best_streak, 3);

        one_fight(&mut duel, &mut world, &seats, LEFT);
        let run = run_of(&duel, LEFT);
        assert_eq!(run.streak, 0, "a loss breaks it");
        assert_eq!(run.best_streak, 3, "and the best of it survives");
        assert_eq!(run.legs, 4);
    }

    /// The card is a window on the most recent fights, and the count says what
    /// fell off the end of it.
    #[test]
    fn the_card_keeps_the_most_recent_fights() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        let seats = [LEFT, RIGHT];
        for _ in 0..DUEL_LOG_LEGS + 2 {
            one_fight(&mut duel, &mut world, &seats, RIGHT);
        }
        let run = run_of(&duel, LEFT);
        assert_eq!(run.logged as usize, DUEL_LOG_LEGS);
        assert_eq!(run.legs, DUEL_LOG_LEGS as u32 + 2);
        assert!(
            run.log.iter().all(|leg| leg.result == LegResult::Cleared),
            "the window holds real fights rather than defaults"
        );
    }

    /// A watcher gets the room's half and nobody's card, which is the whole of
    /// what a spectator is owed.
    #[test]
    fn a_watcher_reads_the_room_and_no_card() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        one_fight(&mut duel, &mut world, &[LEFT, RIGHT], RIGHT);
        let watching = duel.duel_state(None).expect("a duel");
        assert_eq!(watching.run, DuelRun::default());
        assert!(!watching.playing);
        assert_eq!(run_of(&duel, LEFT).legs, 1, "the pilots still have theirs");
    }

    /// A configured first-to keeps the fight open until it is reached.
    #[test]
    fn a_longer_series_needs_every_point() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules { first_to: 3 }, 100_000, 2);
        let seats = [LEFT, RIGHT];
        let names = names();
        duel.tick(&mut ctx(&mut world, &seats, &names));
        for point in 1..3 {
            let mut c = ctx(&mut world, &seats, &names);
            duel.on_death(&mut c, RIGHT, 0);
            assert!(!c.close_match, "point {point} is not the fight");
            assert!(duel.settling.is_none());
        }
        let mut last = ctx(&mut world, &seats, &names);
        duel.on_death(&mut last, RIGHT, 0);
        assert!(duel.settling.is_some(), "the third opens the window");
    }

    /// First to one is the floor. A zone asking for none gets it anyway.
    #[test]
    fn a_zero_first_to_is_clamped_to_one() {
        let duel = Duel::new(DuelRules { first_to: 0 }, 100, 2);
        assert_eq!(duel.rules.first_to, 1);
    }

    /// The room hands a duel to its first person: the pair of bots that were
    /// keeping it playing are not the fight they came for.
    #[test]
    fn the_first_person_gets_a_fight_of_their_own() {
        let mut world = paired_world();
        let mut duel = Duel::new(DuelRules::default(), 100_000, 2);
        one_fight(&mut duel, &mut world, &[LEFT, RIGHT], RIGHT);
        assert_eq!(run_of(&duel, LEFT).legs, 1);

        assert!(duel.first_human());
        assert_eq!(run_of(&duel, LEFT).legs, 0, "nobody else's evening");
        let state = duel.duel_state(Some(LEFT)).expect("a duel");
        assert!(state.waiting);
        assert!(!state.playing);
    }

    /// Every other mode answers nothing, so a caller can ask through the trait
    /// without knowing what it is holding.
    #[test]
    fn only_a_duel_has_a_duel_state() {
        assert!(FreeForAll.duel_state(None).is_none());
        assert!(Melee::new(2, 10, 2).duel_state(None).is_none());
        assert!(Warzone::new(4, 2).duel_state(None).is_none());
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
            seat_names: &[],
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
