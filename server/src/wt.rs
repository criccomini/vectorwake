//! The WebTransport door.
//!
//! The same protocol the WebSocket serves, carried by QUIC instead of TCP so
//! that one lost packet no longer holds every snapshot behind it. The measured
//! cost of that holding is in docs/architecture/networking.md: at 150 ms and 3%
//! loss a hitch every 1.4 seconds, entirely in the tail, because TCP delivers
//! the backlog in a burst once the retransmit lands.
//!
//! Three lanes, chosen per message rather than per connection, which is the
//! shape the message model always had:
//!
//! - The client opens one bidirectional stream and speaks first on it. Both
//!   directions carry every reliable message on that stream, length-framed
//!   with a u32 because a packed map is bigger than a u16 can say.
//! - Snapshots go out as datagrams when they fit in one, else on a fresh
//!   unidirectional stream each. Either way a loss delays only the snapshot
//!   it hit; the next one arrives on time and the client drops the late one
//!   by its tick.
//! - Inputs arrive as datagrams. Losing one costs a tick of held buttons,
//!   which is what the input model already does with silence.
//!
//! The handler behind all of this is `serve_client`, the same function the
//! WebSocket accept loop calls. This module only carries bytes.
//!
//! Certificates are the deployed fleet's one entanglement: Caddy owns the ACME
//! account, so the arena reads the PEM files out of Caddy's own store. The
//! paths are glob patterns because the store nests them under the issuer's
//! directory name, which is Caddy's choice of the week and not something a
//! compose file should hard-code. They are also re-read on a timer: Let's
//! Encrypt certificates rotate every two months, a QUIC handshake uses the
//! certificate loaded at the time, and a fleet that had to be restarted to
//! notice a renewal would fail exactly as silently as the renewal succeeded.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tokio::sync::{mpsc, Mutex, Semaphore};
use tokio_tungstenite::tungstenite::Message;
use wtransport::endpoint::endpoint_side;
use wtransport::endpoint::IncomingSession;
use wtransport::{Connection, Endpoint, Identity, RecvStream, SendStream, ServerConfig, VarInt};

use crate::{serve_client, ArenaServer, C2S_MAX, INBOUND_QUEUE, OUT_QUEUE, S2C_SNAPSHOT};

/// How often the certificate files are re-read. Renewal happens weeks before
/// expiry, so anything under a day is prompt; ten minutes keeps a manual
/// re-issue from feeling ignored.
const CERT_RECHECK: Duration = Duration::from_secs(600);

/// How long a fresh session gets to open its reliable stream. A real client
/// does it immediately after the handshake; a port scanner never does, and
/// this is what stops each of those pinning a task open.
const HELLO: Duration = Duration::from_secs(5);

/// The QUIC idle timeout, above the handler's own 75 s quiet limit so the
/// transport never hangs up on a client the game still considers alive.
const IDLE: Duration = Duration::from_secs(90);

/// Serve WebTransport on `listen` until the process ends. Spawned beside the
/// WebSocket listener when `wt_listen` is configured; never instead of it,
/// because UDP is blocked on enough networks that QUIC can only ever be the
/// preferred door, not the only one.
/// The live endpoint, kept where the shutdown path can reach it. A killed
/// process says nothing over QUIC: the kernel closes TCP sockets for the
/// dead, so WebSocket players get their hangup for free, but a WebTransport
/// session left unclosed is discovered by the browser's idle timer, tens of
/// seconds a player spends in a ghost room. Set once when the endpoint binds.
static LIVE: std::sync::OnceLock<Arc<Endpoint<endpoint_side::Server>>> = std::sync::OnceLock::new();

/// Close every WebTransport session, for the SIGTERM path. The close frame
/// leaves on the endpoint's own driver, so the bounded wait afterwards is
/// what gives it a moment to reach the wire before the process exits; a hang
/// here can only cost the moment, and the sessions it would miss are the ones
/// a kill was already going to lose.
pub async fn shutdown() {
    let Some(endpoint) = LIVE.get() else { return };
    endpoint.close(VarInt::from_u32(0), b"zone restarting");
    let _ = tokio::time::timeout(Duration::from_millis(250), endpoint.wait_idle()).await;
}

pub async fn run(listen: String, cert: String, key: String, zone: Arc<Mutex<ArenaServer>>) {
    let addr: std::net::SocketAddr = match listen.parse() {
        Ok(a) => a,
        Err(e) => {
            println!("wt_listen {listen:?} is not an address ({e}); not serving WebTransport");
            return;
        }
    };
    if cert.is_empty() || key.is_empty() {
        println!("wt_listen is set but wt_cert/wt_key are not; not serving WebTransport");
        return;
    }
    // On a fresh host the arenas come up before Caddy has talked to Let's
    // Encrypt, so the certificate this glob wants may not exist yet. Waiting
    // beats exiting: the WebSocket door is open throughout, and this one
    // opens by itself a few seconds after the certificate lands.
    let mut said = false;
    let (mut stamp, identity) = loop {
        match load_identity(&cert, &key).await {
            Some(found) => break found,
            None => {
                if !said {
                    println!("no certificate matches {cert:?} yet; webtransport waits for one");
                    said = true;
                }
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        }
    };
    let endpoint = match Endpoint::server(config(addr, identity)) {
        Ok(e) => Arc::new(e),
        Err(e) => {
            println!("webtransport cannot bind {addr}: {e}");
            return;
        }
    };
    println!("vectorwake arena server listening on https://{addr} (webtransport)");
    let _ = LIVE.set(endpoint.clone());
    // Said in a number as well as in a line of log, because the log is on a
    // host nobody is reading and this is on a page anybody can. Until the
    // endpoint binds, this stays zero: an arena that never found its
    // certificate serves WebSockets and looks entirely healthy.
    crate::metrics::WT_LISTENING.set(1);

    {
        let endpoint = endpoint.clone();
        let (cert, key) = (cert.clone(), key.clone());
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(CERT_RECHECK).await;
                let Some((fresh, identity)) = load_identity(&cert, &key).await else {
                    // The store went away underneath us. The loaded identity
                    // keeps serving until it expires, which is also the most
                    // useful thing to do while somebody restores the volume.
                    continue;
                };
                if fresh == stamp {
                    continue;
                }
                // New connections handshake with the new certificate; live
                // ones keep the session they already proved. `rebind` stays
                // false so the socket, and every connection on it, survives.
                match endpoint.reload_config(config(addr, identity), false) {
                    Ok(()) => {
                        println!("webtransport certificate reloaded from {:?}", fresh.0);
                        stamp = fresh;
                    }
                    Err(e) => println!("webtransport certificate reload failed: {e}"),
                }
            }
        });
    }

    serve(endpoint, zone).await;
}

/// Accept sessions forever. Split from `run` so a test can hand in an endpoint
/// with a self-signed identity and an ephemeral port.
async fn serve(endpoint: Arc<Endpoint<endpoint_side::Server>>, zone: Arc<Mutex<ArenaServer>>) {
    loop {
        let incoming = endpoint.accept().await;
        // Counted here, which is as early as it can be: this yields when a
        // QUIC connection attempt arrives, before any handshake. It is the
        // only evidence that a client's packets reach this process, and a
        // fallback on the client cannot tell that apart from a refusal.
        crate::metrics::WT_ATTEMPTS.inc();
        let zone = zone.clone();
        tokio::spawn(session(incoming, zone));
    }
}

/// What one session may hold of this process, in QUIC's own currency.
///
/// The WebSocket door caps a frame at `C2S_MAX` and says why: a stranger on
/// an open port gets to cost kilobytes, not gigabytes. This door was opened
/// without the equivalent, and QUIC's defaults are generous in a way a
/// WebSocket's are not. A hundred streams at a 1.25 MB window each, with no
/// connection-wide ceiling at all, is a quarter of a gigabyte per handshake
/// from a peer that opens streams and never reads them: the arena accepts one
/// bidirectional stream and no unidirectional ones, so anything else a client
/// opens sits buffered and unread until the connection ends.
///
/// `RECEIVE_WINDOW` is the one that actually bounds it, because it covers the
/// connection rather than a stream, and no count of streams can climb past
/// it. The rest are defense in depth. Datagrams are not flow controlled by
/// any of these, so inputs and snapshots are unaffected.
///
/// The stream counts cannot go to one and nought, tempting as that is: this
/// is HTTP/3 underneath, and a client legitimately opens a control stream and
/// two QPACK streams before it can ask for anything, plus the CONNECT stream
/// the session itself rides. These numbers leave room for those and for the
/// arena's one reliable lane.
const MAX_BIDI: u32 = 4;
const MAX_UNI: u32 = 8;
/// Per stream, against a join that is under eight kilobytes.
const STREAM_WINDOW: u32 = 64 * 1024;
/// And across all of them at once.
const RECEIVE_WINDOW: u32 = 512 * 1024;

fn config(addr: std::net::SocketAddr, identity: Identity) -> ServerConfig {
    use wtransport::quinn::VarInt;
    let mut transport = wtransport::quinn::TransportConfig::default();
    transport
        .max_concurrent_bidi_streams(VarInt::from_u32(MAX_BIDI))
        .max_concurrent_uni_streams(VarInt::from_u32(MAX_UNI))
        .stream_receive_window(VarInt::from_u32(STREAM_WINDOW))
        .receive_window(VarInt::from_u32(RECEIVE_WINDOW));
    ServerConfig::builder()
        .with_bind_address(addr)
        .with_custom_tls_and_transport(
            wtransport::tls::server::build_default_tls_config(identity),
            transport,
        )
        .max_idle_timeout(Some(IDLE))
        .expect("a constant idle timeout converts")
        .keep_alive_interval(Some(Duration::from_secs(15)))
        .build()
}

/// The newest file matching a glob pattern, by modification time. A pattern
/// with no wildcard is just a path that matches itself.
fn newest(pattern: &str) -> Vec<(PathBuf, SystemTime)> {
    let mut found: Vec<(PathBuf, SystemTime)> = glob::glob(pattern)
        .map(|paths| {
            paths
                .filter_map(|p| p.ok())
                .filter_map(|p| {
                    let t = std::fs::metadata(&p).and_then(|m| m.modified()).ok()?;
                    Some((p, t))
                })
                .collect()
        })
        .unwrap_or_default();
    found.sort_by(|a, b| b.1.cmp(&a.1));
    found
}

/// What identifies a loaded certificate for the reload check: both paths and
/// the newer of the two modification times.
type CertStamp = (PathBuf, PathBuf, SystemTime);

/// Load the newest certificate and its key. The key is taken from the same
/// directory as the chosen certificate when the pattern offers a choice,
/// because Caddy keeps a `.crt` and `.key` side by side per issuer and pairing
/// newest-with-newest across issuers would marry a certificate to somebody
/// else's key.
async fn load_identity(cert_pat: &str, key_pat: &str) -> Option<(CertStamp, Identity)> {
    let certs = newest(cert_pat);
    let (cert, cert_t) = certs.first()?.clone();
    let keys = newest(key_pat);
    let (key, key_t) = keys
        .iter()
        .find(|(p, _)| p.parent() == cert.parent())
        .or_else(|| keys.first())?
        .clone();
    match Identity::load_pemfiles(&cert, &key).await {
        Ok(identity) => Some(((cert, key, cert_t.max(key_t)), identity)),
        Err(e) => {
            println!("webtransport certificate {cert:?}: {e}");
            None
        }
    }
}

/// One session, from handshake to cleanup. The mirror of the WebSocket accept
/// task: readers feed bytes to `serve_client`, a writer carries its replies,
/// and when the handler returns the transport is torn down around it.
async fn session(incoming: IncomingSession, zone: Arc<Mutex<ArenaServer>>) {
    let Ok(request) = incoming.await else { return };
    // Any path on this authority is this arena; the address a client dials
    // already picked the process, the same way the WebSocket port does.
    let Ok(conn) = request.accept().await else {
        return;
    };
    // Counted here rather than at the handshake: a session is a client that
    // got through, which is the number worth having against the sockets.
    crate::metrics::WT_SESSIONS.inc();
    let Ok(Ok((reliable_tx, reliable_rx))) = tokio::time::timeout(HELLO, conn.accept_bi()).await
    else {
        conn.close(VarInt::from_u32(0), b"open a stream first");
        return;
    };

    let (tx, rx) = mpsc::channel::<Message>(OUT_QUEUE);
    let (in_tx, inbound) = mpsc::channel::<Vec<u8>>(INBOUND_QUEUE);
    let writer = tokio::spawn(write_loop(conn.clone(), reliable_tx, rx));
    let framed = tokio::spawn(read_framed(conn.clone(), reliable_rx, in_tx.clone()));
    let dgrams = {
        let conn = conn.clone();
        tokio::spawn(async move {
            loop {
                match conn.receive_datagram().await {
                    Ok(d) => {
                        if in_tx.send(d.to_vec()).await.is_err() {
                            return;
                        }
                    }
                    Err(_) => return,
                }
            }
        })
    };

    serve_client(zone, inbound, tx.clone(), "wt").await;

    framed.abort();
    dgrams.abort();
    // Let the writer drain before the session closes: a refusal is enqueued
    // and the handler returns immediately, and closing under it would eat the
    // very byte that tells the client whether to try another instance.
    drop(tx);
    let mut writer = writer;
    if tokio::time::timeout(Duration::from_secs(2), &mut writer)
        .await
        .is_err()
    {
        writer.abort();
    }
    conn.close(VarInt::from_u32(0), b"");
}

/// How many oversized snapshots may be on their way at once.
///
/// Opening a stream needs the peer's permission, and the peer decides how
/// freely to give it, so anything awaited here is a client's to stall and
/// anything spawned here is a client's to accumulate. Two in the air is
/// enough that a snapshot never waits on its predecessor, and a third means
/// the first two are stuck, in which case the newest is worth more than a
/// queue. Combat state is superseded 20 ms later, which is the same reason the
/// out queue drops rather than blocks.
///
/// The permit ends once the bytes and FIN are in QUIC. `SendStream::finish`
/// waits until the peer acknowledges every byte, so awaiting it here makes
/// this limit a function of RTT. Two acknowledgement waits cannot carry a
/// 50 Hz lane on an ordinary Internet connection.
const UNI_INFLIGHT: usize = 2;

/// Everything the arena says, sorted onto the lane it belongs on.
async fn write_loop(conn: Connection, mut reliable: SendStream, mut rx: mpsc::Receiver<Message>) {
    let uni = Arc::new(Semaphore::new(UNI_INFLIGHT));
    while let Some(msg) = rx.recv().await {
        let Message::Binary(b) = msg else { continue };
        if b.first() == Some(&S2C_SNAPSHOT) {
            // Fresh state: superseded in 20 ms on the combat lane, so the
            // transport never waits to enqueue it. A datagram carries it when
            // it fits under the path's MTU; its own stream carries it when it
            // does not, which still leaves every other snapshot free to pass.
            if conn.max_datagram_size().is_some_and(|m| b.len() <= m) {
                if conn.send_datagram(&b).is_err() {
                    crate::metrics::SEND_DROPPED.inc();
                }
            } else {
                // Opening the stream belongs to the spawned task, not to this
                // loop. Awaited here it was the reliable lane's problem: a
                // client that stops granting stream credit parks the loop on
                // the snapshot, the out queue fills a couple of seconds
                // later, and every roster, kill and refusal after that is
                // dropped by a queue with nowhere to put it, on a stream that
                // was writable the whole time.
                let Ok(permit) = uni.clone().try_acquire_owned() else {
                    crate::metrics::SEND_DROPPED.inc();
                    continue;
                };
                let conn = conn.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let Ok(opening) = conn.open_uni().await else {
                        crate::metrics::SEND_DROPPED.inc();
                        return;
                    };
                    let Ok(mut s) = opening.await else {
                        crate::metrics::SEND_DROPPED.inc();
                        return;
                    };
                    if s.write_all(&b).await.is_err() || s.quic_stream_mut().finish().is_err() {
                        crate::metrics::SEND_DROPPED.inc();
                    }
                });
            }
        } else if write_frame(&mut reliable, &b).await.is_err() {
            return;
        }
    }
    let _ = reliable.finish().await;
}

async fn write_frame(s: &mut SendStream, b: &[u8]) -> Result<(), ()> {
    let len = (b.len() as u32).to_le_bytes();
    s.write_all(&len).await.map_err(|_| ())?;
    s.write_all(b).await.map_err(|_| ())
}

/// The reliable stream, u32-framed, capped at the same size the WebSocket
/// gives a frame: nothing a client legitimately says is bigger than a join,
/// and a stranger on an open port gets to cost kilobytes, not gigabytes.
///
/// The session goes when this lane does. It has two readers and they do not
/// speak for each other: the datagram loop holds the other half of the
/// inbound channel, so a reliable stream that ended left the handler running
/// on inputs alone, and a client whose asks all vanished kept its seat and
/// its flying. A watcher fared worse, since the ask is its whole proof of
/// life: it went on sending keepalives up a stream nobody read and was
/// dropped for silence a minute later. On the WebSocket the same bad frame
/// is a read error that ends the connection, and that is the behavior to
/// match, so closing here is the honest equivalent.
async fn read_framed(conn: Connection, s: RecvStream, tx: mpsc::Sender<Vec<u8>>) {
    read_frames(s, tx).await;
    conn.close(VarInt::from_u32(0), b"reliable stream ended");
}

async fn read_frames(mut s: RecvStream, tx: mpsc::Sender<Vec<u8>>) {
    while let Some(buf) = read_frame(&mut s, C2S_MAX).await {
        if tx.send(buf).await.is_err() {
            return;
        }
    }
}

/// One u32-framed message, or nothing when the lane is over or has said
/// something no message of that size can be. The cap is an argument because
/// the two directions do not share one: a client's largest word is a join and
/// a zone's is a map, three orders of magnitude apart.
async fn read_frame(s: &mut RecvStream, cap: usize) -> Option<Vec<u8>> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len).await.ok()?;
    let n = u32::from_le_bytes(len) as usize;
    if n == 0 || n > cap {
        return None;
    }
    let mut buf = vec![0u8; n];
    s.read_exact(&mut buf).await.ok()?;
    Some(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole door, exercised the way a browser will use it: handshake,
    /// open the reliable stream, join, watch the welcome arrive framed and the
    /// snapshots arrive out of band, then land an input as a datagram and see
    /// the arena acknowledge its tick. This is the one test that proves the
    /// lanes carry the same protocol the WebSocket does, so a failure here is
    /// a client that joins and then flies blind.
    /// An arena on the built-in room behind a real door, ticked by hand at
    /// full speed with a snapshot every fifth tick, which is the shipping
    /// cadence. Returns the port it answers on.
    async fn arena_door() -> u16 {
        let (cfg, _) = crate::config::ConfigWatcher::load("/nonexistent/zone.toml");
        let zone = Arc::new(Mutex::new(crate::ArenaServer::new(
            cfg,
            crate::spool::Spools::open("/nonexistent"),
            std::collections::HashMap::new(),
        )));
        // Standalone, like a laptop: a process under a directory holds no room
        // until it is told which zone it is, and there is no directory here.
        zone.lock().await.serve_local();
        {
            let zone = zone.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; crate::sim::PACK_MAX];
                let mut n = 0u32;
                loop {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                    let mut z = zone.lock().await;
                    n += 1;
                    for a in z.rooms.iter_mut() {
                        a.tick();
                        if n % 5 == 0 {
                            a.broadcast_snapshot(&mut buf);
                        }
                    }
                }
            });
        }

        let identity = Identity::self_signed(["localhost"]).expect("a self-signed identity");
        let endpoint = Arc::new(
            Endpoint::server(config("127.0.0.1:0".parse().unwrap(), identity))
                .expect("an ephemeral endpoint binds"),
        );
        let port = endpoint.local_addr().unwrap().port();
        tokio::spawn(serve(endpoint, zone));
        port
    }

    /// A dialled session. No certificate validation, because the door's
    /// identity is self-signed and these tests are about the lanes, not the
    /// CA.
    async fn dial(port: u16) -> Connection {
        let client = Endpoint::client(
            wtransport::ClientConfig::builder()
                // v4 explicitly: the default is a dual-stack v6 socket, and CI
                // runners without v6 fail the bind before anything is tested.
                .with_bind_address("0.0.0.0:0".parse().unwrap())
                .with_no_cert_validation()
                .build(),
        )
        .expect("a client endpoint");
        tokio::time::timeout(
            Duration::from_secs(5),
            client.connect(format!("https://127.0.0.1:{port}")),
        )
        .await
        .expect("the handshake is not hanging")
        .expect("the handshake succeeds")
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_client_joins_and_flies_over_webtransport() {
        let port = arena_door().await;
        // What the fleet is asked later, so it is worth knowing the question
        // reaches this code at all: nothing else can tell a door nobody uses
        // from a door that was never opened.
        let sessions_before = crate::metrics::WT_SESSIONS.get();
        let conn = dial(port).await;

        let (mut reliable_tx, mut reliable_rx) = conn
            .open_bi()
            .await
            .expect("a stream opens")
            .await
            .expect("the server accepts it");
        let name = b"probe";
        let mut join = vec![
            crate::C2S_JOIN,
            0,
            crate::CLIENT_PROTOCOL,
            0,
            0,
            name.len() as u8,
        ];
        join.extend_from_slice(name);
        write_frame(&mut reliable_tx, &join)
            .await
            .expect("the join sends");

        // Everything reliable rides the stream, and the welcome closes the
        // door sequence: map and settings must already have passed by then,
        // because the client cannot predict a single tick without them.
        let mut seen = Vec::new();
        let welcome = loop {
            let msg = tokio::time::timeout(Duration::from_secs(5), read_one(&mut reliable_rx))
                .await
                .expect("the join is answered")
                .expect("the stream stays open");
            seen.push(msg[0]);
            if msg[0] == crate::S2C_WELCOME {
                break msg;
            }
        };
        assert!(
            seen.contains(&crate::S2C_MAP),
            "no map before the welcome: {seen:?}"
        );
        assert!(
            seen.contains(&crate::S2C_SETTINGS),
            "no settings before the welcome: {seen:?}"
        );
        let ship = welcome[1];
        assert_ne!(ship, 255, "a plain join seats a pilot, not a watcher");

        // Snapshots arrive beside the stream, not on it: a datagram when one
        // fits, a stream of their own when not. Take either.
        let snap = tokio::time::timeout(Duration::from_secs(5), next_snapshot(&conn))
            .await
            .expect("a snapshot arrives out of band");
        assert_eq!(snap[0], crate::S2C_SNAPSHOT);
        assert_eq!(snap[1], ship, "the snapshot names the ship the welcome did");
        // The pack body opens with the simulation tick, which is the clock an
        // input has to name. The welcome's tick is stale by now, and a tick
        // past `now + INPUT_LEAD_MAX` is clamped before it is echoed, so a
        // made-up lead would chase its own clamp here and never match.
        let tick = u32::from_le_bytes(
            snap[crate::SNAPSHOT_HEADER..crate::SNAPSHOT_HEADER + 4]
                .try_into()
                .expect("snapshot tick"),
        );

        // An input as a datagram: buttons and the tick they belong to. The
        // arena records the newest input tick it has heard and repeats it in
        // every snapshot header, which is the acknowledgement the client
        // steers its clock by. Seeing it come back is seeing the datagram
        // lane work end to end.
        let named = tick + 20;
        let input = crate::input_message(0, 0, &[(named, 1)]);
        conn.send_datagram(&input).expect("the input sends");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the input's tick never came back acknowledged"
            );
            let snap = tokio::time::timeout(Duration::from_secs(5), next_snapshot(&conn))
                .await
                .expect("snapshots keep arriving");
            let acked = u32::from_le_bytes([snap[2], snap[3], snap[4], snap[5]]);
            if acked == named {
                break;
            }
        }

        assert!(
            crate::metrics::WT_SESSIONS.get() > sessions_before,
            "the session went uncounted, so the fleet cannot report this door"
        );
    }

    /// One reliable message off the framed stream.
    async fn read_one(s: &mut RecvStream) -> Option<Vec<u8>> {
        // The zone's own frames, so the cap is the zone's largest word rather
        // than a client's: a map is a megabyte and a half.
        read_frame(s, crate::sim::MAP_PACK_MAX + 1).await
    }

    /// The next snapshot, whichever lane carried it.
    async fn next_snapshot(conn: &Connection) -> Vec<u8> {
        loop {
            tokio::select! {
                d = conn.receive_datagram() => {
                    let d = d.expect("the connection is up");
                    if d.first() == Some(&crate::S2C_SNAPSHOT) {
                        return d.to_vec();
                    }
                }
                s = conn.accept_uni() => {
                    let mut s = s.expect("the connection is up");
                    let mut msg = Vec::new();
                    let mut chunk = [0u8; 2048];
                    while let Ok(Some(n)) = s.read(&mut chunk).await {
                        msg.extend_from_slice(&chunk[..n]);
                    }
                    if msg.first() == Some(&crate::S2C_SNAPSHOT) {
                        return msg;
                    }
                }
            }
        }
    }

    /// A frame no client legitimately sends ends the session, rather than
    /// only the lane that carried it.
    ///
    /// The reliable stream and the datagram loop each hold half of the
    /// inbound channel, so a reader that gave up used to leave the other one
    /// feeding a handler that still had a seat: every ask the client made
    /// afterwards went nowhere, and a watcher, whose keepalive is an ask, was
    /// dropped for silence a minute later while it was still writing. The
    /// WebSocket ends the connection on the same frame.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_oversized_frame_ends_the_session() {
        let port = arena_door().await;
        let conn = dial(port).await;
        let (mut tx, _rx) = conn
            .open_bi()
            .await
            .expect("a stream opens")
            .await
            .expect("the server accepts it");

        // A length word past the cap, and enough bytes that nothing is
        // waiting on the rest of a frame it will never read.
        let mut over = ((C2S_MAX + 1) as u32).to_le_bytes().to_vec();
        over.extend_from_slice(&[0u8; 64]);
        let _ = tx.write_all(&over).await;

        // The session goes, rather than the client keeping a live connection
        // whose every word is now ignored.
        tokio::time::timeout(Duration::from_secs(5), conn.closed())
            .await
            .expect("the door hangs up on a frame it refuses");
    }
}
