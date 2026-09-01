use std::collections::{BTreeMap, HashMap};

use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::delivery::*;
use crate::presence::*;
use crate::protocol::*;
use crate::{
    ai, catalog, config, fleet, growth, metrics, modes, pilot, rating, sim, spool, token,
    CHANNEL_DELAY, CHANNEL_HOLD, DEFAULT_MAX_WATCHERS,
};

/// The simulation heading for a vector from `from` to `to`.
///
/// Heading zero is north and increases clockwise. Match setup happens once at
/// the authoritative server, outside the fixed-point tick loop, so this uses
/// the same angle convention as the AI and rounds to the nearest wire heading.
pub(crate) fn heading_toward(from: (i32, i32), to: (i32, i32)) -> u16 {
    let dx = f64::from(to.0) - f64::from(from.0);
    let dy = f64::from(to.1) - f64::from(from.1);
    if dx == 0.0 && dy == 0.0 {
        return 0;
    }
    let turns = dx.atan2(-dy) / std::f64::consts::TAU;
    let units = (turns.rem_euclid(1.0) * 65536.0).round() as i64;
    (units & 0xffff) as u16
}

/// Face both public teams toward the current center of the other side.
///
/// Starts are authored on different axes from map to map. A fixed north and
/// south facing made one layout open sideways and another open with both teams
/// looking away from the fight. Positions are already fixed at the whistle,
/// so the opposing centroid is the match-facing contract.
pub(crate) fn face_public_teams(world: &mut sim::World) {
    let mut sums = [(0i64, 0i64, 0u32); 2];
    for row in world.state.ships.iter() {
        if row.active == 0 || row.team >= 2 {
            continue;
        }
        let side = &mut sums[row.team as usize];
        side.0 += i64::from(row.x);
        side.1 += i64::from(row.y);
        side.2 += 1;
    }
    for row in world.state.ships.iter_mut() {
        if row.active == 0 || row.team >= 2 {
            continue;
        }
        let target = sums[1 - row.team as usize];
        if target.2 == 0 {
            continue;
        }
        let at = (
            (target.0 / i64::from(target.2)) as i32,
            (target.1 / i64::from(target.2)) as i32,
        );
        row.heading = heading_toward((row.x, row.y), at);
    }
}

pub(crate) struct Player {
    pub(crate) ship: u8,
    /// Changes whenever this connection moves between flying and watching.
    /// Inputs and snapshots carry it so packets from the life that ended are
    /// harmless in the life that replaced it.
    pub(crate) lifecycle: u32,
    /// What this pilot is currently holding down, which is what a tick with no
    /// scheduled input uses. A held key is the common case, so a lost packet
    /// reads as a continued hold rather than a stutter.
    pub(crate) buttons: u16,
    /// Inputs stamped for ticks this arena has not reached yet, oldest first.
    ///
    /// A client that runs its clock ahead of ours sends an input before the
    /// tick it belongs to, and this is where it waits. Both ends then apply the
    /// same buttons on the same tick number, which is the whole point: the
    /// alternative, taking each packet as the current state on arrival, means
    /// the pilot brakes several ticks before the server does and sees itself
    /// corrected back into motion.
    pub(crate) pending: HashMap<u32, u16>,
    /// Newest accepted input tick and the selective receipt window behind it.
    /// A client repairs the zeroes instead of guessing that the last few
    /// consecutive ticks are the ones a datagram lost.
    pub(crate) input_ack: u32,
    pub(crate) input_mask: u32,
    /// Server-only receipt history used to judge whether each due input
    /// arrived. The public repair mask is only 32 ticks wide, while a healthy
    /// client may run as much as 40 ticks ahead after recovering from a long
    /// frame. Using that mask for enforcement called every queued input late
    /// once the lead crossed its edge.
    pub(crate) input_receipts: u128,
    pub(crate) input_seen: bool,
    /// The newest tick whose buttons are the ones being held.
    ///
    /// `pending` is keyed by tick and so never applies two out of order, but a
    /// late input is applied where it lands, and over a WebSocket that was
    /// safe because arrival order was send order. Inputs are datagrams now and
    /// two of them can swap, so without this a stale packet overwrote a newer
    /// one that had already been applied and the pilot's press was undone
    /// until the next frame's datagram. `input_ack` cannot stand in for it:
    /// that one counts ticks that are still waiting in `pending`, and
    /// would refuse the late input the moment a client stamped anything ahead.
    pub(crate) applied_tick: u32,
    pub(crate) applied_input: bool,
    /// Last server tick on which an input packet arrived. Browsers can suspend
    /// between a focus event and the next frame, so held controls need a
    /// server-side backstop as well as the client's release message.
    pub(crate) last_input_at: u32,
    /// Keep the fast snapshot lane briefly after combat leaves the radius.
    /// This stops the cadence flipping at the exact distance boundary.
    pub(crate) combat_until: Option<u32>,
    pub(crate) lag: LagTracker,
    pub(crate) name: String,
    /// What this pilot's rating movement is filed under. See `Seat::rid`.
    pub(crate) rid: rating::Id,
    /// Whether this client declared itself a bot at join. It decides three
    /// things and nothing else: the roster label, whether the seat counts
    /// against the human cap, and whether the seat can be taken away.
    pub(crate) bot: bool,
    /// Consecutive ticks spent inside a safe zone. Counted here rather than in
    /// the core, which has no model of a seat and nothing to do with one; the
    /// limit it is measured against travels in the settings so the client can
    /// draw the same countdown. Reset the moment the hull is outside, so this
    /// is dwell rather than a total.
    pub(crate) safe: u16,
    /// This pilot has not been handed the ground the room is standing on.
    ///
    /// A client predicts collisions against its own copy of the map and draws
    /// the walls from that same copy, so one that misses a rotation flies the
    /// previous round's map for the whole of the next one: bouncing off walls
    /// it cannot see, passing through the ones it can, and corrected by the
    /// server on every snapshot. Nothing on the wire says so, because the
    /// hash a client verifies rides inside the map message it never received.
    ///
    /// `try_send` refuses rather than waits, so the room keeps offering until
    /// it lands. The tuning is held back meanwhile and travels with the map
    /// when it goes: a client that takes the new generation without the new
    /// ground stops refusing snapshots and starts predicting on the old
    /// walls.
    pub(crate) owes_map: bool,
    /// The room's tick when this pilot took the seat, so a departure can say
    /// how long they held it. A room's own tick rather than a clock, because
    /// the two things anybody compares this against, a golden trace and the
    /// rest of the log, are both in ticks.
    pub(crate) joined: u32,
    pub(crate) tx: mpsc::Sender<Message>,
    pub(crate) presence: PresenceHandle,
}

/// How far ahead of the arena's own tick a scheduled input may be stamped.
///
/// A second at 100 Hz, which is far more lead than a playable connection needs
/// and short enough that a client cannot queue up a minute of flying. Anything
/// past it is clamped rather than refused, because a clock that has drifted is
/// a client to correct, not one to disconnect.
pub(crate) const INPUT_LEAD_MAX: u32 = 100;

/// Future ticks required before a new input stream is considered coherent.
///
/// The current tick proves the stream has caught the arena. Two more prove it
/// has crossed from late arrival into scheduled prediction rather than merely
/// touching the clock for one packet.
pub(crate) const INPUT_SYNC_LEAD: u32 = 2;

/// Scheduled inputs held per player. At one input per tick and a lead well
/// under the cap this is never near full; it exists so a client that floods
/// cannot grow the arena's memory.
pub(crate) const INPUT_QUEUE_MAX: usize = 128;

/// Silence limits for held controls. A brief gap keeps ordinary held movement
/// intact, but a suspended client cannot keep firing or drift through an
/// objective forever.
const STALE_WEAPON_BUTTONS: u16 = sim::BTN_FIRE | sim::BTN_BOMB | sim::BTN_USE | sim::BTN_MULTI;

/// What a watcher is looking at.
/// A connection with a seat in the roster and no ship in the simulation.
/// The sim never hears about these; `sim_state` gains no field.
pub(crate) struct Watcher {
    /// The same connection generation carried by a flying player. It advances
    /// at each move between the cockpit and the stands.
    pub(crate) lifecycle: u32,
    /// Everything needed to put this pilot back in the game: `fly` hands this
    /// straight back to `join`, so watching and returning is a despawn and a
    /// spawn rather than a reconnect.
    pub(crate) seat: Seat,
    /// The side they sat out from. It colors their screen, it is the side the
    /// team list calls theirs, and it is the seat they prefer when they fly
    /// again. None until the room seats them, which `watch_join` does at the
    /// door for somebody who arrived watching.
    pub(crate) team: Option<u8>,
    pub(crate) tx: mpsc::Sender<Message>,
    pub(crate) presence: PresenceHandle,
}

/// One frame of the room channel: the snapshot message as every channel
/// watcher will receive it, the kills announced since the frame before, and
/// what the room said about itself in the same span. All of it rides with the
/// picture, so the feed cannot spoil a death that has not been shown and the
/// clock over it cannot read five seconds into its future.
pub(crate) struct ChannelFrame {
    pub(crate) tick: u32,
    /// Whose hull this frame is centered on, 255 for an empty room. Kept
    /// beside the bytes because it is the answer to "who is being seen right
    /// now", which is a question about the frame going out rather than about
    /// the camera: with a delay on the channel those are seconds apart.
    pub(crate) subject: u8,
    /// The lines this frame's watchers are owed: kills, the streaks they
    /// started, and anything said over the podium. Whatever a player was
    /// told, held back to the frame it belongs with.
    pub(crate) feed: Vec<Vec<u8>>,
    pub(crate) charges: Vec<Vec<u8>>,
    /// What the room said about itself while this frame was the live one: the
    /// clock, the score, the banner, the ground and the scoreboard. Held here
    /// for the same reason the feed is, and served ahead of the picture so a
    /// map arrives before the snapshot packed on it.
    pub(crate) state: Vec<Vec<u8>>,
    pub(crate) msg: Vec<u8>,
}

/// The room channel: one shared feed per room, subject picked by the server on
/// its own clock, same bytes for every watcher on it, and the whole of what
/// spectating is. Shared is what makes it safe: reconnecting lands on the same
/// channel everyone else is watching, so there is no re-rolling for a victim,
/// and the delay is what makes the frame that does show them film rather than
/// targeting data.
///
/// The delay is on the whole broadcast rather than on the picture alone. A
/// watcher used to be sent the clock, the score, the banner and the ground the
/// moment they changed, while the frames they were drawing were five seconds
/// old: a match's last five seconds ticked away over ships still fighting, and
/// the death that ended it landed under a clock already counting the next
/// match down. Everything a watcher reads about the room goes through the ring
/// now, so one clock governs the whole screen. What a side is called and who
/// may open which door is the exception, and stays live: it describes the room
/// rather than the moment.
pub(crate) struct Channel {
    pub(crate) subject: Option<u8>,
    /// The subject of the newest frame actually served, which is what channel
    /// watchers are looking at. Behind `subject` by the delay, and None until
    /// the ring is warm enough to have served anything.
    pub(crate) showing: Option<u8>,
    /// Ticks left before the subject is re-picked. Also re-picked early when
    /// the subject leaves.
    pub(crate) hold: u32,
    pub(crate) ring: std::collections::VecDeque<ChannelFrame>,
    /// Feed lines waiting for the next frame.
    pub(crate) pending_feed: Vec<Vec<u8>>,
    /// Room messages waiting for the next frame. See `ChannelFrame::state`.
    pub(crate) pending_state: Vec<Vec<u8>>,
    /// The last copy of each room message the channel has actually served,
    /// keyed by its leading type byte. Somebody walking into the stands is
    /// given these rather than what the room is doing now, so they land in
    /// the picture everybody else is watching instead of five seconds ahead
    /// of it.
    pub(crate) served_state: std::collections::BTreeMap<u8, Vec<u8>>,
    /// Public charge actions waiting for the next frame. The ship byte stays
    /// beside each message until the frame center is known, so an event
    /// outside that frame's fairness circle is discarded rather than leaked.
    pub(crate) pending_charges: Vec<(i32, i32, Vec<u8>)>,
    /// Its own generator, not the simulation's: the pick must not perturb the
    /// state the golden traces hash.
    pub(crate) rng: u64,
}

impl Channel {
    pub(crate) fn new() -> Self {
        Channel {
            subject: None,
            showing: None,
            hold: 0,
            ring: std::collections::VecDeque::new(),
            pending_feed: Vec::new(),
            pending_state: Vec::new(),
            served_state: std::collections::BTreeMap::new(),
            pending_charges: Vec::new(),
            rng: 0x9e3779b97f4a7c15,
        }
    }

    pub(crate) fn next_rand(&mut self) -> u64 {
        // xorshift64. Quality does not matter here; not being the sim's rng does.
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng = x;
        x
    }
}

impl Player {
    pub(crate) fn record_input_tick(&mut self, tick: u32) -> bool {
        if !self.input_seen || serial_after(tick, self.input_ack) {
            let shift = tick.wrapping_sub(self.input_ack);
            self.input_mask = if !self.input_seen || shift >= 32 {
                1
            } else {
                (self.input_mask << shift) | 1
            };
            self.input_receipts = if !self.input_seen || shift >= u128::BITS {
                1
            } else {
                (self.input_receipts << shift) | 1
            };
            self.input_ack = tick;
            self.input_seen = true;
            return true;
        }
        let behind = self.input_ack.wrapping_sub(tick);
        if behind >= u128::BITS {
            return false;
        }
        let receipt_bit = 1u128 << behind;
        let fresh = self.input_receipts & receipt_bit == 0;
        self.input_receipts |= receipt_bit;
        if behind < u32::BITS {
            self.input_mask |= 1u32 << behind;
        }
        fresh
    }

    pub(crate) fn received_input(&self, tick: u32) -> bool {
        if !self.input_seen || serial_after(tick, self.input_ack) {
            return false;
        }
        let behind = self.input_ack.wrapping_sub(tick);
        behind < u128::BITS && self.input_receipts & (1u128 << behind) != 0
    }

    pub(crate) fn input_window_ready(&self, now: u32) -> bool {
        (0..=INPUT_SYNC_LEAD).all(|ahead| self.received_input(now.wrapping_add(ahead)))
    }

    /// File an input for the tick it names.
    ///
    /// An input for a tick already simulated is applied now instead. That is
    /// the old behavior and the right fallback: the server must not rewind the
    /// room to honour one late packet, which is the lag compensation
    /// docs/architecture/networking.md rules out, and a client with no lead at
    /// all keeps working exactly as it did.
    pub(crate) fn schedule(&mut self, tick: u32, buttons: u16, now: u32) {
        self.last_input_at = now;
        // Clamp before recording. `input_ack` is echoed back so a client can
        // measure how late its inputs are arriving, so it has to be a tick
        // this arena agreed to: a client stamping u32::MAX would otherwise pin
        // its own echo at u32::MAX forever and steer its clock off the readout.
        // That only ever hurts the client that did it, which is exactly why it
        // would have been found late and by somebody confused.
        //
        // Serial arithmetic is deliberate here. A room reaches u32::MAX after
        // 497 days and continues at zero, so a wrapped ceiling is still one
        // second ahead rather than a tick in the distant past.
        let tick = if serial_after(tick, now) && tick.wrapping_sub(now) > INPUT_LEAD_MAX {
            now.wrapping_add(INPUT_LEAD_MAX)
        } else {
            tick
        };
        self.record_input_tick(tick);
        if serial_at_or_before(tick, now) {
            // Only if it is not older than what is already held. Two late
            // datagrams that swapped in flight would otherwise land newest
            // first and oldest second, and the pilot's newest press would be
            // undone by a packet describing a tick that has already been and
            // gone.
            if !self.applied_input || serial_after(tick, self.applied_tick) {
                self.applied_tick = tick;
                self.applied_input = true;
                self.buttons = buttons;
            }
            return;
        }
        // Keyed by tick, so a repeat of one already spoken for replaces it and
        // the order is the map's rather than the arrival order's. That matters
        // because the clamp above can lower a tick, and a queue that assumed
        // arrival order would then hand out inputs out of sequence.
        self.pending.insert(tick, buttons);
        while self.pending.len() > INPUT_QUEUE_MAX {
            let oldest = *self
                .pending
                .keys()
                .max_by_key(|tick| now.wrapping_sub(**tick))
                .expect("non-empty");
            self.pending.remove(&oldest);
        }
    }

    /// What this pilot is holding on `now`: the newest input scheduled for this
    /// tick or any before it, and otherwise whatever they were already holding.
    pub(crate) fn buttons_at(&mut self, now: u32) -> u16 {
        let mut due: Vec<(u32, u16)> = self
            .pending
            .iter()
            .filter(|(tick, _)| serial_at_or_before(**tick, now))
            .map(|(tick, buttons)| (*tick, *buttons))
            .collect();
        due.sort_by_key(|(tick, _)| std::cmp::Reverse(now.wrapping_sub(*tick)));
        for (t, b) in due {
            self.buttons = b;
            self.applied_tick = t;
            self.applied_input = true;
            self.pending.remove(&t);
        }
        let silent = self.input_silence(now);
        if silent >= INPUT_WEAPON_RELEASE_TICKS {
            self.buttons &= !STALE_WEAPON_BUTTONS;
        }
        if silent >= INPUT_RELEASE_TICKS {
            self.buttons = 0;
            self.pending.clear();
        }
        self.buttons
    }

    pub(crate) fn input_silence(&self, now: u32) -> u32 {
        if serial_at_or_before(self.last_input_at, now) {
            serial_elapsed(now, self.last_input_at)
        } else {
            0
        }
    }
}

/// Messages a client may fall behind by before the arena stops queueing for it.
///
/// The queue used to be unbounded, which meant a client that stopped reading
/// cost this process memory without limit: two hundred stalled clients in one
/// room took it from 8 MB to 450 MB in twenty-five seconds, measured. A snapshot
/// is a whole state pack rather than a delta, so the next one supersedes any that
/// was dropped and the cure is simply not to send it. Two seconds of snapshots at
/// 20 Hz: long enough to ride out a hiccup, short enough that two hundred hopeless
/// clients in one room cost tens of megabytes rather than hundreds. Disconnecting
/// a client this far behind is a lag action, which server.md defers.
pub(crate) const OUT_QUEUE: usize = 40;

/// The inbound side of the same idea, between a transport's reader task and
/// `serve_client`. Bounded so a client flooding messages exerts backpressure on
/// its own socket rather than growing a queue; deep enough that a burst of
/// asks never stalls the reader answering a ping.
pub(crate) const INBOUND_QUEUE: usize = 64;

/// Below this fraction of the hull's effective ceiling, a pilot under recent
/// fire who disconnects has quit a fight they were losing, and it settles as
/// a death (see `leave`). Energy in this game is health and escape both and
/// it refills in seconds, so above the line a pilot could as easily have
/// flown away; below it, roughly one solid hit from dead, the tab is being
/// closed instead of the fight finished. One number, tuned here.
pub(crate) const QUIT_ENERGY: f64 = 0.40;

/// Feed one tick's damage into the ledger and hand back the deaths it
/// contained. Shared by the live arena and the offline calibration
/// tournament, so the two cannot disagree about what an event means.
pub(crate) fn ingest_damage(
    world: &sim::World,
    rating: &mut rating::Rating,
    name_of: &dyn Fn(u8) -> String,
) -> Vec<(u8, u8)> {
    let tick = world.state.tick;
    let ev = &*world.events;
    let mut deaths = Vec::new();
    for i in 0..ev.count as usize {
        let e = ev.e[i];
        match e.etype {
            sim::EV_HIT => {
                let (victim, attacker) = (e.a as usize, e.b as usize);
                if victim < sim::MAX_SHIPS && attacker < sim::MAX_SHIPS {
                    let same = world.state.ships[victim].team == world.state.ships[attacker].team;
                    rating.damage(tick, &name_of(e.a), &name_of(e.b), e.v, same);
                }
            }
            // The event's value is what the kill paid, and it travels to the
            // clients: the feed is drawn from this message rather than from
            // each client's own prediction, which used to print the same
            // death once per rollback that revived and re-killed the victim.
            sim::EV_DEATH => deaths.push((e.a, e.b)),
            _ => {}
        }
    }
    deaths
}

/// Who is in a seat. This was a name and a bot flag while those were the only
/// two things a room knew about a pilot. Accounts add two more: what the
/// A side in this room: what it is called, and whether its door is open.
///
/// Public teams are the zone's, named in its settings, stable across rounds,
/// and the only ones a mode scores over. Private teams are the players': a
/// generated name, entry by invitation, and gone when the last member leaves.
/// See design/teams.md.
#[derive(Clone, Debug)]
pub(crate) struct Team {
    pub(crate) name: String,
    pub(crate) public: bool,
}

/// roster is allowed to say they are, and what their rating belongs to.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Seat {
    pub(crate) name: String,
    /// Declared at join. Still decides the human cap and eviction, as before.
    pub(crate) bot: bool,
    /// `token::Label` as a byte, derived from the account rather than asserted
    /// by the client, and sent to every other pilot in the room.
    pub(crate) label: u8,
    /// Who the rating movement belongs to. An account id where there is one,
    /// and the call sign where there is not, which is what a pilot flying
    /// against a deployment with no meta-layer gets.
    pub(crate) rid: rating::Id,
    /// Present only with a verified token. No account means nothing durable is
    /// written for this pilot: they are rated inside the room and forgotten
    /// when it ends.
    pub(crate) account: Option<u64>,
    /// What the token said this pilot's rating was, per class, at the moment
    /// it was minted. This is how a career crosses zones without an arena
    /// asking anybody anything.
    pub(crate) carried: Option<Vec<token::ClassRating>>,
    /// A seat holds no build. Two doc comments stood here describing one, an
    /// entitlement vector out of the token and a pending kit waiting for a
    /// whistle, and both outlived their fields. Neither comes back with the
    /// credits: there is nothing to be entitled to, since every pilot reaches
    /// every slot, and nothing to hold pending, since a build lives on the
    /// ship in the core and a whistle re-deals it from there.
    /// The tick this seat last said one of the fixed things, so it cannot say
    /// them faster than anybody wants to read them. Zero is never.
    pub(crate) said_at: u32,
    /// When the credential used at the door expires. Guests have no credential.
    /// A rated pilot proves their standing again through the renewable lease;
    /// a watcher has no lease, so this clock closes a session that has outlived
    /// the token which admitted it.
    pub(crate) expires: Option<u64>,
    /// Which connection this is, for the pilot log. On the seat rather than
    /// beside the socket because the two places a pilot's handles are reissued
    /// underneath them, sitting out and flying again, both carry the seat
    /// across and neither is a new session.
    pub(crate) session: pilot::Session,
}

impl Seat {
    /// A pilot with no account. This is what a deployment running without a
    /// meta-layer produces for everybody, and what a test wants when the thing
    /// under test is seats rather than identity.
    #[cfg(test)]
    pub(crate) fn guest(name: impl Into<String>, bot: bool) -> Seat {
        let name = name.into();
        Seat {
            rid: name.clone(),
            name,
            bot,
            label: if bot {
                token::Label::ThirdPartyBot.to_byte()
            } else {
                token::Label::Unknown.to_byte()
            },
            account: None,
            carried: None,
            said_at: 0,
            expires: None,
            session: pilot::Session::new("none"),
        }
    }
}

/// The rating id for an account. Prefixed so it can never collide with a call
/// sign, which is the other thing that lands in this namespace.
pub(crate) fn account_rid(account: u64) -> String {
    format!("a{account}")
}

/// File one line of the pilot log.
///
/// Every emitter in this file ends up here. It is a free function rather than
/// a method because the two callers that matter hold different things: a room
/// knows its number and its tick, and the door knows neither and still has to
/// record the refusal it just sent.
///
/// Nothing here can fail in a way a caller should handle. A poisoned lock, an
/// unarmed spool and a session out of budget all mean the same thing to the
/// game, which is that play continues and this line is not written down.
pub(crate) fn file_event(
    pilots: &std::sync::Arc<std::sync::Mutex<spool::Spool<pilot::Event>>>,
    session: &pilot::Session,
    kind: &str,
    who: Option<&Seat>,
    room: Option<u32>,
    tick: u32,
    detail: serde_json::Value,
) {
    let Ok(mut s) = pilots.lock() else { return };
    // Budget is spent only when there is somewhere for the row to go, so a
    // deployment with no meta-layer does not quietly exhaust every session's
    // allowance against a spool that writes nothing. Combat is exempt from
    // spending altogether: see `pilot::budgeted`.
    if !s.armed() || (pilot::budgeted(kind) && !session.spend()) {
        return;
    }
    s.push(pilot::Event {
        id: rand::random(),
        at: fleet::now_ms(),
        session: session.id.clone(),
        kind: kind.to_string(),
        pilot: who.and_then(|w| w.account),
        name: who.map(|w| w.name.clone()).unwrap_or_default(),
        bot: who.map(|w| w.bot).unwrap_or(false),
        room,
        tick,
        detail,
    });
}

/// One simulation: a world, the pilots seated in it, and the rules they are
/// playing under. The unit of "can these two shoot each other", so two pilots
/// in the same zone but different rooms share nothing but a name on a list.
///
/// An arena server holds one of these per room it has open, up to the zone's
/// `max_rooms`. See `ArenaServer` below.
fn match_message(state: modes::MatchState, artifact: Option<u64>) -> Vec<u8> {
    let mut flags = u8::from(state.playing) * MATCH_PLAYING;
    if artifact.is_some() {
        flags |= MATCH_HAS_ARTIFACT;
    }
    let mut out = vec![
        S2C_MATCH,
        flags,
        state.seconds_left,
        state.score.len().min(255) as u8,
    ];
    for score in state.score.iter().take(255) {
        out.extend_from_slice(&score.to_le_bytes());
    }
    if let Some(id) = artifact {
        out.extend_from_slice(&id.to_le_bytes());
    }
    out
}

pub(crate) struct Room {
    /// This room's number, which is what a player calls it and the only handle
    /// a join may name it by. Chosen when the room opens, from the numbers no
    /// live room of this zone is using, and held until it closes.
    ///
    /// Never its position in `ArenaServer::rooms`. Reclaiming an empty room
    /// shifts every position after it, so a join keyed on one would land a
    /// pilot in a room they did not pick, and a number read off a directory's
    /// ordering moves every time anybody joins anything.
    pub(crate) number: u32,
    pub(crate) world: sim::World,
    /// Everybody connected, humans and bots alike. There is no separate bot
    /// list: a bot is a client, so it is a row here with a flag on it, and
    /// nothing in the tick can tell the two apart.
    pub(crate) players: HashMap<u64, Player>,
    /// Everybody watching. Beside `players` rather than inside it, because
    /// every rule that reads `players` -- the human cap, the fill target, the
    /// drain, the tick's input loop -- is a rule about people in the game, and
    /// a watcher is in the room without being in the game.
    pub(crate) watchers: HashMap<u64, Watcher>,
    /// The most watchers this room admits, the zone's number.
    pub(crate) max_watchers: usize,
    pub(crate) channel: Channel,
    /// Ships somebody is currently looking at, as last announced. Held so the
    /// tally can be recomputed every snapshot and only its edges sent.
    pub(crate) on_air: std::collections::HashSet<u8>,
    pub(crate) names: HashMap<u8, Seat>,
    /// Where rated events go on their way out of this process. Shared with
    /// every other room here, because the spool is a property of the process
    /// and its disk rather than of a room.
    pub(crate) spool: std::sync::Arc<std::sync::Mutex<spool::Spool<spool::Event>>>,
    /// And where the pilot log goes. A second spool rather than a second kind
    /// of row in the first, because the two land in different tables and are
    /// kept for different lengths of time.
    pub(crate) pilots: std::sync::Arc<std::sync::Mutex<spool::Spool<pilot::Event>>>,
    /// Completed matches, including the short replay the public result opens.
    pub(crate) matches: std::sync::Arc<std::sync::Mutex<spool::Spool<growth::Artifact>>>,
    /// Rating id to account, for the pilots in this room that have one.
    ///
    /// It outlives the seat on purpose. A pilot who leaves can still appear as
    /// a contributor to somebody else's death a moment later, since leaving
    /// clears their own ledger and not their credit in anybody else's, and an
    /// event that loses that contributor loses the rating with it.
    pub(crate) accounts: HashMap<rating::Id, u64>,
    pub(crate) next_id: u64,
    pub(crate) rating: rating::Rating,
    pub(crate) mode: Box<dyn modes::Mode>,
    pub(crate) banner: String,
    pub(crate) finished: bool,
    /// Every side this room currently holds, by the byte the simulation knows
    /// it as. The zone's own come first and outlive every round; the rest are
    /// private, founded by players, and removed when their last member goes.
    /// See design/teams.md.
    pub(crate) teams: BTreeMap<u8, Team>,
    /// How many of the zone's teams are its own, which is the count a mode
    /// scores over. Private teams take bytes from here up and can never win a
    /// flag round.
    pub(crate) public_teams: u8,
    /// The three caps that are the whole of the team policy. There is no
    /// balance rule beyond them, so the only refusal a player can meet is a
    /// full team.
    pub(crate) max_teams: u8,
    pub(crate) max_humans_per_team: u16,
    pub(crate) max_bots_per_team: u16,
    /// Tunable connection-quality thresholds for this zone.
    pub(crate) lag_policy: config::LagConfig,
    /// Generation of the tuning currently applied to `world`. Snapshots carry
    /// it so one sent under new physics cannot be predicted with an older
    /// settings pack that is still crossing the reliable stream.
    pub(crate) settings_generation: u32,
    /// Standing invitations, by the ship they were extended to. A private team
    /// admits nobody else. Cleared with the seat, because a seat is furniture
    /// and the next occupant was invited to nothing.
    pub(crate) invites: HashMap<u8, std::collections::HashSet<u8>>,
    /// Where the next founded side takes its name from. It only moves forward,
    /// so leaving a side and starting another hands out a different word rather
    /// than the one the reaper just freed.
    pub(crate) name_cursor: usize,
    /// The zone tuning this room is running, kept so it can be put back on
    /// after the ground changes. Swapping a map resets the settings to the
    /// baseline, because most of the baseline is derived from the geometry it
    /// was built against, so a room on its second map would otherwise be a
    /// room that had quietly forgotten its zone file.
    pub(crate) tuning: config::ArenaConfig,
    /// The last match message sent, so the tick can send one only when the
    /// clock or the score has actually moved. That is about twice a second in
    /// a busy match and once a second in a quiet one, against a hundred a
    /// second if the tick simply sent it.
    pub(crate) last_match: Option<Vec<u8>>,
    /// Every map this zone plays, in the order it named them, and which of
    /// them this room is on. A match game takes the next at every whistle, so
    /// two people playing back to back do not play the same ground twice.
    ///
    /// Shared with the room's siblings rather than unpacked per room: a zone
    /// with four maps holds four sets of tiles for the whole process.
    pub(crate) maps: Vec<std::sync::Arc<sim::sim_map>>,
    /// What each of those is called, same order and length. Presentation
    /// only: the client captions its map panel with it, and a room built
    /// without names (tests, the built-in arena) sends none.
    pub(crate) map_names: Vec<String>,
    pub(crate) map_at: usize,
    /// Matches this room has opened, so the one being played is number one.
    /// Zero is a room that has not started yet, which is the difference
    /// between opening a match and opening the next one: the first is played
    /// on the ground the room was built on and only the ones after it change
    /// it.
    pub(crate) match_no: u32,
    /// The room tick at the opening whistle. A match payout requires thirty
    /// seconds on the field, so an arrival in the closing seconds cannot farm
    /// the participation grant.
    pub(crate) match_opened_at: u32,
    pub(crate) artifact_id: Option<i64>,
    pub(crate) replay: growth::Recorder,
    /// The share of this room's seats the bot server is asked to keep filled.
    /// The room does not fill anything itself; it publishes the count it would
    /// like and the bot server supplies it, per decision 29.
    pub(crate) bot_fill: f32,
}

impl Room {
    /// Apply the operator's tuning over a fresh baseline, and report anything
    /// the file asked for that could not be done.
    ///
    /// Rebuilding first is what makes a reload mean the file as it stands
    /// rather than the file plus everything it has ever said: a deleted line
    /// used to stay in force until a restart, and a weapon block would append
    /// another row every time the file was saved.
    /// The same thing on a room, which also remembers what it was given. A
    /// match game changes ground between matches and has to be able to put the
    /// tuning back on afterwards; a calibration harness has a world and no
    /// room, which is why the plain function stays.
    pub(crate) fn retune(&mut self, c: &config::ArenaConfig) -> Vec<String> {
        self.tuning = c.clone();
        Room::apply_config(&mut self.world, c)
    }

    pub(crate) fn apply_config(world: &mut sim::World, c: &config::ArenaConfig) -> Vec<String> {
        let mut warn = Vec::new();
        world.reset_settings();
        // The room, and the shape of the space in it. Every one of these is
        // absent-means-baseline rather than zero-means-baseline, because zero
        // is a legal value for most of them: a bounce of zero is a wall that
        // eats everything that hits it, and a door period of zero is a zone
        // whose doors never open.
        if let Some(v) = c.bounce {
            world.cfg.bounce = v;
        }
        if let Some(v) = c.friction {
            world.cfg.friction = v;
        }
        if let Some(v) = c.respawn_delay {
            world.cfg.respawn_delay = v;
        }
        if let Some(v) = c.spawn_radius {
            world.cfg.spawn_radius = v;
        }
        if let Some(v) = c.show_spawns {
            world.cfg.show_spawns = v as u8;
        }
        if let Some(v) = c.safe_limit {
            world.cfg.safe_limit = v;
        }
        // The core clamps this to SIM_MAX_SHIPS and reads zero as the ceiling,
        // so a zone asking for more than the array holds gets the array rather
        // than an overflow.
        if let Some(v) = c.max_ships {
            world.cfg.max_ships = v;
        }
        if let Some(v) = c.flag_radius {
            world.cfg.flag_radius = v * 256;
        }
        if let Some(v) = c.flag_drop_cooldown {
            world.cfg.flag_drop_cooldown = v;
        }
        if let Some(v) = c.flag_carry {
            world.cfg.flag_carry = u8::from(v);
        }
        if let Some(v) = c.flag_carry_seconds {
            world.cfg.flag_carry_ticks = v.saturating_mul(modes::TICKS_PER_SECOND as u16);
        }
        if let Some(v) = c.greens {
            world.cfg.green_target = v.min(sim::MAX_GREENS as u8);
            if v as usize > sim::MAX_GREENS {
                warn.push(format!(
                    "greens: the core holds {} at once and the file asks for {v}",
                    sim::MAX_GREENS
                ));
            }
        }
        if let Some(v) = c.green_seconds {
            world.cfg.green_life = v.saturating_mul(modes::TICKS_PER_SECOND as u16);
        }
        if let Some(v) = c.green_every_seconds {
            world.cfg.green_every = v.saturating_mul(modes::TICKS_PER_SECOND as u16);
        }
        if let Some(v) = c.green_near_tiles {
            world.cfg.green_near = v * sim::TILE_PX * 256;
        }
        if let Some(v) = c.green_far_tiles {
            world.cfg.green_far = v * sim::TILE_PX * 256;
        }
        if let Some(v) = c.green_radius {
            world.cfg.green_radius = v * 256;
        }
        if !c.green_weights.is_empty() {
            world.cfg.green_weight = [0; sim::SLOT_COUNT];
            for (name, weight) in &c.green_weights {
                match Self::slot_index(name) {
                    Some(i) => world.cfg.green_weight[i] = *weight,
                    // Named and not found is a green that will never appear,
                    // which is exactly the kind of quiet nothing the mode key
                    // used to be. Said out loud instead.
                    None => warn.push(format!("green_weights: no kit slot called {name:?}")),
                }
            }
        }
        // A ring the wrong way round puts every green on one circle, which is
        // a strange enough room to be worth a line about.
        if world.cfg.green_far < world.cfg.green_near {
            warn.push(format!(
                "greens: the ring's far edge ({}) is inside its near one ({})",
                world.cfg.green_far / (sim::TILE_PX * 256),
                world.cfg.green_near / (sim::TILE_PX * 256)
            ));
        }
        if let Some(v) = c.door_period {
            world.cfg.door_period = v;
        }
        if let Some(v) = c.door_open {
            world.cfg.door_open = v;
        }
        if let Some(v) = c.wormhole_pull {
            world.cfg.wormhole_pull = unsafe { sim::sim_units_speed(v) };
        }
        if let Some(v) = c.wormhole_top_speed {
            world.cfg.wormhole_top_speed = unsafe { sim::sim_units_speed(v) };
        }
        if let Some(v) = c.gravity_bombs {
            world.cfg.gravity_bombs = v as u8;
        }
        if let Some(v) = c.wormhole_range {
            world.cfg.wormhole_range = v * 256;
        }

        // Weapons are named here and numbered in the core. There is one gun
        // and one bomb in this game, whoever is flying, so rung zero of each
        // gets the name an operator would guess, `gun` or `bomb`, and
        // anything else in the file is a weapon that did not exist before. A
        // trigger is a ladder, so the rungs above that one are `gun-2` and
        // up, which reads as the level it is.
        //
        // These were per hull, `apex-gun` and `anvil-bomb`, back when a hull
        // owned its weapons. Tuning one now tunes it for the room.
        let mut named: Vec<(String, u8)> = Vec::new();
        let cls = world.cfg.classes[0];
        for (t, trig) in ["gun", "bomb"].iter().enumerate() {
            for (rung, &pat) in cls.trigger[t].iter().enumerate() {
                if pat == sim::NO_PATTERN {
                    break;
                }
                let n = if rung == 0 {
                    (*trig).to_string()
                } else {
                    format!("{trig}-{}", rung + 1)
                };
                named.push((n, pat));
            }
        }
        // And the weapons that belong to a slot in the settings rather than to
        // a trigger: the four charges, and what each rung of shrapnel breaks
        // into. Without names those were the only weapons in the zone an
        // operator could not touch: the repel's own radius was ours and
        // nobody else's.
        for (name, pat) in Room::slots(world) {
            if pat != sim::NO_PATTERN {
                named.push((name, pat));
            }
        }
        if let Some(v) = c.streak_kills {
            world.cfg.streak_kills = v;
        }
        if let Some(v) = c.multi_energy {
            world.cfg.mod_multi_energy = v;
        }
        if let Some(v) = c.multi_delay {
            world.cfg.mod_multi_delay = v;
        }
        // What a rung of each add-on is worth, before any hull is told which
        // ones it may hold.
        for (name, v) in &c.mod_step {
            match Room::mod_index(name) {
                Some(m) => {
                    world.cfg.mod_step[m] = match m {
                        sim::MOD_PROX => v * 256, // px
                        sim::MOD_PUSH => unsafe { sim::sim_units_speed(*v) },
                        _ => *v,
                    }
                }
                None => warn.push(format!("\"{name}\" is not an add-on")),
            }
        }
        if let Some(v) = c.mod_spread {
            world.cfg.mod_spread = ((v as i64 * 65536 / 360) & 0xffff) as u16;
        }
        if let Some(v) = c.prox_step {
            world.cfg.prox_step = v * 256;
        }
        if let Some(v) = c.prox_delay {
            world.cfg.prox_delay = v;
        }
        if let Some(v) = c.bomb_safety {
            world.cfg.bomb_safety = v as u8;
        }
        if let Some(v) = c.bbomb_damage {
            world.cfg.bbomb_damage = v;
        }
        if let Some(v) = c.shrap_inactive {
            world.cfg.shrap_inactive = unsafe { sim::sim_units_energy(v) };
        }
        if let Some(v) = c.shrap_inactive_ticks {
            world.cfg.shrap_inactive_ticks = v;
        }
        // Two passes, because a splinter may name a weapon written later in
        // the file, or one that does not exist until this pass makes it.
        for w in &c.weapons {
            if w.name.is_empty() {
                warn.push("a weapon with no name is a weapon nothing can point at".into());
                continue;
            }
            if named.iter().any(|(n, _)| *n == w.name) {
                continue;
            }
            match world.add_weapon() {
                Some(p) => {
                    // A slot name the baseline left empty -- `charge-3`, say
                    // -- fills that slot as well as making the weapon, so a
                    // zone adding a third charge writes one block rather than
                    // a block and a wiring line that does not exist.
                    Room::fill_slot(world, &w.name, p);
                    named.push((w.name.clone(), p));
                }
                None => warn.push(format!("no room in the weapon table for \"{}\"", w.name)),
            }
        }
        for w in &c.weapons {
            let Some(&(_, pat)) = named.iter().find(|(n, _)| *n == w.name) else {
                continue;
            };
            Room::apply_weapon(world, &named, pat, w, &mut warn);
        }

        for s in &c.ships {
            let Some(idx) = ai::class_index(&s.name) else {
                warn.push(format!("no hull called \"{}\"", s.name));
                continue;
            };
            // This hull's flight. Flat, because nobody upgrades one: the
            // floor, the step and the ceiling all move together, so a zone
            // writes one number a stat and gets exactly that.
            {
                let class = &mut world.cfg.classes[idx];
                for (want, floor, step, cap, to_core) in [
                    (
                        s.speed,
                        &mut class.init_speed,
                        &mut class.up_speed,
                        &mut class.max_speed,
                        sim::units_speed as fn(i32) -> i32,
                    ),
                    (
                        s.thrust,
                        &mut class.init_thrust,
                        &mut class.up_thrust,
                        &mut class.thrust,
                        sim::units_thrust as fn(i32) -> i32,
                    ),
                    (
                        s.rotation,
                        &mut class.init_rot,
                        &mut class.up_rot,
                        &mut class.rot,
                        sim::units_rotation as fn(i32) -> i32,
                    ),
                    (
                        s.energy,
                        &mut class.init_energy,
                        &mut class.up_energy,
                        &mut class.max_energy,
                        sim::units_energy as fn(i32) -> i32,
                    ),
                    (
                        s.recharge,
                        &mut class.init_recharge,
                        &mut class.up_recharge,
                        &mut class.recharge,
                        sim::units_recharge as fn(i32) -> i32,
                    ),
                ] {
                    if let Some(v) = want {
                        let v = to_core(v);
                        *floor = v;
                        *step = 0;
                        *cap = v;
                    }
                }
            }
            // The row above was written straight into the class, so the
            // core's bounds have not been applied to it yet. Clamping here is
            // what makes them a rule about the game rather than a property of
            // the shipped roster, and a number that moves is reported: a zone
            // asking for a 5000 speed and getting 3750 should hear about it
            // from the file rather than from a stopwatch.
            for (label, want, band) in [
                ("speed", s.speed, sim::SPEED_BAND),
                ("rotation", s.rotation, sim::ROTATION_BAND),
                ("energy", s.energy, sim::ENERGY_BAND),
                ("recharge", s.recharge, sim::RECHARGE_BAND),
            ] {
                if let Some(v) = want {
                    if v < band.0 || v > band.1 {
                        warn.push(format!(
                            "{}: {label} {v} is outside {} to {}, held at the edge",
                            s.name, band.0, band.1
                        ));
                    }
                }
            }
            unsafe { sim::sim_class_clamp(&mut world.cfg.classes[idx]) };
        }

        warn
    }

    /// What this room builds its mode from: the flags it actually laid, the
    /// sides the zone named, and the two clocks a match game runs on. One
    /// place, so a room built at startup and a room grown later cannot differ
    /// on any of it.
    ///
    /// Seconds in the file, ticks here, because the arena runs at 100 Hz and a
    /// zone file is written by a person.
    pub(crate) fn mode_setup(&self, c: &config::ArenaConfig) -> modes::Setup {
        modes::Setup {
            flags: self.world.state.flag_count,
            teams: self.public_teams,
            match_ticks: c.match_seconds.unwrap_or(180) as u32 * 100,
            intermission_ticks: c.intermission_seconds.unwrap_or(25) as u32 * 100,
            turf_period: c.turf_seconds.unwrap_or(5) as u32 * 100,
        }
    }

    /// The weapons that belong to a settings slot rather than to a hull, under
    /// the names a zone file reaches them by: `repel` and `burst` for the two
    /// charges the baseline fills, and `shrapnel-1` up, one per rung of the
    /// add-on.
    ///
    /// Charges are named for what they are rather than for the slot they sit
    /// in, because a slot number is an implementation detail of the kit space
    /// and a zone file is written by a person.
    pub(crate) fn slots(world: &sim::World) -> Vec<(String, u8)> {
        let mut v = Vec::new();
        const NAMED: [&str; 2] = ["repel", "burst"];
        for k in 0..sim::MAX_CHARGES {
            let name = NAMED
                .get(k)
                .map(|s| (*s).to_string())
                .unwrap_or_else(|| format!("charge-{}", k + 1));
            v.push((name, world.cfg.charge[k]));
        }
        for k in 1..sim::MAX_RUNGS {
            v.push((format!("shrapnel-{k}"), world.cfg.mod_splinter[k]));
        }
        v
    }

    /// Put a freshly made weapon in the slot its name asks for, if it asks for
    /// one. This is what lets a zone fill a slot the baseline leaves empty.
    pub(crate) fn fill_slot(world: &mut sim::World, name: &str, pat: u8) {
        if let Some(k) = Room::charge_named(name) {
            world.cfg.charge[k] = pat;
        } else if let Some(n) = name.strip_prefix("charge-") {
            if let Ok(k) = n.parse::<usize>() {
                if (1..=sim::MAX_CHARGES).contains(&k) {
                    world.cfg.charge[k - 1] = pat;
                }
            }
        } else if let Some(n) = name.strip_prefix("shrapnel-") {
            if let Ok(k) = n.parse::<usize>() {
                if (1..sim::MAX_RUNGS).contains(&k) {
                    world.cfg.mod_splinter[k] = pat;
                }
            }
        }
    }

    /// The charge kinds this game ships, by the name a zone file uses. A
    /// zone says `repel` rather than `charge-1`, because which slot a kind
    /// sits in is an implementation detail and what it is is not. The
    /// positional names still work for the slots nothing has claimed.
    pub(crate) fn charge_named(name: &str) -> Option<usize> {
        match name {
            "repel" => Some(sim::CHARGE_REPEL),
            "burst" => Some(sim::CHARGE_BURST),
            _ => None,
        }
    }

    /// Add-ons are named in a zone file and numbered in the core. The order
    /// is `sim_mod`'s and the names are the ones the design doc uses.
    pub(crate) fn mod_index(name: &str) -> Option<usize> {
        const NAMES: [&str; sim::MOD_COUNT] =
            ["multi", "bounce", "prox", "shrapnel", "freeze", "push"];
        NAMES.iter().position(|n| n.eq_ignore_ascii_case(name))
    }

    /// A kit slot, by the name a zone file calls it.
    ///
    /// The flat space has four kinds in it and this is the one place they are
    /// written out as words, because a green weight table is the only file
    /// that names a slot directly. The forms are the ones the rest of a zone
    /// file already uses: a stat by its own name, a weapon rung as
    /// `gun`/`bomb`, an add-on as `gun.multi`, and a charge as `repel` or
    /// `burst`, which is what `[arena.kit]` and `[[arena.weapons]]` call the
    /// two the baseline fills.
    pub(crate) fn slot_index(name: &str) -> Option<usize> {
        const STATS: [&str; sim::UP_COUNT] = ["energy", "recharge", "speed", "thrust", "rotation"];
        const TRIGGERS: [&str; sim::TRIG_COUNT] = ["gun", "bomb"];
        const CHARGES: [&str; 2] = ["repel", "burst"];
        let name = name.trim();
        if let Some(i) = STATS.iter().position(|n| n.eq_ignore_ascii_case(name)) {
            return Some(sim::slot_stat(i) as usize);
        }
        if let Some((trigger, add_on)) = name.split_once('.') {
            let t = TRIGGERS
                .iter()
                .position(|n| n.eq_ignore_ascii_case(trigger.trim()))?;
            let m = Self::mod_index(add_on.trim())?;
            return Some(sim::slot_mod(t, m) as usize);
        }
        if let Some(i) = TRIGGERS.iter().position(|n| n.eq_ignore_ascii_case(name)) {
            return Some(sim::slot_level(i) as usize);
        }
        CHARGES
            .iter()
            .position(|n| n.eq_ignore_ascii_case(name))
            .map(|i| sim::slot_charge(i) as usize)
    }

    /// One weapon block, over whatever that weapon already was. The units are
    /// the ones the rest of the file uses -- px, px/s/10, energy, ticks --
    /// and degrees, because nobody thinks in sixty-five thousandths of a turn.
    pub(crate) fn apply_weapon(
        world: &mut sim::World,
        named: &[(String, u8)],
        pat: u8,
        w: &config::WeaponConfig,
        warn: &mut Vec<String>,
    ) {
        let spec_idx = world.cfg.patterns[pat as usize].spec as usize;
        let sp = &mut world.cfg.specs[spec_idx];
        unsafe {
            if let Some(v) = w.speed {
                sp.speed = sim::sim_units_speed(v);
            }
            if let Some(v) = w.push {
                sp.push = sim::sim_units_speed(v);
            }
            if let Some(v) = w.damage {
                sp.damage = sim::sim_units_energy(v);
            }
        }
        if let Some(v) = w.push_time {
            sp.push_time = v;
        }
        if let Some(v) = w.life {
            sp.life = v;
        }
        if let Some(v) = w.bounces {
            sp.bounces = v;
        }
        if let Some(v) = w.trigger {
            sp.trigger = v * 256;
        }
        if let Some(v) = w.blast {
            sp.blast = v * 256;
        }
        if let Some(v) = w.stall {
            sp.stall = v;
        }
        if let Some(v) = w.expire_ends {
            sp.expire_ends = v as u8;
        }
        if let Some(rule) = &w.on_wall {
            match rule.as_str() {
                "end" => sp.on_wall = 0,
                "bounce" => sp.on_wall = 1,
                "pass" => sp.on_wall = 2,
                other => warn.push(format!(
                    "\"{other}\" is not a wall rule: end, bounce or pass"
                )),
            }
        }
        if let Some(name) = &w.splinter {
            // Naming itself is legal and bounded: the core stops a fragment
            // fragmenting by the generation it carries, not by the table.
            match named.iter().find(|(n, _)| n == name) {
                Some(&(_, p)) => world.cfg.specs[spec_idx].splinter = p,
                None if name.is_empty() => world.cfg.specs[spec_idx].splinter = sim::NO_PATTERN,
                None => warn.push(format!(
                    "\"{}\" splinters into \"{name}\", which is not a weapon",
                    w.name
                )),
            }
        }
        let p = &mut world.cfg.patterns[pat as usize];
        unsafe {
            if let Some(v) = w.recoil {
                p.recoil = sim::sim_units_speed(v);
            }
            if let Some(v) = w.energy {
                p.energy = sim::sim_units_energy(v);
            }
        }
        if let Some(v) = w.count {
            p.count = v;
        }
        if let Some(v) = w.delay {
            p.delay = v;
        }
        if let Some(v) = w.spread {
            p.spacing = ((v as i64 * 65536 / 360) & 0xffff) as u16;
        }
    }

    pub(crate) fn new_from(cfg: &config::ZoneConfig) -> Self {
        let mut a = Room::new_on_maps(&cfg.maps);
        // Mode and flags were keys in the file that nobody read: the arena
        // built a four-flag warzone whatever they said. They settle at start
        // rather than on reload, because changing what a round is for while
        // one is being played is not a tuning change.
        //
        // Flags can come down but not up: where they stand is the map's, and
        // the built-in arena puts four in the four quadrants. A zone asking
        // for more is told so rather than quietly given four.
        let placed = a.world.state.flag_count;
        if let Some(want) = cfg.arena.flags {
            if want > placed {
                println!("zone: this map places {placed} flags and the file asks for {want}");
            }
            a.world.state.flag_count = want.min(placed);
        }
        a.mode = modes::build(&cfg.arena.mode, &a.mode_setup(&cfg.arena));
        for w in a.retune(&cfg.arena) {
            println!("zone: {w}");
        }
        a.lag_policy = cfg.arena.lag.clone();
        a
    }

    /// A zone's own maps, if it named any, with the room opening on the first.
    /// A map that will not load is reported and then skipped: a zone that
    /// refuses to start because of a bad file is worse for the people trying
    /// to play in it than one that runs what it can and says so.
    pub(crate) fn new_on_maps(paths: &[String]) -> Self {
        let mut maps = Vec::new();
        let mut names = Vec::new();
        for path in paths {
            match std::fs::read(path)
                .map_err(|e| e.to_string())
                .and_then(|b| {
                    let n = b.len();
                    sim::unpack_map(&b).map(|m| (m, n))
                }) {
                Ok((m, n)) => {
                    println!("map {path}: {n} bytes");
                    maps.push(m);
                    names.push(
                        std::path::Path::new(path)
                            .file_stem()
                            .map(|s| s.to_string_lossy().into_owned())
                            .unwrap_or_default(),
                    );
                }
                Err(e) => println!("map {path}: {e}; skipped"),
            }
        }
        let Some(first) = maps.first() else {
            if !paths.is_empty() {
                println!("no map loaded; running the built-in arena");
            }
            return Room::new();
        };
        let mut room = Room::with_world(sim::World::on_map(0x5eed, first.clone()));
        room.maps = maps;
        room.map_names = names;
        room
    }

    /// The built-in arena, which is the room a process holds when it has no
    /// zone to serve and the ground every warzone test flies.
    ///
    /// Its four flags are put here rather than in `with_world` because they
    /// are this arena's: 1024 tiles wide, with the stands forty tiles out
    /// from the middle. A zone map that draws no stands has said it is not a
    /// flag game and gets none.
    pub(crate) fn new() -> Self {
        let mut a = Self::with_world(sim::World::new(0x5eed));
        a.add_default_flags();
        a
    }

    pub(crate) fn with_world(world: sim::World) -> Self {
        let mut a = Room::with_world_bare(world);
        // The built-in arena's own defaults, which a catalog zone replaces
        // the moment it names its clocks.
        a.mode = Box::new(modes::Warzone::new(
            4,
            a.public_teams,
            240 * modes::TICKS_PER_SECOND,
            15 * modes::TICKS_PER_SECOND,
        ));
        a.place_flags();
        a
    }

    /// An empty room. A catalog zone builds one of these and then decides its
    /// mode, its teams and its population, rather than inheriting a warzone.
    pub(crate) fn with_world_bare(world: sim::World) -> Self {
        Room {
            // One. An arena server renumbers it the moment it knows which zone
            // it is serving and what the rest of the fleet is holding; a room
            // built for a test never needs more than a number that exists.
            number: 1,
            world,
            players: HashMap::new(),
            watchers: HashMap::new(),
            max_watchers: DEFAULT_MAX_WATCHERS,
            channel: Channel::new(),
            on_air: std::collections::HashSet::new(),
            names: HashMap::new(),
            accounts: HashMap::new(),
            // Replaced by the process's own the moment an arena server takes
            // ownership. A room built and never handed one writes nothing,
            // which is the right answer for a room in a test.
            spool: std::sync::Arc::new(std::sync::Mutex::new(spool::Spool::rated("/nonexistent"))),
            pilots: std::sync::Arc::new(std::sync::Mutex::new(spool::Spool::pilot("/nonexistent"))),
            matches: std::sync::Arc::new(std::sync::Mutex::new(spool::Spool::matches(
                "/nonexistent",
            ))),
            next_id: 1,
            rating: rating::Rating::new(),
            mode: Box::new(modes::FreeForAll),
            banner: String::new(),
            finished: false,
            // A room nobody has configured is a free-for-all with no caps,
            // which is the shape that needs no settings to be playable.
            teams: BTreeMap::new(),
            public_teams: 0,
            max_teams: 255,
            max_humans_per_team: 255,
            max_bots_per_team: 255,
            lag_policy: Default::default(),
            settings_generation: 1,
            invites: HashMap::new(),
            name_cursor: 0,
            tuning: Default::default(),
            last_match: None,
            maps: Vec::new(),
            map_names: Vec::new(),
            map_at: 0,
            match_no: 0,
            match_opened_at: 0,
            artifact_id: None,
            replay: growth::Recorder::default(),
            bot_fill: catalog::DEFAULT_BOT_FILL,
        }
    }

    /// Humans in this room. What the player cap, the fill target and the drain
    /// all mean, and none of them mean bots: a room held at four fifths by the
    /// bot server would otherwise read as permanently full, never scale out,
    /// and never finish draining.
    pub(crate) fn humans(&self) -> usize {
        self.players.values().filter(|p| !p.bot).count()
    }

    pub(crate) fn bot_count(&self) -> usize {
        self.players.values().filter(|p| p.bot).count()
    }

    /// People in the stands. Guests count as people here because `Seat::bot`
    /// is the admission decision, while the public label only says whether an
    /// account has been claimed.
    pub(crate) fn human_spectators(&self) -> usize {
        self.watchers.values().filter(|w| !w.seat.bot).count()
    }

    /// Both arguments are read only by the assertions below, so a release
    /// build has a function that takes two things and looks at neither. That
    /// is the point of it rather than an oversight, and saying so here is
    /// cheaper than underscoring names the debug build uses.
    #[cfg_attr(not(debug_assertions), allow(unused_variables))]
    pub(crate) fn debug_assert_member(&self, id: u64, presence: &PresenceHandle) {
        #[cfg(debug_assertions)]
        {
            let player = self.players.get(&id);
            let watcher = self.watchers.get(&id);
            debug_assert!(player.is_none() || watcher.is_none());
            match presence.current() {
                Presence::Unjoined => {
                    debug_assert!(player.is_none());
                    debug_assert!(watcher.is_none());
                }
                Presence::Flying { room, member } => {
                    debug_assert_eq!(room, self.number);
                    debug_assert_eq!(member, id);
                    let player = player.expect("flying member has a player row");
                    debug_assert!(std::sync::Arc::ptr_eq(
                        &player.presence.state,
                        &presence.state
                    ));
                    debug_assert!(watcher.is_none());
                    debug_assert_ne!(self.world.state.ships[player.ship as usize].active, 0);
                    debug_assert!(self.names.contains_key(&player.ship));
                    debug_assert_eq!(
                        self.players
                            .values()
                            .filter(|other| other.ship == player.ship)
                            .count(),
                        1
                    );
                }
                Presence::Watching { room, member } => {
                    debug_assert_eq!(room, self.number);
                    debug_assert_eq!(member, id);
                    let watcher = watcher.expect("watching member has a watcher row");
                    debug_assert!(std::sync::Arc::ptr_eq(
                        &watcher.presence.state,
                        &presence.state
                    ));
                    debug_assert!(player.is_none());
                }
            }
        }
    }

    /// Change the public room number and every live member's stable address
    /// together. The fleet can settle a number collision while a room is live.
    pub(crate) fn renumber(&mut self, to: u32) {
        let from = self.number;
        if from == to {
            return;
        }
        for (id, player) in self.players.iter() {
            player
                .presence
                .transition(PresenceEvent::Renumber {
                    from,
                    to,
                    member: *id,
                })
                .expect("flying member belongs to renumbered room");
        }
        for (id, watcher) in self.watchers.iter() {
            watcher
                .presence
                .transition(PresenceEvent::Renumber {
                    from,
                    to,
                    member: *id,
                })
                .expect("watching member belongs to renumbered room");
        }
        self.number = to;
        for (id, player) in self.players.iter() {
            self.debug_assert_member(*id, &player.presence);
        }
        for (id, watcher) in self.watchers.iter() {
            self.debug_assert_member(*id, &watcher.presence);
        }
    }

    /// How many bots this room would like, and how many more it is short.
    ///
    /// The target is a share of the room rather than of what is free, so bots
    /// give way one for one as people arrive: 51 of 64 seats, then 50 once
    /// somebody joins, then 49. The thirteen seats that are never asked for are
    /// the headroom that keeps an arrival from waiting on a departure.
    pub(crate) fn bot_target(&self) -> usize {
        let seats = unsafe { sim::sim_eff_max_ships(&*self.world.cfg) } as usize;
        (seats as f32 * self.bot_fill).round() as usize
    }

    pub(crate) fn bots_wanted(&self) -> usize {
        self.bot_target().saturating_sub(self.humans())
    }

    /// One flag per quadrant, forty tiles out from the middle, so all four are
    /// on the radar of a pilot standing between them.
    ///
    /// They were three hundred tiles apart, which reads well and made the flag
    /// game unplayable: the shipped War map starts its pilots in a 68-tile box at
    /// the center, so the nearest flag was two hundred tiles away, past sixty
    /// tiles of sight, past the radar, and past anything that would take a pilot
    /// there. Watched live for four minutes: forty-two kills, four flags, and the
    /// banner never moved off "flags 0 - 0, 4 loose". Nobody had touched one.
    ///
    /// Forty is far enough that holding all four is a team's job -- eighty tiles
    /// between neighbours is about twelve seconds of flying, so a lone pilot
    /// collecting the set gives the other side time to flip one behind them --
    /// and near enough that a player can see what the round is about. The
    /// previous swing of this pendulum put them four tiles apart, which was one
    /// scrum in one room; this is between the two, not a return to it.
    pub(crate) fn add_default_flags(&mut self) {
        for (tx, ty) in [(472, 472), (552, 472), (472, 552), (552, 552)] {
            self.world.add_flag(tx, ty);
        }
    }

    /// Stand this room's flags where the map wants them.
    ///
    /// A map that draws flag stands owns where they are, which is the rule
    /// both flag games need and neither had: War's ground was four tiles
    /// hardcoded in this file for the built-in arena, and a turf map has
    /// nowhere else its stands could come from. The quadrants stay as the
    /// fallback for a map that names none, since that is the arena those
    /// numbers were measured on.
    ///
    /// Called again whenever the ground changes, because a rotation onto a
    /// map with its stands somewhere else would otherwise keep flying the
    /// last map's objective.
    ///
    /// A map that draws no stands gets no flags. The four quadrants below are
    /// the built-in arena's, measured on the 1024-tile ground that arena is,
    /// and they sit off the edge of every map a zone actually ships: a melee
    /// room carried four of them, unreachable, out past its own wall, and
    /// drew a pennant apiece across the top of the HUD for a game it was not
    /// playing.
    pub(crate) fn place_flags(&mut self) {
        self.world.state.flag_count = 0;
        for (tx, ty) in self.world.flag_stands() {
            self.world.add_flag(tx, ty);
        }
    }

    /// An arrival with nothing to say about which side they land on, which is
    /// every arrival that did not just get up out of a chair in this room.
    // Called by the tests rather than by the server, which reaches for the
    // fuller form beside it. Kept because it is the short way to say the
    // ordinary thing, and a test is a caller.
    #[cfg(test)]
    pub(crate) fn join(
        &mut self,
        seat: Seat,
        class: u8,
        max_players: usize,
        tx: mpsc::Sender<Message>,
    ) -> Option<u64> {
        self.join_with_presence(seat, class, max_players, tx, PresenceHandle::new())
    }

    pub(crate) fn join_with_presence(
        &mut self,
        seat: Seat,
        class: u8,
        max_players: usize,
        tx: mpsc::Sender<Message>,
        presence: PresenceHandle,
    ) -> Option<u64> {
        let logged = seat.clone();
        let id = self.join_on(seat, class, max_players, None, tx, None, presence)?;
        // After the seat is real, so the log never claims an arrival the caps
        // refused. The hull is read back rather than echoed: the core clamps a
        // class it does not have, and what the pilot is flying is the useful
        // number.
        let ship = self.players[&id].ship;
        self.note(
            pilot::JOIN,
            &logged,
            serde_json::json!({
                "class": self.world.state.ships[ship as usize].cls,
                "ship": ship,
                "team": self.world.state.ships[ship as usize].team,
                "label": logged.label,
                "transport": logged.session.transport,
            }),
        );
        Some(id)
    }

    /// `max_players` is the zone's, which used to be a constant here while the
    /// key in the file was read by nobody. It bounds humans; the room's own size
    /// is `arena.max_ships` and the two are different questions, since a wide
    /// room with a small player cap is a zone that wants mostly bots.
    ///
    /// `prefer` is a side this pilot already belongs to, which a watcher taking
    /// a hull has and nobody else does. It is honoured while the side exists and
    /// has room, and ignored otherwise rather than refused: a watcher whose side
    /// filled up while they sat out is still a player who wants to fly.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn join_on(
        &mut self,
        seat: Seat,
        class: u8,
        max_players: usize,
        prefer: Option<u8>,
        tx: mpsc::Sender<Message>,
        member: Option<u64>,
        presence: PresenceHandle,
    ) -> Option<u64> {
        let name = seat.name.clone();
        let bot = seat.bot;
        let valid_entry = match (member, presence.current()) {
            (None, Presence::Unjoined) => true,
            (
                Some(member),
                Presence::Watching {
                    room,
                    member: current,
                },
            ) => room == self.number && current == member,
            _ => false,
        };
        if !valid_entry {
            return None;
        }
        let lifecycle = member
            .and_then(|id| self.watchers.get(&id).map(|watcher| watcher.lifecycle))
            .map(next_nonzero)
            .unwrap_or(1);
        // The cap is on people. A declared bot passes it by, which is the whole
        // of what the declaration buys the arena: a zone can hold a wide room
        // mostly full of AI and still admit every human its operator allowed.
        if !bot && self.humans() >= max_players {
            return None;
        }
        // A joining pilot takes the next start in the map's rotation, so
        // arrivals spread across them instead of landing on each other.
        let class = class.min(self.world.cfg.class_count.saturating_sub(1));
        let nth = self.world.state.ship_count as u32;
        let mut ship = self.world.spawn_on_map(class, 0, nth, 0);
        if ship < 0 && !bot {
            // Every seat taken and a human at the door. The bot server leaves a
            // fifth of the room empty precisely so this does not happen, but a
            // burst of joins can outrun it: the target is recomputed on a
            // browse, and eight people can arrive between two of those. So the
            // room makes its own space, newest bot first.
            //
            // Refusing here instead would be the arena telling a player that a
            // room full of AI has no space for them, which is the one refusal
            // this design must never produce.
            if let Some(freed) = self.evict_bot() {
                ship = freed as i32;
            }
        }
        if ship < 0 {
            return None;
        }
        let ship = ship as u8;
        self.world.state.ships[ship as usize].kills = 0;
        self.world.state.ships[ship as usize].deaths = 0;

        // Which side an arrival lands on is the room's answer, not the
        // client's: the side they already hold if they hold one, else the
        // emptiest of the zone's own that has room, or a side of their own
        // where the zone names none. Moving is then one selection away in the
        // team list, and only a full side can refuse it.
        let team = match prefer {
            Some(t) if self.teams.contains_key(&t) && self.team_has_room(t, bot, Some(ship)) => t,
            _ => self.seat_team(ship, &seat),
        };
        // Where a fresh pilot starts, worked out before anything about them is
        // set: a seat is furniture, and its last occupant does not come with
        // it.
        let nth = self.world.state.ship_count as u32;
        // The core works it out, so a seat handed out here lands exactly where
        // a death would put the same pilot. This used to walk the map's tiles
        // itself and multiply by the tile size, which was a second copy of the
        // arithmetic and knew nothing about a spawn radius.
        let (sx, sy) = self.world.spawn_point(team, class, nth);
        {
            let sh = &mut self.world.state.ships[ship as usize];
            // Clamped against the roster the core actually holds rather
            // than a literal: a class byte comes off the wire, and the last
            // hull's index is one less than the count. Written out as 7 it
            // was right for eight hulls and one past the end for seven.
            sh.cls = class;
            sh.team = team;
            // Occupied, as well as alive. A seat taken back from a bot arrives
            // here inactive, because handing it over is `leave` followed by
            // this rather than a spawn, and `leave` is what empties a seat.
            // Only `alive` was set, so the new pilot sat in a chair the
            // simulation considered nobody's: the core skips an inactive ship,
            // and `sim_spawn` hands the first one it finds to the next arrival.
            // Two people, one seat, and neither of them flying.
            sh.active = 1;
            sh.alive = 1;
            // Everything a pilot carries, cleared. This was `up` alone, so a
            // seat handed on kept the last occupant's weapon levels, add-ons,
            // charges and run. Leaving and rejoining is the case that shows
            // it: seats come back in the order they were vacated, so a player
            // is handed their own and the zone reads as having saved their
            // game. The profile goes back on below, off the hull.
            sh.up = [0; sim::UP_COUNT];
            sh.level = [0; sim::TRIG_COUNT];
            sh.mods = [0; sim::TRIG_COUNT];
            sh.charge = [0; sim::MAX_CHARGES];
            sh.streak = 0;
            sh.stall = 0;
            sh.repel = 0;
            sh.repel_speed = 0;
            sh.fire_cooldown = [0; sim::TRIG_COUNT];
            sh.respawn_at = 0;
            // And where they are, which is the same bug wearing its most
            // obvious face: a pilot who rejoined appeared exactly where they
            // had left off.
            sh.x = sx;
            sh.y = sy;
            sh.vx = 0;
            sh.vy = 0;
            sh.spawn_x = sh.x;
            sh.spawn_y = sh.y;
        }
        // The kit is dealt by whoever seats this pilot, right after this, and
        // it has to be: the clear above took away everything, and the core no
        // longer outfits a ship it spawns because there is nothing to roll.
        // A seat inherited from a departing bot is not a spawn either, which
        // is what used to leave an arriving pilot plain in a zone whose bots
        // and repeat-deaths were all dressed.
        //
        // A full bar, asked for as the number it is, and after the class is
        // set, because the ceiling depends on it. This used to be i32::MAX with a
        // comment saying the core would clamp it; the core clamped it by adding
        // a tick of recharge first, which overflowed, so a joining ship spent
        // its first tick at INT32_MIN energy and one hit from dead. The core no
        // longer allows that, and this no longer asks for it.
        let full = self.world.eff_max_energy(ship as usize);
        self.world.state.ships[ship as usize].energy = full;
        let id = match member {
            Some(id) => id,
            None => {
                let id = self.next_id;
                self.next_id += 1;
                id
            }
        };
        let event = if member.is_some() {
            PresenceEvent::Resume {
                room: self.number,
                member: id,
            }
        } else {
            PresenceEvent::JoinFlying {
                room: self.number,
                member: id,
            }
        };
        presence
            .transition(event)
            .expect("validated presence entry");
        // A bot's rating moves slowly, so a human who kills one moves further
        // than it does. The room learns which pilots those are from what they
        // declared, rather than from a roster it holds a copy of: a bot the bot
        // server generated is as much a bot as one the tournament calibrated.
        if bot {
            self.rating.mark_bot(&seat.rid);
        }
        // The pinned reference personality, by account rather than by name once
        // it has one. It is the fixed point every other rating in the fleet is
        // measured against, so it is set wherever it sits.
        if seat.bot && seat.name == ai::ANCHOR {
            self.rating.set_anchor(&seat.rid, ai::ANCHOR_RATING);
        }
        let rid = seat.rid.clone();
        if let Some(a) = seat.account {
            self.accounts.insert(rid.clone(), a);
        }
        self.names.insert(ship, seat);
        self.players.insert(
            id,
            Player {
                ship,
                lifecycle,
                buttons: 0,
                pending: Default::default(),
                input_ack: 0,
                input_mask: 0,
                input_receipts: 0,
                input_seen: false,
                applied_tick: 0,
                applied_input: false,
                last_input_at: self.world.state.tick,
                combat_until: None,
                // Declared bots use sparse control heartbeats rather than a
                // tick-by-tick prediction stream, and lag policy already
                // exempts them. Human clients establish the coherent clock
                // that the missed-deadline metric requires.
                lag: if bot {
                    LagTracker::default()
                } else {
                    LagTracker::waiting_for_input()
                },
                name,
                rid,
                bot,
                safe: 0,
                // The join hands over the map itself, and sets this if the
                // socket refused it.
                owes_map: false,
                joined: self.world.state.tick,
                tx,
                presence,
            },
        );
        if member.is_some() {
            self.watchers.remove(&id);
        }
        // Dressed on arrival, whatever the room is doing. A pilot who spawns
        // into the middle of a match in a bare hull is a pilot who was better
        // off waiting, which is the thing joining a room in progress exists to
        // avoid.
        self.deal_seat(ship);
        // And a full bar again, because the kit just moved the ceiling. The
        // energy set above was full for a bare hull; a kit with four steps of
        // energy in it raises the maximum, and a ship one step short of full
        // is a ship the core refuses a hull change and a side change to.
        let full = self.world.eff_max_energy(ship as usize);
        self.world.state.ships[ship as usize].energy = full;
        // Unless the podium is up, in which case they join the wait rather
        // than a match that is not running. `close_match` benched everybody at
        // the whistle and the controls are held until the next one, so a pilot
        // seated alive now would be the one hull on an empty map, unable to
        // move it and hearing their own engine. Benched on the same terms as
        // everybody else, and `open_match` puts the whole room back.
        //
        // Last, after the kit and the bar, because both of those write the
        // fields this clears: the seat is dealt exactly as it would be for a
        // match, and then sat down.
        if self.mode.match_state().is_some_and(|m| !m.playing) {
            let sh = &mut self.world.state.ships[ship as usize];
            sh.alive = 0;
            sh.energy = 0;
            sh.respawn_at = 0;
        }
        // In a duel, taking a seat is the whistle. The match is between the
        // two seats, so whoever is in them now is the fight, and the clock
        // and the score belong to that fight rather than to the one the
        // seat's last occupant was having. Without this an arrival was put
        // into somebody else's match with the score already on the board:
        // two bots hold an empty room, one is evicted for the person at the
        // door, and the survivor's kills against it were the podium's whole
        // story at a whistle the arrival had not earned. Only while playing;
        // with the podium up the next match opens on its own, and a wait of
        // at most an intermission beats cutting a podium short.
        if self.is_duel() && self.mode.match_state().is_some_and(|m| m.playing) {
            self.mode.reopen();
        }
        self.debug_assert_member(id, &self.players[&id].presence);
        Some(id)
    }

    /// Apply an in-seat hull change, under the core's own rules, on the
    /// hull's own profile. A pilot who has spent their credits differently
    /// says so through `set_ship_kit`, which carries both at once.
    pub(crate) fn set_ship_class(&mut self, ship: u8, class: u8) -> bool {
        self.world.set_ship_class(ship, class, None)
    }

    /// Apply a ship: the hull it names and the build it carries.
    ///
    /// One act rather than two, because a build belongs to a hull and the
    /// two arriving separately would deal the wrong one in between: a pilot
    /// moving from an Anvil to a Cipher would fly a Cipher on the Cipher's
    /// own profile for as long as it took the second message to land, and
    /// their own build would arrive as a second re-deal.
    ///
    /// From a pilot in the air this is a ship change under the core's own
    /// rules: a full bar, and a respawn to pay for it. That holds whether
    /// what moved is the hull or the row, because a ship is both together;
    /// gating one and not the other would leave a refit as the free way out
    /// of a fight that is going badly.
    ///
    /// From a pilot who is not in the air it is dealt in place, because there
    /// is no fight to leave and no bar to have: a seat benched between
    /// matches takes its owner's build and flies it at the whistle, which is
    /// how a build arrives with a pilot who joined during a podium. A pilot
    /// waiting out a respawn is the same case, and re-speccing on the way
    /// back costs them the death they have already paid.
    ///
    /// Nothing here is checked against anything: the core fits every build
    /// to the ceilings and the budget on the way in, so a hostile client
    /// spends what a player spends. What it cannot do is refill: a build
    /// dealt either way clamps the rack down and never up, which is what
    /// stops a pilot reloading by opening a menu.
    pub(crate) fn set_ship_kit(&mut self, ship: u8, class: u8, kit: &[u8; sim::SLOT_COUNT]) {
        let sh = &self.world.state.ships[ship as usize];
        if sh.alive != 0 || sh.cls != class {
            self.world.set_ship_class(ship, class, Some(kit));
        } else {
            self.world.set_ship_kit(ship, kit);
        }
    }

    /// One of the fixed things, said to the room.
    ///
    /// Between matches only. That is where it is for, and it is also what
    /// keeps it out of a fight: nothing here can be used to talk over somebody
    /// who is trying to play. The phrase is an index into a list the clients
    /// hold, so this never sees a word and there is nothing here to moderate.
    ///
    /// Throttled to one every two seconds a seat. A line nobody can repeat
    /// faster than it can be read is a line that cannot be used to shout.
    pub(crate) fn say(&mut self, ship: u8, phrase: u8) {
        if phrase >= crate::protocol::SAY_COUNT {
            return;
        }
        if self.mode.match_state().is_some_and(|m| m.playing) {
            return;
        }
        let now = self.world.state.tick;
        match self.names.get_mut(&ship) {
            Some(seat) => {
                if seat.said_at != 0 && now.wrapping_sub(seat.said_at) < 200 {
                    return;
                }
                seat.said_at = now;
            }
            None => return,
        }
        let msg = vec![crate::protocol::S2C_SAID, ship, phrase];
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(msg.clone()));
        }
        // Said over a podium, and the stands are still looking at the last
        // of the match. It waits for the podium they can see.
        self.channel.pending_feed.push(msg);
    }

    /// Deal this seat what it is flying, which is the build on the ship,
    /// rack included.
    ///
    /// There is still nothing to choose and nothing to check here. A seat
    /// starts on its hull's own profile, so a pilot who has never opened a
    /// menu, a bot and a guest all arrive in a whole ship; a pilot who has
    /// spent their credits elsewhere put that on the ship through
    /// `set_ship_kit` before this ever runs, and a whistle deals it back
    /// without knowing which of the two it is handling.
    ///
    /// With ammunition, because both callers are moments that fill a rack: a
    /// pilot arriving, and a whistle. It dealt the frame alone and left the
    /// rack empty, which cost every pilot every charge they had. `join` builds
    /// a seat by hand rather than through `sim_spawn` and clears the counts on
    /// the way, so nothing put them back; a match start then re-dealt over the
    /// top of what `restart` had just filled. Charges were dim from the
    /// whistle and no key did anything.
    ///
    /// Not a respawn, which is the one moment that must not refill: that is
    /// the core's own path and deals the frame alone, so a pilot who has spent
    /// both repels flies the rest of the match without them and cannot reload
    /// by dying. A hull change is the core's too, and clamps rather than
    /// fills.
    pub(crate) fn deal_seat(&mut self, ship: u8) {
        self.world.deal_kit(ship as usize, true);
    }

    /// Take a seat back from the bot fewest people are looking at.
    ///
    /// This is the arena's half of yielding, and it is the half under time
    /// pressure: a human is at the door and the seat has to exist this tick,
    /// so unlike the bot server's half there is no walking out. What it can do
    /// is choose well. The room holds the whole simulation, so it knows which
    /// bots are dead, which have nobody near them, and which are in the middle
    /// of a fight somebody is watching.
    ///
    /// It used to take the newest, on the reasoning that a bot which just
    /// arrived is not in the middle of anything. That is a proxy for the
    /// question and not the question: the newest bot is as likely as any other
    /// to be the one currently trading shots with a player, and vanishing out
    /// of that is exactly the pop this ordering exists to avoid. Age only
    /// breaks ties now.
    pub(crate) fn evict_bot(&mut self) -> Option<u8> {
        // Lower is more expendable: dead, then alone, then anybody, and the
        // newest of whichever band wins.
        let cost = |p: &Player| -> u8 {
            let me = &self.world.state.ships[p.ship as usize];
            if me.alive == 0 {
                return 0;
            }
            let (mx, my) = (me.x as f32 / 256.0, me.y as f32 / 256.0);
            let watched = (0..self.world.state.ship_count as usize).any(|i| {
                let o = &self.world.state.ships[i];
                if i == p.ship as usize || o.active == 0 || o.alive == 0 {
                    return false;
                }
                let (dx, dy) = (o.x as f32 / 256.0 - mx, o.y as f32 / 256.0 - my);
                dx * dx + dy * dy < ai::SIGHT * ai::SIGHT
            });
            if watched {
                2
            } else {
                1
            }
        };
        let (id, ship) = self
            .players
            .iter()
            .filter(|(_, p)| p.bot)
            .min_by_key(|(id, p)| (cost(p), std::cmp::Reverse(**id)))
            .map(|(id, p)| (*id, p.ship))?;
        // Told, then removed. The message is a courtesy that lets a bot close
        // its own socket rather than work out from an empty simulation that it
        // is gone; the seat is taken either way.
        if let Some(p) = self.players.get(&id) {
            println!(
                "seat {ship} taken back from {} for an arriving pilot",
                p.name
            );
            let _ = p.tx.try_send(Message::Binary(vec![S2C_YIELD]));
        }
        self.leave(id, pilot::why::EVICTED);
        Some(ship)
    }

    /// Every bot out, which is how a drain finishes. Bots would otherwise hold
    /// a draining instance at four fifths full for ever, and `total_players`
    /// would never reach zero.
    pub(crate) fn evict_all_bots(&mut self) -> usize {
        let ids: Vec<u64> = self
            .players
            .iter()
            .filter(|(_, p)| p.bot)
            .map(|(id, _)| *id)
            .collect();
        if !ids.is_empty() {
            println!("sending {} bot(s) home", ids.len());
        }
        for id in &ids {
            if let Some(p) = self.players.get(id) {
                let _ = p.tx.try_send(Message::Binary(vec![S2C_YIELD]));
            }
            self.leave(*id, pilot::why::DRAINED);
        }
        ids.len()
    }

    /// A room with no named sides is a free-for-all, and a free-for-all is not
    /// one team: it is none. Every pilot arrives as a side of their own.
    ///
    /// This ran as `teams = 1` once, which put everybody on side zero, and
    /// every hostility test in this stack asks whether two sides differ. Chaos
    /// spent a day with no damage, no kills, and nine pilots with nothing to
    /// shoot at while War two doors down played fine.
    #[cfg(test)]
    pub(crate) fn free_for_all(&self) -> bool {
        self.public_teams == 0
    }

    /// The zone's own sides, and the caps that are the whole of the policy.
    /// Called once when a room is built from its catalog entry.
    pub(crate) fn set_teams(&mut self, def: &catalog::ZoneDef) {
        self.teams.clear();
        for (i, name) in def.teams.iter().take(254).enumerate() {
            self.teams.insert(
                i as u8,
                Team {
                    name: name.clone(),
                    public: true,
                },
            );
        }
        self.public_teams = self.teams.len() as u8;
        self.max_teams = def.max_teams();
        self.max_humans_per_team = def.max_humans_per_team();
        self.max_bots_per_team = def.max_bots_per_team();
        self.invites.clear();
    }

    /// Whether this room is a duel: a zone whose every side is one person.
    /// That is the whole of what the duel zone declares beyond its size, and
    /// it is what a match here means: the two seats, against each other.
    pub(crate) fn is_duel(&self) -> bool {
        self.max_humans_per_team == 1 && self.public_teams == 2
    }

    /// Who is on a side, counted apart because the caps are. `skip` leaves one
    /// ship out, which is what a pilot asking to move needs: they are about to
    /// stop being where they are.
    pub(crate) fn team_census(&self, team: u8, skip: Option<u8>) -> (u16, u16) {
        let (mut humans, mut bots) = (0u16, 0u16);
        for (ship, seat) in &self.names {
            if Some(*ship) == skip {
                continue;
            }
            let sh = &self.world.state.ships[*ship as usize];
            if sh.active == 0 || sh.team != team {
                continue;
            }
            if seat.bot {
                bots += 1
            } else {
                humans += 1
            }
        }
        (humans, bots)
    }

    /// Whether one more of this kind fits on this side.
    pub(crate) fn team_has_room(&self, team: u8, bot: bool, skip: Option<u8>) -> bool {
        let (humans, bots) = self.team_census(team, skip);
        if bot {
            bots < self.max_bots_per_team
        } else {
            humans < self.max_humans_per_team
        }
    }

    /// Whether this ship may enter this side: it has to exist, have room, and
    /// either be the zone's own or have invited them.
    pub(crate) fn may_join(&self, ship: u8, team: u8, bot: bool) -> bool {
        let Some(t) = self.teams.get(&team) else {
            return false;
        };
        if self.world.state.ships[ship as usize].team == team {
            return true;
        }
        if !t.public && !self.invites.get(&ship).is_some_and(|s| s.contains(&team)) {
            return false;
        }
        self.team_has_room(team, bot, Some(ship))
    }

    /// The lowest byte no side is using, or none when the room is at its cap.
    pub(crate) fn free_team_byte(&self) -> Option<u8> {
        if self.teams.len() as u16 >= self.max_teams as u16 {
            return None;
        }
        (0u8..255).find(|b| !self.teams.contains_key(b))
    }

    /// Where an arrival is put. The emptiest of the zone's own sides that has
    /// room, which is a default rather than a rule: the list is one selection
    /// away and only a full side can refuse it. A free-for-all has no such
    /// list, so an arrival founds their own side of one.
    pub(crate) fn seat_team(&mut self, joining: u8, seat: &Seat) -> u8 {
        let bot = seat.bot;
        let mut best: Option<(u8, (u16, u16))> = None;
        for t in 0..self.public_teams {
            if !self.team_has_room(t, bot, Some(joining)) {
                continue;
            }
            // Emptiest of your own kind, because that is the emptiness the
            // caps measure and the one an arrival cares about. Counting heads
            // of both kinds together put six bots on one side of a two-team
            // room: every side held no humans, so the first one always won.
            //
            // Heads of both kinds break a tie, so an arrival lands across
            // from whoever is already here rather than beside them. The duel
            // is where it showed: a person at the door of a room two bots
            // held took one bot's seat, found no humans on either side, and
            // was put on the first side, next to the bot they had come to
            // fight, until the ballast rule moved it across a few seconds
            // later with its kills.
            let (humans, bots) = self.team_census(t, Some(joining));
            let n = if bot { bots } else { humans };
            let key = (n, humans + bots);
            if best.is_none_or(|(_, best_key)| key < best_key) {
                best = Some((t, key));
            }
        }
        if let Some((t, _)) = best {
            return t;
        }
        // Every named side is full, or there are none. A side of your own is
        // the honest answer to both: in a free-for-all it is the whole design,
        // and in a full room it beats refusing a pilot who has a seat.
        self.found_team(joining).unwrap_or(0)
    }

    /// Where a watcher belongs. The same question `seat_team` answers for a
    /// pilot, asked by somebody holding no hull: a watcher occupies no seat, so
    /// the per-side caps have nothing to weigh here and the emptiest of the
    /// zone's own sides is the whole rule. Room is checked when they fly, which
    /// is the moment it starts to mean anything.
    ///
    /// A free-for-all has no such sides, and the answer there is none. Every
    /// pilot is a private side of one, so there is no side for an arrival to
    /// share and nothing but the room channel to see.
    pub(crate) fn watch_team(&self) -> Option<u8> {
        (0..self.public_teams).min_by_key(|t| self.team_census(*t, None).0)
    }

    /// A new private side, named and empty, or none when the room already
    /// holds as many as it may. The founder is not moved here; the caller
    /// does that, because moving is gated and founding is not.
    pub(crate) fn found_team(&mut self, founder: u8) -> Option<u8> {
        let byte = self.free_team_byte()?;
        let name = self.fresh_team_name();
        self.teams.insert(
            byte,
            Team {
                name,
                public: false,
            },
        );
        // The founder is invited to their own team, which is what makes the
        // move that follows legal without a special case for it.
        self.invites.entry(founder).or_default().insert(byte);
        Some(byte)
    }

    /// A name no side in this room is wearing. The words are the roster's
    /// register and none of its names, the same rule the call sign generator
    /// follows, so a team never reads as a pilot.
    ///
    /// The search starts where the last one stopped rather than at the top of
    /// the list. Starting at the top always returned the same word to a lone
    /// player: found a side, leave it, the reaper takes it, and the next found
    /// hands back the name that just came free. Two different sides in a row
    /// called Anvil Watch reads as a button that did nothing.
    ///
    /// The cursor still wraps, so a room only reuses a freed word after going
    /// all the way round. That matters in a free-for-all, where every arrival
    /// founds a side: a cursor that only ever climbed would have a room of
    /// twenty-five bots flying for Anvil Watch 30 by the afternoon.
    pub(crate) fn fresh_team_name(&mut self) -> String {
        const WORDS: [&str; 24] = [
            "Anvil Watch",
            "Black Sill",
            "Cold Harbour",
            "Deep Keel",
            "Ember Line",
            "Far Reach",
            "Gray Span",
            "High Trestle",
            "Iron Weir",
            "Long Lintel",
            "Mill Race",
            "North Gantry",
            "Old Causeway",
            "Pale Arch",
            "Quarry Gate",
            "Red Culvert",
            "Salt Pier",
            "Stone Chord",
            "Tall Derrick",
            "Under Span",
            "Verge Works",
            "West Buttress",
            "Yard Bell",
            "Zinc Landing",
        ];
        for step in 0..WORDS.len() {
            let i = (self.name_cursor + step) % WORDS.len();
            if !self.teams.values().any(|t| t.name == WORDS[i]) {
                self.name_cursor = i + 1;
                return WORDS[i].to_string();
            }
        }
        // Every word is out at once, which takes twenty-four live sides. The
        // laps are plain suffixes and the cursor stays out of them: a room this
        // full is a free-for-all, and there the number is the useful part.
        for lap in 1..64u32 {
            for w in WORDS {
                let name = format!("{w} {}", lap + 1);
                if !self.teams.values().any(|t| t.name == name) {
                    return name;
                }
            }
        }
        "Unnamed".into()
    }

    /// Cross to a side. The room decides whether the door is open; the core
    /// decides whether the pilot may leave where they are, which it refuses
    /// for anyone dead or hurt. Both have to agree, and a refusal is silent:
    /// the team list that follows still says where you are, which is the only
    /// thing the client asked about.
    pub(crate) fn join_team(&mut self, ship: u8, team: u8) -> bool {
        let bot = self.names.get(&ship).is_some_and(|s| s.bot);
        if !self.may_join(ship, team, bot) {
            self.send_teams(ship);
            return false;
        }
        let from = self.world.state.ships[ship as usize].team;
        let moved = self.world.set_ship_team(ship, team);
        if moved {
            // Only a crossing that happened. Both gates above are silent to
            // the pilot, and a log that recorded the asking would mostly
            // record hurt pilots pressing a key that did nothing.
            if let Some(seat) = self.names.get(&ship).cloned() {
                let public = self.teams.get(&team).is_some_and(|t| t.public);
                self.note(
                    pilot::TEAM,
                    &seat,
                    serde_json::json!({ "from": from, "to": team, "public": public }),
                );
            }
            // The side they left may have been its last member's.
            self.reap_teams();
            self.broadcast_teams();
            self.broadcast_roster();
        } else {
            self.send_teams(ship);
        }
        moved
    }

    /// Found a side and cross to it, which is one act to a player and two
    /// here. If the crossing is refused -- a hurt pilot, a dead one -- the
    /// side is given back rather than left standing empty for the reaper.
    pub(crate) fn found_and_move(&mut self, ship: u8) -> bool {
        let Some(byte) = self.found_team(ship) else {
            self.send_teams(ship);
            return false;
        };
        if self.join_team(ship, byte) {
            // Beside the `team` row the crossing already wrote, because
            // founding is the act a player took and crossing is how it was
            // carried out. A side appearing with one member on it is also the
            // shape of somebody hiding from a team game.
            if let Some(seat) = self.names.get(&ship).cloned() {
                let name = self
                    .teams
                    .get(&byte)
                    .map(|t| t.name.clone())
                    .unwrap_or_default();
                self.note(
                    pilot::FOUND,
                    &seat,
                    serde_json::json!({ "team": byte, "name": name }),
                );
            }
            return true;
        }
        self.teams.remove(&byte);
        if let Some(s) = self.invites.get_mut(&ship) {
            s.remove(&byte);
        }
        self.send_teams(ship);
        false
    }

    /// Extend an invitation to the inviter's own side. Only private sides have
    /// a door to open: everyone may already walk into a public one, so an
    /// invitation to it would be a message that changes nothing.
    pub(crate) fn invite(&mut self, from: u8, to: u8) -> bool {
        let team = self.world.state.ships[from as usize].team;
        let private = self.teams.get(&team).is_some_and(|t| !t.public);
        if !private || from == to || !self.names.contains_key(&to) {
            return false;
        }
        self.invites.entry(to).or_default().insert(team);
        // Any member may invite and there is no kick to go with it, so an
        // invitation is the one thing a pilot can aim at another pilot without
        // shooting. Recorded for that reason rather than for the side change,
        // which the invitee's own `team` row covers if they accept.
        if let Some(seat) = self.names.get(&from).cloned() {
            self.note(
                pilot::INVITE,
                &seat,
                serde_json::json!({ "to": to, "team": team }),
            );
        }
        // The invitee's list is the one that changed, but the inviter wants to
        // see that it went, so everybody gets the new one.
        self.broadcast_teams();
        true
    }

    /// Move one bot toward the side that needs one.
    ///
    /// Seating already puts an arriving bot on the emptiest side, which is
    /// enough until people start moving. Then it is not: five friends crossing
    /// to one side of a flag game leaves the other holding whatever it held
    /// when they arrived, and the room they made for themselves is a stomp
    /// rather than the co-op raid it should be. So the ballast follows.
    ///
    /// One bot per call, on the roster's own slow clock, because a side that
    /// emptied all at once should refill over a few seconds rather than blink.
    /// The move goes through the same gate everything else does, so a bot in a
    /// fight stays in it and the next call finds another.
    pub(crate) fn rebalance_bots(&mut self) {
        if self.public_teams < 2 {
            return;
        }
        let mut count = Vec::new();
        for team in 0..self.public_teams {
            let (humans, bots) = self.team_census(team, None);
            count.push((team, humans + bots, bots));
        }
        let Some(&(fullest, most, bots_there)) = count.iter().max_by_key(|(_, n, _)| *n) else {
            return;
        };
        let Some(&(emptiest, fewest, _)) = count.iter().min_by_key(|(_, n, _)| *n) else {
            return;
        };
        // Two is the smallest gap worth moving for: one is what an odd number
        // of pilots looks like, and chasing it would move a bot every clock.
        if fullest == emptiest || most < fewest + 2 || bots_there == 0 {
            return;
        }
        let movers: Vec<u8> = self
            .names
            .iter()
            .filter(|(ship, seat)| {
                seat.bot && self.world.state.ships[**ship as usize].team == fullest
            })
            .map(|(ship, _)| *ship)
            .collect();
        for ship in movers {
            if self.join_team(ship, emptiest) {
                return;
            }
        }
    }

    /// The zone's own sides, in the order it scores them. Private sides are
    /// left out: a mode never scores over one, so it never has to name one.
    pub(crate) fn public_team_names(&self) -> Vec<String> {
        (0..self.public_teams)
            .map(|b| {
                self.teams
                    .get(&b)
                    .map(|t| t.name.clone())
                    .unwrap_or_default()
            })
            .collect()
    }

    /// One client's team list, for the answers only they can see.
    pub(crate) fn send_teams(&self, ship: u8) {
        if let Some(p) = self.players.values().find(|p| p.ship == ship) {
            let _ = p.tx.try_send(Message::Binary(self.teams_msg(ship)));
        }
    }

    /// A private side nobody is left on stops existing, and its byte goes back
    /// in the pool. Called wherever a ship stops being on one: leaving, and
    /// crossing to somewhere else.
    pub(crate) fn reap_teams(&mut self) {
        let live: std::collections::HashSet<u8> = self
            .names
            .keys()
            .filter(|s| self.world.state.ships[**s as usize].active != 0)
            .map(|s| self.world.state.ships[*s as usize].team)
            .collect();
        let public = self.public_teams;
        let gone: Vec<u8> = self
            .teams
            .iter()
            .filter(|(b, t)| !t.public && **b >= public && !live.contains(b))
            .map(|(b, _)| *b)
            .collect();
        for b in gone {
            self.teams.remove(&b);
            for s in self.invites.values_mut() {
                s.remove(&b);
            }
        }
        self.invites.retain(|_, s| !s.is_empty());
    }

    /// One line of the pilot log, stamped with this room's number and tick.
    pub(crate) fn note(&self, kind: &str, seat: &Seat, detail: serde_json::Value) {
        file_event(
            &self.pilots,
            &seat.session,
            kind,
            Some(seat),
            Some(self.number),
            self.world.state.tick,
            detail,
        );
    }

    /// One death, into the pilot log, from whichever path resolved it.
    ///
    /// A row for whoever died and a row for whoever did it. `rated_events`
    /// remains the authority on what the death did to the ladder; these rows
    /// are what put it in the story of a session, where a join followed by an
    /// hour of silence used to stand in for the whole evening. Assists are
    /// deliberately left to the rated log: one death is at most two rows here,
    /// not one per contributor.
    ///
    /// Bots file too. They used to be skipped, which was cheap and left a
    /// roster individual with no log at all. It is an account with a career,
    /// so it files the way a person does. The week's table reads
    /// `where not bot`, so what this adds is a log, not a machine in the
    /// standings. See docs/design/ai-players.md.
    pub(crate) fn note_death(&self, victim: u8, killer: u8, run: u16) {
        // The run the victim was on, handed in rather than worked back out of
        // anything: a death clears it and the live state no longer has it.
        // Filed on the death rather than on the kill because the run belongs
        // to whoever was on it, and a pilot's best week is the longest one of
        // theirs that anybody managed to end.
        let run = run as i32;
        if let Some(seat) = self.names.get(&victim) {
            let seat = seat.clone();
            self.note(
                pilot::DIED,
                &seat,
                serde_json::json!({
                    "by": self.name_of(killer),
                    "run": run,
                }),
            );
        }
        // Whose mistake it was, if it was one. Two shapes of the same thing:
        // your own bomb at your own feet, and your own bomb at your wingman's.
        // Both file a misfire against whoever threw it rather than a kill,
        // the way the arena has already taken a kill off the board for it.
        //
        // A wall death has no thrower at all: seat 255 is nobody and
        // `self.names` has no row for it, so nothing is filed. Flying into a
        // rock is a death and not a mistake anybody aimed.
        let own = victim == killer;
        let friendly = !own
            && (killer as usize) < self.world.state.ships.len()
            && (victim as usize) < self.world.state.ships.len()
            && self.world.state.ships[killer as usize].team
                == self.world.state.ships[victim as usize].team;
        if own || friendly {
            let at = if own { victim } else { killer };
            if let Some(seat) = self.names.get(&at) {
                let seat = seat.clone();
                self.note(
                    pilot::MISFIRE,
                    &seat,
                    serde_json::json!({ "of": self.name_of(victim), "own": own }),
                );
            }
            return;
        }
        if let Some(seat) = self.names.get(&killer) {
            let seat = seat.clone();
            self.note(
                pilot::KILL,
                &seat,
                serde_json::json!({ "of": self.name_of(victim) }),
            );
        }
    }

    /// A pilot goes, and their seat is retired rather than handed on.
    ///
    /// Handing it to a fresh bot is what this used to do, and it was the
    /// in-process director's last reflex: the room refilled itself. It cannot
    /// now, and should not, because filling is the bot server's job and it is
    /// watching. The slot is reusable either way, since the core gives an
    /// inactive one to the next arrival rather than only ever appending.
    ///
    /// `why` is one of [`pilot::why`]. Five callers reach this and they used to
    /// be indistinguishable afterwards, which made the commonest question about
    /// any departure, whether the pilot quit or the room took the seat,
    /// unanswerable from anything the fleet kept.
    pub(crate) fn leave(&mut self, id: u64, why: &str) -> bool {
        let Some(presence) = self.players.get(&id).map(|p| p.presence.clone()) else {
            return false;
        };
        if presence.current()
            != (Presence::Flying {
                room: self.number,
                member: id,
            })
        {
            return false;
        }
        self.remove_player(id, why);
        presence
            .transition(PresenceEvent::Disconnect {
                room: self.number,
                member: id,
            })
            .expect("validated player departure");
        self.debug_assert_member(id, &presence);
        true
    }

    /// Retire the simulation seat without changing connection presence.
    /// `sit_out_for` uses this while moving the same member into the watcher
    /// table. Every departure from the room goes through `leave` instead.
    pub(crate) fn remove_player(&mut self, id: u64, why: &str) {
        if let Some(p) = self.players.remove(&id) {
            // A quit under fire is a death. The rating settles on death, and
            // a leave used to drop the damage ledger unsettled, which made
            // closing the tab strictly better than losing the fight it was
            // closed on. Two conditions, each held where its facts live: the
            // ledger must be hot, which rating::quit judges from its own
            // last-damage tick, and the pilot must have been losing, judged
            // here from the tank because energy is both health and the means
            // to fly away, and a full pilot taking a stray hit quits nothing
            // they could not have flown out of.
            //
            // A disconnect and a menu leave land here alike, on purpose:
            // intent is unknowable at the socket, and a pilot dead to rights
            // when their wifi died was dead to rights. The sim is not told.
            // This is bookkeeping about a fight that already happened, not a
            // death in the world, so no mode hook fires and no bounty pays.
            let tick = self.world.state.tick;
            // A restart is the process leaving, not the pilot: settling it
            // as a quit would charge everyone who happened to be mid-fight
            // when a deploy landed with a death they did not choose.
            let losing = why != pilot::why::RESTART && {
                let sh = &self.world.state.ships[p.ship as usize];
                let ceiling = self.world.eff_max_energy(p.ship as usize).max(1);
                sh.alive != 0 && (sh.energy as f64) < QUIT_ENERGY * ceiling as f64
            };
            let rated = if losing {
                self.rating.quit(tick, &p.rid)
            } else {
                self.rating.forget(&p.rid);
                None
            };
            if let Some(r) = rated.as_ref() {
                self.hand_off(r, None);
                // The feed line, on the same wire as any kill, because the
                // death is real and should read like one. Credited to the
                // largest contributor still seated; if they have all left
                // too, the ladder moved but there is nobody to point at,
                // and no line is written.
                let top = r
                    .credits
                    .iter()
                    .max_by(|a, b| a.1.total_cmp(&b.1))
                    .map(|(who, ..)| who.clone());
                let seat = top.as_ref().and_then(|who| {
                    self.names
                        .iter()
                        .find(|(_, k)| &k.rid == who)
                        .map(|(s, _)| *s)
                });
                if let (Some(ks), Some(krid)) = (seat, top) {
                    // The killer's half of a quit. The victim's own row is
                    // the LEAVE below, marked as a quit; a `died` here too
                    // would say the same thing twice about one departure.
                    if let Some(kseat) = self.names.get(&ks).cloned() {
                        self.note(
                            pilot::KILL,
                            &kseat,
                            serde_json::json!({ "of": p.name, "quit": true }),
                        );
                    }
                    let vr = self.rating.rating_of(&p.rid).round() as i16;
                    let kr = self.rating.rating_of(&krid).round() as i16;
                    let mut m = vec![S2C_KILL, p.ship, ks];
                    m.extend_from_slice(&vr.to_le_bytes());
                    m.extend_from_slice(&kr.to_le_bytes());
                    m.push(r.credits.len() as u8);
                    // A quit pays no bounty: points are the sim's to award
                    // and the sim saw no death.
                    m.extend_from_slice(&0u16.to_le_bytes());
                    m.extend_from_slice(&tick.to_le_bytes());
                    // Nobody is told they helped, for the same reason. The
                    // sim never ran a death here, so no assist column moved,
                    // and a notice about one the scoreboard does not show is
                    // the disagreement this byte exists to avoid.
                    m.push(0);
                    for pl in self.players.values() {
                        let _ = pl.tx.try_send(Message::Binary(m.clone()));
                    }
                    self.channel.pending_feed.push(m);
                }
            }
            // Filed before the seat is torn down, since the seat is what says
            // who this was. `held` is the whole of what the log knows about
            // how long somebody stayed, so a session that ends without one of
            // these ended with the process rather than with the pilot.
            if let Some(seat) = self.names.get(&p.ship).cloned() {
                self.note(
                    pilot::LEAVE,
                    &seat,
                    serde_json::json!({
                        "why": why,
                        "ship": p.ship,
                        "held": serial_elapsed(self.world.state.tick, p.joined),
                        "quit_loss": rated.is_some(),
                    }),
                );
            }
            let sh = &mut self.world.state.ships[p.ship as usize];
            sh.active = 0;
            sh.alive = 0;
            self.names.remove(&p.ship);
            // Invitations belong to the pilot, not the seat: the next occupant
            // of this one was invited nowhere. And a private side whose last
            // member just left stops existing.
            self.invites.remove(&p.ship);
            // The tally belongs to the pilot, not to the seat. Left set, the
            // next occupant would inherit a lit state nobody ever sent them
            // and never see it go out.
            self.on_air.remove(&p.ship);
            self.reap_teams();
            // Here rather than at each of the several callers -- a quit, an
            // eviction, a kick, a drain -- because every one of them changes
            // who is on what.
            self.broadcast_teams();
        }
    }

    /// A flying pilot becomes a watcher on the same socket. A despawn and a
    /// seat change, not a reconnect: map, settings and socket all stay. The
    /// side they sat out from is remembered, because it colors their screen
    /// and it is the seat they prefer when they fly again.
    ///
    /// `swept` says the safe-zone timer moved them rather than the pilot
    /// asking. The two are the same operation and read very differently in a
    /// log: one is a player taking a break and the other is the room deciding
    /// they were loitering.
    pub(crate) fn sit_out(&mut self, id: u64, swept: bool) -> bool {
        let why = if swept {
            SitOutWhy::Safe
        } else {
            SitOutWhy::Asked
        };
        self.sit_out_for(id, why)
    }

    pub(crate) fn sit_out_for(&mut self, id: u64, why: SitOutWhy) -> bool {
        if self.watchers.len() >= self.max_watchers {
            return false;
        }
        let Some(p) = self.players.get(&id) else {
            return false;
        };
        let ship = p.ship;
        if why == SitOutWhy::Asked && !self.world.may_reset_ship(ship as usize) {
            return false;
        }
        let tx = p.tx.clone();
        let presence = p.presence.clone();
        let lifecycle = next_nonzero(p.lifecycle);
        let Some(seat) = self.names.get(&ship).cloned() else {
            return false;
        };
        let team = self.world.state.ships[ship as usize].team;
        if presence.current()
            != (Presence::Flying {
                room: self.number,
                member: id,
            })
        {
            return false;
        }
        self.note(
            pilot::SIT_OUT,
            &seat,
            serde_json::json!({
                "why": match why {
                    SitOutWhy::Asked => "asked",
                    SitOutWhy::Safe => "safe",
                    SitOutWhy::Lag => "lag",
                },
                "ship": ship,
            }),
        );
        self.remove_player(id, pilot::why::SAT_OUT);
        // This wakeup can release the account's rated lease. Send it only
        // after a combat quit has reached the spool, so the release task's
        // settlement snapshot contains the final exchange.
        presence
            .transition(PresenceEvent::SitOut {
                room: self.number,
                member: id,
                reason: why,
            })
            .expect("validated move to the stands");
        self.watchers.insert(
            id,
            Watcher {
                lifecycle,
                seat,
                team: Some(team),
                tx: tx.clone(),
                presence,
            },
        );
        self.debug_assert_member(id, &self.watchers[&id].presence);
        // The client learns which of its two lives this is from the welcome:
        // 255 is a watcher's ship.
        let mut w = vec![S2C_WELCOME, 255];
        w.extend_from_slice(&lifecycle.to_le_bytes());
        w.extend_from_slice(&self.world.state.tick.to_le_bytes());
        // A watcher is in a room like anybody else, and the welcome is one
        // shape whoever it greets: a client that had to know which kind it was
        // holding before it could read the length would be parsing the message
        // twice.
        w.extend_from_slice(&(self.number as u16).to_le_bytes());
        w.extend_from_slice(&self.settings_generation.to_le_bytes());
        // Why they are in the stands. A pilot who pressed the key already
        // knows; one the room moved cannot tell from the swap alone, because
        // the stands run five seconds behind and the first thing they are
        // shown is their own hull, still flying. Without a word on the screen
        // that reads as the game coming apart rather than as a bench.
        w.push(match why {
            SitOutWhy::Asked => WHY_NONE,
            SitOutWhy::Safe => WHY_SAFE,
            SitOutWhy::Lag => WHY_LAG,
        });
        let _ = tx.try_send(Message::Binary(w));
        // They were flying a second ago and their screen still holds the live
        // clock. The stands run five seconds behind, so hand them what the
        // channel is showing rather than leaving the readout ahead of the
        // first frame they are about to be served.
        for m in self.channel_sync() {
            let _ = tx.try_send(Message::Binary(m));
        }
        self.broadcast_roster();
        // After the watcher row exists, not before: `leave` above broadcast a
        // list this pilot was no longer on, and the side they sat out from is
        // what colors the room for them from here.
        self.broadcast_teams();
        true
    }

    /// A client that arrived to watch. They are seated on a side at the door,
    /// the same as anybody else who walks in: watching is a way of being in
    /// this room rather than a lobby beside it. So the team list has a side to
    /// call theirs, and the room is colored from it.
    ///
    /// Arriving to watch used to hand out no side at all, on the reasoning that
    /// somebody who never flew here sat out from nowhere. What that produced
    /// was a spectator alone off the edge of a room's two teams, with every
    /// hull on screen drawn as an enemy's, while the same person joining in a
    /// hull and then sitting out kept their side and everything that came with
    /// it.
    #[cfg(test)]
    pub(crate) fn watch_join(&mut self, seat: Seat, tx: mpsc::Sender<Message>) -> Option<u64> {
        self.watch_join_with_presence(seat, tx, PresenceHandle::new())
    }

    pub(crate) fn watch_join_with_presence(
        &mut self,
        seat: Seat,
        tx: mpsc::Sender<Message>,
        presence: PresenceHandle,
    ) -> Option<u64> {
        if self.watchers.len() >= self.max_watchers {
            return None;
        }
        if presence.current() != Presence::Unjoined {
            return None;
        }
        let id = self.next_id;
        self.next_id += 1;
        let team = self.watch_team();
        presence
            .transition(PresenceEvent::JoinWatching {
                room: self.number,
                member: id,
            })
            .expect("validated watcher entry");
        self.note(pilot::WATCH, &seat, serde_json::json!({ "team": team }));
        self.watchers.insert(
            id,
            Watcher {
                lifecycle: 1,
                seat,
                team,
                tx,
                presence,
            },
        );
        self.debug_assert_member(id, &self.watchers[&id].presence);
        // Their side is what colors the room for them, so the list saying
        // which one it is goes out before the first frame does.
        self.broadcast_teams();
        Some(id)
    }

    /// A watcher takes a hull again. Everything is `join`: the caps, the bot
    /// eviction, the spawn kit, the team seating. The watcher row goes only
    /// once the seat is real, so a room that filled while they sat out
    /// refuses and leaves them watching.
    ///
    /// The side they were watching with goes in as a preference rather than
    /// being re-picked from scratch, because it was theirs the whole time they
    /// sat there: the team list said so and the follow rule enforced it. Losing
    /// it on the way back into a cockpit would move a pilot across the room for
    /// having watched a minute of it.
    pub(crate) fn fly(&mut self, id: u64, class: u8, max_players: usize) -> Option<u64> {
        let seat = self.watchers.get(&id)?.seat.clone();
        let tx = self.watchers.get(&id)?.tx.clone();
        let back = self.watchers.get(&id)?.team;
        let presence = self.watchers.get(&id)?.presence.clone();
        let logged = seat.clone();
        let new_id = self.join_on(
            seat,
            class,
            max_players,
            back,
            tx.clone(),
            Some(id),
            presence,
        )?;
        self.debug_assert_member(id, &self.players[&new_id].presence);
        let ship = self.players[&new_id].ship;
        let lifecycle = self.players[&new_id].lifecycle;
        // Not a `join`: the same connection, the same session, and a stay the
        // log should read as continuous. A room that filled while they sat
        // there refuses above and writes nothing, which is the case worth
        // being able to tell apart.
        self.note(
            pilot::FLY,
            &logged,
            serde_json::json!({
                "class": self.world.state.ships[ship as usize].cls,
                "ship": ship,
                "team": self.world.state.ships[ship as usize].team,
            }),
        );
        let mut m = vec![S2C_WELCOME, ship];
        m.extend_from_slice(&lifecycle.to_le_bytes());
        m.extend_from_slice(&self.world.state.tick.to_le_bytes());
        // The room, like every other welcome carries it. This one did not, and
        // it is the only welcome a pilot receives without having just picked a
        // room, so the corner chip lost the number for the rest of the session:
        // the client reads it off the end of the message and got nothing.
        m.extend_from_slice(&(self.number as u16).to_le_bytes());
        m.extend_from_slice(&self.settings_generation.to_le_bytes());
        m.push(WHY_NONE);
        let _ = tx.try_send(Message::Binary(m));
        self.broadcast_roster();
        self.broadcast_teams();
        Some(new_id)
    }

    pub(crate) fn leave_watcher(&mut self, id: u64) -> bool {
        let Some(watcher) = self.watchers.get(&id) else {
            return false;
        };
        let presence = watcher.presence.clone();
        if presence
            .transition(PresenceEvent::Disconnect {
                room: self.number,
                member: id,
            })
            .is_err()
        {
            return false;
        }
        self.watchers.remove(&id);
        self.debug_assert_member(id, &presence);
        true
    }

    /// Every watcher out, told the way a yielded bot is told. A drain empties
    /// the room of players, and a watcher with nobody to watch is a socket
    /// holding a picture of an empty map open.
    pub(crate) fn drop_watchers(&mut self) -> usize {
        let n = self.watchers.len();
        let mut departed = Vec::with_capacity(n);
        for (id, w) in self.watchers.iter() {
            let _ = w.tx.try_send(Message::Binary(vec![S2C_YIELD]));
            w.presence
                .transition(PresenceEvent::Disconnect {
                    room: self.number,
                    member: *id,
                })
                .expect("watcher belongs to this room");
            departed.push((*id, w.presence.clone()));
        }
        self.watchers.clear();
        for (id, presence) in departed {
            self.debug_assert_member(id, &presence);
        }
        if n > 0 {
            self.broadcast_roster();
        }
        n
    }

    pub(crate) fn tick(&mut self) -> bool {
        // Before anything is stepped: a pilot owed the ground is a pilot whose
        // client is refusing every frame this room sends.
        self.retry_owed_maps();
        let mut player_count_changed = false;
        let mut inputs: Vec<sim::sim_input> = Vec::with_capacity(32);
        // The tick this room is about to run, which is the tick a scheduled
        // input has to name to be applied here. `world.tick()` is the last one
        // completed, so the step below produces the one after it.
        let now = self.world.state.tick.wrapping_add(1);
        // One loop, because there is one kind of pilot. Bots used to be thought
        // for here, between the queue and the step, reading the world directly;
        // their inputs now arrive on sockets like everybody else's and this
        // function cannot tell which is which.
        let mut no_flags = [false; sim::MAX_SHIPS];
        let mut spectate = Vec::new();
        let live = self.mode.match_state().is_none_or(|m| m.playing);
        for (id, p) in self.players.iter_mut() {
            if !p.lag.input_synchronized && p.input_window_ready(now) {
                p.lag.synchronize_input();
            }
            if !p.bot && p.lag.input_synchronized {
                let missing = !p.received_input(now);
                p.lag
                    .observe_input(missing, self.lag_policy.input_sample_ticks);
            }
            let input_silence = p.input_silence(now);
            let update = p.lag.tick(&self.lag_policy, p.bot, now, input_silence);
            if update.notify {
                let _ = p.tx.try_send(Message::Binary(p.lag.notice()));
            }
            // A new stream cannot take an objective before its clock is
            // coherent, even though the brief startup gate stays out of the
            // connection-quality banner.
            no_flags[p.ship as usize] = !p.lag.input_synchronized || update.decision.no_flags;
            if update.decision.spectate {
                spectate.push(*id);
            }
            // Held between matches. That is the whole of what makes an
            // intermission an intermission rather than a free-for-all under a
            // frozen scoreboard: the podium is up, and nobody is flying.
            let buttons = if live { p.buttons_at(now) } else { 0 };
            inputs.push(sim::sim_input {
                ship: p.ship,
                buttons,
            });
        }
        if live {
            self.replay.record(&self.world, &inputs);
        }
        let flags_before = self.world.state.flags;
        self.world.step(&inputs);
        if no_flags.iter().any(|v| *v) {
            let mut write = 0usize;
            let count = self.world.events.count as usize;
            for read in 0..count {
                let event = self.world.events.e[read];
                let denied = event.etype == sim::EV_FLAG_TAKE
                    && no_flags.get(event.a as usize).copied().unwrap_or(false);
                if denied {
                    metrics::LAG_ACTIONS.inc();
                    if let Some(flag) = self.world.state.flags.get_mut(event.b as usize) {
                        *flag = flags_before[event.b as usize];
                    }
                } else {
                    self.world.events.e[write] = event;
                    write += 1;
                }
            }
            self.world.events.count = write as u16;
        }
        self.score_events();
        player_count_changed |= self.sweep_safe();

        let names = self.public_team_names();
        let mut ctx = modes::ModeCtx {
            world: &mut self.world,
            team_names: &names,
            banner: std::mem::take(&mut self.banner),
            finished: false,
            open_match: false,
            close_match: false,
        };
        self.mode.tick(&mut ctx);
        self.banner = std::mem::take(&mut ctx.banner);
        let (finished, closed, opened) = (ctx.finished, ctx.close_match, ctx.open_match);
        // The context holds the world, so it has to go before the room can act
        // on what the mode asked for.
        drop(ctx);
        if finished {
            self.finished = true;
        }
        if closed {
            self.close_match();
        }
        if opened {
            self.open_match();
        }
        // The room's own half is the change signal. A pilot's card only ever
        // moves when a fight is filed, and filing one flips `playing`, which
        // is in here.
        let now_match = self.match_msg();
        if now_match != self.last_match {
            self.broadcast_match();
            self.last_match = now_match;
        }
        for id in spectate {
            if self.sit_out_for(id, SitOutWhy::Lag) {
                player_count_changed = true;
                metrics::LAG_ACTIONS.inc();
            } else if let Some(tx) = self.players.get(&id).map(|p| p.tx.clone()) {
                let mut denied = vec![S2C_DENIED, 0];
                denied.extend_from_slice(b"connection quality exceeded this room's limits");
                let _ = tx.try_send(Message::Binary(denied));
                let _ = tx.try_send(Message::Binary(vec![S2C_YIELD]));
                player_count_changed |= self.leave(id, pilot::why::KICKED);
                metrics::LAG_ACTIONS.inc();
            }
        }
        player_count_changed
    }

    /// The whistle at the end of a match: clear the arena, and move to the
    /// ground the next one is played on.
    ///
    /// Both halves of that are about the wait rather than about the match that
    /// just ended. A podium over the arena you were fighting in, with the
    /// wrecks and the last bomb still hanging there and the map you have just
    /// finished with underneath, is fifteen seconds of looking at something
    /// over. So the map changes here rather than at the next whistle, and the
    /// arena empties: nothing in the air, and nobody on the ground.
    ///
    /// Nothing a pilot earned is touched. The tallies the podium is reading
    /// live on the ships, and `restart` zeroes them, which is why this is not
    /// that: it benches everybody instead. A ship with no respawn scheduled
    /// stays down until something puts it back, and `open_match` is what does.
    pub(crate) fn close_match(&mut self) {
        self.note_match_results();
        self.file_match();
        if self.maps.len() > 1 {
            self.map_at = (self.map_at + 1) % self.maps.len();
            // Which ground, since a zone's rotation is something an operator
            // can change from the panel now and "did that land" is otherwise
            // a question with nowhere to look. The next match rather than this
            // one: the whistle changes the ground and the podium waits on it.
            println!(
                "room {}: next match is on map {} of {} ({} by {})",
                self.number,
                self.map_at + 1,
                self.maps.len(),
                self.maps[self.map_at].w,
                self.maps[self.map_at].h
            );
            // The room's size is a zone key that lives on the settings, so it
            // is read back off the running room rather than out of the tuning:
            // a `max_ships` from the zone stanza never passed through the
            // `[arena]` block this puts back on.
            let seats = self.world.cfg.max_ships;
            self.world.set_map(self.maps[self.map_at].clone());
            let tuning = self.tuning.clone();
            for w in Room::apply_config(&mut self.world, &tuning) {
                println!("room {}: {w}", self.number);
            }
            self.world.cfg.max_ships = seats;
            // New ground, new stands. A flag game that rotated maps kept the
            // last one's objective: on a turf map the stands are the whole of
            // where the fight happens, so flags left at the old map's
            // coordinates are a match played over nothing.
            let want = self.tuning.flags;
            self.place_flags();
            if let Some(want) = want {
                self.world.state.flag_count = want.min(self.world.state.flag_count);
            }
            self.settings_generation = crate::delivery::next_nonzero(self.settings_generation);
            self.broadcast_map();
            self.broadcast_settings();
        }
        // Nothing left in the air. A bomb thrown in the last second would
        // otherwise still be travelling over ground nobody is standing on.
        self.world.state.weapon_count = 0;
        // And nobody on it. Benched rather than killed: writing the fields is
        // not the death path, so no event is filed, nothing is paid, and the
        // numbers the podium is drawing stay where the match left them.
        //
        // The energy goes with the life, because the wire says it must: a
        // snapshot carrying a ship that is down with charge still in it is
        // refused by `sim_unpack`, and refused by every client at once. That
        // is a good rule and this is the code that has to keep it. Leaving it
        // out emptied a room the first time a match ended, with every player
        // told the zone had sent a snapshot they could not read.
        for sh in self.world.state.ships.iter_mut() {
            if sh.active != 0 {
                sh.alive = 0;
                sh.energy = 0;
                sh.respawn_at = 0;
            }
        }
    }

    /// Open a fresh match: everybody home, kits re-dealt.
    ///
    /// The room does this rather than the mode because both halves of it
    /// belong to the room: the sockets are the room's, and so is the roster
    /// everybody is reading, which has just had every tally in it zeroed. The
    /// ground was changed at the last whistle, so the wait happened on it.
    pub(crate) fn open_match(&mut self) {
        self.match_no += 1;
        self.match_opened_at = self.world.state.tick;
        self.artifact_id = None;
        self.replay.reset();
        println!(
            "room {}: match {} opens, {} pilot(s)",
            self.number,
            self.match_no,
            self.players.len()
        );
        // Settle the sides before the restart chooses one side's starts. A
        // pilot moved afterward kept the old pocket for the opening life.
        self.rebalance();
        // And the objective back on its stands, neutral, the way `restart`
        // puts the pilots back on theirs. A flag game whose last match ended
        // with the set gathered in one corner would otherwise open the next
        // one there, which is the same match continuing under a new clock.
        let want = self.tuning.flags;
        self.place_flags();
        if let Some(want) = want {
            self.world.state.flag_count = want.min(self.world.state.flag_count);
        }
        self.world.restart();
        face_public_teams(&mut self.world);
        // A whistle is where a hull is unlocked, so anything asked for during
        // the last match lands here. After `restart`, which deals what each
        // seat is already wearing: this deals the new one over the top, with
        // its ammunition, which is what a match start means.
        let seats: Vec<u8> = self.names.keys().copied().collect();
        for ship in seats {
            self.deal_seat(ship);
            // A pending build lands after `restart`, and Energy may move its
            // ceiling. Match setup is the safe place to fill the new bar;
            // doing this in `set_kit` would turn a mid-life respec into a
            // refill exploit.
            let full = self.world.eff_max_energy(ship as usize);
            self.world.state.ships[ship as usize].energy = full;
        }
        self.broadcast_roster();
        self.broadcast_match();
    }

    fn file_match(&mut self) {
        let Some(state) = self.mode.match_state() else {
            return;
        };
        if !self.names.values().any(|seat| !seat.bot) {
            return;
        }
        let mut seats = self.names.iter().collect::<Vec<_>>();
        seats.sort_by_key(|(ship, _)| **ship);
        let pilots = seats
            .into_iter()
            .map(|(ship, seat)| {
                let row = self.world.state.ships[*ship as usize];
                growth::Pilot {
                    ship: *ship,
                    account: seat.account,
                    name: seat.name.clone(),
                    bot: seat.bot,
                    team: row.team,
                    class: row.cls,
                    kills: row.kills,
                    deaths: row.deaths,
                    assists: row.assists,
                }
            })
            .collect();
        let id = growth::artifact_id();
        let artifact = growth::Artifact {
            id,
            room: self.number,
            match_no: self.match_no,
            map: self.map_names.get(self.map_at).cloned().unwrap_or_default(),
            teams: self.public_team_names(),
            score: state.score,
            pilots,
            replay: self.replay.finish(&self.world),
        };
        self.artifact_id = Some(id);
        if let Ok(mut matches) = self.matches.lock() {
            matches.push(artifact);
        }
    }

    /// File one settlement event per occupied seat at the whistle: whether
    /// they stayed to the end, whether their side took it, and what they
    /// helped with. Thirty seconds of field time is what counts as having
    /// been in the match, so the closing seconds are not worth arriving for.
    fn note_match_results(&self) {
        const MIN_PLAY_TICKS: u32 = 30 * 100;
        let Some(state) = self.mode.match_state().filter(|state| !state.playing) else {
            return;
        };
        let top_score = state.score.iter().copied().max();
        let winner = top_score.and_then(|score| {
            let mut teams = state
                .score
                .iter()
                .enumerate()
                .filter(|(_, value)| **value == score)
                .map(|(team, _)| team as u8);
            let first = teams.next()?;
            teams.next().is_none().then_some(first)
        });
        let now = self.world.state.tick;
        let match_age = now.wrapping_sub(self.match_opened_at);
        for player in self.players.values() {
            let Some(seat) = self.names.get(&player.ship) else {
                continue;
            };
            let played = match_age.min(now.wrapping_sub(player.joined));
            let completed = played >= MIN_PLAY_TICKS;
            let ship = &self.world.state.ships[player.ship as usize];
            let detail = serde_json::json!({
                "match": self.match_no,
                "completed": completed,
                "won": completed && winner == Some(ship.team),
                "assists": if completed { ship.assists.min(5) } else { 0 },
                "played_ticks": played,
            });
            self.note(pilot::MATCH, seat, detail);
        }
    }

    /// Even the sides up, by humans, at a whistle.
    ///
    /// A room fills between matches: people arrive one at a time and each
    /// takes the thinner side, which is right at the moment and drifts. Four
    /// humans against four bots is the arrangement the seating rule exists to
    /// avoid and the one a run of departures produces anyway, so the
    /// intermission is where it is put right. That is the job the twenty-five
    /// seconds have beyond the podium.
    ///
    /// Whoever arrived most recently moves, because they are the one who
    /// unbalanced it. A bot is never moved: bots fill what humans leave, and
    /// moving one only makes the room look even while the fight is not.
    pub(crate) fn rebalance(&mut self) {
        if self.public_teams < 2 {
            return;
        }
        // A bounded loop rather than a while: every pass moves one pilot and
        // the gap shrinks by two, so a room of 255 settles long before this,
        // and a rule that could not terminate has no business on a tick.
        for _ in 0..self.world.state.ship_count as usize {
            let mut census: Vec<(u8, usize)> = (0..self.public_teams)
                .map(|t| {
                    (
                        t,
                        self.players
                            .values()
                            .filter(|p| !p.bot && self.world.state.ships[p.ship as usize].team == t)
                            .count(),
                    )
                })
                .collect();
            census.sort_by_key(|(_, n)| *n);
            let (thin, few) = census[0];
            let (thick, many) = census[census.len() - 1];
            if many <= few + 1 {
                return;
            }
            // The newest arrival on the fullest side. `joined` is the tick
            // they took the seat, and the ship id breaks the common tie where
            // several joins land before the next simulation tick.
            let Some(ship) = self
                .players
                .values()
                .filter(|p| !p.bot && self.world.state.ships[p.ship as usize].team == thick)
                .max_by_key(|p| (p.joined, p.ship))
                .map(|p| p.ship)
            else {
                return;
            };
            if !self.team_has_room(thin, false, Some(ship)) {
                return;
            }
            // Straight to the side rather than through `join_team`, which
            // gates on a full bar: a pilot who happens to be short of energy
            // at the whistle is not a reason to leave the sides uneven, and
            // `sim_restart` is about to refill everybody anyway.
            self.world.state.ships[ship as usize].team = thin;
            if let Some(seat) = self.names.get(&ship).cloned() {
                self.note(
                    pilot::TEAM,
                    &seat,
                    serde_json::json!({ "from": thick, "to": thin, "why": "rebalance" }),
                );
            }
        }
    }

    /// What the rotation calls the ground the room is standing on, ready to
    /// send, or nothing from a room whose maps arrived without names.
    pub(crate) fn map_name_msg(&self) -> Option<Vec<u8>> {
        let name = self.map_names.get(self.map_at)?;
        if name.is_empty() {
            return None;
        }
        let mut m = vec![S2C_MAPNAME];
        m.extend_from_slice(name.as_bytes());
        Some(m)
    }

    pub(crate) fn map_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_MAP];
        m.extend_from_slice(&self.world.packed_map());
        m
    }

    /// Hand one pilot the map and the name beside it. False if their queue
    /// refused either. The name goes with the map rather than on its own, so
    /// the sky and the label a room is drawn under always belong to it.
    fn offer_map(p: &Player, m: &[u8], name: &Option<Vec<u8>>) -> bool {
        if p.tx.try_send(Message::Binary(m.to_vec())).is_err() {
            return false;
        }
        match name {
            Some(n) => p.tx.try_send(Message::Binary(n.clone())).is_ok(),
            None => true,
        }
    }

    /// The ground everybody is playing on. Sent at a join and again whenever a
    /// match opens on a different map, which is the only time it changes. The
    /// name rides beside it, when the room has one.
    ///
    /// Anybody whose queue refuses it is marked, held back from the tuning,
    /// and offered both again every tick until they land. See `Player::owes_map`
    /// for why this one message is worth the bookkeeping.
    pub(crate) fn broadcast_map(&mut self) {
        let m = self.map_msg();
        let name = self.map_name_msg();
        let mut refused = 0;
        for p in self.players.values_mut() {
            if !Self::offer_map(p, &m, &name) {
                p.owes_map = true;
                refused += 1;
                metrics::SEND_DROPPED.inc();
            }
        }
        if refused > 0 {
            println!(
                "room {}: {refused} client(s) refused the map; holding their tuning \
                 and retrying",
                self.number
            );
        }
        // The ground the delayed picture is packed on. Sent live it changed
        // under a watcher five seconds before the frames drawn on it arrived,
        // and since a new map bumps the settings generation the client refused
        // every one of those frames: a map rotation blanked the stands.
        self.tell_watchers(m);
        if let Some(n) = name {
            self.tell_watchers(n);
        }
    }

    /// The clock and the score, for a room that has them.
    ///
    /// The flags, the clock, the score and the optional result artifact share
    /// one packet. A client therefore observes one transition even when its
    /// output queue has room for only one message. See `protocol::S2C_MATCH`
    /// for the byte layout.
    pub(crate) fn match_msg(&self) -> Option<Vec<u8>> {
        let m = self.mode.match_state()?;
        Some(match_message(m, self.artifact_id.map(|id| id as u64)))
    }

    pub(crate) fn broadcast_match(&mut self) {
        let Some(m) = self.match_msg() else {
            return;
        };
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(m.clone()));
        }
        // The clock belongs to the picture it is over. See `Channel`.
        self.tell_watchers(m);
    }

    /// Turn this tick's events into rating movement. The simulation does not
    /// know rating exists; this layer reads what it produced.
    /// Anybody who has sat in a safe zone long enough loses the seat.
    ///
    /// A safe zone is the one place nothing can reach you and you cannot
    /// shoot out of, which makes parking in one free: a room of thirty holds
    /// twenty-nine people fighting and one occupying a seat at no risk. This
    /// is what stops that, and it stops it by moving them to the stands
    /// rather than by disconnecting them. They keep the socket, the map, the
    /// settings and the room; they lose the hull, and taking another is one
    /// press away.
    ///
    /// Dwell, not a total: leaving resets it. Somebody crossing a safe zone at
    /// speed, or ducking into one to recharge, is doing what it is for.
    ///
    /// Bots are exempt. They are not holding a seat from anybody, since the
    /// room asks for theirs back the moment a human is at the door, and a bot
    /// that pathed through a safe zone and stopped would empty the room of the
    /// population it exists to provide.
    pub(crate) fn sweep_safe(&mut self) -> bool {
        let limit = self.world.cfg.safe_limit;
        if limit == 0 {
            return false;
        }
        let mut evicted: Vec<u64> = Vec::new();
        for (id, p) in self.players.iter_mut() {
            let sh = &self.world.state.ships[p.ship as usize];
            let inside = sh.active != 0
                && sh.alive != 0
                && unsafe { sim::sim_in_safe(self.world.cfg.map, sh.x, sh.y) } != 0;
            if !inside || p.bot {
                p.safe = 0;
            } else if p.safe >= limit {
                evicted.push(*id);
            } else {
                p.safe += 1;
            }
        }
        let mut changed = false;
        for id in evicted {
            changed |= self.sit_out(id, true);
        }
        changed
    }

    pub(crate) fn score_events(&mut self) {
        let tick = self.world.state.tick;
        let events = self.world.events.e[..self.world.events.count as usize].to_vec();
        // Who this tick's deaths handed an assist to, as (the pilot credited,
        // the victim). Read off the core's own report rather than worked out
        // from the rating layer's credits, so a pilot is told about exactly
        // the assist their scoreboard column is about to count: the two
        // definitions differ at the edges and only one of them is in the row
        // the pilot can see (decision 53).
        let mut assists: Vec<(u8, u8)> = Vec::new();
        // And who went on a run. Held rather than sent where it is found,
        // because a streak has to reach a feed under the kill that started it
        // and the kills go out below. Both carry this tick, so what decides
        // the order a player reads them in is the order they are written.
        let mut streaks = Vec::new();
        for e in events {
            if e.etype == sim::EV_ASSIST {
                assists.push((e.a, e.b));
            }
            if e.etype == sim::EV_STREAK {
                streaks.push((e.a, e.v));
            }
            if e.etype == sim::EV_CHARGE {
                let Some(sh) = self.world.state.ships.get(e.a as usize) else {
                    continue;
                };
                let mut m = vec![S2C_CHARGE, e.a, e.b];
                m.extend_from_slice(&sh.x.to_le_bytes());
                m.extend_from_slice(&sh.y.to_le_bytes());
                m.extend_from_slice(&tick.to_le_bytes());
                for p in self.players.values() {
                    if p.ship != e.a && fair_contains(&self.world, p.ship, e.a) {
                        let _ = p.tx.try_send(Message::Binary(m.clone()));
                    }
                }
                self.channel.pending_charges.push((sh.x, sh.y, m));
            }
        }
        // Borrowed, not cloned. This runs every tick of every room, and the
        // clone it replaces copied a map of names and account ids at 100 Hz to
        // serve events that mostly do not happen.
        //
        // A seat with no name is a seat nobody is sitting in, which is what a
        // ship that died on the tick its owner disconnected looks like. It used
        // to fall back to the roster name for that index, which was right while
        // seats and roster entries were the same list and is a fabrication now
        // that a name arrives with its pilot.
        let names = &self.names;
        let name_of = move |ship: u8| {
            names
                .get(&ship)
                .map(|k| k.rid.clone())
                .unwrap_or_else(|| format!("ship{ship}"))
        };
        let deaths = ingest_damage(&self.world, &mut self.rating, &name_of);
        let mut mode_finished = false;
        let mut close_match = false;
        let mut open_match = false;
        if !deaths.is_empty() {
            let names = self.public_team_names();
            let mut ctx = modes::ModeCtx {
                world: &mut self.world,
                team_names: &names,
                banner: std::mem::take(&mut self.banner),
                finished: false,
                open_match: false,
                close_match: false,
            };
            for &(victim, killer) in &deaths {
                self.mode.on_death(&mut ctx, victim, killer);
            }
            self.banner = std::mem::take(&mut ctx.banner);
            mode_finished |= ctx.finished;
            close_match |= ctx.close_match;
            open_match |= ctx.open_match;
        }
        for (victim, killer) in deaths {
            // Rating is filed under the pilot's id, which is their account
            // where they have one. The display name is a different question
            // and is answered separately below.
            let vname = self.rid_of(victim);
            let kname = self.rid_of(killer);
            let rated = self.rating.death(tick, &vname);
            // On its way out of this process, if the participants have
            // accounts to file it against. Appending to the spool is a
            // buffered write to a local file, so a tick never waits on it.
            if let Some(r) = rated.as_ref() {
                self.hand_off(r, Some(&kname));
            }
            // Read before the note, because a death clears the run and the
            // live state no longer has it.
            let run = self.world.run_before(victim as usize);
            self.note_death(victim, killer, run);
            let mut m = vec![S2C_KILL];
            m.push(victim);
            m.push(killer);
            // Rating after the exchange, rounded, for the scoreboard.
            let vr = self.rating.rating_of(&vname).round() as i16;
            let kr = self.rating.rating_of(&kname).round() as i16;
            m.extend_from_slice(&vr.to_le_bytes());
            m.extend_from_slice(&kr.to_le_bytes());
            m.push(rated.as_ref().map_or(0, |r| r.credits.len() as u8));
            m.extend_from_slice(&tick.to_le_bytes());
            // Everyone the core credited for this particular death.
            let assisted: Vec<u8> = assists
                .iter()
                .filter(|(_, dead)| *dead == victim)
                .map(|(who, _)| *who)
                .collect();
            // The last byte is the one thing on this message that is not the
            // same for everybody: "you helped with this one". Told to the
            // pilot who did and to nobody else, because who else was shooting
            // is a fact about somebody's own fight, and a room that read it
            // off the feed would be reading a list of who is working together
            // and how hurt the loser already was.
            for p in self.players.values() {
                let mut theirs = m.clone();
                theirs.push(u8::from(assisted.contains(&p.ship)));
                let _ = p.tx.try_send(Message::Binary(theirs));
            }
            // And the copy that claims nothing, which is the one the stands
            // get. It waits in the ring with the frame it belongs to, or the
            // feed would announce a death the delayed picture has not shown
            // yet.
            m.push(0);
            self.channel.pending_feed.push(m.clone());
            let assists = rated.as_ref().map_or(0, |r| r.credits.len());
            if assists > 1 {
                println!(
                    "tick {tick}: {} killed {} with {assists} contributors",
                    self.name_of(killer),
                    self.name_of(victim)
                );
            }
        }
        // The room's news, said to everybody: a streak is the one thing here
        // that is about the arena rather than about a fight somebody can see.
        // No fairness circle, for the same reason a kill has none: knowing
        // that a stranger is on a tear is what makes it worth ending, and it
        // is not a position.
        for (ship, kills) in streaks {
            let mut m = vec![S2C_STREAK, ship, kills.clamp(0, 255) as u8];
            m.extend_from_slice(&tick.to_le_bytes());
            for p in self.players.values() {
                let _ = p.tx.try_send(Message::Binary(m.clone()));
            }
            self.channel.pending_feed.push(m);
            println!(
                "tick {tick}: {} is on a streak of {kills}",
                self.name_of(ship)
            );
        }
        if mode_finished {
            self.finished = true;
        }
        if close_match {
            self.close_match();
        }
        if open_match {
            self.open_match();
        }
    }

    /// A rated death, addressed to the meta-layer.
    ///
    /// Only participants with accounts travel. A guest is rated inside the
    /// room and forgotten when it ends, which is what having no account means,
    /// so sending them would be reporting a pilot nobody can look up. An event
    /// where nobody at all has an account is not sent.
    pub(crate) fn hand_off(&mut self, r: &rating::RatedEvent, killer: Option<&str>) {
        let Some(&victim) = self.accounts.get(&r.victim) else {
            // The victim carries the negative half of the exchange. Without
            // them there is no event, only unbalanced credit.
            return;
        };
        // Whether a person was involved, tracked alongside the credits rather
        // than derived later: only this process knows which rid is a bot, and
        // once the event is a row in the log that knowledge is gone. Retention
        // reads this and nothing else.
        let mut all_bots = self.rating.is_bot(&r.victim);
        let credits: Vec<spool::Credit> = r
            .credits
            .iter()
            .filter_map(|(who, w, before, after)| {
                let account = *self.accounts.get(who)?;
                all_bots = all_bots && self.rating.is_bot(who);
                Some(spool::Credit {
                    account,
                    weight: *w,
                    before: *before,
                    after: *after,
                })
            })
            .collect();
        if credits.is_empty() {
            return;
        }
        let ev = spool::Event {
            // Random rather than derived, because nothing here is unique
            // enough to derive from: ticks restart with the process, so a
            // key built on them would recur across two lives of one instance.
            id: rand::random(),
            tick: r.tick,
            victim,
            killer: killer.and_then(|who| self.accounts.get(who)).copied(),
            victim_kind: u8::from(self.rating.is_bot(&r.victim)),
            victim_before: r.victim_before,
            victim_after: r.victim_after,
            credits,
            bots_only: all_bots,
        };
        if let Ok(mut s) = self.spool.lock() {
            s.push(ev);
        }
    }

    pub(crate) fn name_of(&self, ship: u8) -> String {
        self.names
            .get(&ship)
            .map(|k| k.name.clone())
            .unwrap_or_else(|| format!("ship{ship}"))
    }

    /// What a seat's rating is filed under, which is not what it is called.
    pub(crate) fn rid_of(&self, ship: u8) -> String {
        self.names
            .get(&ship)
            .map(|k| k.rid.clone())
            .unwrap_or_else(|| format!("ship{ship}"))
    }

    pub(crate) fn banner_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_BANNER];
        m.extend_from_slice(self.banner.as_bytes());
        m
    }

    pub(crate) fn broadcast_banner(&mut self) {
        let m = self.banner_msg();
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(m.clone()));
        }
        // Watchers read the round too, and it is a line about the fight in
        // front of them: "the clock has run out and the next death settles
        // it" over two ships with five seconds still to fly is the banner
        // arriving before the moment it describes.
        self.tell_watchers(m);
    }

    fn snapshot_buffer(buf: &mut [u8], private: bool) -> &mut [u8] {
        let cap = if private {
            sim::STATE_PACK_MAX
        } else {
            sim::PACK_MAX
        };
        let len = buf.len().min(cap);
        &mut buf[..len]
    }

    pub(crate) fn broadcast_player_snapshots(&mut self, buf: &mut [u8], combat_lane: bool) {
        let world = &self.world;
        let names = &self.names;
        for p in self.players.values_mut() {
            // Packed per player rather than once for everybody, so each is
            // sent only what is near its own ship. A client can act on the
            // handful inside its radar, sixty tiles out, and nothing beyond
            // it: the rest is bytes bought and thrown away.
            //
            // A pack is under two microseconds, so sixteen of them is thirty
            // microseconds of a fifty millisecond period. The bytes saved are
            // worth far more than the pack costs.
            let sh = &world.state.ships[p.ship as usize];
            // Our own bots get the whole room. They sit on loopback, and the
            // bot server predicts each room in one world shared by all its
            // pilots, which is only sound if any one bot's snapshot is the
            // whole room's truth. It costs no egress and it buys no sight
            // anybody could act on, since the process holding it is ours.
            //
            // The label rather than the declaration, and that is the whole
            // point of this line. `p.bot` is what the client said about
            // itself at join, and anybody may say it: before this, declaring
            // yourself a bot from any address on the internet was a request
            // for the position, heading and energy of every ship on the map,
            // granted. The label is derived from the account the token was
            // minted for and cannot be asserted by a client, so a third-party
            // bot is now filtered exactly like the person running it.
            let house = names
                .get(&p.ship)
                .is_some_and(|s| s.label == token::Label::HouseBot.to_byte());
            let now = world.state.tick;
            let close = !house && near_combat(world, p.ship);
            if close {
                p.combat_until = Some(now.wrapping_add(COMBAT_TAIL_TICKS));
            } else if p.combat_until.is_some_and(|until| serial_after(now, until)) {
                p.combat_until = None;
            }
            let fast = !house && (close || p.combat_until.is_some());
            if fast != combat_lane {
                continue;
            }
            let radius = if house { -1 } else { FAIR_INTEREST };
            // Their own seat, so the private half of the snapshot is theirs.
            let options = if house { sim::PACK_PRIVATE_ALL } else { 0 };
            let packed = Self::snapshot_buffer(buf, house);
            let n = world.pack_around(packed, sh.x, sh.y, radius, p.ship, options);
            if n <= 0 {
                continue;
            }
            let seq =
                p.lag
                    .sent_snapshot(world.state.tick, combat_lane, self.lag_policy.sample_ticks);
            let mut msg = Vec::with_capacity(n as usize + SNAPSHOT_HEADER);
            msg.push(S2C_SNAPSHOT);
            msg.push(p.ship);
            msg.push(SNAPSHOT_FLYING);
            msg.extend_from_slice(&p.lifecycle.to_le_bytes());
            msg.extend_from_slice(&self.settings_generation.to_le_bytes());
            msg.extend_from_slice(&p.input_ack.to_le_bytes());
            msg.extend_from_slice(&p.input_mask.to_le_bytes());
            msg.extend_from_slice(&seq.to_le_bytes());
            p.lag.append_telemetry(&mut msg);
            msg.extend_from_slice(&packed[..n as usize]);
            // Counted here rather than at the socket: this is the byte the
            // room decided to send, and egress is what a host bills for.
            metrics::SNAPSHOT_BYTES.add(msg.len() as u64);
            // And again, to the side of the split that answers "what does a
            // player download". Ours are excluded because they are sent the
            // whole room over loopback, and averaging them in is what made the
            // fleet view report three hundred kilobytes a second for a client
            // pulling seventeen.
            if !house {
                metrics::SNAPSHOT_BYTES_OUT.add(msg.len() as u64);
            }
            metrics::SNAPSHOT_LAST.set(msg.len() as i64);
            if p.tx.try_send(Message::Binary(msg)).is_err() {
                metrics::SEND_DROPPED.inc();
            }
        }
        if !combat_lane {
            // Network seats, whether this particular pass selected them or
            // the combat lane did. This is the denominator for all outbound
            // snapshot bytes, not a count of messages on one cadence.
            let network_seats = self
                .players
                .values()
                .filter(|p| {
                    self.names
                        .get(&p.ship)
                        .is_none_or(|s| s.label != token::Label::HouseBot.to_byte())
                })
                .count() as i64;
            metrics::SEATS_OUT.set(network_seats);
        }
    }

    /// One room message for the stands, held for the frame it belongs with.
    ///
    /// Every watcher on the channel is served the same bytes at the same
    /// moment, so this queues once rather than once per watcher, and it runs
    /// with nobody in the stands: the ring is what a watcher arrives into.
    fn tell_watchers(&mut self, m: Vec<u8>) {
        self.channel.pending_state.push(m);
    }

    /// What the channel is showing, for somebody who has just walked into the
    /// stands: the last copy of each room message the ring actually served,
    /// falling back to the live one for anything it has not served yet, which
    /// is only a room whose ring is still filling.
    ///
    /// A one-off line rides the feed rather than this, so nobody arrives to a
    /// kill or a podium phrase from a match that is already over.
    pub(crate) fn channel_sync(&self) -> Vec<Vec<u8>> {
        let mut live = vec![self.map_msg()];
        if let Some(n) = self.map_name_msg() {
            live.push(n);
        }
        live.push(self.settings_msg());
        if let Some(m) = self.match_msg() {
            live.push(m);
        }
        live.push(self.banner_msg());
        live.push(self.roster_msg());
        live.into_iter()
            .map(|m| self.channel.served_state.get(&m[0]).cloned().unwrap_or(m))
            .collect()
    }

    pub(crate) fn broadcast_snapshot(&mut self, buf: &mut [u8]) {
        self.broadcast_player_snapshots(buf, false);
        let buf = Self::snapshot_buffer(buf, false);
        // Everybody in the stands is on the one feed, so there is nothing to
        // pack per watcher: the channel is packed once and fanned out.
        self.channel_frame(buf);
    }

    /// One frame of the room channel: pick the subject if its hold expired,
    /// pack once, push into the delay ring, and serve everything old enough.
    /// Runs whether or not anybody is on the channel, so a watcher arriving
    /// lands in a warm ring instead of staring at nothing for the delay.
    pub(crate) fn channel_frame(&mut self, buf: &mut [u8]) {
        // Re-pick when the hold runs out or the seat empties. Live humans
        // first, because a random camera in a bot-filled room is a bot
        // documentary five frames out of six; then any human, then any seat.
        let valid = self
            .channel
            .subject
            .is_some_and(|s| self.names.contains_key(&s));
        if !valid || self.channel.hold == 0 {
            let mut pool: Vec<u8> = self
                .names
                .iter()
                .filter(|(s, k)| !k.bot && self.world.state.ships[**s as usize].alive == 1)
                .map(|(s, _)| *s)
                .collect();
            if pool.is_empty() {
                pool = self
                    .names
                    .iter()
                    .filter(|(_, k)| !k.bot)
                    .map(|(s, _)| *s)
                    .collect();
            }
            if pool.is_empty() {
                pool = self.names.keys().copied().collect();
            }
            let pick = if pool.is_empty() {
                None
            } else {
                Some(pool[(self.channel.next_rand() % pool.len() as u64) as usize])
            };
            // Who the camera is on. Nobody is told anything here: being
            // picked is not being seen, and what a pilot is owed is the
            // second one. See `refresh_on_air`.
            self.channel.subject = pick;
            self.channel.hold = CHANNEL_HOLD;
        }
        self.channel.hold = self.channel.hold.saturating_sub(SNAPSHOT_EVERY);

        // Packed once, same bytes for everybody on the channel. The human
        // radius always; an empty room points the camera at the map's middle.
        let (cx, cy, subject) = match self.channel.subject {
            Some(s) => {
                let sh = &self.world.state.ships[s as usize];
                (sh.x, sh.y, s)
            }
            None => {
                let mid = 512 * sim::TILE_PX * 256;
                (mid, mid, 255u8)
            }
        };
        let n = self.world.pack_around(buf, cx, cy, FAIR_INTEREST, 255, 0);
        if n > 0 {
            let mut msg = Vec::with_capacity(n as usize + SNAPSHOT_HEADER);
            msg.push(S2C_SNAPSHOT);
            msg.push(subject);
            msg.push(SNAPSHOT_WATCHING);
            // Patched for each watcher when the delayed frame is served.
            msg.extend_from_slice(&0u32.to_le_bytes());
            msg.extend_from_slice(&self.settings_generation.to_le_bytes());
            msg.extend_from_slice(&0u32.to_le_bytes());
            msg.extend_from_slice(&0u32.to_le_bytes());
            msg.extend_from_slice(&0u32.to_le_bytes());
            msg.extend_from_slice(&[0; 9]);
            msg.extend_from_slice(&buf[..n as usize]);
            let charges = std::mem::take(&mut self.channel.pending_charges)
                .into_iter()
                .filter_map(|(x, y, msg)| fair_contains_xy(cx, cy, x, y).then_some(msg))
                .collect();
            self.channel.ring.push_back(ChannelFrame {
                tick: self.world.state.tick,
                subject,
                feed: std::mem::take(&mut self.channel.pending_feed),
                charges,
                state: std::mem::take(&mut self.channel.pending_state),
                msg,
            });
        }

        // Serve everything old enough: one frame per snapshot once the ring
        // is warm, each with the kills it was holding, so the feed cannot
        // spoil a death the picture has not shown.
        let now = self.world.state.tick;
        let delay = CHANNEL_DELAY;
        while self
            .channel
            .ring
            .front()
            .is_some_and(|f| serial_at_or_before(f.tick.wrapping_add(delay), now))
        {
            let f = self.channel.ring.pop_front().unwrap();
            // What the channel is showing, whether or not anybody is on it:
            // the ring runs regardless so an arriving watcher lands in a warm
            // picture, and this follows the picture rather than the audience.
            self.channel.showing = if f.subject == 255 {
                None
            } else {
                Some(f.subject)
            };
            // Ahead of the picture, because some of it is what the picture
            // is read through: a map and its settings have to be in hand
            // before the first frame packed on them arrives.
            for m in &f.state {
                self.channel.served_state.insert(m[0], m.clone());
            }
            for w in self.watchers.values() {
                for m in &f.state {
                    let _ = w.tx.try_send(Message::Binary(m.clone()));
                }
                for k in &f.feed {
                    let _ = w.tx.try_send(Message::Binary(k.clone()));
                }
                for charge in &f.charges {
                    let _ = w.tx.try_send(Message::Binary(charge.clone()));
                }
                let mut msg = f.msg.clone();
                msg[3..7].copy_from_slice(&w.lifecycle.to_le_bytes());
                metrics::SNAPSHOT_BYTES.add(msg.len() as u64);
                if w.tx.try_send(Message::Binary(msg)).is_err() {
                    metrics::SEND_DROPPED.inc();
                }
            }
        }

        self.refresh_on_air();
    }

    /// Who is being looked at, and telling them when that changes.
    ///
    /// The tally has to mean "somebody is seeing you", so it is derived from
    /// the audience rather than from the camera: the frame going out shows
    /// you, and there is somebody in the stands to see it. That is not the
    /// same as the channel having picked you, which is what this used to
    /// announce: a pilot alone in a room with no watchers at all wore the
    /// tally, and a pilot the camera had just landed on wore it for the whole
    /// delay before a single frame of them was served.
    pub(crate) fn refresh_on_air(&mut self) {
        let mut lit: std::collections::HashSet<u8> = std::collections::HashSet::new();
        if !self.watchers.is_empty() {
            if let Some(s) = self.channel.showing {
                lit.insert(s);
            }
        }
        if lit == self.on_air {
            return;
        }
        // Edges only. A player who is still being watched hears nothing,
        // which is what makes this safe to run every snapshot.
        for ship in self.on_air.difference(&lit) {
            if let Some(p) = self.players.values().find(|p| p.ship == *ship) {
                let _ = p.tx.try_send(Message::Binary(vec![S2C_ONAIR, 0]));
            }
        }
        for ship in lit.difference(&self.on_air) {
            if let Some(p) = self.players.values().find(|p| p.ship == *ship) {
                let _ = p.tx.try_send(Message::Binary(vec![S2C_ONAIR, 1]));
            }
            // The rising edge only. A pilot is told on the wire that they are
            // being watched, and what the room disclosed about somebody who
            // did not choose to be watched is worth being able to answer for
            // later. Bounded by real spectating: with nobody in the stands
            // this set is empty and no row is ever written.
            if let Some(seat) = self.names.get(ship).cloned() {
                self.note(pilot::ON_AIR, &seat, serde_json::json!({ "ship": ship }));
            }
        }
        self.on_air = lit;
    }

    /// Names and labels, sent on every join and leave and then every two
    /// seconds regardless. A player deserves to know who they are fighting, so
    /// the label rides here: human, house bot, third-party bot, or unknown.
    ///
    /// It used to be one bit for "this is AI". Three values were not enough
    /// once bots could be somebody else's and a pilot could be a guest we
    /// genuinely cannot vouch for, and guessing on a player's behalf is the
    /// one thing this field must not do.
    ///
    /// The scores ride here too, and that is what keeps a scoreboard whole
    /// once snapshots stopped being. A client is no longer told about a ship
    /// on the far side of the map, so it can no longer read that ship's kills
    /// out of the simulation; this channel already carried every seat in the
    /// arena on a slow clock, which is exactly the shape a scoreboard wants.
    /// Eleven bytes a seat at half a hertz is a fifth of a kilobyte a second
    /// against the three hundred the cull took off.
    ///
    /// Team comes with them because the board groups by side, and a seat you
    /// cannot see is still a seat on somebody's team. It says nothing about
    /// where they are, which is the line this whole change draws.
    pub(crate) fn roster_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ROSTER];
        m.push(self.names.len() as u8);
        for (ship, seat) in &self.names {
            m.push(*ship);
            m.push(seat.label);
            m.extend_from_slice(&(self.rating.rating_of(&seat.rid).round() as i16).to_le_bytes());
            // Rated deaths so far. The client derives the tier from the
            // rating itself, but it cannot know from a number alone whether
            // that number has been earned yet, and an unearned rating should
            // not be shown as if it had been.
            m.push(self.rating.games_of(&seat.rid).min(255) as u8);
            let sh = &self.world.state.ships[*ship as usize];
            m.push(sh.team);
            m.extend_from_slice(&sh.kills.to_le_bytes());
            m.extend_from_slice(&sh.deaths.to_le_bytes());
            m.extend_from_slice(&sh.assists.to_le_bytes());
            let bytes = seat.name.as_bytes();
            let len = bytes.len().min(24) as u8;
            m.push(len);
            m.extend_from_slice(&bytes[..len as usize]);
        }
        // The watchers, after the ships: label, then the name. No ship index
        // and no rating, because a watcher is not fighting in this room. Named
        // on purpose: the roster exists so you know who is in the room with
        // you, and an unnamed watcher is exactly the scout the sight rules
        // are pricing. Invisibility is a capability someday, not a default.
        m.push(self.watchers.len().min(255) as u8);
        for w in self.watchers.values() {
            m.push(w.seat.label);
            let bytes = w.seat.name.as_bytes();
            let len = bytes.len().min(24) as u8;
            m.push(len);
            m.extend_from_slice(&bytes[..len as usize]);
        }
        m
    }

    /// The team list, as one client sees it.
    ///
    /// Per recipient because two of its answers are: which side you are on,
    /// and which of these doors is open to you. A public side with room is
    /// open to everybody; a private one only to whoever it invited. The counts
    /// are the same for all, but splitting the message to share them would
    /// cost more than building a few dozen bytes a handful of times a minute.
    pub(crate) fn teams_msg(&self, ship: u8) -> Vec<u8> {
        let bot = self.names.get(&ship).is_some_and(|s| s.bot);
        let mine = self.world.state.ships[ship as usize].team;
        // Which sides are worth telling this client about: the zone's own,
        // the one they are on, and any that has invited them. A free-for-all
        // is why this is a filter rather than the whole list -- there, every
        // pilot is a side, so sixty-four seats is sixty-four teams, and a menu
        // listing sixty-three strangers' private sides of one is a menu nobody
        // can use. A pact you were not invited to is not a door you can open,
        // and who is allied with whom already reads off the scoreboard.
        let shown: Vec<u8> = self
            .teams
            .iter()
            .filter(|(b, t)| {
                t.public || **b == mine || self.invites.get(&ship).is_some_and(|s| s.contains(b))
            })
            .map(|(b, _)| *b)
            .collect();
        let mut m = vec![S2C_TEAMS];
        m.push(mine);
        // Whether the found-a-team row is offered. A zone whose `max_teams` is
        // its own count never offers it, which is how a flag round says there
        // is no third side to be -- and neither does a room where you are
        // already alone on one of your own, since founding another would hand
        // you the same solitude under a different name.
        let alone = self.teams.get(&mine).is_some_and(|t| !t.public)
            && self.team_census(mine, None) == (1, 0);
        m.push(u8::from(self.free_team_byte().is_some() && !alone));
        m.push(shown.len().min(255) as u8);
        for byte in shown {
            let team = &self.teams[&byte];
            let (humans, bots) = self.team_census(byte, None);
            m.push(byte);
            m.push(u8::from(team.public));
            m.push(u8::from(self.may_join(ship, byte, bot)));
            m.push(humans.min(255) as u8);
            m.push(bots.min(255) as u8);
            let bytes = team.name.as_bytes();
            let len = bytes.len().min(24) as u8;
            m.push(len);
            m.extend_from_slice(&bytes[..len as usize]);
        }
        m
    }

    /// The same list as a watcher sees it.
    ///
    /// They need it for one thing the flying version is also for: knowing
    /// which side is theirs. Every watcher has one, whether they sat out from
    /// it or were seated on it at the door, and it is what decides whose hull
    /// they may ask to follow, so without this the interface cannot tell a
    /// lawful ask from one that will fall to the channel and has to either
    /// offer every pilot or none. The exception is a free-for-all, where there
    /// are no shared sides to be on and 255 is the truth.
    ///
    /// No doors in it. Every `may_join` is zero and so is the found byte,
    /// because a watcher crosses nothing while watching: taking a hull again
    /// is what puts them back on a side.
    pub(crate) fn watcher_teams_msg(&self, w: &Watcher) -> Vec<u8> {
        let mine = w.team.unwrap_or(255);
        let shown: Vec<u8> = self
            .teams
            .iter()
            .filter(|(b, t)| t.public || Some(**b) == w.team)
            .map(|(b, _)| *b)
            .collect();
        let mut m = vec![S2C_TEAMS];
        m.push(mine);
        m.push(0);
        m.push(shown.len().min(255) as u8);
        for byte in shown {
            let team = &self.teams[&byte];
            let (humans, bots) = self.team_census(byte, None);
            m.push(byte);
            m.push(u8::from(team.public));
            m.push(0);
            m.push(humans.min(255) as u8);
            m.push(bots.min(255) as u8);
            let bytes = team.name.as_bytes();
            let len = bytes.len().min(24) as u8;
            m.push(len);
            m.extend_from_slice(&bytes[..len as usize]);
        }
        m
    }

    /// Sent on every change to who is where, and to whom. Cheap enough to send
    /// whole rather than diffed: a room holds a handful of sides.
    ///
    /// The one thing a watcher reads that does not ride the channel's delay.
    /// It names the sides and colors the screen, which is the room rather than
    /// the moment, and it is built per recipient, so there is no one copy for
    /// the ring to hold.
    pub(crate) fn broadcast_teams(&self) {
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(self.teams_msg(p.ship)));
        }
        for w in self.watchers.values() {
            let _ = w.tx.try_send(Message::Binary(self.watcher_teams_msg(w)));
        }
    }

    /// Offer the map again to anybody whose queue refused it, with the tuning
    /// behind it, and clear the debt only when the whole set lands.
    ///
    /// Every tick rather than on a clock. A queue that refused a message is a
    /// queue that is draining, so this is normally one retry a tick or two
    /// later. While it is outstanding that client refuses snapshots for a
    /// generation it has no map for and its screen stops, which is the better
    /// of the two failures: the other is a whole match flown on the previous
    /// round's walls.
    fn retry_owed_maps(&mut self) {
        if !self.players.values().any(|p| p.owes_map) {
            return;
        }
        let m = self.map_msg();
        let name = self.map_name_msg();
        let settings = self.settings_msg();
        for p in self.players.values_mut() {
            if p.owes_map
                && Self::offer_map(p, &m, &name)
                && p.tx.try_send(Message::Binary(settings.clone())).is_ok()
            {
                p.owes_map = false;
            }
        }
    }

    pub(crate) fn settings_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_SETTINGS];
        m.extend_from_slice(&self.settings_generation.to_le_bytes());
        m.extend_from_slice(&self.world.packed_settings());
        m
    }

    /// Everyone in the room gets the new numbers. An operator retuning a
    /// live arena would otherwise leave every client predicting the game as
    /// it was when they joined.
    pub(crate) fn broadcast_settings(&mut self) {
        let m = self.settings_msg();
        for p in self.players.values_mut() {
            // Held back from anybody still owed the map. The generation this
            // carries is what a client checks every snapshot against, so a
            // pilot who takes it without the ground it belongs to stops
            // refusing frames and starts predicting the new match on the last
            // match's walls. Refused here for the same reason: both halves
            // arrive together on a later tick or neither does.
            if p.owes_map {
                continue;
            }
            if p.tx.try_send(Message::Binary(m.clone())).is_err() {
                p.owes_map = true;
                metrics::SEND_DROPPED.inc();
            }
        }
        // A watcher decodes snapshots through the same core, so stale rules
        // would have it drawing a different game than the one it is shown.
        // Rules that arrive early are that same fault the other way round.
        // Each frame carries the generation it was packed under, so the rules
        // reach the stands with the first frame that was played by them.
        self.tell_watchers(m);
    }

    /// Called on every change, and on a two-second clock from the tick loop so a
    /// client whose queue was full gets another one. `try_send` is why it needs
    /// the clock.
    pub(crate) fn broadcast_roster(&mut self) {
        let m = self.roster_msg();
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(m.clone()));
        }
        // The scoreboard rides here, so a live copy would put the kill in the
        // panel five seconds before the picture showed it, which is the
        // spoiler the feed is held back to avoid.
        self.tell_watchers(m);
    }
}

#[cfg(test)]
mod wire_tests {
    use super::*;

    #[test]
    fn match_headings_point_at_all_four_cardinal_targets() {
        let from = (100, 100);
        assert_eq!(heading_toward(from, (100, 0)), 0);
        assert_eq!(heading_toward(from, (200, 100)), 16384);
        assert_eq!(heading_toward(from, (100, 200)), 32768);
        assert_eq!(heading_toward(from, (0, 100)), 49152);
    }

    /// The clock, the score and the result artifact ride in one packet, so a
    /// client that can hold only one message never reads a score from one
    /// state under a result from another.
    #[test]
    fn a_match_has_the_documented_atomic_layout() {
        let message = match_message(
            modes::MatchState {
                playing: false,
                seconds_left: 0x50,
                score: vec![1, 0],
            },
            Some(0x7172_7374_7576_7778),
        );

        assert_eq!(message.len(), 16, "header, two scores, the artifact");
        assert_eq!(message[0], S2C_MATCH);
        assert_eq!(message[1], MATCH_HAS_ARTIFACT, "a result is carried");
        assert_eq!(message[2], 0x50);
        assert_eq!(message[3], 2);
        assert_eq!(u16::from_le_bytes(message[4..6].try_into().unwrap()), 1);
        assert_eq!(u16::from_le_bytes(message[6..8].try_into().unwrap()), 0);
        assert_eq!(
            u64::from_le_bytes(message[8..16].try_into().unwrap()),
            0x7172_7374_7576_7778
        );
    }

    /// A match still being played carries no artifact, and the flag says so
    /// rather than the reader having to measure the packet.
    #[test]
    fn a_live_match_carries_no_result() {
        let message = match_message(
            modes::MatchState {
                playing: true,
                seconds_left: 180,
                score: vec![0, 0],
            },
            None,
        );
        assert_eq!(message.len(), 8, "header and two scores");
        assert_eq!(message[1], MATCH_PLAYING);
    }
}
