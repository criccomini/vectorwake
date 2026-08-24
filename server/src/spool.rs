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
use serde::{Deserialize, Serialize};
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
    /// The account that landed the final blow. None for a combat quit or when
    /// the killer was a guest with no durable account.
    #[serde(default)]
    pub killer: Option<u64>,
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
    pending: Vec<Pending<T>>,
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

/// The destination is captured with each record. An arena can switch zones
/// while old events are still owed, and relabeling that debt with its new zone
/// would write a real fight into the wrong ladder.
#[derive(Serialize, Deserialize, Clone, Debug)]
struct Pending<T> {
    zone: String,
    class: String,
    instance: String,
    event: T,
}

/// Files written before destinations traveled with each line. The first aim
/// after an upgrade assigns them once and rewrites them in the current format.
#[derive(Deserialize)]
#[serde(untagged)]
enum OnDisk<T> {
    Current(Pending<T>),
    Legacy(T),
}

struct Batch<T> {
    zone: String,
    class: String,
    instance: String,
    events: Vec<T>,
}

#[derive(Debug, PartialEq, Eq)]
struct BatchRejection {
    index: usize,
    error: String,
}

#[derive(Serialize)]
struct DeadLetter<T> {
    error: String,
    zone: String,
    class: String,
    instance: String,
    event: T,
}

/// Both of an arena's spools, which are made together, aimed together and
/// handed to every room together. One struct rather than two arguments because
/// nothing in the arena ever wants one without the other, and a third kind of
/// record later should not be a third parameter on every constructor.
#[derive(Clone)]
pub struct Spools {
    pub rated: Arc<Mutex<Spool<Event>>>,
    pub pilots: Arc<Mutex<Spool<crate::pilot::Event>>>,
    pub matches: Arc<Mutex<Spool<crate::growth::Artifact>>>,
}

impl Spools {
    pub fn open(dir: &str) -> Spools {
        Spools {
            rated: Arc::new(Mutex::new(Spool::rated(dir))),
            pilots: Arc::new(Mutex::new(Spool::pilot(dir))),
            matches: Arc::new(Mutex::new(Spool::matches(dir))),
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
        if let Ok(mut s) = self.matches.lock() {
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

    /// Copy the debt that can change one account's standing. The copies may
    /// race the regular drain, which is safe because every event keeps the id
    /// minted when it first entered the spool.
    fn account_batches(&self, account: u64) -> Vec<Batch<Event>> {
        self.batches_matching(|event| event.involves(account))
    }
}

impl Event {
    fn involves(&self, account: u64) -> bool {
        self.victim == account
            || self.killer == Some(account)
            || self.credits.iter().any(|credit| credit.account == account)
    }
}

/// The pilot log half.
impl Spool<crate::pilot::Event> {
    pub fn pilot(dir: &str) -> Spool<crate::pilot::Event> {
        Spool::open(dir, "pilot.jsonl", "/v1/pilot-events", "pilot event")
    }

    /// Ladder progress is projected from match rows. These are the rows that
    /// must be acknowledged before the account's exclusive rated lease can be
    /// released and reclaimed with a fresh progress snapshot.
    fn ladder_batches(&self, account: u64) -> Vec<Batch<crate::pilot::Event>> {
        self.batches_matching(|event| {
            event.pilot == Some(account)
                && event.kind == crate::pilot::MATCH
                && event.detail.get("ladder").is_some()
        })
    }
}

impl Spool<crate::growth::Artifact> {
    pub fn matches(dir: &str) -> Spool<crate::growth::Artifact> {
        Spool::open(dir, "matches.jsonl", "/v1/matches", "match")
    }
}

impl<T: Serialize + DeserializeOwned + Clone> Spool<T> {
    fn open(dir: &str, file: &str, route: &'static str, noun: &'static str) -> Spool<T> {
        let path = PathBuf::from(format!("{dir}/{file}"));
        // Anything left from a previous process is still owed to the
        // meta-layer, so a restart picks it up rather than starting clean.
        let mut pending = Vec::new();
        let mut corrupt: Vec<Vec<u8>> = Vec::new();
        if let Ok(bytes) = std::fs::read(&path) {
            for (line, record) in bytes.split_inclusive(|byte| *byte == b'\n').enumerate() {
                let raw = record.strip_suffix(b"\n").unwrap_or(record);
                let raw = raw.strip_suffix(b"\r").unwrap_or(raw);
                match serde_json::from_slice::<OnDisk<T>>(raw) {
                    Ok(OnDisk::Current(record)) => pending.push(record),
                    Ok(OnDisk::Legacy(event)) => pending.push(Pending {
                        zone: String::new(),
                        class: String::new(),
                        instance: String::new(),
                        event,
                    }),
                    Err(error) => {
                        println!(
                            "spool: corrupt {noun} line {} kept aside: {error}",
                            line + 1
                        );
                        corrupt.push(raw.to_vec());
                    }
                }
            }
        }
        if !corrupt.is_empty() {
            let corrupt_path = PathBuf::from(format!("{}.corrupt", path.display()));
            let preserved = if let Ok(mut file) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&corrupt_path)
            {
                let mut result = Ok(());
                for line in &corrupt {
                    if let Err(error) = file.write_all(line).and_then(|_| file.write_all(b"\n")) {
                        result = Err(error);
                        break;
                    }
                }
                result
                    .and_then(|_| file.flush())
                    .and_then(|_| file.sync_data())
                    .is_ok()
            } else {
                println!(
                    "spool: could not preserve corrupt {noun} lines at {}",
                    corrupt_path.display()
                );
                false
            };
            if preserved {
                if let Err(error) = rewrite(&path, &pending) {
                    println!(
                        "spool: could not remove corrupt {noun} lines from {}: {error}",
                        path.display()
                    );
                }
            } else {
                println!(
                    "spool: leaving corrupt {noun} lines in {} until they can be preserved",
                    path.display()
                );
            }
        }
        if !pending.is_empty() {
            println!(
                "spool: {} {noun}s carried over from a previous run",
                pending.len()
            );
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
        if self.pending.iter().any(|record| record.zone.is_empty()) {
            let mut migrated = self.pending.clone();
            for record in &mut migrated {
                if record.zone.is_empty() {
                    record.zone = self.zone.clone();
                    record.class = self.class.clone();
                    record.instance = self.instance.clone();
                }
            }
            match rewrite(&self.path, &migrated) {
                Ok(()) => self.pending = migrated,
                Err(error) => println!("spool: could not migrate old {}s: {error}", self.noun),
            }
        }
    }

    pub fn armed(&self) -> bool {
        !self.url.is_empty() && !self.token.is_empty()
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// The most recent event still owed. For a caller that wants to see what
    /// it just filed rather than what the far end eventually made of it.
    #[cfg(test)]
    pub fn last(&self) -> Option<&T> {
        self.pending.last().map(|record| &record.event)
    }

    /// One of the events still owed, oldest first. For reading back an order
    /// that matters: the pilot log is a sequence, and a test that could only
    /// see the last row could not tell a stay from a shuffle of one.
    #[cfg(test)]
    pub fn nth(&self, i: usize) -> Option<&T> {
        self.pending.get(i).map(|record| &record.event)
    }

    fn batches_matching(&self, keep: impl Fn(&T) -> bool) -> Vec<Batch<T>> {
        let mut batches: Vec<Batch<T>> = Vec::new();
        for record in self.pending.iter().filter(|record| keep(&record.event)) {
            let append = batches.last_mut().filter(|batch| {
                batch.zone == record.zone
                    && batch.class == record.class
                    && batch.instance == record.instance
                    && batch.events.len() < BATCH
            });
            if let Some(batch) = append {
                batch.events.push(record.event.clone());
            } else {
                batches.push(Batch {
                    zone: record.zone.clone(),
                    class: record.class.clone(),
                    instance: record.instance.clone(),
                    events: vec![record.event.clone()],
                });
            }
        }
        batches
    }

    /// Called from a tick. Appends and returns; it never blocks on anything
    /// slower than a buffered write to a local file, and drops the event
    /// entirely when there is nowhere for it to go.
    pub fn push(&mut self, ev: T) {
        if !self.armed() {
            return;
        }
        let record = Pending {
            zone: self.zone.clone(),
            class: self.class.clone(),
            instance: self.instance.clone(),
            event: ev,
        };
        let result = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .and_then(|mut file| {
                let line = serde_json::to_string(&record)
                    .map_err(|error| std::io::Error::other(error.to_string()))?;
                writeln!(file, "{line}")?;
                file.flush()?;
                file.sync_data()
            });
        match result {
            Ok(()) => self.pending.push(record),
            Err(error) => {
                println!("spool: could not file {}: {error}", self.noun);
            }
        }
    }

    /// The oldest destination's debt, up to one batch. A later zone waits
    /// behind it so one post never mixes records from different ladders.
    fn batch(&self) -> Option<Batch<T>> {
        let first = self.pending.first()?;
        if first.zone.is_empty() {
            return None;
        }
        let events = self
            .pending
            .iter()
            .take(if self.route == "/v1/matches" {
                1
            } else {
                BATCH
            })
            .take_while(|record| {
                record.zone == first.zone
                    && record.class == first.class
                    && record.instance == first.instance
            })
            .map(|record| record.event.clone())
            .collect();
        Some(Batch {
            zone: first.zone.clone(),
            class: first.class.clone(),
            instance: first.instance.clone(),
            events,
        })
    }

    /// Drop the events a post confirmed, and rewrite the file to match. The
    /// rewrite is the whole file rather than a truncation, because the events
    /// that did not fit in the batch are still owed.
    fn confirm(&mut self, n: usize) -> std::io::Result<()> {
        let keep = self.pending[n.min(self.pending.len())..].to_vec();
        rewrite(&self.path, &keep)?;
        self.pending = keep;
        Ok(())
    }

    /// Finish one acknowledged batch. Refused records first go to a durable
    /// side file, then the entire batch leaves the retry queue. If either disk
    /// write fails, the live queue stays intact and the batch is tried again.
    fn settle(&mut self, n: usize, rejected: &[BatchRejection]) -> std::io::Result<()> {
        if !rejected.is_empty() {
            let path = PathBuf::from(format!("{}.rejected", self.path.display()));
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)?;
            for refusal in rejected {
                let Some(record) = self
                    .pending
                    .get(refusal.index)
                    .filter(|_| refusal.index < n)
                else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "meta rejected an event outside the posted batch",
                    ));
                };
                let dead = DeadLetter {
                    error: refusal.error.clone(),
                    zone: record.zone.clone(),
                    class: record.class.clone(),
                    instance: record.instance.clone(),
                    event: record.event.clone(),
                };
                let line = serde_json::to_string(&dead)
                    .map_err(|error| std::io::Error::other(error.to_string()))?;
                writeln!(file, "{line}")?;
            }
            file.flush()?;
            file.sync_data()?;
        }
        self.confirm(n)
    }
}

fn batch_rejections(
    reply: &serde_json::Value,
    batch_len: usize,
) -> Result<Vec<BatchRejection>, String> {
    let Some(value) = reply.get("rejected") else {
        return Ok(Vec::new());
    };
    let rows = value
        .as_array()
        .ok_or("meta returned a malformed rejection list")?;
    let mut seen = std::collections::HashSet::new();
    let mut rejected = Vec::with_capacity(rows.len());
    for row in rows {
        let index = row
            .get("index")
            .and_then(|value| value.as_u64())
            .and_then(|value| usize::try_from(value).ok())
            .filter(|index| *index < batch_len)
            .ok_or("meta rejected an event outside the posted batch")?;
        if !seen.insert(index) {
            return Err("meta rejected the same event twice".into());
        }
        let error = row
            .get("error")
            .and_then(|value| value.as_str())
            .filter(|error| !error.is_empty())
            .ok_or("meta returned a rejection without a reason")?;
        rejected.push(BatchRejection {
            index,
            error: error.to_string(),
        });
    }
    Ok(rejected)
}

/// Put every pending exchange involving this account in front of the
/// meta-layer before its exclusive lease is released. The regular drain still
/// owns queue removal; this is an acknowledgment barrier, and duplicate posts
/// are absorbed by the event id.
pub async fn settle_account(
    spool: &Arc<Mutex<Spool<Event>>>,
    base: &str,
    pool_token: &str,
    account: u64,
) -> Result<(), String> {
    let batches = spool
        .lock()
        .map_err(|_| "rated event spool lock failed".to_string())?
        .account_batches(account);
    settle_batches(batches, base, pool_token, "/v1/events", "event").await
}

/// Acknowledge every Ladder-bearing match row for this account before its
/// lease is released. The ordinary drain still removes the queue entries.
pub async fn settle_ladder_account(
    spool: &Arc<Mutex<Spool<crate::pilot::Event>>>,
    base: &str,
    pool_token: &str,
    account: u64,
) -> Result<(), String> {
    let batches = spool
        .lock()
        .map_err(|_| "pilot event spool lock failed".to_string())?
        .ladder_batches(account);
    settle_batches(
        batches,
        base,
        pool_token,
        "/v1/pilot-events",
        "Ladder event",
    )
    .await
}

async fn settle_batches<T: Serialize>(
    batches: Vec<Batch<T>>,
    base: &str,
    pool_token: &str,
    route: &str,
    noun: &str,
) -> Result<(), String> {
    for batch in batches {
        let n = batch.events.len();
        let payload = serde_json::json!({
            "pool_token": pool_token,
            "zone": batch.zone,
            "class": batch.class,
            "instance": batch.instance,
            "events": batch.events,
        });
        let reply = crate::meta::call(base, route, &payload.to_string()).await?;
        let rejected = batch_rejections(&reply, n)?;
        if let Some(refusal) = rejected.first() {
            return Err(format!(
                "meta refused pending {noun} {}: {}",
                refusal.index, refusal.error,
            ));
        }
    }
    Ok(())
}

/// Replace a spool without exposing a truncated or half-written live file.
/// The directory sync makes the rename survive the same power loss as the
/// file contents.
fn rewrite<T: Serialize>(path: &std::path::Path, records: &[Pending<T>]) -> std::io::Result<()> {
    let temp = PathBuf::from(format!("{}.tmp-{}", path.display(), std::process::id()));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temp)?;
        for record in records {
            let line = serde_json::to_string(record)
                .map_err(|error| std::io::Error::other(error.to_string()))?;
            writeln!(file, "{line}")?;
        }
        file.flush()?;
        file.sync_all()?;
        std::fs::rename(&temp, path)?;
        if let Some(parent) = path.parent() {
            std::fs::File::open(parent)?.sync_all()?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
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
        let (url, token, route, noun, batch) = {
            let Ok(s) = spool.lock() else { return };
            if !s.armed() || s.pending.is_empty() {
                continue;
            }
            let Some(batch) = s.batch() else { continue };
            (s.url.clone(), s.token.clone(), s.route, s.noun, batch)
        };
        let n = batch.events.len();
        let payload = serde_json::json!({
            "pool_token": token,
            "zone": batch.zone,
            "class": batch.class,
            "instance": batch.instance,
            "events": batch.events,
        });
        match crate::meta::call(&url, route, &payload.to_string()).await {
            Ok(reply) => {
                let rejected = match batch_rejections(&reply, n) {
                    Ok(rejected) => rejected,
                    Err(error) => {
                        println!("spool: {n} {noun}s still owed ({error})");
                        continue;
                    }
                };
                if let Ok(mut s) = spool.lock() {
                    if let Err(error) = s.settle(n, &rejected) {
                        println!("spool: {n} {noun}s landed but remain owed ({error})");
                    } else if !rejected.is_empty() {
                        println!(
                            "spool: {} of {n} {noun}s were refused and kept aside",
                            rejected.len()
                        );
                    }
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
            killer: Some(7),
            victim_kind: 0,
            victim_before: 1200.0,
            victim_after: 1184.0,
            credits: vec![Credit {
                account: 7,
                weight: 1.0,
                before: 1200.0,
                after: 1216.0,
            }],
            bots_only: false,
        }
    }

    fn ladder_event(account: u64, checkpoint: u32, best: u32) -> crate::pilot::Event {
        crate::pilot::Event {
            id: rand::random(),
            at: 1_700_000_000_000,
            session: "ladder-session".into(),
            kind: crate::pilot::MATCH.into(),
            pilot: Some(account),
            name: "Climber".into(),
            bot: false,
            room: Some(7),
            tick: 900,
            detail: serde_json::json!({
                "match": 4,
                "completed": true,
                "won": true,
                "assists": 0,
                "played_ticks": 4_000,
                "ladder": {
                    "checkpoint": checkpoint,
                    "best": best,
                    "rung": checkpoint,
                    "streak": 0,
                },
            }),
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

    fn reply_once(body: &'static str) -> (String, std::thread::JoinHandle<String>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let read = std::io::Read::read(&mut stream, &mut chunk).unwrap();
                assert!(read > 0, "client closed before finishing its request");
                request.extend_from_slice(&chunk[..read]);
                let Some(headers) = request.windows(4).position(|part| part == b"\r\n\r\n") else {
                    continue;
                };
                let head = String::from_utf8_lossy(&request[..headers]);
                let length = head
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("Content-Length: ")
                            .and_then(|value| value.parse::<usize>().ok())
                    })
                    .unwrap();
                if request.len() >= headers + 4 + length {
                    break;
                }
            }
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            std::io::Write::write_all(&mut stream, response.as_bytes()).unwrap();
            String::from_utf8(request).unwrap()
        });
        (base, task)
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
        assert_eq!(s.pending[0].event.tick, 10, "oldest first");
        assert_eq!(
            s.pending[0].event.id,
            ev(10, 1).id,
            "the same event, not a reminted one"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn confirming_drops_only_what_was_sent() {
        let d = tmp("confirm");
        let mut s = spool_in(&d);
        for i in 0..5 {
            s.push(ev(i, 1));
        }
        s.confirm(2).unwrap();
        assert_eq!(s.len(), 3);
        // And the file agrees, so a restart here does not resend the two that
        // already landed.
        let reread = Spool::rated(d.to_str().unwrap());
        assert_eq!(reread.len(), 3);
        assert_eq!(reread.pending[0].event.tick, 2);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn confirming_a_batch_keeps_an_event_appended_while_it_was_in_flight() {
        let d = tmp("confirm-race");
        let mut s = spool_in(&d);
        s.push(ev(1, 1));
        s.push(ev(2, 2));
        let sent = s.batch().unwrap().events.len();

        s.push(ev(3, 3));
        s.confirm(sent).unwrap();

        assert_eq!(s.len(), 1);
        assert_eq!(s.last().unwrap().tick, 3);
        let reread = Spool::rated(d.to_str().unwrap());
        assert_eq!(reread.len(), 1, "the appended event survives a restart");
        assert_eq!(reread.last().unwrap().tick, 3);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_refused_event_is_kept_aside_without_blocking_the_tail() {
        let d = tmp("dead-letter");
        let mut s = spool_in(&d);
        s.push(ev(1, 1));
        s.push(ev(2, 2));
        s.push(ev(3, 3));

        let rejected = batch_rejections(
            &serde_json::json!({
                "stored": 1,
                "rejected": [{ "index": 1, "error": "invalid victim" }],
            }),
            2,
        )
        .unwrap();
        s.settle(2, &rejected).unwrap();

        assert_eq!(s.len(), 1);
        assert_eq!(s.last().unwrap().tick, 3, "later debt can now drain");
        let line = std::fs::read_to_string(d.join("spool.jsonl.rejected")).unwrap();
        let dead: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(dead["error"], "invalid victim");
        assert_eq!(dead["event"]["tick"], 2);
        let reread = Spool::rated(d.to_str().unwrap());
        assert_eq!(reread.len(), 1, "the queue rewrite survives a restart");
        assert_eq!(reread.last().unwrap().tick, 3);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_malformed_batch_reply_removes_nothing() {
        assert_eq!(
            batch_rejections(
                &serde_json::json!({
                    "rejected": [{ "index": 2, "error": "outside" }],
                }),
                2,
            ),
            Err("meta rejected an event outside the posted batch".into())
        );
        assert_eq!(
            batch_rejections(
                &serde_json::json!({
                    "rejected": [
                        { "index": 0, "error": "first" },
                        { "index": 0, "error": "again" }
                    ],
                }),
                2,
            ),
            Err("meta rejected the same event twice".into())
        );
    }

    #[test]
    fn without_a_meta_layer_nothing_is_written() {
        let d = tmp("unarmed");
        let mut s = Spool::rated(d.to_str().unwrap());
        assert!(!s.armed());
        s.push(ev(1, 1));
        assert_eq!(
            s.len(),
            0,
            "a deployment without accounts writes nothing durable"
        );
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
        assert_eq!(
            s.batch().unwrap().events.len(),
            BATCH,
            "one post does not carry an unbounded backlog"
        );
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
        assert!(text.contains("\"killer\":7"));
        assert!(text.contains("\"victim_before\":1200.0"));
        assert!(text.contains("\"account\":7"));
    }

    #[test]
    fn a_zone_change_does_not_relabel_old_debt() {
        let d = tmp("zones");
        let mut s = spool_in(&d);
        s.push(ev(1, 1));
        s.aim("http://127.0.0.1:1", "tok", "war", "duel", "i1");
        s.push(ev(2, 2));

        let first = s.batch().unwrap();
        assert_eq!(first.zone, "chaos");
        assert_eq!(first.class, "arena");
        assert_eq!(first.events.len(), 1);
        s.confirm(1).unwrap();
        let second = s.batch().unwrap();
        assert_eq!(second.zone, "war");
        assert_eq!(second.class, "duel");
        assert_eq!(second.events.len(), 1);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn an_account_barrier_carries_every_role_across_destinations() {
        let d = tmp("account-barrier");
        let mut s = spool_in(&d);
        s.push(ev(1, 11));

        s.aim("http://127.0.0.1:1", "tok", "war", "duel", "i2");
        let mut killer = ev(2, 22);
        killer.killer = Some(11);
        killer.credits[0].account = 11;
        s.push(killer);
        let mut unrelated = ev(3, 33);
        unrelated.killer = Some(44);
        unrelated.credits[0].account = 44;
        s.push(unrelated);

        let batches = s.account_batches(11);
        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].zone, "chaos");
        assert_eq!(batches[0].events[0].tick, 1);
        assert_eq!(batches[1].zone, "war");
        assert_eq!(batches[1].events[0].tick, 2);
        assert_eq!(
            batches
                .iter()
                .map(|batch| batch.events.len())
                .sum::<usize>(),
            2,
            "unrelated debt is not part of this account's release barrier"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn an_account_barrier_waits_for_meta_without_owning_queue_removal() {
        let d = tmp("account-ack");
        let (base, server) = reply_once(r#"{"stored":1,"rejected":[]}"#);
        let mut s = Spool::rated(d.to_str().unwrap());
        s.aim(&base, "tok", "chaos", "arena", "i1");
        s.push(ev(7, 11));
        let spool = Arc::new(Mutex::new(s));

        settle_account(&spool, &base, "tok", 11)
            .await
            .expect("meta acknowledged the account's debt");

        let request = server.join().unwrap();
        assert!(request.starts_with("POST /v1/events HTTP/1.1"));
        assert!(request.contains("\"victim\":11"));
        assert_eq!(
            spool.lock().unwrap().len(),
            1,
            "the regular drain still owns queue removal"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn an_account_barrier_does_not_accept_a_refused_event() {
        let d = tmp("account-refused");
        let (base, server) =
            reply_once(r#"{"stored":0,"rejected":[{"index":0,"error":"invalid victim"}]}"#);
        let mut s = Spool::rated(d.to_str().unwrap());
        s.aim(&base, "tok", "chaos", "arena", "i1");
        s.push(ev(7, 11));
        let spool = Arc::new(Mutex::new(s));

        let error = settle_account(&spool, &base, "tok", 11)
            .await
            .expect_err("a refusal is not a settlement acknowledgment");

        assert!(error.contains("invalid victim"));
        assert_eq!(spool.lock().unwrap().len(), 1);
        server.join().unwrap();
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn the_release_barrier_acknowledges_ladder_progress_before_reconnect() {
        let d = tmp("ladder-account-ack");
        let (base, server) = reply_once(r#"{"stored":1,"rejected":[]}"#);
        let mut s = Spool::pilot(d.to_str().unwrap());
        s.aim(&base, "tok", "ladder", "ladder", "i1");
        let mut unrelated = ladder_event(22, 5, 7);
        unrelated.name = "Somebody else".into();
        s.push(unrelated);
        s.push(crate::pilot::Event {
            kind: crate::pilot::JOIN.into(),
            detail: serde_json::json!({ "class": 0 }),
            ..ladder_event(11, 0, 0)
        });
        s.push(ladder_event(11, 10, 13));
        let spool = Arc::new(Mutex::new(s));

        settle_ladder_account(&spool, &base, "tok", 11)
            .await
            .expect("meta acknowledged the checkpoint before lease release");

        let request = server.join().unwrap();
        assert!(request.starts_with("POST /v1/pilot-events HTTP/1.1"));
        assert!(request.contains("\"checkpoint\":10"));
        assert!(!request.contains("Somebody else"));
        assert!(!request.contains("\"kind\":\"join\""));
        assert_eq!(
            spool.lock().unwrap().len(),
            3,
            "the ordinary drain still owns queue removal"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn corrupt_lines_are_preserved_and_do_not_hide_valid_debt() {
        let d = tmp("corrupt");
        let path = d.join("spool.jsonl");
        let record = Pending {
            zone: "chaos".into(),
            class: "arena".into(),
            instance: "i1".into(),
            event: ev(3, 4),
        };
        std::fs::write(
            &path,
            format!("not json\n{}\n", serde_json::to_string(&record).unwrap()),
        )
        .unwrap();
        let s = Spool::rated(d.to_str().unwrap());
        assert_eq!(s.len(), 1);
        assert_eq!(s.last().unwrap().tick, 3);
        assert_eq!(
            std::fs::read_to_string(d.join("spool.jsonl.corrupt")).unwrap(),
            "not json\n"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn invalid_utf8_does_not_hide_valid_debt() {
        let d = tmp("invalid-utf8");
        let path = d.join("spool.jsonl");
        let record = Pending {
            zone: "chaos".into(),
            class: "arena".into(),
            instance: "i1".into(),
            event: ev(4, 5),
        };
        let mut bytes = b"\xffbroken\n".to_vec();
        bytes.extend_from_slice(serde_json::to_string(&record).unwrap().as_bytes());
        bytes.push(b'\n');
        std::fs::write(&path, bytes).unwrap();

        let s = Spool::rated(d.to_str().unwrap());
        assert_eq!(s.len(), 1, "one bad byte cannot erase later debt");
        assert_eq!(s.last().unwrap().tick, 4);
        assert_eq!(
            std::fs::read(d.join("spool.jsonl.corrupt")).unwrap(),
            b"\xffbroken\n"
        );
        let _ = std::fs::remove_dir_all(&d);
    }
}
