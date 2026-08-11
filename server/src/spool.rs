//! Durable records, on their way out of the arena.
//!
//! An arena computes rating movement because it is the only thing that saw the
//! damage, and then it has to get that movement somewhere durable without ever
//! making a tick wait on a network. So a death appends a line to a file and the
//! tick moves on; a background task drains the file into the meta-layer. What a
//! pilot did, in [`crate::pilot`], travels the same road for the same reason,
//! in its own file and to its own route.
//!
//! This replaces `persist.rs`, which wrote a rating per pilot beside the
//! process. That was correct while one instance served a zone and wrong the
//! moment two did, because two files then held two opinions and neither was the
//! answer. Nothing migrates: those records are keyed by generated guest names on
//! one box, which nobody can claim.
//!
//! The file is a buffer, not a database. An arena destroyed with a full spool
//! loses those events, which is the same bounded loss the fleet already accepts
//! for a room in progress.

use serde::de::DeserializeOwned;
use serde::Serialize;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// One rated death, as it travels. Accounts only: a pilot without one is rated
/// inside the room and forgotten when it ends, so they are dropped here rather
/// than sent as somebody the meta-layer has never heard of.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq)]
pub struct Event {
    /// Minted once, when the event is filed, and carried through every retry.
    /// Delivery is at-least-once: a batch that half-lands is posted again
    /// whole, and this is what lets the meta-layer refuse the half it kept.
    pub id: i64,
    pub tick: u32,
    pub victim: u64,
    pub victim_kind: u8,
    pub victim_before: f64,
    pub victim_after: f64,
    pub credits: Vec<Credit>,
    /// True when no human was on either side of this death. The bots fight
    /// around the clock at fill, so these are the overwhelming majority of
    /// the log and the only rows retention is willing to drop: a model
    /// migration replays human careers, and a bot re-seeds from calibration.
    /// Computed in the arena, which is the only place that knows who was a
    /// person.
    #[serde(default)]
    pub bots_only: bool,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq)]
pub struct Credit {
    pub account: u64,
    pub weight: f64,
    pub before: f64,
    pub after: f64,
}

/// How many events one post carries. A batch is one transaction per event at
/// the far end, so this is about bounding a retry rather than about throughput.
const BATCH: usize = 256;

/// How often the drain runs when there is nothing to send. A death is durable
/// within a few seconds of happening, which is far inside the window where
/// anybody would notice.
const IDLE_SECS: u64 = 5;

pub struct Spool<T> {
    path: PathBuf,
    pending: Vec<T>,
    /// The route these records are posted to. Two kinds travel this way and
    /// they land in different tables, so the kind is carried by the address
    /// rather than by a field inside the batch.
    route: &'static str,
    /// What one of these is called, for the line printed when a restart finds
    /// a debt.
    noun: &'static str,
    /// Where to post. Empty means a deployment without accounts, and then this
    /// whole module is a no-op: nothing is written and nothing is sent.
    url: String,
    token: String,
    zone: String,
    class: String,
    instance: String,
}

/// Both of an arena's spools, which are made together, aimed together and
/// handed to every room together. One struct rather than two arguments because
/// nothing in the arena ever wants one without the other, and a third kind of
/// record later should not be a third parameter on every constructor.
#[derive(Clone)]
pub struct Spools {
    pub rated: Arc<Mutex<Spool<Event>>>,
    pub pilots: Arc<Mutex<Spool<crate::pilot::Event>>>,
}

impl Spools {
    pub fn open(dir: &str) -> Spools {
        Spools {
            rated: Arc::new(Mutex::new(Spool::rated(dir))),
            pilots: Arc::new(Mutex::new(Spool::pilot(dir))),
        }
    }

    /// Aim both at the same meta-layer. They post to different routes, which
    /// each spool carries itself.
    pub fn aim(&self, url: &str, token: &str, zone: &str, class: &str, instance: &str) {
        if let Ok(mut s) = self.rated.lock() {
            s.aim(url, token, zone, class, instance);
        }
        if let Ok(mut s) = self.pilots.lock() {
            s.aim(url, token, zone, class, instance);
        }
    }
}

/// The rating half. Its file keeps the name it has always had, because an
/// arena upgraded in place still owes whatever is in it.
impl Spool<Event> {
    pub fn rated(dir: &str) -> Spool<Event> {
        Spool::open(dir, "spool.jsonl", "/v1/events", "rated event")
    }
}

/// The pilot log half.
impl Spool<crate::pilot::Event> {
    pub fn pilot(dir: &str) -> Spool<crate::pilot::Event> {
        Spool::open(dir, "pilot.jsonl", "/v1/pilot-events", "pilot event")
    }
}

impl<T: Serialize + DeserializeOwned + Clone> Spool<T> {
    fn open(dir: &str, file: &str, route: &'static str, noun: &'static str) -> Spool<T> {
        let path = PathBuf::from(format!("{dir}/{file}"));
        // Anything left from a previous process is still owed to the
        // meta-layer, so a restart picks it up rather than starting clean.
        let pending = std::fs::read_to_string(&path)
            .map(|t| {
                t.lines()
                    .filter_map(|l| serde_json::from_str::<T>(l).ok())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if !pending.is_empty() {
            println!("spool: {} {noun}s carried over from a previous run", pending.len());
        }
        Spool {
            path,
            pending,
            route,
            noun,
            url: String::new(),
            token: String::new(),
            zone: String::new(),
            class: String::new(),
            instance: String::new(),
        }
    }

    /// Told once the catalog has arrived, since that is what carries the
    /// meta-layer's address, and again whenever the instance changes zone.
    pub fn aim(&mut self, url: &str, token: &str, zone: &str, class: &str, instance: &str) {
        self.url = url.trim_end_matches('/').to_string();
        self.token = token.to_string();
        self.zone = zone.to_string();
        self.class = class.to_string();
        self.instance = instance.to_string();
    }

    pub fn armed(&self) -> bool {
        !self.url.is_empty() && !self.token.is_empty()
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// The most recent event still owed. For a caller that wants to see what
    /// it just filed rather than what the far end eventually made of it.
    pub fn last(&self) -> Option<&T> {
        self.pending.last()
    }

    /// One of the events still owed, oldest first. For reading back an order
    /// that matters: the pilot log is a sequence, and a test that could only
    /// see the last row could not tell a stay from a shuffle of one.
    pub fn nth(&self, i: usize) -> Option<&T> {
        self.pending.get(i)
    }

    /// Called from a tick. Appends and returns; it never blocks on anything
    /// slower than a buffered write to a local file, and drops the event
    /// entirely when there is nowhere for it to go.
    pub fn push(&mut self, ev: T) {
        if !self.armed() {
            return;
        }
        self.pending.push(ev.clone());
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            if let Ok(line) = serde_json::to_string(&ev) {
                let _ = writeln!(f, "{line}");
            }
        }
    }

    /// Everything currently owed, oldest first, up to one batch.
    fn batch(&self) -> Vec<T> {
        self.pending.iter().take(BATCH).cloned().collect()
    }

    /// Drop the events a post confirmed, and rewrite the file to match. The
    /// rewrite is the whole file rather than a truncation, because the events
    /// that did not fit in the batch are still owed.
    fn confirm(&mut self, n: usize) {
        self.pending.drain(..n.min(self.pending.len()));
        let body: String = self
            .pending
            .iter()
            .filter_map(|e| serde_json::to_string(e).ok())
            .map(|l| l + "\n")
            .collect();
        let _ = std::fs::write(&self.path, body);
    }
}

/// The drain. One task per spool per process, started at boot, doing nothing at
/// all until a catalog with a meta-layer in it arrives.
pub async fn drain_loop<T>(spool: Arc<Mutex<Spool<T>>>)
where
    T: Serialize + DeserializeOwned + Clone + Send + 'static,
{
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(IDLE_SECS)).await;
        // A plain mutex, locked twice around the post and never held across
        // it. The work inside is a memory copy and a file rewrite; the rooms
        // that append to this hold it for a line of JSON.
        let (url, token, zone, class, instance, route, noun, batch) = {
            let Ok(s) = spool.lock() else { return };
            if !s.armed() || s.pending.is_empty() {
                continue;
            }
            (
                s.url.clone(),
                s.token.clone(),
                s.zone.clone(),
                s.class.clone(),
                s.instance.clone(),
                s.route,
                s.noun,
                s.batch(),
            )
        };
        let n = batch.len();
        let payload = serde_json::json!({
            "pool_token": token,
            "zone": zone,
            "class": class,
            "instance": instance,
            "events": batch,
        });
        match crate::meta::call(&url, route, &payload.to_string()).await {
            Ok(_) => {
                if let Ok(mut s) = spool.lock() {
                    s.confirm(n);
                }
            }
            // Kept, and tried again on the next pass. A meta-layer that is down
            // costs persistence and nothing else, which is the property the
            // whole arrangement exists to have.
            Err(e) => println!("spool: {n} {noun}s still owed ({e})"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(tick: u32, victim: u64) -> Event {
        Event {
            id: (tick as i64) << 32 | victim as i64,
            tick,
            victim,
            victim_kind: 0,
            victim_before: 1200.0,
            victim_after: 1184.0,
            credits: vec![Credit { account: 7, weight: 1.0, before: 1200.0, after: 1216.0 }],
            bots_only: false,
        }
    }

    fn spool_in(dir: &std::path::Path) -> Spool<Event> {
        let mut s = Spool::rated(dir.to_str().unwrap());
        s.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        s
    }

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("vw-spool-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn events_survive_a_restart() {
        let d = tmp("restart");
        {
            let mut s = spool_in(&d);
            s.push(ev(10, 1));
            s.push(ev(20, 2));
            assert_eq!(s.len(), 2);
        }
        // A new process over the same directory still owes both.
        let s = Spool::rated(d.to_str().unwrap());
        assert_eq!(s.len(), 2, "a restart does not forgive a debt");
        assert_eq!(s.pending[0].tick, 10, "oldest first");
        assert_eq!(s.pending[0].id, ev(10, 1).id, "the same event, not a reminted one");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn confirming_drops_only_what_was_sent() {
        let d = tmp("confirm");
        let mut s = spool_in(&d);
        for i in 0..5 {
            s.push(ev(i, 1));
        }
        s.confirm(2);
        assert_eq!(s.len(), 3);
        // And the file agrees, so a restart here does not resend the two that
        // already landed.
        let reread = Spool::rated(d.to_str().unwrap());
        assert_eq!(reread.len(), 3);
        assert_eq!(reread.pending[0].tick, 2);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn without_a_meta_layer_nothing_is_written() {
        let d = tmp("unarmed");
        let mut s = Spool::rated(d.to_str().unwrap());
        assert!(!s.armed());
        s.push(ev(1, 1));
        assert_eq!(s.len(), 0, "a deployment without accounts writes nothing durable");
        assert!(!d.join("spool.jsonl").exists());
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The two spools are separate files and separate debts. They shared a
    /// name for one draft of this and the pilot log's lines were then handed
    /// to the rating ingest, which refused every one of them for having no
    /// victim.
    #[test]
    fn the_two_spools_do_not_share_a_file() {
        let d = tmp("two");
        let mut rated = Spool::rated(d.to_str().unwrap());
        rated.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        let mut pilots = Spool::pilot(d.to_str().unwrap());
        pilots.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        rated.push(ev(1, 1));
        pilots.push(crate::pilot::Event {
            id: 5,
            at: 1_700_000_000_000,
            session: "abc".into(),
            kind: crate::pilot::JOIN.into(),
            pilot: Some(7),
            name: "Vega 001".into(),
            bot: false,
            room: Some(2),
            tick: 99,
            detail: serde_json::json!({ "class": 3 }),
        });
        assert_eq!(rated.len(), 1);
        assert_eq!(pilots.len(), 1);
        assert_eq!(
            Spool::rated(d.to_str().unwrap()).len(),
            1,
            "the rating spool re-reads only its own file"
        );
        assert_eq!(Spool::pilot(d.to_str().unwrap()).len(), 1);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_batch_is_bounded() {
        let d = tmp("batch");
        let mut s = spool_in(&d);
        for i in 0..(BATCH as u32 + 50) {
            s.push(ev(i, 1));
        }
        assert_eq!(s.batch().len(), BATCH, "one post does not carry an unbounded backlog");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn an_event_round_trips_through_json() {
        let e = ev(42, 9);
        let text = serde_json::to_string(&e).unwrap();
        assert_eq!(serde_json::from_str::<Event>(&text).unwrap(), e);
        // The field names are the wire contract with the meta-layer's ingest,
        // so they are asserted rather than assumed.
        assert!(text.contains("\"victim\":9"));
        assert!(text.contains("\"victim_before\":1200.0"));
        assert!(text.contains("\"account\":7"));
    }
}
