//! The bot server: the AI roster, flown as clients.
//!
//!     vectorwake-server bots
//!
//! One process holds a deployment's whole bot population. It browses a
//! directory the way the game client does, and for every arena it finds it
//! opens as many WebSocket connections as that arena says it wants bots. Each
//! connection is an ordinary client: it declares itself a bot at join, takes the
//! map and the settings the zone sends, decodes every snapshot through the
//! simulation core, and answers with input messages. There is no other channel.
//!
//! That is the whole of decision 29. Bots used to run inside the arena's tick,
//! reading its `World` directly, which was cheaper and which cost us the two
//! things this arrangement buys. The wire is exercised by its own population, so
//! a protocol bug is a bot flying badly in every room rather than something only
//! a harness ever meets. And "a bot knows no more than a player" stops being a
//! convention about which functions take a `&World`: a bot here has nothing to
//! read but the snapshot the arena decided to send it.
//!
//! What it costs is on the arena rather than here: a snapshot stream per bot
//! where the in-process roster needed none. See docs/architecture/ai-runtime.md.
//!
//! Two economies inside the process, both invisible on the wire. Pilots in one
//! arena room predict it in one shared `Rig` rather than private copies, while
//! pilots in other rooms have separate rigs. Each rig has one clock: a single
//! driver task advances the world and runs every seated brain,
//! where each pilot used to carry a 100 Hz ticker of its own, which at fifty
//! pilots was most of this process's CPU spent waking up and contending for
//! the lock rather than flying. Each connection still joins, receives and
//! answers as an ordinary client; where the bytes land, and who does the
//! thinking, is this process's own business.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

use crate::{ai, directory, nav, pilots, sim};

/// How often the fleet is re-read and the population reconciled. A second is
/// far quicker than a population changes and costs one small JSON document per
/// directory, so the loop is never the reason a room fills slowly.
const POLL_MS: u64 = 1000;
/// Connections opened per cycle per instance. Fifty bots arriving in the same
/// millisecond is a thundering herd against the one process they all want, and
/// there is nothing to gain by it: eight a second fills a 64-seat room in six.
const ADD_PER_CYCLE: usize = 8;
/// How long a bot lives before it can be asked to leave. Without it a player
/// joining and quitting repeatedly makes the roster flicker, which
/// docs/design/ai-players.md calls out by name.
const MIN_LIFE_MS: u64 = 30_000;
/// And how long an instance waits after letting a bot go before it takes
/// another. The other half of the same guard.
const REFILL_COOLDOWN_MS: u64 = 30_000;
/// The whole budget for leaving: break off, fly somewhere nobody is, and stop.
/// Past this the bot goes wherever it happens to be.
///
/// Forty seconds, against the ten it replaces. Ten was not a backstop, it was
/// the exit: the old rule waited for a death or an empty horizon while the bot
/// went on fighting at full strength, and in a busy room neither arrives, so
/// what fired was the timer and what a player saw was an opponent vanishing
/// mid-duel. This is sized so the ordinary departure finishes well inside it
/// and reaching it means something went wrong.
///
/// It is charged to a seat somebody may be waiting for: a yielding bot still
/// holds its own until it goes. That is affordable only because a room with no
/// seats left does not wait: `evict_bot` takes one that tick.
const DEPART_MAX_MS: u64 = 40_000;
/// No frame of any kind arrives for ten seconds. Snapshot progress has its own
/// shorter deadline; this one catches a socket that has gone completely quiet.
const QUIET_MS: u64 = 10_000;
/// A bot normally sends only when its controls change. Repeat the current
/// controls once a second so a healthy pilot never looks silent to the arena's
/// connection timeout.
const INPUT_HEARTBEAT_TICKS: u32 = 50;
/// How often the shared driver's supervisor checks that its clock moved, and
/// how long no movement is allowed before it starts a replacement driver.
const DRIVER_WATCH_MS: u64 = 1_000;
const DRIVER_STALL_MS: u64 = 5_000;
/// Consecutive cycles an arena may fail to answer before its bots are called
/// home. Five seconds of silence from a process on the same host is gone; one
/// second of it is a busy moment, and treating that as gone would empty a room
/// and refill it for no reason anybody could see.
const GONE_AFTER: u32 = 5;
/// A flying client receives snapshots at least twenty times a second. Five
/// seconds without one is a live socket whose simulation has stopped.
const SNAPSHOT_STALL_MS: u64 = 5_000;
const RETRY_MAX_MS: u64 = 60_000;

/// Geometry, shared by every bot that was sent the same map.
///
/// A map unpacks to a megabyte and fifty bots in one zone are sent the identical
/// bytes, so without this the population would cost fifty megabytes of duplicate
/// tiles per zone. It is the same trick the arena uses to keep a room at 79 KB,
/// and the same `Arc`.
/// The routing grid rides along with it, for the same reason and by the same
/// argument: it is derived from the map and nothing else, so fifty pilots on
/// one map want one of them rather than fifty. Building it reads a million
/// tiles, which is a cost worth paying once.
/// The pair every pilot on one map shares: the map itself and the routes
/// through it.
type Ground = (Arc<sim::sim_map>, Arc<nav::Nav>);

enum MapEntry {
    Building(Arc<tokio::sync::OnceCell<Option<Ground>>>),
    Ready(std::sync::Weak<sim::sim_map>, std::sync::Weak<nav::Nav>),
}

#[derive(Default)]
struct Maps(Mutex<HashMap<u64, MapEntry>>);

impl Maps {
    /// Get one map and routing grid. The first caller builds them off the async
    /// runtime; everybody arriving behind it waits on the same cell. Ready
    /// entries are weak, so a map rotation releases geometry nobody is flying.
    async fn get(&self, packed: &[u8]) -> Option<Ground> {
        let key = fingerprint(packed);
        let build = {
            let mut maps = self.0.lock().ok()?;
            maps.retain(|_, entry| match entry {
                MapEntry::Building(_) => true,
                MapEntry::Ready(map, route) => map.strong_count() > 0 && route.strong_count() > 0,
            });
            match maps.get(&key) {
                Some(MapEntry::Ready(map, route)) => {
                    return Some((map.upgrade()?, route.upgrade()?));
                }
                Some(MapEntry::Building(cell)) => Arc::clone(cell),
                None => {
                    let cell = Arc::new(tokio::sync::OnceCell::new());
                    maps.insert(key, MapEntry::Building(Arc::clone(&cell)));
                    cell
                }
            }
        };
        let bytes = packed.to_vec();
        let ground = build
            .get_or_init(|| async move {
                tokio::task::spawn_blocking(move || {
                    crate::metrics::BOT_MAP_BUILDS.inc();
                    let map = sim::unpack_map(&bytes).ok()?;
                    let route = Arc::new(nav::Nav::build(&map));
                    Some((map, route))
                })
                .await
                .ok()
                .flatten()
            })
            .await
            .clone();
        let mut maps = self.0.lock().ok()?;
        if maps.get(&key).is_some_and(
            |entry| matches!(entry, MapEntry::Building(cell) if Arc::ptr_eq(cell, &build)),
        ) {
            match &ground {
                Some((map, route)) => {
                    maps.insert(
                        key,
                        MapEntry::Ready(Arc::downgrade(map), Arc::downgrade(route)),
                    );
                }
                None => {
                    maps.remove(&key);
                }
            }
        }
        ground
    }
}

/// FNV-1a over the packed map. Only ever used to notice that two clients were
/// sent the same geometry, so it needs to be fast and not to be a hash anybody
/// trusts.
fn fingerprint(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// Tells pilots apart for seat and pen ownership. Starts at one so that zero
/// can mean nobody.
static PILOT_ID: AtomicU64 = AtomicU64::new(1);
/// Per-flight entropy. A pilot's stable configuration seed lives in its spec;
/// this counter exists so reconnecting does not replay the same fight forever.
static MATCH_ID: AtomicU64 = AtomicU64::new(1);

/// One predicted room, shared by every pilot this process has flying in it.
///
/// Fifty-one pilots on one arena used to hold fifty-one private copies of the
/// same room and step every one of them at 100 Hz, so each copy re-simulated
/// all fifty-one ships to move one. Measured on the live shape of the fleet,
/// that was 82% of this process's CPU, and the answer it bought each pilot was
/// the answer the pilot next door had already computed. The room is the same
/// room for everybody, so it is predicted once.
///
/// One pilot holds the pen: it applies the arena's snapshots and steps the
/// world each tick with every seat's latest buttons. The rest only read. What
/// a pilot gives up is the instant echo of its own input, which now lands on
/// the next shared step, up to one tick late. The servo already rides out
/// five-tick snapshot corrections, so a tick of echo lag is inside the noise
/// it was built to absorb. What a pilot gains, besides the CPU, is a live
/// picture of the other bots' inputs between snapshots, where its private
/// world showed every other ship coasting.
///
/// Sound only while any one bot's snapshot is the whole room's truth, which
/// the arena now guarantees for declared bots: see `broadcast_snapshot`.
/// What the driver tells a connection task. Frames are this pilot's own
/// input messages, sent on its own socket so the wire holds one client per
/// bot exactly as decision 29 requires; Leave is a departure that finished,
/// however it finished.
enum Ctl {
    Frame { match_number: u32, message: Vec<u8> },
    Leave,
}

/// Derive an independent controller stream for each match on one connection.
/// Number zero preserves the flight's original seed. Later matches mix in the
/// monotonic match number, so a rematch is fresh without depending on wall
/// time or on which driver happened to process the transition first.
fn controller_seed(flight_seed: u32, match_number: u32) -> u32 {
    if match_number == 0 {
        return flight_seed;
    }
    flight_seed ^ match_number.wrapping_mul(0x9e37_79b9).rotate_left(13)
}

fn fresh_brain(
    ship: u8,
    config: pilots::BrainConfig,
    flight_seed: u32,
    match_number: u32,
) -> ai::Bot {
    let mut brain = ai::Bot::new(ship, config);
    brain.reseed(controller_seed(flight_seed, match_number));
    brain
}

/// Apply one authoritative match state and say whether a new match began.
/// Duplicate packets do not advance the number or reset a brain.
/// Seconds left on the match clock, off the room's own broadcast.
///
/// `[S2C_MATCH, flags, seconds left, sides, ...]`, and only while the match is
/// running: between matches that byte counts an intermission down rather than a
/// match, and there is no rack to spend during one.
///
/// A zero is the room counting nothing, which is a flag game for all of a
/// match except the fifteen seconds somebody spends holding every flag. Those
/// fifteen are seconds until the whistle like any other, so they are what a
/// pilot with charges left should be pacing against.
fn seconds_left(data: &[u8]) -> Option<f32> {
    let playing = data.get(1)? & crate::MATCH_PLAYING != 0;
    let left = *data.get(2)?;
    (playing && left > 0).then_some(left as f32)
}

fn match_transition(playing: &mut bool, match_number: &mut u32, next: bool) -> bool {
    let began = !*playing && next;
    if began {
        *match_number = match_number.wrapping_add(1);
    }
    *playing = next;
    began
}

/// One pilot's standing in the shared rig: its brain and everything the
/// driver needs to fly it. The connection task holds the socket; this holds
/// the mind. Constructed at welcome, removed at release or departure.
struct Seat {
    id: u64,
    lifecycle: u32,
    name: String,
    addr: String,
    brain: ai::Bot,
    brain_config: pilots::BrainConfig,
    flight_seed: u32,
    match_number: u32,
    playing: bool,
    /// Seconds left on the match clock, as the room last broadcast it. A rack
    /// of charges is a match's supply rather than a life's, so the pilot
    /// deciding whether to spend one needs the same clock every player in the
    /// room is reading off the top of their screen.
    match_left: Option<f32>,
    route: Arc<nav::Nav>,
    yielding: Arc<AtomicBool>,
    asked: Option<std::time::Instant>,
    sent: Option<u16>,
    sent_at: u32,
    tx: tokio::sync::mpsc::Sender<Ctl>,
}

impl Seat {
    /// Follow the connection's authoritative match state. A false-to-true
    /// transition replaces the whole controller, including its timers, route,
    /// recovery state, departure state, and random stream.
    fn set_match(&mut self, playing: bool, match_number: u32, left: Option<f32>) -> bool {
        let reset = playing && self.match_number != match_number;
        self.match_left = left;
        if reset {
            self.brain = fresh_brain(
                self.brain.ship,
                self.brain_config,
                self.flight_seed,
                match_number,
            );
            self.match_number = match_number;
            self.asked = None;
            self.sent = None;
            self.sent_at = 0;
        }
        self.playing = playing;
        reset
    }
}

/// What the roster last said about every seat in the room.
///
/// The arena broadcasts `S2C_ROSTER` to every client twice a second and this
/// process used to drop it on the floor, which is why a bot could not tell a
/// pilot on their first evening from one on their thousandth. Nothing here is
/// privileged: it is the same message every scoreboard in the room is drawn
/// from.
pub(crate) struct Standings([Option<ai::Standing>; sim::MAX_SHIPS]);

impl Default for Standings {
    fn default() -> Self {
        Standings(std::array::from_fn(|_| None))
    }
}

impl Standings {
    /// Read one roster message. Rows are twelve bytes and a name: ship, label,
    /// rating, games, team, kills, deaths, assists, and the name's length
    /// before it.
    ///
    /// It was nineteen. Points and bounty came off the row with the two
    /// numbers a kill used to pay.
    ///
    /// Built fresh rather than merged, so a seat that has left the room takes
    /// its row with it instead of haunting the table.
    pub(crate) fn read(&mut self, m: &[u8]) {
        let mut next: [Option<ai::Standing>; sim::MAX_SHIPS] = std::array::from_fn(|_| None);
        let Some(&n) = m.get(1) else { return };
        let mut o = 2usize;
        for _ in 0..n {
            // A short read keeps the rows already parsed and abandons the
            // rest, which is what the client does with the same message.
            let Some(&len) = m.get(o + 12) else { break };
            if m.len() < o + 13 + len as usize {
                break;
            }
            let ship = m[o] as usize;
            let label = m[o + 1];
            if ship < sim::MAX_SHIPS {
                next[ship] = Some(ai::Standing {
                    rating: i16::from_le_bytes([m[o + 2], m[o + 3]]),
                    games: m[o + 4],
                    bot: label == 2 || label == 3,
                });
            }
            o += 13 + len as usize;
        }
        self.0 = next;
    }

    pub(crate) fn of(&self, ship: u8) -> Option<ai::Standing> {
        self.0.get(ship as usize).copied().flatten()
    }

    /// The best rating among the people in the room, or `None` where every
    /// seat is a machine. This is what the director matches an opponent
    /// against. A duel room holds one person; where a bigger one holds several
    /// the strongest is who an opponent has to be worth fighting.
    pub(crate) fn rival(&self) -> Option<i16> {
        self.0
            .iter()
            .flatten()
            .filter(|standing| !standing.bot)
            .map(|standing| standing.rating)
            .max()
    }

    /// Hang the roster on a look, which is otherwise entirely the
    /// simulation's account of the room.
    fn apply(&self, ship: u8, own: &mut ai::Own, seen: Option<&mut ai::Scan>) {
        own.standing = self.of(ship);
        if let Some(seen) = seen {
            for f in seen.contacts.iter_mut() {
                f.standing = self.of(f.ship);
            }
            if let Some(f) = seen.foe.as_mut() {
                f.standing = self.of(f.ship);
            }
        }
    }
}

struct Rig {
    world: Mutex<sim::World>,
    /// The last buttons each seat produced, read when the driver steps.
    /// Meaningful only while `crew` holds a pilot in that seat.
    buttons: [AtomicU16; sim::MAX_SHIPS],
    /// Everybody flying this arena room, by seat. The rig key includes the
    /// room sent in `S2C_WELCOME`, so a collision here is an unexpected
    /// duplicate seat rather than another room reusing the same ship index.
    crew: Mutex<HashMap<u8, Seat>>,
    /// The connection feeding snapshots into the shared world, zero while
    /// the role is open. Taken by compare-and-swap when a snapshot arrives,
    /// released on the way out, so losing the feeder costs the rig a
    /// snapshot of staleness at most.
    pen: AtomicU64,
    /// Progress and ownership of the shared driver. The supervisor watches the
    /// first and changes the second before replacing a stopped task. A late
    /// task sees that its generation is stale and leaves without starting a
    /// second clock beside the replacement.
    driver_beat: AtomicU64,
    driver_generation: AtomicU64,
    /// One roster for the whole crew, since they share a room and are sent
    /// the same message. Written by whichever connections happen to be
    /// reading, which is all of them: the bytes are identical, so there is
    /// nothing to arbitrate and no owner to lose.
    standings: Mutex<Standings>,
}

impl Rig {
    fn new(world: sim::World) -> Self {
        Rig {
            world: Mutex::new(world),
            buttons: std::array::from_fn(|_| AtomicU16::new(0)),
            crew: Mutex::new(HashMap::new()),
            pen: AtomicU64::new(0),
            standings: Mutex::new(Standings::default()),
            driver_beat: AtomicU64::new(0),
            driver_generation: AtomicU64::new(1),
        }
    }

    /// A driver panic must not turn its two locks into permanent damage. The
    /// supervisor can replace the task, and these accessors let that replacement
    /// take back the state the old task left behind.
    fn lock_world(&self) -> std::sync::MutexGuard<'_, sim::World> {
        self.world.lock().unwrap_or_else(|poisoned| {
            self.world.clear_poison();
            poisoned.into_inner()
        })
    }

    fn lock_crew(&self) -> std::sync::MutexGuard<'_, HashMap<u8, Seat>> {
        self.crew.lock().unwrap_or_else(|poisoned| {
            self.crew.clear_poison();
            poisoned.into_inner()
        })
    }

    /// Take a seat, or refuse it because a live pilot already has it.
    fn claim(&self, ship: u8, seat: Seat) -> Result<(), Box<Seat>> {
        if ship as usize >= sim::MAX_SHIPS {
            return Err(Box::new(seat));
        }
        let mut c = self.lock_crew();
        if let Some(held) = c.get(&ship) {
            if held.id != seat.id {
                return Err(Box::new(seat));
            }
        }
        self.buttons[ship as usize].store(0, Ordering::Relaxed);
        c.insert(ship, seat);
        Ok(())
    }

    /// Lift this pilot's seat out and hand it back, brain and all.
    ///
    /// `release` drops it, which is right when a flight is over and wrong when
    /// it is only moving house: a map change keys a new rig, and a pilot that
    /// arrives at one with no brain in its seat has nothing to fly with.
    fn take(&self, ship: u8, id: u64) -> Option<Seat> {
        let mut c = self.lock_crew();
        let seat = match c.get(&ship) {
            Some(held) if held.id == id => {
                self.buttons[ship as usize].store(0, Ordering::Relaxed);
                c.remove(&ship)
            }
            _ => None,
        };
        let _ = self
            .pen
            .compare_exchange(id, 0, Ordering::Relaxed, Ordering::Relaxed);
        seat
    }

    /// Give back whatever this pilot held: its seat if it had one, the pen if
    /// it was writing. Safe to call however the flight ended.
    fn release(&self, ship: u8, id: u64) {
        let mut c = self.lock_crew();
        if c.get(&ship).is_some_and(|s| s.id == id) {
            c.remove(&ship);
            self.buttons[ship as usize].store(0, Ordering::Relaxed);
        }
        let _ = self
            .pen
            .compare_exchange(id, 0, Ordering::Relaxed, Ordering::Relaxed);
    }

    /// Pause or start one seated controller from its own socket's match
    /// packet. Taking the crew lock makes the transition atomic with respect
    /// to the shared driver: once this returns, the old brain cannot think
    /// again.
    fn set_match(&self, ship: u8, id: u64, playing: bool, match_number: u32, left: Option<f32>) {
        let mut crew = self.lock_crew();
        let Some(seat) = crew.get_mut(&ship).filter(|seat| seat.id == id) else {
            return;
        };
        let reset = seat.set_match(playing, match_number, left);
        if !playing || reset {
            self.buttons[ship as usize].store(0, Ordering::Relaxed);
        }
    }

    /// One tick of shared prediction: every seated pilot's last buttons, one
    /// step. The driver calls this with both locks already held.
    fn advance(&self, w: &mut sim::World, crew: &HashMap<u8, Seat>) {
        let mut inputs = [sim::sim_input {
            ship: 0,
            buttons: 0,
        }; sim::MAX_SHIPS];
        let mut n = 0;
        for &ship in crew.keys() {
            inputs[n] = sim::sim_input {
                ship,
                buttons: self.buttons[ship as usize].load(Ordering::Relaxed),
            };
            n += 1;
        }
        w.step(&inputs[..n]);
    }
}

/// An unchanged control is still sent often enough to prove the bot is alive.
/// The arena holds the latest buttons between messages, so this does not alter
/// flight or require a separate protocol message.
fn input_frame_due(sent: Option<u16>, sent_at: u32, buttons: u16, tick: u32) -> bool {
    sent != Some(buttons) || tick.wrapping_sub(sent_at) >= INPUT_HEARTBEAT_TICKS
}

struct DriverWatch {
    beat: u64,
    moved: std::time::Instant,
}

impl DriverWatch {
    fn new(beat: u64, now: std::time::Instant) -> Self {
        DriverWatch { beat, moved: now }
    }

    fn stalled(&mut self, beat: u64, now: std::time::Instant) -> bool {
        if beat != self.beat {
            self.beat = beat;
            self.moved = now;
            return false;
        }
        now.duration_since(self.moved).as_millis() as u64 >= DRIVER_STALL_MS
    }
}

/// The rig's one clock. Fifty pilots used to carry a 100 Hz ticker each,
/// which was four thousand eight hundred scheduler wake-ups a second spent
/// mostly contending for the same world lock; the profile of the running
/// process was scheduler and locks, not flying. One task ticks the rig
/// instead: it advances the world once, runs every seated brain against the
/// same picture, and hands each pilot's input frame to its own connection to
/// send. The wire is untouched by any of this: every bot still joins,
/// receives and answers as its own client, per decision 29.
async fn drive(rig: std::sync::Weak<Rig>, generation: u64) {
    let mut ticker = tokio::time::interval(std::time::Duration::from_micros(10_000));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        ticker.tick().await;
        let Some(rig) = rig.upgrade() else { return };
        if rig.driver_generation.load(Ordering::SeqCst) != generation {
            return;
        }
        let mut crew = match rig.crew.try_lock() {
            Ok(crew) => crew,
            Err(std::sync::TryLockError::WouldBlock) => continue,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => {
                rig.crew.clear_poison();
                poisoned.into_inner()
            }
        };
        if crew.is_empty() {
            rig.driver_beat.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        // The look happens under the world lock so a scan and the step it
        // reads cannot interleave; the thinking happens after it is dropped,
        // because a route or a refuge search is not something to hold the
        // room's picture for.
        let mut views = Vec::with_capacity(crew.len());
        {
            let mut w = match rig.world.try_lock() {
                Ok(world) => world,
                Err(std::sync::TryLockError::WouldBlock) => continue,
                Err(std::sync::TryLockError::Poisoned(poisoned)) => {
                    rig.world.clear_poison();
                    poisoned.into_inner()
                }
            };
            rig.advance(&mut w, &crew);
            // Locked once for the whole crew rather than once per pilot: they
            // share a room, so they share a roster.
            let standings = rig.standings.lock();
            for (&ship, seat) in crew.iter_mut() {
                if !seat.playing {
                    continue;
                }
                let mut own = ai::own(&w, ship);
                own.match_left = seat.match_left;
                let mut fresh = seat.brain.looks_due().then(|| ai::scan(&w, ship));
                if let Ok(st) = standings.as_ref() {
                    st.apply(ship, &mut own, fresh.as_mut());
                }
                let crowd = seat.brain.wants_refuge().then(|| {
                    let mut c = ai::crowd(&w, ship);
                    c.extend_from_slice(seat.brain.avoid());
                    c
                });
                views.push((ship, own, fresh, w.state.tick, crowd));
            }
        }
        let mut gone: Vec<u8> = Vec::new();
        for (ship, own, fresh, tick, crowd) in views {
            let Some(seat) = crew.get_mut(&ship) else {
                continue;
            };
            if let Some(crowd) = crowd {
                seat.brain.refuge(
                    seat.route
                        .refuge((own.x, own.y), &crowd, ai::REFUGE_PX, true),
                );
            }
            // Asked to stand down. The endings and their names are unchanged
            // from when every pilot judged its own: they are not equally
            // good, and nothing else can tell them apart.
            if seat.yielding.load(Ordering::Relaxed) {
                seat.brain.stand_down();
                let since = *seat.asked.get_or_insert_with(std::time::Instant::now);
                let how = if !own.alive {
                    Some("died")
                } else if seat.brain.departed() {
                    Some("clear")
                } else if since.elapsed().as_millis() as u64 > DEPART_MAX_MS {
                    Some("gave up")
                } else {
                    None
                };
                if let Some(how) = how {
                    println!(
                        "{}: {} left ({how}, {:.1}s)",
                        seat.addr,
                        seat.name,
                        since.elapsed().as_secs_f32()
                    );
                    // The seat outlives a full channel: removal waits for the
                    // Leave to be accepted, so a pilot is never marooned with
                    // a mind already gone.
                    if seat.tx.try_send(Ctl::Leave).is_ok() {
                        gone.push(ship);
                    }
                    continue;
                }
            }
            let buttons = seat.brain.think(&own, &seat.route, fresh);
            rig.buttons[ship as usize].store(buttons, Ordering::Relaxed);
            if input_frame_due(seat.sent, seat.sent_at, buttons, tick) {
                // The tick this input produces, not the last one finished,
                // which is what `net.lua` stamps and what the arena's queue
                // reads: an input naming a tick waits for it.
                let m =
                    crate::input_message(seat.lifecycle, 0, 0, &[(tick.wrapping_add(1), buttons)]);
                if seat
                    .tx
                    .try_send(Ctl::Frame {
                        match_number: seat.match_number,
                        message: m,
                    })
                    .is_ok()
                {
                    seat.sent = Some(buttons);
                    seat.sent_at = tick;
                }
            }
        }
        for ship in gone {
            crew.remove(&ship);
            rig.buttons[ship as usize].store(0, Ordering::Relaxed);
        }
        rig.driver_beat.fetch_add(1, Ordering::Relaxed);
    }
}

/// Keep one driver behind a rig for as long as the rig exists. A completed or
/// panicked task is replaced immediately. A task that stops making progress is
/// replaced after five seconds, with its generation revoked first so it cannot
/// resume as a second clock for the room later.
async fn supervise_driver(rig: std::sync::Weak<Rig>) {
    let mut generation = 1u64;
    loop {
        let Some(live) = rig.upgrade() else { return };
        live.driver_generation.store(generation, Ordering::SeqCst);
        let mut watch = DriverWatch::new(
            live.driver_beat.load(Ordering::Relaxed),
            std::time::Instant::now(),
        );
        drop(live);

        let mut driver = tokio::spawn(drive(rig.clone(), generation));
        let mut ticker = tokio::time::interval(std::time::Duration::from_millis(DRIVER_WATCH_MS));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                result = &mut driver => {
                    if rig.upgrade().is_none() {
                        return;
                    }
                    println!("bot shared driver stopped ({result:?}); restarting");
                    break;
                }
                _ = ticker.tick() => {
                    let Some(live) = rig.upgrade() else {
                        driver.abort();
                        return;
                    };
                    let beat = live.driver_beat.load(Ordering::Relaxed);
                    if watch.stalled(beat, std::time::Instant::now()) {
                        println!("bot shared driver made no progress for {DRIVER_STALL_MS} ms; restarting");
                        break;
                    }
                }
            }
        }
        crate::metrics::BOT_DRIVER_RESTARTS.inc();
        generation = generation.wrapping_add(1).max(1);
        if let Some(live) = rig.upgrade() {
            live.driver_generation.store(generation, Ordering::SeqCst);
        }
        driver.abort();
    }
}

/// The rigs, one per arena room and map. Weak, so a rig lives exactly as long
/// as some pilot holds it and a map change simply keys a new one.
#[derive(Default)]
struct Rigs(Mutex<HashMap<(String, u16, u64), std::sync::Weak<Rig>>>);

impl Rigs {
    fn get(&self, addr: &str, room: u16, key: u64, map: &Arc<sim::sim_map>) -> Option<Arc<Rig>> {
        let mut g = self.0.lock().ok()?;
        let rig_key = (addr.to_string(), room, key);
        if let Some(rig) = g.get(&rig_key).and_then(|w| w.upgrade()) {
            return Some(rig);
        }
        g.retain(|_, w| w.strong_count() > 0);
        let rig = Arc::new(Rig::new(sim::World::on_shared_map(
            key as u32,
            Arc::clone(map),
        )));
        tokio::spawn(supervise_driver(Arc::downgrade(&rig)));
        g.insert(rig_key, Arc::downgrade(&rig));
        Some(rig)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FlightEnd {
    Departed,
    Yielded,
    RatedBusy,
    Refused,
    AuthFailed,
    DialFailed,
    Protocol,
    SnapshotStalled,
    DriverStopped,
    Closed { welcomed: bool },
    Panicked,
}

impl FlightEnd {
    fn needs_backoff(self) -> bool {
        matches!(
            self,
            FlightEnd::AuthFailed
                | FlightEnd::DialFailed
                | FlightEnd::Refused
                | FlightEnd::Protocol
                | FlightEnd::SnapshotStalled
                | FlightEnd::DriverStopped
                | FlightEnd::Closed { welcomed: false }
                | FlightEnd::Panicked
        )
    }
}

fn protocol_error() -> FlightEnd {
    crate::metrics::BOT_PROTOCOL_ERRORS.inc();
    FlightEnd::Protocol
}

fn snapshot_stalled() -> FlightEnd {
    crate::metrics::BOT_SNAPSHOT_STALLS.inc();
    FlightEnd::SnapshotStalled
}

fn retry_delay_ms(failures: u32, addr: &str) -> u64 {
    let shift = failures.saturating_sub(1).min(6);
    let base = 1_000u64.saturating_mul(1u64 << shift).min(RETRY_MAX_MS);
    base.saturating_add(fingerprint(addr.as_bytes()) % 1_000)
        .min(RETRY_MAX_MS)
}

/// One bot the supervisor is holding open.
struct Live {
    id: pilots::PilotId,
    name: String,
    room: u32,
    born_ms: u64,
    /// Set when this bot has been asked to stand down. It leaves at the next
    /// good moment rather than at once, per the graceful rules in
    /// docs/design/ai-players.md.
    yielding: Arc<AtomicBool>,
    /// Set where this pilot is leaving so the room can be dealt a different
    /// one, rather than because a person took the seat. The seat is still
    /// wanted, so the room does not read short until this pilot has actually
    /// gone, and the churn guard, which is about people arriving and leaving,
    /// stays out of it.
    swapping: bool,
    /// Where it sits on the provisional strength order, so the director can
    /// tell whether it still suits the room.
    prior: f32,
    seen: Arc<Seen>,
    task: tokio::task::JoinHandle<FlightEnd>,
}

const RATED_BUSY_BACKOFF_MS: u64 = 180_000;

/// One roster individual's credential, kept for the life of the process.
///
/// It used to carry a shopping flag too, because a completed flight earned an
/// individual the right to buy one rung. There is nothing to buy: what a bot
/// flies is the hull it was written into.
struct Account {
    secret: String,
}

#[derive(Default)]
struct Accounts(Mutex<HashMap<String, Account>>);

impl Accounts {
    fn secret(&self, who: &str) -> Option<String> {
        self.0.lock().ok()?.get(who).map(|a| a.secret.clone())
    }

    fn remember(&self, who: &str, secret: String) {
        if let Ok(mut accounts) = self.0.lock() {
            accounts
                .entry(who.to_string())
                .or_insert(Account { secret });
        }
    }
}

/// Nobody in the room to be matched against. A rating is signed and every
/// value of one is real, so the sentinel sits outside the type.
const NO_RIVAL: i32 = i32::MIN;

/// What a flying pilot has seen of the room it is in, read by the director
/// that dealt it there.
///
/// A connection inside a room is the only thing in this process that can see
/// one, so the population's questions about who is in there are answered from
/// the seat rather than over a wire. The arena publishes its bot requests to
/// anybody who asks, and a room's occupant is not the sort of thing that
/// belongs on a public status.
#[derive(Debug)]
struct Seen {
    rival: AtomicI32,
    matches: AtomicU32,
}

impl Default for Seen {
    fn default() -> Self {
        Seen {
            rival: AtomicI32::new(NO_RIVAL),
            matches: AtomicU32::new(0),
        }
    }
}

impl Seen {
    fn note_room(&self, standings: &Standings) {
        self.rival.store(
            standings.rival().map_or(NO_RIVAL, i32::from),
            Ordering::Relaxed,
        );
    }

    /// A match opening, which is how this pilot counts how long it has been
    /// the same person's opponent.
    fn note_match(&self) {
        self.matches.fetch_add(1, Ordering::Relaxed);
    }

    fn rival(&self) -> Option<i16> {
        match self.rival.load(Ordering::Relaxed) {
            NO_RIVAL => None,
            rating => Some(rating as i16),
        }
    }

    fn matches(&self) -> u32 {
        self.matches.load(Ordering::Relaxed)
    }
}

/// What a rival of each tier is worth flying against, as a window on
/// `PilotSpec::ordering_prior`.
///
/// Wide and overlapping. A band is where to look for an opponent rather than a
/// bracket to sort people into, and neighboring bands share ground so a pilot
/// sitting near a boundary meets both sides of it.
///
/// This is a designed table and not a measurement. `ordering_prior` is
/// deliberately not a rating, the generated pool has no calibrated one, and
/// nothing checked in could derive these numbers. What holds it honest is that
/// the rows are the tiers in `rating.rs`, and `every_tier_names_a_band` fails
/// if the two lists ever stop matching.
const RIVAL_BANDS: [(&str, f32, f32); 5] = [
    ("Newb", 0.02, 0.35),
    ("Wing", 0.20, 0.50),
    ("Lead", 0.35, 0.65),
    ("Ace", 0.50, 0.80),
    ("Legend", 0.65, 0.95),
];

/// Where a room with nobody to measure against looks, which is also where an
/// unrated pilot's own rating sits.
const MIDDLE_BAND: (f32, f32) = (RIVAL_BANDS[2].1, RIVAL_BANDS[2].2);

fn band_for(rating: i16) -> (f32, f32) {
    let tier = crate::rating::tier(f64::from(rating));
    RIVAL_BANDS
        .iter()
        .find(|(named, _, _)| *named == tier)
        .map_or(MIDDLE_BAND, |(_, low, high)| (*low, *high))
}

/// Matches a pilot flies against the same person before the room is dealt
/// somebody else.
///
/// Three, because the rating layer discounts a repeated kill on a `1/(1+n)`
/// curve and by the fourth the ending card has stopped moving with the play.
/// The fight is still a fight past here; the measurement is not.
const RIVAL_MATCHES: u32 = 3;

/// How many pilots a room remembers, so the one it is dealt next is not the
/// one it just had back again.
const RIVAL_MEMORY: usize = 4;

/// Whether a room should be dealt somebody else.
///
/// Two reasons and one guard. A pilot is replaced once it has been the same
/// person's opponent for `RIVAL_MATCHES`, and at once where it never suited
/// them, since fill answers a count and cannot know who it is sending anybody
/// against. The guard is that neither reason counts before a match has been
/// played, which holds this to one swap a match however wrong the pilot is.
///
/// A room with nobody in it wants nothing. Bots fighting bots are the zone
/// keeping itself warm, and there is no one in there to be matched to.
fn wants_replacing(played: u32, prior: f32, rival: Option<i16>) -> bool {
    let Some(rival) = rival else { return false };
    if played == 0 {
        return false;
    }
    let (low, high) = band_for(rival);
    played >= RIVAL_MATCHES || prior < low || prior > high
}

/// What a room has lately been dealt, and what it wants next.
#[derive(Default)]
struct RoomMemory {
    band: Option<(f32, f32)>,
    recent: VecDeque<pilots::PilotId>,
}

/// What the supervisor knows about one arena.
#[derive(Default)]
struct Instance {
    bots: Vec<Live>,
    /// When this instance last let a bot go, so it does not immediately take
    /// another one back.
    released_ms: u64,
    /// Consecutive cycles it has failed to answer. See `GONE_AFTER`.
    misses: u32,
    /// Connection failures hold refill here rather than sending eight new
    /// clients into the same outage every second.
    retry_after_ms: u64,
    failures: u32,
    /// Per room, so a replacement suits the room rather than the instance. It
    /// outlives the pilot it was learned from, which is the point: the pilot
    /// that saw the room is usually the one being replaced.
    rooms: HashMap<u32, RoomMemory>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct Assignment {
    room: u32,
}

impl Live {
    fn assignment(&self) -> Assignment {
        Assignment { room: self.room }
    }

    /// Whether this pilot's seat has stopped filling the room's request. A
    /// pilot standing down for a person has; one leaving to be replaced has
    /// not, right up until it is gone.
    fn departing(&self) -> bool {
        self.yielding.load(Ordering::Relaxed) && !self.swapping
    }
}

#[derive(Clone, Debug, Default)]
struct ArenaWant {
    scalar: u32,
    requests: Option<Vec<crate::fleet::BotRequest>>,
}

impl ArenaWant {
    fn new(scalar: u32, requests: Option<Vec<crate::fleet::BotRequest>>) -> Self {
        Self { scalar, requests }
    }

    fn assignments(&self) -> Vec<Assignment> {
        let Some(requests) = &self.requests else {
            return (0..self.scalar).map(|_| Assignment { room: 0 }).collect();
        };
        let mut requests = requests.clone();
        requests.sort_by_key(|request| request.room);
        requests
            .into_iter()
            .filter(|request| (1..=crate::MAX_ROOM_NUMBER).contains(&request.room))
            .flat_map(|request| (0..request.count).map(move |_| Assignment { room: request.room }))
            .collect()
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Reconciliation {
    surplus: Vec<usize>,
    missing: Vec<Assignment>,
}

/// Match the live population to the final room-scoped population an arena
/// requested. The flag beside each assignment is whether that pilot has
/// stopped filling it: a bot standing down for a person has, and one leaving
/// so the room can be dealt a different rival has not, because its seat is
/// still wanted and refilling it twice would send two pilots at one chair.
fn reconcile_assignments(current: &[(Assignment, bool)], desired: &[Assignment]) -> Reconciliation {
    let mut remaining = desired.to_vec();
    let mut kept = vec![false; current.len()];
    for (index, (assignment, departing)) in current.iter().enumerate() {
        if *departing {
            continue;
        }
        if let Some(at) = remaining.iter().position(|wanted| wanted == assignment) {
            remaining.remove(at);
            kept[index] = true;
        }
    }

    let mut plan = Reconciliation {
        missing: remaining,
        ..Reconciliation::default()
    };
    for (index, (_, departing)) in current.iter().enumerate() {
        if *departing || kept[index] {
            continue;
        }
        plan.surplus.push(index);
    }
    plan
}

fn merge_want(want: &mut HashMap<String, ArenaWant>, addr: String, incoming: ArenaWant) {
    match want.get_mut(&addr) {
        Some(current)
            if incoming.requests.is_some()
                && (current.requests.is_none()
                    || incoming.assignments().len() >= current.assignments().len()) =>
        {
            *current = incoming;
        }
        Some(current)
            if incoming.requests.is_none()
                && current.requests.is_none()
                && incoming.scalar > current.scalar =>
        {
            *current = incoming;
        }
        None => {
            want.insert(addr, incoming);
        }
        _ => {}
    }
}

pub async fn run() {
    // The one process in the fleet nothing could ask about, which is why it
    // was the one nobody could account for when the host pegged.
    crate::metrics::spawn("bots", "");
    let maps: Arc<Maps> = Arc::default();
    let rigs: Arc<Rigs> = Arc::default();
    // Stable pilot identities in use by this supervisor. The meta-layer's
    // rated lease arbitrates the same career between different hosts.
    let taken: Arc<Mutex<HashSet<pilots::PilotId>>> = Arc::default();
    let blocked: Arc<Mutex<HashMap<String, u64>>> = Arc::default();
    // Account state stays with the supervisor, so a reconnect keeps its secret
    // and cannot turn one failed flight into a stack of purchases.
    let accounts: Arc<Accounts> = Arc::default();
    let mut fleet: HashMap<String, Instance> = HashMap::new();

    let dirs = crate::directory_urls().await;
    let direct: Vec<String> = std::env::var("VW_ARENAS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if dirs.is_empty() && direct.is_empty() {
        println!("no directory (VW_DIRECTORY) and no arenas (VW_ARENAS); nothing to fly");
        return;
    }
    if !direct.is_empty() {
        println!(
            "flying at {} arena(s) directly: {}",
            direct.len(),
            direct.join(", ")
        );
    }

    let mut ticker = tokio::time::interval(std::time::Duration::from_millis(POLL_MS));
    loop {
        ticker.tick().await;
        let now = crate::fleet::now_ms();

        // Anything that has gone: a refused join, a yield, an arena that
        // restarted. Its identity goes back in the pool.
        for (addr, inst) in fleet.iter_mut() {
            let mut at = 0;
            while at < inst.bots.len() {
                if !inst.bots[at].task.is_finished() {
                    at += 1;
                    continue;
                }
                let live = inst.bots.remove(at);
                let outcome = live.task.await.unwrap_or(FlightEnd::Panicked);
                if let Ok(mut t) = taken.lock() {
                    t.remove(&live.id);
                }
                if outcome == FlightEnd::RatedBusy {
                    if let Ok(mut blocked) = blocked.lock() {
                        blocked
                            .insert(live.name.clone(), now.saturating_add(RATED_BUSY_BACKOFF_MS));
                    }
                }
                if outcome.needs_backoff() {
                    inst.failures = inst.failures.saturating_add(1);
                    let delay = retry_delay_ms(inst.failures, addr);
                    inst.retry_after_ms = inst.retry_after_ms.max(now.saturating_add(delay));
                    crate::metrics::BOT_RETRY_BACKOFFS.inc();
                    println!(
                        "{addr}: {} ended {outcome:?}; refill waits {:.1}s",
                        live.name,
                        delay as f32 / 1_000.0
                    );
                } else {
                    inst.failures = 0;
                    inst.retry_after_ms = 0;
                }
            }
        }

        // Asked all at once rather than one after another, which is not a
        // throughput question: a single unreachable address would otherwise
        // stall the whole loop for its dial timeout, so one arena restarting
        // stops the population being tended anywhere. Measured before it was
        // fixed: two dead addresses in the list turned a one second cycle into
        // a ten second one.
        let mut want: HashMap<String, ArenaWant> = HashMap::new();
        let asked = futures_util::future::join_all(dirs.iter().map(|u| browse(u))).await;
        for (addr, wanted, _) in asked.into_iter().flatten() {
            merge_want(&mut want, addr, wanted);
        }
        let asked = futures_util::future::join_all(
            direct
                .iter()
                .map(|a| async move { (a.clone(), ask(a).await) }),
        )
        .await;
        for (addr, status) in asked {
            if let Some((wanted, _)) = status {
                want.insert(addr, wanted);
            }
        }

        // An arena that has dropped off the list wants nothing, and its bots are
        // told so rather than left flying at a game nobody can see. But not on
        // the first miss: a browse that times out or an arena that is a moment
        // slow to answer would otherwise read as "wants zero bots", empty a room
        // of fifty-one, and then refill it a cooldown later. A room's population
        // must not depend on every status query succeeding.
        for (addr, inst) in fleet.iter_mut() {
            if want.contains_key(addr) {
                inst.misses = 0;
            } else {
                inst.misses += 1;
                if inst.misses >= GONE_AFTER {
                    want.insert(addr.clone(), ArenaWant::default());
                }
            }
        }

        for (addr, wanted) in want {
            let inst = fleet.entry(addr.clone()).or_default();
            let have = inst.bots.len();
            let desired = wanted.assignments();
            let current: Vec<(Assignment, bool)> = inst
                .bots
                .iter()
                .map(|bot| (bot.assignment(), bot.departing()))
                .collect();
            let plan = reconcile_assignments(&current, &desired);

            // A room the arena has stopped running takes its memory with it.
            let live: HashSet<u32> = desired
                .iter()
                .map(|assignment| assignment.room)
                .chain(inst.bots.iter().map(|bot| bot.room))
                .collect();
            inst.rooms.retain(|room, _| live.contains(room));

            // What each room looks like from inside it, which only a pilot
            // sitting in one can say. Kept on the instance rather than on the
            // pilot, because the pilot that saw it is usually the one about to
            // be replaced.
            for bot in inst.bots.iter() {
                if let Some(rival) = bot.seen.rival() {
                    inst.rooms.entry(bot.room).or_default().band = Some(band_for(rival));
                }
            }

            // Deal the room somebody else. A pilot is replaced once it has
            // been the same person's opponent for long enough, or where it
            // never suited them: fill answers a count and cannot know who it
            // is sending anybody against, so the first pilot into a room is
            // dealt blind and this is where that is put right.
            //
            // Only ever at a match boundary, which bounds this to one swap a
            // match however wrong the pilot is. The departure itself is the
            // one a yielding bot already takes, at the next intermission, so
            // the seat changes hands under a podium: per decision 141 a seat
            // changing hands mid-match starts the match over.
            for bot in inst.bots.iter_mut() {
                if bot.yielding.load(Ordering::Relaxed) {
                    continue;
                }
                let played = bot.seen.matches();
                if !wants_replacing(played, bot.prior, bot.seen.rival()) {
                    continue;
                }
                bot.swapping = true;
                bot.yielding.store(true, Ordering::Relaxed);
                println!(
                    "{addr}: {} leaves room {} after {played} match(es), for another rival",
                    bot.name, bot.room
                );
            }

            // Ordinary fill still leaves one pilot at a time and observes the
            // minimum lifetime. Room-scoped requests choose which room loses
            // the seat instead of treating the instance as one bucket.
            for index in plan.surplus {
                let bot = &inst.bots[index];
                if now.saturating_sub(bot.born_ms) < MIN_LIFE_MS {
                    continue;
                }
                bot.yielding.store(true, Ordering::Relaxed);
                inst.released_ms = now;
                println!(
                    "{addr}: {have} bots, wants {}; {} stands down from room {}",
                    desired.len(),
                    bot.name,
                    bot.room
                );
                break;
            }

            if now < inst.retry_after_ms {
                continue;
            }
            if now.saturating_sub(inst.released_ms) < REFILL_COOLDOWN_MS {
                continue;
            }
            let mut sent = 0;
            for assignment in plan.missing {
                if sent >= ADD_PER_CYCLE {
                    break;
                }
                let want = {
                    let memory = inst.rooms.entry(assignment.room).or_default();
                    Wanted {
                        band: memory.band,
                        recent: memory.recent.iter().copied().collect(),
                    }
                };
                let Some(who) = claim(&taken, &blocked, now, &want) else {
                    break;
                };
                let seen: Arc<Seen> = Arc::default();
                let yielding = Arc::new(AtomicBool::new(false));
                let prior = who.ordering_prior();
                let task = tokio::spawn(fly(
                    addr.clone(),
                    who.clone(),
                    assignment.room,
                    Arc::clone(&maps),
                    Arc::clone(&rigs),
                    Arc::clone(&yielding),
                    Arc::clone(&seen),
                    Arc::clone(&accounts),
                ));
                let memory = inst.rooms.entry(assignment.room).or_default();
                memory.recent.push_back(who.id);
                while memory.recent.len() > RIVAL_MEMORY {
                    memory.recent.pop_front();
                }
                inst.bots.push(Live {
                    id: who.id,
                    name: who.callsign,
                    room: assignment.room,
                    born_ms: now,
                    yielding,
                    swapping: false,
                    prior,
                    seen,
                    task,
                });
                sent += 1;
            }
            if sent > 0 {
                println!("{addr}: {have} bots, wants {}; sent {sent}", desired.len());
            }
        }
    }
}

/// A room draws from the authored roster and then a large generated
/// population.
const PILOT_POOL: usize = pilots::HOUSE_PILOT_POOL;
/// How far a banded search reads into the generated pool before it settles for
/// anybody free. The pool is 65,536 and a band covers a good share of it, so
/// this bounds the arithmetic rather than the choice.
const BAND_SEARCH: usize = 1_024;

/// What a room wants of the next pilot dealt into it. Empty is what fill has
/// always asked for: anybody free.
#[derive(Clone, Debug, Default)]
struct Wanted {
    /// The window on `ordering_prior` the room's rival asks for, or none where
    /// nobody in there has to be matched.
    band: Option<(f32, f32)>,
    /// Pilots this room has had lately.
    recent: Vec<pilots::PilotId>,
}

impl Wanted {
    fn suits(&self, spec: &pilots::PilotSpec) -> bool {
        if self.recent.contains(&spec.id) {
            return false;
        }
        match self.band {
            None => true,
            Some((low, high)) => (low..=high).contains(&spec.ordering_prior()),
        }
    }
}

fn claim(
    taken: &Arc<Mutex<HashSet<pilots::PilotId>>>,
    blocked: &Arc<Mutex<HashMap<String, u64>>>,
    now: u64,
    want: &Wanted,
) -> Option<pilots::PilotSpec> {
    let mut t = taken.lock().ok()?;
    let mut blocked = blocked.lock().ok()?;
    blocked.retain(|_, until| *until > now);
    let mut take = |e: pilots::PilotSpec| {
        debug_assert_eq!(e.version, pilots::PILOT_SPEC_VERSION);
        if blocked.contains_key(&e.callsign) {
            return None;
        }
        if t.insert(e.id) {
            Some(e)
        } else {
            None
        }
    };

    // The authored roster first and in order, which is what this was before
    // any of it was banded. It is also what keeps the pinned anchor in the
    // air: it holds the whole ladder's scale and does that by fighting rather
    // than by being written down.
    let authored = pilots::AUTHORED_PILOT_COUNT;
    if let Some(spec) = (0..authored)
        .map(pilots::individual)
        .filter(|spec| want.suits(spec))
        .find_map(&mut take)
    {
        return Some(spec);
    }

    // Then the generated pool, entered somewhere random in it. This used to be
    // one walk from zero, so a room that lost a pilot was handed back the
    // lowest free index every time, which in a duel zone is one opponent all
    // night.
    let span = PILOT_POOL - authored;
    let from = rand::random::<usize>() % span;
    if let Some(spec) = (0..BAND_SEARCH.min(span))
        .map(|step| pilots::individual(authored + (from + step) % span))
        .filter(|spec| want.suits(spec))
        .find_map(&mut take)
    {
        return Some(spec);
    }

    // And anybody at all. An empty seat is worse than a mismatched opponent,
    // so a band is a preference the search gives up on rather than a filter.
    (0..PILOT_POOL).map(pilots::individual).find_map(&mut take)
}

/// Ask a directory what is running, and how many bots each instance wants.
async fn browse(url: &str) -> Vec<(String, ArenaWant, String)> {
    let Some(body) =
        directory::request(url, directory::STATUS_REQUEST, directory::STATUS_REPLY).await
    else {
        return Vec::new();
    };
    let Ok(b) = serde_json::from_str::<directory::Browse>(&body) else {
        return Vec::new();
    };
    b.zones
        .iter()
        .flat_map(|z| {
            z.instances.iter().map(|i| {
                (
                    i.address.clone(),
                    ArenaWant::new(i.bots_wanted, i.bot_requests.clone()),
                    z.name.clone(),
                )
            })
        })
        .collect()
}

/// The same question straight to one arena, for a laptop running without a
/// directory. `C2S_STATUS` is answerable without joining, which is what makes
/// this the same request a directory's verification makes.
async fn ask(addr: &str) -> Option<(ArenaWant, String)> {
    let body = directory::request(addr, directory::STATUS_REQUEST, directory::STATUS_REPLY).await?;
    serde_json::from_str::<crate::fleet::Status>(&body)
        .ok()
        .map(|s| (ArenaWant::new(s.bots_wanted, s.bot_requests), s.zone))
}

/// One bot, from dial to disconnect.
///
/// The loop is the client's loop. Inputs go out when they change, because the
/// arena holds the last buttons it was sent and applies them every tick, so a
/// bot flying straight costs nothing on the wire. The world is stepped locally
/// at the simulation's own rate between snapshots, which is not an optimisation
/// but the only way the brain's timing survives the move out of the arena:
/// planning and look cadence are counted in 100 Hz ticks, and a brain fed a
/// 20 Hz picture would plan and steer from a clock five times too slow.
///
/// The world it steps is the arena's `Rig`, shared with every other pilot on
/// the same arena address, room, and map. Predicting each room once is the
/// difference between this process fitting on the host and not. Each connection
/// still looks ordinary from the arena's side; the sharing is entirely inside
/// this process.
/// How one roster individual may see the room. A house token earns the complete
/// snapshot that makes the shared rig sound. A deployment without accounts is
/// still allowed to fly bots, but each one must use its own filtered world.
#[derive(Debug, PartialEq, Eq)]
enum BotIdentity {
    /// A token, and nothing else. What a bot flies is the hull it was written
    /// with, and a hull is a whole ship: there is no kit to build and nothing
    /// an account could own that would change what leaves the barrel.
    House {
        token: String,
    },
    Unaccounted,
}

impl BotIdentity {
    fn session(&self) -> &str {
        match self {
            BotIdentity::House { token } => token,
            BotIdentity::Unaccounted => "",
        }
    }

    fn shares_world(&self) -> bool {
        matches!(self, BotIdentity::House { .. })
    }
}

/// The identity for one roster individual, claiming its account the first time
/// and logging in whenever a token is wanted.
///
/// An individual is one account and one career, per docs/design/ai-players.md,
/// so the account is claimed by name and the meta-layer hands back the same one
/// however many times this process restarts. The secret is kept in memory for
/// the life of the process, which is what stops a restart loop minting a
/// credential row per attempt.
async fn bot_identity(who: &pilots::PilotSpec, accounts: &Accounts) -> Result<BotIdentity, String> {
    let name = who.callsign.as_str();
    let meta = std::env::var("VW_META").unwrap_or_default();
    let pool = std::env::var("VW_TOKEN").unwrap_or_default();
    if meta.is_empty() || pool.is_empty() {
        // A deployment without accounts. The bot still flies, declared and
        // labeled as somebody's bot, and rates nothing.
        return Ok(BotIdentity::Unaccounted);
    }
    // Read and release before any await: this is a plain mutex, and a guard
    // held across a network call is a deadlock waiting for a slow reply.
    let held = accounts.secret(name);
    let secret = match held {
        Some(s) => s,
        None => {
            let body = serde_json::json!({ "pool_token": pool, "name": name }).to_string();
            let reply = crate::meta::call(&meta, "/v1/bot", &body)
                .await
                .map_err(|e| format!("no account for {name}: {e}"))?;
            let s = reply
                .get("secret")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| format!("no account for {name}: response had no secret"))?
                .to_string();
            accounts.remember(name, s.clone());
            s
        }
    };
    // `/v1/session` and not `/v1/login`: session is secret-in-token-out,
    // login is name-and-password. A bot account never holds a password, so
    // asking login was answered 403 for every bot in the fleet, each one then
    // joined tokenless, and no death a bot was part of could file. The pilot
    // log kept flowing, which is what made the ladder's silence look like a
    // rating bug instead of this.
    let session = |secret: String| {
        let meta = meta.clone();
        async move {
            let body = serde_json::json!({ "secret": secret }).to_string();
            crate::meta::call(&meta, "/v1/session", &body)
                .await
                .map_err(|e| format!("{name} cannot begin a session: {e}"))
        }
    };
    let reply = session(secret.clone()).await?;

    // What carries an individual's history is its rating and nothing else.
    // The hull and the skill are written down, and the ship is the hull.
    let token = reply
        .get("token")
        .and_then(|v| v.as_str())
        .filter(|token| !token.is_empty())
        .ok_or_else(|| format!("{name} cannot begin a session: response had no token"))?
        .to_string();
    Ok(BotIdentity::House { token })
}

/// The join a bot sends, built where something can check it.
///
/// It was written inline and it went stale: the header grew a room byte, this
/// did not, and every bot in the fleet arrived nameless. Out here it is one
/// expression a test can call, which is the whole reason it moved.
///
/// A structured fleet request names the room that asked for this pilot. Zero
/// keeps the older scalar-fill behavior and lets the arena choose a room.
fn join_msg(class: u8, name: &str, session: &str, room: u32) -> Option<Vec<u8>> {
    let n = name.as_bytes();
    let mut join = vec![
        crate::C2S_JOIN,
        class.min((sim::MAX_CLASSES - 1) as u8),
        crate::CLIENT_PROTOCOL,
        crate::JOIN_BOT,
        0,
        u8::try_from(n.len()).ok()?,
        u8::try_from(room).ok()?,
    ];
    debug_assert_eq!(join.len(), crate::C2S_JOIN_HEADER);
    join.extend_from_slice(n);
    join.extend_from_slice(session.as_bytes());
    Some(join)
}

/// The build a bot sends, in the shape `C2S_KIT` reads: the hull it was spent
/// on, how many slots carry anything, and a slot and a count for each.
///
/// Out here beside `join_msg` and for its reason: the message a bot sends is
/// the message a player's client sends, and one written inline is one that
/// goes stale the next time the wire moves.
fn kit_msg(class: u8, kit: &[u8; sim::SLOT_COUNT]) -> Vec<u8> {
    let mut spent: Vec<(u8, u8)> = Vec::new();
    for (slot, &n) in kit.iter().enumerate() {
        if n > 0 {
            spent.push((slot as u8, n));
        }
    }
    let mut msg = vec![
        crate::C2S_KIT,
        class.min((sim::MAX_CLASSES - 1) as u8),
        spent.len().min(u8::MAX as usize) as u8,
    ];
    for (slot, n) in spent.into_iter().take(u8::MAX as usize) {
        msg.push(slot);
        msg.push(n);
    }
    msg
}

fn welcome_room(message: &[u8]) -> Option<u16> {
    Some(u16::from_le_bytes(message.get(10..12)?.try_into().ok()?))
}

#[allow(clippy::too_many_arguments)]
async fn fly(
    addr: String,
    who: pilots::PilotSpec,
    room: u32,
    maps: Arc<Maps>,
    rigs: Arc<Rigs>,
    yielding: Arc<AtomicBool>,
    seen: Arc<Seen>,
    accounts: Arc<Accounts>,
) -> FlightEnd {
    let cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
        max_message_size: Some(2 * 1024 * 1024),
        max_frame_size: Some(2 * 1024 * 1024),
        ..Default::default()
    };
    let dial = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio_tungstenite::connect_async_with_config(&addr, Some(cfg), false),
    );
    let Ok(Ok((mut ws, _))) = dial.await else {
        crate::metrics::BOT_DIAL_FAILURES.inc();
        return FlightEnd::DialFailed;
    };
    // Counted after the dial succeeds, so this is arenas reached rather than
    // arenas attempted. A step in it with no deploy behind it is a roster
    // being rebuilt, which is the shape a restart has from in here.
    crate::metrics::BOT_CONNECTS.inc();
    let _flying = crate::metrics::PilotGuard::new();

    // Dial before shopping. An address that cannot take a connection is not a
    // session and must not move a pilot's career. Authentication still happens
    // before join, so a failed meta-layer never turns a house bot into an
    // unaccounted one with a filtered view.
    let identity = match bot_identity(&who, &accounts).await {
        Ok(identity) => identity,
        Err(e) => {
            crate::metrics::BOT_AUTH_RETRIES.inc();
            println!("bots: {e}; retrying");
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), ws.close(None)).await;
            return FlightEnd::AuthFailed;
        }
    };
    fly_socket(addr, who, room, maps, rigs, yielding, seen, identity, ws).await
}

#[allow(clippy::too_many_arguments)]
async fn fly_socket<S>(
    addr: String,
    who: pilots::PilotSpec,
    room: u32,
    maps: Arc<Maps>,
    rigs: Arc<Rigs>,
    yielding: Arc<AtomicBool>,
    seen: Arc<Seen>,
    identity: BotIdentity,
    ws: tokio_tungstenite::WebSocketStream<S>,
) -> FlightEnd
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send,
{
    let class = who.hull;
    let flight = MATCH_ID.fetch_add(1, Ordering::Relaxed);
    let match_seed = flight as u32 ^ (flight >> 32) as u32 ^ fingerprint(addr.as_bytes()) as u32;
    let share_world = identity.shares_world();
    let (mut sink, mut source) = ws.split();

    // A bot picks its zone the way a player who typed an address does: it takes
    // whatever the instance is running. It was sent here by a browse of that
    // very instance, and a wrong-zone refusal would only tell it what it already
    // knows -- that the arena changed game underneath the browse.
    // Ours, and able to prove it. A house bot flies on a bot account, which is
    // what lets one of them anchor the ladder and what tells a player which
    // bots are the fleet's own. Without a meta-layer it flies declared but
    // unaccounted, which reads as somebody else's bot, honestly enough. Its
    // filtered view cannot feed the shared rig, so it flies a private world.
    let Some(join) = join_msg(class, &who.callsign, identity.session(), room) else {
        return protocol_error();
    };
    if sink.send(Message::Binary(join)).await.is_err() {
        return FlightEnd::Closed { welcomed: false };
    }

    // How this pilot sees the room: the rig it shares with every other pilot
    // welcomed into the same arena room, or nothing yet. The actual room comes
    // from welcome, after the map, so initial rig binding waits for it.
    enum Sight {
        Dark,
        Shared(Arc<Rig>),
    }
    let me = PILOT_ID.fetch_add(1, Ordering::Relaxed);
    let mut sight = Sight::Dark;
    // Held back for welcome and the private fallback, after the map and the
    // settings have already gone by.
    let mut map: Option<Arc<sim::sim_map>> = None;
    let mut map_key: Option<u64> = None;
    let mut actual_room: Option<u16> = None;
    let mut cfg_bytes: Vec<u8> = Vec::new();
    let mut route: Option<Arc<nav::Nav>> = None;
    let mut ship: u8 = 0;
    let mut lifecycle: u32 = 1;
    // The mind flies in the rig's driver; what this task keeps is the
    // socket. Frames arrive here to be sent because the socket is this
    // task's and nobody else's, which is what keeps one client per bot on
    // the wire.
    let (ctl_tx, mut ctl_rx) = tokio::sync::mpsc::channel::<Ctl>(16);
    // A pilot the driver flies needs no clock of its own; one slow tick
    // watches for a connection that has gone quiet.
    let mut quiet = tokio::time::interval(std::time::Duration::from_secs(1));
    quiet.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut heard = std::time::Instant::now();
    let mut snapshot_at = std::time::Instant::now();
    let mut welcomed_at: Option<std::time::Instant> = None;
    let mut outcome = FlightEnd::Closed { welcomed: false };
    let mut match_playing = true;
    let mut match_left: Option<f32> = None;
    let mut match_number = 0u32;
    // Set at a seat collision; flown after this loop ends.
    let mut go_private: Option<(sim::World, ai::Bot)> = None;

    loop {
        if !match_playing && yielding.load(Ordering::Relaxed) {
            outcome = FlightEnd::Departed;
            break;
        }
        tokio::select! {
            biased;
            msg = source.next() => {
                let data = match msg {
                    Some(Ok(Message::Binary(data))) => data,
                    Some(Ok(Message::Ping(data))) => {
                        heard = std::time::Instant::now();
                        if sink.send(Message::Pong(data)).await.is_err() {
                            break;
                        }
                        continue;
                    }
                    Some(Ok(Message::Pong(_))) => {
                        heard = std::time::Instant::now();
                        continue;
                    }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    Some(Ok(_)) => continue,
                };
                heard = std::time::Instant::now();
                if data.is_empty() {
                    outcome = protocol_error();
                    break;
                }
                if data[0] == crate::S2C_MAP && data.len() == 1
                    || data[0] == crate::S2C_SETTINGS && data.len() < 5
                    || data[0] == crate::S2C_WELCOME && data.len() < 17
                    || data[0] == crate::S2C_SNAPSHOT && data.len() <= crate::SNAPSHOT_HEADER
                    || data[0] == crate::S2C_DENIED && data.len() < 2
                    || data[0] == crate::S2C_ROSTER && data.len() < 2
                    || data[0] == crate::S2C_MATCH && data.len() < 4
                {
                    outcome = protocol_error();
                    break;
                }
                if data[0] == crate::S2C_MAPNAME {
                    continue;
                }
                match data.first().copied() {
                    Some(crate::S2C_MAP) => {
                        let key = fingerprint(&data[1..]);
                        let Some((m, grid)) = maps.get(&data[1..]).await else {
                            outcome = protocol_error();
                            break;
                        };
                        route = Some(Arc::clone(&grid));
                        // A fresh map mid-flight keys a new rig, and the seat
                        // moves house rather than ending: it is lifted out of
                        // the old one with the brain still in it and set down
                        // in the new one.
                        //
                        // It used to be released, which drops it. The seat was
                        // only ever taken at welcome, so nothing put the pilot
                        // back in one: it sat at the controls of nothing until
                        // the supervisor noticed it doing nothing and replaced
                        // it, about a minute later. A match game changes map
                        // at every whistle, so that was the first minute of
                        // every three minute match with the bots parked.
                        let carried = match &sight {
                            Sight::Shared(rig) => rig.take(ship, me),
                            _ => None,
                        };
                        if share_world {
                            if let Some(room) = actual_room {
                                let Some(rig) = rigs.get(&addr, room, key, &m) else { break };
                                if let Some(mut seat) = carried {
                                    // The route it was flying was a list of points
                                    // on the old ground.
                                    seat.brain.remap();
                                    seat.route = Arc::clone(&grid);
                                    seat.sent = None;
                                    seat.sent_at = 0;
                                    if let Err(seat) = rig.claim(ship, seat) {
                                        let seat = *seat;
                                        let seed = match_seed;
                                        let mut world =
                                            sim::World::on_shared_map(seed, Arc::clone(&m));
                                        if !cfg_bytes.is_empty()
                                            && !world.apply_settings(&cfg_bytes)
                                        {
                                            outcome = protocol_error();
                                            break;
                                        }
                                        println!(
                                            "{addr}: seat {ship} is taken after a map change; \
                                             {} flies a private world",
                                            who.callsign
                                        );
                                        go_private = Some((world, seat.brain));
                                    }
                                }
                                sight = Sight::Shared(rig);
                            } else {
                                sight = Sight::Dark;
                            }
                        } else {
                            sight = Sight::Dark;
                        }
                        map_key = Some(key);
                        map = Some(m);
                        if go_private.is_some() {
                            break;
                        }
                    }
                    Some(crate::S2C_SETTINGS) => {
                        if map.is_none() {
                            outcome = protocol_error();
                            break;
                        }
                        cfg_bytes = data[5..].to_vec();
                        // Every pilot applies on arrival. The bytes are the
                        // zone's one answer, so on the shared rig this is the
                        // same settings written again, which is idempotent.
                        if let Sight::Shared(rig) = &sight {
                            if !rig.lock_world().apply_settings(&cfg_bytes) {
                                outcome = protocol_error();
                                break;
                            }
                        }
                    }
                    Some(crate::S2C_WELCOME) => {
                        if map.is_none() || map_key.is_none() || route.is_none() {
                            outcome = protocol_error();
                            break;
                        }
                        let Some(welcomed_room) = welcome_room(&data) else {
                            outcome = protocol_error();
                            break;
                        };
                        // A fresh welcome is a fresh life and may also move a
                        // connection. Remove its old seat before binding the
                        // authoritative room carried by this welcome.
                        if welcomed_at.is_some() {
                            if let Sight::Shared(rig) = &sight {
                                rig.release(ship, me);
                            }
                            sight = Sight::Dark;
                        }
                        actual_room = Some(welcomed_room);
                        if share_world {
                            let Some(m) = map.as_ref() else { break };
                            let Some(key) = map_key else { break };
                            let Some(rig) = rigs.get(&addr, welcomed_room, key, m) else { break };
                            if !cfg_bytes.is_empty() && !rig.lock_world().apply_settings(&cfg_bytes) {
                                outcome = protocol_error();
                                break;
                            }
                            sight = Sight::Shared(rig);
                        }
                        ship = data[1];
                        if ship as usize >= sim::MAX_SHIPS {
                            outcome = protocol_error();
                            break;
                        }
                        lifecycle = u32::from_le_bytes(data[2..6].try_into().unwrap());
                        welcomed_at.get_or_insert_with(std::time::Instant::now);
                        outcome = FlightEnd::Closed { welcomed: true };
                        // What this pilot is flying, sent the way a player's
                        // client sends it, because it is the same message: the
                        // arena fits a kit to the hull and the purse and deals
                        // the result, so this is an intent rather than a
                        // promise.
                        //
                        // Without it a bot flies whatever `sim_deal_kit` puts
                        // on the hull, which is that hull's own profile: every
                        // Wedge in the fleet carrying the same two rungs of
                        // shrapnel, and the only thing separating one
                        // bombardier from another being how it flew. The kit
                        // comes off the personality now, and no two pilots off
                        // one strategy build alike. See `pilots::kit` and
                        // decision 117.
                        //
                        // After the welcome rather than with the join, because
                        // the arena only takes a kit from a pilot in a seat: a
                        // watcher asking to spend credits is asking about a
                        // ship they are not in.
                        if sink
                            .send(Message::Binary(kit_msg(who.hull, &pilots::kit(&who))))
                            .await
                            .is_err()
                        {
                            break;
                        }
                        let brain_config = who.brain();
                        let b = fresh_brain(ship, brain_config, match_seed, match_number);
                        if !share_world {
                            let Some(m) = map.clone() else { break };
                            let mut w = sim::World::on_shared_map(
                                match_seed,
                                m,
                            );
                            if !cfg_bytes.is_empty() && !w.apply_settings(&cfg_bytes) {
                                outcome = protocol_error();
                                break;
                            }
                            go_private = Some((w, b));
                            break;
                        }
                        if let Sight::Shared(rig) = &sight {
                            let Some(r) = route.clone() else { break };
                            let seat = Seat {
                                id: me,
                                lifecycle,
                                name: who.callsign.clone(),
                                addr: addr.clone(),
                                brain: b,
                                brain_config,
                                flight_seed: match_seed,
                                match_number,
                                playing: match_playing,
                                match_left,
                                route: r,
                                yielding: Arc::clone(&yielding),
                                asked: None,
                                sent: None,
                                sent_at: 0,
                                tx: ctl_tx.clone(),
                            };
                            if let Err(seat) = rig.claim(ship, seat) {
                                let seat = *seat;
                                // Somebody live already answers to this ship
                                // in this room. Keep the new connection correct
                                // with a private world rather than merging seats.
                                let Some(m) = map.clone() else { break };
                                let seed = match_seed;
                                let mut w = sim::World::on_shared_map(seed, m);
                                if !cfg_bytes.is_empty() && !w.apply_settings(&cfg_bytes) {
                                    outcome = protocol_error();
                                    break;
                                }
                                println!("{addr}: seat {ship} is taken; {} flies a private world", who.callsign);
                                go_private = Some((w, seat.brain));
                                break;
                            }
                        }
                    }
                    Some(crate::S2C_SNAPSHOT) => {
                        if welcomed_at.is_none() {
                            outcome = protocol_error();
                            break;
                        }
                        snapshot_at = std::time::Instant::now();
                        if let Sight::Shared(rig) = &sight {
                            // One connection feeds the room; everybody
                            // else's copy of the same truth is dropped here,
                            // unread, which is most of what a snapshot used
                            // to cost this process.
                            let _ = rig.pen.compare_exchange(
                                0, me, Ordering::Relaxed, Ordering::Relaxed);
                            if rig.pen.load(Ordering::Relaxed) == me
                                && !rig
                                    .lock_world()
                                    .apply_snapshot(&data[crate::SNAPSHOT_HEADER..])
                            {
                                outcome = protocol_error();
                                break;
                            }
                        }
                    }
                    Some(crate::S2C_ROSTER) => {
                        if let Sight::Shared(rig) = &sight {
                            if let Ok(mut st) = rig.standings.lock() {
                                st.read(&data);
                                seen.note_room(&st);
                            }
                        }
                    }
                    Some(crate::S2C_MATCH) => {
                        let next = data[1] & crate::MATCH_PLAYING != 0;
                        if match_transition(&mut match_playing, &mut match_number, next) {
                            seen.note_match();
                        }
                        if let Sight::Shared(rig) = &sight {
                            rig.set_match(ship, me, match_playing, match_number, seconds_left(&data));
                        }
                        if !match_playing && yielding.load(Ordering::Relaxed) {
                            outcome = FlightEnd::Departed;
                            break;
                        }
                    }
                    Some(crate::S2C_YIELD) => {
                        outcome = FlightEnd::Yielded;
                        break;
                    }
                    Some(crate::S2C_DENIED) => {
                        if data.get(1) == Some(&crate::DENY_RATED_SESSION) {
                            outcome = FlightEnd::RatedBusy;
                        } else {
                            outcome = FlightEnd::Refused;
                        }
                        println!("{addr} refused {}: {}", who.callsign,
                                 String::from_utf8_lossy(&data[2.min(data.len())..]));
                        break;
                    }
                    _ => {}
                }
            }
            ctl = ctl_rx.recv() => {
                match ctl {
                    Some(Ctl::Frame { match_number: frame_match, message }) => {
                        // A frame queued before the whistle belongs to the old
                        // controller. Do not let it leak into intermission or
                        // the next match while the socket catches up.
                        if match_playing
                            && frame_match == match_number
                            && sink.send(Message::Binary(message)).await.is_err()
                        {
                            break;
                        }
                    }
                    Some(Ctl::Leave) => {
                        outcome = FlightEnd::Departed;
                        break;
                    }
                    None => {
                        outcome = FlightEnd::DriverStopped;
                        break;
                    }
                }
            }
            _ = quiet.tick() => {
                if heard.elapsed().as_millis() as u64 > QUIET_MS {
                    break;
                }
                if welcomed_at.is_some()
                    && snapshot_at.elapsed().as_millis() as u64 > SNAPSHOT_STALL_MS
                {
                    outcome = snapshot_stalled();
                    break;
                }
            }
        }
    }

    // An unexpected duplicate-seat pilot, flown the way every pilot used to
    // be: its own world, its own clock, its own hands. Correct rather than
    // merged with somebody else's seat.
    if let Some((mut w, mut b)) = go_private {
        let mut buttons: u16;
        let mut sent: Option<u16> = None;
        let mut sent_at = 0u32;
        // Its own copy, since a private world has no rig to share one with.
        let mut standings = Standings::default();
        let mut asked: Option<std::time::Instant> = None;
        let mut ticker = tokio::time::interval(std::time::Duration::from_micros(10_000));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            if !match_playing && yielding.load(Ordering::Relaxed) {
                outcome = FlightEnd::Departed;
                break;
            }
            tokio::select! {
                biased;
                msg = source.next() => {
                    let data = match msg {
                        Some(Ok(Message::Binary(data))) => data,
                        Some(Ok(Message::Ping(data))) => {
                            heard = std::time::Instant::now();
                            if sink.send(Message::Pong(data)).await.is_err() {
                                break;
                            }
                            continue;
                        }
                        Some(Ok(Message::Pong(_))) => {
                            heard = std::time::Instant::now();
                            continue;
                        }
                        Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                        Some(Ok(_)) => continue,
                    };
                    heard = std::time::Instant::now();
                    if data.is_empty() {
                        outcome = protocol_error();
                        break;
                    }
                    if data[0] == crate::S2C_MAP && data.len() == 1
                        || data[0] == crate::S2C_SETTINGS && data.len() < 5
                        || data[0] == crate::S2C_WELCOME && data.len() < 17
                        || data[0] == crate::S2C_SNAPSHOT && data.len() <= crate::SNAPSHOT_HEADER
                        || data[0] == crate::S2C_DENIED && data.len() < 2
                        || data[0] == crate::S2C_ROSTER && data.len() < 2
                        || data[0] == crate::S2C_MATCH && data.len() < 4
                    {
                        outcome = protocol_error();
                        break;
                    }
                    if data[0] == crate::S2C_MAPNAME {
                        continue;
                    }
                    match data.first().copied() {
                        Some(crate::S2C_MAP) => {
                            let Some((m, grid)) = maps.get(&data[1..]).await else {
                                outcome = protocol_error();
                                break;
                            };
                            let seed = match_seed;
                            let mut next = sim::World::on_shared_map(seed, m);
                            if !cfg_bytes.is_empty() && !next.apply_settings(&cfg_bytes) {
                                outcome = protocol_error();
                                break;
                            }
                            b.remap();
                            route = Some(grid);
                            w = next;
                        }
                        Some(crate::S2C_SETTINGS) => {
                            cfg_bytes = data[5..].to_vec();
                            if !w.apply_settings(&cfg_bytes) {
                                outcome = protocol_error();
                                break;
                            }
                        }
                        Some(crate::S2C_WELCOME) => {
                            ship = data[1];
                            if ship as usize >= sim::MAX_SHIPS {
                                outcome = protocol_error();
                                break;
                            }
                            b.ship = ship;
                            lifecycle = u32::from_le_bytes(data[2..6].try_into().unwrap());
                        }
                        Some(crate::S2C_SNAPSHOT) => {
                            if !w.apply_snapshot(&data[crate::SNAPSHOT_HEADER..]) {
                                outcome = protocol_error();
                                break;
                            }
                            snapshot_at = std::time::Instant::now();
                        }
                        Some(crate::S2C_ROSTER) => {
                            standings.read(&data);
                            seen.note_room(&standings);
                        }
                        Some(crate::S2C_MATCH) => {
                            let next = data[1] & crate::MATCH_PLAYING != 0;
                            match_left = seconds_left(&data);
                            if match_transition(&mut match_playing, &mut match_number, next) {
                                seen.note_match();
                                b = fresh_brain(ship, who.brain(), match_seed, match_number);
                                sent = None;
                                sent_at = 0;
                                asked = None;
                            }
                            if !match_playing && yielding.load(Ordering::Relaxed) {
                                outcome = FlightEnd::Departed;
                                break;
                            }
                        }
                        Some(crate::S2C_YIELD) => {
                            outcome = FlightEnd::Yielded;
                            break;
                        }
                        Some(crate::S2C_DENIED) => {
                            outcome = if data[1] == crate::DENY_RATED_SESSION {
                                FlightEnd::RatedBusy
                            } else {
                                FlightEnd::Refused
                            };
                            break;
                        }
                        _ => {}
                    }
                }
                _ = ticker.tick() => {
                    if heard.elapsed().as_millis() as u64 > QUIET_MS {
                        break;
                    }
                    if snapshot_at.elapsed().as_millis() as u64 > SNAPSHOT_STALL_MS {
                        outcome = snapshot_stalled();
                        break;
                    }
                    if ship as usize >= sim::MAX_SHIPS {
                        break;
                    }
                    if !match_playing {
                        continue;
                    }
                    let mut own = ai::own(&w, ship);
                    own.match_left = match_left;
                    let mut fresh = b.looks_due().then(|| ai::scan(&w, ship));
                    standings.apply(ship, &mut own, fresh.as_mut());
                    if b.wants_refuge() {
                        let mut c = ai::crowd(&w, ship);
                        c.extend_from_slice(b.avoid());
                        if let Some(r) = route.as_deref() {
                            b.refuge(r.refuge((own.x, own.y), &c, ai::REFUGE_PX, true));
                        }
                    }
                    let tick = w.state.tick;
                    if yielding.load(Ordering::Relaxed) {
                        b.stand_down();
                        let since = *asked.get_or_insert_with(std::time::Instant::now);
                        let how = if !own.alive {
                            Some("died")
                        } else if b.departed() {
                            Some("clear")
                        } else if since.elapsed().as_millis() as u64 > DEPART_MAX_MS {
                            Some("gave up")
                        } else {
                            None
                        };
                        if let Some(how) = how {
                            println!("{addr}: {} left ({how}, {:.1}s)",
                                     who.callsign, since.elapsed().as_secs_f32());
                            outcome = FlightEnd::Departed;
                            break;
                        }
                    }
                    buttons = match route.as_deref() {
                        Some(r) => b.think(&own, r, fresh),
                        None => 0,
                    };
                    if input_frame_due(sent, sent_at, buttons, tick) {
                        let m = crate::input_message(
                            lifecycle,
                            0,
                            0,
                            &[(tick.wrapping_add(1), buttons)],
                        );
                        if sink.send(Message::Binary(m)).await.is_err() {
                            break;
                        }
                        sent = Some(buttons);
                        sent_at = tick;
                    }
                    w.step(&[sim::sim_input { ship, buttons }]);
                }
            }
        }
    }

    // Whatever was held against the rig goes back: the seat with the mind in
    // it, and the pen if this connection was the one feeding. The driver's
    // next tick simply finds one fewer pilot.
    if let Sight::Shared(rig) = &sight {
        rig.release(ship, me);
    }
    // Bounded, because a close waits for the peer's reply and nothing polls the
    // read half any more. The supervisor counts a bot as present until its task
    // ends, so a close that hangs is a seat the room has already given up and
    // the population has not noticed.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), sink.close()).await;
    outcome
}

#[cfg(test)]
mod tests {

    use super::*;

    fn welcome_message(ship: u8, lifecycle: u32, tick: u32, room: u16) -> Vec<u8> {
        let mut message = vec![crate::S2C_WELCOME, ship];
        message.extend_from_slice(&lifecycle.to_le_bytes());
        message.extend_from_slice(&tick.to_le_bytes());
        message.extend_from_slice(&room.to_le_bytes());
        message.extend_from_slice(&1u32.to_le_bytes());
        message.push(crate::WHY_NONE);
        message
    }

    fn test_seat(
        ship: u8,
        route: Arc<nav::Nav>,
        tx: tokio::sync::mpsc::Sender<Ctl>,
        playing: bool,
    ) -> Seat {
        let brain_config = pilots::individual(0).brain();
        Seat {
            id: 71,
            lifecycle: 1,
            name: "Halcyon".into(),
            addr: "ws://nowhere".into(),
            brain: fresh_brain(ship, brain_config, 19, 0),
            brain_config,
            flight_seed: 19,
            match_number: 0,
            playing,
            match_left: None,
            route,
            yielding: Arc::new(AtomicBool::new(false)),
            asked: None,
            sent: None,
            sent_at: 0,
            tx,
        }
    }

    #[test]
    fn a_match_transition_is_numbered_once() {
        let mut playing = true;
        let mut number = 0;
        assert!(!match_transition(&mut playing, &mut number, true));
        assert_eq!(number, 0, "a repeated playing packet is not a rematch");
        assert!(!match_transition(&mut playing, &mut number, false));
        assert!(match_transition(&mut playing, &mut number, true));
        assert_eq!(number, 1);
        assert!(!match_transition(&mut playing, &mut number, true));
        assert_eq!(number, 1);
        assert_ne!(controller_seed(19, 0), controller_seed(19, 1));
        assert_eq!(controller_seed(19, 1), controller_seed(19, 1));
    }

    #[test]
    fn a_rematch_replaces_the_entire_seated_brain() {
        let world = sim::World::with_map(7, sim::build_pit);
        let route = Arc::new(nav::Nav::build(&world.map));
        let (tx, _rx) = tokio::sync::mpsc::channel(4);
        let mut seat = test_seat(0, route, tx, true);

        seat.brain.stand_down();
        assert_eq!(seat.brain.doing(), 4, "the old brain carries exit state");
        assert!(!seat.set_match(false, 0, None));
        assert_eq!(
            seat.brain.doing(),
            4,
            "pausing does not spend or rewrite controller state"
        );
        assert!(seat.set_match(true, 1, None));
        assert_ne!(
            seat.brain.doing(),
            4,
            "the new match has a fresh departure, route, and recovery state"
        );

        seat.brain.stand_down();
        assert!(!seat.set_match(true, 1, None));
        assert_eq!(
            seat.brain.doing(),
            4,
            "a duplicate playing packet cannot reset a live match"
        );
        assert!(!seat.set_match(false, 1, None));
        assert!(seat.set_match(true, 2, None));
        assert_ne!(seat.brain.doing(), 4, "the next rematch is fresh too");
    }

    #[tokio::test]
    async fn the_shared_driver_does_not_fly_during_intermission() {
        let mut world = sim::World::with_map(7, sim::build_pit);
        let ship = world.spawn(0, 0, 100, 100, 0) as u8;
        let route = Arc::new(nav::Nav::build(&world.map));
        let rig = Arc::new(Rig::new(world));
        let (tx, mut rx) = tokio::sync::mpsc::channel(16);
        assert!(
            rig.claim(ship, test_seat(ship, route, tx, false)).is_ok(),
            "the test pilot takes its seat"
        );
        let driver = tokio::spawn(drive(Arc::downgrade(&rig), 1));

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(80), rx.recv())
                .await
                .is_err(),
            "a paused controller produces no input frame"
        );
        rig.set_match(ship, 71, true, 1, None);
        let frame = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
            .await
            .expect("a started controller thinks promptly")
            .expect("the driver's channel stays open");
        assert!(matches!(
            frame,
            Ctl::Frame {
                match_number: 1,
                ..
            }
        ));

        rig.driver_generation.store(2, Ordering::SeqCst);
        tokio::time::timeout(std::time::Duration::from_secs(1), driver)
            .await
            .expect("the old driver observes its revoked generation")
            .expect("the shared driver exits cleanly");
    }

    /// The bot's join, read the way the arena reads it.
    ///
    /// This is the check that was missing. The header grew a room byte, the
    /// arena and the player's client took it, this file did not, and the name
    /// then landed one byte late. On a message with a session token that is a
    /// mangled name; on one without, the slice runs past the end and comes back
    /// empty, which the arena turns into "pilot". Fifty bots, one name.
    ///
    /// So the offsets here are deliberately spelled out rather than shared with
    /// the parser: two copies of an arithmetic that disagree is exactly the bug,
    /// and a test that imports the parser's own arithmetic cannot see it.
    fn name_as_the_arena_reads_it(msg: &[u8]) -> String {
        let zlen = msg[4] as usize;
        let nlen = msg[5] as usize;
        let h = 7;
        String::from_utf8_lossy(msg.get(h + zlen..h + zlen + nlen).unwrap_or_default()).to_string()
    }

    #[test]
    fn welcome_names_the_authoritative_room_in_its_header() {
        let message = welcome_message(3, 9, 77, 0x3412);
        assert_eq!(welcome_room(&message), Some(0x3412));
        assert_eq!(welcome_room(&message[..11]), None);
    }

    #[test]
    fn scalar_population_requests_keep_the_old_fill_behavior() {
        assert_eq!(
            ArenaWant::new(3, None).assignments(),
            vec![Assignment { room: 0 }; 3]
        );
    }

    #[test]
    fn structured_population_requests_are_room_scoped_final_counts() {
        let wanted = ArenaWant::new(
            99,
            Some(vec![
                crate::fleet::BotRequest { room: 7, count: 1 },
                crate::fleet::BotRequest { room: 3, count: 2 },
            ]),
        );
        assert_eq!(
            wanted.assignments(),
            vec![
                Assignment { room: 3 },
                Assignment { room: 3 },
                Assignment { room: 7 },
            ]
        );
    }

    #[test]
    fn a_structured_request_cannot_alias_an_unrepresentable_room_to_zero() {
        let wanted = ArenaWant::new(
            1,
            Some(vec![crate::fleet::BotRequest {
                room: crate::MAX_ROOM_NUMBER + 1,
                count: 1,
            }]),
        );
        assert!(wanted.assignments().is_empty());
    }

    #[test]
    fn reconciliation_moves_only_the_room_whose_final_count_changed() {
        let room_one = Assignment { room: 1 };
        let room_two = Assignment { room: 2 };
        assert_eq!(
            reconcile_assignments(
                &[(room_one, false), (room_one, false), (room_two, false)],
                &[room_one, room_two, room_two],
            ),
            Reconciliation {
                surplus: vec![1],
                missing: vec![room_two],
            }
        );
    }

    #[test]
    fn a_yielding_ordinary_bot_no_longer_fills_a_population_request() {
        let assignment = Assignment { room: 4 };
        assert_eq!(
            reconcile_assignments(&[(assignment, true)], &[assignment]).missing,
            vec![assignment]
        );
    }

    /// A pilot leaving so the room can be dealt another one is not the room
    /// getting quieter. Its seat is still wanted, so nothing is claimed for it
    /// until the pilot has actually gone: refilling early would send a second
    /// client at a chair the first one is still in.
    #[test]
    fn a_pilot_leaving_to_be_replaced_still_fills_its_room() {
        let assignment = Assignment { room: 4 };
        let plan = reconcile_assignments(&[(assignment, false)], &[assignment]);
        assert!(plan.missing.is_empty(), "the room is not short yet");
        assert!(plan.surplus.is_empty(), "and it is not over-full either");
    }

    /// The bands are the tiers, in the tiers' own order. Two lists that have to
    /// agree and live in different files agree because this fails otherwise.
    #[test]
    fn every_tier_names_a_band() {
        let tiers: Vec<&str> = crate::rating::TIERS.iter().map(|(name, _)| *name).collect();
        let bands: Vec<&str> = RIVAL_BANDS.iter().map(|(name, _, _)| *name).collect();
        assert_eq!(tiers, bands);
        for (name, low, high) in RIVAL_BANDS {
            assert!(low < high, "{name} is a window rather than a point");
        }
    }

    /// What a rating asks for. The tier is what a player is shown, so it is
    /// also what decides who they are shown across from.
    #[test]
    fn a_band_follows_the_rival_s_tier() {
        assert_eq!(band_for(900), (RIVAL_BANDS[0].1, RIVAL_BANDS[0].2));
        assert_eq!(band_for(1200), MIDDLE_BAND);
        assert_eq!(band_for(1800), (RIVAL_BANDS[4].1, RIVAL_BANDS[4].2));
    }

    /// A room asking for a band gets somebody inside it. The pool is 65,536
    /// pilots and every band covers a wide share of it, so the banded pass
    /// answers and the fall-through to anybody free is never reached.
    #[test]
    fn a_banded_claim_takes_a_pilot_the_room_can_use() {
        let taken = Arc::new(Mutex::new(HashSet::new()));
        let blocked = Arc::new(Mutex::new(HashMap::new()));
        for (_, low, high) in RIVAL_BANDS {
            let want = Wanted {
                band: Some((low, high)),
                recent: Vec::new(),
            };
            let got = claim(&taken, &blocked, 0, &want).expect("the pool is not empty");
            let prior = got.ordering_prior();
            assert!(
                (low..=high).contains(&prior),
                "{} sits at {prior:.2}, outside {low:.2}-{high:.2}",
                got.callsign
            );
        }
    }

    /// And not the one it just had. This is the whole of the complaint the
    /// rotation answers: a duel room used to be handed the lowest free index
    /// every time, which is one opponent for a whole session.
    #[test]
    fn a_claim_skips_the_pilots_a_room_has_just_had() {
        let taken = Arc::new(Mutex::new(HashSet::new()));
        let blocked = Arc::new(Mutex::new(HashMap::new()));
        let mut recent = Vec::new();
        for _ in 0..RIVAL_MEMORY {
            let want = Wanted {
                band: None,
                recent: recent.clone(),
            };
            let got = claim(&taken, &blocked, 0, &want).expect("the pool is not empty");
            assert!(!recent.contains(&got.id), "{} came back", got.callsign);
            recent.push(got.id);
        }
    }

    /// When a room is dealt somebody else, and when it is left alone.
    #[test]
    fn a_room_is_dealt_a_new_rival_when_the_old_one_has_run_its_course() {
        let (low, high) = band_for(1200);
        let suits = (low + high) / 2.0;
        assert!(
            !wants_replacing(0, suits, Some(1200)),
            "never before a match has been played, whatever else is true"
        );
        assert!(
            !wants_replacing(RIVAL_MATCHES - 1, suits, Some(1200)),
            "a pilot who suits the room stays for its whole run"
        );
        assert!(
            wants_replacing(RIVAL_MATCHES, suits, Some(1200)),
            "and is replaced at the end of it"
        );
        assert!(
            wants_replacing(1, high + 0.1, Some(1200)),
            "a pilot the room was dealt blind goes after one match"
        );
        assert!(
            wants_replacing(1, low - 0.1, Some(1200)),
            "outclassed either way round"
        );
        assert!(
            !wants_replacing(99, suits, None),
            "bots keeping an empty room warm are matched to nobody"
        );
    }

    /// The rival is the best person in the room and never a machine, which is
    /// what makes an empty room ask for nobody in particular.
    #[test]
    fn the_rival_is_the_best_person_in_the_room() {
        let standing = |rating: i16, bot: bool| {
            Some(ai::Standing {
                rating,
                games: 40,
                bot,
            })
        };
        let mut seats: [Option<ai::Standing>; sim::MAX_SHIPS] = std::array::from_fn(|_| None);
        seats[0] = standing(1600, true);
        seats[1] = standing(1310, false);
        seats[2] = standing(1180, false);
        assert_eq!(Standings(seats).rival(), Some(1310));

        let mut machines: [Option<ai::Standing>; sim::MAX_SHIPS] = std::array::from_fn(|_| None);
        machines[0] = standing(1600, true);
        assert_eq!(Standings(machines).rival(), None);
    }

    /// A map change carries the pilot across rather than emptying its seat.
    ///
    /// A match game changes map at every whistle, and a new map keys a new
    /// rig. The seat used to be released into the old one, and nothing takes a
    /// seat except a welcome, so every bot in the room ended up at the
    /// controls of nothing: parked until the supervisor noticed it doing
    /// nothing and replaced it, about a minute into a three minute match.
    #[tokio::test]
    async fn a_map_change_moves_the_pilot_rather_than_emptying_the_seat() {
        let drydock = std::fs::read("../catalog/zones/melee/drydock.vwmap")
            .expect("a shipped map lives in this repository");
        let relay = std::fs::read("../catalog/zones/melee/relay.vwmap")
            .expect("a shipped map lives in this repository");
        assert_ne!(
            fingerprint(&drydock),
            fingerprint(&relay),
            "two maps, or this test is about nothing"
        );

        let maps = Maps::default();
        let (first, road) = maps.get(&drydock).await.expect("the map unpacks");
        let (second, other_road) = maps.get(&relay).await.expect("the map unpacks");
        let old = Rig::new(sim::World::on_shared_map(1, first));
        let new = Rig::new(sim::World::on_shared_map(2, second));

        let (tx, _rx) = tokio::sync::mpsc::channel(4);
        let ship = 3u8;
        let me = 77u64;
        let brain_config = pilots::individual(0).brain();
        let mut brain = ai::Bot::new(ship, brain_config);
        brain.reseed(19);
        assert!(old
            .claim(
                ship,
                Seat {
                    id: me,
                    lifecycle: 1,
                    name: "Halcyon".into(),
                    addr: "ws://nowhere".into(),
                    brain,
                    brain_config,
                    flight_seed: 19,
                    match_number: 0,
                    playing: true,
                    match_left: None,
                    route: Arc::clone(&road),
                    yielding: Arc::new(AtomicBool::new(false)),
                    asked: None,
                    sent: Some(0b101),
                    sent_at: 40,
                    tx,
                }
            )
            .is_ok());

        // What the map message does, in the order it does it.
        let carried = old.take(ship, me).expect("the pilot comes out with it");
        assert!(
            old.lock_crew().get(&ship).is_none(),
            "and is not left behind in the rig it came from"
        );
        let mut seat = carried;
        seat.brain.remap();
        seat.route = Arc::clone(&other_road);
        seat.sent = None;
        seat.sent_at = 0;
        assert!(
            new.claim(ship, seat).is_ok(),
            "and sits down in the new one"
        );

        let crew = new.lock_crew();
        let landed = crew.get(&ship).expect("somebody is at the controls");
        assert_eq!(landed.id, me, "the same pilot, not a fresh one");
        assert_eq!(
            landed.name, "Halcyon",
            "with its own name and its own brain"
        );
        assert!(
            std::ptr::eq(Arc::as_ptr(&landed.route), Arc::as_ptr(&other_road)),
            "flying the new ground rather than the old"
        );
        assert_eq!(
            landed.sent, None,
            "and its last controls forgotten, so the first frame on the new \
             map is sent rather than held back as unchanged"
        );
    }

    #[test]
    fn a_bot_arrives_under_its_own_name() {
        let msg = join_msg(3, "vX-9", "", 0).expect("representable join");
        assert_eq!(
            name_as_the_arena_reads_it(&msg),
            "vX-9",
            "a bot with no meta-layer behind it still has a name"
        );
    }

    #[test]
    fn and_under_it_with_a_token_on_the_end_too() {
        // The case that hides the bug rather than showing it: with something
        // after the name, a late read returns a wrong name instead of no name.
        let msg = join_msg(0, "Halcyon", "a.session.token", 0).expect("representable join");
        assert_eq!(name_as_the_arena_reads_it(&msg), "Halcyon");
    }

    #[test]
    fn the_header_is_the_length_the_arena_expects() {
        let msg = join_msg(0, "", "", 0).expect("representable join");
        assert_eq!(
            msg.len(),
            crate::C2S_JOIN_HEADER,
            "an empty name and no token is the header alone"
        );
    }

    #[test]
    fn a_room_scoped_bot_asks_for_the_room_that_requested_it() {
        let msg = join_msg(0, "Halcyon", "", 17).expect("representable join");
        assert_eq!(
            msg[6], 17,
            "the existing join room byte carries the request"
        );
        assert_eq!(name_as_the_arena_reads_it(&msg), "Halcyon");
        assert_eq!(
            join_msg(0, "Halcyon", "", crate::MAX_ROOM_NUMBER + 1),
            None,
            "an unrepresentable room is refused rather than aliased to ordinary fill"
        );
    }

    #[test]
    fn retry_backoff_is_stable_exponential_and_capped() {
        let delays: Vec<u64> = (1..=8)
            .map(|failure| retry_delay_ms(failure, "ws://arena"))
            .collect();
        assert_eq!(delays, {
            let mut sorted = delays.clone();
            sorted.sort_unstable();
            sorted
        });
        assert_eq!(delays[7], RETRY_MAX_MS);
        assert_eq!(
            retry_delay_ms(3, "ws://arena"),
            retry_delay_ms(3, "ws://arena"),
            "one arena gets repeatable jitter"
        );
    }

    #[tokio::test]
    async fn concurrent_map_arrivals_share_one_build_and_release_it_afterward() {
        let source = sim::World::with_map(7, sim::build_pit);
        let packed = source.packed_map();
        let maps = Maps::default();
        let grounds = futures_util::future::join_all((0..8).map(|_| maps.get(&packed))).await;
        let grounds: Vec<Ground> = grounds
            .into_iter()
            .map(|ground| ground.expect("the map unpacks"))
            .collect();
        for ground in &grounds[1..] {
            assert!(Arc::ptr_eq(&grounds[0].0, &ground.0));
            assert!(Arc::ptr_eq(&grounds[0].1, &ground.1));
        }
        let map = Arc::downgrade(&grounds[0].0);
        let route = Arc::downgrade(&grounds[0].1);
        drop(grounds);
        assert!(
            map.upgrade().is_none(),
            "the cache does not own old geometry"
        );
        assert!(
            route.upgrade().is_none(),
            "the cache does not own old routing grids"
        );
    }

    #[tokio::test]
    async fn shared_rigs_are_keyed_by_arena_room_and_map() {
        let first = sim::World::with_map(7, sim::build_pit);
        let first_packed = first.packed_map();
        let second = sim::World::with_map(11, sim::build_arena);
        let second_packed = second.packed_map();
        let maps = Maps::default();
        let (first_map, _) = maps.get(&first_packed).await.expect("the map unpacks");
        let (second_map, _) = maps.get(&second_packed).await.expect("the map unpacks");
        let first_key = fingerprint(&first_packed);
        let second_key = fingerprint(&second_packed);
        let rigs = Rigs::default();

        let original = rigs.get("wss://arena", 7, first_key, &first_map).unwrap();
        let same = rigs.get("wss://arena", 7, first_key, &first_map).unwrap();
        let other_room = rigs.get("wss://arena", 8, first_key, &first_map).unwrap();
        let other_map = rigs.get("wss://arena", 7, second_key, &second_map).unwrap();
        let other_arena = rigs
            .get("wss://other-arena", 7, first_key, &first_map)
            .unwrap();

        assert!(Arc::ptr_eq(&original, &same));
        assert!(!Arc::ptr_eq(&original, &other_room));
        assert!(!Arc::ptr_eq(&original, &other_map));
        assert!(!Arc::ptr_eq(&original, &other_arena));
    }

    #[tokio::test]
    async fn an_invalid_welcome_is_a_protocol_failure() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            let _ = ws.next().await;
            ws.send(Message::Binary(welcome_message(255, 1, 0, 0)))
                .await
                .unwrap();
        });
        let (ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
        let outcome = fly_socket(
            url,
            pilots::individual(8),
            0,
            Arc::new(Maps::default()),
            Arc::new(Rigs::default()),
            Arc::new(AtomicBool::new(false)),
            Arc::default(),
            BotIdentity::Unaccounted,
            ws,
        )
        .await;
        assert_eq!(outcome, FlightEnd::Protocol);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn a_yielding_bot_leaves_as_soon_as_intermission_arrives() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            let _ = ws.next().await;
            ws.send(Message::Binary(vec![crate::S2C_MATCH, 0, 0, 0]))
                .await
                .unwrap();
        });
        let (ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
        let outcome = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            fly_socket(
                url,
                pilots::individual(8),
                6,
                Arc::new(Maps::default()),
                Arc::new(Rigs::default()),
                Arc::new(AtomicBool::new(true)),
                Arc::default(),
                BotIdentity::Unaccounted,
                ws,
            ),
        )
        .await
        .expect("intermission departure does not wait for graceful flight");
        assert_eq!(outcome, FlightEnd::Departed);
        server.await.unwrap();
    }

    #[test]
    fn a_filtered_bot_view_is_not_a_complete_shared_world() {
        let mut source = sim::World::with_map(7, sim::build_pit);
        let near = source.spawn(0, 0, 100, 100, 0) as u8;
        let far = source.spawn(0, 1, 300, 300, 0) as u8;
        let me = &source.state.ships[near as usize];
        let mut packed = vec![0u8; sim::PACK_MAX];
        let n = source.pack_around(
            &mut packed,
            me.x,
            me.y,
            crate::delivery::FAIR_INTEREST,
            near,
            0,
        );
        assert!(n > 0);

        let mut view = sim::World::from_packed(11, &source.packed_map()).unwrap();
        assert!(view.apply_snapshot(&packed[..n as usize]));
        assert!(ai::own(&view, near).alive);
        assert!(
            !ai::own(&view, far).alive,
            "a distant pilot must be absent from an interest-filtered snapshot"
        );
        assert!(
            !BotIdentity::Unaccounted.shares_world(),
            "that filtered snapshot cannot become every bot's truth"
        );
    }

    #[test]
    fn departure_crowds_obey_the_same_sight_limit_as_combat() {
        let mut world = sim::World::with_map(7, sim::build_pit);
        let me = world.spawn(0, 0, 100, 100, 0) as u8;
        world.spawn(0, 1, 105, 100, 0);
        world.spawn(0, 1, 300, 300, 0);
        assert_eq!(
            ai::crowd(&world, me).len(),
            1,
            "a distant ship cannot steer a pilot that cannot see it"
        );
    }

    #[test]
    fn unchanged_controls_are_sent_as_a_heartbeat() {
        assert!(input_frame_due(None, 0, 0, 10), "the first input is sent");
        assert!(input_frame_due(Some(1), 10, 2, 11), "a change is immediate");
        assert!(
            !input_frame_due(Some(2), 10, 2, 59),
            "an unchanged input waits"
        );
        assert!(
            input_frame_due(Some(2), 10, 2, 60),
            "half a second of unchanged input is enough"
        );
    }

    #[test]
    fn driver_watch_requires_five_seconds_without_progress() {
        let now = std::time::Instant::now();
        let mut watch = DriverWatch::new(7, now);
        assert!(!watch.stalled(7, now + std::time::Duration::from_millis(4_999)));
        assert!(watch.stalled(7, now + std::time::Duration::from_millis(5_000)));

        let mut watch = DriverWatch::new(7, now);
        assert!(!watch.stalled(8, now + std::time::Duration::from_secs(4)));
        assert!(
            !watch.stalled(8, now + std::time::Duration::from_secs(8)),
            "progress restarts the watchdog clock"
        );
    }

    #[test]
    fn a_fleet_busy_identity_does_not_block_the_roster() {
        let taken = Arc::new(Mutex::new(HashSet::new()));
        let blocked = Arc::new(Mutex::new(HashMap::new()));
        let first = pilots::individual(0);
        blocked
            .lock()
            .unwrap()
            .insert(first.callsign.clone(), 20_000);
        let got = claim(&taken, &blocked, 10_000, &Wanted::default()).unwrap();
        assert_ne!(got.callsign, first.callsign);
        assert_eq!(got.callsign, pilots::individual(1).callsign);
    }
}
