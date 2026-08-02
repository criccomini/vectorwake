//! Zone selection: how an arena server decides which game it serves.
//!
//! docs/architecture/zones-and-arenas.md is the argument and the algorithm. The
//! two things easiest to get wrong are both encoded here rather than left to a
//! caller:
//!
//! Unexpired intents count as live instances. That *is* the anti-herding
//! mechanism, so nine of ten instances booting together see the tenth's claim.
//!
//! And a zone is needy only when it has no live instance or every live one is
//! capped, never merely when one is below its fill target. A zone with one room
//! holding six of twenty does not want a second container of any kind; it wants
//! the next six players, which the client's own preference for the fullest room
//! delivers. Loosening this is the mistake that scatters the population the rule
//! exists to concentrate.

use crate::fleet::{self, now_ms};
use std::collections::HashMap;

/// Spread before a cold instance decides, so a deploy does not have every
/// process reading the same view at the same instant.
pub const DECIDE_JITTER_MS: u64 = 5_000;
/// Between announcing an intent and committing to it.
pub const ANNOUNCE_HOLD_MS: u64 = 3_000;
/// How long an announcement reserves a zone. Travels in the message so a crashed
/// announcer releases its claim on a timer.
pub const INTENT_TTL_MS: u64 = 15_000;
/// Minimum between two commits by one instance, so a flapping view cannot make
/// an instance thrash even when it is empty.
pub const RECHOOSE_COOLDOWN_MS: u64 = 60_000;

/// The union of what every directory reported, deduplicated by instance id with
/// the freshest observation of each kept. Directories relay only their own
/// observations, so unioning is how an arena sees more than any one of them.
#[derive(Default, Clone, Debug)]
pub struct Union {
    pub by_instance: HashMap<String, fleet::Observed>,
}

impl Union {
    /// Fold one directory's view in. `age_ms` is that directory's own measure of
    /// staleness, so the smaller age wins rather than a wall-clock comparison
    /// between two machines whose clocks need not agree.
    pub fn absorb(&mut self, view: &fleet::View) {
        for o in &view.instances {
            match self.by_instance.get(&o.instance) {
                Some(prev) if prev.age_ms <= o.age_ms => {}
                _ => {
                    self.by_instance.insert(o.instance.clone(), o.clone());
                }
            }
        }
    }

    /// Instances serving a zone, plus unexpired announcements naming it. The
    /// second half is the whole anti-herding mechanism.
    pub fn live(&self, zone: &str, me: &str) -> Vec<&fleet::Observed> {
        self.by_instance
            .values()
            .filter(|o| o.instance != me)
            .filter(|o| o.zone == zone || (o.intent == zone && o.intent_ms > 0))
            .collect()
    }
}

/// What an instance decided, and why, so a log line can say more than "chaos".
#[derive(Debug, Clone, PartialEq)]
pub enum Choice {
    /// Serve this zone.
    Take(String),
    /// Nothing is short; keep doing whatever we are doing.
    Stay(&'static str),
}

/// The zone this instance should serve, given a unioned view.
///
/// `willing` empty means every zone in the catalog, which is what a block of
/// identical containers wants. `order` is the catalog's declared order and is the
/// tie-break: two instances with identical views must reach the same answer, or
/// the announce step has no collision to detect, and "first in the file" is the
/// only total order they already agree on.
pub fn pick(
    cat: &fleet::WireCatalog,
    union: &Union,
    me: &str,
    my_region: &str,
    willing: &[String],
) -> Choice {
    let wanted: Vec<&fleet::WireZone> = cat
        .zones
        .iter()
        .filter(|z| willing.is_empty() || willing.iter().any(|w| w == &z.name))
        .collect();
    if wanted.is_empty() {
        return Choice::Stay("this instance is willing to serve no zone in the catalog");
    }

    let needy: Vec<&fleet::WireZone> = wanted
        .iter()
        .copied()
        .filter(|z| {
            let live = union.live(&z.name, me);
            // No instance at all, or none with room left. An instance that has
            // announced but not yet committed counts as live and uncapped, which
            // is what stops ten arenas taking one zone.
            live.is_empty() || live.iter().all(|o| capped(o))
        })
        .collect();
    if needy.is_empty() {
        return Choice::Stay("every zone has an instance with room");
    }

    // Region is a preference, not a constraint, and the distinction matters:
    // ranking rather than filtering is what keeps it from overriding rule 2.
    // Filtering needy zones by region cannot work at all, because a needy zone
    // is one whose every instance is capped, so "has no uncapped local
    // instance" is true of all of them by definition. Instead: among zones that
    // genuinely need capacity, prefer the one my own region serves least, and
    // break ties on catalog order so two instances with one view still agree.
    let best = needy
        .iter()
        .enumerate()
        .min_by_key(|(idx, z)| {
            let local = union
                .live(&z.name, me)
                .iter()
                .filter(|o| o.region == my_region)
                .count();
            (local, *idx)
        })
        .map(|(_, z)| z.name.clone());
    match best {
        Some(name) => Choice::Take(name),
        None => Choice::Stay("nothing to take"),
    }
}

/// Having announced `want` and waited, may we commit?
///
/// This cannot be "run `pick` again and check it still says `want`", which is the
/// obvious implementation and is a deadlock: two instances that announced the
/// same zone each see the other's intent, each concludes the zone is covered, and
/// both stand down, leaving it served by nobody until the intents lapse -- and
/// then they race again.
///
/// So the commit check is its own rule. Somebody actually *serving* the zone with
/// room to spare beats us. Otherwise, among the instances that announced it, the
/// lowest instance id wins and the rest stand down. That is deterministic, needs
/// no extra round trip, and resolves a collision inside one hold period.
pub fn may_commit(union: &Union, want: &str, me: &str) -> Result<(), String> {
    for o in union.live(want, me) {
        if o.zone == want && !capped(o) {
            return Err(format!("{} is already serving it with room", o.instance));
        }
    }
    // Contenders: other instances with an unexpired announcement for this zone.
    // Ties break on the id, which both sides can see and neither can dispute.
    let mut rival: Option<&str> = None;
    for o in union.live(want, me) {
        if o.intent == want && o.intent_ms > 0 && o.instance.as_str() < me {
            if rival.map(|r| o.instance.as_str() < r).unwrap_or(true) {
                rival = Some(&o.instance);
            }
        }
    }
    match rival {
        Some(r) => Err(format!("{r} announced it too and sorts first")),
        None => Ok(()),
    }
}

/// Out of room: every seat taken and no headroom to make another. The arena
/// itself reports `capped`, so the rule lives in one place; this adds the room
/// ceiling, which a reader can see and the arena cannot lie about usefully.
fn capped(o: &fleet::Observed) -> bool {
    o.capped && o.rooms >= o.max_rooms.max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cat(names: &[&str]) -> fleet::WireCatalog {
        fleet::WireCatalog {
            version: 1,
            zones: names
                .iter()
                .map(|n| fleet::WireZone {
                    name: (*n).into(),
                    max_players: 8,
                    fill_target: 4,
                    max_rooms: 1,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }
    }

    fn obs(inst: &str, zone: &str, players: u32, capped: bool) -> fleet::Observed {
        fleet::Observed {
            instance: inst.into(),
            zone: zone.into(),
            players,
            rooms: 1,
            max_rooms: 1,
            capped,
            verified: true,
            region: "local".into(),
            ..Default::default()
        }
    }

    fn union(list: Vec<fleet::Observed>) -> Union {
        let mut u = Union::default();
        u.absorb(&fleet::View { instances: list });
        u
    }

    #[test]
    fn an_empty_fleet_takes_the_first_zone_in_the_file() {
        let c = cat(&["chaos", "war"]);
        assert_eq!(
            pick(&c, &Union::default(), "me", "local", &[]),
            Choice::Take("chaos".into()),
            "the declared order is the tie-break, so two instances agree"
        );
    }

    #[test]
    fn a_zone_with_room_is_not_a_reason_to_add_an_instance() {
        // The mistake this guards: chaos has one instance holding 1 of 8, which
        // wants the next seven players and not a second room anywhere.
        let c = cat(&["chaos"]);
        let u = union(vec![obs("a", "chaos", 1, false)]);
        assert_eq!(
            pick(&c, &u, "me", "local", &[]),
            Choice::Stay("every zone has an instance with room")
        );
    }

    #[test]
    fn a_capped_zone_needs_another_instance() {
        let c = cat(&["chaos"]);
        let u = union(vec![obs("a", "chaos", 8, true)]);
        assert_eq!(pick(&c, &u, "me", "local", &[]), Choice::Take("chaos".into()));
    }

    #[test]
    fn room_headroom_means_not_capped_even_when_players_are() {
        // The fill ladder's second rung: that instance can grow its own room,
        // so the fleet does not need another process.
        let c = cat(&["chaos"]);
        let mut o = obs("a", "chaos", 8, true);
        o.max_rooms = 4;
        let u = union(vec![o]);
        assert_eq!(
            pick(&c, &u, "me", "local", &[]),
            Choice::Stay("every zone has an instance with room")
        );
    }

    #[test]
    fn an_unexpired_intent_reserves_a_zone() {
        // Ten instances booting together: the one that announced holds chaos, so
        // the next one looks at war instead. This is the anti-herding mechanism.
        let c = cat(&["chaos", "war"]);
        let mut o = obs("a", "", 0, false);
        o.intent = "chaos".into();
        o.intent_ms = 9_000;
        let u = union(vec![o]);
        assert_eq!(pick(&c, &u, "me", "local", &[]), Choice::Take("war".into()));
    }

    #[test]
    fn an_expired_intent_reserves_nothing() {
        let c = cat(&["chaos", "war"]);
        let mut o = obs("a", "", 0, false);
        o.intent = "chaos".into();
        o.intent_ms = 0; // lapsed
        let u = union(vec![o]);
        assert_eq!(
            pick(&c, &u, "me", "local", &[]),
            Choice::Take("chaos".into()),
            "a crashed announcer must not hold a zone empty forever"
        );
    }

    #[test]
    fn my_own_row_is_not_a_reason_to_stay_put() {
        // An instance sees itself in the view. Counting itself as covering the
        // zone would make a drained instance decline to re-take it.
        let c = cat(&["chaos"]);
        let u = union(vec![obs("me", "chaos", 1, false)]);
        assert_eq!(pick(&c, &u, "me", "local", &[]), Choice::Take("chaos".into()));
    }

    #[test]
    fn an_uncapped_zone_beats_a_region_preference() {
        // Rule 2 dominates rule 4, and it has to: preferring a local instance
        // over an uncapped remote one would put one half-empty room in every
        // region, which is exactly the scatter the concentration rule prevents.
        let c = cat(&["chaos", "war"]);
        let mut o = obs("a", "chaos", 1, false); // uncapped, far away
        o.region = "eu-west".into();
        let u = union(vec![o]);
        assert_eq!(
            pick(&c, &u, "me", "us-east", &[]),
            Choice::Take("war".into()),
            "chaos has room somewhere, so the need is war regardless of region"
        );
    }

    #[test]
    fn region_ranks_zones_that_all_need_capacity() {
        // Both are capped, so both are needy, and now region decides. chaos is
        // already served here and war is not, so the players in front of me have
        // no war at all: that is the one to take.
        let c = cat(&["chaos", "war"]);
        let mut here = obs("a", "chaos", 8, true);
        here.region = "us-east".into();
        let mut far = obs("b", "war", 8, true);
        far.region = "eu-west".into();
        let u = union(vec![here, far]);
        assert_eq!(pick(&c, &u, "me", "us-east", &[]), Choice::Take("war".into()));
        // And from the other side the answer flips, which is the whole point.
        assert_eq!(pick(&c, &u, "me", "eu-west", &[]), Choice::Take("chaos".into()));
    }

    #[test]
    fn with_no_region_signal_the_catalog_order_still_decides() {
        // Every needy zone equally unserved locally: determinism has to come
        // from the file, or the announce step has no collision to detect.
        let c = cat(&["chaos", "war"]);
        let u = Union::default();
        assert_eq!(pick(&c, &u, "me", "us-east", &[]), Choice::Take("chaos".into()));
    }

    #[test]
    fn willingness_bounds_the_choice() {
        let c = cat(&["chaos", "war"]);
        let u = Union::default();
        assert_eq!(
            pick(&c, &u, "me", "local", &["war".into()]),
            Choice::Take("war".into()),
            "an operator hosting one zone gets that zone"
        );
        assert!(matches!(
            pick(&c, &u, "me", "local", &["ball".into()]),
            Choice::Stay(_)
        ));
    }

    #[test]
    fn the_union_keeps_the_freshest_observation_of_each_instance() {
        let mut u = Union::default();
        let mut fresh = obs("a", "chaos", 5, false);
        fresh.age_ms = 100;
        let mut stale = obs("a", "war", 1, false);
        stale.age_ms = 9_000;
        u.absorb(&fleet::View { instances: vec![stale] });
        u.absorb(&fleet::View { instances: vec![fresh] });
        assert_eq!(u.by_instance["a"].zone, "chaos", "the newer report wins");
        assert_eq!(u.by_instance.len(), 1, "deduplicated by instance id");

        // And the other order gives the same answer, which is what makes the
        // union independent of the order directories answer in.
        let mut u = Union::default();
        let mut fresh = obs("a", "chaos", 5, false);
        fresh.age_ms = 100;
        let mut stale = obs("a", "war", 1, false);
        stale.age_ms = 9_000;
        u.absorb(&fleet::View { instances: vec![fresh] });
        u.absorb(&fleet::View { instances: vec![stale] });
        assert_eq!(u.by_instance["a"].zone, "chaos");
    }

    /// The herding case the roadmap asks for a harness for, in miniature: ten
    /// instances deciding in sequence against a view that carries each previous
    /// announcement, which is what the announce step buys.
    #[test]
    fn announcements_spread_ten_instances_across_four_zones() {
        let c = cat(&["a", "b", "c", "d"]);
        let mut seen: Vec<fleet::Observed> = Vec::new();
        let mut taken: Vec<String> = Vec::new();
        for i in 0..10 {
            let me = format!("i{i}");
            let u = union(seen.clone());
            let got = match pick(&c, &u, &me, "local", &[]) {
                Choice::Take(z) => z,
                Choice::Stay(_) => "none".into(),
            };
            taken.push(got.clone());
            if got != "none" {
                let mut o = obs(&me, "", 0, false);
                o.intent = got;
                o.intent_ms = INTENT_TTL_MS;
                seen.push(o);
            }
        }
        // Four zones get covered, and the remaining six decline rather than
        // piling on. Without the intent rule all ten would have taken "a".
        assert_eq!(&taken[..4], &["a", "b", "c", "d"]);
        assert!(taken[4..].iter().all(|t| t == "none"),
                "the rest should stay put, got {taken:?}");
    }
}

/// The arena side of the registration channel: one task per directory, plus the
/// decision loop that reads their union.
///
/// State the arena keeps about the fleet. Held behind the same mutex as the
/// zone, because a commit changes both.
#[derive(Default)]
pub struct Fleet {
    /// This instance's stable id, minted once and persisted.
    pub instance: String,
    pub region: String,
    /// What a client should dial to reach us.
    pub address: String,
    /// Zones we will serve. Empty means all of them.
    pub willing: Vec<String>,
    /// Per directory, the last view it pushed. Unioned on read, so a directory
    /// going quiet degrades the picture rather than corrupting it.
    pub views: HashMap<String, fleet::View>,
    /// The highest catalog version any directory offered, and where it came from,
    /// so a disagreement is a log line naming both.
    pub catalog_from: String,
    /// What we announced and until when, so we do not announce twice and so the
    /// commit step can check nothing else claimed it meanwhile.
    pub announced: Option<(String, u64)>,
    pub last_commit_ms: u64,
    /// Directories that have accepted us, for the log and the admin view.
    pub accepted_by: Vec<String>,
    /// A sender per live registration socket, so an announcement reaches every
    /// directory the instant it is made. Riding on the next status heartbeat
    /// instead would put an intent up to half a heartbeat late, which is most of
    /// the announce hold and therefore most of the protection it buys.
    pub senders: HashMap<String, tokio::sync::mpsc::UnboundedSender<Vec<u8>>>,
}

impl Fleet {
    pub fn union(&self) -> Union {
        let mut u = Union::default();
        for v in self.views.values() {
            u.absorb(v);
        }
        u
    }

    /// Load the instance id, or mint and persist one. Not derived from the token:
    /// many instances share a token and the point of the id is to tell them
    /// apart. A restart keeps its identity, so a reconnecting arena replaces its
    /// own row in a directory rather than appearing twice.
    pub fn load_instance_id(dir: &str) -> String {
        let path = std::path::Path::new(dir).join("instance-id");
        if let Ok(s) = std::fs::read_to_string(&path) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
        let mut raw = [0u8; 8];
        use std::io::Read;
        let _ = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw));
        // Mixed with the clock, so two containers starting from one image in the
        // same instant with an unreadable random source still differ.
        let mixed = u64::from_le_bytes(raw) ^ now_ms().rotate_left(17);
        let id = format!("{mixed:016x}");
        if let Err(e) = std::fs::write(&path, &id) {
            println!("could not persist instance id to {}: {e}", path.display());
            println!("  this instance will look like a new one after a restart");
        }
        id
    }
}

/// Keep one registration socket alive for the whole life of the process,
/// reconnecting with backoff. Losing every directory is not an outage for the
/// players already in a room, so this never gives up and never blocks a tick.
pub async fn register_with(
    url: String,
    token: String,
    zone: std::sync::Arc<tokio::sync::Mutex<crate::Zone>>,
) {
    let mut backoff_ms = 1_000u64;
    loop {
        match run_one(&url, &token, &zone).await {
            Ok(()) => {
                println!("directory {url}: disconnected");
                backoff_ms = 1_000;
            }
            Err(e) => println!("directory {url}: {e}"),
        }
        {
            // A directory that is gone should stop contributing to the union, or
            // an arena keeps deciding against a picture nobody is maintaining.
            let mut z = zone.lock().await;
            z.fleet.views.remove(&url);
            z.fleet.senders.remove(&url);
            z.fleet.accepted_by.retain(|u| u != &url);
        }
        tokio::time::sleep(std::time::Duration::from_millis(backoff_ms)).await;
        backoff_ms = (backoff_ms * 2).min(60_000);
    }
}

async fn run_one(
    url: &str,
    token: &str,
    zone: &std::sync::Arc<tokio::sync::Mutex<crate::Zone>>,
) -> Result<(), String> {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;

    let (ws, _) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    let (mut sink, mut source) = ws.split();

    let reg = {
        let z = zone.lock().await;
        fleet::Register {
            token: token.to_string(),
            instance: z.fleet.instance.clone(),
            address: z.fleet.address.clone(),
            region: z.fleet.region.clone(),
            pool_hint: String::new(),
            willing: z.fleet.willing.clone(),
            version: fleet::PROTOCOL,
        }
    };
    sink.send(Message::Binary(fleet::frame(fleet::A2D_REGISTER, &reg)))
        .await
        .map_err(|e| format!("register: {e}"))?;

    // Status on a heartbeat, so a directory can tell a quiet room from a wedged
    // process, and immediately when the count changes.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let pump = {
        let zone = zone.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let mut last = String::new();
            loop {
                let (msg, key) = {
                    let z = zone.lock().await;
                    let s = z.status();
                    (
                        fleet::frame(fleet::A2D_STATUS, &s),
                        format!("{}|{}|{}|{}", s.zone, s.players, s.rooms, s.capped),
                    )
                };
                if key != last {
                    last = key;
                }
                if tx.send(msg).is_err() {
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_millis(fleet::HEARTBEAT_MS / 2))
                    .await;
            }
        })
    };

    {
        // Announcements go out through here too, so an intent is immediate.
        let mut z = zone.lock().await;
        z.fleet.senders.insert(url.to_string(), tx.clone());
    }

    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(Message::Binary(m)).await.is_err() {
                return;
            }
        }
    });

    while let Some(Ok(msg)) = source.next().await {
        let Message::Binary(data) = msg else { continue };
        match fleet::tag_of(&data) {
            Some(fleet::D2A_ACCEPTED) => {
                let Some(a) = fleet::parse::<fleet::Accepted>(&data, fleet::D2A_ACCEPTED) else {
                    continue;
                };
                let mut z = zone.lock().await;
                if !z.fleet.accepted_by.iter().any(|u| u == url) {
                    z.fleet.accepted_by.push(url.to_string());
                }
                println!(
                    "directory {url}: accepted into pool {:?}, catalog v{}",
                    a.pool, a.catalog_version
                );
                z.take_catalog(a.catalog, url);
            }
            Some(fleet::D2A_REJECTED) => {
                let r = fleet::parse::<fleet::Rejected>(&data, fleet::D2A_REJECTED)
                    .unwrap_or_default();
                // A rejection is terminal for this attempt and never for the
                // process: an arena keeps serving whoever already reached it.
                return Err(format!("rejected: {} {}", r.reason, r.detail));
            }
            Some(fleet::D2A_VIEW) => {
                let Some(v) = fleet::parse::<fleet::View>(&data, fleet::D2A_VIEW) else {
                    continue;
                };
                let mut z = zone.lock().await;
                z.fleet.views.insert(url.to_string(), v);
            }
            Some(fleet::D2A_CATALOG) => {
                let Some(c) = fleet::parse::<fleet::WireCatalog>(&data, fleet::D2A_CATALOG)
                else {
                    continue;
                };
                let mut z = zone.lock().await;
                z.take_catalog(c, url);
            }
            Some(fleet::D2A_COMMAND) => {
                let Some(c) = fleet::parse::<fleet::Command>(&data, fleet::D2A_COMMAND) else {
                    continue;
                };
                let (outcome, detail) = {
                    let mut z = zone.lock().await;
                    z.run_command(&c)
                };
                println!(
                    "directory {url}: command {} {:?} by {:?} -> {outcome} {detail}",
                    c.command_id, c.verb, c.actor
                );
                let _ = tx.send(fleet::frame(
                    fleet::A2D_ACK,
                    &fleet::Ack {
                        command_id: c.command_id,
                        outcome: outcome.into(),
                        detail,
                    },
                ));
            }
            _ => {}
        }
    }
    pump.abort();
    writer.abort();
    Ok(())
}

/// The decision loop. Runs forever alongside the tick, never inside it.
///
/// Only an empty room chooses, which is the rule that makes the rest safe: an
/// instance may flap all it likes while nobody is affected, and drain time
/// rate-limits decisions for free.
pub async fn decide_loop(zone: std::sync::Arc<tokio::sync::Mutex<crate::Zone>>) {
    // Jitter once at the start too, so a deploy does not have every process
    // reach its first decision in the same instant.
    let spread = (now_ms() % DECIDE_JITTER_MS.max(1)) as u64;
    tokio::time::sleep(std::time::Duration::from_millis(spread)).await;

    loop {
        tokio::time::sleep(std::time::Duration::from_millis(2_000)).await;

        // Phase one: is there anything to do, and may we do it?
        let want = {
            let z = zone.lock().await;
            if z.catalog.is_none() || z.pinned.is_some() {
                continue;
            }
            if !z.arena.players.is_empty() {
                continue; // rule 1, and it is absolute
            }
            if now_ms().saturating_sub(z.fleet.last_commit_ms) < RECHOOSE_COOLDOWN_MS
                && !z.zone_name.is_empty()
            {
                continue;
            }
            let cat = z.catalog.clone().unwrap();
            let u = z.fleet.union();
            match pick(&cat, &u, &z.fleet.instance, &z.fleet.region, &z.fleet.willing) {
                Choice::Take(n) if n == z.zone_name => continue, // already right
                Choice::Take(n) => n,
                Choice::Stay(_) => continue,
            }
        };

        // Phase two: announce, wait, re-read. Carrier sense with backoff.
        {
            let mut z = zone.lock().await;
            z.fleet.announced = Some((want.clone(), now_ms() + INTENT_TTL_MS));
            z.announce(&want);
        }
        tokio::time::sleep(std::time::Duration::from_millis(ANNOUNCE_HOLD_MS)).await;

        // Phase three: commit only if the announcements we can now see still
        // leave room for us.
        let mut z = zone.lock().await;
        if !z.arena.players.is_empty() || z.pinned.is_some() {
            continue; // somebody arrived while we waited; they win
        }
        let cat = match z.catalog.clone() {
            Some(c) => c,
            None => continue,
        };
        let u = z.fleet.union();
        if let Err(why) = may_commit(&u, &want, &z.fleet.instance) {
            println!("selection: standing down from {want:?}: {why}");
            z.fleet.announced = None;
            continue;
        }
        let Some(def) = cat.zone(&want).cloned() else { continue };
        match z.serve_zone(&def) {
            Ok(()) => {
                z.fleet.last_commit_ms = now_ms();
                z.fleet.announced = None;
            }
            Err(e) => println!("selection: cannot serve {want:?}: {e}"),
        }
    }
}

#[cfg(test)]
mod commit_tests {
    use super::*;

    fn obs(inst: &str, zone: &str, intent: &str, capped: bool) -> fleet::Observed {
        fleet::Observed {
            instance: inst.into(),
            zone: zone.into(),
            intent: intent.into(),
            intent_ms: if intent.is_empty() { 0 } else { INTENT_TTL_MS },
            players: if capped { 8 } else { 1 },
            rooms: 1,
            max_rooms: 1,
            capped,
            verified: true,
            ..Default::default()
        }
    }
    fn union(list: Vec<fleet::Observed>) -> Union {
        let mut u = Union::default();
        u.absorb(&fleet::View { instances: list });
        u
    }

    #[test]
    fn an_uncontested_announcement_commits() {
        assert!(may_commit(&Union::default(), "war", "b").is_ok());
    }

    #[test]
    fn somebody_already_serving_it_with_room_wins() {
        let u = union(vec![obs("a", "war", "", false)]);
        assert!(may_commit(&u, "war", "b").is_err(), "no second instance needed");
    }

    #[test]
    fn somebody_serving_it_full_does_not_block_us() {
        let u = union(vec![obs("a", "war", "", true)]);
        assert!(may_commit(&u, "war", "b").is_ok(), "a capped zone wants capacity");
    }

    /// The deadlock this rule exists to break: two instances announce the same
    /// zone, and exactly one of them must proceed.
    #[test]
    fn a_collision_resolves_to_exactly_one_winner() {
        let a = obs("aaa", "", "war", false);
        let b = obs("bbb", "", "war", false);
        let u = union(vec![a.clone(), b.clone()]);
        assert!(may_commit(&u, "war", "aaa").is_ok(), "the lower id proceeds");
        assert!(may_commit(&u, "war", "bbb").is_err(), "the higher id stands down");
    }

    #[test]
    fn a_three_way_collision_still_has_one_winner() {
        let all = vec![
            obs("i1", "", "war", false),
            obs("i2", "", "war", false),
            obs("i3", "", "war", false),
        ];
        let u = union(all);
        let winners: Vec<&str> = ["i1", "i2", "i3"]
            .into_iter()
            .filter(|me| may_commit(&u, "war", me).is_ok())
            .collect();
        assert_eq!(winners, vec!["i1"], "exactly one, and deterministically");
    }

    #[test]
    fn an_expired_rival_announcement_does_not_block() {
        let mut rival = obs("aaa", "", "war", false);
        rival.intent_ms = 0;
        let u = union(vec![rival]);
        assert!(may_commit(&u, "war", "bbb").is_ok(),
                "a crashed announcer must not hold a zone forever");
    }

    #[test]
    fn an_announcement_for_another_zone_is_irrelevant() {
        let u = union(vec![obs("aaa", "", "chaos", false)]);
        assert!(may_commit(&u, "war", "bbb").is_ok());
    }
}
