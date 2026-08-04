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
//! One economy inside the process, invisible on the wire: the fifty pilots an
//! arena wants are all being sent the same room, so they predict it in one
//! shared `Rig` rather than fifty private copies. Each connection still joins,
//! receives and answers as an ordinary client; where the bytes land is this
//! process's own business.

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
/// How long a bot that has been asked to leave may take to find a good moment.
/// It waits for a death or for an empty horizon; past this it simply goes.
const YIELD_GRACE_MS: u64 = 10_000;
/// Snapshots stop arriving and nothing else says why. Ten seconds is five
/// hundred missed snapshots, so this only ever fires on a connection that is
/// actually gone.
const QUIET_MS: u64 = 10_000;
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
        self.0.lock().ok()?.insert(key, (Arc::clone(&m), Arc::clone(&n)));
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
struct Rig {
    world: Mutex<sim::World>,
    /// The last buttons each seat sent its arena, read by the pen holder when
    /// it steps. Meaningful only while `seats` says a live pilot is in it.
    buttons: [AtomicU16; sim::MAX_SHIPS],
    /// Which pilot holds each seat, zero for nobody. A claim that finds the
    /// seat taken has found a second room: ship indices are unique within a
    /// room and nothing on the wire says which room a welcome came from, so
    /// the claimer flies a private world rather than somebody else's picture.
    /// No shipped zone opens a second room today; when one does, the honest
    /// fix is a room id in the protocol, and this fallback is what keeps the
    /// population correct rather than fast until then.
    seats: Mutex<[u64; sim::MAX_SHIPS]>,
    /// The pilot applying snapshots and stepping, zero while the role is
    /// open. Taken by compare-and-swap on the tick, released on the way out,
    /// so losing the holder costs the rig one tick of standstill at most.
    pen: AtomicU64,
}

impl Rig {
    fn new(world: sim::World) -> Self {
        Rig {
            world: Mutex::new(world),
            buttons: std::array::from_fn(|_| AtomicU16::new(0)),
            seats: Mutex::new([0; sim::MAX_SHIPS]),
            pen: AtomicU64::new(0),
        }
    }

    /// Take a seat, or refuse it because a live pilot already has it, which is
    /// the second-room signal described on `seats`.
    fn claim(&self, ship: u8, id: u64) -> bool {
        let Ok(mut s) = self.seats.lock() else { return false };
        let seat = &mut s[ship as usize];
        if *seat != 0 && *seat != id {
            return false;
        }
        *seat = id;
        self.buttons[ship as usize].store(0, Ordering::Relaxed);
        true
    }

    /// Give back whatever this pilot held: its seat if it had one, the pen if
    /// it was writing. Safe to call however the flight ended.
    fn release(&self, ship: u8, id: u64) {
        if let Ok(mut s) = self.seats.lock() {
            if s[ship as usize] == id {
                s[ship as usize] = 0;
                self.buttons[ship as usize].store(0, Ordering::Relaxed);
            }
        }
        let _ = self.pen.compare_exchange(id, 0, Ordering::Relaxed, Ordering::Relaxed);
    }

    /// One tick of shared prediction: every seated pilot's last buttons, one
    /// step. The pen holder calls this with the world lock already held.
    fn advance(&self, w: &mut sim::World) {
        let mut inputs = [sim::sim_input { ship: 0, buttons: 0 }; sim::MAX_SHIPS];
        let mut n = 0;
        if let Ok(s) = self.seats.lock() {
            for (i, holder) in s.iter().enumerate() {
                if *holder != 0 {
                    inputs[n] = sim::sim_input {
                        ship: i as u8,
                        buttons: self.buttons[i].load(Ordering::Relaxed),
                    };
                    n += 1;
                }
            }
        }
        w.step(&inputs[..n]);
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
        let rig = Arc::new(Rig::new(sim::World::on_shared_map(key as u32, Arc::clone(map))));
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
    task: tokio::task::JoinHandle<()>,
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
}

pub async fn run() {
    let maps: Arc<Maps> = Arc::default();
    let rigs: Arc<Rigs> = Arc::default();
    // Names in use across the whole fleet. An individual appears in one place at
    // a time, which is what makes its rating the record of one career rather
    // than an average over clones.
    let taken: Arc<Mutex<HashSet<String>>> = Arc::default();
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
        println!("flying at {} arena(s) directly: {}", direct.len(), direct.join(", "));
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
        let asked = futures_util::future::join_all(
            dirs.iter().map(|u| browse(u))
        ).await;
        for (addr, n) in asked.into_iter().flatten() {
            // The most any directory says, because a directory relays only what
            // it observed itself and one may have heard more recently than
            // another.
            let e = want.entry(addr).or_insert(0);
            *e = (*e).max(n);
        }
        let asked = futures_util::future::join_all(
            direct.iter().map(|a| async move { (a.clone(), ask(a).await) })
        ).await;
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
                    let Some(who) = claim(&taken) else { break };
                    let yielding = Arc::new(AtomicBool::new(false));
                    let task = tokio::spawn(fly(
                        addr.clone(),
                        who.clone(),
                        Arc::clone(&maps),
                        Arc::clone(&rigs),
                        Arc::clone(&yielding),
                        Arc::clone(&secrets),
                    ));
                    inst.bots.push(Live {
                        name: who.name,
                        born_ms: now,
                        yielding,
                        task,
                    });
                }
                println!("{addr}: {have} bots, wants {n}; sent {add}");
            } else if have > n {
                // Oldest first among those old enough to go, so a bot that has
                // just arrived is not immediately turned around.
                let mut asked = 0;
                let over = have - n;
                for b in inst.bots.iter() {
                    if asked >= over {
                        break;
                    }
                    if b.yielding.load(Ordering::Relaxed) {
                        asked += 1; // already on its way
                        continue;
                    }
                    if now.saturating_sub(b.born_ms) < MIN_LIFE_MS {
                        continue;
                    }
                    b.yielding.store(true, Ordering::Relaxed);
                    inst.released_ms = now;
                    asked += 1;
                    println!("{addr}: {have} bots, wants {n}; {} stands down", b.name);
                }
            }
        }
    }
}

/// Take the next unused individual. The calibrated nine go first, and after them
/// the roster is generated, so a room asking for fifty-one gets fifty-one
/// distinct pilots rather than the same nine six times over.
fn claim(taken: &Arc<Mutex<HashSet<String>>>) -> Option<ai::RosterEntry> {
    let mut t = taken.lock().ok()?;
    for n in 0..4096 {
        let e = ai::individual(n);
        if t.insert(e.name.clone()) {
            return Some(e);
        }
    }
    None
}

/// Ask a directory what is running, and how many bots each instance wants.
async fn browse(url: &str) -> Vec<(String, u32)> {
    let Some(body) = request(url, directory::STATUS_REQUEST, directory::STATUS_REPLY).await
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
    let body = request(addr, directory::STATUS_REQUEST, directory::STATUS_REPLY).await?;
    serde_json::from_str::<crate::fleet::Status>(&body)
        .ok()
        .map(|s| s.bots_wanted)
}

/// One request, one reply, one closed socket. Both ends of a browse are cheap
/// and neither is worth a held connection: this runs once a second and a
/// directory that is down should cost a failed dial rather than a stuck task.
async fn request(url: &str, ask: u8, expect: u8) -> Option<String> {
    // Short, because this runs on a one second cycle and everything it dials is
    // a process that either answers immediately or is not there. A long dial
    // timeout here would let a dead address hold a cycle open past the next one.
    let deadline = std::time::Duration::from_secs(2);
    let dial = tokio::time::timeout(deadline, tokio_tungstenite::connect_async(url));
    let (mut ws, _) = dial.await.ok()?.ok()?;
    ws.send(Message::Binary(vec![ask])).await.ok()?;
    loop {
        let msg = tokio::time::timeout(deadline, ws.next()).await.ok()??.ok()?;
        if let Message::Binary(b) = msg {
            if b.first() == Some(&expect) && b.len() > 1 {
                let _ = ws.close(None).await;
                return Some(String::from_utf8_lossy(&b[1..]).to_string());
            }
        }
    }
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
/// The session token for one roster individual, claiming its account the first
/// time and logging in whenever a token is wanted.
///
/// An individual is one account and one career, per docs/design/ai-players.md,
/// so the account is claimed by name and the meta-layer hands back the same one
/// however many times this process restarts. The secret is kept in memory for
/// the life of the process, which is what stops a restart loop minting a
/// credential row per attempt.
async fn bot_token(who: &str, secrets: &Mutex<HashMap<String, String>>) -> Option<String> {
    let meta = std::env::var("VW_META").unwrap_or_default();
    let pool = std::env::var("VW_TOKEN").unwrap_or_default();
    if meta.is_empty() || pool.is_empty() {
        // A deployment without accounts. The bot still flies, declared and
        // labeled as somebody's bot, and rates nothing.
        return None;
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
                .map_err(|e| println!("bots: no account for {who}: {e}"))
                .ok()?;
            let s = reply.get("secret")?.as_str()?.to_string();
            if let Ok(mut m) = secrets.lock() {
                m.insert(who.to_string(), s.clone());
            }
            s
        }
    };
    let body = serde_json::json!({ "secret": secret }).to_string();
    let reply = crate::meta::call(&meta, "/v1/login", &body)
        .await
        .map_err(|e| println!("bots: {who} cannot log in: {e}"))
        .ok()?;
    Some(reply.get("token")?.as_str()?.to_string())
}

async fn fly(addr: String, who: ai::RosterEntry, maps: Arc<Maps>, rigs: Arc<Rigs>,
             yielding: Arc<AtomicBool>, secrets: Arc<Mutex<HashMap<String, String>>>) {
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
    let (mut sink, mut source) = ws.split();

    // A bot picks its zone the way a player who typed an address does: it takes
    // whatever the instance is running. It was sent here by a browse of that
    // very instance, and a wrong-zone refusal would only tell it what it already
    // knows -- that the arena changed game underneath the browse.
    // Ours, and able to prove it. A house bot flies on a bot account, which is
    // what lets one of them anchor the ladder and what tells a player which
    // bots are the fleet's own. Without a meta-layer it flies declared but
    // unaccounted, which reads as somebody else's bot, honestly enough.
    let session = bot_token(&who.name, &secrets).await.unwrap_or_default();
    let name = who.name.as_bytes();
    let mut join = vec![crate::C2S_JOIN, who.class.min(7), crate::CLIENT_PROTOCOL,
                        crate::JOIN_BOT, 0, name.len().min(255) as u8];
    join.extend_from_slice(name);
    join.extend_from_slice(session.as_bytes());
    if sink.send(Message::Binary(join)).await.is_err() {
        return;
    }

    // The two ways this pilot can see the room: the rig it shares with every
    // other pilot on this arena, or a private world of its own when a seat
    // collision says the rig is describing a different room than its own.
    enum Sight {
        Dark,
        Shared(Arc<Rig>),
        Private(sim::World),
    }
    let me = PILOT_ID.fetch_add(1, Ordering::Relaxed);
    let mut sight = Sight::Dark;
    // Held back for the private fallback, which is built at welcome, after
    // the map and the settings have already gone by.
    let mut map: Option<Arc<sim::sim_map>> = None;
    let mut cfg_bytes: Vec<u8> = Vec::new();
    let mut route: Option<Arc<nav::Nav>> = None;
    let mut brain: Option<ai::Bot> = None;
    let mut ship: u8 = 0;
    let mut buttons: u16 = 0;
    let mut sent: Option<u16> = None;
    let mut ticker = tokio::time::interval(std::time::Duration::from_micros(10_000));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut asked: Option<std::time::Instant> = None;
    // Checked on the tick rather than by wrapping the read in a timeout: the
    // two arms below race every ten milliseconds, and a timeout rebuilt on each
    // pass of that race is a timeout that never expires.
    let mut heard = std::time::Instant::now();

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
                        let Some(rig) = rigs.get(&addr, key, &m) else { break };
                        sight = Sight::Shared(rig);
                        map = Some(m);
                    }
                    Some(crate::S2C_SETTINGS) => {
                        cfg_bytes = data[1..].to_vec();
                        // Every pilot applies on arrival. The bytes are the
                        // zone's one answer, so on the shared rig this is the
                        // same settings written again, which is idempotent.
                        match &mut sight {
                            Sight::Shared(rig) => {
                                if let Ok(mut w) = rig.world.lock() {
                                    w.apply_settings(&cfg_bytes);
                                }
                            }
                            Sight::Private(w) => {
                                w.apply_settings(&cfg_bytes);
                            }
                            Sight::Dark => {}
                        }
                    }
                    Some(crate::S2C_WELCOME) if data.len() >= 2 => {
                        ship = data[1];
                        let mut b = ai::Bot::new(ship, who.skill);
                        // Luck of its own, so two pilots of one skill in one
                        // room do not fly the same match.
                        b.reseed(fingerprint(who.name.as_bytes()) as u32);
                        brain = Some(b);
                        if let Sight::Shared(rig) = &sight {
                            if !rig.claim(ship, me) {
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
                                sight = Sight::Private(w);
                            }
                        }
                    }
                    Some(crate::S2C_SNAPSHOT) if data.len() > 6 => {
                        match &mut sight {
                            // The pen holder applies for the room; everybody
                            // else's copy of the same truth is dropped here,
                            // unread, which is most of what a snapshot used to
                            // cost this process.
                            Sight::Shared(rig) => {
                                if rig.pen.load(Ordering::Relaxed) == me {
                                    if let Ok(mut w) = rig.world.lock() {
                                        w.apply_snapshot(&data[6..]);
                                    }
                                }
                            }
                            Sight::Private(w) => {
                                w.apply_snapshot(&data[6..]);
                            }
                            Sight::Dark => {}
                        }
                    }
                    Some(crate::S2C_YIELD) => break,
                    Some(crate::S2C_DENIED) => {
                        println!("{addr} refused {}: {}", who.name,
                                 String::from_utf8_lossy(&data[2.min(data.len())..]));
                        break;
                    }
                    _ => {}
                }
            }
            _ = ticker.tick() => {
                if heard.elapsed().as_millis() as u64 > QUIET_MS {
                    break;
                }
                let Some(b) = brain.as_mut() else { continue };
                if ship as usize >= sim::MAX_SHIPS {
                    break;
                }
                // One pass against the current picture, whichever kind this
                // pilot holds. The look happens here too, inside the same
                // lock, so a scan and the step it reads cannot interleave.
                let (own, fresh, tick) = match &mut sight {
                    Sight::Shared(rig) => {
                        // The pen is claimed on the tick rather than at
                        // welcome, so whoever is flying picks it up within
                        // 10 ms of the last holder leaving.
                        let _ = rig.pen.compare_exchange(0, me, Ordering::Relaxed, Ordering::Relaxed);
                        let Ok(mut w) = rig.world.lock() else { break };
                        if rig.pen.load(Ordering::Relaxed) == me {
                            rig.advance(&mut w);
                        }
                        let own = ai::own(&w, ship);
                        let fresh = b.looks_due().then(|| ai::scan(&w, ship));
                        (own, fresh, w.state.tick)
                    }
                    Sight::Private(w) => {
                        let own = ai::own(w, ship);
                        let fresh = b.looks_due().then(|| ai::scan(w, ship));
                        (own, fresh, w.state.tick)
                    }
                    Sight::Dark => continue,
                };
                // Asked to stand down, and looking for the moment. A pilot that
                // is dead is between fights, and one with nobody in sight is
                // not in one; either will do, and past the grace it simply
                // goes. Both tests are the bot's own view, which is the only
                // one it has.
                if yielding.load(Ordering::Relaxed) {
                    let since = *asked.get_or_insert_with(std::time::Instant::now);
                    let quiet = !own.alive || b.horizon_clear();
                    if quiet || since.elapsed().as_millis() as u64 > YIELD_GRACE_MS {
                        break;
                    }
                }
                buttons = match route.as_deref() {
                    Some(r) => b.think(&own, r, fresh),
                    None => 0,
                };
                if sent != Some(buttons) {
                    let mut m = vec![crate::C2S_INPUT];
                    m.extend_from_slice(&buttons.to_le_bytes());
                    // The tick this input produces, not the last one finished,
                    // which is what `net.lua` stamps and what the arena's queue
                    // reads: an input naming a tick waits for it. Stamping the
                    // completed tick instead would land every bot's input one
                    // tick early, and a bot walking a different path through the
                    // wire than a player does is half the point given away.
                    m.extend_from_slice(&(tick + 1).to_le_bytes());
                    if sink.send(Message::Binary(m)).await.is_err() {
                        break;
                    }
                    sent = Some(buttons);
                }
                // Forward on our own input, so a later tick's `own` is this
                // tick's answer rather than the last snapshot's. The arena's
                // next snapshot overwrites all of it, which is the point: a bot
                // predicts to stay steerable and defers to the server for
                // everything that matters. On the rig the forwarding is a note
                // for the pen holder, whose next step carries it.
                match &mut sight {
                    Sight::Shared(rig) => {
                        rig.buttons[ship as usize].store(buttons, Ordering::Relaxed);
                    }
                    Sight::Private(w) => {
                        w.step(&[sim::sim_input { ship, buttons }]);
                    }
                    Sight::Dark => {}
                }
            }
        }
    }
    // Whatever was held against the rig goes back: the seat, and the pen if
    // this pilot was the one writing. The next pilot's tick picks the pen up.
    if let Sight::Shared(rig) = &sight {
        rig.release(ship, me);
    }
    // Bounded, because a close waits for the peer's reply and nothing polls the
    // read half any more. The supervisor counts a bot as present until its task
    // ends, so a close that hangs is a seat the room has already given up and
    // the population has not noticed.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), sink.close()).await;
}
