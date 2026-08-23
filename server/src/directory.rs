//! The directory: a deployment's front door.
//!
//! It holds the catalog and the token table, accepts arena-server registrations,
//! verifies the addresses they claim, relays what it has observed itself, and
//! answers browse requests. It assigns nothing. docs/architecture/discovery.md
//! is the protocol and the argument.
//!
//! Registration state is a held socket and a local file, never a database, which
//! is what lets a deployment run several directories with no shared storage and
//! no agreement between them.

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

use crate::catalog::Catalog;
use crate::fleet::{self, now_ms};

/// The byte a client asks with and the byte it gets back, unchanged from when a
/// directory only served a list of addresses. A client that could browse before
/// can still browse.
pub const STATUS_REQUEST: u8 = 4;
pub const STATUS_REPLY: u8 = 8;

/// How often to re-verify a registered address. Push says an arena is alive;
/// only a callback says the address it claimed works.
const VERIFY_EVERY_MS: u64 = 30_000;

/// Frames waiting for one registration socket. Status and view messages are
/// replaceable, so a peer that cannot drain this many has no reason to make the
/// directory retain an unlimited history for it.
const OUT_QUEUE: usize = 16;

/// One registration this directory holds. Everything here is its own
/// observation, which is the rule that bounds a lying arena to lying about
/// itself.
struct Reg {
    pool: String,
    build: String,
    host_id: String,
    instance: String,
    address: String,
    wt: String,
    region: String,
    /// Which zones this arena said it would serve. Kept because a
    /// registration is a record of what an arena claimed, and selection reads
    /// what it is actually running instead.
    #[allow(dead_code)]
    willing: Vec<String>,
    status: fleet::Status,
    verified: bool,
    seen_ms: u64,
    intent: String,
    intent_until_ms: u64,
    tx: mpsc::Sender<Message>,
}

pub struct Directory {
    pub catalog: Catalog,
    /// Keyed by instance id. A restart reuses its id, so a reconnecting arena
    /// replaces its own row rather than appearing twice.
    regs: HashMap<String, Reg>,
    /// Rising, so an `Ack` can name the command it answers.
    next_command: u64,
    /// Commands and their outcomes, newest last, for the admin surface. Bounded,
    /// because an audit log that grows without limit is an outage waiting.
    pub audit: Vec<AuditRow>,
    /// What an operator has published from the panel: maps they drew, and the
    /// zone rotations naming them. Laid over the catalog on disk rather than
    /// replacing it, so a zone nobody has published keeps the file's maps and
    /// the file stays the thing a fresh deployment boots with.
    ///
    /// Held in memory only. The meta-layer's table is where a publication
    /// lives; this is a copy that arrives by push and is asked for again at
    /// startup, so a directory that restarts is briefly behind rather than
    /// permanently wrong.
    pub published: fleet::Published,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuditRow {
    pub at_ms: u64,
    pub actor: String,
    pub verb: String,
    pub target: String,
    pub args: String,
    pub outcome: String,
}

const AUDIT_MAX: usize = 500;

/// What a browse request gets: the games on offer, with the instances serving
/// each underneath. Per-zone totals so a list can be drawn without arithmetic.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Browse {
    pub name: String,
    pub description: String,
    pub catalog_version: u32,
    /// Where a client logs in, empty on a deployment without accounts. It
    /// travels with the games list because that is the one thing a client asks
    /// for before it needs an identity, which saves it a second address to be
    /// configured with and keeps the account system a property of the
    /// deployment rather than of the build.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub meta: String,
    pub zones: Vec<BrowseZone>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct BrowseZone {
    pub name: String,
    pub description: String,
    pub players: u32,
    pub bots: u32,
    pub instances: Vec<BrowseInstance>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct BrowseInstance {
    /// Which instance this is. Published so a client holding a friend's
    /// whereabouts can turn it into an address: the meta-layer knows an
    /// account is in instance `abc`, and this list is the only thing that
    /// knows where `abc` answers. See docs/design/friends.md.
    ///
    /// Not a secret and not the address: an id names a process, and knowing
    /// one buys nothing the games list does not already hand out.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub id: String,
    pub address: String,
    /// The WebTransport address, when the instance serves one. A client that
    /// can speak it dials this first and keeps `address` as the fallback; one
    /// that cannot ignores it, which is why it is a second field rather than a
    /// replacement.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub wt: String,
    pub region: String,
    pub players: u32,
    pub bots: u32,
    /// What the instance says it wants across all its rooms. This is what the
    /// bot server acts on, and it is the instance's own number rather than
    /// anything the directory computes: a zone's `bot_fill` is a share of a room
    /// size the directory would otherwise have to look up per instance.
    #[serde(default)]
    pub bots_wanted: u32,
    /// The directory's summary of whether a join would be refused, which saves a
    /// client the round trip it would otherwise spend learning the same thing.
    /// Counts humans, so a room holding bots a human would displace is not full.
    pub full: bool,
    /// The rooms this instance is holding, when it holds more than one.
    ///
    /// Relayed rather than summarised. A client listing the rooms of a zone
    /// flattens these across every instance of it, so what travels has to be
    /// each room's own number and population, and the directory has no more to
    /// add: it did not choose the numbers and it does not police them.
    ///
    /// Absent for the ordinary zone, which holds one room per process. A list
    /// of one room is a list of the thing the player is already in.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rooms: Vec<fleet::RoomView>,
}

impl Directory {
    pub fn new(catalog: Catalog) -> Self {
        Directory {
            catalog,
            regs: HashMap::new(),
            next_command: 1,
            audit: Vec::new(),
            published: fleet::Published::default(),
        }
    }

    /// The catalog as it travels: zone definitions, bans and staff, and none of
    /// the pool tokens.
    pub fn wire_catalog(&self) -> fleet::WireCatalog {
        let c = &self.catalog;
        fleet::WireCatalog {
            version: self.version(),
            name: c.name.clone(),
            default_zone: c.default_zone.clone(),
            bans: c.bans.clone(),
            staff: c
                .staff
                .iter()
                .map(|s| fleet::WireStaff {
                    name: s.name.clone(),
                    capabilities: s.capabilities.clone(),
                })
                .collect(),
            meta_key: c.meta.key.clone(),
            meta_url: c.meta.url.clone(),
            zones: c
                .order
                .iter()
                .filter_map(|n| {
                    let z = c.zones.get(n)?;
                    Some(fleet::WireZone {
                        name: n.clone(),
                        description: z.description.clone(),
                        mode: z.mode.clone(),
                        max_ships: z.max_ships.unwrap_or(64),
                        max_players: z.max_players() as u32,
                        fill_target: z.fill_target() as u32,
                        bot_fill: z.bot_fill(),
                        max_rooms: z.max_rooms() as u32,
                        admission: z.admission.clone(),
                        // A published rotation wins over the file, and a zone
                        // without one keeps the file. That is the whole of the
                        // override: everything else in the stanza is still the
                        // reviewed text on disk.
                        maps_b64: self
                            .published
                            .zone(n)
                            .unwrap_or_else(|| c.map_bytes(n))
                            .iter()
                            .map(|b| fleet::b64(b))
                            .collect(),
                        zone_toml: z.raw.clone(),
                    })
                })
                .collect(),
        }
    }

    /// The version this directory serves: the catalog's own, plus how many
    /// times anything has been published.
    ///
    /// Added rather than replaced, so both sources of change still count up
    /// and an arena's "highest version wins" holds across both. Bumping the
    /// file while publications exist stays a bigger number, and rolling a
    /// publication back is another publication rather than a smaller serial.
    pub fn version(&self) -> u32 {
        self.catalog.version.saturating_add(self.published.serial)
    }

    /// Take a publication from the operator. Returns what version the fleet
    /// will now be offered, or nothing when this is one it already holds.
    ///
    /// Refused when it is not newer, for the reason an arena refuses an older
    /// catalog: two pushes can cross, and the loser must not undo the winner.
    pub fn publish(&mut self, p: fleet::Published) -> Option<u32> {
        if p.serial < self.published.serial {
            return None;
        }
        self.published = p;
        Some(self.version())
    }

    /// Drop registrations whose socket has gone quiet. A delisting has to be
    /// prompt or a player is offered a room that is not there.
    fn reap(&mut self) {
        let now = now_ms();
        self.regs
            .retain(|_, r| now.saturating_sub(r.seen_ms) < fleet::DEAD_AFTER_MS);
    }

    /// Everything this directory has observed, for the arena servers and for the
    /// admin surface. Unverified rows are included here and excluded from browse:
    /// an operator wants to see a misconfigured instance, a player does not.
    pub fn view(&self) -> fleet::View {
        let now = now_ms();
        fleet::View {
            catalog_version: self.version(),
            meta_key: self.catalog.meta.key.clone(),
            build: crate::metrics::commit().to_string(),
            instances: self
                .regs
                .values()
                .map(|r| fleet::Observed {
                    instance: r.instance.clone(),
                    zone: r.status.zone.clone(),
                    address: r.address.clone(),
                    region: r.region.clone(),
                    players: r.status.players,
                    bots: r.status.bots,
                    bots_wanted: r.status.bots_wanted,
                    rooms: r.status.rooms.clone(),
                    max_rooms: r.status.max_rooms,
                    capped: r.status.capped,
                    verified: r.verified,
                    age_ms: now.saturating_sub(r.seen_ms),
                    intent: if r.intent_until_ms > now {
                        r.intent.clone()
                    } else {
                        String::new()
                    },
                    intent_ms: r.intent_until_ms.saturating_sub(now),
                    pool: r.pool.clone(),
                    metrics: r.status.metrics.clone(),
                    build: r.build.clone(),
                    host_id: r.host_id.clone(),
                    pinned: r.status.pinned.clone(),
                    pinned_by: r.status.pinned_by.clone(),
                    pinned_at_ms: r.status.pinned_at_ms,
                })
                .collect(),
        }
    }

    pub fn browse(&self) -> Browse {
        let meta = self.catalog.meta.url.clone();
        let mut zones: Vec<BrowseZone> = self
            .catalog
            .order
            .iter()
            .map(|n| BrowseZone {
                name: n.clone(),
                description: self
                    .catalog
                    .zones
                    .get(n)
                    .map(|z| z.description.clone())
                    .unwrap_or_default(),
                ..Default::default()
            })
            .collect();

        for r in self.regs.values() {
            // Unverified instances are not offered: the address is unproven and
            // a player sent there learns that the hard way.
            if !r.verified || r.status.zone.is_empty() {
                continue;
            }
            let cap = self
                .catalog
                .zones
                .get(&r.status.zone)
                .map(|z| z.max_players() as u32)
                .unwrap_or(u32::MAX);
            if let Some(z) = zones.iter_mut().find(|z| z.name == r.status.zone) {
                let people = r.status.players.saturating_add(r.status.spectators);
                z.players += people;
                z.bots += r.status.bots;
                z.instances.push(BrowseInstance {
                    id: r.instance.clone(),
                    address: r.address.clone(),
                    wt: r.wt.clone(),
                    region: r.region.clone(),
                    players: people,
                    bots: r.status.bots,
                    bots_wanted: r.status.bots_wanted,
                    // Full means no seat and no headroom to make one.
                    full: r.status.players >= cap
                        && r.status.rooms.len() as u32 >= r.status.max_rooms.max(1),
                    rooms: if r.status.max_rooms > 1 {
                        r.status.rooms.clone()
                    } else {
                        Vec::new()
                    },
                });
            }
        }
        // Fullest first, so a client taking the head of the list concentrates a
        // population by default rather than scattering it. Full instances go
        // last regardless: they are still listed, because a spectator or an
        // operator wants to see them, but the head of the list has to be an
        // address that will actually take the player who clicked it.
        for z in zones.iter_mut() {
            z.instances
                .sort_by(|a, b| a.full.cmp(&b.full).then(b.players.cmp(&a.players)));
        }
        Browse {
            name: self.catalog.name.clone(),
            description: self.catalog.description.clone(),
            catalog_version: self.version(),
            meta,
            zones,
        }
    }

    fn note(&mut self, row: AuditRow) {
        self.audit.push(row);
        if self.audit.len() > AUDIT_MAX {
            let drop = self.audit.len() - AUDIT_MAX;
            self.audit.drain(..drop);
        }
    }

    /// Send a verb to one instance. Scoped by construction: a directory can only
    /// reach arenas registered with it, because the socket is the only path.
    pub fn command(&mut self, instance: &str, verb: &str, args: &str, actor: &str) -> bool {
        let id = self.next_command;
        self.next_command += 1;
        let msg = fleet::frame(
            fleet::D2A_COMMAND,
            &fleet::Command {
                command_id: id,
                verb: verb.to_string(),
                args: args.to_string(),
                actor: actor.to_string(),
            },
        );
        let sent = match self.regs.get(instance) {
            Some(r) => r.tx.try_send(Message::Binary(msg)).is_ok(),
            None => false,
        };
        self.note(AuditRow {
            at_ms: now_ms(),
            actor: actor.to_string(),
            verb: verb.to_string(),
            target: instance.to_string(),
            args: args.to_string(),
            outcome: if sent {
                "sent".into()
            } else {
                "no such instance".into()
            },
        });
        sent
    }
}

/// One request, one reply, one closed socket. Both ends of a browse are cheap
/// and neither is worth a held connection: the bot server runs this once a
/// second, and a directory that is down should cost a failed dial rather than
/// a stuck task.
///
/// Lives here rather than with its first caller because the question it asks
/// belongs to this protocol: the bot server browses with it, and the
/// meta-layer asks for the fleet view with it.
pub async fn request(url: &str, ask: u8, expect: u8) -> Option<String> {
    ask_with(url, vec![ask], expect).await
}

/// The same, for a question that carries a body. One frame out, one frame with
/// the tag we want back.
pub async fn ask_with(url: &str, frame: Vec<u8>, expect: u8) -> Option<String> {
    // Short, because everything it dials is a process that either answers
    // immediately or is not there. A long dial timeout would let a dead
    // address hold a caller's cycle open past the next one.
    let deadline = std::time::Duration::from_secs(2);
    let dial = tokio::time::timeout(deadline, tokio_tungstenite::connect_async(url));
    let (mut ws, _) = dial.await.ok()?.ok()?;
    ws.send(Message::Binary(frame)).await.ok()?;
    loop {
        let msg = tokio::time::timeout(deadline, ws.next())
            .await
            .ok()??
            .ok()?;
        if let Message::Binary(b) = msg {
            if b.first() == Some(&expect) && b.len() > 1 {
                let _ = ws.close(None).await;
                return Some(String::from_utf8_lossy(&b[1..]).to_string());
            }
        }
    }
}

/// Verify a claimed address the way a client is about to: connect, ask for
/// status, require a well-formed answer. The party with a reason to care runs
/// the check, and an operator can move hosts without a new credential.
#[allow(dead_code)]
pub async fn verify(address: &str) -> bool {
    check(address).await.is_ok()
}

/// The same check, keeping the reason it failed.
///
/// A failure here is invisible in the worst way: every game is running, the
/// arena is registered, and the browse reply offers nothing, because an
/// unproven address is withheld from players. "No games" is then the only
/// symptom, and the cause is one of half a dozen unrelated things -- DNS not
/// propagated, a certificate not issued yet, a firewall, a reverse proxy that
/// will not carry an upgrade, a host that cannot reach its own public address.
/// Guessing between those on a box with no shell is the situation this avoids.
async fn check(address: &str) -> Result<(), String> {
    const PATIENCE: std::time::Duration = std::time::Duration::from_secs(4);
    let connect = tokio_tungstenite::connect_async(address);
    let mut ws = match tokio::time::timeout(PATIENCE, connect).await {
        Err(_) => return Err("timed out connecting".into()),
        Ok(Err(e)) => return Err(format!("{e}")),
        Ok(Ok((ws, _))) => ws,
    };
    if let Err(e) = ws.send(Message::Binary(vec![STATUS_REQUEST])).await {
        return Err(format!("connected, then could not ask for status: {e}"));
    }
    let read = async {
        while let Some(msg) = ws.next().await {
            match msg {
                Ok(Message::Binary(b)) if b.first() == Some(&STATUS_REPLY) && b.len() > 1 => {
                    return Ok(());
                }
                Ok(_) => continue,
                Err(e) => return Err(format!("connected, then the socket broke: {e}")),
            }
        }
        Err("connected, but it closed without answering".to_string())
    };
    match tokio::time::timeout(PATIENCE, read).await {
        Err(_) => Err("connected, but no status arrived".into()),
        Ok(r) => r,
    }
}

/// One registration socket, for its whole life.
async fn serve_registration(
    dir: Arc<Mutex<Directory>>,
    ws: tokio_tungstenite::WebSocketStream<Box<dyn crate::Conn>>,
    local: bool,
) {
    let (mut sink, mut source) = ws.split();
    let (tx, mut rx) = mpsc::channel::<Message>(OUT_QUEUE);
    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(m).await.is_err() {
                return;
            }
        }
        // A close once the queue is done, so a rejected peer sees a closed
        // socket rather than a dropped one.
        let _ = sink.close().await;
    });

    // Nothing is registered until a REGISTER arrives and is accepted.
    let mut instance: Option<String> = None;

    while let Some(Ok(msg)) = source.next().await {
        // Answer the keepalive here too, for the same reason as the game port:
        // the pong tungstenite queues goes on the sink half, which this task
        // does not hold. An operator running an arena on a client library that
        // pings would be dropped mid-registration and never learn why.
        if let Message::Ping(p) = msg {
            if tx.try_send(Message::Pong(p)).is_err() {
                break;
            }
            continue;
        }
        let Message::Binary(data) = msg else { continue };
        match fleet::tag_of(&data) {
            Some(fleet::A2D_REGISTER) => {
                let Some(r) = fleet::parse::<fleet::Register>(&data, fleet::A2D_REGISTER) else {
                    continue;
                };
                // Said out loud, not just sent. A refusal the operator cannot
                // see is a support ticket: the arena knows only that it was
                // turned away, and until this existed neither side named a
                // wrong token at all.
                let reject = |reason: &str, detail: &str| {
                    // Every refusal goes through here, so counting it once
                    // here counts all of them.
                    crate::metrics::REFUSALS.inc();
                    println!(
                        "refused a registration for {:?} from {:?}: {reason} {detail}",
                        r.instance, r.address
                    );
                    fleet::frame(
                        fleet::D2A_REJECTED,
                        &fleet::Rejected {
                            reason: reason.into(),
                            detail: detail.into(),
                        },
                    )
                };
                if r.version != fleet::PROTOCOL {
                    let _ = tx.try_send(Message::Binary(reject(
                        "version_unsupported",
                        &format!("this directory speaks {}", fleet::PROTOCOL),
                    )));
                    break;
                }
                if r.instance.is_empty() || r.address.is_empty() {
                    let _ = tx.try_send(Message::Binary(reject(
                        "bad_address",
                        "instance and address are required",
                    )));
                    break;
                }
                let (pool, cap, region_default) = {
                    let d = dir.lock().await;
                    match d.catalog.pool_for_token(&r.token) {
                        Some(p) => (p.name.clone(), p.max_instances, p.region.clone()),
                        None => (String::new(), 0, String::new()),
                    }
                };
                if pool.is_empty() {
                    let _ = tx.try_send(Message::Binary(reject("unknown_token", "")));
                    break;
                }
                {
                    let mut d = dir.lock().await;
                    d.reap();
                    // The cap bounds what one leaked token can do. A reconnecting
                    // instance replaces its own row, so it does not count twice.
                    let held = d
                        .regs
                        .values()
                        .filter(|x| x.pool == pool && x.instance != r.instance)
                        .count();
                    if cap > 0 && held >= cap {
                        let _ = tx.try_send(Message::Binary(reject(
                            "pool_full",
                            &format!("pool {pool:?} is at its {cap} instance cap"),
                        )));
                        break;
                    }
                    let region = if r.region.is_empty() {
                        region_default
                    } else {
                        r.region.clone()
                    };
                    // Newest registration for an instance wins: a half-open
                    // socket outliving a restart must not lock an arena out.
                    d.regs.insert(
                        r.instance.clone(),
                        Reg {
                            pool: pool.clone(),
                            build: r.build.clone(),
                            host_id: r.host_id.clone(),
                            instance: r.instance.clone(),
                            address: r.address.clone(),
                            wt: r.wt.clone(),
                            region,
                            willing: r.willing.clone(),
                            status: fleet::Status::default(),
                            verified: false,
                            seen_ms: now_ms(),
                            intent: String::new(),
                            intent_until_ms: 0,
                            tx: tx.clone(),
                        },
                    );
                    let accepted = fleet::Accepted {
                        pool: pool.clone(),
                        catalog_version: d.version(),
                        catalog: d.wire_catalog(),
                        verified: false,
                    };
                    crate::metrics::REGISTRATIONS.inc();
                    let _ = tx.try_send(Message::Binary(fleet::frame(
                        fleet::D2A_ACCEPTED,
                        &accepted,
                    )));
                }
                println!(
                    "registered {} at {} (pool {pool:?}, willing {:?})",
                    r.instance, r.address, r.willing
                );
                instance = Some(r.instance.clone());

                // Verify out of band: an arena serves the players who already
                // reached it whether or not its listing is proven.
                let dir2 = dir.clone();
                let inst = r.instance.clone();
                let addr = r.address.clone();
                tokio::spawn(async move {
                    // Said on every change, and on the first attempt whatever it
                    // says, because the first one is the one an operator watching
                    // a deploy is waiting for. Not on every attempt after that: a
                    // failing address would otherwise be two lines a minute
                    // forever.
                    let mut spoken = false;
                    loop {
                        let outcome = check(&addr).await;
                        let ok = outcome.is_ok();
                        {
                            let mut d = dir2.lock().await;
                            match d.regs.get_mut(&inst) {
                                Some(reg) if reg.address == addr => {
                                    if reg.verified != ok || !spoken {
                                        match &outcome {
                                            Ok(()) => println!("{inst} at {addr}: verified"),
                                            Err(why) => println!(
                                                "{inst} at {addr}: address check failed: {why}\n  \
                                                 players are not being sent here until it passes; \
                                                 retrying every {}s",
                                                VERIFY_EVERY_MS / 1000
                                            ),
                                        }
                                        spoken = true;
                                    }
                                    reg.verified = ok;
                                }
                                // Gone, or re-registered elsewhere: stop.
                                _ => return,
                            }
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(VERIFY_EVERY_MS)).await;
                    }
                });
            }
            Some(fleet::A2D_STATUS) => {
                let Some(s) = fleet::parse::<fleet::Status>(&data, fleet::A2D_STATUS) else {
                    continue;
                };
                let Some(id) = instance.clone() else { continue };
                let mut d = dir.lock().await;
                if let Some(r) = d.regs.get_mut(&id) {
                    r.status = s;
                    r.seen_ms = now_ms();
                }
            }
            Some(fleet::A2D_INTENT) => {
                let Some(i) = fleet::parse::<fleet::Intent>(&data, fleet::A2D_INTENT) else {
                    continue;
                };
                let Some(id) = instance.clone() else { continue };
                let mut d = dir.lock().await;
                if let Some(r) = d.regs.get_mut(&id) {
                    r.intent = i.zone;
                    r.intent_until_ms = now_ms() + i.expires_ms.min(60_000);
                    r.seen_ms = now_ms();
                }
            }
            Some(fleet::A2D_ACK) => {
                let Some(a) = fleet::parse::<fleet::Ack>(&data, fleet::A2D_ACK) else {
                    continue;
                };
                let id = instance.clone().unwrap_or_default();
                let mut d = dir.lock().await;
                println!("ack from {id}: command {} {}", a.command_id, a.outcome);
                d.note(AuditRow {
                    at_ms: now_ms(),
                    actor: String::new(),
                    verb: format!("ack:{}", a.command_id),
                    target: id,
                    args: a.detail,
                    outcome: a.outcome,
                });
            }
            // A client asking a directory for the browse list, on the same port.
            Some(t) if t == STATUS_REQUEST => {
                let d = dir.lock().await;
                let mut m = vec![STATUS_REPLY];
                m.extend_from_slice(
                    serde_json::to_string(&d.browse())
                        .unwrap_or_default()
                        .as_bytes(),
                );
                if tx.try_send(Message::Binary(m)).is_err() {
                    break;
                }
            }
            // An operator asking for everything this directory has observed,
            // which is the browse reply plus the rows a player is deliberately
            // not shown: unverified instances, ages, intents, pools, metrics.
            //
            // Answered only for a peer that arrived without a proxy in front
            // of it, which on these hosts means a process on the box rather
            // than somebody's browser. Loopback alone will not do it: every
            // service here runs on the host network and Caddy proxies to
            // 127.0.0.1, so a request through the public /dir route has a
            // loopback peer too. What it does not have is this socket without
            // an `X-Forwarded-For`, because Caddy always writes one.
            //
            // The meta-layer is the caller, and it is the caller because it is
            // the only process that can check an admin flag. See
            // `/v1/admin/fleet`.
            Some(t) if t == fleet::O2D_FLEET => {
                if !local {
                    println!("refused a fleet view from a proxied peer");
                    continue;
                }
                let d = dir.lock().await;
                // The audit rides along rather than costing a second round
                // trip, because the panel polls this every few seconds and
                // the log is how a command's outcome gets back to whoever
                // sent it. Newest first here; the panel reads downward.
                let mut body = serde_json::to_value(d.view()).unwrap_or_default();
                let mut rows = d.audit.clone();
                rows.reverse();
                body["audit"] = serde_json::to_value(rows).unwrap_or_default();
                let mut m = vec![fleet::D2O_FLEET];
                m.extend_from_slice(body.to_string().as_bytes());
                if tx.try_send(Message::Binary(m)).is_err() {
                    break;
                }
            }
            // An operator handing over the maps an admin drew and the zone
            // rotations naming them. Same gate as the view above, and the same
            // reason: the meta-layer is the only process that can tell an
            // operator from anybody else.
            //
            // Taking one bumps the version this directory serves, so every
            // arena registered to it takes the new catalog on its next
            // heartbeat and every room swaps ground at its next whistle. That
            // is the whole of the delivery: the machinery a catalog edit
            // already used, reached by a different door.
            Some(t) if t == fleet::O2D_MAPS => {
                if !local {
                    println!("refused a publication from a proxied peer");
                    continue;
                }
                let Some(p) = fleet::parse::<fleet::Published>(&data, fleet::O2D_MAPS) else {
                    continue;
                };
                let (serial, zones) = (p.serial, p.zones.len());
                let mut d = dir.lock().await;
                let reply = match d.publish(p) {
                    Some(v) => {
                        println!(
                            "catalog: publication {serial} taken, {zones} zone(s), serving v{v}"
                        );
                        serde_json::json!({ "version": v, "serial": serial, "taken": true })
                    }
                    None => serde_json::json!({
                        "version": d.version(),
                        "serial": d.published.serial,
                        "taken": false,
                        "why": "this directory already holds a later publication",
                    }),
                };
                // Every registered arena hears about it now rather than at its
                // next heartbeat, because a rotation an operator just set is
                // one they are about to go and look at.
                let catalog = d.wire_catalog();
                let frame = fleet::frame(fleet::D2A_CATALOG, &catalog);
                for r in d.regs.values() {
                    let _ = r.tx.try_send(Message::Binary(frame.clone()));
                }
                let mut m = vec![fleet::D2O_MAPS];
                m.extend_from_slice(reply.to_string().as_bytes());
                if tx.try_send(Message::Binary(m)).is_err() {
                    break;
                }
            }
            // An operator asking this directory to command an instance it
            // holds. Same gate as the view above, and the same reason: the
            // meta-layer is the only process that can tell an operator from
            // anybody else, so it asks on their behalf over loopback.
            Some(t) if t == fleet::O2D_COMMAND => {
                if !local {
                    println!("refused a command from a proxied peer");
                    continue;
                }
                let Some(c) = fleet::parse::<fleet::OperatorCommand>(&data, fleet::O2D_COMMAND)
                else {
                    continue;
                };
                let mut d = dir.lock().await;
                let reply = if !fleet::VERBS.contains(&c.verb.as_str()) {
                    // What the constant is for: a typo is refused here rather
                    // than sent, so no arena has to answer `unknown_verb` and
                    // no audit row records a verb that never existed.
                    fleet::CommandSent {
                        sent: 0,
                        error: format!(
                            "no such verb {:?}; one of {}",
                            c.verb,
                            fleet::VERBS.join(", ")
                        ),
                    }
                } else {
                    // Empty or `*` is every instance this directory holds. A
                    // kick wants that: an operator knows the call sign and not
                    // which process is holding that pilot.
                    let targets: Vec<String> = if c.instance.is_empty() || c.instance == "*" {
                        d.regs.keys().cloned().collect()
                    } else {
                        vec![c.instance.clone()]
                    };
                    let mut sent = 0u32;
                    for t in &targets {
                        if d.command(t, &c.verb, &c.args, &c.actor) {
                            sent += 1;
                        }
                    }
                    fleet::CommandSent {
                        sent,
                        error: if sent == 0 {
                            "no instance took it".into()
                        } else {
                            String::new()
                        },
                    }
                };
                if tx
                    .try_send(Message::Binary(fleet::frame(fleet::D2O_COMMAND, &reply)))
                    .is_err()
                {
                    break;
                }
            }
            _ => {}
        }
    }

    if let Some(id) = instance {
        let mut d = dir.lock().await;
        if d.regs
            .get(&id)
            .map(|r| r.tx.same_channel(&tx))
            .unwrap_or(false)
        {
            d.regs.remove(&id);
            println!("{id} disconnected");
        }
    }
    // Let the writer drain before it goes. Every rejection above is queued and
    // then the loop breaks immediately, so aborting here threw away the frame
    // that says why -- and an arena that is told nothing reads a rejection as a
    // clean disconnect, resets its backoff, and comes straight back. A wrong
    // token produced a silent one-per-second reconnect loop against this
    // directory, forever, with neither side ever naming the cause.
    //
    // The identical mistake on the client side is fixed in main.rs. It was not
    // generalised at the time, which is the whole reason it was still here.
    let mut writer = writer;
    drop(tx);
    if tokio::time::timeout(std::time::Duration::from_secs(2), &mut writer)
        .await
        .is_err()
    {
        writer.abort();
    }
}

/// Push the view to every registered arena, on change and on a heartbeat. This
/// is how the fleet's shared picture propagates: through the workers, because
/// directories never talk to each other.
async fn push_views(dir: Arc<Mutex<Directory>>) {
    let mut last = String::new();
    loop {
        {
            let mut d = dir.lock().await;
            d.reap();
            let view = d.view();
            let json = serde_json::to_string(&view).unwrap_or_default();
            // Ages change every tick, so compare the part that matters rather
            // than the whole document.
            let fingerprint: String = view
                .instances
                .iter()
                .map(|i| {
                    format!(
                        "{}:{}:{}:{}:{}:{}|",
                        i.instance,
                        i.zone,
                        i.players,
                        i.rooms.len(),
                        i.capped,
                        i.intent
                    )
                })
                .collect();
            if fingerprint != last {
                last = fingerprint;
            }
            let msg = {
                let mut m = vec![fleet::D2A_VIEW];
                m.extend_from_slice(json.as_bytes());
                m
            };
            for r in d.regs.values() {
                let _ = r.tx.try_send(Message::Binary(msg.clone()));
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(fleet::HEARTBEAT_MS / 2)).await;
    }
}

/// Serve the directory.
///
///     vectorwake-server directory <listen> [catalog-dir]
pub async fn run() {
    crate::metrics::spawn("directory", "");
    let addr = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "0.0.0.0:9000".into());
    let dir_path = std::env::args().nth(3).unwrap_or_else(|| "catalog".into());

    let catalog = match crate::catalog::load(&dir_path) {
        Ok(c) => c,
        Err(e) => {
            println!("catalog {dir_path}: {e}");
            println!("a directory with no catalog has nothing to serve; refusing to start");
            std::process::exit(1);
        }
    };
    println!(
        "directory {:?}: catalog version {}, {} zones, {} pools",
        catalog.name,
        catalog.version,
        catalog.order.len(),
        catalog.pools.len()
    );
    for n in &catalog.order {
        println!("  zone {n}");
    }

    let dir = Arc::new(Mutex::new(Directory::new(catalog)));
    tokio::spawn(push_views(dir.clone()));

    // TLS if the operator supplied a certificate. Registration carries a bearer
    // token, so a public directory wants this; loopback development does not.
    let cert = std::env::var("VW_TLS_CERT").unwrap_or_default();
    let key = std::env::var("VW_TLS_KEY").unwrap_or_default();
    let tls = crate::tls_acceptor(&cert, &key);
    if tls.is_none() && !cert.is_empty() {
        println!("VW_TLS_CERT set without VW_TLS_KEY; serving cleartext");
    }

    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    println!(
        "vectorwake directory listening on {}{addr}",
        if tls.is_some() { "wss://" } else { "ws://" }
    );

    while let Ok((stream, peer)) = listener.accept().await {
        let dir = dir.clone();
        let tls = tls.clone();
        tokio::spawn(async move {
            let stream: Box<dyn crate::Conn> = match &tls {
                Some(a) => match a.accept(stream).await {
                    Ok(s) => Box::new(s),
                    Err(_) => return,
                },
                None => Box::new(stream),
            };
            // A bearer token over cleartext is a token given away. Loopback is
            // the exception, because that is development and it has no path.
            let cleartext_remote = tls.is_none() && !peer.ip().is_loopback();
            accept_conn(stream, dir, peer.ip().is_loopback(), cleartext_remote).await;
        });
    }
}

/// One connection, from handshake to hang-up. Its own function so a test can
/// hand it a socket: what it decides, whether this peer may ask for the fleet
/// view, is the only authorisation on this port and is worth proving rather
/// than reading.
async fn accept_conn(
    stream: Box<dyn crate::Conn>,
    dir: Arc<Mutex<Directory>>,
    peer_loopback: bool,
    cleartext_remote: bool,
) {
    // Everything an arena sends up this socket is small: a REGISTER, a
    // STATUS, an INTENT, an ACK, none past a kilobyte. The library default
    // buffers frames up to 64 MiB each, and this port is dialed by strangers
    // before any token is checked, so the cap is what bounds what an
    // unauthenticated peer can make this process hold. The big payloads,
    // catalogs and views, travel the other way and are not limited by this.
    let cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
        max_message_size: Some(64 * 1024),
        max_frame_size: Some(64 * 1024),
        ..Default::default()
    };
    // Whether a proxy handled this request before we did. Caddy writes
    // `X-Forwarded-For` on everything it forwards, upgrades included, so its
    // presence is the difference between a process on this box and somebody
    // on the internet, both of which otherwise arrive from 127.0.0.1 on a
    // host-network deployment. Read during the handshake because that is the
    // only place the HTTP headers exist.
    let proxied = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let saw = proxied.clone();
    // The closure's error type is tungstenite's own `ErrorResponse`, which is
    // a whole HTTP response and is what the handshake takes. Not ours to box.
    #[allow(clippy::result_large_err)]
    let ws = tokio_tungstenite::accept_hdr_async_with_config(
        stream,
        move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
              resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
            if req.headers().contains_key("x-forwarded-for") {
                saw.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            Ok(resp)
        },
        Some(cfg),
    )
    .await;
    let Ok(ws) = ws else { return };
    let local = peer_loopback && !proxied.load(std::sync::atomic::Ordering::Relaxed);
    if cleartext_remote {
        let (mut sink, _) = ws.split();
        let _ = sink
            .send(Message::Binary(fleet::frame(
                fleet::D2A_REJECTED,
                &fleet::Rejected {
                    reason: "bad_address".into(),
                    detail: "this directory will not accept a credential over \
                             cleartext from a remote peer; set VW_TLS_CERT and \
                             VW_TLS_KEY"
                        .into(),
                },
            )))
            .await;
        return;
    }
    serve_registration(dir, ws, local).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Catalog, PoolDef, ZoneDef};

    fn cat() -> Catalog {
        let mut c = Catalog {
            version: 7,
            name: "t".into(),
            order: vec!["chaos".into(), "war".into()],
            pools: vec![PoolDef {
                name: "p".into(),
                token: format!("sha256:{}", crate::catalog::sha256_hex(b"secret")),
                region: "local".into(),
                max_instances: 2,
            }],
            ..Default::default()
        };
        for n in ["chaos", "war"] {
            c.zones.insert(
                n.into(),
                ZoneDef {
                    max_players: Some(8),
                    fill_target: Some(4),
                    ..Default::default()
                },
            );
        }
        c
    }

    /// A publication naming one zone, with tiles that are not a real map: the
    /// directory carries bytes and never reads them, which is the property
    /// these check.
    fn publication(serial: u32, zone: &str, maps: &[(&str, &[u8])]) -> fleet::Published {
        fleet::Published {
            serial,
            zones: vec![fleet::PublishedZone {
                zone: zone.into(),
                maps: maps
                    .iter()
                    .map(|(n, b)| fleet::PublishedMap {
                        name: (*n).into(),
                        bytes_b64: fleet::b64(b),
                    })
                    .collect(),
            }],
        }
    }

    #[test]
    fn a_publication_replaces_one_zone_and_leaves_the_rest_on_the_file() {
        let mut d = Directory::new(cat());
        assert_eq!(d.version(), 7, "with nothing published, the file's version");

        let v = d
            .publish(publication(3, "chaos", &[("drawn", b"tiles")]))
            .expect("a first publication is taken");
        assert_eq!(v, 10, "the served version is the file's plus the serial");

        let w = d.wire_catalog();
        assert_eq!(w.version, 10, "and that is the version an arena is offered");
        let chaos = w.zones.iter().find(|z| z.name == "chaos").expect("chaos");
        assert_eq!(
            chaos.maps_b64,
            vec![fleet::b64(b"tiles")],
            "the published rotation is what the zone plays"
        );
        let war = w.zones.iter().find(|z| z.name == "war").expect("war");
        assert!(
            war.maps_b64.is_empty(),
            "a zone nobody published still reads its maps off the file"
        );
    }

    #[test]
    fn a_later_publication_wins_and_an_earlier_one_is_refused() {
        let mut d = Directory::new(cat());
        d.publish(publication(2, "chaos", &[("first", b"one")]));
        let v = d
            .publish(publication(5, "chaos", &[("second", b"two")]))
            .expect("a later serial is taken");
        assert_eq!(v, 12);

        // Two pushes can cross on the wire. The loser must not undo the
        // winner, which is the same rule an arena applies to a catalog.
        assert!(
            d.publish(publication(4, "chaos", &[("stale", b"old")]))
                .is_none(),
            "an older publication is refused"
        );
        let w = d.wire_catalog();
        assert_eq!(w.version, 12, "and the version does not go backwards");
        let chaos = w.zones.iter().find(|z| z.name == "chaos").expect("chaos");
        assert_eq!(
            chaos.maps_b64,
            vec![fleet::b64(b"two")],
            "nor does the ground"
        );
    }

    #[test]
    fn a_publication_and_a_file_bump_both_count_up() {
        // The two sources of change are added rather than one replacing the
        // other, so "highest version wins" still holds when an operator has
        // published and somebody then ships a new catalog.
        let mut d = Directory::new(cat());
        d.publish(publication(4, "chaos", &[("drawn", b"tiles")]));
        let published = d.version();
        d.catalog.version = 9;
        assert!(
            d.version() > published,
            "a newer file still outranks what it replaced"
        );
    }

    #[test]
    fn an_empty_rotation_hands_the_zone_back_to_the_file() {
        let mut d = Directory::new(cat());
        d.publish(publication(1, "chaos", &[("drawn", b"tiles")]));
        // A publication that names no maps for a zone is how a rotation is
        // taken off: the meta-layer deletes the row rather than storing an
        // empty list, so the zone simply stops appearing here.
        d.publish(fleet::Published {
            serial: 2,
            zones: vec![],
        });
        let w = d.wire_catalog();
        let chaos = w.zones.iter().find(|z| z.name == "chaos").expect("chaos");
        assert!(
            chaos.maps_b64.is_empty(),
            "with no publication the zone reads the file again"
        );
    }

    fn reg(d: &mut Directory, id: &str, zone: &str, players: u32, verified: bool) {
        let (tx, _rx) = mpsc::channel(1);
        d.regs.insert(
            id.into(),
            Reg {
                pool: "p".into(),
                build: "testbuild".into(),
                host_id: String::new(),
                instance: id.into(),
                address: format!("ws://{id}:9010"),
                wt: String::new(),
                region: "local".into(),
                willing: vec![],
                status: fleet::Status {
                    zone: zone.into(),
                    players,
                    rooms: vec![fleet::RoomView {
                        number: 1,
                        ..Default::default()
                    }],
                    max_rooms: 1,
                    ..Default::default()
                },
                verified,
                seen_ms: now_ms(),
                intent: String::new(),
                intent_until_ms: 0,
                tx,
            },
        );
    }

    #[test]
    fn browse_lists_zones_with_instances_and_totals() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "chaos", 5, true);
        d.regs.get_mut("a").unwrap().status.spectators = 2;
        reg(&mut d, "b", "chaos", 2, true);
        reg(&mut d, "c", "war", 1, true);
        let b = d.browse();
        assert_eq!(b.catalog_version, 7);
        assert_eq!(b.zones.len(), 2, "every catalog zone appears, busy or not");
        let chaos = b.zones.iter().find(|z| z.name == "chaos").unwrap();
        assert_eq!(
            chaos.players, 9,
            "the zone total includes people flying and watching"
        );
        assert_eq!(chaos.instances.len(), 2);
        assert_eq!(
            chaos.instances[0].players, 7,
            "fullest first concentrates by default"
        );
    }

    #[test]
    fn an_unverified_instance_is_seen_by_an_operator_and_not_by_a_player() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "chaos", 5, false);
        let chaos = d
            .browse()
            .zones
            .into_iter()
            .find(|z| z.name == "chaos")
            .unwrap();
        assert!(
            chaos.instances.is_empty(),
            "an unproven address is not offered"
        );
        assert_eq!(chaos.players, 0);
        assert_eq!(d.view().instances.len(), 1, "but the admin view shows it");
        assert!(!d.view().instances[0].verified);
    }

    #[test]
    fn full_means_no_seat_and_no_headroom() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "chaos", 8, true); // at max_players, rooms 1 of 1
        let inst = &d.browse().zones[0].instances[0];
        assert!(inst.full, "capped on players and on rooms");

        let mut d = Directory::new(cat());
        reg(&mut d, "b", "chaos", 8, true);
        d.regs.get_mut("b").unwrap().status.max_rooms = 4;
        let inst = &d.browse().zones[0].instances[0];
        assert!(!inst.full, "room headroom means a seat can still be made");

        let mut d = Directory::new(cat());
        reg(&mut d, "c", "chaos", 7, true);
        d.regs.get_mut("c").unwrap().status.spectators = 3;
        let inst = &d.browse().zones[0].instances[0];
        assert_eq!(inst.players, 10, "spectators are visible in the population");
        assert!(
            !inst.full,
            "spectators do not consume the remaining ship seat"
        );
    }

    #[test]
    fn a_full_instance_is_listed_but_never_first() {
        // The head of the list is what a client takes by default, so it has to
        // be an address that will accept the player who clicked it. Before this,
        // sorting purely by population put the one full instance at the top and
        // the default click was a guaranteed refusal.
        let mut d = Directory::new(cat());
        reg(&mut d, "packed", "chaos", 8, true); // at max_players, one room of one
        reg(&mut d, "roomy", "chaos", 3, true);
        let chaos = d
            .browse()
            .zones
            .into_iter()
            .find(|z| z.name == "chaos")
            .unwrap();
        assert_eq!(chaos.instances.len(), 2, "the full one is still shown");
        assert_eq!(
            chaos.instances[0].players, 3,
            "but the one with room is first"
        );
        assert!(chaos.instances[1].full);
        assert_eq!(chaos.players, 11, "and both count toward the zone's total");
    }

    #[test]
    fn a_silent_registration_is_reaped() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "chaos", 1, true);
        d.regs.get_mut("a").unwrap().seen_ms = now_ms() - fleet::DEAD_AFTER_MS - 1;
        d.reap();
        assert!(d.regs.is_empty(), "a delisting has to be prompt");
    }

    #[test]
    fn an_expired_intent_stops_reserving_a_zone() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "", 0, true);
        d.regs.get_mut("a").unwrap().intent = "war".into();
        d.regs.get_mut("a").unwrap().intent_until_ms = now_ms() + 5_000;
        assert_eq!(d.view().instances[0].intent, "war");
        d.regs.get_mut("a").unwrap().intent_until_ms = now_ms() - 1;
        assert_eq!(
            d.view().instances[0].intent,
            "",
            "a crashed announcer releases its claim on a timer"
        );
    }

    #[test]
    fn the_wire_catalog_omits_the_token_table() {
        let d = Directory::new(cat());
        let w = d.wire_catalog();
        assert_eq!(w.version, 7);
        assert_eq!(w.zones.len(), 2);
        assert_eq!(w.zones[0].name, "chaos", "declared order survives the wire");
        let json = serde_json::to_string(&w).unwrap();
        assert!(!json.contains("secret"), "no raw token");
        assert!(
            !json.contains("sha256"),
            "not even the digest: an arena cannot register others"
        );
    }

    #[test]
    fn a_command_to_a_stranger_is_refused_and_logged() {
        let mut d = Directory::new(cat());
        assert!(!d.command("nobody", "drain", "", "chris"));
        assert_eq!(d.audit.len(), 1);
        assert_eq!(d.audit[0].outcome, "no such instance");
    }

    #[test]
    fn the_audit_log_is_bounded() {
        let mut d = Directory::new(cat());
        for _ in 0..AUDIT_MAX + 50 {
            d.command("nobody", "drain", "", "chris");
        }
        assert_eq!(
            d.audit.len(),
            AUDIT_MAX,
            "a log that grows forever is an outage waiting"
        );
    }

    #[test]
    fn the_view_carries_what_an_operator_checks_the_deployment_by() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "chaos", 5, true);
        let v = d.view();
        assert_eq!(v.catalog_version, 7, "which version this directory serves");
        assert_eq!(
            v.meta_key, d.catalog.meta.key,
            "and the key it says to check tokens with"
        );
    }

    /// The fleet view is the one thing on this port a stranger may not have,
    /// and the only thing standing between them is whether a proxy touched the
    /// request. Both halves are proven against a real socket rather than
    /// asserted about the flag, because the flag is not the claim: the claim is
    /// that a browser coming through Caddy cannot get this and a process on the
    /// box can.
    #[tokio::test]
    async fn a_proxied_peer_browses_but_cannot_read_the_fleet() {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;

        let mut d = Directory::new(cat());
        reg(&mut d, "unproven", "chaos", 3, false);
        let dir = Arc::new(Mutex::new(d));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((stream, peer)) = listener.accept().await {
                let dir = dir.clone();
                tokio::spawn(async move {
                    accept_conn(Box::new(stream), dir, peer.ip().is_loopback(), false).await;
                });
            }
        });

        // Ask one question and wait briefly for the tag that answers it.
        async fn ask(port: u16, forwarded: bool, tag: u8, want: u8) -> Option<String> {
            let mut req = format!("ws://127.0.0.1:{port}/")
                .into_client_request()
                .unwrap();
            if forwarded {
                req.headers_mut()
                    .insert("x-forwarded-for", "203.0.113.9".parse().unwrap());
            }
            let (mut ws, _) = tokio_tungstenite::connect_async(req).await.ok()?;
            ws.send(Message::Binary(vec![tag])).await.ok()?;
            let wait = std::time::Duration::from_millis(500);
            while let Ok(Some(Ok(m))) = tokio::time::timeout(wait, ws.next()).await {
                if let Message::Binary(b) = m {
                    if b.first() == Some(&want) {
                        return Some(String::from_utf8_lossy(&b[1..]).to_string());
                    }
                }
            }
            None
        }

        let direct = ask(port, false, fleet::O2D_FLEET, fleet::D2O_FLEET).await;
        assert!(
            direct.is_some(),
            "a process on the box reads the fleet view"
        );
        assert!(
            direct.unwrap().contains("unproven"),
            "including the unverified instance no browse reply carries"
        );

        assert!(
            ask(port, true, fleet::O2D_FLEET, fleet::D2O_FLEET)
                .await
                .is_none(),
            "a request that came through a proxy is refused the fleet view"
        );

        // And refused rather than disconnected: the same peer still browses,
        // which is what every player's client does on this port all day.
        let browsed = ask(port, true, STATUS_REQUEST, STATUS_REPLY).await;
        assert!(browsed.is_some(), "a proxied peer still browses");
        assert!(
            !browsed.unwrap().contains("unproven"),
            "and still does not learn about an unverified instance"
        );
    }
}
