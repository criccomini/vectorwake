//! What happened to one pilot, on its way out of the arena.
//!
//! A room knows things about a pilot that no other process can reconstruct
//! afterwards: which of five refusals it gave at the door, whether a departure
//! was a quit or a kick, which hull somebody swapped into and when. None of it
//! survives the tick that produced it. When a player reports being bounced, or
//! a bot fleet deadlocks, or somebody asks which ships people actually fly, the
//! answer is in a log nobody kept.
//!
//! So this is that log. It travels the way [`crate::spool`] already carries
//! rated deaths: append a line, move on, let a background task drain it into
//! the meta-layer. Nothing here is on the tick's critical path and nothing here
//! is allowed to be, per
//! [decision 42](../../docs/architecture/decisions.md).
//!
//! Two properties are load-bearing and easy to lose.
//!
//! The log holds no addresses. An arena never learns one: the accept discards
//! the peer and the WebTransport session is never asked. That is not an
//! oversight to fix here. The meta-layer's best property is that a breach
//! discloses a ladder rather than anybody's identity, and a per-pilot behavior
//! log keyed to an IP is the fastest way to spend it.
//!
//! And a session's rows are capped. Half the events below are things a pilot
//! can do as fast as they can press a key, so without a ceiling one bored
//! player with a script is a write amplifier pointed at the fleet's database.
//! See [`Session::spend`].

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

/// One thing that happened, as it travels. Zone, class and instance are not
/// here: they are the same for every row in a batch and ride on the envelope
/// the drain builds, which is where `rated_events` puts them too.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq)]
pub struct Event {
    /// Minted once, when the event is filed, and carried through every retry.
    /// Delivery is at-least-once, so this is what lets the meta-layer refuse
    /// the second arrival of a row it already has.
    pub id: i64,
    /// Wall clock at the arena, in milliseconds, when this happened. The
    /// meta-layer's own `now()` would be the moment it drained the spool
    /// instead, and a log whose timestamps move when the far end goes down for
    /// an hour is not one you can debug an outage with.
    pub at: u64,
    /// Which connection this belongs to. Every row a pilot's stay produces
    /// carries the same one.
    pub session: String,
    /// One of the constants below.
    pub kind: String,
    /// The account, where there is one. A guest has none, and their rows are
    /// keyed by session and call sign alone.
    pub pilot: Option<u64>,
    /// The call sign as it read at the time, which is the only handle a guest
    /// has and is worth keeping beside an account that has since been renamed.
    pub name: String,
    pub bot: bool,
    /// The room's number, not its position in the arena's list: positions
    /// shift when an empty room is reclaimed. None at the door, where a
    /// refusal happens before any room is chosen.
    pub room: Option<u32>,
    /// The room's tick, for lining a row up against a recording or a golden
    /// trace. Zero where there is no room yet.
    pub tick: u32,
    /// Whatever this kind of event is about. Deliberately loose: the shape of
    /// a refusal has nothing in common with the shape of a hull change, and a
    /// column per field would be forty columns that are null forty times over.
    pub detail: serde_json::Value,
}

/// A pilot took a seat. `detail`: the hull, the sim slot, the side, the
/// protocol they speak, and which transport carried them.
pub const JOIN: &str = "join";
/// Refused at the door. `detail`: the deny code and the sentence sent with it.
/// The one event here that can be written for somebody who never got in, which
/// is exactly why it is worth writing.
///
/// Carries the account wherever the door got far enough to know it, which is
/// every refusal after the token is read. Three happen before that and can only
/// record the name the client claimed. The distinction is the difference
/// between a refusal that shows up in the pilot it happened to and one that
/// shows up nowhere.
pub const DENIED: &str = "denied";
/// Arrived to watch rather than to fly.
pub const WATCH: &str = "watch";
/// A hull change that took effect. `detail`: from and to.
pub const SHIP: &str = "ship";
/// Crossed to a side. `detail`: from and to, and whether the side is public.
pub const TEAM: &str = "team";
/// Founded a side of their own. `detail`: the byte and the generated name.
pub const FOUND: &str = "found";
/// Invited somebody to a private side. `detail`: the invited slot.
pub const INVITE: &str = "invite";
/// Gave up a hull for the stands. `detail`: why, either the pilot asking or
/// the safe-zone sweep moving them.
pub const SIT_OUT: &str = "sit_out";
/// Took a hull again after watching.
pub const FLY: &str = "fly";
/// Became the subject somebody is watching. A pilot is told this on the wire,
/// so recording it keeps the log honest about what the room disclosed and to
/// how many.
pub const ON_AIR: &str = "on_air";
/// The seat ended. `detail`: `why`, one of the reasons below, how many ticks
/// the pilot held the seat, and whether it settled as a quit.
pub const LEAVE: &str = "leave";
/// This pilot's hull was destroyed. `detail`: who by, and what it paid.
///
/// Combat started outside this log, on the reasoning that `rated_events`
/// already keeps every death and a log should not say things twice. What that
/// produced was a session that read as a join and a leave with an hour of
/// silence between them, which is nobody's idea of what happened. So the
/// human-involving deaths are filed here too, as the pilot's own row: the
/// rated log stays the authority on what a death did to a number, and this
/// one says that it happened to this person in this room. Bot-on-bot deaths,
/// the overwhelming bulk, still never enter.
pub const DIED: &str = "died";
/// This pilot destroyed somebody. `detail`: who, and what it paid.
pub const KILL: &str = "kill";

/// The two combat kinds do not spend the session budget. The budget exists
/// because most of this log is things a pilot can do as fast as they can
/// press a key; a death is gated by the simulation, which charges a respawn
/// and a flight back before the next one is possible, so a session cannot
/// flood through it. Spending would also mean a long evening of honest
/// flying exhausts the allowance and the departure at the end of it goes
/// unrecorded, which is the row the whole log is for.
pub fn budgeted(kind: &str) -> bool {
    kind != DIED && kind != KILL
}

/// Written by the meta-layer rather than an arena, for the handful of things
/// that happen to a pilot with no room involved. These carry no session: there
/// is no connection to tie them to, and inventing one would suggest a
/// continuity that is not there.
pub const ACCOUNT: &str = "account";
pub const CLAIM: &str = "claim";
pub const LOGIN: &str = "login";
pub const RENAME: &str = "rename";
pub const BAN: &str = "ban";
pub const UNBAN: &str = "unban";
pub const GRANT: &str = "grant";
/// Rivets spent on an upgrade. `detail`: the slot, what it was raised to, and
/// what it cost. The wallet is a number with no history of its own, so this
/// is the only record of where it went.
pub const BOUGHT: &str = "bought";
pub const REVOKE: &str = "revoke";
/// An operator set a wallet by hand. `detail`: what it held, what it holds,
/// and who moved it.
///
/// For the same reason `BOUGHT` exists. The wallet keeps no history, so
/// without this a balance that grew by five hundred overnight is a number
/// nobody can account for: not the player, who did not earn it, and not the
/// next operator, who cannot tell a correction from a compromise.
pub const WALLET: &str = "wallet";
/// An operator moved what an account owns in one slot. `detail`: the slot, its
/// name, what it held, what it holds, and who moved it.
///
/// The counterpart to `BOUGHT`, and kept apart from it on purpose: one is a
/// pilot spending what they earned and the other is an operator deciding, and
/// a log that called both "bought" would make the second invisible inside the
/// first.
pub const ENTITLEMENT: &str = "entitlement";

/// Why a seat ended. `Room::leave` is the one funnel for all five, and until
/// this existed they were indistinguishable afterwards: the commonest question
/// anybody asks of a departure is which of these it was.
pub mod why {
    /// The socket closed. A player quitting to the menu and a player whose
    /// network died land here alike, because intent is not knowable at the
    /// socket.
    pub const LEFT: &str = "left";
    /// Gave up the hull for the stands, still connected.
    pub const SAT_OUT: &str = "sat_out";
    /// A bot's seat taken back for an arriving human.
    pub const EVICTED: &str = "evicted";
    /// A bot sent home because the instance is draining.
    pub const DRAINED: &str = "drained";
    /// An operator kicked them.
    pub const KICKED: &str = "kicked";
    /// The process is going down, by the restart verb or the host stopping
    /// the container. Every deploy lands as one of these, and before it was
    /// written down a converge simply cut every open session's story short:
    /// the join was on file and the departure never happened.
    pub const RESTART: &str = "restart";
}

/// Rows one connection may file before it stops being written down.
///
/// A normal stay writes somewhere between five and twenty. The ceiling is for
/// the pilot who found that sitting out and flying again is free and can be
/// done in a loop: past this they are still playing, and the log simply stops
/// growing on their account. Two hundred is far enough above honest play that
/// reaching it is itself the finding.
pub const PER_SESSION: u32 = 200;

/// Refusals one arena process will write down in a minute.
///
/// The per-session cap does not reach a refusal: every reconnect is a new
/// connection and so a new session with a full allowance, which makes a client
/// that loops on a refusal the one flooder the cap cannot see. That client also
/// happens to be the one most worth recording, so the answer is a ceiling
/// rather than a filter. Sixty is far above what a healthy instance refuses and
/// low enough that a loop costs a row a second.
pub const REFUSALS_PER_MINUTE: u32 = 60;

static REFUSAL_WINDOW: AtomicU64 = AtomicU64::new(0);
static REFUSALS: AtomicU32 = AtomicU32::new(0);

/// Whether this process has room to write down another refusal.
///
/// Coarse on purpose: the window is a whole minute and resets by whoever
/// notices first, so two threads can race and one minute can start slightly
/// early. Nothing here needs to be exact. It needs to be bounded.
pub fn refusal_budget(now_ms: u64) -> bool {
    let minute = now_ms / 60_000;
    if REFUSAL_WINDOW.swap(minute, Ordering::Relaxed) != minute {
        REFUSALS.store(0, Ordering::Relaxed);
    }
    REFUSALS.fetch_add(1, Ordering::Relaxed) < REFUSALS_PER_MINUTE
}

/// One connection's identity in the log, and its remaining budget.
///
/// Minted at the door and carried on the `Seat`, which is what makes it
/// survive the two places a pilot's handles are reissued underneath them:
/// sitting out keeps the seat and reissues nothing, and flying again allocates
/// a fresh player id in a room whose position in the arena's list may have
/// moved. Neither is a new session, and a log that started a new one at each
/// would cut every spectating pilot's stay into unrelated pieces.
#[derive(Clone, Debug)]
pub struct Session {
    pub id: String,
    /// `ws` or `wt`. A property of the connection rather than of anything that
    /// happens over it, which is why it rides here instead of being threaded
    /// through every call that files a row. Worth having: a client that
    /// negotiated QUIC and then quietly fell back to WebSocket looks identical
    /// to one that never tried, and that exact confusion cost an afternoon.
    pub transport: &'static str,
    /// Shared with every clone of this seat, so the budget is the connection's
    /// rather than each copy's.
    filed: Arc<AtomicU32>,
}

impl Session {
    pub fn new(transport: &'static str) -> Session {
        let bytes: [u8; 16] = rand::random();
        Session {
            id: crate::token::to_hex(&bytes),
            transport,
            filed: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Claim one row's worth of budget, or refuse. The refusal is silent to
    /// the pilot, who is not doing anything wrong by playing quickly.
    pub fn spend(&self) -> bool {
        self.filed.fetch_add(1, Ordering::Relaxed) < PER_SESSION
    }

    /// How many rows this connection has asked to file, capped or not. For
    /// tests, and for a caller that wants to say so in a log line.
    pub fn filed(&self) -> u32 {
        self.filed.load(Ordering::Relaxed)
    }
}

impl Default for Session {
    fn default() -> Self {
        Session::new("none")
    }
}

/// Two seats are the same seat when they are the same connection. The budget
/// is a counter that moves on its own, so comparing it would make a `Seat`
/// stop equalling itself the moment anything was written.
impl PartialEq for Session {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_sessions_differ() {
        assert_ne!(Session::new("ws").id, Session::new("ws").id);
        assert_eq!(Session::new("ws").id.len(), 32, "16 bytes as hex");
    }

    /// The budget belongs to the connection. A seat is cloned every time a
    /// pilot sits out and flies again, and a per-copy counter would hand a
    /// fresh allowance to exactly the loop the cap exists to bound.
    #[test]
    fn clones_share_one_budget() {
        let a = Session::new("ws");
        let b = a.clone();
        assert!(a.spend());
        assert_eq!(b.filed(), 1, "a clone sees what the original spent");
        for _ in 1..PER_SESSION {
            assert!(b.spend());
        }
        assert!(!a.spend(), "the cap binds across both");
        assert!(!b.spend(), "and stays bound");
    }

    /// A seat is compared in several places and none of them mean to ask how
    /// much of the log this connection has used up.
    #[test]
    fn equality_ignores_the_budget() {
        let a = Session::new("ws");
        let b = a.clone();
        a.spend();
        assert_eq!(a, b, "still the same session");
    }
}
