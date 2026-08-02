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

/// One registration this directory holds. Everything here is its own
/// observation, which is the rule that bounds a lying arena to lying about
/// itself.
struct Reg {
    pool: String,
    instance: String,
    address: String,
    region: String,
    willing: Vec<String>,
    status: fleet::Status,
    verified: bool,
    seen_ms: u64,
    intent: String,
    intent_until_ms: u64,
    tx: mpsc::UnboundedSender<Vec<u8>>,
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
    pub address: String,
    pub region: String,
    pub players: u32,
    pub bots: u32,
    /// The directory's summary of whether a join would be refused, which saves a
    /// client the round trip it would otherwise spend learning the same thing.
    pub full: bool,
}

impl Directory {
    pub fn new(catalog: Catalog) -> Self {
        Directory {
            catalog,
            regs: HashMap::new(),
            next_command: 1,
            audit: Vec::new(),
        }
    }

    /// The catalog as it travels: zone definitions, bans and staff, and none of
    /// the pool tokens.
    pub fn wire_catalog(&self) -> fleet::WireCatalog {
        let c = &self.catalog;
        fleet::WireCatalog {
            version: c.version,
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
                        max_rooms: z.max_rooms() as u32,
                        teams: z.teams(),
                        balance: z.balance.clone(),
                        map_b64: c.map_bytes(n).map(|b| fleet::b64(&b)).unwrap_or_default(),
                        zone_toml: z.raw.clone(),
                    })
                })
                .collect(),
        }
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
                    rooms: r.status.rooms,
                    max_rooms: r.status.max_rooms,
                    capped: r.status.capped,
                    verified: r.verified,
                    age_ms: now.saturating_sub(r.seen_ms),
                    intent: if r.intent_until_ms > now { r.intent.clone() } else { String::new() },
                    intent_ms: r.intent_until_ms.saturating_sub(now),
                    pool: r.pool.clone(),
                    metrics: r.status.metrics.clone(),
                })
                .collect(),
        }
    }

    pub fn browse(&self) -> Browse {
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
                z.players += r.status.players;
                z.bots += r.status.bots;
                z.instances.push(BrowseInstance {
                    address: r.address.clone(),
                    region: r.region.clone(),
                    players: r.status.players,
                    bots: r.status.bots,
                    // Full means no seat and no headroom to make one.
                    full: r.status.players >= cap
                        && r.status.rooms >= r.status.max_rooms.max(1),
                });
            }
        }
        // Fullest first, so a client taking the head of the list concentrates a
        // population by default rather than scattering it.
        for z in zones.iter_mut() {
            z.instances.sort_by(|a, b| b.players.cmp(&a.players));
        }
        Browse {
            name: self.catalog.name.clone(),
            description: self.catalog.description.clone(),
            catalog_version: self.catalog.version,
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
            Some(r) => r.tx.send(msg).is_ok(),
            None => false,
        };
        self.note(AuditRow {
            at_ms: now_ms(),
            actor: actor.to_string(),
            verb: verb.to_string(),
            target: instance.to_string(),
            args: args.to_string(),
            outcome: if sent { "sent".into() } else { "no such instance".into() },
        });
        sent
    }
}

/// Verify a claimed address the way a client is about to: connect, ask for
/// status, require a well-formed answer. The party with a reason to care runs
/// the check, and an operator can move hosts without a new credential.
pub async fn verify(address: &str) -> bool {
    let connect = tokio_tungstenite::connect_async(address);
    let Ok(Ok((mut ws, _))) =
        tokio::time::timeout(std::time::Duration::from_secs(4), connect).await
    else {
        return false;
    };
    if ws.send(Message::Binary(vec![STATUS_REQUEST])).await.is_err() {
        return false;
    }
    let read = async {
        while let Some(Ok(msg)) = ws.next().await {
            if let Message::Binary(b) = msg {
                if b.first() == Some(&STATUS_REPLY) && b.len() > 1 {
                    return true;
                }
            }
        }
        false
    };
    tokio::time::timeout(std::time::Duration::from_secs(4), read)
        .await
        .unwrap_or(false)
}

/// One registration socket, for its whole life.
async fn serve_registration(
    dir: Arc<Mutex<Directory>>,
    ws: tokio_tungstenite::WebSocketStream<Box<dyn crate::Conn>>,
) {
    let (mut sink, mut source) = ws.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(Message::Binary(m)).await.is_err() {
                break;
            }
        }
    });

    // Nothing is registered until a REGISTER arrives and is accepted.
    let mut instance: Option<String> = None;

    while let Some(Ok(msg)) = source.next().await {
        let Message::Binary(data) = msg else { continue };
        match fleet::tag_of(&data) {
            Some(fleet::A2D_REGISTER) => {
                let Some(r) = fleet::parse::<fleet::Register>(&data, fleet::A2D_REGISTER) else {
                    continue;
                };
                let reject = |reason: &str, detail: &str| {
                    fleet::frame(
                        fleet::D2A_REJECTED,
                        &fleet::Rejected {
                            reason: reason.into(),
                            detail: detail.into(),
                        },
                    )
                };
                if r.version != fleet::PROTOCOL {
                    let _ = tx.send(reject(
                        "version_unsupported",
                        &format!("this directory speaks {}", fleet::PROTOCOL),
                    ));
                    break;
                }
                if r.instance.is_empty() || r.address.is_empty() {
                    let _ = tx.send(reject("bad_address", "instance and address are required"));
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
                    let _ = tx.send(reject("unknown_token", ""));
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
                        let _ = tx.send(reject(
                            "pool_full",
                            &format!("pool {pool:?} is at its {cap} instance cap"),
                        ));
                        break;
                    }
                    let region = if r.region.is_empty() { region_default } else { r.region.clone() };
                    // Newest registration for an instance wins: a half-open
                    // socket outliving a restart must not lock an arena out.
                    d.regs.insert(
                        r.instance.clone(),
                        Reg {
                            pool: pool.clone(),
                            instance: r.instance.clone(),
                            address: r.address.clone(),
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
                        catalog_version: d.catalog.version,
                        catalog: d.wire_catalog(),
                        verified: false,
                    };
                    let _ = tx.send(fleet::frame(fleet::D2A_ACCEPTED, &accepted));
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
                    loop {
                        let ok = verify(&addr).await;
                        {
                            let mut d = dir2.lock().await;
                            match d.regs.get_mut(&inst) {
                                Some(reg) if reg.address == addr => {
                                    if reg.verified != ok {
                                        println!(
                                            "{inst} at {addr}: {}",
                                            if ok { "verified" } else { "verification failed" }
                                        );
                                    }
                                    reg.verified = ok;
                                }
                                // Gone, or re-registered elsewhere: stop.
                                _ => return,
                            }
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(VERIFY_EVERY_MS))
                            .await;
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
                let Some(a) = fleet::parse::<fleet::Ack>(&data, fleet::A2D_ACK) else { continue };
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
                    serde_json::to_string(&d.browse()).unwrap_or_default().as_bytes(),
                );
                let _ = tx.send(m);
            }
            _ => {}
        }
    }

    if let Some(id) = instance {
        let mut d = dir.lock().await;
        if d.regs.get(&id).map(|r| r.tx.same_channel(&tx)).unwrap_or(false) {
            d.regs.remove(&id);
            println!("{id} disconnected");
        }
    }
    writer.abort();
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
                        i.instance, i.zone, i.players, i.rooms, i.capped, i.intent
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
                let _ = r.tx.send(msg.clone());
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(fleet::HEARTBEAT_MS / 2)).await;
    }
}

/// Serve the directory.
///
///     vectorwake-server directory <listen> [catalog-dir]
pub async fn run() {
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

    crate::admin::spawn(dir.clone());

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
            let Ok(ws) = tokio_tungstenite::accept_async(stream).await else { return };
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
            serve_registration(dir, ws).await;
        });
    }
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

    fn reg(d: &mut Directory, id: &str, zone: &str, players: u32, verified: bool) {
        let (tx, _rx) = mpsc::unbounded_channel();
        d.regs.insert(
            id.into(),
            Reg {
                pool: "p".into(),
                instance: id.into(),
                address: format!("ws://{id}:9010"),
                region: "local".into(),
                willing: vec![],
                status: fleet::Status {
                    zone: zone.into(),
                    players,
                    rooms: 1,
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
        reg(&mut d, "b", "chaos", 2, true);
        reg(&mut d, "c", "war", 1, true);
        let b = d.browse();
        assert_eq!(b.catalog_version, 7);
        assert_eq!(b.zones.len(), 2, "every catalog zone appears, busy or not");
        let chaos = b.zones.iter().find(|z| z.name == "chaos").unwrap();
        assert_eq!(chaos.players, 7, "per-zone total needs no arithmetic by the client");
        assert_eq!(chaos.instances.len(), 2);
        assert_eq!(chaos.instances[0].players, 5, "fullest first concentrates by default");
    }

    #[test]
    fn an_unverified_instance_is_seen_by_an_operator_and_not_by_a_player() {
        let mut d = Directory::new(cat());
        reg(&mut d, "a", "chaos", 5, false);
        let chaos = d.browse().zones.into_iter().find(|z| z.name == "chaos").unwrap();
        assert!(chaos.instances.is_empty(), "an unproven address is not offered");
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
        assert_eq!(d.view().instances[0].intent, "",
                   "a crashed announcer releases its claim on a timer");
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
        assert!(!json.contains("sha256"), "not even the digest: an arena cannot register others");
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
        assert_eq!(d.audit.len(), AUDIT_MAX, "a log that grows forever is an outage waiting");
    }
}
