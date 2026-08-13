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
//! Two economies inside the process, both invisible on the wire. The fifty
//! pilots an arena wants are all being sent the same room, so they predict it
//! in one shared `Rig` rather than fifty private copies. And that rig has one
//! clock: a single driver task advances the world and runs every seated brain,
//! where each pilot used to carry a 100 Hz ticker of its own, which at fifty
//! pilots was most of this process's CPU spent waking up and contending for
//! the lock rather than flying. Each connection still joins, receives and
//! answers as an ordinary client; where the bytes land, and who does the
//! thinking, is this process's own business.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

use crate::{ai, directory, nav, sim};

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
/// Snapshots stop arriving and nothing else says why. Ten seconds is five
/// hundred missed snapshots, so this only ever fires on a connection that is
/// actually gone.
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
#[derive(Default)]
struct Maps(Mutex<HashMap<u64, (Arc<sim::sim_map>, Arc<nav::Nav>)>>);

impl Maps {
    fn get(&self, packed: &[u8]) -> Option<(Arc<sim::sim_map>, Arc<nav::Nav>)> {
        let key = fingerprint(packed);
        if let Some((m, n)) = self.0.lock().ok()?.get(&key) {
            return Some((Arc::clone(m), Arc::clone(n)));
        }
        let m = sim::unpack_map(packed)?;
        let n = Arc::new(nav::Nav::build(&m));
        self.0
            .lock()
            .ok()?
            .insert(key, (Arc::clone(&m), Arc::clone(&n)));
        Some((m, n))
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
/// the arena now guarantees for declared bots: see the prize radius note in
/// `broadcast_snapshot`.
/// What the driver tells a connection task. Frames are this pilot's own
/// input messages, sent on its own socket so the wire holds one client per
/// bot exactly as decision 29 requires; Leave is a departure that finished,
/// however it finished.
enum Ctl {
    Frame(Vec<u8>),
    Leave,
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
    route: Arc<nav::Nav>,
    yielding: Arc<AtomicBool>,
    asked: Option<std::time::Instant>,
    sent: Option<u16>,
    sent_at: u32,
    tx: tokio::sync::mpsc::Sender<Ctl>,
}

struct Rig {
    world: Mutex<sim::World>,
    /// The last buttons each seat produced, read when the driver steps.
    /// Meaningful only while `crew` holds a pilot in that seat.
    buttons: [AtomicU16; sim::MAX_SHIPS],
    /// Everybody flying this rig, by seat. A claim that finds the seat held
    /// by a live pilot has found a second room: ship indices are unique
    /// within a room and nothing on the wire says which room a welcome came
    /// from, so the claimer flies a private world rather than somebody
    /// else's picture. No shipped zone opens a second room today; when one
    /// does, the honest fix is a room id in the protocol, and this fallback
    /// is what keeps the population correct rather than fast until then.
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
}

impl Rig {
    fn new(world: sim::World) -> Self {
        Rig {
            world: Mutex::new(world),
            buttons: std::array::from_fn(|_| AtomicU16::new(0)),
            crew: Mutex::new(HashMap::new()),
            pen: AtomicU64::new(0),
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

    /// Take a seat, or refuse it because a live pilot already has it, which is
    /// the second-room signal described on `crew`.
    fn claim(&self, ship: u8, seat: Seat) -> bool {
        let mut c = self.lock_crew();
        if let Some(held) = c.get(&ship) {
            if held.id != seat.id {
                return false;
            }
        }
        self.buttons[ship as usize].store(0, Ordering::Relaxed);
        c.insert(ship, seat);
        true
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
            for (&ship, seat) in crew.iter_mut() {
                let own = ai::own(&w, ship);
                let fresh = seat.brain.looks_due().then(|| ai::scan(&w, ship));
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
                if seat.tx.try_send(Ctl::Frame(m)).is_ok() {
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
/// resume as a second room clock later.
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

/// The rigs, one per arena address and map. Weak, so a rig lives exactly as
/// long as some pilot holds it and a map change simply keys a new one.
#[derive(Default)]
struct Rigs(Mutex<HashMap<(String, u64), std::sync::Weak<Rig>>>);

impl Rigs {
    fn get(&self, addr: &str, key: u64, map: &Arc<sim::sim_map>) -> Option<Arc<Rig>> {
        let mut g = self.0.lock().ok()?;
        if let Some(rig) = g.get(&(addr.to_string(), key)).and_then(|w| w.upgrade()) {
            return Some(rig);
        }
        g.retain(|_, w| w.strong_count() > 0);
        let rig = Arc::new(Rig::new(sim::World::on_shared_map(
            key as u32,
            Arc::clone(map),
        )));
        tokio::spawn(supervise_driver(Arc::downgrade(&rig)));
        g.insert((addr.to_string(), key), Arc::downgrade(&rig));
        Some(rig)
    }
}

/// One bot the supervisor is holding open.
struct Live {
    name: String,
    born_ms: u64,
    /// Set when this bot has been asked to stand down. It leaves at the next
    /// good moment rather than at once, per the graceful rules in
    /// docs/design/ai-players.md.
    yielding: Arc<AtomicBool>,
    /// This identity already holds a rated lease on another host. Back it out
    /// of this supervisor's front of the roster long enough for that lease and
    /// its renewal window to clear.
    busy: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
}

const RATED_BUSY_BACKOFF_MS: u64 = 180_000;

/// What the supervisor knows about one arena.
#[derive(Default)]
struct Instance {
    bots: Vec<Live>,
    /// When this instance last let a bot go, so it does not immediately take
    /// another one back.
    released_ms: u64,
    /// Consecutive cycles it has failed to answer. See `GONE_AFTER`.
    misses: u32,
}

pub async fn run() {
    // The one process in the fleet nothing could ask about, which is why it
    // was the one nobody could account for when the host pegged.
    crate::metrics::spawn("bots", "");
    let maps: Arc<Maps> = Arc::default();
    let rigs: Arc<Rigs> = Arc::default();
    // Names in use by this supervisor. The meta-layer's rated lease arbitrates
    // the same identity between supervisors on different hosts.
    let taken: Arc<Mutex<HashSet<String>>> = Arc::default();
    let blocked: Arc<Mutex<HashMap<String, u64>>> = Arc::default();
    // One account secret per individual, held for the life of the process.
    let secrets: Arc<Mutex<HashMap<String, String>>> = Arc::default();
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
        // restarted. Its name goes back in the pool.
        for inst in fleet.values_mut() {
            inst.bots.retain(|b| {
                let done = b.task.is_finished();
                if done {
                    if b.busy.load(Ordering::Relaxed) {
                        if let Ok(mut blocked) = blocked.lock() {
                            blocked
                                .insert(b.name.clone(), now.saturating_add(RATED_BUSY_BACKOFF_MS));
                        }
                    }
                    if let Ok(mut t) = taken.lock() {
                        t.remove(&b.name);
                    }
                }
                !done
            });
        }

        // Asked all at once rather than one after another, which is not a
        // throughput question: a single unreachable address would otherwise
        // stall the whole loop for its dial timeout, so one arena restarting
        // stops the population being tended anywhere. Measured before it was
        // fixed: two dead addresses in the list turned a one second cycle into
        // a ten second one.
        let mut want: HashMap<String, u32> = HashMap::new();
        let asked = futures_util::future::join_all(dirs.iter().map(|u| browse(u))).await;
        for (addr, n) in asked.into_iter().flatten() {
            // The most any directory says, because a directory relays only what
            // it observed itself and one may have heard more recently than
            // another.
            let e = want.entry(addr).or_insert(0);
            *e = (*e).max(n);
        }
        let asked = futures_util::future::join_all(
            direct
                .iter()
                .map(|a| async move { (a.clone(), ask(a).await) }),
        )
        .await;
        for (addr, n) in asked {
            if let Some(n) = n {
                want.insert(addr, n);
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
                    want.insert(addr.clone(), 0);
                }
            }
        }

        for (addr, n) in want {
            let inst = fleet.entry(addr.clone()).or_default();
            // Bots on their way out still hold their seat, so they count. The
            // difference is what stops the supervisor asking a second one to
            // leave every cycle while the first is looking for its moment.
            let have = inst.bots.len();
            let n = n as usize;
            if have < n {
                if now.saturating_sub(inst.released_ms) < REFILL_COOLDOWN_MS {
                    continue;
                }
                let add = (n - have).min(ADD_PER_CYCLE);
                for _ in 0..add {
                    let Some(who) = claim(&taken, &blocked, now) else {
                        break;
                    };
                    let yielding = Arc::new(AtomicBool::new(false));
                    let busy = Arc::new(AtomicBool::new(false));
                    let task = tokio::spawn(fly(
                        addr.clone(),
                        who.clone(),
                        Arc::clone(&maps),
                        Arc::clone(&rigs),
                        Arc::clone(&yielding),
                        Arc::clone(&busy),
                        Arc::clone(&secrets),
                    ));
                    inst.bots.push(Live {
                        name: who.name,
                        born_ms: now,
                        yielding,
                        busy,
                        task,
                    });
                }
                println!("{addr}: {have} bots, wants {n}; sent {add}");
            } else if have > n {
                // Oldest first among those old enough to go, so a bot that has
                // just arrived is not immediately turned around.
                //
                // One at a time, whatever the surplus. A room shrinks by one
                // seat per person who joins it, so a group arriving together
                // used to put that many bots into leaving in the same second.
                // While leaving was instant nobody could tell; now that it is
                // a flight across the map with the trigger shut, five at once
                // is an evacuation, and a cycle is about a second, so the
                // surplus still drains at a person's pace. The already-going
                // ones are counted first so this does not stack a second
                // departure on a bot that is mid-way through one.
                let asked = inst
                    .bots
                    .iter()
                    .filter(|b| b.yielding.load(Ordering::Relaxed))
                    .count();
                let over = have - n;
                if asked < over {
                    for b in inst.bots.iter() {
                        if now.saturating_sub(b.born_ms) < MIN_LIFE_MS
                            || b.yielding.load(Ordering::Relaxed)
                        {
                            continue;
                        }
                        b.yielding.store(true, Ordering::Relaxed);
                        inst.released_ms = now;
                        println!("{addr}: {have} bots, wants {n}; {} stands down", b.name);
                        break;
                    }
                }
            }
        }
    }
}

/// Take the next unused individual. The calibrated pilots go first, and after them
/// the roster is generated, so a room asking for fifty-one gets fifty-one
/// distinct pilots rather than repeating the calibrated group.
fn claim(
    taken: &Arc<Mutex<HashSet<String>>>,
    blocked: &Arc<Mutex<HashMap<String, u64>>>,
    now: u64,
) -> Option<ai::RosterEntry> {
    let mut t = taken.lock().ok()?;
    let mut blocked = blocked.lock().ok()?;
    blocked.retain(|_, until| *until > now);
    for n in 0..4096 {
        let e = ai::individual(n);
        if blocked.contains_key(&e.name) {
            continue;
        }
        if t.insert(e.name.clone()) {
            return Some(e);
        }
    }
    None
}

/// Ask a directory what is running, and how many bots each instance wants.
async fn browse(url: &str) -> Vec<(String, u32)> {
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
        .flat_map(|z| z.instances.iter())
        .map(|i| (i.address.clone(), i.bots_wanted))
        .collect()
}

/// The same question straight to one arena, for a laptop running without a
/// directory. `C2S_STATUS` is answerable without joining, which is what makes
/// this the same request a directory's verification makes.
async fn ask(addr: &str) -> Option<u32> {
    let body = directory::request(addr, directory::STATUS_REQUEST, directory::STATUS_REPLY).await?;
    serde_json::from_str::<crate::fleet::Status>(&body)
        .ok()
        .map(|s| s.bots_wanted)
}

/// One bot, from dial to disconnect.
///
/// The loop is the client's loop. Inputs go out when they change, because the
/// arena holds the last buttons it was sent and applies them every tick, so a
/// bot flying straight costs nothing on the wire. The world is stepped locally
/// at the simulation's own rate between snapshots, which is not an optimisation
/// but the only way the brain's timing survives the move out of the arena:
/// reaction delay and look cadence are counted in 100 Hz ticks, and a brain fed
/// a 20 Hz picture would be a brain with five times the reaction time and a
/// heading five ticks stale to steer against.
///
/// The world it steps is the arena's `Rig`, shared with every other pilot on
/// the same address, because the rooms are one room and predicting it once is
/// the difference between this process fitting on the host and not. Each
/// connection still looks ordinary from the arena's side; the sharing is
/// entirely inside this process.
/// How one roster individual may see the room. A house token earns the complete
/// snapshot that makes the shared rig sound. A deployment without accounts is
/// still allowed to fly bots, but each one must use its own filtered world.
#[derive(Debug, PartialEq, Eq)]
enum BotIdentity {
    House(String),
    Unaccounted,
}

impl BotIdentity {
    fn session(&self) -> &str {
        match self {
            BotIdentity::House(token) => token,
            BotIdentity::Unaccounted => "",
        }
    }

    fn shares_world(&self) -> bool {
        matches!(self, BotIdentity::House(_))
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
async fn bot_identity(
    who: &str,
    secrets: &Mutex<HashMap<String, String>>,
) -> Result<BotIdentity, String> {
    let meta = std::env::var("VW_META").unwrap_or_default();
    let pool = std::env::var("VW_TOKEN").unwrap_or_default();
    if meta.is_empty() || pool.is_empty() {
        // A deployment without accounts. The bot still flies, declared and
        // labeled as somebody's bot, and rates nothing.
        return Ok(BotIdentity::Unaccounted);
    }
    // Read and release before any await: this is a plain mutex, and a guard
    // held across a network call is a deadlock waiting for a slow reply.
    let held = secrets.lock().ok().and_then(|m| m.get(who).cloned());
    let secret = match held {
        Some(s) => s,
        None => {
            let body = serde_json::json!({ "pool_token": pool, "name": who }).to_string();
            let reply = crate::meta::call(&meta, "/v1/bot", &body)
                .await
                .map_err(|e| format!("no account for {who}: {e}"))?;
            let s = reply
                .get("secret")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| format!("no account for {who}: response had no secret"))?
                .to_string();
            if let Ok(mut m) = secrets.lock() {
                m.insert(who.to_string(), s.clone());
            }
            s
        }
    };
    // `/v1/session` and not `/v1/login`: session is secret-in-token-out,
    // login is name-and-password. A bot account never holds a password, so
    // asking login was answered 403 for every bot in the fleet, each one then
    // joined tokenless, and no death a bot was part of could file. The pilot
    // log kept flowing, which is what made the ladder's silence look like a
    // rating bug instead of this.
    let body = serde_json::json!({ "secret": secret }).to_string();
    let reply = crate::meta::call(&meta, "/v1/session", &body)
        .await
        .map_err(|e| format!("{who} cannot begin a session: {e}"))?;
    let token = reply
        .get("token")
        .and_then(|v| v.as_str())
        .filter(|token| !token.is_empty())
        .ok_or_else(|| format!("{who} cannot begin a session: response had no token"))?;
    Ok(BotIdentity::House(token.to_string()))
}

/// The join a bot sends, built where something can check it.
///
/// It was written inline and it went stale: the header grew a room byte, this
/// did not, and every bot in the fleet arrived nameless. Out here it is one
/// expression a test can call, which is the whole reason it moved.
///
/// Zero for the room, meaning "whichever the fill ladder picks". A bot has been
/// shown no list and has no preference: it goes where the room that wants
/// filling is.
fn join_msg(class: u8, name: &str, session: &str) -> Vec<u8> {
    let n = name.as_bytes();
    let mut join = vec![
        crate::C2S_JOIN,
        class.min((sim::MAX_CLASSES - 1) as u8),
        crate::CLIENT_PROTOCOL,
        crate::JOIN_BOT,
        0,
        n.len().min(255) as u8,
        0,
    ];
    debug_assert_eq!(join.len(), crate::C2S_JOIN_HEADER);
    join.extend_from_slice(n);
    join.extend_from_slice(session.as_bytes());
    join
}

async fn fly(
    addr: String,
    who: ai::RosterEntry,
    maps: Arc<Maps>,
    rigs: Arc<Rigs>,
    yielding: Arc<AtomicBool>,
    busy: Arc<AtomicBool>,
    secrets: Arc<Mutex<HashMap<String, String>>>,
) {
    // The meta-layer and the arena normally restart together during a deploy.
    // A transient login failure must keep this pilot outside the room until
    // the account service returns. Joining without the token would make the
    // arena treat it as a third-party bot and send an interest-filtered
    // snapshot. If that connection won the shared rig's pen, every bot outside
    // its radar would disappear from the AI world and sit idle.
    let identity = match bot_identity(&who.name, &secrets).await {
        Ok(identity) => identity,
        Err(e) => {
            crate::metrics::BOT_AUTH_RETRIES.inc();
            println!("bots: {e}; retrying");
            return;
        }
    };
    let share_world = identity.shares_world();
    let cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
        max_message_size: Some(2 * 1024 * 1024),
        max_frame_size: Some(2 * 1024 * 1024),
        ..Default::default()
    };
    let dial = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio_tungstenite::connect_async_with_config(&addr, Some(cfg), false),
    );
    let Ok(Ok((ws, _))) = dial.await else { return };
    // Counted after the dial succeeds, so this is arenas reached rather than
    // arenas attempted. A step in it with no deploy behind it is a roster
    // being rebuilt, which is the shape a restart has from in here.
    crate::metrics::BOT_CONNECTS.inc();
    let _flying = crate::metrics::PilotGuard::new();
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
    let join = join_msg(who.class, &who.name, identity.session());
    if sink.send(Message::Binary(join)).await.is_err() {
        return;
    }

    // How this pilot sees the room: the rig it shares with every other
    // pilot on this arena, or nothing yet. A seat collision at welcome is
    // the second-room signal, and that pilot leaves this loop to fly a
    // private world at the old per-connection cost.
    enum Sight {
        Dark,
        Shared(Arc<Rig>),
    }
    let me = PILOT_ID.fetch_add(1, Ordering::Relaxed);
    let mut sight = Sight::Dark;
    // Held back for the private fallback, which is built at welcome, after
    // the map and the settings have already gone by.
    let mut map: Option<Arc<sim::sim_map>> = None;
    let mut cfg_bytes: Vec<u8> = Vec::new();
    let mut route: Option<Arc<nav::Nav>> = None;
    let mut ship: u8 = 0;
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
    // Set at a seat collision; flown after this loop ends.
    let mut go_private: Option<(sim::World, ai::Bot)> = None;

    loop {
        tokio::select! {
            biased;
            msg = source.next() => {
                let Some(Ok(Message::Binary(data))) = msg else {
                    // A close, or a frame we cannot read. Either way this
                    // connection is over and the supervisor will notice.
                    break;
                };
                heard = std::time::Instant::now();
                if data.is_empty() {
                    continue;
                }
                match data.first().copied() {
                    Some(crate::S2C_MAP) => {
                        let key = fingerprint(&data[1..]);
                        let Some((m, grid)) = maps.get(&data[1..]) else { break };
                        route = Some(grid);
                        // A fresh map mid-flight would mean a new rig; give
                        // back whatever was held against the old one first.
                        if let Sight::Shared(rig) = &sight {
                            rig.release(ship, me);
                        }
                        if share_world {
                            let Some(rig) = rigs.get(&addr, key, &m) else { break };
                            sight = Sight::Shared(rig);
                        } else {
                            sight = Sight::Dark;
                        }
                        map = Some(m);
                    }
                    Some(crate::S2C_SETTINGS) => {
                        if data.len() < 5 { break; }
                        cfg_bytes = data[5..].to_vec();
                        // Every pilot applies on arrival. The bytes are the
                        // zone's one answer, so on the shared rig this is the
                        // same settings written again, which is idempotent.
                        if let Sight::Shared(rig) = &sight {
                            rig.lock_world().apply_settings(&cfg_bytes);
                        }
                    }
                    Some(crate::S2C_WELCOME) if data.len() >= 16 => {
                        ship = data[1];
                        let lifecycle = u32::from_le_bytes(data[2..6].try_into().unwrap());
                        let mut b = ai::Bot::new(ship, who.skill);
                        // Luck of its own, so two pilots of one skill in one
                        // room do not fly the same match.
                        b.reseed(fingerprint(who.name.as_bytes()) as u32);
                        if !share_world {
                            let Some(m) = map.clone() else { break };
                            let mut w = sim::World::on_shared_map(
                                fingerprint(who.name.as_bytes()) as u32,
                                m,
                            );
                            if !cfg_bytes.is_empty() {
                                w.apply_settings(&cfg_bytes);
                            }
                            go_private = Some((w, b));
                            break;
                        }
                        if let Sight::Shared(rig) = &sight {
                            let Some(r) = route.clone() else { break };
                            let seat = Seat {
                                id: me,
                                lifecycle,
                                name: who.name.clone(),
                                addr: addr.clone(),
                                brain: b,
                                route: r,
                                yielding: Arc::clone(&yielding),
                                asked: None,
                                sent: None,
                                sent_at: 0,
                                tx: ctl_tx.clone(),
                            };
                            if !rig.claim(ship, seat) {
                                // Somebody live already answers to this ship
                                // index, so this welcome came from a second
                                // room. Fly it privately, at the old cost.
                                let Some(m) = map.clone() else { break };
                                let seed = fingerprint(who.name.as_bytes()) as u32;
                                let mut w = sim::World::on_shared_map(seed, m);
                                if !cfg_bytes.is_empty() {
                                    w.apply_settings(&cfg_bytes);
                                }
                                println!("{addr}: seat {ship} is taken; {} flies a private world", who.name);
                                let mut b = ai::Bot::new(ship, who.skill);
                                b.reseed(seed);
                                go_private = Some((w, b));
                                break;
                            }
                        }
                    }
                    Some(crate::S2C_SNAPSHOT) if data.len() > crate::SNAPSHOT_HEADER => {
                        if let Sight::Shared(rig) = &sight {
                            // One connection feeds the room; everybody
                            // else's copy of the same truth is dropped here,
                            // unread, which is most of what a snapshot used
                            // to cost this process.
                            let _ = rig.pen.compare_exchange(
                                0, me, Ordering::Relaxed, Ordering::Relaxed);
                            if rig.pen.load(Ordering::Relaxed) == me {
                                rig.lock_world()
                                    .apply_snapshot(&data[crate::SNAPSHOT_HEADER..]);
                            }
                        }
                    }
                    Some(crate::S2C_YIELD) => break,
                    Some(crate::S2C_DENIED) => {
                        if data.get(1) == Some(&crate::DENY_RATED_SESSION) {
                            busy.store(true, Ordering::Relaxed);
                        }
                        println!("{addr} refused {}: {}", who.name,
                                 String::from_utf8_lossy(&data[2.min(data.len())..]));
                        break;
                    }
                    _ => {}
                }
            }
            ctl = ctl_rx.recv() => {
                match ctl {
                    Some(Ctl::Frame(m)) => {
                        if sink.send(Message::Binary(m)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ctl::Leave) | None => break,
                }
            }
            _ = quiet.tick() => {
                if heard.elapsed().as_millis() as u64 > QUIET_MS {
                    break;
                }
            }
        }
    }

    // The second-room pilot, flown the way every pilot used to be: its own
    // world, its own clock, its own hands. Correct rather than fast, and
    // rare enough that fast does not matter.
    if let Some((mut w, mut b)) = go_private {
        let mut buttons: u16;
        let mut sent: Option<u16> = None;
        let mut sent_at = 0u32;
        let mut lifecycle = 1u32;
        let mut asked: Option<std::time::Instant> = None;
        let mut ticker = tokio::time::interval(std::time::Duration::from_micros(10_000));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                biased;
                msg = source.next() => {
                    let Some(Ok(Message::Binary(data))) = msg else { break };
                    heard = std::time::Instant::now();
                    if data.is_empty() {
                        continue;
                    }
                    match data.first().copied() {
                        Some(crate::S2C_SETTINGS) => {
                            if data.len() >= 5 {
                                w.apply_settings(&data[5..]);
                            }
                        }
                        Some(crate::S2C_WELCOME) if data.len() >= 16 => {
                            lifecycle = u32::from_le_bytes(data[2..6].try_into().unwrap());
                        }
                        Some(crate::S2C_SNAPSHOT) if data.len() > crate::SNAPSHOT_HEADER => {
                            w.apply_snapshot(&data[crate::SNAPSHOT_HEADER..]);
                        }
                        Some(crate::S2C_YIELD) => break,
                        _ => {}
                    }
                }
                _ = ticker.tick() => {
                    if heard.elapsed().as_millis() as u64 > QUIET_MS {
                        break;
                    }
                    if ship as usize >= sim::MAX_SHIPS {
                        break;
                    }
                    let own = ai::own(&w, ship);
                    let fresh = b.looks_due().then(|| ai::scan(&w, ship));
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
                                     who.name, since.elapsed().as_secs_f32());
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
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn a_bot_arrives_under_its_own_name() {
        let msg = join_msg(3, "vX-9", "");
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
        let msg = join_msg(0, "Halcyon", "a.session.token");
        assert_eq!(name_as_the_arena_reads_it(&msg), "Halcyon");
    }

    #[test]
    fn the_header_is_the_length_the_arena_expects() {
        let msg = join_msg(0, "", "");
        assert_eq!(
            msg.len(),
            crate::C2S_JOIN_HEADER,
            "an empty name and no token is the header alone"
        );
    }

    #[test]
    fn only_an_authenticated_house_bot_shares_a_world() {
        let house = BotIdentity::House("session-token".into());
        assert!(house.shares_world());
        assert_eq!(house.session(), "session-token");

        let unaccounted = BotIdentity::Unaccounted;
        assert!(!unaccounted.shares_world());
        assert_eq!(unaccounted.session(), "");
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
        let first = ai::individual(0);
        blocked.lock().unwrap().insert(first.name.clone(), 20_000);
        let got = claim(&taken, &blocked, 10_000).unwrap();
        assert_ne!(got.name, first.name);
        assert_eq!(got.name, ai::individual(1).name);
    }
}
