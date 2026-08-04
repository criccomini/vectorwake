//! vectorwake zone server.
//!
//! One arena, ticking at 100 Hz, authoritative over everything that matters.
//! Clients send inputs and nothing else; positions, damage, deaths, and prize
//! pickups are outputs of `sim_step` and cannot be asserted from outside.
//!
//! Transport is WebSocket, which every browser can speak. UDP for native
//! clients is the same message format on a different socket and is not built
//! yet; see docs/architecture/networking.md.

mod ai;
mod admin;
mod bots;
mod calibrate;
mod catalog;
mod config;
mod directory;
mod drill;
mod fleet;
mod meta;
mod modes;
mod nav;
mod rating;
mod select;
mod sim;
mod spool;
mod token;

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

const TICK_HZ: u64 = 100;
const SNAPSHOT_EVERY: u32 = 5; // 20 Hz
/// How far from a player a prize has to be before it is left out of that
/// player's snapshot, in Q8 pixels. 256 tiles.
///
/// Four times the radar's reach, which is the furthest a client can see one
/// by any means. A hull tops out at 490 px/s and a snapshot period is 50 ms,
/// so a ship covers 24 px between snapshots against 3136 px of margin beyond
/// the radar -- the boundary is not somewhere a player can arrive at.
const PRIZE_INTEREST: i32 = 256 * 16 * 256;
/// Humans a zone admits when its file says nothing. The room may hold more
/// seats than this: `max_ships` sizes the room, and this bounds how many of its
/// seats people get, which is what leaves room for the bot roster.
const DEFAULT_MAX_PLAYERS: usize = 16;

// Client to server
/// `[C2S_JOIN, class, protocol, flags, zone_len, name_len] zone name token`
///
/// The zone is what the player picked out of a browse list, and it is checked
/// rather than assumed: an instance is free to change zone the moment its last
/// player leaves, so a client can arrive at an address that no longer serves the
/// game it chose. Empty means "whatever you are running", which is what somebody
/// typing an address directly means.
///
/// The token is a session token from the meta-layer, and it runs to the end of
/// the message because it is the only variable-length field left without a
/// length. It may be empty: a client that has never reached the meta-layer, or
/// reached it while it was down, still flies. It just flies as a guest whose
/// name this room believes and whose rating goes nowhere.
const C2S_JOIN: u8 = 1;
const C2S_INPUT: u8 = 2;
const C2S_SHIP: u8 = 5;
/// The three asks a pilot can make about sides, all of them requests rather
/// than assertions: cross to a side, found one, invite somebody to mine. None
/// is answered directly. The team list that follows says what happened, the
/// same way a snapshot answers a hull change. See design/teams.md.
const C2S_TEAM: u8 = 6;
const C2S_FOUND: u8 = 7;
const C2S_INVITE: u8 = 8;
/// This client is a bot and says so. Everything that follows from the
/// declaration is in the arena's favour, which is why a well-behaved bot sets
/// it: a declared bot is labeled in the roster, sits outside the human cap, and
/// is asked to leave before a human is ever refused a seat. Anybody may set it.
/// See docs/architecture/ai-runtime.md.
const JOIN_BOT: u8 = 1;
/// The client wire, which versions separately from the arena-to-directory one in
/// `fleet.rs`: they change for different reasons and are spoken by different
/// programs. Bump when a message's layout changes, so a stale build is told its
/// build is stale rather than left to misparse a snapshot.
const CLIENT_PROTOCOL: u8 = 5;

/// Whether this arena files its rated exchanges with the meta-layer.
///
/// On unless `VW_REPORT` says otherwise. That way round because reporting is
/// what the ladder is made of, and a deployment that quietly kept its results
/// to itself would be a worse surprise than one that quietly sent them: the
/// off switch has to be something an operator wrote down.
///
/// Read per call rather than cached. It is an environment variable, so it
/// cannot change under a running process, and reading it costs nothing next to
/// the clock this is on.
fn reporting_enabled() -> bool {
    reporting_from(std::env::var("VW_REPORT").ok().as_deref())
}

/// The reading, split out from the environment so it can be tested without a
/// test reaching into a variable the whole process shares.
fn reporting_from(v: Option<&str>) -> bool {
    match v {
        Some(s) => !matches!(
            s.trim().to_ascii_lowercase().as_str(),
            "0" | "off" | "false" | "no"
        ),
        None => true,
    }
}
/// The biggest message a client may send. The largest legitimate one is a join:
/// tag, class, protocol, a zone name and a call sign. 8 KB is two orders of
/// magnitude of headroom.
const C2S_MAX: usize = 8 * 1024;
/// Asked by the directory, and by any client that wants to know what a zone
/// is before committing to it. Answerable without joining.
const C2S_STATUS: u8 = directory::STATUS_REQUEST;

// Server to client
const S2C_WELCOME: u8 = 1;
const S2C_SNAPSHOT: u8 = 2;
const S2C_ROSTER: u8 = 3;
const S2C_KILL: u8 = 4;
const S2C_BANNER: u8 = 5;
const S2C_ZONE: u8 = 6;
const S2C_DENIED: u8 = 7;
/// Why a join was refused. Three of these mean "try another instance" and two
/// mean "stop trying", which is the distinction a client cannot make from a
/// sentence. See the refusal table in docs/architecture/zones-and-arenas.md.
const DENY_FULL: u8 = 1;
const DENY_DRAINING: u8 = 2;
const DENY_WRONG_ZONE: u8 = 3;
const DENY_BANNED: u8 = 4;
const DENY_VERSION: u8 = 5;
const S2C_STATUS: u8 = directory::STATUS_REPLY;
/// The map, run-length encoded, sent before the first snapshot. A client
/// predicts collisions locally, so it needs the room before it needs anyone
/// in it.
const S2C_MAP: u8 = 9;
/// The tuning, sent straight after the map and again whenever an operator
/// reloads the zone file. A client that predicts on its own compiled
/// defaults is predicting a different game the moment a zone tunes anything.
const S2C_SETTINGS: u8 = 10;
/// Your seat is wanted. Sent to a declared bot when a human needs the room it
/// is standing in, and to every bot when the instance starts draining.
///
/// The seat is already gone by the time this arrives: it is a courtesy, not a
/// request, so that a bot leaves cleanly rather than being deduced from a
/// simulation it is no longer in. A client that ignores it holds a socket and
/// nothing else.
const S2C_YIELD: u8 = 11;
/// Every side in the room, what it is called, who is on it, and whether this
/// particular client may enter it. Built per recipient rather than broadcast
/// as one buffer, because the last of those is a different answer for every
/// pilot: a private side is a door only the invited can see open.
const S2C_TEAMS: u8 = 12;

struct Player {
    ship: u8,
    /// What this pilot is currently holding down, which is what a tick with no
    /// scheduled input uses. A held key is the common case, so a lost packet
    /// reads as a continued hold rather than a stutter.
    buttons: u16,
    /// Inputs stamped for ticks this arena has not reached yet, oldest first.
    ///
    /// A client that runs its clock ahead of ours sends an input before the
    /// tick it belongs to, and this is where it waits. Both ends then apply the
    /// same buttons on the same tick number, which is the whole point: the
    /// alternative, taking each packet as the current state on arrival, means
    /// the pilot brakes several ticks before the server does and sees itself
    /// corrected back into motion.
    pending: std::collections::BTreeMap<u32, u16>,
    /// Highest input tick this client has sent, echoed back in snapshots so
    /// it knows how far its prediction has been confirmed, and so it can
    /// measure how late its inputs are arriving.
    last_input_tick: u32,
    name: String,
    /// What this pilot's rating movement is filed under. See `Seat::rid`.
    rid: rating::Id,
    /// Whether this client declared itself a bot at join. It decides three
    /// things and nothing else: the roster label, whether the seat counts
    /// against the human cap, and whether the seat can be taken away.
    bot: bool,
    tx: mpsc::Sender<Message>,
}

/// How far ahead of the arena's own tick a scheduled input may be stamped.
///
/// A second at 100 Hz, which is far more lead than a playable connection needs
/// and short enough that a client cannot queue up a minute of flying. Anything
/// past it is clamped rather than refused, because a clock that has drifted is
/// a client to correct, not one to disconnect.
const INPUT_LEAD_MAX: u32 = 100;

/// Scheduled inputs held per player. At one input per tick and a lead well
/// under the cap this is never near full; it exists so a client that floods
/// cannot grow the arena's memory.
const INPUT_QUEUE_MAX: usize = 128;

impl Player {
    /// File an input for the tick it names.
    ///
    /// An input for a tick already simulated is applied now instead. That is
    /// the old behaviour and the right fallback: the server must not rewind the
    /// room to honour one late packet, which is the lag compensation
    /// docs/architecture/networking.md rules out, and a client with no lead at
    /// all keeps working exactly as it did.
    fn schedule(&mut self, tick: u32, buttons: u16, now: u32) {
        // Clamp before recording. `last_input_tick` is echoed back so a client
        // can measure how late its inputs are arriving, so it has to be a tick
        // this arena agreed to: a client stamping u32::MAX would otherwise pin
        // its own echo at u32::MAX forever and steer its clock off the readout.
        // That only ever hurts the client that did it, which is exactly why it
        // would have been found late and by somebody confused.
        //
        // Saturating, because `now` is a tick counter and a room that has been
        // up for 497 days reaches u32::MAX. A plain add there panics in debug
        // and wraps in release, and a wrapped ceiling clamps every input to a
        // tick in the distant past. This project has already shipped one
        // overflow that release builds swallowed and debug builds refused to
        // start on.
        let tick = tick.min(now.saturating_add(INPUT_LEAD_MAX));
        self.last_input_tick = self.last_input_tick.max(tick);
        if tick <= now {
            self.buttons = buttons;
            return;
        }
        // Keyed by tick, so a repeat of one already spoken for replaces it and
        // the order is the map's rather than the arrival order's. That matters
        // because the clamp above can lower a tick, and a queue that assumed
        // arrival order would then hand out inputs out of sequence.
        self.pending.insert(tick, buttons);
        while self.pending.len() > INPUT_QUEUE_MAX {
            let oldest = *self.pending.keys().next().expect("non-empty");
            self.pending.remove(&oldest);
        }
    }

    /// What this pilot is holding on `now`: the newest input scheduled for this
    /// tick or any before it, and otherwise whatever they were already holding.
    fn buttons_at(&mut self, now: u32) -> u16 {
        while let Some((&t, &b)) = self.pending.iter().next() {
            if t > now {
                break;
            }
            self.buttons = b;
            self.pending.remove(&t);
        }
        self.buttons
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
const OUT_QUEUE: usize = 40;

/// Feed one tick's damage into the ledger and hand back the deaths it
/// contained. Shared by the live arena and the offline calibration
/// tournament, so the two cannot disagree about what an event means.
fn ingest_damage(
    world: &sim::World,
    rating: &mut rating::Rating,
    name_of: &dyn Fn(u8) -> String,
) -> Vec<(u8, u8, i32)> {
    let tick = world.state.tick;
    let ev = &*world.events;
    let mut deaths = Vec::new();
    for i in 0..ev.count as usize {
        let e = ev.e[i];
        match e.etype {
            sim::EV_HIT => {
                let (victim, attacker) = (e.a as usize, e.b as usize);
                if victim < sim::MAX_SHIPS && attacker < sim::MAX_SHIPS {
                    let same =
                        world.state.ships[victim].team == world.state.ships[attacker].team;
                    rating.damage(tick, &name_of(e.a), &name_of(e.b), e.v, same);
                }
            }
            // The event's value is what the kill paid, and it travels to the
            // clients: the feed is drawn from this message rather than from
            // each client's own prediction, which used to print the same
            // death once per rollback that revived and re-killed the victim.
            sim::EV_DEATH => deaths.push((e.a, e.b, e.v)),
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
struct Team {
    name: String,
    public: bool,
}

/// roster is allowed to say they are, and what their rating belongs to.
#[derive(Clone, Debug, PartialEq)]
struct Seat {
    name: String,
    /// Declared at join. Still decides the human cap and eviction, as before.
    bot: bool,
    /// `token::Label` as a byte, derived from the account rather than asserted
    /// by the client, and sent to every other pilot in the room.
    label: u8,
    /// Who the rating movement belongs to. An account id where there is one,
    /// and the call sign where there is not, which is what a pilot flying
    /// against a deployment with no meta-layer gets.
    rid: rating::Id,
    /// Present only with a verified token. No account means nothing durable is
    /// written for this pilot: they are rated inside the room and forgotten
    /// when it ends.
    account: Option<u64>,
    /// What the token said this pilot's rating was, per class, at the moment
    /// it was minted. This is how a career crosses zones without an arena
    /// asking anybody anything.
    carried: Option<Vec<token::ClassRating>>,
}

impl Seat {
    /// A pilot with no account. This is what a deployment running without a
    /// meta-layer produces for everybody, and what a test wants when the thing
    /// under test is seats rather than identity.
    fn guest(name: impl Into<String>, bot: bool) -> Seat {
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
        }
    }
}

/// The rating id for an account. Prefixed so it can never collide with a call
/// sign, which is the other thing that lands in this namespace.
fn account_rid(account: u64) -> String {
    format!("a{account}")
}

struct Arena {
    world: sim::World,
    /// Everybody connected, humans and bots alike. There is no separate bot
    /// list: a bot is a client, so it is a row here with a flag on it, and
    /// nothing in the tick can tell the two apart.
    players: HashMap<u64, Player>,
    names: HashMap<u8, Seat>,
    /// Where rated events go on their way out of this process. Shared with
    /// every other room here, because the spool is a property of the process
    /// and its disk rather than of a room.
    spool: std::sync::Arc<std::sync::Mutex<spool::Spool>>,
    /// Rating id to account, for the pilots in this room that have one.
    ///
    /// It outlives the seat on purpose. A pilot who leaves can still appear as
    /// a contributor to somebody else's death a moment later, since leaving
    /// clears their own ledger and not their credit in anybody else's, and an
    /// event that loses that contributor loses the rating with it.
    accounts: HashMap<rating::Id, u64>,
    next_id: u64,
    rating: rating::Rating,
    mode: Box<dyn modes::Mode>,
    banner: String,
    finished: bool,
    /// Every side this room currently holds, by the byte the simulation knows
    /// it as. The zone's own come first and outlive every round; the rest are
    /// private, founded by players, and removed when their last member goes.
    /// See design/teams.md.
    teams: BTreeMap<u8, Team>,
    /// How many of the zone's teams are its own, which is the count a mode
    /// scores over. Private teams take bytes from here up and can never win a
    /// flag round.
    public_teams: u8,
    /// The three caps that are the whole of the team policy. There is no
    /// balance rule beyond them, so the only refusal a player can meet is a
    /// full team.
    max_teams: u8,
    max_humans_per_team: u16,
    max_bots_per_team: u16,
    /// Standing invitations, by the ship they were extended to. A private team
    /// admits nobody else. Cleared with the seat, because a seat is furniture
    /// and the next occupant was invited to nothing.
    invites: HashMap<u8, std::collections::HashSet<u8>>,
    /// Where the next founded side takes its name from. It only moves forward,
    /// so leaving a side and starting another hands out a different word rather
    /// than the one the reaper just freed.
    name_cursor: usize,
    /// The share of this room's seats the bot server is asked to keep filled.
    /// The arena does not fill anything itself; it publishes the count it would
    /// like and the bot server supplies it, per decision 29.
    bot_fill: f32,
}

impl Arena {
    /// Apply the operator's tuning over a fresh baseline, and report anything
    /// the file asked for that could not be done.
    ///
    /// Rebuilding first is what makes a reload mean the file as it stands
    /// rather than the file plus everything it has ever said: a deleted line
    /// used to stay in force until a restart, and a weapon block would append
    /// another row every time the file was saved.
    fn apply_config(world: &mut sim::World, c: &config::ArenaConfig) -> Vec<String> {
        let mut warn = Vec::new();
        world.reset_settings();
        // The room, and the shape of the space in it. Every one of these is
        // absent-means-baseline rather than zero-means-baseline, because zero
        // is a legal value for most of them: a bounce of zero is a wall that
        // eats everything that hits it, and a door period of zero is a zone
        // whose doors never open.
        if let Some(v) = c.bounce { world.cfg.bounce = v; }
        if let Some(v) = c.friction { world.cfg.friction = v; }
        if let Some(v) = c.respawn_delay { world.cfg.respawn_delay = v; }
        // The core clamps this to SIM_MAX_SHIPS and reads zero as the ceiling,
        // so a zone asking for more than the array holds gets the array rather
        // than an overflow.
        if let Some(v) = c.max_ships { world.cfg.max_ships = v; }
        if let Some(v) = c.prize_delay { world.cfg.prize_delay = v; }
        if let Some(v) = c.prize_max { world.cfg.prize_max = v; }
        if let Some(v) = c.prize_life { world.cfg.prize_life = v; }
        if let Some(v) = c.prize_radius { world.cfg.prize_radius = v * 256; }
        if let Some(v) = c.prize_lo { world.cfg.prize_lo = v; }
        if let Some(v) = c.prize_hi { world.cfg.prize_hi = v; }
        if let Some(v) = c.flag_radius { world.cfg.flag_radius = v * 256; }
        if let Some(v) = c.flag_drop_cooldown { world.cfg.flag_drop_cooldown = v; }
        if let Some(v) = c.door_period { world.cfg.door_period = v; }
        if let Some(v) = c.door_open { world.cfg.door_open = v; }
        if let Some(v) = c.wormhole_pull {
            world.cfg.wormhole_pull = unsafe { sim::sim_units_speed(v) };
        }
        if let Some(v) = c.wormhole_range { world.cfg.wormhole_range = v * 256; }

        // Weapons are named here and numbered in the core. The baseline
        // built one gun and one bomb per hull, so those get the names an
        // operator would guess -- `apex-gun`, `anvil-bomb` -- and anything
        // else in the file is a weapon that did not exist before.
        // A hull's trigger is a ladder now, so every rung gets a name: the
        // first is `apex-gun` and the ones above it are `apex-gun-2` and up,
        // which reads as the level it is.
        let mut named: Vec<(String, u8)> = Vec::new();
        for (i, hull) in ai::CLASS_NAMES.iter().enumerate() {
            let hull: &str = hull;
            let cls = world.cfg.classes[i];
            for (t, trig) in ["gun", "bomb"].iter().enumerate() {
                for (rung, &pat) in cls.trigger[t].iter().enumerate() {
                    if pat == sim::NO_PATTERN { break }
                    let n = if rung == 0 {
                        format!("{}-{trig}", hull.to_lowercase())
                    } else {
                        format!("{}-{trig}-{}", hull.to_lowercase(), rung + 1)
                    };
                    named.push((n, pat));
                }
            }
        }
        // And the weapons that belong to a slot in the settings rather than to
        // a hull: the four charges, and what each rung of shrapnel breaks
        // into. Without names those were the only weapons in the zone an
        // operator could not touch -- the repel's own radius was ours and
        // nobody else's.
        for (name, pat) in Arena::slots(world) {
            if pat != sim::NO_PATTERN { named.push((name, pat)); }
        }
        if let Some(v) = c.rust { world.cfg.rust_chance = v.min(1000); }
        if let Some(v) = c.spawn_prizes { world.cfg.spawn_prizes = v; }
        if let Some(v) = c.bounty_per_kill { world.cfg.bounty_per_kill = v; }
        if let Some(v) = c.points_per_flag { world.cfg.points_per_flag = v; }
        if let Some(v) = c.multi_energy { world.cfg.mod_multi_energy = v; }
        if let Some(v) = c.multi_delay { world.cfg.mod_multi_delay = v; }
        for (name, v) in &c.prize_weight {
            match Arena::prize_index(name) {
                Some(i) => world.cfg.prize_weight[i] = *v,
                None => warn.push(format!("\"{name}\" is not a prize")),
            }
        }
        // What a rung of each add-on is worth, before any hull is told which
        // ones it may hold.
        for (name, v) in &c.mod_step {
            match Arena::mod_index(name) {
                Some(m) => world.cfg.mod_step[m] = match m {
                    sim::MOD_PROX => v * 256,               // px
                    sim::MOD_PUSH => unsafe { sim::sim_units_speed(*v) },
                    _ => *v,
                },
                None => warn.push(format!("\"{name}\" is not an add-on")),
            }
        }
        if let Some(v) = c.mod_spread {
            world.cfg.mod_spread = ((v as i64 * 65536 / 360) & 0xffff) as u16;
        }
        if let Some(v) = c.prox_step { world.cfg.prox_step = v * 256; }
        if let Some(v) = c.shrap_inactive {
            world.cfg.shrap_inactive = unsafe { sim::sim_units_energy(v) };
        }
        if let Some(v) = c.shrap_inactive_ticks { world.cfg.shrap_inactive_ticks = v; }
        // Two passes, because a splinter may name a weapon written later in
        // the file, or one that does not exist until this pass makes it.
        for w in &c.weapons {
            if w.name.is_empty() {
                warn.push("a weapon with no name is a weapon nothing can point at".into());
                continue;
            }
            if named.iter().any(|(n, _)| *n == w.name) { continue; }
            match world.add_weapon() {
                Some(p) => {
                    // A slot name the baseline left empty -- `charge-3`, say
                    // -- fills that slot as well as making the weapon, so a
                    // zone adding a third charge writes one block rather than
                    // a block and a wiring line that does not exist.
                    Arena::fill_slot(world, &w.name, p);
                    named.push((w.name.clone(), p));
                }
                None => warn.push(format!("no room in the weapon table for \"{}\"", w.name)),
            }
        }
        for w in &c.weapons {
            let Some(&(_, pat)) = named.iter().find(|(n, _)| *n == w.name) else { continue };
            Arena::apply_weapon(world, &named, pat, w, &mut warn);
        }

        for s in &c.ships {
            let Some(idx) = ai::class_index(&s.name) else {
                warn.push(format!("no hull called \"{}\"", s.name));
                continue;
            };
            for (t, (field, want)) in [("gun", &s.gun), ("bomb", &s.bomb)]
                .into_iter().enumerate()
            {
                let Some(want) = want else { continue };
                if want.len() > sim::MAX_RUNGS {
                    warn.push(format!("{}'s {field} ladder is {} rungs and {} is the ceiling",
                                      s.name, want.len(), sim::MAX_RUNGS));
                    continue;
                }
                // The whole ladder, first rung first, and an empty list takes
                // the trigger away -- which is how a hull loses its bomb rack
                // rather than being handed a free one. A name that resolves to
                // nothing leaves the hull's own ladder alone: half-applying it
                // would silently shorten the ladder, and a shortened ladder is
                // a hull that stops levelling for no reason a log would show.
                let mut ladder = [sim::NO_PATTERN; sim::MAX_RUNGS];
                let mut ok = true;
                for (rung, n) in want.iter().enumerate() {
                    match named.iter().find(|(nm, _)| nm == n) {
                        Some(&(_, p)) => ladder[rung] = p,
                        None => {
                            warn.push(format!(
                                "{} has no weapon called \"{n}\" to put on its {field}", s.name));
                            ok = false;
                        }
                    }
                }
                if ok { world.cfg.classes[idx].trigger[t] = ladder; }
            }
            for (t, mods) in [&s.gun_mods, &s.bomb_mods].into_iter().enumerate() {
                if mods.is_empty() { continue }
                let mut packed = 0u16;
                for (name, rungs) in mods {
                    match Arena::mod_index(name) {
                        Some(m) => {
                            let n = (*rungs).min(sim::MOD_MAX) as u16;
                            packed |= n << (m * 2);
                        }
                        None => warn.push(format!("\"{name}\" is not an add-on")),
                    }
                }
                world.cfg.classes[idx].mod_max[t] = packed;
            }
            if s.charges.len() > sim::MAX_CHARGES {
                warn.push(format!("{} names {} charge slots and there are {}",
                                  s.name, s.charges.len(), sim::MAX_CHARGES));
            }
            for (k, &n) in s.charges.iter().take(sim::MAX_CHARGES).enumerate() {
                world.cfg.classes[idx].charge_max[k] = n.min(sim::CHARGE_MAX);
            }
            let cls = &mut world.cfg.classes[idx];
            // Raise the ceiling and the ladder under it moves with it, in
            // proportion. A zone that says nothing keeps the baseline's own
            // numbers exactly, which is the whole point: those are the
            // original's, and it starts a pilot at 62% of top speed but 88%
            // of top thrust and closes a quarter of the speed gap per green
            // against a seventh of the energy gap. Recomputing them from a
            // flat rule -- seventy per cent of the ceiling and an eighth of
            // the gap, which is what stood here -- overwrote all of that on
            // every reload, whether or not the file mentioned the ship.
            fn scaled(old_max: i32, new_max: i32, v: &mut i32) {
                if old_max > 0 && new_max != old_max {
                    *v = ((*v as i64) * new_max as i64 / old_max as i64) as i32;
                }
            }
            unsafe {
                if let Some(v) = s.speed {
                    let m = sim::sim_units_speed(v);
                    scaled(cls.max_speed, m, &mut cls.init_speed);
                    scaled(cls.max_speed, m, &mut cls.up_speed);
                    cls.max_speed = m;
                }
                if let Some(v) = s.thrust {
                    let m = sim::sim_units_thrust(v);
                    scaled(cls.thrust, m, &mut cls.init_thrust);
                    scaled(cls.thrust, m, &mut cls.up_thrust);
                    cls.thrust = m;
                }
                if let Some(v) = s.rotation {
                    let m = sim::sim_units_rotation(v);
                    scaled(cls.rot, m, &mut cls.init_rot);
                    scaled(cls.rot, m, &mut cls.up_rot);
                    cls.rot = m;
                }
                if let Some(v) = s.energy {
                    let m = sim::sim_units_energy(v);
                    scaled(cls.max_energy, m, &mut cls.init_energy);
                    scaled(cls.max_energy, m, &mut cls.up_energy);
                    cls.max_energy = m;
                }
                if let Some(v) = s.recharge {
                    let m = sim::sim_units_recharge(v);
                    scaled(cls.recharge, m, &mut cls.init_recharge);
                    scaled(cls.recharge, m, &mut cls.up_recharge);
                    cls.recharge = m;
                }
                // A floor or a step written out beats the proportion, so a
                // zone can say what the original's files say -- InitialSpeed,
                // UpgradeSpeed and MaximumSpeed as three independent numbers
                // -- rather than only being able to move all three together.
                if let Some(v) = s.initial_speed { cls.init_speed = sim::sim_units_speed(v); }
                if let Some(v) = s.upgrade_speed { cls.up_speed = sim::sim_units_speed(v); }
                if let Some(v) = s.initial_thrust { cls.init_thrust = sim::sim_units_thrust(v); }
                if let Some(v) = s.upgrade_thrust { cls.up_thrust = sim::sim_units_thrust(v); }
                if let Some(v) = s.initial_rotation { cls.init_rot = sim::sim_units_rotation(v); }
                if let Some(v) = s.upgrade_rotation { cls.up_rot = sim::sim_units_rotation(v); }
                if let Some(v) = s.initial_energy { cls.init_energy = sim::sim_units_energy(v); }
                if let Some(v) = s.upgrade_energy { cls.up_energy = sim::sim_units_energy(v); }
                if let Some(v) = s.initial_recharge {
                    cls.init_recharge = sim::sim_units_recharge(v);
                }
                if let Some(v) = s.upgrade_recharge {
                    cls.up_recharge = sim::sim_units_recharge(v);
                }
            }
            if let Some(v) = s.fore { cls.fore = v * 256; }
            if let Some(v) = s.aft { cls.aft = v * 256; }
            if let Some(v) = s.width { cls.halfw = v * 256 / 2; }
        }
        warn
    }

    /// The weapons that belong to a settings slot rather than to a hull, under
    /// the names a zone file reaches them by: `charge-1` through `charge-4`,
    /// and `shrapnel-1` up, one per rung of the add-on.
    ///
    /// Numbered rather than called repel and burst, because what sits in a
    /// charge slot is the zone's own choice and the prize weights name them
    /// the same way.
    fn slots(world: &sim::World) -> Vec<(String, u8)> {
        let mut v = Vec::new();
        for k in 0..sim::MAX_CHARGES {
            v.push((format!("charge-{}", k + 1), world.cfg.charge[k]));
        }
        for k in 1..sim::MAX_RUNGS {
            v.push((format!("shrapnel-{k}"), world.cfg.mod_splinter[k]));
        }
        v
    }

    /// Put a freshly made weapon in the slot its name asks for, if it asks for
    /// one. This is what lets a zone fill a slot the baseline leaves empty.
    fn fill_slot(world: &mut sim::World, name: &str, pat: u8) {
        if let Some(n) = name.strip_prefix("charge-") {
            if let Ok(k) = n.parse::<usize>() {
                if k >= 1 && k <= sim::MAX_CHARGES { world.cfg.charge[k - 1] = pat; }
            }
        } else if let Some(n) = name.strip_prefix("shrapnel-") {
            if let Ok(k) = n.parse::<usize>() {
                if k >= 1 && k < sim::MAX_RUNGS { world.cfg.mod_splinter[k] = pat; }
            }
        }
    }

    /// Prizes are named in a zone file and numbered in the core. The five
    /// stats keep the names the panel shows; a level and an add-on are named
    /// for the trigger they belong to, because both are per trigger.
    fn prize_index(name: &str) -> Option<usize> {
        const STATS: [&str; sim::UP_COUNT] =
            ["energy", "recharge", "speed", "thrust", "rotation"];
        if let Some(i) = STATS.iter().position(|n| n.eq_ignore_ascii_case(name)) {
            return Some(i);
        }
        // Charge slots are named by position, because what sits in each is
        // the zone's own choice: the baseline puts a repel in one and a burst
        // in two, and a zone that fills three and four names those.
        if let Some(n) = name.strip_prefix("charge-") {
            let k: usize = n.parse().ok()?;
            if k >= 1 && k <= sim::MAX_CHARGES {
                return Some(sim::UP_COUNT + sim::TRIG_COUNT
                            + sim::TRIG_COUNT * sim::MOD_COUNT + k - 1);
            }
            return None;
        }
        let (trig, rest) = name.split_once('-')?;
        let t = match trig.to_ascii_lowercase().as_str() {
            "gun" => 0,
            "bomb" => 1,
            _ => return None,
        };
        if rest.eq_ignore_ascii_case("level") {
            return Some(sim::UP_COUNT + t);
        }
        let m = Arena::mod_index(rest)?;
        Some(sim::UP_COUNT + sim::TRIG_COUNT + t * sim::MOD_COUNT + m)
    }

    /// Add-ons are named in a zone file and numbered in the core. The order
    /// is `sim_mod`'s and the names are the ones the design doc uses.
    fn mod_index(name: &str) -> Option<usize> {
        const NAMES: [&str; sim::MOD_COUNT] =
            ["multi", "bounce", "prox", "shrapnel", "freeze", "push"];
        NAMES.iter().position(|n| n.eq_ignore_ascii_case(name))
    }

    /// One weapon block, over whatever that weapon already was. The units are
    /// the ones the rest of the file uses -- px, px/s/10, energy, ticks --
    /// and degrees, because nobody thinks in sixty-five thousandths of a turn.
    fn apply_weapon(world: &mut sim::World, named: &[(String, u8)], pat: u8,
                    w: &config::WeaponConfig, warn: &mut Vec<String>) {
        let spec_idx = world.cfg.patterns[pat as usize].spec as usize;
        let sp = &mut world.cfg.specs[spec_idx];
        unsafe {
            if let Some(v) = w.speed { sp.speed = sim::sim_units_speed(v); }
            if let Some(v) = w.push { sp.push = sim::sim_units_speed(v); }
            if let Some(v) = w.damage { sp.damage = sim::sim_units_energy(v); }
        }
        if let Some(v) = w.push_time { sp.push_time = v; }
        if let Some(v) = w.life { sp.life = v; }
        if let Some(v) = w.bounces { sp.bounces = v; }
        if let Some(v) = w.trigger { sp.trigger = v * 256; }
        if let Some(v) = w.blast { sp.blast = v * 256; }
        if let Some(v) = w.stall { sp.stall = v; }
        if let Some(v) = w.expire_ends { sp.expire_ends = v as u8; }
        if let Some(rule) = &w.on_wall {
            match rule.as_str() {
                "end" => sp.on_wall = 0,
                "bounce" => sp.on_wall = 1,
                "pass" => sp.on_wall = 2,
                other => warn.push(format!(
                    "\"{other}\" is not a wall rule: end, bounce or pass")),
            }
        }
        if let Some(name) = &w.splinter {
            // Naming itself is legal and bounded: the core stops a fragment
            // fragmenting by the generation it carries, not by the table.
            match named.iter().find(|(n, _)| n == name) {
                Some(&(_, p)) => world.cfg.specs[spec_idx].splinter = p,
                None if name.is_empty() => world.cfg.specs[spec_idx].splinter = sim::NO_PATTERN,
                None => warn.push(format!(
                    "\"{}\" splinters into \"{name}\", which is not a weapon", w.name)),
            }
        }
        let p = &mut world.cfg.patterns[pat as usize];
        unsafe {
            if let Some(v) = w.recoil { p.recoil = sim::sim_units_speed(v); }
            if let Some(v) = w.energy { p.energy = sim::sim_units_energy(v); }
        }
        if let Some(v) = w.count { p.count = v; }
        if let Some(v) = w.delay { p.delay = v; }
        if let Some(v) = w.spread {
            p.spacing = ((v as i64 * 65536 / 360) & 0xffff) as u16;
        }
    }

    fn new_from(cfg: &config::ZoneConfig) -> Self {
        let mut a = Arena::new_on_map(&cfg.map);
        // Mode and flags were keys in the file that nobody read: the arena
        // built a four-flag warzone whatever they said. They settle at start
        // rather than on reload, because changing what a round is for while
        // one is being played is not a tuning change.
        //
        // Flags can come down but not up: where they stand is the map's, and
        // the built-in arena puts four in the four quadrants. A zone asking
        // for more is told so rather than quietly given four.
        let placed = a.world.state.flag_count;
        if cfg.arena.flags > placed {
            println!("zone: this map places {placed} flags and the file asks for {}",
                     cfg.arena.flags);
        }
        a.world.state.flag_count = cfg.arena.flags.min(placed);
        a.mode = match cfg.arena.mode.as_str() {
            "arena" | "ffa" => Box::new(modes::FreeForAll),
            _ => Box::new(modes::Warzone::new(a.world.state.flag_count, a.public_teams)),
        };
        for w in Arena::apply_config(&mut a.world, &cfg.arena) {
            println!("zone: {w}");
        }
        a
    }

    /// A zone's own map, if it named one. A map that will not load is
    /// reported and then ignored: a zone that refuses to start because of a
    /// bad file is worse for the people trying to play in it than one that
    /// runs the built-in room and says so.
    fn new_on_map(path: &str) -> Self {
        if path.is_empty() {
            return Arena::new();
        }
        match std::fs::read(path) {
            Ok(bytes) => match sim::World::from_packed(0x5eed, &bytes) {
                Ok(w) => {
                    println!("map {path}: {} bytes", bytes.len());
                    Arena::with_world(w)
                }
                Err(e) => {
                    println!("map {path}: {e}; running the built-in arena");
                    Arena::new()
                }
            },
            Err(e) => {
                println!("map {path}: {e}; running the built-in arena");
                Arena::new()
            }
        }
    }

    fn new() -> Self {
        Self::with_world(sim::World::new(0x5eed))
    }

    fn with_world(world: sim::World) -> Self {
        let mut a = Arena::with_world_bare(world);
        a.mode = Box::new(modes::Warzone::new(4, a.public_teams));
        a.add_default_flags();
        a
    }

    /// An empty room. A catalog zone builds one of these and then decides its
    /// mode, its teams and its population, rather than inheriting a warzone.
    fn with_world_bare(world: sim::World) -> Self {
        Arena {
            world,
            players: HashMap::new(),
            names: HashMap::new(),
            accounts: HashMap::new(),
            // Replaced by the process's own the moment a Zone takes ownership
            // of this room. A room built and never handed one writes nothing,
            // which is the right answer for a room in a test.
            spool: std::sync::Arc::new(std::sync::Mutex::new(spool::Spool::new("/nonexistent"))),
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
            invites: HashMap::new(),
            name_cursor: 0,
            bot_fill: catalog::DEFAULT_BOT_FILL,
        }
    }

    /// Humans in this room. What the player cap, the fill target and the drain
    /// all mean, and none of them mean bots: a room held at four fifths by the
    /// bot server would otherwise read as permanently full, never scale out,
    /// and never finish draining.
    fn humans(&self) -> usize {
        self.players.values().filter(|p| !p.bot).count()
    }

    fn bot_count(&self) -> usize {
        self.players.values().filter(|p| p.bot).count()
    }

    /// How many bots this room would like, and how many more it is short.
    ///
    /// The target is a share of the room rather than of what is free, so bots
    /// give way one for one as people arrive: 51 of 64 seats, then 50 once
    /// somebody joins, then 49. The thirteen seats that are never asked for are
    /// the headroom that keeps an arrival from waiting on a departure.
    fn bot_target(&self) -> usize {
        let seats = unsafe { sim::sim_eff_max_ships(&*self.world.cfg) } as usize;
        (seats as f32 * self.bot_fill).round() as usize
    }

    fn bots_wanted(&self) -> usize {
        self.bot_target().saturating_sub(self.humans())
    }

    /// One flag per quadrant, forty tiles out from the middle, so all four are
    /// on the radar of a pilot standing between them.
    ///
    /// They were three hundred tiles apart, which reads well and made the flag
    /// game unplayable: the shipped War map starts its pilots in a 68-tile box at
    /// the centre, so the nearest flag was two hundred tiles away, past sixty
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
    fn add_default_flags(&mut self) {
        for (tx, ty) in [(472, 472), (552, 472), (472, 552), (552, 552)] {
            self.world.add_flag(tx, ty);
        }
    }

    /// `max_players` is the zone's, which used to be a constant here while the
    /// key in the file was read by nobody. It bounds humans; the room's own size
    /// is `arena.max_ships` and the two are different questions, since a wide
    /// room with a small player cap is a zone that wants mostly bots.
    fn join(&mut self, seat: Seat, class: u8, max_players: usize,
            tx: mpsc::Sender<Message>) -> Option<u64> {
        let name = seat.name.clone();
        let bot = seat.bot;
        // The cap is on people. A declared bot passes it by, which is the whole
        // of what the declaration buys the arena: a zone can hold a wide room
        // mostly full of AI and still admit every human its operator allowed.
        if !bot && self.humans() >= max_players {
            return None;
        }
        // A joining pilot takes the next start in the map's rotation, so
        // arrivals spread across them instead of landing on each other.
        let nth = self.world.state.ship_count as u32;
        let mut ship = self.world.spawn_on_map(class.min(7), 0, nth, 512, 522, 0);
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
        // client's: the emptiest of the zone's own that has room, or a side of
        // their own where the zone names none. Moving is then one selection
        // away in the team list, and only a full side can refuse it.
        let team = self.seat_team(ship, seat.bot);
        // Where a fresh pilot starts, worked out before anything about them is
        // set: a seat is furniture, and its last occupant does not come with
        // it.
        let nth = self.world.state.ship_count as u32;
        let (sx, sy) = self.world.map_spawn(team, nth).unwrap_or((512, 522));
        {
            let sh = &mut self.world.state.ships[ship as usize];
            sh.cls = class.min(7);
            sh.team = team;
            sh.alive = 1;
            // Everything a pilot carries, cleared. This was `up` alone, so a
            // seat handed on kept the last occupant's weapon levels, add-ons,
            // charges, earned bounty and score. Leaving and rejoining is the
            // case that shows it: seats come back in the order they were
            // vacated, so a player is handed their own and the zone reads as
            // having saved their game.
            sh.up = [0; sim::UP_COUNT];
            sh.level = [0; sim::TRIG_COUNT];
            sh.mods = [0; sim::TRIG_COUNT];
            sh.charge = [0; sim::MAX_CHARGES];
            sh.earned = 0;
            sh.points = 0;
            sh.stall = 0;
            sh.repel = 0;
            sh.repel_speed = 0;
            sh.fire_cooldown = 0;
            sh.respawn_at = 0;
            // And where they are, which is the same bug wearing its most
            // obvious face: a pilot who rejoined appeared exactly where they
            // had left off.
            sh.x = sx * sim::TILE_PX * 256;
            sh.y = sy * sim::TILE_PX * 256;
            sh.vx = 0;
            sh.vy = 0;
            sh.spawn_x = sh.x;
            sh.spawn_y = sh.y;
        }
        // And then the zone's opening greens, because the clear above took away
        // everything including what a spawn would have handed out. The core
        // outfits a ship it spawns; a seat inherited from a departing bot is
        // not a spawn, so this asks. Without it a zone with a spawn kit gave
        // one to its bots and to anybody who had died once, and nothing at all
        // to a pilot who had just arrived.
        self.world.outfit(ship as usize);
        // A full bar, asked for as the number it is, and after the class and
        // the greens are set, because the ceiling depends on both. This used to be i32::MAX with a
        // comment saying the core would clamp it; the core clamped it by adding
        // a tick of recharge first, which overflowed, so a joining ship spent
        // its first tick at INT32_MIN energy and one hit from dead. The core no
        // longer allows that, and this no longer asks for it.
        let full = self.world.eff_max_energy(ship as usize);
        self.world.state.ships[ship as usize].energy = full;

        let id = self.next_id;
        self.next_id += 1;
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
        if seat.name == ai::ANCHOR && seat.bot {
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
                buttons: 0,
                pending: Default::default(),
                last_input_tick: 0,
                name,
                rid,
                bot,
                tx,
            },
        );
        Some(id)
    }

    /// Ask the newest bot to leave and hand back its seat.
    ///
    /// Newest rather than any, because a bot that has been in the room a while
    /// is in the middle of something and the one that arrived a moment ago is
    /// not. This is the arena's half of yielding: the graceful half, choosing
    /// the moment after a death and staying out of a fight, belongs to the bot
    /// server, which is watching the same room and is not under time pressure.
    /// This one is, so it takes the cheapest bot it has.
    fn evict_bot(&mut self) -> Option<u8> {
        let (id, ship) = self
            .players
            .iter()
            .filter(|(_, p)| p.bot)
            .max_by_key(|(id, _)| **id)
            .map(|(id, p)| (*id, p.ship))?;
        // Told, then removed. The message is a courtesy that lets a bot close
        // its own socket rather than work out from an empty simulation that it
        // is gone; the seat is taken either way.
        if let Some(p) = self.players.get(&id) {
            println!("seat {ship} taken back from {} for an arriving pilot", p.name);
            let _ = p.tx.try_send(Message::Binary(vec![S2C_YIELD]));
        }
        self.leave(id);
        Some(ship)
    }

    /// Every bot out, which is how a drain finishes. Bots would otherwise hold
    /// a draining instance at four fifths full for ever, and `total_players`
    /// would never reach zero.
    fn evict_all_bots(&mut self) -> usize {
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
            self.leave(*id);
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
    fn free_for_all(&self) -> bool {
        self.public_teams == 0
    }

    /// The zone's own sides, and the caps that are the whole of the policy.
    /// Called once when a room is built from its catalog entry.
    fn set_teams(&mut self, def: &catalog::ZoneDef) {
        self.teams.clear();
        for (i, name) in def.teams.iter().take(254).enumerate() {
            self.teams.insert(i as u8, Team { name: name.clone(), public: true });
        }
        self.public_teams = self.teams.len() as u8;
        self.max_teams = def.max_teams();
        self.max_humans_per_team = def.max_humans_per_team();
        self.max_bots_per_team = def.max_bots_per_team();
        self.invites.clear();
    }

    /// Who is on a side, counted apart because the caps are. `skip` leaves one
    /// ship out, which is what a pilot asking to move needs: they are about to
    /// stop being where they are.
    fn team_census(&self, team: u8, skip: Option<u8>) -> (u16, u16) {
        let (mut humans, mut bots) = (0u16, 0u16);
        for (ship, seat) in &self.names {
            if Some(*ship) == skip {
                continue;
            }
            let sh = &self.world.state.ships[*ship as usize];
            if sh.active == 0 || sh.team != team {
                continue;
            }
            if seat.bot { bots += 1 } else { humans += 1 }
        }
        (humans, bots)
    }

    /// Whether one more of this kind fits on this side.
    fn team_has_room(&self, team: u8, bot: bool, skip: Option<u8>) -> bool {
        let (humans, bots) = self.team_census(team, skip);
        if bot { bots < self.max_bots_per_team } else { humans < self.max_humans_per_team }
    }

    /// Whether this ship may enter this side: it has to exist, have room, and
    /// either be the zone's own or have invited them.
    fn may_join(&self, ship: u8, team: u8, bot: bool) -> bool {
        let Some(t) = self.teams.get(&team) else { return false };
        if self.world.state.ships[ship as usize].team == team {
            return true;
        }
        if !t.public && !self.invites.get(&ship).is_some_and(|s| s.contains(&team)) {
            return false;
        }
        self.team_has_room(team, bot, Some(ship))
    }

    /// The lowest byte no side is using, or none when the room is at its cap.
    fn free_team_byte(&self) -> Option<u8> {
        if self.teams.len() as u16 >= self.max_teams as u16 {
            return None;
        }
        (0u8..255).find(|b| !self.teams.contains_key(b))
    }

    /// Where an arrival is put. The emptiest of the zone's own sides that has
    /// room, which is a default rather than a rule: the list is one selection
    /// away and only a full side can refuse it. A free-for-all has no such
    /// list, so an arrival founds their own side of one.
    fn seat_team(&mut self, joining: u8, bot: bool) -> u8 {
        let mut best: Option<(u8, u16)> = None;
        for t in 0..self.public_teams {
            if !self.team_has_room(t, bot, Some(joining)) {
                continue;
            }
            // Emptiest of your own kind, because that is the emptiness the
            // caps measure and the one an arrival cares about. Counting heads
            // of both kinds together put six bots on one side of a two-team
            // room: every side held no humans, so the first one always won.
            let (humans, bots) = self.team_census(t, Some(joining));
            let n = if bot { bots } else { humans };
            if best.is_none_or(|(_, best_n)| n < best_n) {
                best = Some((t, n));
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

    /// A new private side, named and empty, or none when the room already
    /// holds as many as it may. The founder is not moved here; the caller
    /// does that, because moving is gated and founding is not.
    fn found_team(&mut self, founder: u8) -> Option<u8> {
        let byte = self.free_team_byte()?;
        let name = self.fresh_team_name();
        self.teams.insert(byte, Team { name, public: false });
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
    fn fresh_team_name(&mut self) -> String {
        const WORDS: [&str; 24] = [
            "Anvil Watch", "Black Sill", "Cold Harbour", "Deep Keel",
            "Ember Line", "Far Reach", "Grey Span", "High Trestle",
            "Iron Weir", "Long Lintel", "Mill Race", "North Gantry",
            "Old Causeway", "Pale Arch", "Quarry Gate", "Red Culvert",
            "Salt Pier", "Stone Chord", "Tall Derrick", "Under Span",
            "Verge Works", "West Buttress", "Yard Bell", "Zinc Landing",
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
    fn join_team(&mut self, ship: u8, team: u8) -> bool {
        let bot = self.names.get(&ship).is_some_and(|s| s.bot);
        if !self.may_join(ship, team, bot) {
            self.send_teams(ship);
            return false;
        }
        let moved = self.world.set_ship_team(ship, team);
        if moved {
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
    fn found_and_move(&mut self, ship: u8) -> bool {
        let Some(byte) = self.found_team(ship) else {
            self.send_teams(ship);
            return false;
        };
        if self.join_team(ship, byte) {
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
    fn invite(&mut self, from: u8, to: u8) -> bool {
        let team = self.world.state.ships[from as usize].team;
        let private = self.teams.get(&team).is_some_and(|t| !t.public);
        if !private || from == to || !self.names.contains_key(&to) {
            return false;
        }
        self.invites.entry(to).or_default().insert(team);
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
    fn rebalance_bots(&mut self) {
        if self.public_teams < 2 {
            return;
        }
        let mut count = Vec::new();
        for team in 0..self.public_teams {
            let (humans, bots) = self.team_census(team, None);
            count.push((team, humans + bots, bots));
        }
        let Some(&(fullest, most, bots_there)) =
            count.iter().max_by_key(|(_, n, _)| *n) else { return };
        let Some(&(emptiest, fewest, _)) =
            count.iter().min_by_key(|(_, n, _)| *n) else { return };
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
    fn public_team_names(&self) -> Vec<String> {
        (0..self.public_teams)
            .map(|b| self.teams.get(&b).map(|t| t.name.clone()).unwrap_or_default())
            .collect()
    }

    /// One client's team list, for the answers only they can see.
    fn send_teams(&self, ship: u8) {
        if let Some(p) = self.players.values().find(|p| p.ship == ship) {
            let _ = p.tx.try_send(Message::Binary(self.teams_msg(ship)));
        }
    }

    /// A private side nobody is left on stops existing, and its byte goes back
    /// in the pool. Called wherever a ship stops being on one: leaving, and
    /// crossing to somewhere else.
    fn reap_teams(&mut self) {
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

    /// A pilot goes, and their seat is retired rather than handed on.
    ///
    /// Handing it to a fresh bot is what this used to do, and it was the
    /// in-process director's last reflex: the room refilled itself. It cannot
    /// now, and should not, because filling is the bot server's job and it is
    /// watching. The slot is reusable either way, since the core gives an
    /// inactive one to the next arrival rather than only ever appending.
    fn leave(&mut self, id: u64) {
        if let Some(p) = self.players.remove(&id) {
            self.rating.forget(&p.rid);
            let sh = &mut self.world.state.ships[p.ship as usize];
            sh.active = 0;
            sh.alive = 0;
            self.names.remove(&p.ship);
            // Invitations belong to the pilot, not the seat: the next occupant
            // of this one was invited nowhere. And a private side whose last
            // member just left stops existing.
            self.invites.remove(&p.ship);
            self.reap_teams();
            // Here rather than at each of the several callers -- a quit, an
            // eviction, a kick, a drain -- because every one of them changes
            // who is on what.
            self.broadcast_teams();
        }
    }

    fn tick(&mut self) {
        let mut inputs: Vec<sim::sim_input> = Vec::with_capacity(32);
        // The tick this room is about to run, which is the tick a scheduled
        // input has to name to be applied here. `world.tick()` is the last one
        // completed, so the step below produces the one after it.
        let now = self.world.state.tick + 1;
        // One loop, because there is one kind of pilot. Bots used to be thought
        // for here, between the queue and the step, reading the world directly;
        // their inputs now arrive on sockets like everybody else's and this
        // function cannot tell which is which.
        for p in self.players.values_mut() {
            inputs.push(sim::sim_input {
                ship: p.ship,
                buttons: p.buttons_at(now),
            });
        }
        self.world.step(&inputs);
        self.score_events();

        let seats: Vec<(u8, bool)> = self
            .names
            .iter()
            .map(|(s, seat)| (*s, seat.bot))
            .collect();
        let names = self.public_team_names();
        let mut ctx = modes::ModeCtx {
            world: &mut self.world,
            seats: &seats,
            team_names: &names,
            banner: std::mem::take(&mut self.banner),
            finished: false,
        };
        self.mode.tick(&mut ctx);
        self.banner = std::mem::take(&mut ctx.banner);
        if ctx.finished {
            self.finished = true;
        }
    }

    /// Turn this tick's events into rating movement. The simulation does not
    /// know rating exists; this layer reads what it produced.
    fn score_events(&mut self) {
        let tick = self.world.state.tick;
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
        for (victim, killer, _) in deaths.iter().copied() {
            let seats: Vec<(u8, bool)> = self.names.iter().map(|(s, k)| (*s, k.bot)).collect();
            let names = self.public_team_names();
            let mut ctx = modes::ModeCtx {
                world: &mut self.world,
                seats: &seats,
                team_names: &names,
                banner: std::mem::take(&mut self.banner),
                finished: false,
            };
            self.mode.on_death(&mut ctx, victim, killer);
            self.banner = std::mem::take(&mut ctx.banner);
            if ctx.finished {
                self.finished = true;
            }
        }
        for (victim, killer, paid) in deaths {
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
                self.hand_off(r);
            }
            let mut m = vec![S2C_KILL];
            m.push(victim);
            m.push(killer);
            // Rating after the exchange, rounded, for the scoreboard.
            let vr = self.rating.rating_of(&vname).round() as i16;
            let kr = self.rating.rating_of(&kname).round() as i16;
            m.extend_from_slice(&vr.to_le_bytes());
            m.extend_from_slice(&kr.to_le_bytes());
            m.push(rated.as_ref().map_or(0, |r| r.credits.len() as u8));
            // What the kill paid, for the feed line. Clamped into a u16
            // because a bounty is a few dozen points and the field should
            // not inherit i32 from the event struct.
            m.extend_from_slice(&(paid.clamp(0, u16::MAX as i32) as u16).to_le_bytes());
            for p in self.players.values() {
                let _ = p.tx.try_send(Message::Binary(m.clone()));
            }
            let assists = rated.as_ref().map_or(0, |r| r.credits.len());
            if assists > 1 {
                println!(
                    "tick {tick}: {} killed {} with {assists} contributors",
                    self.name_of(killer),
                    self.name_of(victim)
                );
            }
        }
    }

    /// A rated death, addressed to the meta-layer.
    ///
    /// Only participants with accounts travel. A guest is rated inside the
    /// room and forgotten when it ends, which is what having no account means,
    /// so sending them would be reporting a pilot nobody can look up. An event
    /// where nobody at all has an account is not sent.
    fn hand_off(&mut self, r: &rating::RatedEvent) {
        let Some(&victim) = self.accounts.get(&r.victim) else {
            // The victim carries the negative half of the exchange. Without
            // them there is no event, only unbalanced credit.
            return;
        };
        let credits: Vec<spool::Credit> = r
            .credits
            .iter()
            .filter_map(|(who, w, before, after)| {
                Some(spool::Credit {
                    account: *self.accounts.get(who)?,
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
            tick: r.tick,
            victim,
            victim_kind: u8::from(self.rating.is_bot(&r.victim)),
            victim_before: r.victim_before,
            victim_after: r.victim_after,
            credits,
        };
        if let Ok(mut s) = self.spool.lock() {
            s.push(ev);
        }
    }

    fn name_of(&self, ship: u8) -> String {
        self.names
            .get(&ship)
            .map(|k| k.name.clone())
            .unwrap_or_else(|| format!("ship{ship}"))
    }

    /// What a seat's rating is filed under, which is not what it is called.
    fn rid_of(&self, ship: u8) -> String {
        self.names
            .get(&ship)
            .map(|k| k.rid.clone())
            .unwrap_or_else(|| format!("ship{ship}"))
    }

    fn broadcast_banner(&self) {
        let mut m = vec![S2C_BANNER];
        m.extend_from_slice(self.banner.as_bytes());
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(m.clone()));
        }
    }

    fn broadcast_snapshot(&self, buf: &mut [u8]) {
        for p in self.players.values() {
            // Packed per player rather than once for everybody, so each is
            // sent only the prizes near its own ship. Prizes are most of a
            // snapshot -- two hundred of them outweigh the ships and every
            // projectile together -- and a client can only see the handful
            // inside its radar, sixty tiles out.
            //
            // A pack is under two microseconds, so sixteen of them is thirty
            // microseconds of a fifty millisecond period. The bytes saved are
            // worth far more than the pack costs.
            let sh = &self.world.state.ships[p.ship as usize];
            // A declared bot gets every prize. The radius exists to keep human
            // snapshot bytes down across the internet; the bot server sits on
            // loopback, and it predicts each room in one world shared by all
            // its pilots, which is only sound if any one bot's snapshot is the
            // whole room's truth. Prizes were the one thing packed per player.
            let radius = if p.bot { -1 } else { PRIZE_INTEREST };
            let n = self.world.pack_around(buf, sh.x, sh.y, radius);
            if n <= 0 {
                continue;
            }
            let mut msg = Vec::with_capacity(n as usize + 10);
            msg.push(S2C_SNAPSHOT);
            msg.push(p.ship);
            msg.extend_from_slice(&p.last_input_tick.to_le_bytes());
            msg.extend_from_slice(&buf[..n as usize]);
            let _ = p.tx.try_send(Message::Binary(msg));
        }
    }

    /// Names and labels, sent on every join and leave and then every two
    /// seconds regardless. A player deserves to know who they are fighting, so
    /// the label rides here: human, house bot, third-party bot, or unknown.
    ///
    /// It used to be one bit for "this is AI". Three values were not enough
    /// once bots could be somebody else's and a pilot could be a guest we
    /// genuinely cannot vouch for, and guessing on a player's behalf is the
    /// one thing this field must not do.
    fn roster_msg(&self) -> Vec<u8> {
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
            let bytes = seat.name.as_bytes();
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
    fn teams_msg(&self, ship: u8) -> Vec<u8> {
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
                t.public
                    || **b == mine
                    || self.invites.get(&ship).is_some_and(|s| s.contains(b))
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

    /// Sent on every change to who is where, and to whom. Cheap enough to send
    /// whole rather than diffed: a room holds a handful of sides.
    fn broadcast_teams(&self) {
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(self.teams_msg(p.ship)));
        }
    }

    /// Everyone in the room gets the new numbers. An operator retuning a
    /// live arena would otherwise leave every client predicting the game as
    /// it was when they joined.
    fn broadcast_settings(&self) {
        let mut m = vec![S2C_SETTINGS];
        m.extend_from_slice(&self.world.packed_settings());
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(m.clone()));
        }
    }

    /// Called on every change, and on a two-second clock from the tick loop so a
    /// client whose queue was full gets another one. `try_send` is why it needs
    /// the clock.
    fn broadcast_roster(&self) {
        let m = self.roster_msg();
        for p in self.players.values() {
            let _ = p.tx.try_send(Message::Binary(m.clone()));
        }
    }
}

/// The zone and the one arena it is hosting. This held a map of arenas while
/// duels made rooms of their own; with duels out nothing else ever made a
/// second one, and one process to one room is where decision 23 was going
/// anyway.
struct Zone {
    /// Rooms this process holds for its zone, created on demand and reclaimed
    /// when they empty, capped by the zone's `max_rooms`. Never empty: an
    /// instance serving a zone always keeps one, so it still *is* an instance of
    /// that zone and appears as one. See the fill ladder in
    /// docs/architecture/zones-and-arenas.md.
    rooms: Vec<Arena>,
    cfg: config::ConfigWatcher,
    /// Rated events on their way to the meta-layer. One per process, shared
    /// with every room, and inert on a deployment without accounts.
    spool: std::sync::Arc<std::sync::Mutex<spool::Spool>>,
    /// The zone this process is serving, empty when it is running the built-in
    /// room because no catalog reached it.
    zone_name: String,
    /// The catalog as a directory handed it over, and the version, so the
    /// highest offered wins and a disagreement is a log line rather than a vote.
    catalog: Option<fleet::WireCatalog>,
    /// Last measured tick cost, for the metrics that ride in `STATUS`.
    tick_us: u32,
    /// An operator pin. While set, policy stops applying: admin.md's verbs win
    /// over selection, and the pin is displayed with who set it and when.
    pinned: Option<(String, String, u64)>,
    /// Set by a `drain` command or by wanting a different zone. No new joins.
    draining: bool,
    /// Whether the line about reporting being off has been said. `aim_spool`
    /// runs on a slow clock forever, and a log that repeats a standing
    /// condition every few seconds is a log nobody reads.
    said_quiet: bool,
    /// Everything about this instance's place in a fleet: its id, the views the
    /// directories pushed, what it has announced. Empty and harmless when no
    /// directory was ever configured.
    fleet: select::Fleet,
    /// Calibrated bot ratings, held here because every room needs them and a
    /// room is opened long after startup. Read once; the two places that build
    /// a room used to go back to the disk for it and named a path relative to
    /// the working directory, which on the fleet is not where it lives.
    ladder: HashMap<String, f64>,
}

impl Zone {
    /// Every player in every room, which is what a status push reports.
    ///
    /// There is deliberately no "the arena" accessor. There was one, meaning
    /// room zero, and every caller that used it was wrong once a process held
    /// more than one room: rule 1 let an instance change zone under players in
    /// room two, a kick could not reach them, and their ratings were never
    /// saved. Anything asking about the process asks about all of its rooms.
    fn total_players(&self) -> usize {
        self.rooms.iter().map(|r| r.humans()).sum()
    }

    fn total_bots(&self) -> usize {
        self.rooms.iter().map(|r| r.bot_count()).sum()
    }

    /// Where the next arrival goes, per the fill ladder. Rung one is the fullest
    /// room below its player cap, which is most of the work and needs no
    /// coordination. Rung two is a new room here, when every room is at the
    /// zone's fill target and we are below `max_rooms`: 79 KB and a shared map,
    /// which is why it comes before anything involving another process.
    ///
    /// Fullest counts people, as the cap and the target do. Counting bots would
    /// put every room at target from the moment the bot server found it, so a
    /// zone would open its second room for its second player.
    ///
    /// `None` means this instance is out of room, and the client should try the
    /// next address the directory gave it.
    fn room_for_join(&mut self) -> Option<usize> {
        let cap = self.max_players();
        let target = self.fill_target();

        // Rung 1: fullest below cap.
        let best = self
            .rooms
            .iter()
            .enumerate()
            .filter(|(_, r)| r.humans() < cap)
            .max_by_key(|(_, r)| r.humans())
            .map(|(i, _)| i);

        // Only grow when every room has reached the target. A room holding six of
        // twenty wants the next six players, not a sibling.
        let all_at_target = self.rooms.iter().all(|r| r.humans() >= target);
        if let Some(i) = best {
            if !all_at_target || self.rooms.len() >= self.max_rooms() {
                return Some(i);
            }
        }

        // Rung 2: a new room here.
        if self.rooms.len() < self.max_rooms() {
            match self.open_room() {
                Ok(i) => return Some(i),
                Err(e) => {
                    println!("cannot open another room: {e}");
                    return best;
                }
            }
        }
        best
    }

    /// Where an arriving bot goes: the room shortest of the ones it wants, and
    /// nowhere at all when every room has what it asked for.
    ///
    /// A separate question from `room_for_join`, and it has to be. Rooms open
    /// because people arrive, so a bot must never grow one; and "fullest room"
    /// is the wrong answer for a bot, since it would stack every bot into room
    /// one and leave a room opened for players with nobody in it to fight.
    fn room_for_bot(&self) -> Option<usize> {
        if self.draining {
            return None;
        }
        self.rooms
            .iter()
            .enumerate()
            .map(|(i, r)| (i, r.bots_wanted().saturating_sub(r.bot_count())))
            .filter(|(_, short)| *short > 0)
            .max_by_key(|(_, short)| *short)
            .map(|(i, _)| i)
    }

    /// What this process would like the bot server to supply, across every room.
    /// Zero while draining, which is what lets a drain finish rather than being
    /// topped up for ever by the thing that is supposed to be leaving.
    fn bots_wanted(&self) -> usize {
        if self.draining {
            return 0;
        }
        self.rooms.iter().map(|r| r.bots_wanted()).sum()
    }

    /// Another simulation of the same zone, sharing the map bytes. Bounded by
    /// `max_rooms`, which bounds both memory and the blast radius of this process
    /// dying, since rooms in a process share its fate.
    fn open_room(&mut self) -> Result<usize, String> {
        let z = self.wire_zone().cloned().ok_or("no zone definition")?;
        // On the map the first room already holds, rather than unpacking the
        // bytes again. Geometry is a megabyte and immutable, so a hundred rooms
        // share one copy; without this the ceiling would be a memory limit
        // instead of a blast-radius one.
        let mut fresh = Self::build_room(&z, Some(&self.rooms[0].world))?;
        fresh.spool = self.spool.clone();
        prime_ratings(&mut fresh.rating, &self.ladder);
        self.rooms.push(fresh);
        let n = self.rooms.len();
        println!("opened room {n} of {} for zone {:?}", self.max_rooms(), z.name);
        Ok(n - 1)
    }

    /// Who is at the door, and what this room is allowed to say about them.
    ///
    /// A token is checked against the catalog's key and nothing else, so this
    /// answers without a network call and keeps answering while the meta-layer
    /// is down. What a pilot gets for arriving without one is a seat: they fly
    /// as an unknown guest under the name they gave, and nothing durable is
    /// written for them.
    fn identify(&self, presented: &str, fallback_name: &str, declared_bot: bool)
        -> Result<Seat, String>
    {
        let guest = |name: &str| Seat {
            name: name.to_string(),
            bot: declared_bot,
            // A declared bot with no account is somebody else's bot, which is
            // exactly what the third-party label means. Without an account it
            // anchors nothing and earns nothing, which is the whole difference
            // between a declaration and a credential.
            label: if declared_bot {
                token::Label::ThirdPartyBot.to_byte()
            } else {
                token::Label::Unknown.to_byte()
            },
            rid: name.to_string(),
            account: None,
            carried: None,
        };
        let key = self
            .catalog
            .as_ref()
            .map(|c| c.meta_key.as_str())
            .unwrap_or_default();
        if presented.is_empty() || key.is_empty() {
            return Ok(guest(fallback_name));
        }
        let Some(vk) = token::verifying_key_from_hex(key) else {
            // A catalog with an unreadable key is an operator error, and
            // refusing every pilot over it would take the zone down. Say it
            // once per join and let people fly as guests.
            println!("catalog holds a meta key that is not a key; pilots fly as guests");
            return Ok(guest(fallback_name));
        };
        let claims = match token::verify(&vk, presented, token::now_secs()) {
            Ok(c) => c,
            Err(token::Bad::Expired) => return Err("your session expired; log in again".into()),
            Err(token::Bad::Version) => {
                return Err("your client and this fleet disagree about token format".into())
            }
            Err(_) => return Err("that session token is not one of ours".into()),
        };
        // The declaration and the account have to agree. A bot account that
        // did not declare would be labeled honestly and still sit in a human
        // seat, and a human account that declared would take a bot's exemption
        // from the cap. Neither is a thing to allow quietly.
        if claims.kind.is_bot() != declared_bot {
            return Err(if declared_bot {
                "this account is not a bot account; register the bot first".into()
            } else {
                "a bot account has to declare itself a bot".into()
            });
        }
        Ok(Seat {
            name: claims.name.clone(),
            bot: declared_bot,
            label: claims.label().to_byte(),
            rid: account_rid(claims.account),
            account: Some(claims.account),
            carried: Some(claims.ratings),
        })
    }

    /// A returning pilot's record, into the room they are actually joining.
    ///
    /// The number and its game count move together, always. A rating restored
    /// without its count is a number with no confidence attached: the pilot
    /// reads as still placing, and the next death moves them by a newcomer's K,
    /// which is four times as far as their record says it should.
    ///
    /// The record comes from the token, which is the meta-layer's answer and
    /// therefore the same in every room of the fleet. A pilot without one
    /// arrives unrated, which is what having no account means.
    fn restore_pilot(&mut self, room: usize, seat: &Seat) {
        let class = self.rating_class();
        let Some((saved, played)) = self.token_rating(seat, &class) else {
            return;
        };
        if let Some(a) = self.rooms.get_mut(room) {
            a.rating.score.insert(seat.rid.clone(), saved);
            a.rating.games.insert(seat.rid.clone(), played);
        }
    }

    /// The rating a token carried for this zone's class, if it carried one.
    /// A pilot who has never played this class arrives unrated and places,
    /// which is what a first game in a new class is supposed to be.
    fn token_rating(&self, seat: &Seat, class: &str) -> Option<(f64, u32)> {
        let r = seat.carried.as_ref()?.iter().find(|r| r.class == class)?;
        Some((r.rating, r.games))
    }

    /// Tell the spool where to send, which cannot be known until a catalog
    /// has arrived: the meta-layer's address travels with it. Called on the
    /// same slow clock the ladder save used to run on, so a zone change or a
    /// catalog update is picked up without another trigger to remember.
    fn aim_spool(&mut self) {
        // Unless this arena has been told not to file anything, in which case
        // the spool is simply never aimed. An unaimed spool writes nothing and
        // posts nothing, which is the whole of the off switch: see
        // `Spool::push` and `spool::drain_loop`, both of which check `armed`.
        //
        // Nothing else changes. Accounts still work, a pilot still arrives
        // carrying the rating they earned, the room still rates every
        // exchange, the scoreboard still shows it, and the meta-layer keeps
        // running. What stops is this process filing any of it, which is what
        // a fleet under test wants: a test session's kills are real enough to
        // move a real ladder, and that ladder is other people's.
        if !reporting_enabled() {
            if !self.said_quiet {
                self.said_quiet = true;
                let held = self.spool.lock().map(|s| s.len()).unwrap_or(0);
                println!(
                    "spool: VW_REPORT is off, rated events are not filed{}",
                    if held > 0 {
                        format!(" ({held} carried over from before are held, not dropped)")
                    } else {
                        String::new()
                    }
                );
            }
            return;
        }
        // The catalog's address is the public one, because it is the one a
        // client dials. An arena on the same host as the meta-layer should not
        // go out through DNS, TLS and a proxy to reach a port beside it, so
        // VW_META overrides it the same way VW_ARENAS does for the bot server.
        let url = match std::env::var("VW_META") {
            Ok(v) if !v.is_empty() => v,
            _ => self.catalog.as_ref().map(|c| c.meta_url.clone()).unwrap_or_default(),
        };
        let token = std::env::var("VW_TOKEN").unwrap_or_default();
        let (zone, class, instance) =
            (self.zone_name.clone(), self.rating_class(), self.fleet.instance.clone());
        if let Ok(mut s) = self.spool.lock() {
            s.aim(&url, &token, &zone, &class, &instance);
        }
    }

    /// Whether this zone admits only pilots who have claimed their account.
    fn wants_claimed(&self) -> bool {
        self.wire_zone().map(|z| z.admission == "claimed").unwrap_or(false)
    }

    /// The class this zone rates into. One number per kind of game, per
    /// docs/design/rating.md: a warzone and a duel ladder measure different
    /// skills and one number for both is a number about nothing.
    /// The zone definition is the authority, not the local config file: a
    /// catalog-served arena takes its mode from the zone it was handed, and
    /// the file underneath it is whatever the image happened to ship.
    fn rating_class(&self) -> String {
        let m = self
            .wire_zone()
            .map(|z| z.mode.clone())
            .unwrap_or_else(|| self.cfg.current.arena.mode.clone());
        if m.is_empty() {
            meta::DEFAULT_CLASS.to_string()
        } else {
            m
        }
    }

    /// Give back rooms nobody is in, keeping the first. A process shrinks as
    /// matches end rather than holding its high-water mark forever.
    fn reclaim_rooms(&mut self) {
        if self.rooms.len() <= 1 {
            return;
        }
        let before = self.rooms.len();
        let mut keep_first = true;
        self.rooms.retain(|r| {
            if keep_first {
                keep_first = false;
                return true;
            }
            !r.players.is_empty()
        });
        if self.rooms.len() != before {
            println!("reclaimed {} empty room(s)", before - self.rooms.len());
        }
    }

    /// One room built from a zone definition. Shared by the first room and by
    /// every room grown after it, so they cannot differ. `on` is a room already
    /// running this zone, whose map the new one borrows instead of unpacking a
    /// second megabyte of identical tiles.
    fn build_room(z: &fleet::WireZone, on: Option<&sim::World>) -> Result<Arena, String> {
        let world = match on {
            Some(w) => w.sibling(0x5eed),
            None => {
                let bytes = fleet::unb64(&z.map_b64).ok_or("map is not base64")?;
                sim::World::from_packed(0x5eed, &bytes).map_err(|e| e.to_string())?
            }
        };
        let def: catalog::ZoneDef =
            toml::from_str(&z.zone_toml).map_err(|e| format!("zone.toml: {e}"))?;
        let mut arena = Arena::with_world_bare(world);
        for w in Arena::apply_config(&mut arena.world, &def.arena) {
            println!("zone {}: {w}", z.name);
        }
        if let Some(m) = def.max_ships {
            arena.world.cfg.max_ships = m;
        }
        arena.set_teams(&def);
        arena.mode = modes::build(&z.mode, def.arena.flags, arena.public_teams);
        arena.bot_fill = def.bot_fill();
        if z.mode == "warzone" {
            arena.add_default_flags();
        }
        Ok(arena)
    }

    /// Take a catalog a directory offered. Highest version wins; a tie with
    /// different content is an author error rather than a race, so it is a log
    /// line naming both directories rather than a vote.
    fn take_catalog(&mut self, c: fleet::WireCatalog, from: &str) {
        let have = self.catalog.as_ref().map(|c| c.version).unwrap_or(0);
        if c.version < have {
            println!(
                "catalog: {from} offered v{} and we hold v{have} from {:?}; keeping ours",
                c.version, self.fleet.catalog_from
            );
            return;
        }
        if c.version == have {
            let same = self
                .catalog
                .as_ref()
                .map(|old| serde_json::to_string(old).ok() == serde_json::to_string(&c).ok())
                .unwrap_or(false);
            if !same {
                println!(
                    "catalog: {from} and {:?} both call this v{have} with different \
                     content; keeping what we hold. This is an author error, not a race",
                    self.fleet.catalog_from
                );
            }
            return;
        }
        println!("catalog: v{} from {from} ({} zones)", c.version, c.zones.len());
        self.fleet.catalog_from = from.to_string();

        // A running room does not change zone because the catalog changed: it
        // takes new settings for the zone it already serves, and the rest at its
        // next drain. A catalog edit is not a reason to disconnect anybody.
        if !self.zone_name.is_empty() {
            if let Some(z) = c.zone(&self.zone_name).cloned() {
                if let Ok(def) = toml::from_str::<catalog::ZoneDef>(&z.zone_toml) {
                    let name = self.zone_name.clone();
                    for r in self.rooms.iter_mut() {
                        for w in Arena::apply_config(&mut r.world, &def.arena) {
                            println!("zone {name}: {w}");
                        }
                        if let Some(m) = def.max_ships {
                            r.world.cfg.max_ships = m;
                        }
                        r.broadcast_settings();
                    }
                }
            }
        }
        self.catalog = Some(c);
        // Deliberately not serving anything here. `default_zone` is what an
        // arena falls back to when it can reach no directory at all; taking it
        // the moment a catalog arrives would have every instance in a fleet grab
        // the same zone and skip selection entirely, which is exactly what the
        // first end-to-end run did. The decision loop chooses, within a couple of
        // seconds, and it is the only thing that chooses.
    }

    /// Tell every directory what we are serving, now rather than on the next
    /// heartbeat. Called on commit, because a directory that learns seconds late
    /// is a directory whose view is stale exactly when another instance is
    /// deciding against it, which is how a redundant commit happens.
    fn push_status(&self) {
        let msg = fleet::frame(fleet::A2D_STATUS, &self.status());
        for tx in self.fleet.senders.values() {
            let _ = tx.send(msg.clone());
        }
    }

    /// Announce an intent to every directory, now rather than on the next
    /// heartbeat. The expiry travels with it, so a crash here releases the claim
    /// on a timer rather than holding a zone empty forever.
    fn announce(&self, zone: &str) {
        let msg = fleet::frame(
            fleet::A2D_INTENT,
            &fleet::Intent {
                zone: zone.to_string(),
                expires_ms: select::INTENT_TTL_MS,
            },
        );
        let mut sent = 0;
        for tx in self.fleet.senders.values() {
            if tx.send(msg.clone()).is_ok() {
                sent += 1;
            }
        }
        println!("selection: announced intent to serve {zone:?} to {sent} directory(s)");
    }

    /// Stop taking joins and send every bot home, which is what makes a drain
    /// finish. A draining instance publishes `bots_wanted` of zero as well, so
    /// the bot server does not put back what this just let go; the eviction is
    /// belt to that braces, and the fast half, since it does not wait for a
    /// browse.
    fn begin_drain(&mut self) -> usize {
        self.draining = true;
        let gone: usize = self.rooms.iter_mut().map(|r| r.evict_all_bots()).sum();
        if gone > 0 {
            for r in self.rooms.iter() {
                r.broadcast_roster();
            }
        }
        gone
    }

    /// An operator verb from a directory. `unknown_verb` is what lets a
    /// directory be newer than an arena without either pretending.
    fn run_command(&mut self, c: &fleet::Command) -> (&'static str, String) {
        match c.verb.as_str() {
            "drain" => {
                let bots = self.begin_drain();
                ("done", format!("draining {} player(s), {bots} bot(s) sent home",
                                 self.total_players()))
            }
            "pin" => {
                if self.catalog.as_ref().and_then(|k| k.zone(&c.args)).is_none() {
                    return ("refused", format!("no zone {:?} in the catalog", c.args));
                }
                self.pinned = Some((c.args.clone(), c.actor.clone(), fleet::now_ms()));
                let def = self.catalog.as_ref().and_then(|k| k.zone(&c.args)).cloned();
                if let Some(def) = def {
                    if self.total_players() == 0 {
                        if let Err(e) = self.serve_zone(&def) {
                            return ("refused", e);
                        }
                    } else {
                        self.begin_drain();
                        return ("done", "pinned; draining before the switch".into());
                    }
                }
                ("done", format!("pinned to {:?}", c.args))
            }
            "unpin" => {
                self.pinned = None;
                ("done", String::new())
            }
            "kick" => {
                // Every room, because an operator naming a player does not know
                // or care which room of this process holds them.
                let before = self.total_players();
                let mut hit = 0;
                for r in self.rooms.iter_mut() {
                    let ids: Vec<u64> = r
                        .players
                        .iter()
                        .filter(|(_, p)| p.name.eq_ignore_ascii_case(&c.args))
                        .map(|(id, _)| *id)
                        .collect();
                    for id in &ids {
                        r.leave(*id);
                    }
                    if !ids.is_empty() {
                        hit += ids.len();
                        r.broadcast_roster();
                    }
                }
                if hit == 0 {
                    ("refused", format!("nobody here called {:?}", c.args))
                } else {
                    ("done", format!("kicked {hit} of {before}"))
                }
            }
            "restart" => {
                println!("restart asked for by {:?}; exiting so the supervisor restarts us",
                         c.actor);
                // The container platform owns restarts. Exiting is the whole
                // implementation, and it is the honest one.
                std::process::exit(0);
            }
            _ => ("unknown_verb", c.verb.clone()),
        }
    }

    fn wire_zone(&self) -> Option<&fleet::WireZone> {
        self.catalog.as_ref()?.zone(&self.zone_name)
    }

    fn fill_target(&self) -> usize {
        self.wire_zone()
            .map(|z| z.fill_target as usize)
            .unwrap_or(catalog::DEFAULT_FILL_TARGET)
    }

    fn max_rooms(&self) -> usize {
        self.wire_zone().map(|z| z.max_rooms as usize).unwrap_or(1).max(1)
    }

    fn max_players(&self) -> usize {
        self.wire_zone()
            .map(|z| z.max_players as usize)
            .unwrap_or(DEFAULT_MAX_PLAYERS)
    }

    /// Bans come from the catalog when there is one, because they are
    /// deployment-wide, and from the local file only when there is not.
    fn is_banned(&self, name: &str) -> bool {
        match &self.catalog {
            Some(c) => c.is_banned(name),
            None => self.cfg.current.is_banned(name),
        }
    }

    /// Take a zone definition and rebuild the room around it: its map, its
    /// settings, its mode. The one path by which a process changes what game it
    /// is running, so the map failing is a refusal rather than a half-change.
    fn serve_zone(&mut self, z: &fleet::WireZone) -> Result<(), String> {
        // From the bytes, not from a sibling: this is a change of zone, so the
        // map the running rooms hold is the wrong map.
        let mut arena = Self::build_room(z, None)?;
        arena.spool = self.spool.clone();
        prime_ratings(&mut arena.rating, &self.ladder);
        // Tell the bots before the room they are in stops existing. Rule 1 means
        // no human is here to tell, but bots are: an instance with only bots in
        // it reads as empty and is free to change zone, and a bot whose room was
        // replaced underneath it would sit on a socket that had gone quiet until
        // its own timeout rather than reconnecting into the new game.
        for r in self.rooms.iter_mut() {
            r.evict_all_bots();
        }
        // A change of zone replaces every room: they all served the old game.
        self.rooms = vec![arena];
        self.zone_name = z.name.clone();
        self.draining = false;
        println!(
            "serving zone {:?}: mode {}, {} ships, {} players, teams {}",
            z.name, z.mode, z.max_ships, z.max_players,
            if self.rooms[0].public_teams == 0 {
                "free-for-all".to_string()
            } else {
                self.rooms[0]
                    .teams
                    .values()
                    .filter(|t| t.public)
                    .map(|t| t.name.as_str())
                    .collect::<Vec<_>>()
                    .join("/")
            }
        );
        Ok(())
    }
}

/// Put an arena's ratings on the same footing as every other: the AI marked
/// so it moves slowly against humans, each bot seeded from the calibrated
/// prior, and the anchor pinned last so nothing can overwrite the fixed
/// point the rest of the ladder is measured against.
/// A call sign as the rest of the system may hold it.
///
/// The wire hands us arbitrary bytes, and a name travels further than anywhere
/// else a client can reach: into every other player's roster, into the kill
/// feed and so into the logs, into the ratings map and so onto disk, and into
/// the argument of an operator's kick. So it is printable ASCII, single-spaced,
/// and at most 24 characters -- which is also the roster wire format's cap, so
/// what is stored is what everyone sees. Control characters would otherwise
/// ride into the logs (a newline forges a log line), and a 64 MB name is a
/// memory bill somebody else pays.
fn sanitize_name(raw: &str) -> String {
    let mut out = String::with_capacity(24);
    let mut pending_space = false;
    for c in raw.chars() {
        if c == ' ' || c.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if !c.is_ascii_graphic() {
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(c);
        if out.len() >= 24 {
            break;
        }
    }
    if out.is_empty() {
        "pilot".into()
    } else {
        out
    }
}

/// Seed a room's ladder with what the offline tournament measured.
///
/// Only the calibrated nine, because they are the only pilots it measured. The
/// bot server draws from a much longer roster than that, and the rest arrive
/// unrated and earn their number in play, which is what a new individual is
/// supposed to do. Who is a bot at all is no longer decided here either: it is
/// whoever said so at join, and `Arena::join` marks them.
fn prime_ratings(r: &mut rating::Rating, ladder: &HashMap<String, f64>) {
    for (name, _, _) in ai::CALIBRATED {
        r.mark_bot(name);
        if let Some(&v) = ladder.get(name) {
            r.score.insert(name.to_string(), v);
        }
    }
    r.set_anchor(ai::ANCHOR, ai::ANCHOR_RATING);
}

/// The calibrated ladder, compiled in.
///
/// It is a property of the roster in `ai.rs` rather than of any one zone: the
/// same nine pilots fly in every room this binary serves, so their ratings
/// travel with the binary the way `sim/tests/golden.txt` travels with the core.
/// Regenerate with `calibrate`, which writes the file, and commit it.
///
/// Shipping it as a file is what did not work. The fleet runs the arena with a
/// data volume as its directory and the image never put a ladder in it, so every
/// room on the live server started its bots level while two documents said the
/// ladder seeds every zone.
const LADDER: &str = include_str!("../../zone/ladder.json");

/// What the offline tournament measured for one calibrated individual.
///
/// The meta-layer seeds a house bot's account from this the first time it is
/// claimed, which is where the calibrated ladder now enters the fleet. It used
/// to enter by priming every room, and that stopped reaching accounted bots the
/// moment their rating started being filed under an account rather than a name:
/// a room primes what it knows, and it no longer knows them by name.
pub fn calibrated_rating(name: &str) -> Option<f64> {
    if name == ai::ANCHOR {
        // The pinned reference personality. It is a definition rather than a
        // measurement, so it does not depend on a calibration run having
        // happened.
        return Some(ai::ANCHOR_RATING);
    }
    if !ai::CALIBRATED.iter().any(|(n, _, _)| *n == name) {
        return None;
    }
    serde_json::from_str::<HashMap<String, f64>>(LADDER)
        .ok()
        .and_then(|m| m.get(name).copied())
}

/// Read the ladder a calibration run wrote, falling back to the compiled one.
/// A missing file is the normal case and not a warning: it means nobody has
/// calibrated since this build.
fn load_ladder(dir: &str) -> HashMap<String, f64> {
    std::fs::read_to_string(format!("{dir}/ladder.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<HashMap<String, f64>>(&t).ok())
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| serde_json::from_str(LADDER).unwrap_or_default())
}

impl Zone {
    fn new(cfg: config::ConfigWatcher, spool: std::sync::Arc<std::sync::Mutex<spool::Spool>>,
           ladder: HashMap<String, f64>) -> Self {
        let mut arena = Arena::new_from(&cfg.current);
        arena.spool = spool.clone();
        prime_ratings(&mut arena.rating, &ladder);
        Zone {
            rooms: vec![arena],
            cfg,
            spool,
            zone_name: String::new(),
            catalog: None,
            tick_us: 0,
            pinned: None,
            draining: false,
            said_quiet: false,
            fleet: select::Fleet::default(),
            ladder,
        }
    }

    /// Re-read the zone file and push the new numbers into every live arena.
    /// Nobody is disconnected: an operator tuning a bounce factor should not
    /// cost the room its round.
    fn reload(&mut self) {
        if let Some(msg) = self.cfg.poll() {
            println!("{msg}");
            // Cloned so the arena can be borrowed mutably while reading it, and
            // applied to every room: they are all the same game.
            let block = self.cfg.current.arena.clone();
            for r in self.rooms.iter_mut() {
                for w in Arena::apply_config(&mut r.world, &block) {
                    println!("zone: {w}");
                }
                r.broadcast_settings();
            }
        }
    }

    /// What this arena server tells a directory, and anybody else who asks.
    /// This doubles as the verification answer: a directory dials the claimed
    /// address, asks for status, and requires a well-formed reply, so the shape
    /// here is what proves an address works.
    fn status_json(&self) -> String {
        serde_json::to_string(&self.status()).unwrap_or_default()
    }

    fn status(&self) -> fleet::Status {
        let zone = self.zone_name.clone();
        let target = self.fill_target();
        fleet::Status {
            zone,
            players: self.total_players() as u32,
            bots: self.total_bots() as u32,
            bots_wanted: self.bots_wanted() as u32,
            rooms: self.rooms.len() as u32,
            max_rooms: self.max_rooms() as u32,
            // This instance's own answer to "am I out of room", so the rule lives
            // in one place rather than being recomputed by every reader. Capped
            // means every room is at the target *and* there is no headroom to
            // open another, which is the fill ladder's second rung exhausted.
            capped: self.rooms.iter().all(|r| r.humans() >= target)
                && self.rooms.len() >= self.max_rooms(),
            metrics: fleet::Metrics {
                tick_us: self.tick_us,
                // The worst-off client in the process. A depth near `OUT_QUEUE`
                // is a connection that cannot keep up and is losing snapshots,
                // which is the one player-visible symptom an operator cannot see
                // from a player count.
                queue_depth: self
                    .rooms
                    .iter()
                    .flat_map(|r| r.players.values())
                    .map(|p| (OUT_QUEUE - p.tx.capacity()) as u32)
                    .max()
                    .unwrap_or(0),
                ..Default::default()
            },
        }
    }

    /// The name a joining player is shown. The catalog's when this process is
    /// serving a catalog zone, because that is the game they picked; the local
    /// file's only when no directory was ever reached.
    fn zone_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ZONE];
        let (name, desc) = match self.wire_zone() {
            Some(z) => (z.name.clone(), z.description.clone()),
            None => (
                self.cfg.current.name.clone(),
                self.cfg.current.description.clone(),
            ),
        };
        m.extend_from_slice(format!("{name}\n{desc}").as_bytes());
        m
    }
}

/// Run the offline tournament and write the ladder the zone seeds bots from.
///
///     vectorwake-server calibrate [rounds] [dir]
fn run_calibration() {
    let rounds: u32 = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);
    let dir = std::env::args().nth(3).unwrap_or_else(|| ".".into());
    let path = format!("{dir}/ladder.json");

    println!("calibrating: {rounds} rounds of round-robin matches");
    let r = calibrate::run(rounds, true);

    println!("\n{:<12} {:>7}  {:>6}  {}", "pilot", "rating", "games", "tier");
    let mut ladder = std::collections::HashMap::new();
    for (name, score, games, tier) in calibrate::table(&r) {
        let pin = if name == ai::ANCHOR { " (anchor)" } else { "" };
        println!("{name:<12} {score:>7.0}  {games:>6}  {tier}{pin}");
        ladder.insert(name, score);
    }

    let doc = serde_json::to_string_pretty(&ladder).expect("serialize ladder");
    match std::fs::write(&path, doc) {
        Ok(()) => println!("\nwrote {path}"),
        Err(e) => println!("\ncould not write {path}: {e}"),
    }
}

/// Where the directories are. `VW_DIRECTORY` names a host, which is resolved,
/// so one hostname with several records is a whole deployment and a directory can
/// be added or moved without touching an arena server. That is the DNS decision
/// in docs/architecture/discovery.md: `directory.vectorwake.net` resolves to
/// every directory of this deployment.
///
/// An explicit `ws://` or `wss://` URL is taken as given, which is what a
/// developer running one of each on a laptop wants.
async fn directory_urls() -> Vec<String> {
    let spec = std::env::var("VW_DIRECTORY").unwrap_or_default();
    if spec.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for part in spec.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        if part.starts_with("ws://") || part.starts_with("wss://") {
            out.push(part.to_string());
            continue;
        }
        // A bare host, optionally with a port. Resolve it and take every record,
        // so a round-robin name is a list of directories.
        let (host, port) = match part.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => (h, p.to_string()),
            _ => (part, "9000".to_string()),
        };
        match tokio::net::lookup_host(format!("{host}:{port}")).await {
            Ok(addrs) => {
                let mut seen = Vec::new();
                for a in addrs {
                    // wss for a real hostname, because the token is a bearer
                    // credential and the directory will refuse it in the clear.
                    // Loopback is development and stays ws.
                    let scheme = if a.ip().is_loopback() { "ws" } else { "wss" };
                    // Dial the name rather than the address so TLS verifies: the
                    // certificate is issued for the hostname, and all of a
                    // deployment's directories share it.
                    let url = if a.ip().is_loopback() {
                        format!("{scheme}://{a}")
                    } else {
                        format!("{scheme}://{host}:{port}")
                    };
                    if !seen.contains(&url) {
                        seen.push(url);
                    }
                }
                if seen.is_empty() {
                    println!("VW_DIRECTORY {part:?} resolved to nothing");
                }
                out.extend(seen);
            }
            Err(e) => println!("VW_DIRECTORY {part:?}: {e}"),
        }
    }
    // Shuffled, so a fleet of identical containers does not all prefer the same
    // directory. The order is arbitrary and only needs to differ between hosts.
    let n = out.len();
    if n > 1 {
        let seed = (fleet::now_ms() as usize).wrapping_mul(2654435761);
        out.rotate_left(seed % n);
    }
    println!("directories: {}", out.join(", "));
    out
}

/// Either kind of accepted connection, boxed so the connection handler is
/// written once. tokio implements AsyncRead and AsyncWrite for Box<T>, and a
/// trait object carries its supertraits, so this needs no glue of its own.
pub trait Conn: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Conn for T {}

/// Build a TLS acceptor from PEM files, or None when the zone is plain ws.
/// A zone that is configured for TLS and cannot load its certificate must
/// not quietly fall back to cleartext: the operator asked for wss, and
/// serving ws instead would look like it worked.
pub fn tls_acceptor(cert: &str, key: &str) -> Option<tokio_rustls::TlsAcceptor> {
    if cert.is_empty() && key.is_empty() {
        return None;
    }
    if cert.is_empty() || key.is_empty() {
        panic!("tls_cert and tls_key must be set together");
    }
    let certs: Vec<_> = rustls_pemfile::certs(&mut std::io::BufReader::new(
        std::fs::File::open(cert).unwrap_or_else(|e| panic!("tls_cert {cert}: {e}")),
    ))
    .collect::<Result<_, _>>()
    .expect("tls_cert is not a PEM certificate chain");
    let k = rustls_pemfile::private_key(&mut std::io::BufReader::new(
        std::fs::File::open(key).unwrap_or_else(|e| panic!("tls_key {key}: {e}")),
    ))
    .expect("tls_key is not readable")
    .expect("tls_key holds no private key");
    let cfg = tokio_rustls::rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, k)
        .expect("certificate and key do not match");
    Some(tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(cfg)))
}

#[tokio::main]
async fn main() {
    if std::env::args().nth(1).as_deref() == Some("directory") {
        directory::run().await;
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("catalog") {
        catalog::run_check();
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("token") {
        catalog::run_token();
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("calibrate") {
        run_calibration();
        return;
    }
    // What the ladder cannot see: the roster on a real map, with walls in it.
    if std::env::args().nth(1).as_deref() == Some("drill") {
        drill::run_check();
        return;
    }
    // The meta-layer: accounts, ratings, and the rated event log. The one
    // process in the fleet with a database behind it, and the one every other
    // process is designed to survive the loss of.
    if std::env::args().nth(1).as_deref() == Some("meta") {
        meta::run().await;
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("metakey") {
        meta::run_keygen();
        return;
    }
    // The bot server. Same binary as the arena and the directory, and a
    // separate process for the same reason they are: one image, run with
    // different first arguments, is what a deployment of this thing is.
    //
    // It also settles what "a crate both depend on" was going to mean. The
    // calibration tournament and the live bots have to run identical code or
    // the ladder rates pilots that do not exist, and being one program makes
    // that structural rather than a rule about dependencies.
    if std::env::args().nth(1).as_deref() == Some("bots") {
        bots::run().await;
        return;
    }
    let addr_arg = std::env::args().nth(1);

    let dir = std::env::args().nth(2).unwrap_or_else(|| ".".into());
    let (watcher, err) = config::ConfigWatcher::load(format!("{dir}/zone.toml"));
    if let Some(e) = err {
        println!("no usable zone.toml ({e}); running on the built-in defaults");
    }
    // The one thing an arena's disk holds besides its instance id: rated
    // events waiting for the meta-layer.
    let spool = std::sync::Arc::new(std::sync::Mutex::new(spool::Spool::new(&dir)));
    tokio::spawn(spool::drain_loop(spool.clone()));
    let ladder = load_ladder(&dir);
    let local = std::path::Path::new(&dir).join("ladder.json").exists();
    println!(
        "seeded {} bot ratings from {}",
        ladder.len(),
        if local { "ladder.json" } else { "the compiled ladder" }
    );
    println!("zone \"{}\": {}", watcher.current.name, watcher.current.description);
    // The command line wins over the zone file, so an operator can move a
    // zone to another port without editing its configuration.
    let addr = addr_arg.unwrap_or_else(|| watcher.current.listen.clone());
    // Read before the watcher moves into the zone. Certificates are not
    // hot-reloaded: a listener is bound once, and swapping its identity
    // underneath live connections is not something an operator asked for.
    let cfg_tls = (
        watcher.current.tls_cert.clone(),
        watcher.current.tls_key.clone(),
    );
    let zone = Arc::new(Mutex::new(Zone::new(watcher, spool, ladder)));
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    let tls = tls_acceptor(&cfg_tls.0, &cfg_tls.1);
    let scheme = if tls.is_some() { "wss" } else { "ws" };
    println!("vectorwake arena server listening on {scheme}://{addr}");

    // Join a fleet, if one was configured. An arena server with no directory is
    // still a whole game: it serves the built-in room or its local zone file to
    // anybody who knows its address, which is the Offline state in
    // docs/architecture/zones-and-arenas.md and the reason a discovery outage is
    // not a gameplay outage.
    {
        let mut z = zone.lock().await;
        z.fleet.instance = select::Fleet::load_instance_id(&dir);
        z.fleet.region = std::env::var("VW_REGION").unwrap_or_else(|_| "local".into());
        // What a client should dial. Defaults to the listen address, which is
        // right for a single host and wrong behind NAT, so it is overridable.
        z.fleet.address = std::env::var("VW_ADDRESS")
            .unwrap_or_else(|_| format!("{scheme}://{addr}"));
        z.fleet.willing = std::env::var("VW_ZONES")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        println!(
            "instance {} in region {:?}, reachable at {}",
            z.fleet.instance, z.fleet.region, z.fleet.address
        );
        if !z.fleet.willing.is_empty() {
            println!("  willing to serve only {:?}", z.fleet.willing);
        }
    }
    let token = std::env::var("VW_TOKEN").unwrap_or_default();
    let urls = directory_urls().await;
    if urls.is_empty() {
        println!("no directory configured (VW_DIRECTORY); serving standalone");
    } else if token.is_empty() {
        println!("VW_DIRECTORY is set but VW_TOKEN is empty; serving standalone");
    } else {
        for url in urls {
            tokio::spawn(select::register_with(url, token.clone(), zone.clone()));
        }
        tokio::spawn(select::decide_loop(zone.clone()));
    }

    // The arena loop. One thread owns the simulation for the duration of a
    // tick; connections only ever enqueue inputs.
    {
        let zone = zone.clone();
        tokio::spawn(async move {
            let mut ticker =
                tokio::time::interval(std::time::Duration::from_micros(1_000_000 / TICK_HZ));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut buf = vec![0u8; sim::PACK_MAX];
            let mut n: u32 = 0;
            loop {
                ticker.tick().await;
                let mut z = zone.lock().await;
                n += 1;
                if n % 300 == 0 {
                    z.reload();
                }
                if n % 3000 == 0 {
                    z.aim_spool();
                }
                // Every room, in order. The process holds one arena per room and
                // ticks them all on this thread: at 16 us for sixty-four ships
                // and 1.6 for two, a hundred duel rooms is a sixth of a core, so
                // there is nothing here a pool would buy.
                let snap = n % SNAPSHOT_EVERY == 0;
                // The roster, on a slow clock rather than only when it changes.
                //
                // Every name a client shows comes from that one message, and
                // `try_send` drops it without a word when a client's queue is
                // full. Sent only on join and on somebody arriving or leaving,
                // one lost roster meant a whole session with a scoreboard of ship
                // numbers and a kill feed reading "ship 5 killed ship 8".
                // Somebody watched that happen in War, and only a page refresh
                // cleared it, because nothing was ever going to send it again.
                //
                // The message is about 125 bytes, so a player taking 20 Hz
                // snapshots at 30 KB/s pays two thousandths of that for a roster
                // that repairs itself.
                let roster = n % 200 == 0;
                let t0 = std::time::Instant::now();
                for a in z.rooms.iter_mut() {
                    a.tick();
                    if snap {
                        a.broadcast_snapshot(&mut buf);
                        a.broadcast_banner();
                    }
                    if roster {
                        // Ballast follows the people. See `rebalance_bots`.
                        a.rebalance_bots();
                        a.broadcast_roster();
                        // On the same clock and for the same reason: these go
                        // out with `try_send`, which drops rather than waits,
                        // and a client that missed one would hold a team list
                        // from before somebody moved.
                        a.broadcast_teams();
                    }
                }
                z.tick_us = t0.elapsed().as_micros() as u32;

                // A drain that has finished is an instance free to choose again,
                // and an empty extra room is memory to give back.
                if n % 100 == 0 {
                    z.reclaim_rooms();
                    if z.draining && z.total_players() == 0 {
                        println!("drain complete");
                        z.draining = false;
                        if let Some((want, who, _)) = z.pinned.clone() {
                            if let Some(def) =
                                z.catalog.as_ref().and_then(|c| c.zone(&want)).cloned()
                            {
                                match z.serve_zone(&def) {
                                    Ok(()) => println!("pinned to {want:?} by {who}"),
                                    Err(e) => println!("cannot serve pinned {want:?}: {e}"),
                                }
                            }
                        }
                        z.push_status();
                    }
                }
            }
        });
    }

    while let Ok((stream, _)) = listener.accept().await {
        let zone = zone.clone();
        let tls = tls.clone();
        tokio::spawn(async move {
            // The TLS handshake happens before the WebSocket one, and a
            // client that fails it is simply a client that never arrives.
            let stream: Box<dyn Conn> = match &tls {
                Some(a) => match a.accept(stream).await {
                    Ok(s) => Box::new(s),
                    Err(_) => return,
                },
                None => Box::new(stream),
            };
            // Incoming frames are capped far below the library default of
            // 64 MiB, which is buffered in full per frame. Nothing a client
            // legitimately sends is bigger than a join -- a tag, a few bytes,
            // a zone name and a call sign -- so a stranger on an open port
            // gets to cost this process kilobytes, not gigabytes.
            let cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
                max_message_size: Some(C2S_MAX),
                max_frame_size: Some(C2S_MAX),
                ..Default::default()
            };
            let ws = match tokio_tungstenite::accept_async_with_config(stream, Some(cfg)).await {
                Ok(w) => w,
                Err(_) => return,
            };
            let (mut sink, mut source) = ws.split();
            let (tx, mut rx) = mpsc::channel::<Message>(OUT_QUEUE);

            let writer = tokio::spawn(async move {
                while let Some(msg) = rx.recv().await {
                    if sink.send(msg).await.is_err() {
                        return;
                    }
                }
                // A proper close once the channel is done, so a refused client
                // sees a closed socket rather than a dropped one and can tell
                // "you are not welcome" from "the network ate it".
                let _ = sink.close().await;
            });

            // This connection's id in the arena, once it has joined.
            // Which room, and which id within it.
            let mut seat: Option<(usize, u64)> = None;
            // A connection that says nothing for this long is gone. A joined
            // client sends its buttons every frame whatever the player is doing,
            // even sitting in the menu, so silence is not idleness. Without this
            // a peer whose network vanished without an RST keeps its seat until
            // the kernel gives up on the socket, which on a full arena is a seat
            // nobody can have.
            let quiet = std::time::Duration::from_secs(75);
            loop {
                let msg = match tokio::time::timeout(quiet, source.next()).await {
                    Ok(Some(Ok(m))) => m,
                    Ok(_) => break,
                    Err(_) => break,
                };
                let data = match msg {
                    Message::Binary(b) => b,
                    Message::Close(_) => break,
                    // Answer the keepalive. Splitting the stream is what made
                    // this necessary: tungstenite queues a pong on the sink half,
                    // which this task does not hold and nothing else flushes, so
                    // a ping went unanswered forever. Browsers never ping, which
                    // is why it took a harness to find -- and why every non-browser
                    // client was dropped at its own ping timeout, forty seconds in.
                    Message::Ping(p) => {
                        let _ = tx.try_send(Message::Pong(p));
                        continue;
                    }
                    _ => continue,
                };
                if data.is_empty() {
                    continue;
                }
                match data[0] {
                    C2S_STATUS => {
                        // Answerable without joining, so a directory or a
                        // browsing player can look before committing.
                        let z = zone.lock().await;
                        let mut m = vec![S2C_STATUS];
                        m.extend_from_slice(z.status_json().as_bytes());
                        let _ = tx.try_send(Message::Binary(m));
                    }
                    C2S_JOIN if seat.is_none() => {
                        let class = data.get(1).copied().unwrap_or(0);
                        let proto = data.get(2).copied().unwrap_or(0);
                        let flags = data.get(3).copied().unwrap_or(0);
                        let is_bot = flags & JOIN_BOT != 0;
                        let zlen = data.get(4).copied().unwrap_or(0) as usize;
                        let nlen = data.get(5).copied().unwrap_or(0) as usize;
                        let want = String::from_utf8_lossy(
                            data.get(6..6 + zlen).unwrap_or_default(),
                        )
                        .to_string();
                        let claimed_name = sanitize_name(&String::from_utf8_lossy(
                            data.get(6 + zlen..6 + zlen + nlen).unwrap_or_default(),
                        ));
                        let presented = String::from_utf8_lossy(
                            data.get(6 + zlen + nlen..).unwrap_or_default(),
                        )
                        .to_string();
                        let mut z = zone.lock().await;

                        // A refusal has to say which of five things went wrong,
                        // because three mean "try another instance" and two mean
                        // "stop trying". The code is the first byte after the tag.
                        let deny = |code: u8, why: &str| {
                            let mut m = vec![S2C_DENIED, code];
                            m.extend_from_slice(why.as_bytes());
                            m
                        };
                        if proto != CLIENT_PROTOCOL {
                            // Before anything else: a client that misparses this
                            // wire would misread every refusal below it too.
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_VERSION,
                                &format!("this zone speaks protocol {CLIENT_PROTOCOL}"),
                            )));
                            break;
                        }
                        // A player picked a game, not an address. This instance may
                        // have changed zone since the browse reply they are acting
                        // on, and sending them into a different game because the
                        // address still answers is worse than telling them to
                        // re-browse.
                        if !want.is_empty() && want != z.zone_name {
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_WRONG_ZONE,
                                &format!(
                                    "this instance serves {:?} now; re-browse",
                                    z.zone_name
                                ),
                            )));
                            break;
                        }
                        // Who this is. A signature and a clock, checked here,
                        // against a key that arrived with the catalog: no
                        // call to the meta-layer, which is what lets it be
                        // down without shutting the door.
                        let seat_of = match z.identify(&presented, &claimed_name, is_bot) {
                            Ok(s) => s,
                            Err(why) => {
                                let _ = tx.try_send(Message::Binary(deny(DENY_BANNED, &why)));
                                break;
                            }
                        };
                        // A zone that wants a field it can vouch for. The
                        // default is `any`, because turning a newcomer away in
                        // the second they arrived is the cost of caring and
                        // most rooms should not pay it.
                        if z.wants_claimed() && seat_of.label == token::Label::Unknown.to_byte() {
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_BANNED,
                                "this zone is for claimed pilots; keep your pilot in the menu first",
                            )));
                            break;
                        }
                        let name = seat_of.name.clone();
                        // A per-zone ban, checked against the name the token
                        // carries. The fleet ban never reaches this door: the
                        // meta-layer refuses a banned account its token, so a
                        // banned pilot arrives holding nothing.
                        if z.is_banned(&name) {
                            let _ = tx.try_send(Message::Binary(deny(DENY_BANNED, "you are banned here")));
                            break;
                        }
                        if z.draining {
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_DRAINING,
                                "this arena is draining; try another instance",
                            )));
                            break;
                        }
                        let _ = tx.try_send(Message::Binary(z.zone_msg()));
                        let cap = z.max_players();
                        // A bot goes where a bot is short, and nowhere when every
                        // room has the population it asked for. It never opens a
                        // room: rooms exist because people arrived.
                        let room = if is_bot { z.room_for_bot() } else { z.room_for_join() };
                        // The fill ladder: fullest room below cap, else a new room
                        // here if the zone allows one, else this instance is out
                        // of room and the client should try the next address.
                        let Some(idx) = room else {
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_FULL,
                                if is_bot {
                                    "this instance wants no more bots"
                                } else {
                                    "no room here; try another instance of this zone"
                                },
                            )));
                            break;
                        };
                        // Into the room they are actually joining. Rooms keep their
                        // own ladders, so putting a returning player's rating in
                        // room zero would leave them unrated wherever they landed.
                        z.restore_pilot(idx, &seat_of);
                        let a = &mut z.rooms[idx];
                        if let Some(new_id) = a.join(seat_of, class, cap, tx.clone()) {
                            seat = Some((idx, new_id));
                            let ship = a.players[&new_id].ship;
                            let mut m = vec![S2C_MAP];
                            m.extend_from_slice(&a.world.packed_map());
                            let _ = tx.try_send(Message::Binary(m));
                            let mut c = vec![S2C_SETTINGS];
                            c.extend_from_slice(&a.world.packed_settings());
                            let _ = tx.try_send(Message::Binary(c));
                            let mut w = vec![S2C_WELCOME, ship];
                            w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                            let _ = tx.try_send(Message::Binary(w));
                            a.broadcast_roster();
                            // Which sides this room holds, who is on them, and
                            // which of their doors are open to this arrival.
                            a.broadcast_teams();
                        } else {
                            let _ = tx.try_send(Message::Binary(deny(DENY_FULL, "no seat in that room")));
                        }
                        // A join changes the count a directory reports, and a
                        // stale count is a directory routing players to the wrong
                        // place, so it goes out now rather than on the heartbeat.
                        z.push_status();
                    }
                    C2S_SHIP => {
                        // A hull change, in place. The core refuses it unless
                        // the pilot is alive and at a full bar, which is what
                        // stops it being an escape from a fight -- a fresh
                        // ship is a fresh bar. Nothing is sent back: the next
                        // snapshot carries the new class, and a refusal leaves
                        // the old one, which is the same answer either way.
                        if data.len() >= 2 {
                            if let Some((room, pid)) = seat {
                                let cls = data[1];
                                let mut z = zone.lock().await;
                                if let Some(a) = z.rooms.get_mut(room) {
                                    let ship = a.players.get(&pid).map(|p| p.ship);
                                    if let Some(ship) = ship {
                                        a.world.set_ship_class(ship, cls);
                                    }
                                }
                            }
                        }
                    }
                    C2S_TEAM => {
                        // Cross to a side. Refused unless the side exists, has
                        // room for one more of this kind, and either belongs
                        // to the zone or has invited this pilot -- and then
                        // refused again by the core unless they are alive and
                        // whole, which is the gate a hull change gets and for
                        // the same reason. Nothing is sent back but the team
                        // list, whose "you are on" byte is the whole answer.
                        if data.len() >= 2 {
                            if let Some((room, pid)) = seat {
                                let want = data[1];
                                let mut z = zone.lock().await;
                                if let Some(a) = z.rooms.get_mut(room) {
                                    if let Some(ship) = a.players.get(&pid).map(|p| p.ship) {
                                        a.join_team(ship, want);
                                    }
                                }
                            }
                        }
                    }
                    C2S_FOUND => {
                        // A side of your own, if the room may hold another.
                        if let Some((room, pid)) = seat {
                            let mut z = zone.lock().await;
                            if let Some(a) = z.rooms.get_mut(room) {
                                if let Some(ship) = a.players.get(&pid).map(|p| p.ship) {
                                    a.found_and_move(ship);
                                }
                            }
                        }
                    }
                    C2S_INVITE => {
                        // Any member may invite, because that is how a group
                        // actually forms. There is no kick to go with it: a
                        // team that wants somebody gone walks away and founds
                        // another, which costs a respawn and no machinery.
                        if data.len() >= 2 {
                            if let Some((room, pid)) = seat {
                                let guest = data[1];
                                let mut z = zone.lock().await;
                                if let Some(a) = z.rooms.get_mut(room) {
                                    if let Some(ship) = a.players.get(&pid).map(|p| p.ship) {
                                        a.invite(ship, guest);
                                    }
                                }
                            }
                        }
                    }
                    C2S_INPUT => {
                        // buttons: u16, tick: u32. The tick says which tick this
                        // input belongs to, and it is honoured: an input for a
                        // tick this room has not reached waits for it, so a
                        // client whose clock leads ours applies the same buttons
                        // on the same tick number we do. One that arrives late
                        // takes effect now, which is what the server did with
                        // every input before this and is still the right answer
                        // for a client with no lead.
                        if data.len() >= 7 {
                            if let Some((room, pid)) = seat {
                                let buttons = u16::from_le_bytes([data[1], data[2]]);
                                let t = u32::from_le_bytes([data[3], data[4], data[5], data[6]]);
                                let mut z = zone.lock().await;
                                if let Some(a) = z.rooms.get_mut(room) {
                                    let now = a.world.state.tick + 1;
                                    if let Some(p) = a.players.get_mut(&pid) {
                                        p.schedule(t, buttons, now);
                                    }
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            if let Some((room, pid)) = seat {
                let mut z = zone.lock().await;
                if let Some(a) = z.rooms.get_mut(room) {
                    a.leave(pid);
                    a.broadcast_roster();
                }
                // An empty room goes back, except the first: a process shrinks as
                // matches end rather than holding its high-water mark.
                z.reclaim_rooms();
                z.push_status();
            }

            // Let the writer drain before it goes. A refusal is enqueued and then
            // the read loop breaks immediately, so aborting here threw away the
            // very byte that tells a client whether to try the next instance or
            // stop trying. Dropping our sender closes the channel, the writer
            // finishes what is in it and exits; the timeout is for the case where
            // the socket is gone and the send will never complete.
            let mut writer = writer;
            drop(tx);
            if tokio::time::timeout(std::time::Duration::from_secs(2), &mut writer)
                .await
                .is_err()
            {
                writer.abort();
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reporting is on unless somebody wrote down that it is off, and the ways
    /// of writing that down are the ways an operator would reach for. Anything
    /// else is on, including nonsense: a typo in a variable meant to silence a
    /// fleet should leave the ladder recording, not quietly stop it.
    #[test]
    fn only_a_deliberate_word_turns_reporting_off() {
        for off in ["0", "off", "false", "no", "OFF", " no ", "False"] {
            assert!(!reporting_from(Some(off)), "{off} should turn it off");
        }
        for on in ["1", "on", "true", "yes", "", "maybe", "0.0"] {
            assert!(reporting_from(Some(on)), "{on} should leave it on");
        }
        assert!(reporting_from(None), "unset reports, which is the point");
    }

    fn parse(toml_src: &str) -> config::ArenaConfig {
        let z: config::ZoneConfig = toml::from_str(toml_src).expect("zone file parses");
        z.arena
    }

    /// The tables a zone file produces, which is the only thing a client
    /// ever sees of it.
    fn tuned(toml_src: &str) -> (sim::World, Vec<String>) {
        let mut w = sim::World::new(1);
        let warn = Arena::apply_config(&mut w, &parse(toml_src));
        (w, warn)
    }

    fn gun(w: &sim::World, cls: usize) -> (sim::sim_fire_pattern, sim::sim_weapon_spec) {
        let p = w.cfg.patterns[w.cfg.classes[cls].trigger[0][0] as usize];
        (p, w.cfg.specs[p.spec as usize])
    }

    // ---- input scheduling --------------------------------------------------

    fn a_player() -> Player {
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        // Held so the sender does not see a closed channel, though nothing here
        // sends: these tests are about which tick a button lands on.
        std::mem::forget(rx);
        Player {
            ship: 0,
            buttons: 0,
            pending: Default::default(),
            last_input_tick: 0,
            name: "probe".into(),
            rid: "probe".into(),
            bot: false,
            tx,
        }
    }

    /// The point of the whole exercise. A client running its clock ahead sends
    /// an input before the tick it belongs to, and it has to wait there rather
    /// than taking effect on arrival, or the two ends brake on different ticks.
    #[test]
    fn an_input_waits_for_the_tick_it_names() {
        let mut p = a_player();
        p.schedule(105, sim::BTN_FIRE, 100);
        for t in 100..105 {
            assert_eq!(p.buttons_at(t), 0, "fire took effect early, on tick {t}");
        }
        assert_eq!(p.buttons_at(105), sim::BTN_FIRE, "fire missed its own tick");
        // And stays held afterwards, because a key held down is the common case
        // and a tick with nothing scheduled must not read as hands off.
        assert_eq!(p.buttons_at(106), sim::BTN_FIRE);
        assert_eq!(p.buttons_at(140), sim::BTN_FIRE);
    }

    /// A client with no lead, which is every client until one ships with it.
    /// Its inputs name ticks that have already run, and the honest answer is to
    /// apply them now: the server must not rewind the room for one late packet.
    #[test]
    fn an_input_that_arrives_late_applies_now() {
        let mut p = a_player();
        p.schedule(90, sim::BTN_THRUST, 100);
        assert_eq!(p.buttons_at(100), sim::BTN_THRUST);
        assert!(p.pending.is_empty(), "a late input has nothing to wait for");
    }

    /// Ticks arrive in order on this transport, but the clamp can lower one, so
    /// the queue is keyed by tick rather than by arrival. Out of order in, in
    /// order out.
    #[test]
    fn scheduled_inputs_come_out_in_tick_order() {
        let mut p = a_player();
        p.schedule(112, sim::BTN_FIRE, 100);
        p.schedule(105, sim::BTN_THRUST, 100);
        assert_eq!(p.buttons_at(105), sim::BTN_THRUST);
        assert_eq!(p.buttons_at(111), sim::BTN_THRUST);
        assert_eq!(p.buttons_at(112), sim::BTN_FIRE);
    }

    /// A repeat for a tick already spoken for is the client correcting itself
    /// inside the window, so the newer one is what it meant.
    #[test]
    fn the_newest_input_for_a_tick_wins() {
        let mut p = a_player();
        p.schedule(105, sim::BTN_FIRE, 100);
        p.schedule(105, sim::BTN_THRUST, 100);
        assert_eq!(p.buttons_at(105), sim::BTN_THRUST);
    }

    /// A clock that has drifted is a client to correct, not one to disconnect,
    /// so an absurd lead is clamped rather than refused. Without this a client
    /// could queue a minute of flying and then stop sending.
    #[test]
    fn a_wild_lead_is_clamped_rather_than_honoured() {
        let mut p = a_player();
        p.schedule(100_000, sim::BTN_FIRE, 100);
        assert_eq!(
            *p.pending.keys().next().unwrap(),
            100 + INPUT_LEAD_MAX,
            "an input a minute ahead should land at the ceiling"
        );
    }

    /// The echoed tick is what the arena accepted, not what was asked for. A
    /// client steers its clock off this number, so a clamped input that
    /// reported its unclamped tick would tell the client its inputs were
    /// arriving impossibly early and drive the lead to zero.
    #[test]
    fn the_echoed_tick_is_the_one_that_was_accepted() {
        let mut p = a_player();
        p.schedule(u32::MAX, sim::BTN_FIRE, 100);
        assert_eq!(p.last_input_tick, 100 + INPUT_LEAD_MAX);
    }

    /// A room that has been up for 497 days is at u32::MAX. The ceiling has to
    /// saturate there rather than wrap: a wrapped ceiling clamps every input to
    /// a tick in the distant past, which `buttons_at` then drains immediately,
    /// so every client in the room would go rigid at once.
    #[test]
    fn the_lead_ceiling_saturates_at_the_end_of_the_clock() {
        let mut p = a_player();
        let now = u32::MAX - 10;
        p.schedule(u32::MAX, sim::BTN_FIRE, now);
        assert_eq!(p.buttons_at(now), 0, "not before its tick");
        assert_eq!(p.buttons_at(u32::MAX), sim::BTN_FIRE, "and not lost either");
    }

    /// And a client that floods cannot grow the arena's memory with it.
    #[test]
    fn the_input_queue_is_bounded() {
        let mut p = a_player();
        for t in 1..=(INPUT_QUEUE_MAX as u32 * 3) {
            p.schedule(100 + t, sim::BTN_FIRE, 100);
        }
        assert!(p.pending.len() <= INPUT_QUEUE_MAX, "queue grew to {}", p.pending.len());
    }

    /// The compiled ladder has to name the roster this binary actually flies,
    /// or it seeds nothing and every bot starts level. That is not a crash and
    /// not a log line; it is a room that plays slightly wrong, which is why it
    /// ran on the live fleet unnoticed while the path was pointing into a
    /// directory the image never created.
    #[test]
    fn the_compiled_ladder_covers_the_roster() {
        let ladder: HashMap<String, f64> =
            serde_json::from_str(LADDER).expect("the compiled ladder parses");
        for (name, _, _) in ai::CALIBRATED {
            assert!(ladder.contains_key(name), "{name} has no calibrated rating");
        }
        assert_eq!(
            ladder.get(ai::ANCHOR).copied(),
            Some(ai::ANCHOR_RATING),
            "the anchor is fixed by definition, so the ladder has to agree with it"
        );
    }

    /// And it has to reach a room, including one opened long after startup.
    /// `open_room` and `serve_zone` each went back to the disk for it and named
    /// a path relative to the working directory, so on the fleet they found
    /// nothing and primed nothing. The ladder is held on the zone now, and the
    /// second room is the one that proves it.
    #[test]
    fn a_room_opened_later_carries_the_ladder() {
        // A ladder with a value the compiled one cannot produce, so this test
        // can tell "read the ladder this process was given" apart from "read
        // some ladder". With the path hardcoded, the second room fell back to
        // the compiled numbers and the assertion below caught it.
        let dir = std::env::temp_dir().join("vw-ladder-test");
        std::fs::create_dir_all(&dir).expect("temp dir");
        std::fs::write(dir.join("ladder.json"), r#"{"Kestrel": 1777.5}"#).expect("write");
        let ladder = load_ladder(dir.to_str().unwrap());
        assert_eq!(ladder.get("Kestrel").copied(), Some(1777.5), "the file wins");

        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(
            cfg,
            test_spool(),
            ladder,
        );
        let def = wire_zone(4, 2, 8);
        z.catalog = Some(fleet::WireCatalog {
            version: 1,
            name: "test".into(),
            default_zone: "testzone".into(),
            zones: vec![def.clone()],
            ..Default::default()
        });
        z.serve_zone(&def).expect("a room");
        let room = z.open_room().expect("a second room");
        let seeded = z.rooms[room].rating.score.get("Kestrel").copied().unwrap_or_default();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(
            seeded, 1777.5,
            "the second room did not get the ladder this process was given"
        );
    }

    // ---- rooms on demand ---------------------------------------------------
    //
    // The fill ladder's first two rungs live entirely inside one process, so
    // they are testable without a directory, a socket, or a second binary.

    /// A zone as a catalog would deliver it, with a real packed map so
    /// `build_room` takes the same path it takes in production.
    fn wire_zone(rooms: u32, target: u32, cap: u32) -> fleet::WireZone {
        fleet::WireZone {
            name: "testzone".into(),
            description: "a zone for tests".into(),
            mode: "arena".into(),
            max_ships: 64,
            max_players: cap,
            fill_target: target,
            max_rooms: rooms,
            admission: "any".into(),
            bot_fill: 0.0,
            map_b64: fleet::b64(&sim::World::new(1).packed_map()),
            // A zone's name lives in the catalog that references it, never in the
            // zone's own file, so there is one place a name can be.
            zone_toml: "description = \"a zone for tests\"\n".into(),
        }
    }

    // ---- identity ----------------------------------------------------------

    /// A fixed key for both halves of the exchange, so a failure here is a
    /// failure rather than a coin flip.
    fn meta_key() -> ed25519_dalek::SigningKey {
        ed25519_dalek::SigningKey::from_bytes(&[3u8; 32])
    }

    /// A zone whose catalog carries the meta-layer's verifying key, which is
    /// the whole of what an arena needs to know who anybody is.
    fn serving_with_accounts() -> Zone {
        let mut z = serving(1, 6, 16);
        if let Some(c) = z.catalog.as_mut() {
            c.meta_key = token::to_hex(meta_key().verifying_key().as_bytes());
        }
        z
    }

    fn a_token(kind: token::Kind, claimed: bool, name: &str, ratings: Vec<token::ClassRating>)
        -> String
    {
        a_token_for(4242, kind, claimed, name, ratings)
    }

    fn a_token_for(account: u64, kind: token::Kind, claimed: bool, name: &str,
                   ratings: Vec<token::ClassRating>) -> String {
        token::mint(&meta_key(), &token::Claims {
            account,
            kind,
            claimed,
            name: name.into(),
            expires: token::now_secs() + 600,
            ratings,
        })
    }

    #[test]
    fn a_signed_token_names_the_pilot_and_their_account() {
        let z = serving_with_accounts();
        let t = a_token(token::Kind::Human, true, "Vesper 47", vec![]);
        let seat = z.identify(&t, "whatever the client typed", false).expect("verifies");
        // The name comes from the token, not from the client. A pilot cannot
        // wear somebody else's call sign by asking to.
        assert_eq!(seat.name, "Vesper 47");
        assert_eq!(seat.account, Some(4242));
        assert_eq!(seat.rid, "a4242");
        assert_eq!(seat.label, token::Label::Human.to_byte());
    }

    #[test]
    fn a_guest_is_unknown_rather_than_human() {
        let z = serving_with_accounts();
        let t = a_token(token::Kind::Human, false, "Talon 3", vec![]);
        let seat = z.identify(&t, "", false).expect("verifies");
        assert_eq!(seat.label, token::Label::Unknown.to_byte(),
                   "an unclaimed account is somebody we cannot vouch for");
        assert_eq!(seat.account, Some(4242), "which does not make them anonymous");
    }

    #[test]
    fn a_house_bot_and_a_third_party_bot_are_told_apart() {
        let z = serving_with_accounts();
        let house = z
            .identify(&a_token(token::Kind::HouseBot, true, "Nine", vec![]), "", true)
            .expect("verifies");
        assert_eq!(house.label, token::Label::HouseBot.to_byte());
        let theirs = z
            .identify(&a_token(token::Kind::ThirdPartyBot, true, "Someone", vec![]), "", true)
            .expect("verifies");
        assert_eq!(theirs.label, token::Label::ThirdPartyBot.to_byte());
        // And a bot flying with no account at all is somebody else's by
        // definition, since ours all have one.
        let undeclared = z.identify("", "Anon", true).expect("no token is still a seat");
        assert_eq!(undeclared.label, token::Label::ThirdPartyBot.to_byte());
        assert_eq!(undeclared.account, None);
    }

    #[test]
    fn a_declaration_that_disagrees_with_the_account_is_refused() {
        let z = serving_with_accounts();
        // A bot account that stayed quiet would sit in a human seat wearing a
        // human's label, which is the one thing the declaration exists to stop.
        let quiet_bot = a_token(token::Kind::HouseBot, true, "Nine", vec![]);
        assert!(z.identify(&quiet_bot, "", false).is_err());
        // And a human account claiming the bot exemption takes a seat that the
        // cap was supposed to protect.
        let loud_human = a_token(token::Kind::Human, true, "Vesper 47", vec![]);
        assert!(z.identify(&loud_human, "", true).is_err());
    }

    #[test]
    fn a_forged_or_expired_token_does_not_get_in() {
        let z = serving_with_accounts();
        let other = ed25519_dalek::SigningKey::from_bytes(&[9u8; 32]);
        let forged = token::mint(&other, &token::Claims {
            account: 1, kind: token::Kind::Human, claimed: true,
            name: "Impostor".into(), expires: token::now_secs() + 600, ratings: vec![],
        });
        assert!(z.identify(&forged, "", false).is_err(), "another key is not our key");

        let stale = token::mint(&meta_key(), &token::Claims {
            account: 1, kind: token::Kind::Human, claimed: true,
            name: "Yesterday".into(), expires: token::now_secs() - 1, ratings: vec![],
        });
        let why = z.identify(&stale, "", false).expect_err("expired");
        assert!(why.contains("log in again"), "an expired token is a login, not an accusation");
    }

    #[test]
    fn without_a_meta_layer_everybody_flies_as_a_guest() {
        // The supported no-accounts arrangement, and also what an outage looks
        // like from inside a room: play continues, nothing durable is written.
        let z = serving(1, 6, 16);
        let t = a_token(token::Kind::Human, true, "Vesper 47", vec![]);
        let seat = z.identify(&t, "Local Name", false).expect("a seat regardless");
        assert_eq!(seat.account, None, "no key in the catalog, so no token is read");
        assert_eq!(seat.name, "Local Name");
        assert_eq!(seat.label, token::Label::Unknown.to_byte());
    }

    #[test]
    fn a_carried_rating_seeds_the_room_and_a_new_class_does_not() {
        let mut z = serving_with_accounts();
        let t = a_token(token::Kind::Human, true, "Veteran", vec![
            token::ClassRating { class: "arena".into(), rating: 1640.0, games: 40 },
            token::ClassRating { class: "hockey".into(), rating: 1000.0, games: 5 },
        ]);
        let seat = z.identify(&t, "", false).expect("verifies");
        let rid = seat.rid.clone();
        z.restore_pilot(0, &seat);
        // The zone's mode is the class, and this one is an arena.
        assert_eq!(z.rating_class(), "arena");
        assert_eq!(z.rooms[0].rating.rating_of(&rid), 1640.0);
        assert_eq!(z.rooms[0].rating.games_of(&rid), 40, "a rating without its count places again");

        // A pilot who has never played this zone's class arrives unrated,
        // which is what a first game in a new class is supposed to be.
        let fresh = a_token_for(99, token::Kind::Human, true, "Newcomer", vec![
            token::ClassRating { class: "hockey".into(), rating: 1900.0, games: 99 },
        ]);
        let fresh = z.identify(&fresh, "", false).expect("verifies");
        z.restore_pilot(0, &fresh);
        assert_eq!(z.rooms[0].rating.games_of(&fresh.rid), 0);
    }

    /// A spool aimed nowhere, which is what a room that is not handing off
    /// anywhere holds. Writes nothing, because it is not armed.
    fn test_spool() -> std::sync::Arc<std::sync::Mutex<spool::Spool>> {
        std::sync::Arc::new(std::sync::Mutex::new(spool::Spool::new("/nonexistent")))
    }

    /// A zone process already serving that definition. No config file and no
    /// store file: both read defaults when the path is absent, which is what a
    /// catalog-served arena runs on anyway.
    fn serving(rooms: u32, target: u32, cap: u32) -> Zone {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, test_spool(),
                              HashMap::new());
        let def = wire_zone(rooms, target, cap);
        z.catalog = Some(fleet::WireCatalog {
            version: 1,
            name: "test".into(),
            default_zone: "testzone".into(),
            zones: vec![def.clone()],
            ..Default::default()
        });
        z.serve_zone(&def).expect("the definition builds a room");
        z
    }

    /// Seat `n` players in a room without a socket on the other end. A dropped
    /// receiver is fine: every send is `let _ =`, because a client that has gone
    /// away must not take the tick loop with it.
    fn seat(z: &mut Zone, room: usize, n: usize) {
        let cap = z.max_players();
        for i in 0..n {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[room]
                .join(Seat::guest(format!("p{room}-{i}"), false), 0, cap, tx)
                .expect("a seat below the cap");
        }
    }

    /// The same, for bots, and it is the same call: a bot joins through the
    /// front door now, so a test that wants a populated room does what the bot
    /// server does rather than reaching into the arena to plant one.
    ///
    /// Returns the ship each took, since a bot's seat is chosen by the arena.
    fn seat_bots(a: &mut Arena, n: usize) -> Vec<u8> {
        let mut out = Vec::new();
        for i in 0..n {
            let (tx, rx) = mpsc::channel(OUT_QUEUE);
            // Held, because a bot that is evicted is sent a yield and a closed
            // receiver would make that send fail silently in a test that is
            // about to check it happened.
            std::mem::forget(rx);
            let e = ai::individual(i);
            let id = a
                .join(Seat::guest(e.name.clone(), true), e.class, 0, tx)
                .expect("a seat for a bot");
            out.push(a.players[&id].ship);
        }
        out
    }

    // ---- bots as clients ---------------------------------------------------

    #[test]
    fn a_bot_does_not_use_up_a_human_seat() {
        // The declaration's whole point. `max_players` bounds people, and a zone
        // that holds a wide room mostly full of AI has to keep admitting every
        // human its operator allowed: an arena that counted bots against the cap
        // would refuse the second player to a room with sixty-two free seats.
        let mut z = serving(1, 4, 4);
        seat_bots(&mut z.rooms[0], 20);
        assert_eq!(z.rooms[0].humans(), 0, "twenty bots are nobody");
        assert_eq!(z.rooms[0].bot_count(), 20);

        for i in 0..4 {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            assert!(
                z.rooms[0].join(Seat::guest(format!("h{i}"), false), 0, 4, tx).is_some(),
                "human {i} was refused a seat a bot was not holding"
            );
        }
        // And the cap is still a cap.
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        assert!(z.rooms[0].join(Seat::guest("overflow", false), 0, 4, tx).is_none());
    }

    #[test]
    fn a_room_full_of_bots_still_has_room_for_a_person() {
        // The backstop under the bot server's headroom. It leaves a fifth of the
        // room empty so this never fires, and a burst of joins between two
        // browses can outrun that: the arena has to make its own space rather
        // than tell a player that a room full of AI is full.
        let mut z = serving(1, 4, 32);
        let seats = z.rooms[0].world.cfg.max_ships as usize;
        let seated = seat_bots(&mut z.rooms[0], seats);
        assert_eq!(seated.len(), seats, "every seat taken by a bot");

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0]
            .join(Seat::guest("latecomer", false), 0, 32, tx)
            .expect("a room of bots is not full");
        assert_eq!(z.rooms[0].humans(), 1);
        assert_eq!(z.rooms[0].bot_count(), seats - 1, "exactly one bot gave way");
        // The newest, because a bot that has been in the room a while is in the
        // middle of something and the one that arrived a moment ago is not.
        assert_eq!(
            z.rooms[0].players[&id].ship,
            *seated.last().unwrap(),
            "the seat taken is the newest bot's"
        );
    }

    #[test]
    fn bots_yield_one_for_one_and_never_below_zero() {
        // What a player actually sees: a room held at four fifths, and their
        // arrival costing the room one bot rather than emptying it or changing
        // nothing. 64 seats at 0.8 is 51, so one human means 50 bots wanted.
        let mut z = serving(1, 4, 32);
        z.rooms[0].bot_fill = 0.8;
        assert_eq!(z.rooms[0].bot_target(), 51);
        assert_eq!(z.rooms[0].bots_wanted(), 51);

        for i in 0..3 {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[0].join(Seat::guest(format!("h{i}"), false), 0, 32, tx).expect("a seat");
            assert_eq!(z.rooms[0].bots_wanted(), 51 - (i + 1),
                       "one human in is one bot out");
        }

        // Past the target the answer is zero rather than a negative number
        // wrapping into an enormous one, which is what `saturating_sub` is for.
        for i in 3..32 {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[0].join(Seat::guest(format!("h{i}"), false), 0, 32, tx).expect("a seat");
        }
        assert_eq!(z.rooms[0].humans(), 32);
        assert_eq!(z.rooms[0].bots_wanted(), 19);

        // A zone that wants no bots says so, and is believed.
        z.rooms[0].bot_fill = 0.0;
        assert_eq!(z.rooms[0].bots_wanted(), 0);
    }

    #[test]
    fn bots_do_not_hold_a_room_open_against_the_fill_ladder() {
        // Every count that decides anything is a count of people. A room the bot
        // server holds at four fifths would otherwise read as permanently at
        // target, so the zone would open its second room for its second player
        // and scatter the population the ladder exists to concentrate.
        let mut z = serving(2, 4, 16);
        seat_bots(&mut z.rooms[0], 30);
        assert_eq!(z.room_for_join(), Some(0), "a room of bots wants people");
        assert_eq!(z.rooms.len(), 1, "and did not grow a sibling to hold them");
        assert!(!z.status().capped, "nor does it report itself out of room");

        seat(&mut z, 0, 4);
        assert_eq!(z.room_for_join(), Some(1), "four people is the target");
    }

    #[test]
    fn draining_sends_the_bots_home() {
        // Bots would otherwise hold a draining instance at four fifths for ever:
        // `total_players` never reaches zero, the drain never completes, and the
        // instance never gets to choose another zone. Two things stop that, and
        // this is the fast one; the other is publishing a want of zero so the
        // bot server does not put back what this let go.
        let mut z = serving(1, 4, 16);
        seat_bots(&mut z.rooms[0], 12);
        seat(&mut z, 0, 2);
        assert_eq!(z.bots_wanted(), z.rooms[0].bot_target() - 2);

        let gone = z.begin_drain();
        assert_eq!(gone, 12, "every bot was told");
        assert_eq!(z.total_bots(), 0);
        assert_eq!(z.bots_wanted(), 0, "and none are asked for while draining");
        assert_eq!(z.total_players(), 2, "the people are left alone");
        assert_eq!(z.room_for_bot(), None, "a draining room takes no bots");
    }

    #[test]
    fn a_bot_goes_to_the_room_that_is_shortest_of_them() {
        // The other half of "a bot is not a player". An arrival goes to the
        // fullest room, which concentrates people; a bot going there would stack
        // the whole population into room one and leave a room opened for players
        // with nobody in it to fight.
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        z.room_for_join().expect("a second room opens");
        assert_eq!(z.rooms.len(), 2);

        seat_bots(&mut z.rooms[0], 40);
        assert_eq!(z.room_for_bot(), Some(1), "the empty room is the short one");

        // And a bot never opens a room of its own: rooms exist because people
        // arrived. Fill both to target and the answer is nobody wants one.
        let target = z.rooms[0].bot_target();
        seat_bots(&mut z.rooms[1], target);
        seat_bots(&mut z.rooms[0], target - 40);
        assert_eq!(z.room_for_bot(), None);
        assert_eq!(z.rooms.len(), 2, "and no third room was built to hold bots");
    }

    #[test]
    fn a_declared_bot_is_labelled_and_rated_as_one() {
        // Players deserve to know who they are fighting, and a rating system
        // that quietly mixes bots into your record is one nobody will trust.
        // Both come from what the client declared rather than from a roster the
        // arena holds a copy of, because the bot server draws from a much longer
        // list than the nine the tournament calibrated.
        let mut z = serving(1, 4, 16);
        let ship = seat_bots(&mut z.rooms[0], 1)[0];
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        z.rooms[0].join(Seat::guest("Person", false), 0, 16, tx).expect("a seat");

        let a = &z.rooms[0];
        assert_eq!(a.names[&ship].bot, true, "the bot says so on the scoreboard");
        let human = a.names.iter().find(|(_, k)| k.name == "Person").unwrap();
        assert_eq!(human.1.bot, false);
        // A generated pilot is as much a bot as a calibrated one. `Aperture` is
        // the tenth individual, so it is past the nine in the ladder.
        let tenth = ai::individual(9);
        assert!(!ai::CALIBRATED.iter().any(|(n, _, _)| *n == tenth.name));
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        z.rooms[0].join(Seat::guest(tenth.name.clone(), true), 0, 16, tx).expect("a seat");
        // Marked, which is what holds its K down so a human who kills it moves
        // further than it does.
        assert!(z.rooms[0].rating.is_bot(&tenth.name),
                "{} rates as a human", tenth.name);
        assert!(!z.rooms[0].rating.is_bot("Person"));
    }

    #[test]
    fn every_individual_the_bot_server_can_fly_is_its_own_pilot() {
        // One individual, one place, which is what makes a bot's rating the
        // record of one career rather than an average over clones. The bot
        // server allocates names from this list and a repeat would put two
        // pilots on one row.
        let mut seen = std::collections::HashSet::new();
        for n in 0..300 {
            let e = ai::individual(n);
            assert!(seen.insert(e.name.clone()), "individual {n} repeats a name");
            assert!(e.class < 8, "{} flies a hull that does not exist", e.name);
            assert!(e.skill > 0.0 && e.skill <= 1.0, "{} has no skill", e.name);
            assert_eq!(e.name, sanitize_name(&e.name), "{} needs sanitising", e.name);
        }
        // The calibrated nine come first, because they are the pilots whose
        // ratings mean anything.
        for (i, (name, _, _)) in ai::CALIBRATED.iter().enumerate() {
            assert_eq!(&ai::individual(i).name, name);
        }
    }

    /// How long a War round takes and who wins it, with the shipped roster
    /// flying. Measurement rather than assertion, so it is ignored by default:
    /// `cargo test round_pace -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn round_pace() {
        let mut def = wire_zone(1, 16, 32);
        def.mode = "warzone".into();
        def.zone_toml = "description = \"war\"\nteams = [\"Keel\", \"Vantage\"]\n\
                         [arena]\nflags = 4\n".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, test_spool(),
                              HashMap::new());
        z.serve_zone(&def).expect("a room");
        // The bot server would put these here. A round needs a population and
        // this test is about how long one takes, so it seats its own rather
        // than standing up a directory to be told the same number.
        let mut brains: Vec<ai::Bot> = Vec::new();
        for (i, ship) in seat_bots(&mut z.rooms[0], 12).into_iter().enumerate() {
            brains.push(ai::Bot::new(ship, ai::individual(i).skill));
        }
        let route = nav::Nav::build(&z.rooms[0].world.map);
        let sides: Vec<u8> = z.rooms[0].world.state.ships.iter()
            .filter(|s| s.active != 0).map(|s| s.team).collect();
        let a = sides.iter().filter(|t| **t == 0).count();
        println!("roster sides: {a} against {}", sides.len() - a);

        // Ten minutes of arena time. Counted by the round number in the
        // banner, not by the banner: a win holds its message for the whole
        // five-second reset, so matching the string counts one round many times.
        let mut seen = std::collections::HashSet::new();
        let mut at = 0u32;
        let mut rounds = Vec::new();
        for n in 0..60_000u32 {
            // The buttons the bot server would have sent, put straight on the
            // players. Over a socket this is the same bytes and one more hop.
            for b in brains.iter_mut() {
                let ship = b.ship;
                let fresh = b.looks_due().then(|| ai::scan(&z.rooms[0].world, ship));
                let buttons = b.think(&ai::own(&z.rooms[0].world, ship), &route, fresh);
                if let Some(p) = z.rooms[0].players.values_mut().find(|p| p.ship == ship) {
                    p.buttons = buttons;
                }
            }
            z.rooms[0].tick();
            let m = z.rooms[0].banner.clone();
            if let Some(rest) = m.strip_prefix("team ") {
                if let Some(num) = rest.split("wins round ").nth(1) {
                    if seen.insert(num.to_string()) {
                        rounds.push((m.clone(), (n - at) as f64 / 100.0));
                        at = n;
                    }
                }
            }
        }
        println!("{} rounds in 600 s of arena time", rounds.len());
        for (who, secs) in rounds.iter().take(12) {
            println!("  {secs:6.1}s  {who}");
        }
    }

    #[test]
    fn a_flag_is_somewhere_a_pilot_will_find_it() {
        // The flag game ran for four minutes on the live server with forty-two
        // kills and not one flag touched, because the flags were two hundred
        // tiles from every spawn and a pilot sees sixty. A flag nobody can reach
        // is a round nobody can win, and neither end of that says so: the arena
        // is healthy, the fighting works, the banner just never moves.
        // Measured against the middle of the map rather than against any one
        // map's spawns: the two shipped zones start their pilots in a 68-tile box
        // there, and a pilot with nothing in sight roams to the same place, so
        // "on the radar from the middle" is the property that makes a flag
        // findable however the map places its starts.
        let mut z = serving(1, 6, 16);
        let a = &mut z.rooms[0];
        a.add_default_flags();
        assert!(a.world.state.flag_count > 0, "flags were placed");
        let mid = (sim::MAP_TILES as f32 / 2.0) * 16.0;

        let mut spacing = f32::MAX;
        for i in 0..a.world.state.flag_count as usize {
            let f = a.world.state.flags[i];
            let (fx, fy) = (f.x as f32 / 256.0, f.y as f32 / 256.0);
            let d = ((fx - mid).powi(2) + (fy - mid).powi(2)).sqrt();
            assert!(d <= ai::SIGHT,
                    "flag {i} is {d:.0} px from the middle, and a pilot sees {}",
                    ai::SIGHT);
            for k in 0..i {
                let g = a.world.state.flags[k];
                let (gx, gy) = (g.x as f32 / 256.0, g.y as f32 / 256.0);
                spacing = spacing.min(((fx - gx).powi(2) + (fy - gy).powi(2)).sqrt());
            }
        }
        // And not a scrum: neighbours far enough apart that one pilot cannot sit
        // on the whole set. They were four tiles apart once, which was one fight
        // in one room and the reason they were flung to the corners.
        assert!(spacing >= 40.0 * 16.0,
                "flags are {spacing:.0} px apart, which one pilot covers at once");
    }

    #[test]
    fn a_free_for_all_has_enemies_in_it() {
        // Chaos ran for a day with nothing able to hit anything. `teams = 1` put
        // every pilot on side zero, and every hostility test in the stack is
        // whether two sides differ: no weapon could reach a ship, no kill paid,
        // and no bot could see a target, so nine of them sat still while a
        // player flew around an arena that could not fight back.
        let mut z = serving(1, 6, 16);
        assert!(z.rooms[0].free_for_all(), "the fixture is a one-team zone");
        let seats = seat_bots(&mut z.rooms[0], 4);

        let a = &z.rooms[0];
        let mut sides = std::collections::HashSet::new();
        let mut ships = 0;
        for (i, s) in a.world.state.ships.iter().enumerate() {
            if s.active == 0 {
                continue;
            }
            ships += 1;
            assert!(sides.insert(s.team), "ship {i} shares a side with somebody");
            assert_ne!(s.team, sim::TEAM_NONE, "a pilot is never nobody's side");
        }
        assert!(ships >= 2, "a roster to fight over");

        // And the bots' own perception, which is where the symptom was: a
        // pilot with a teammate in front of them sees nobody, plans nothing,
        // and holds still. Put two together rather than trusting the map's
        // starts, so this measures the rule and not the geometry.
        let (a, b) = (seats[0], seats[1]);
        let room = &mut z.rooms[0];
        room.world.state.ships[b as usize].x = room.world.state.ships[a as usize].x + 40 * 256;
        room.world.state.ships[b as usize].y = room.world.state.ships[a as usize].y;
        assert!(ai::scan(&room.world, a).foe.is_some(), "nobody to fight");
        assert!(ai::scan(&room.world, b).foe.is_some(), "and not one-sided");

        // And a joining human is their own side too, not folded in with the
        // pilot whose seat they took.
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join(Seat::guest("human", false), 0, 16, tx).expect("a seat");
        let ship = z.rooms[0].players[&id].ship;
        let mine = z.rooms[0].world.state.ships[ship as usize].team;
        for (i, s) in z.rooms[0].world.state.ships.iter().enumerate() {
            if s.active == 0 || i as u8 == ship {
                continue;
            }
            assert_ne!(s.team, mine, "the human shares a side with ship {i}");
        }
    }

    #[test]
    fn a_pilot_who_can_see_nobody_goes_looking() {
        // The other reason the arena was full of statues. A bot with nothing in
        // sight returned no buttons at all, so it stopped where it stood and
        // stayed there for as long as the room was up.
        let mut z = serving(1, 6, 16);
        let a = &mut z.rooms[0];
        // Alone: one pilot and nobody else, so there is provably nothing for
        // them to see.
        let keep = seat_bots(a, 1)[0];
        let mut bot = ai::Bot::new(keep, 0.5);
        let route = nav::Nav::build(&a.world.map);
        let mut moved = false;
        for _ in 0..400 {
            let fresh = bot.looks_due().then(|| ai::scan(&a.world, keep));
            let buttons = bot.think(&ai::own(&a.world, keep), &route, fresh);
            a.world.step(&[sim::sim_input { ship: keep, buttons }]);
            let sh = &a.world.state.ships[keep as usize];
            if sh.vx != 0 || sh.vy != 0 {
                moved = true;
                break;
            }
        }
        assert!(moved, "a pilot with nobody in sight sat still instead of looking");
    }

    /// Put one green on the map, wherever asked, and nothing else.
    fn only_prize(w: &mut sim::World, tile_x: i32, tile_y: i32) {
        for p in w.state.prizes.iter_mut() {
            p.active = 0;
        }
        w.state.prizes[0] = sim::sim_prize {
            active: 1,
            x: (tile_x * 16 + 8) * 256,
            y: (tile_y * 16 + 8) * 256,
            life: 30_000,
        };
    }

    #[test]
    fn a_green_behind_a_wall_is_not_a_green_worth_chasing() {
        // Reported from the live server: bots with their noses against a wall and
        // a green on the other side of it. Selection tested distance and nothing
        // else, and a green does not move, so the next plan chose the same one,
        // for the same reason, for ever.
        //
        // The pit's inner block spans tiles 505 to 508. A pilot at 503 has it
        // between them and anything at 511 on the same row, and open floor above.
        let mut w = sim::World::with_map(1, sim::build_pit);
        let ship = w.spawn(0, 0, 503, 506, 0) as u8;

        only_prize(&mut w, 503, 502);
        assert!(
            ai::scan(&w, ship).prize.is_some(),
            "a green four tiles away across open floor is worth the detour"
        );

        only_prize(&mut w, 511, 506);
        assert!(
            ai::scan(&w, ship).prize.is_none(),
            "a green with a wall in front of it was chosen anyway"
        );
    }

    #[test]
    fn a_pilot_pushing_at_a_wall_eventually_does_something_else() {
        // The case the line of sight test above cannot catch: somewhere visible,
        // not behind a straight wall, and still not reachable, which is what a
        // corner is. So the green is handed over directly rather than found by
        // `scan`, and the only way out is the pilot noticing it is not getting
        // any closer.
        //
        // An enemy sits in range throughout. Greens are chosen before foes and a
        // pilot running one takes its hands off the trigger, so a shot fired is
        // proof the green was abandoned: it cannot fire until it has been.
        let mut w = sim::World::with_map(1, sim::build_pit);
        let ship = w.spawn(0, 0, 503, 506, 0) as u8;
        let mut bot = ai::Bot::new(ship, 0.5);

        let px = |t: i32| (t * 16 + 8) as f32;
        let stuck_on = ai::Scan {
            prize: Some((px(511), px(506))),
            foe: Some(ai::Foe { x: px(503), y: px(517), vx: 0.0, vy: 0.0, clear: true }),
            flag: None,
            threat: None,
            // Hand-built, so the whiskers say open on purpose: this test is
            // about giving up on a green behind a wall, and a bot that could
            // see the wall would never press into it to begin with.
            clear: [1e9; ai::WHISKERS],
        };

        let route = nav::Nav::build(&w.map);
        let mut fired_at = None;
        for t in 0..2500u32 {
            // Handed over once and never refreshed. Working from a stale picture
            // is the ordinary case for these pilots, and here it is what keeps
            // the unreachable green in front of them.
            let fresh = (t == 0).then(|| stuck_on.clone());
            let buttons = bot.think(&ai::own(&w, ship), &route, fresh);
            if buttons & (sim::BTN_FIRE | sim::BTN_BOMB) != 0 && fired_at.is_none() {
                fired_at = Some(t);
            }
            w.step(&[sim::sim_input { ship, buttons }]);
        }
        // Measured at 290 before there was a router: two seconds of no progress
        // plus a reaction cycle to act on it and one more to line up the shot.
        // The router moved it to about 1450, and the extra is the pilot being
        // right about the geometry the whole way: this green *is* reachable
        // around the block, so it routes there, finds nothing at the place a
        // stale scan still swears a green stands, orbits the phantom, and only
        // then concludes the errand is not working. Fourteen seconds to give up
        // on a lie is the price of not giving up on every green that merely
        // needs going round something.
        //
        // The bound stays loose because the exact tick is not the point. Giving
        // up at all is.
        let t = fired_at.expect("never gave up on a green it could not reach");
        assert!((200..2200).contains(&t), "gave up on the green at tick {t}");
    }

    /// A seat is furniture, and its last occupant does not come with it.
    ///
    /// Joining cleared the stat upgrades and nothing else, so a pilot handed a
    /// used seat inherited its weapon levels, add-ons, charges, earned bounty,
    /// score and position. Leaving and rejoining is the case that makes it
    /// plain: seats come back in the order they were vacated, so a player is
    /// handed their own and the zone reads as having saved their game.
    #[test]
    fn a_joining_pilot_does_not_inherit_the_seat() {
        // No spawn kit, so every number below can be asserted at zero. A zone
        // that hands one out puts real upgrades on the arriving ship, and a
        // rolled level of two is indistinguishable from an inherited one, which
        // would make this test about the kit instead of about the seat. The kit
        // has a test of its own.
        let mut def = wire_zone(1, 6, 16);
        def.zone_toml = "description = \"no kit\"\n[arena]\nspawn_prizes = 0\n".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, test_spool(),
                              HashMap::new());
        z.serve_zone(&def).expect("a room");

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join(Seat::guest("first", false), 0, 16, tx).expect("a seat");
        let ship = z.rooms[0].players[&id].ship;
        {
            let sh = &mut z.rooms[0].world.state.ships[ship as usize];
            sh.level = [2; sim::TRIG_COUNT];
            sh.mods = [0x15; sim::TRIG_COUNT];
            sh.charge = [3; sim::MAX_CHARGES];
            sh.up = [4; sim::UP_COUNT];
            sh.earned = 250;
            sh.points = 9000;
            sh.x += 400 * 256;
            sh.vx = 12345;
        }
        let flown_to = z.rooms[0].world.state.ships[ship as usize].x;
        z.rooms[0].leave(id);

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id2 = z.rooms[0].join(Seat::guest("second", false), 0, 16, tx).expect("a seat");
        let ship2 = z.rooms[0].players[&id2].ship;
        assert_eq!(ship2, ship, "the vacated seat is the one handed back");

        let sh = z.rooms[0].world.state.ships[ship2 as usize];
        assert_eq!(sh.level, [0; sim::TRIG_COUNT], "weapon levels are not inherited");
        assert_eq!(sh.mods, [0; sim::TRIG_COUNT], "nor add-ons");
        assert_eq!(sh.charge, [0; sim::MAX_CHARGES], "nor charges");
        assert_eq!(sh.up, [0; sim::UP_COUNT], "nor stat upgrades");
        assert_eq!(sh.earned, 0, "nor bounty somebody else earned");
        assert_eq!(sh.points, 0, "nor their score");
        assert_eq!(sh.vx, 0, "and it arrives at rest");
        assert_ne!(sh.x, flown_to, "at a start, not where the last one left off");
    }

    /// The other half of not inheriting a seat: what the arriving pilot gets
    /// instead.
    ///
    /// Clearing the seat was the whole of `join` for a while, which is right
    /// for a zone that starts everybody plain and wrong for one that does not.
    /// A zone handing out thirty greens gave them to its bots and to anybody
    /// who had died once, and nothing at all to somebody who had just walked
    /// in, so a fresh arrival was the poorest ship in the room.
    #[test]
    fn an_arriving_pilot_gets_the_zones_spawn_kit() {
        let mut def = wire_zone(1, 6, 16);
        def.zone_toml = "description = \"a zone with a kit\"\n\
                         [arena]\nspawn_prizes = 30\n".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, test_spool(),
                              HashMap::new());
        z.serve_zone(&def).expect("a room");

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join(Seat::guest("arrival", false), 0, 16, tx).expect("a seat");
        let ship = z.rooms[0].players[&id].ship as usize;
        let sh = z.rooms[0].world.state.ships[ship];
        // One green is one bounty, whatever it turned out to be, so thirty
        // rolls is a bounty near thirty. Near rather than exactly: rust takes
        // one back now and then, which is the zone's own setting doing its job.
        let bounty = unsafe { sim::sim_bounty(&sh) };
        assert!(bounty > 20, "an arrival carries the kit, not nothing: {bounty}");
        // And the bar is full of the energy those greens just bought, rather
        // than of the ceiling the ship had before them.
        let full = z.rooms[0].world.eff_max_energy(ship);
        assert_eq!(sh.energy, full, "the bar is filled after the kit lands");

        // A zone that hands out nothing still starts pilots plain.
        let mut bare = wire_zone(1, 6, 16);
        bare.zone_toml = "description = \"bare\"\n[arena]\nspawn_prizes = 0\n".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z2 = Zone::new(cfg, test_spool(),
                               HashMap::new());
        z2.serve_zone(&bare).expect("a room");
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z2.rooms[0].join(Seat::guest("arrival", false), 0, 16, tx).expect("a seat");
        let ship = z2.rooms[0].players[&id].ship as usize;
        assert_eq!(z2.rooms[0].world.state.ships[ship].up, [0; sim::UP_COUNT],
                   "and a zone with no kit hands out no kit");
    }

    /// A room built from a zone with named sides, for the team tests below.
    fn room_with_teams(toml: &str) -> Arena {
        let mut def = wire_zone(1, 16, 32);
        def.zone_toml = toml.into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        z.rooms.remove(0)
    }

    fn seat_human(a: &mut Arena, name: &str) -> u8 {
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        std::mem::forget(rx);
        let id = a
            .join(Seat::guest(name.to_string(), false), 0, 32, tx)
            .expect("a seat");
        a.players[&id].ship
    }

    #[test]
    fn a_zone_names_its_own_sides_and_arrivals_spread_over_them() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        assert_eq!(a.public_teams, 2);
        assert_eq!(a.teams[&0].name, "Keel");
        assert!(a.teams[&0].public, "the zone's own are public");
        let one = seat_human(&mut a, "one");
        let two = seat_human(&mut a, "two");
        assert_ne!(
            a.world.state.ships[one as usize].team,
            a.world.state.ships[two as usize].team,
            "the second arrival lands on the emptier side"
        );
    }

    #[test]
    fn a_full_side_is_the_only_thing_that_refuses_a_join() {
        // The whole team policy is three caps, so this is the whole of what a
        // player can be told no about.
        let mut a = room_with_teams(
            "teams = [\"Keel\", \"Vantage\"]\nmax_humans_per_team = 1\n",
        );
        let one = seat_human(&mut a, "one");
        let two = seat_human(&mut a, "two");
        let (first, second) = (
            a.world.state.ships[one as usize].team,
            a.world.state.ships[two as usize].team,
        );
        assert!(!a.join_team(two, first), "one a side means one a side");
        assert_eq!(a.world.state.ships[two as usize].team, second, "and no move");
        // The cap counts people, not seats: a bot on that side is not in the
        // way of a human.
        seat_bots(&mut a, 2);
        assert!(!a.join_team(two, first), "still full of its one human");
    }

    #[test]
    fn crossing_sides_drops_the_flag_and_the_bounty_it_earned() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let ship = seat_human(&mut a, "one");
        a.world.state.ships[ship as usize].earned = 30;
        assert!(a.join_team(ship, 1));
        assert_eq!(a.world.state.ships[ship as usize].team, 1);
        assert_eq!(
            a.world.state.ships[ship as usize].earned, 0,
            "what killing paid does not cross with you"
        );
        // And the gate: a hurt pilot stays where they are, so the team list is
        // not a way out of a fight.
        a.world.state.ships[ship as usize].energy /= 2;
        assert!(!a.join_team(ship, 0), "not while hurt");
        assert_eq!(a.world.state.ships[ship as usize].team, 1);
    }

    #[test]
    fn a_private_side_admits_only_who_it_invited_and_dies_when_empty() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let founder = seat_human(&mut a, "founder");
        let guest = seat_human(&mut a, "guest");
        let stranger = seat_human(&mut a, "stranger");

        assert!(a.found_and_move(founder), "anyone may found one");
        let team = a.world.state.ships[founder as usize].team;
        assert!(team >= a.public_teams, "and it is not one of the zone's");
        assert!(!a.teams[&team].public);
        assert!(!a.teams[&team].name.is_empty(), "wearing a generated name");

        assert!(!a.join_team(stranger, team), "a closed door is closed");
        assert!(a.invite(founder, guest), "any member may open it");
        assert!(a.join_team(guest, team), "and then it is open");
        assert!(!a.join_team(stranger, team), "to the invited only");

        // Everyone walks away, which is how a team sheds somebody without a
        // kick, and the side stops existing behind them.
        assert!(a.join_team(founder, 0));
        assert!(a.join_team(guest, 0));
        assert!(!a.teams.contains_key(&team), "an empty private side is gone");
    }

    #[test]
    fn founding_again_after_leaving_gives_a_different_name() {
        // A lone player founding, leaving, and founding again used to be
        // handed the word the reaper had just freed, so the second side was
        // called Anvil Watch exactly like the first and the menu looked stuck.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let ship = seat_human(&mut a, "one");

        let mut seen = Vec::new();
        for _ in 0..4 {
            assert!(a.found_and_move(ship));
            let team = a.world.state.ships[ship as usize].team;
            seen.push(a.teams[&team].name.clone());
            assert!(a.join_team(ship, 0), "back to the zone's own side");
        }
        let mut sorted = seen.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), seen.len(), "four founds, four names: {seen:?}");

        // The cursor wraps rather than climbing, so the words come back round
        // instead of turning into Anvil Watch 30 in a room that churns.
        for _ in 0..20 {
            assert!(a.found_and_move(ship));
            assert!(a.join_team(ship, 0));
        }
        assert!(a.found_and_move(ship));
        let team = a.world.state.ships[ship as usize].team;
        assert_eq!(a.teams[&team].name, seen[0], "round again, no suffix");
    }

    #[test]
    fn a_zone_can_say_there_is_no_third_side() {
        // max_teams at the count of its own is how a flag round refuses to
        // seat a side its mode cannot score.
        let mut a = room_with_teams(
            "teams = [\"Keel\", \"Vantage\"]\nmax_teams = 2\n",
        );
        let ship = seat_human(&mut a, "one");
        assert!(a.free_team_byte().is_none(), "no room for another");
        assert!(!a.found_and_move(ship), "so nobody may found one");
        assert_eq!(a.teams.len(), 2);
    }

    #[test]
    fn a_free_for_all_seats_everybody_on_a_side_of_their_own() {
        // The old shape of this was `teams = 1`, which is one side rather than
        // none: everybody on side zero, and every hostility test in the stack
        // asks whether two sides differ, so the zone ran with combat off.
        let mut a = room_with_teams("teams = []\nmax_humans_per_team = 3\n");
        assert!(a.free_for_all());
        let ships: Vec<u8> = (0..4).map(|i| seat_human(&mut a, &format!("p{i}"))).collect();
        let sides: std::collections::HashSet<u8> = ships
            .iter()
            .map(|s| a.world.state.ships[*s as usize].team)
            .collect();
        assert_eq!(sides.len(), 4, "four pilots, four sides");
        assert!(sides.iter().all(|t| *t != sim::TEAM_NONE));

        // A pact forms by invitation and stops at the cap, which is what the
        // cap is for in a room of soloists.
        let host = ships[0];
        let team = a.world.state.ships[host as usize].team;
        for guest in &ships[1..3] {
            assert!(a.invite(host, *guest));
            assert!(a.join_team(*guest, team));
        }
        assert!(a.invite(host, ships[3]));
        assert!(!a.join_team(ships[3], team), "three is the pact this zone allows");
    }

    #[test]
    fn bots_follow_the_people() {
        // Five friends take one side of a flag game. The ballast is what turns
        // that from a stomp into a raid, so it has to move after them.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        seat_bots(&mut a, 6);
        let humans: Vec<u8> = (0..4).map(|i| seat_human(&mut a, &format!("p{i}"))).collect();
        for h in &humans {
            a.join_team(*h, 0);
        }
        assert_eq!(a.team_census(0, None).0, 4, "everybody on Keel");

        let before = a.team_census(0, None);
        for _ in 0..12 {
            a.rebalance_bots();
        }
        let (k_humans, k_bots) = a.team_census(0, None);
        let (_, v_bots) = a.team_census(1, None);
        assert_eq!(k_humans, 4, "the people stay where they chose");
        assert!(k_bots < before.1, "and the bots left with the imbalance");
        assert!(v_bots > k_bots, "for the side that needed them");
        // And it settles rather than oscillating: another dozen calls change
        // nothing once the sides are within one of each other.
        let settled = (a.team_census(0, None), a.team_census(1, None));
        for _ in 0..12 {
            a.rebalance_bots();
        }
        assert_eq!((a.team_census(0, None), a.team_census(1, None)), settled,
                   "a balanced room stops moving");
    }

    #[test]
    fn a_free_for_all_list_holds_your_own_side_and_nobody_elses() {
        // Sixty-four seats is sixty-four sides here, and a menu listing
        // sixty-three strangers' private teams of one is a menu nobody can
        // use. You see the zone's own, your own, and any that invited you.
        let mut a = room_with_teams("teams = []\n");
        let me = seat_human(&mut a, "me");
        for i in 0..5 {
            seat_human(&mut a, &format!("other{i}"));
        }
        assert_eq!(a.teams.len(), 6, "six pilots, six sides");
        let m = a.teams_msg(me);
        assert_eq!(m[3], 1, "and one of them on my list");
        assert_eq!(m[1], a.world.state.ships[me as usize].team);
        assert_eq!(m[2], 0, "founding another alone would change nothing");
    }

    #[test]
    fn the_team_wire_reads_back_exactly() {
        // Same reason as the roster's: the client walks this with a cursor,
        // so a field added on one side and not the other turns every name
        // after it into gibberish.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let ship = seat_human(&mut a, "one");
        seat_bots(&mut a, 2);
        let m = a.teams_msg(ship);
        assert_eq!(m[0], S2C_TEAMS);
        assert_eq!(m[1], a.world.state.ships[ship as usize].team, "where you are");
        assert_eq!(m[2], 1, "and whether you may found one");
        let count = m[3] as usize;
        assert_eq!(count, 2);
        let mut at = 4;
        let mut read = Vec::new();
        for _ in 0..count {
            let byte = m[at];
            let public = m[at + 1];
            let may_join = m[at + 2];
            let humans = m[at + 3];
            let bots = m[at + 4];
            let len = m[at + 5] as usize;
            let name = String::from_utf8(m[at + 6..at + 6 + len].to_vec()).unwrap();
            at += 6 + len;
            read.push((byte, public, may_join, humans, bots, name));
        }
        assert_eq!(at, m.len(), "the reader lands exactly on the end");
        assert_eq!(read[0].5, "Keel");
        assert_eq!(read[1].5, "Vantage");
        assert!(read.iter().all(|r| r.1 == 1), "both are the zone's own");
        assert!(read.iter().all(|r| r.2 == 1), "and both have room");
        assert_eq!(read.iter().map(|r| r.3 as u32).sum::<u32>(), 1, "one human");
        assert_eq!(read.iter().map(|r| r.4 as u32).sum::<u32>(), 2, "two bots");
    }

    #[test]
    fn a_two_team_zone_still_has_two_teams() {
        // The other half of the same rule: a warzone must not become a
        // free-for-all with two flags in it.
        let mut def = wire_zone(1, 6, 16);
        def.mode = "warzone".into();
        def.zone_toml = "teams = [\"Keel\", \"Vantage\"]\n".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, test_spool(),
                              HashMap::new());
        z.serve_zone(&def).expect("a room");
        assert!(!z.rooms[0].free_for_all());
        seat_bots(&mut z.rooms[0], 6);
        let sides: std::collections::HashSet<u8> = z.rooms[0]
            .world
            .state
            .ships
            .iter()
            .filter(|s| s.active != 0)
            .map(|s| s.team)
            .collect();
        assert_eq!(sides.len(), 2, "two sides, whatever the roster says");
    }

    #[test]
    fn the_roster_wire_reads_back_exactly() {
        // Every name anybody sees comes from this one message, and the client
        // walks it with a cursor: a field added here and not there shifts each
        // name after it into gibberish, which a client cannot tell from a room
        // genuinely full of strangers. A reader that stopped short is what once
        // showed a live player DESTROYED forever.
        //
        // So this parses the bytes the way client/arena/net.lua does, from the
        // outside, and insists on landing exactly on the end. Same rule as
        // sim_unpack, for the same reason: stopping short is both wrong and
        // silent.
        let mut z = serving(1, 9, 16);
        seat_bots(&mut z.rooms[0], 3);
        seat(&mut z, 0, 1);
        let a = &z.rooms[0];

        let m = a.roster_msg();
        assert_eq!(m[0], S2C_ROSTER);
        let n = m[1] as usize;
        assert_eq!(n, a.names.len(), "the count has to match what follows it");
        assert!(n >= 2, "the bots and the player we seated");

        let mut o = 2;
        let mut read: HashMap<u8, (String, u8)> = HashMap::new();
        for _ in 0..n {
            assert!(o + 6 <= m.len(), "an entry header ran off the end");
            let ship = m[o];
            let label = m[o + 1];
            let _rating = i16::from_le_bytes([m[o + 2], m[o + 3]]);
            let _games = m[o + 4];
            let len = m[o + 5] as usize;
            assert!(o + 6 + len <= m.len(), "a name ran off the end");
            let name = String::from_utf8(m[o + 6..o + 6 + len].to_vec())
                .expect("names are sanitised to printable ascii before they get here");
            o += 6 + len;
            assert!(read.insert(ship, (name, label)).is_none(), "ship {ship} twice");
        }
        assert_eq!(o, m.len(), "the reader has to land on the end, not near it");
        let want: HashMap<u8, (String, u8)> = a
            .names
            .iter()
            .map(|(s, k)| (*s, (k.name.clone(), k.label)))
            .collect();
        assert_eq!(read, want, "every name, and what each seat is");
        assert!(
            read.values()
                .any(|(name, l)| name == "p0-0" && *l == token::Label::Unknown.to_byte()),
            "the human we seated is in it, and not labelled a bot"
        );
        assert!(
            read.values().any(|(_, l)| *l == token::Label::ThirdPartyBot.to_byte()),
            "a bot that declared itself without an account is somebody else's"
        );
    }

    #[test]
    fn a_ladder_zone_can_ask_for_claimed_pilots() {
        let mut z = serving_with_accounts();
        assert!(!z.wants_claimed(), "a public room admits anybody, which is the default");
        if let Some(c) = z.catalog.as_mut() {
            c.zones[0].admission = "claimed".into();
        }
        let def = z.catalog.as_ref().unwrap().zones[0].clone();
        z.serve_zone(&def).expect("a room");
        assert!(z.wants_claimed());
        // The bar is on the label, so it is on the account rather than on
        // anything the client said about itself.
        let guest = z
            .identify(&a_token(token::Kind::Human, false, "Talon 3", vec![]), "", false)
            .expect("verifies");
        assert_eq!(guest.label, token::Label::Unknown.to_byte());
        let claimed = z
            .identify(&a_token(token::Kind::Human, true, "Vesper 47", vec![]), "", false)
            .expect("verifies");
        assert_eq!(claimed.label, token::Label::Human.to_byte());
    }

    #[test]
    fn the_calibrated_ladder_seeds_an_account_and_pins_the_anchor() {
        // Where the offline tournament's work now enters the fleet. A room
        // primes by name and stopped reaching bots the moment their rating
        // moved to an account, so this is the path that has to keep working.
        assert_eq!(
            calibrated_rating(ai::ANCHOR),
            Some(ai::ANCHOR_RATING),
            "the anchor is a definition, not a measurement"
        );
        for (name, _, _) in ai::CALIBRATED {
            assert!(
                calibrated_rating(name).is_some(),
                "{name} was calibrated and has to arrive with its number"
            );
        }
        // The roster is longer than the calibrated nine, and the rest earn
        // their number in play.
        let tenth = ai::individual(9);
        assert!(calibrated_rating(&tenth.name).is_none());
    }

    #[test]
    fn a_settled_pilot_is_still_settled_in_a_fresh_process() {
        // The bug this covers outlived the file it was found in: a rating
        // restored without its game count reads as placing, and the pilot's
        // next death moves them by a newcomer's K. The record now arrives in
        // the token rather than from a file beside the process, so the same
        // property is asserted against the thing that carries it.
        let mut z = serving_with_accounts();
        let t = a_token_for(77, token::Kind::Human, true, "Veteran", vec![
            token::ClassRating { class: "arena".into(), rating: 1640.0, games: 40 },
        ]);
        let seat = z.identify(&t, "", false).expect("verifies");
        let rid = seat.rid.clone();
        assert_eq!(z.rooms[0].rating.games_of(&rid), 0, "not until they join");
        z.restore_pilot(0, &seat);
        assert_eq!(z.rooms[0].rating.rating_of(&rid), 1640.0);
        assert_eq!(z.rooms[0].rating.games_of(&rid), 40);
        assert!(z.rooms[0].rating.tier_of(&rid).is_some(),
                "a settled pilot is shown a tier, not 'placing'");
    }

    #[test]
    fn a_rated_death_between_accounts_is_handed_off() {
        let d = std::env::temp_dir().join(format!("vw-handoff-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let mut sp = spool::Spool::new(d.to_str().unwrap());
        sp.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        let sp = std::sync::Arc::new(std::sync::Mutex::new(sp));

        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = Zone::new(cfg, sp.clone(), HashMap::new());
        z.serve_zone(&wire_zone(1, 6, 16)).expect("a room");
        let a = &mut z.rooms[0];
        a.accounts.insert("a1".into(), 1);
        a.accounts.insert("a2".into(), 2);

        a.hand_off(&rating::RatedEvent {
            tick: 100,
            victim: "a2".into(),
            victim_before: 1200.0,
            victim_after: 1184.0,
            credits: vec![("a1".into(), 1.0, 1200.0, 1216.0)],
        });
        {
            let s = sp.lock().unwrap();
            assert_eq!(s.len(), 1, "both had accounts, so the event travels");
        }

        // A guest contributes nothing durable, because there is nobody to file
        // it against. The event is dropped rather than sent half-formed.
        a.hand_off(&rating::RatedEvent {
            tick: 200,
            victim: "a2".into(),
            victim_before: 1184.0,
            victim_after: 1170.0,
            credits: vec![("some guest".into(), 1.0, 1200.0, 1214.0)],
        });
        // And a guest victim is not an event at all: the negative half of the
        // exchange has nowhere to land.
        a.hand_off(&rating::RatedEvent {
            tick: 300,
            victim: "another guest".into(),
            victim_before: 1200.0,
            victim_after: 1184.0,
            credits: vec![("a1".into(), 1.0, 1200.0, 1216.0)],
        });
        assert_eq!(sp.lock().unwrap().len(), 1, "neither half-formed event travelled");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_room_fills_before_a_second_one_opens() {
        // Rung one: the fullest room below cap. A room holding four of a target
        // of six wants the next arrival, not a sibling with nobody in it.
        let mut z = serving(4, 6, 16);
        assert_eq!(z.rooms.len(), 1, "one room to start");
        for _ in 0..6 {
            let i = z.room_for_join().expect("room");
            assert_eq!(i, 0, "everything lands in the first room until it hits target");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 1, "still one room at exactly the target");

        // The seventh is the first arrival every room could refuse to concentrate.
        let i = z.room_for_join().expect("room");
        assert_eq!(i, 1, "so a second room opens for them");
        assert_eq!(z.rooms.len(), 2);
    }

    #[test]
    fn the_room_ceiling_holds_and_players_stack_past_the_target() {
        // `max_rooms` is a ceiling, not a target: once it is reached the fill
        // target stops mattering and rooms take players up to `max_players`.
        let mut z = serving(2, 2, 5);
        for _ in 0..10 {
            let Some(i) = z.room_for_join() else { break };
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 2, "never a third room");
        assert_eq!(z.total_players(), 10, "two rooms of five");
        assert!(z.status().capped, "and the instance says so");
        assert_eq!(z.room_for_join(), None, "the eleventh is sent elsewhere");
    }

    #[test]
    fn an_emptied_room_goes_back_but_never_the_first() {
        let mut z = serving(3, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 3, "a target of one grows a room per player");

        // Empty the last two. The first stays whatever happens: an instance
        // serving a zone always has a room, or it is not an instance of it.
        for r in 1..3 {
            let ids: Vec<u64> = z.rooms[r].players.keys().copied().collect();
            for id in ids {
                z.rooms[r].leave(id);
            }
        }
        z.reclaim_rooms();
        assert_eq!(z.rooms.len(), 1, "the empty ones are given back");

        let ids: Vec<u64> = z.rooms[0].players.keys().copied().collect();
        for id in ids {
            z.rooms[0].leave(id);
        }
        z.reclaim_rooms();
        assert_eq!(z.rooms.len(), 1, "and the first survives being empty");
    }

    #[test]
    fn every_room_runs_the_same_game() {
        // Rooms differing would make which room you landed in matter, which is
        // the one thing the fill ladder is allowed to decide for a player.
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let i = z.room_for_join().expect("a second room");
        assert_eq!(i, 1);
        assert_eq!(z.rooms[0].world.cfg.max_ships, z.rooms[1].world.cfg.max_ships);
        assert_eq!(z.rooms[0].public_teams, z.rooms[1].public_teams);
        assert_eq!(z.rooms[0].bot_fill, z.rooms[1].bot_fill,
                   "including how full of bots each is meant to be");
        assert_eq!(z.rooms[0].world.packed_map(), z.rooms[1].world.packed_map());
        // The same tiles, not a copy of them. A megabyte per room would make
        // `max_rooms` a memory limit rather than the blast-radius limit it is
        // meant to be, and would put the per-room figure in hosting.md out by
        // a factor of thirteen.
        assert!(
            std::sync::Arc::ptr_eq(&z.rooms[0].world.map, &z.rooms[1].world.map),
            "rooms of one zone share one map"
        );
        assert_eq!(std::sync::Arc::strong_count(&z.rooms[0].world.map), 2);
    }

    #[test]
    fn a_hundred_rooms_share_one_map() {
        // What M7.5 asks for: a small-room zone grows to its ceiling in one
        // process, and the geometry is paid for once.
        let mut z = serving(100, 1, 2);
        for _ in 0..100 {
            let Some(i) = z.room_for_join() else { break };
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 100, "the ceiling is reachable");
        assert_eq!(z.total_players(), 100);
        let map = z.rooms[0].world.map.clone();
        for (n, r) in z.rooms.iter().enumerate() {
            assert!(std::sync::Arc::ptr_eq(&map, &r.world.map), "room {n} shares it");
        }
    }

    #[test]
    fn changing_zone_replaces_every_room() {
        let mut z = serving(3, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 3);
        let other = fleet::WireZone { name: "elsewhere".into(), ..wire_zone(3, 1, 16) };
        z.serve_zone(&other).expect("it builds");
        assert_eq!(z.zone_name, "elsewhere");
        assert_eq!(z.rooms.len(), 1, "the old rooms served the old game");
        assert_eq!(z.total_players(), 0);
    }

    #[test]
    fn a_kick_reaches_a_player_in_any_room() {
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let i = z.room_for_join().expect("a second room");
        seat(&mut z, i, 1);
        // p1-0 is in room one, which the operator neither knows nor should.
        let (outcome, _why) = z.run_command(&fleet::Command {
            command_id: 1,
            verb: "kick".into(),
            args: "p1-0".into(),
            actor: "tester".into(),
        });
        assert_eq!(outcome, "done");
        assert_eq!(z.total_players(), 1);
    }

    #[test]
    fn a_client_that_stops_reading_costs_a_bounded_amount() {
        // The queue used to be unbounded, so a client that stopped reading made
        // the process allocate for as long as it stayed connected. A snapshot is
        // a whole state pack, so dropping one is correct: the next supersedes it.
        let mut z = serving(1, 2, 4);
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join(Seat::guest("stalled", false), 0, 4, tx).expect("a seat");
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..OUT_QUEUE * 10 {
            z.rooms[0].tick();
            z.rooms[0].broadcast_snapshot(&mut buf);
        }
        assert_eq!(rx.len(), OUT_QUEUE, "the queue stops at the bound");
        assert_eq!(z.status().metrics.queue_depth, OUT_QUEUE as u32,
                   "and an operator can see which connection is drowning");
        // Still in the room, still simulated: falling behind is not an eviction.
        assert!(z.rooms[0].players.contains_key(&id));
    }

    #[test]
    fn churn_does_not_grow_the_roster_or_the_ship_count() {
        // The leak this pins was found by joining and leaving a live arena for
        // two minutes: a zone configured for nine bots reached sixteen, on its
        // way to sixty-four. `leave` handed every departing player's ship to a
        // fresh bot, while `join` only took a bot when one was there to take, so
        // each player who spawned into a new slot left a bot behind them.
        //
        // Nothing reported it. Status was green, the arena was serving, and the
        // only outward sign was a browse list advertising more AI every hour and
        // a tick cost quietly climbing. The backfill went with the in-process
        // roster and cannot come back; what stays worth pinning is that seats
        // are reused, since a room growing a slot per arrival reaches
        // `max_ships` and starts refusing people who could have had the seat
        // that just went cold.
        let mut z = serving(1, 4, 32);
        let bots0 = 9;
        seat_bots(&mut z.rooms[0], bots0);
        let ships0 = z.rooms[0].world.state.ship_count;

        for _round in 0..6 {
            let mut seated = Vec::new();
            let cap = z.max_players();
            for i in 0..(bots0 + 5) {
                let (tx, _rx) = mpsc::channel(OUT_QUEUE);
                if let Some(id) = z.rooms[0].join(Seat::guest(format!("churn{i}"), false), 0, cap, tx) {
                    seated.push(id);
                }
            }
            for id in seated {
                z.rooms[0].leave(id);
            }
        }

        assert_eq!(z.rooms[0].bot_count(), bots0,
                   "the bots that were here stayed, and nobody made more");
        assert_eq!(z.rooms[0].humans(), 0);
        // The count is a high-water mark and may have risen once to hold the
        // extra concurrent players, but it must not climb every round: the core
        // hands an inactive slot to the next arrival.
        let ships1 = z.rooms[0].world.state.ship_count;
        assert!(u16::from(ships1) <= u16::from(ships0) + (bots0 + 5) as u16,
                "ship_count {ships1} grew past one peak from {ships0}");
        let active = (0..ships1 as usize)
            .filter(|&i| z.rooms[0].world.state.ships[i].active != 0)
            .count();
        assert_eq!(active, bots0, "only the bots are left flying");
    }

    #[test]
    fn a_name_is_printable_bounded_and_never_empty() {
        // The wire hands us arbitrary bytes and a name travels further than
        // anything else a client controls: rosters, logs, the ratings file,
        // an operator's kick argument.
        assert_eq!(sanitize_name("Kestrel"), "Kestrel", "a normal name is untouched");
        assert_eq!(sanitize_name("two  words"), "two words");
        assert_eq!(sanitize_name("  padded\t"), "padded");
        assert_eq!(
            sanitize_name("evil\nname"),
            "evil name",
            "a newline would forge a log line; it becomes a space"
        );
        // The ESC byte is what arms a terminal escape sequence; with it gone
        // the "[2J" left behind is inert text, which is the property that
        // matters when a name is printed into a log.
        assert_eq!(sanitize_name("a\u{1b}[2Jb\u{0}c"), "a[2Jbc");
        assert_eq!(sanitize_name("").as_str(), "pilot");
        assert_eq!(sanitize_name("\u{200b}\u{202e}").as_str(), "pilot",
                   "invisible unicode cannot be a whole name");
        let huge = "x".repeat(10_000_000);
        assert_eq!(sanitize_name(&huge).len(), 24, "10 MB of name stores 24 bytes");
        // The cap matches the roster wire format, so what is stored is what
        // every other player is shown.
        assert_eq!(sanitize_name(&huge).len(), 24usize.min(24));
    }

    #[test]
    fn a_hostile_name_lands_sanitized_in_the_room() {
        let mut z = serving(1, 4, 8);
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let cap = z.max_players();
        let id = z.rooms[0]
            .join(Seat::guest(sanitize_name("bad\r\nguy\u{7f}"), false), 0, cap, tx)
            .expect("a seat");
        assert_eq!(z.rooms[0].players[&id].name, "bad guy");
    }

    #[test]
    fn a_joining_player_is_told_the_zone_they_picked() {
        // Not the local file's name: this process is serving a catalog zone, and
        // the name in the browse list is the name they chose from.
        let z = serving(1, 6, 16);
        let msg = z.zone_msg();
        let text = String::from_utf8_lossy(&msg[1..]).to_string();
        assert!(text.starts_with("testzone\n"), "{text:?}");
        assert!(text.contains("a zone for tests"), "{text:?}");
    }

    #[test]
    fn a_named_baseline_weapon_is_tuned_in_place() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "anvil-bomb"
            on_wall = "bounce"
            bounces = 3
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let p = w.cfg.patterns[w.cfg.classes[anvil].trigger[1][0] as usize];
        let sp = w.cfg.specs[p.spec as usize];
        assert_eq!((sp.on_wall, sp.bounces), (1, 3), "the bomb bounces now");
        assert!(sp.blast > 0, "and is otherwise still the bomb");
        // Nobody else's weapon moved: each hull's rows are its own.
        let (_, apex) = gun(&w, ai::class_index("Apex").unwrap());
        assert_eq!(apex.on_wall, 0);
    }

    #[test]
    fn an_unknown_name_is_a_new_weapon_a_hull_can_carry() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "burst"
            speed = 1500
            life = 60
            damage = 40
            count = 16
            spread = 22
            energy = 300

            [[arena.ships]]
            name = "Spire"
            bomb = ["burst"]
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let spire = ai::class_index("Spire").unwrap();
        let p = w.cfg.patterns[w.cfg.classes[spire].trigger[1][0] as usize];
        let sp = w.cfg.specs[p.spec as usize];
        assert_eq!(p.count, 16);
        assert_eq!(sp.life, 60);
        assert_eq!(sp.splinter, sim::NO_PATTERN, "a new weapon splinters into nothing");
        // Degrees, because nobody thinks in sixty-five thousandths of a turn.
        assert_eq!(p.spacing, (22 * 65536 / 360) as u16);
        // Every hull carries a rack in the baseline now, the way every one
        // of the original's ships does, so what this proves is that the named
        // weapon replaced the rack rather than sat beside it.
        let fresh = sim::World::new(1);
        let base = fresh.cfg.patterns[fresh.cfg.classes[spire].trigger[1][0] as usize];
        assert_ne!(base.count, p.count, "the zone's weapon is not the baseline's");
    }

    #[test]
    fn a_weapon_can_splinter_into_one_written_after_it() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "anvil-bomb"
            splinter = "shrapnel"

            [[arena.weapons]]
            name = "shrapnel"
            speed = 1200
            life = 40
            damage = 50
            count = 8
            spread = 45
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let bomb = w.cfg.patterns[w.cfg.classes[anvil].trigger[1][0] as usize];
        let into = w.cfg.specs[bomb.spec as usize].splinter;
        assert_ne!(into, sim::NO_PATTERN, "the bomb splinters");
        assert_eq!(w.cfg.patterns[into as usize].count, 8, "into eight fragments");
    }

    #[test]
    fn an_empty_name_takes_the_rack_away() {
        let (w, warn) = tuned(r#"
            [[arena.ships]]
            name = "Anvil"
            bomb = []
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.classes[ai::class_index("Anvil").unwrap()].trigger[1][0], sim::NO_PATTERN);
    }

    #[test]
    fn what_the_file_cannot_have_is_reported_rather_than_guessed() {
        let (_, warn) = tuned(r#"
            [[arena.weapons]]
            name = "odd"
            on_wall = "sideways"
            splinter = "nothing-called-this"

            [[arena.ships]]
            name = "Trapezoid"

            [[arena.ships]]
            name = "Apex"
            gun = ["also-not-a-weapon"]
        "#);
        assert_eq!(warn.len(), 4, "{warn:?}");
        assert!(warn.iter().any(|w| w.contains("sideways")));
        assert!(warn.iter().any(|w| w.contains("nothing-called-this")));
        assert!(warn.iter().any(|w| w.contains("Trapezoid")));
        assert!(warn.iter().any(|w| w.contains("also-not-a-weapon")));
    }

    #[test]
    fn a_rung_above_the_first_is_named_for_its_level() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "anvil-bomb-3"
            blast = 96
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let rungs = w.cfg.classes[anvil].trigger[1];
        let top = w.cfg.specs[w.cfg.patterns[rungs[2] as usize].spec as usize];
        let base = w.cfg.specs[w.cfg.patterns[rungs[0] as usize].spec as usize];
        assert_eq!(top.blast, 96 * 256, "the third rung got the wider blast");
        assert_eq!(base.blast, 80 * 256, "and the first kept its own");
        // A bomb rung buys no damage. BombDamageLevel is defined "for all
        // bomb levels" and there is no upgrade beside it; what a level costs
        // is BombFireEnergyUpgrade, so that is where the ladder shows.
        assert_eq!(top.damage, base.damage, "a bomb rung is the same bomb");
        let top_p = w.cfg.patterns[rungs[2] as usize];
        let base_p = w.cfg.patterns[rungs[0] as usize];
        assert!(top_p.energy > base_p.energy, "and it costs more to let go");
    }

    #[test]
    fn a_hull_holds_the_add_ons_its_row_allows() {
        let (w, warn) = tuned(r#"
            [arena.mod_step]
            freeze = 250

            [[arena.ships]]
            name = "Spire"
            gun_mods = { freeze = 3, multi = 1 }
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.mod_step[4], 250, "a rung of freeze is two and a half seconds");
        let spire = ai::class_index("Spire").unwrap();
        let m = w.cfg.classes[spire].mod_max[0];
        assert_eq!((m >> 8) & 3, 3, "three rungs of freeze");
        assert_eq!(m & 3, 1, "and one of multifire");
        // Named add-ons are checked, not guessed at.
        let (_, warn) = tuned(r#"
            [[arena.ships]]
            name = "Spire"
            gun_mods = { sideways = 1 }
        "#);
        assert!(warn.iter().any(|w| w.contains("sideways")), "{warn:?}");
    }

    #[test]
    fn naming_one_weapon_replaces_the_whole_ladder() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "repel"
            speed = 0
            life = 1
            on_wall = "pass"
            expire_ends = true
            blast = 300
            push = 3000

            [[arena.ships]]
            name = "Anvil"
            bomb = ["repel"]
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let rungs = w.cfg.classes[anvil].trigger[1];
        assert_ne!(rungs[0], sim::NO_PATTERN, "the repel is on the trigger");
        assert_eq!(rungs[1], sim::NO_PATTERN,
                   "and there is nothing to level into");
    }

    #[test]
    fn a_zone_sets_its_room_size() {
        let mut w = sim::World::new(1);
        assert_eq!(w.cfg.max_ships, 64, "the baseline's room");
        Arena::apply_config(&mut w, &parse("[arena]\nmax_ships = 200\n"));
        assert_eq!(w.cfg.max_ships, 200, "a zone can widen it");
        // Reload builds from the baseline first, so dropping the line reverts.
        Arena::apply_config(&mut w, &parse("[arena]\n"));
        assert_eq!(w.cfg.max_ships, 64, "and removing the line puts it back");
    }

    #[test]
    fn a_zone_sets_the_odds_and_the_rust() {
        let (w, warn) = tuned(r#"
            [arena]
            rust = 250

            [arena.prize_weight]
            speed = 5
            gun-level = 400
            bomb-shrapnel = 90
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.rust_chance, 250);
        assert_eq!(w.cfg.prize_weight[2], 5, "speed is the third stat");
        assert_eq!(w.cfg.prize_weight[sim::UP_COUNT], 400, "gun level");
        let bomb_shrap = sim::UP_COUNT + sim::TRIG_COUNT + sim::MOD_COUNT + 3;
        assert_eq!(w.cfg.prize_weight[bomb_shrap], 90);
        // Everything unnamed keeps the baseline's odds.
        assert_eq!(w.cfg.prize_weight[0], 40, "energy keeps the original's odds");

        let (w, warn) = tuned(r#"
            [arena.prize_weight]
            luck = 10
        "#);
        assert!(warn.iter().any(|x| x.contains("luck")), "{warn:?}");
        assert_eq!(w.cfg.rust_chance, 10, "and rust keeps its default");
    }

    /// Every zone the shipped catalog offers, applied to a fresh room.
    ///
    /// A weapon or a hull a zone file names and the core does not is a warning
    /// on a running server and nothing else, so the zone goes live with part of
    /// its tuning silently missing. The catalog is the deployment, and these
    /// three files are the only ones anybody actually plays.
    #[test]
    fn every_shipped_zone_applies_with_nothing_left_over() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../catalog");
        let cat = catalog::load(dir).expect("the catalog we ship loads");
        assert!(cat.order.len() >= 3, "chaos, war and alpha at least");
        for name in &cat.order {
            let mut w = sim::World::new(1);
            let warn = Arena::apply_config(&mut w, &cat.zone(name).unwrap().arena);
            assert!(warn.is_empty(), "zone {name}: {warn:?}");
        }
    }

    #[test]
    fn a_zone_prices_a_kill() {
        let (w, warn) = tuned(r#"
            [arena]
            bounty_per_kill = 9
            points_per_flag = 25
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.bounty_per_kill, 9);
        assert_eq!(w.cfg.points_per_flag, 25);

        // And a file that says nothing keeps the core's own numbers, which is
        // the check that catches a mirror drifting out of step with the C
        // struct -- the reason this reads a field two along from the ones it
        // set.
        let (w, _) = tuned(r#"
            [arena]
            mode = "warzone"
        "#);
        assert_eq!(w.cfg.bounty_per_kill, 3);
        assert_eq!(w.cfg.points_per_flag, 100);
        assert_eq!(w.cfg.rust_chance, 10);
    }

    #[test]
    fn a_zone_sets_the_opening_loadout() {
        let (w, warn) = tuned(r#"
            [arena]
            spawn_prizes = 0
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.spawn_prizes, 0, "a zone can start pilots plain");

        // Untouched it is thirty. Reading the field on either side too,
        // because a u16 landing in the wrong place is how this mirror drifts.
        let (w, _) = tuned(r#"
            [arena]
            mode = "warzone"
        "#);
        assert_eq!(w.cfg.spawn_prizes, 30);
        assert_eq!(w.cfg.rust_chance, 10, "and the field before it");
        assert_eq!(w.cfg.mod_step[0], 2, "and the one after");
    }

    #[test]
    fn a_zone_prices_multifire() {
        let (w, warn) = tuned(r#"
            [arena]
            multi_energy = 200
            multi_delay = 25
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.mod_multi_energy, 200);
        assert_eq!(w.cfg.mod_multi_delay, 25);

        // Untouched, these are the original's: MultiFireEnergy 30 against
        // BulletFireEnergy 20, and MultiFireDelay 50 against BulletFireDelay
        // 25. Reading the fields on either side too, because two u16s landing
        // in the wrong place is exactly how this mirror drifts.
        let (w, _) = tuned(r#"
            [arena]
            mode = "warzone"
        "#);
        assert_eq!(w.cfg.mod_multi_energy, 50);
        assert_eq!(w.cfg.mod_multi_delay, 100);
        assert_eq!(w.cfg.mod_spread, 2730, "fifteen degrees, still");
        assert_eq!(w.cfg.bounce, 10, "and the field past the splinters");
    }

    /// `mode` and `flags` were documented keys that nobody read: the arena
    /// built a four-flag warzone whatever the file said.
    #[test]
    fn a_zone_picks_its_mode_and_how_many_flags_it_plays_for() {
        let cfg: config::ZoneConfig =
            toml::from_str("[arena]\nmode = \"arena\"\nflags = 2\n").unwrap();
        let a = Arena::new_from(&cfg);
        assert_eq!(a.mode.name(), "arena");
        assert_eq!(a.world.state.flag_count, 2);

        let cfg: config::ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        let a = Arena::new_from(&cfg);
        assert_eq!(a.mode.name(), "warzone", "and a file that says nothing is a warzone");
        assert_eq!(a.world.state.flag_count, 4);
    }

    /// The zone we ship is the documentation for this format. Parsing it is
    /// half the check; the other half is that every name in it resolves, since
    /// a weapon or an add-on the file cannot have is a warning rather than an
    /// error and would otherwise go out unnoticed.
    #[test]
    fn the_reference_zone_applies_without_a_complaint() {
        let (_, warn) = tuned(include_str!("../../zone/zone.toml"));
        assert!(warn.is_empty(), "{warn:?}");
    }

    /// The bomb rules the original spells out, as settings rather than as
    /// numbers compiled into the baseline.
    #[test]
    fn a_zone_writes_its_own_bomb_rules() {
        let (w, warn) = tuned(r#"
            [arena]
            prox_step = 32
            shrap_inactive = 100
            shrap_inactive_ticks = 5
            mod_spread = 30
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.prox_step, 32 * 256, "two tiles wider a bomb level");
        assert_eq!(w.cfg.shrap_inactive, unsafe { sim::sim_units_energy(100) });
        assert_eq!(w.cfg.shrap_inactive_ticks, 5);
        assert_eq!(w.cfg.mod_spread, (30 * 65536 / 360) as u16);

        // And untouched they are the original's: ProximityDistance gains a
        // tile a level, InactiveShrapDamage is 3 over a quarter second.
        let (w, _) = tuned("[arena]\nmode = \"warzone\"\n");
        assert_eq!(w.cfg.prox_step, 16 * 256);
        assert_eq!(w.cfg.shrap_inactive, unsafe { sim::sim_units_energy(3) });
        assert_eq!(w.cfg.shrap_inactive_ticks, 25);
    }

    /// The weapons that sit in a settings slot rather than on a hull. These
    /// were the only ones in the zone nothing could reach: the repel's radius
    /// and the fragments a bomb breaks into were ours and nobody else's.
    #[test]
    fn a_zone_tunes_the_charges_and_the_shrapnel() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "charge-1"
            blast = 200
            push = 1000

            [[arena.weapons]]
            name = "shrapnel-2"
            count = 12
            damage = 30
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let repel = w.cfg.specs[w.cfg.patterns[w.cfg.charge[0] as usize].spec as usize];
        assert_eq!(repel.blast, 200 * 256, "a shorter shove");
        assert_eq!(repel.push, unsafe { sim::sim_units_speed(1000) });
        let shell = w.cfg.patterns[w.cfg.mod_splinter[2] as usize];
        assert_eq!(shell.count, 12, "a second rung of shrapnel is twelve now");
        assert_eq!(w.cfg.patterns[w.cfg.mod_splinter[1] as usize].count, 2,
                   "and the rung below it is untouched");
    }

    /// The baseline fills two charge slots and leaves two empty. Naming an
    /// empty one makes the weapon and puts it in the slot, so adding a third
    /// charge is one block rather than a block plus a wiring line.
    #[test]
    fn naming_an_empty_charge_slot_fills_it() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "charge-3"
            speed = 0
            life = 1
            on_wall = "pass"
            expire_ends = true
            blast = 400
            damage = 900
            delay = 200

            [arena.prize_weight]
            charge-3 = 40

            [[arena.ships]]
            name = "Anvil"
            charges = [3, 3, 2]
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_ne!(w.cfg.charge[2], sim::NO_PATTERN, "the slot is filled");
        let sp = w.cfg.specs[w.cfg.patterns[w.cfg.charge[2] as usize].spec as usize];
        assert_eq!(sp.blast, 400 * 256);
        assert_eq!(w.cfg.prize_weight[sim::PRIZE_COUNT - 2], 40, "and greens can be it");
        let anvil = ai::class_index("Anvil").unwrap();
        assert_eq!(w.cfg.classes[anvil].charge_max[2], 2, "the Anvil carries two");
        assert_eq!(w.cfg.classes[ai::class_index("Apex").unwrap()].charge_max[2], 0,
                   "and nobody else carries any");
        assert_eq!(w.cfg.charge[3], sim::NO_PATTERN, "the fourth slot is still empty");
    }

    #[test]
    fn a_zone_builds_a_ladder_rather_than_a_single_weapon() {
        let (w, warn) = tuned(r#"
            [[arena.weapons]]
            name = "spike"
            damage = 300

            [[arena.ships]]
            name = "Spire"
            gun = ["spike", "apex-gun-2", "apex-gun-3"]
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let spire = ai::class_index("Spire").unwrap();
        let rungs = w.cfg.classes[spire].trigger[0];
        assert_ne!(rungs[2], sim::NO_PATTERN, "three rungs to climb");
        assert_eq!(rungs[3], sim::NO_PATTERN, "and the ladder ends there");
        let first = w.cfg.specs[w.cfg.patterns[rungs[0] as usize].spec as usize];
        assert_eq!(first.damage, unsafe { sim::sim_units_energy(300) });

        // A rung that names nothing leaves the hull alone rather than
        // half-applying: a ladder silently shortened is a hull that stops
        // levelling for a reason no log would show.
        let (w, warn) = tuned(r#"
            [[arena.ships]]
            name = "Spire"
            gun = ["apex-gun", "not-a-weapon"]
        "#);
        assert!(warn.iter().any(|x| x.contains("not-a-weapon")), "{warn:?}");
        let rungs = w.cfg.classes[spire].trigger[0];
        assert_ne!(rungs[1], sim::NO_PATTERN, "the hull kept its own ladder");
    }

    /// A stat is three numbers -- the original's InitialSpeed, UpgradeSpeed
    /// and MaximumSpeed -- and a zone can write all three.
    #[test]
    fn a_zone_sets_a_floor_and_a_step_as_well_as_a_ceiling() {
        let (w, warn) = tuned(r#"
            [[arena.ships]]
            name = "Apex"
            speed = 4000
            initial_speed = 1000
            upgrade_speed = 600
            initial_energy = 500
            upgrade_recharge = 200
            fore = 20
            aft = 12
            width = 18
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        let apex = w.cfg.classes[ai::class_index("Apex").unwrap()];
        unsafe {
            assert_eq!(apex.max_speed, sim::sim_units_speed(4000));
            assert_eq!(apex.init_speed, sim::sim_units_speed(1000), "written, not scaled");
            assert_eq!(apex.up_speed, sim::sim_units_speed(600));
            assert_eq!(apex.init_energy, sim::sim_units_energy(500));
            assert_eq!(apex.up_recharge, sim::sim_units_recharge(200));
        }
        assert_eq!(apex.fore, 20 * 256);
        assert_eq!(apex.aft, 12 * 256);
        assert_eq!(apex.halfw, 9 * 256, "width is the whole beam, halved");

        // A ceiling on its own still moves the floor and the step with it, so
        // raising a hull's top speed does not make it start slower relative to
        // where it can get.
        let (w, _) = tuned(r#"
            [[arena.ships]]
            name = "Apex"
            speed = 6500
        "#);
        let apex = w.cfg.classes[ai::class_index("Apex").unwrap()];
        let base = sim::World::new(1).cfg.classes[0];
        assert_eq!(apex.init_speed, base.init_speed * 2, "doubling the ceiling doubled it");
    }

    /// Absent and zero are different things. Every setting the core owns is
    /// absent-means-baseline, which leaves zero free to mean zero: a wall that
    /// gives nothing back, doors that never open, a room with no greens in it.
    #[test]
    fn zero_is_a_setting_rather_than_a_missing_one() {
        let (w, warn) = tuned(r#"
            [arena]
            bounce = 0
            prize_max = 0
            door_period = 0
            prize_life = 400
            prize_radius = 4
            prize_lo = 100
            prize_hi = 900
            flag_radius = 30
            flag_drop_cooldown = 50
            door_open = 100
            wormhole_pull = 40
            wormhole_range = 500
        "#);
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.bounce, 0, "a wall that eats everything that hits it");
        assert_eq!(w.cfg.prize_max, 0, "and a room with no greens in it");
        assert_eq!(w.cfg.door_period, 0);
        assert_eq!(w.cfg.prize_life, 400);
        assert_eq!(w.cfg.prize_radius, 4 * 256);
        assert_eq!((w.cfg.prize_lo, w.cfg.prize_hi), (100, 900));
        assert_eq!(w.cfg.flag_radius, 30 * 256);
        assert_eq!(w.cfg.flag_drop_cooldown, 50);
        assert_eq!(w.cfg.door_open, 100);
        assert_eq!(w.cfg.wormhole_pull, unsafe { sim::sim_units_speed(40) });
        assert_eq!(w.cfg.wormhole_range, 500 * 256);

        // Left out, each is the core's own.
        let (w, _) = tuned("[arena]\nmode = \"warzone\"\n");
        assert_eq!(w.cfg.bounce, 10);
        assert_eq!(w.cfg.prize_max, 24);
        assert_eq!(w.cfg.door_period, 600);
        assert_eq!(w.cfg.prize_life, 3000);
        assert_eq!(w.cfg.flag_radius, 18 * 256);
    }

    /// The reason apply_config rebuilds from the baseline. An operator saves
    /// the file repeatedly; the arena has to end up where the file says, not
    /// where every version of it since boot has said.
    #[test]
    fn applying_a_file_twice_is_applying_it_once() {
        let src = r#"
            [[arena.weapons]]
            name = "shrapnel"
            speed = 1200
            count = 8

            [[arena.weapons]]
            name = "anvil-bomb"
            splinter = "shrapnel"
        "#;
        let mut w = sim::World::new(1);
        Arena::apply_config(&mut w, &parse(src));
        let (specs, patterns) = (w.cfg.spec_count, w.cfg.pattern_count);
        for _ in 0..5 {
            Arena::apply_config(&mut w, &parse(src));
        }
        assert_eq!((w.cfg.spec_count, w.cfg.pattern_count), (specs, patterns),
                   "a reload does not append a row every time");
    }

    /// The zones we ship are the worked example of this format, and the half of
    /// it that goes wrong quietly is the names: a weapon no hull has, an add-on
    /// spelled wrong, a prize that is not a prize. None of those is a parse
    /// error. They are a line in a warning list nobody is reading at three in
    /// the morning, and a setting that reached the fleet and did nothing.
    #[test]
    fn every_shipped_zone_applies_without_a_warning() {
        let cat = crate::catalog::load("../catalog").expect("the shipped catalog loads");
        for name in &cat.order {
            let mut w = sim::World::new(1);
            let warn = Arena::apply_config(&mut w, &cat.zones[name].arena);
            assert!(warn.is_empty(), "zone {name:?} applies with warnings: {warn:?}");
        }
    }

    /// And a line taken out of the file comes back out of the arena.
    #[test]
    fn removing_a_line_removes_its_effect() {
        let mut w = sim::World::new(1);
        Arena::apply_config(&mut w, &parse(r#"
            [[arena.ships]]
            name = "Apex"
            speed = 6000
        "#));
        let tuned_speed = w.cfg.classes[0].max_speed;
        Arena::apply_config(&mut w, &parse("[arena]\nmode = \"warzone\""));
        assert!(w.cfg.classes[0].max_speed < tuned_speed, "back to the baseline");
    }
}

#[cfg(test)]
mod one_tick_weapons {
    use crate::sim;

    /// A repel is in the state for exactly one tick, which is why the client
    /// cannot be sent one.
    ///
    /// It is spawned in the ship phase and ends in the weapon phase of the
    /// very next step, so the only snapshot that can carry it is one packed on
    /// the tick it was fired. At `SNAPSHOT_EVERY` of 5 that is one shove in
    /// five with a picture on it, and the other four reach a watcher as ships
    /// moving for no visible reason. The client draws those from the firer's
    /// charge count instead; see `M.charges` in client/arena/world.lua.
    ///
    /// This is here to fail if that stops being true, because the day a repel
    /// lives long enough to be packed is the day the client should go back to
    /// drawing it from the weapon like everything else.
    #[test]
    fn a_repel_is_gone_before_a_snapshot_can_carry_it() {
        let mut w = sim::World::new(7);
        let a = w.spawn(0, 0, 30, 30, 0);
        assert!(a >= 0);
        w.state.ships[a as usize].charge[0] = 3;
        for _ in 0..30 {
            w.step(&[]);
        }
        let mut buf = vec![0u8; sim::PACK_MAX];
        let mut carried = Vec::new();
        for t in 0..12 {
            let buttons = if t == 0 { sim::BTN_USE } else { 0 };
            w.step(&[sim::sim_input { ship: a as u8, buttons }]);
            let n = w.pack(&mut buf);
            let mut view = sim::World::new(1);
            view.apply_snapshot(&buf[..n as usize]);
            if view.state.weapon_count > 0 {
                carried.push(t);
            }
        }
        assert_eq!(carried, vec![0],
                   "a repel should be packable on exactly the tick it is fired");
    }
}
