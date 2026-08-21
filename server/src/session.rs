use std::sync::Arc;

use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

use crate::arena::{sanitize_name, ArenaServer, RatedLease, StandingCheck};
use crate::presence::*;
use crate::protocol::*;
use crate::room::{file_event, Seat};
use crate::{fleet, metrics, pilot, token};

/// A connection that sends nothing is gone. Watchers heartbeat every thirty
/// seconds, so this leaves one half-interval of scheduling slack.
pub(crate) const SESSION_QUIET: std::time::Duration = std::time::Duration::from_secs(45);

/// One client from join to cleanup, fed by whichever transport carried it.
///
/// `inbound` is complete messages, first byte the tag, however they travelled:
/// WebSocket frames, WebTransport stream frames, or datagrams. `tx` is the
/// bounded out-queue a transport writer on the other end drains. Every enqueue
/// is a `try_send` whose failure is discarded, which is right for a snapshot
/// and is why anything that must arrive and is not on a clock repeats on one
/// (see networking.md).
pub(crate) async fn serve_client(
    zone: Arc<Mutex<ArenaServer>>,
    mut inbound: mpsc::Receiver<Vec<u8>>,
    tx: mpsc::Sender<Message>,
    transport: &'static str,
) {
    // Held for the life of the connection, however this function leaves.
    let _conn = metrics::ConnGuard::new();
    // This connection's name in the pilot log, minted before anything can be
    // refused so that a pilot who never gets through the door still has their
    // attempts tied together. Nothing is written until something happens: a
    // socket that opens and says nothing leaves no trace, which is what keeps
    // a port scan from being a write amplifier.
    let session = pilot::Session::new(transport);
    // Shared with the room entries this connection creates. Forced spectating
    // happens in the room tick, so the socket must observe the same state
    // instead of keeping its own seat and watcher flags.
    let (presence, mut presence_events) = PresenceHandle::connected();
    let mut rated_lease: Option<RatedLease> = None;
    let mut standing_check: Option<StandingCheck> = None;
    let mut credential_expires: Option<u64> = None;
    // Whether this pilot holds the `watch` capability, decided once at
    // the door where the token was checked, because the ask arrives
    // later on a message that carries no identity.
    let mut watch_any = false;
    // A connection that says nothing for this long is gone. A joined
    // client sends its buttons every frame whatever the player is doing,
    // even sitting in the menu, so silence is not idleness. Without this
    // a peer whose network vanished without an RST keeps its seat until
    // the kernel gives up on the socket, which on a full arena is a seat
    // nobody can have.
    'connection: loop {
        // A watcher does not renew a rated lease, so its original token is the
        // last standing check this socket has made. Rated pilots are checked by
        // the lease below and may keep playing through a token refresh without
        // being thrown out of their ship every fifteen minutes.
        let wait = if rated_lease.is_none() {
            match credential_expires {
                Some(at) if at <= token::now_secs() => {
                    let mut m = vec![S2C_DENIED, DENY_BANNED];
                    m.extend_from_slice(b"your session expired; log in again");
                    let _ = tx.try_send(Message::Binary(m));
                    break;
                }
                Some(at) => SESSION_QUIET.min(std::time::Duration::from_secs(
                    at.saturating_sub(token::now_secs()),
                )),
                None => SESSION_QUIET,
            }
        } else {
            SESSION_QUIET
        };
        let received = tokio::select! {
            biased;
            event = presence_events.recv() => {
                let Some(event) = event else {
                    break;
                };
                if event.release_rated_lease {
                    if let Some(lease) = rated_lease.take() {
                        lease.release().await;
                    }
                }
                if event.connection_closed {
                    break 'connection;
                }
                continue;
            }
            received = tokio::time::timeout(wait, inbound.recv()) => received,
        };
        let data = match received {
            Ok(Some(d)) => d,
            Ok(None) => break,
            Err(_) => break,
        };
        if data.is_empty() {
            // Empty client messages carry no protocol word. Transports also
            // use this sentinel when their write half fails, so either case
            // ends the session and runs the ordinary room cleanup.
            break;
        }
        // A forced move to the stands changes the shared presence during the
        // room tick. Give its rated seat back before considering a renewal or
        // dispatching the watcher's next message.
        if matches!(presence.current(), Presence::Watching { .. }) {
            if let Some(lease) = rated_lease.take() {
                lease.release().await;
            }
        }
        if rated_lease
            .as_ref()
            .is_some_and(|lease| lease.touched.elapsed() >= std::time::Duration::from_secs(30))
        {
            let renewed = rated_lease.as_mut().unwrap().renew().await;
            match renewed {
                Ok(true) => {}
                Ok(false) => {
                    let mut m = vec![S2C_DENIED, DENY_RATED_SESSION];
                    m.extend_from_slice(b"this account is active in another rated session");
                    let _ = tx.try_send(Message::Binary(m));
                    break;
                }
                Err(e) if e == "banned" => {
                    let mut m = vec![S2C_DENIED, DENY_BANNED];
                    m.extend_from_slice(b"this account is banned");
                    let _ = tx.try_send(Message::Binary(m));
                    break;
                }
                Err(e) => {
                    // Keep the live socket during a short meta outage. The
                    // three-minute lease and thirty-second retry leave five
                    // more chances before another arena can take the row.
                    println!("rated session renewal failed: {e}");
                }
            }
        }
        if rated_lease.is_none()
            && standing_check
                .as_ref()
                .is_some_and(|check| check.touched.elapsed() >= std::time::Duration::from_secs(30))
        {
            let checked = standing_check.as_mut().unwrap().renew().await;
            match checked {
                Ok(()) => {}
                Err(error) if error == "banned" || error == "no such account" => {
                    let mut message = vec![S2C_DENIED, DENY_BANNED];
                    message.extend_from_slice(b"this account is banned");
                    let _ = tx.try_send(Message::Binary(message));
                    break;
                }
                Err(error) => println!("account standing check failed: {error}"),
            }
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
            C2S_JOIN if presence.current() == Presence::Unjoined => {
                let class = data.get(1).copied().unwrap_or(0);
                let proto = data.get(2).copied().unwrap_or(0);
                let flags = data.get(3).copied().unwrap_or(0);
                let is_bot = flags & JOIN_BOT != 0;
                let zlen = data.get(4).copied().unwrap_or(0) as usize;
                let nlen = data.get(5).copied().unwrap_or(0) as usize;
                // Which room, or zero for "whichever the ladder picks", which
                // is what every arrival that has not been shown a list says.
                let want_room = data.get(6).copied().unwrap_or(0) as u32;
                let h = C2S_JOIN_HEADER;
                let want =
                    String::from_utf8_lossy(data.get(h..h + zlen).unwrap_or_default()).to_string();
                let claimed_name = sanitize_name(&String::from_utf8_lossy(
                    data.get(h + zlen..h + zlen + nlen).unwrap_or_default(),
                ));
                let presented =
                    String::from_utf8_lossy(data.get(h + zlen + nlen..).unwrap_or_default())
                        .to_string();
                let mut z = zone.lock().await;

                // A refusal has to say which of six things went wrong,
                // because three mean "try another instance" and three mean
                // "stop trying". The code is the first byte after the tag.
                //
                // It is also the one thing that happens to a pilot which
                // leaves no other trace anywhere: the connection closes and
                // the only party that knows why is the one being refused. So
                // the same closure that builds the message files the row.
                //
                // `who` is the seat where the door has got far enough to have
                // one. Three of these refusals happen before any token is
                // read and cannot name an account; the rest can, and it
                // matters that they do. A refusal is the event an operator is
                // most often asked about, and one filed against nobody is one
                // that never appears in the pilot it happened to.
                let pilots = z.spools.pilots.clone();
                let deny = |code: u8, why: &str, who: Option<&Seat>| {
                    // A bot bouncing off a full instance is the fill loop
                    // working, not an event. It is also the only refusal that
                    // happens by the thousand, so leaving it out is most of
                    // what keeps this log about people.
                    let routine = is_bot && code == DENY_FULL;
                    if !routine && pilot::refusal_budget(fleet::now_ms()) {
                        file_event(
                            &pilots,
                            &session,
                            pilot::DENIED,
                            who,
                            None,
                            0,
                            // `claimed` is what the client typed, kept even
                            // where a seat vouched for a name, because the
                            // two disagreeing is worth seeing. Where there is
                            // no seat it is the only handle the row has, and
                            // it is recorded as an assertion rather than as
                            // identity.
                            serde_json::json!({
                                "code": code,
                                "why": why,
                                "claimed": claimed_name,
                                "zone": want,
                                "protocol": proto,
                                "transport": transport,
                                "bot": is_bot,
                            }),
                        );
                    }
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
                        None,
                    )));
                    break;
                }
                // Nothing to join. An instance waiting for a directory to name
                // its zone holds no room, and it is answered before the check
                // below rather than by it: that one would report the zone this
                // instance serves instead, which is the empty string, and a
                // player would read `this instance serves "" now`.
                if z.rooms.is_empty() {
                    let _ = tx.try_send(Message::Binary(deny(DENY_WRONG_ZONE, NO_ZONE_YET, None)));
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
                        &format!("this instance serves {:?} now; re-browse", z.zone_name),
                        None,
                    )));
                    break;
                }
                // Who this is. A signature and a clock, checked here,
                // against a key that arrived with the catalog: no
                // call to the meta-layer, which is what lets it be
                // down without shutting the door.
                let mut seat_of = match z.identify(&presented, &claimed_name, is_bot, &session) {
                    Ok(s) => s,
                    Err(why) => {
                        let _ = tx.try_send(Message::Binary(deny(DENY_BANNED, &why, None)));
                        break;
                    }
                };
                let presented_expires = seat_of.expires;
                if let Some(account) = seat_of.account {
                    if let Ok((base, pool_token, _)) = z.rated_lease_args() {
                        standing_check = Some(StandingCheck {
                            base,
                            pool_token,
                            account,
                            touched: std::time::Instant::now(),
                        });
                    }
                }
                // A zone that wants a field it can vouch for. The
                // default is `any`, because turning a newcomer away in
                // the second they arrived is the cost of caring and
                // most rooms should not pay it.
                if z.wants_claimed() && seat_of.label == token::Label::Unknown.to_byte() {
                    let _ = tx.try_send(Message::Binary(deny(
                        DENY_BANNED,
                        "this zone is for claimed pilots; keep your pilot in the menu first",
                        Some(&seat_of),
                    )));
                    break;
                }
                let name = seat_of.name.clone();
                // A per-zone ban, checked against the name the token
                // carries. The fleet ban never reaches this door: the
                // meta-layer refuses a banned account its token, so a
                // banned pilot arrives holding nothing.
                if z.is_banned(&name) {
                    let _ = tx.try_send(Message::Binary(deny(
                        DENY_BANNED,
                        "you are banned here",
                        Some(&seat_of),
                    )));
                    break;
                }
                if z.draining {
                    let _ = tx.try_send(Message::Binary(deny(
                        DENY_DRAINING,
                        "this arena is draining; try another instance",
                        Some(&seat_of),
                    )));
                    break;
                }
                if flags & JOIN_WATCH == 0 {
                    if let Some(account) = seat_of.account {
                        let (base, pool_token, instance) = match z.rated_lease_args() {
                            Ok(v) => v,
                            Err(e) => {
                                let _ = tx.try_send(Message::Binary(deny(
                                    DENY_RATED_SESSION,
                                    &format!("cannot open a rated session: {e}"),
                                    Some(&seat_of),
                                )));
                                break;
                            }
                        };
                        let rated_spool = z.spools.rated.clone();
                        drop(z);
                        let claimed = RatedLease::claim(
                            base,
                            pool_token,
                            instance,
                            account,
                            session.id.clone(),
                            rated_spool,
                        )
                        .await;
                        let lease = match claimed {
                            Ok(Some((lease, ratings))) => {
                                // The signed token is an admission credential,
                                // not a rating checkpoint. The lease response
                                // carries current standing so replaying an old
                                // token cannot seed another room from old data.
                                seat_of.carried = Some(ratings);
                                lease
                            }
                            Ok(None) => {
                                let _ = tx.try_send(Message::Binary(deny(
                                    DENY_RATED_SESSION,
                                    "this account is active in another rated session",
                                    Some(&seat_of),
                                )));
                                break;
                            }
                            Err(e) => {
                                let _ = tx.try_send(Message::Binary(deny(
                                    DENY_RATED_SESSION,
                                    &format!("cannot open a rated session: {e}"),
                                    Some(&seat_of),
                                )));
                                break;
                            }
                        };
                        z = zone.lock().await;
                        // The lock was released for the meta call. Selection
                        // may have changed this process in the meantime, so
                        // the door conditions that can move are checked again
                        // before the claim becomes a seat.
                        if z.rooms.is_empty() || (!want.is_empty() && want != z.zone_name) {
                            rated_lease = Some(lease);
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_WRONG_ZONE,
                                "this instance changed games while the rated seat was checked; re-browse",
                                Some(&seat_of),
                            )));
                            break;
                        }
                        if z.draining || z.is_banned(&name) {
                            rated_lease = Some(lease);
                            let _ = tx.try_send(Message::Binary(deny(
                                if z.draining {
                                    DENY_DRAINING
                                } else {
                                    DENY_BANNED
                                },
                                if z.draining {
                                    "this arena began draining while the rated seat was checked"
                                } else {
                                    "you are banned here"
                                },
                                Some(&seat_of),
                            )));
                            break;
                        }
                        rated_lease = Some(lease);
                    }
                }
                let _ = tx.try_send(Message::Binary(z.zone_msg()));
                watch_any = z.watch_any(&seat_of);
                // Arrived to watch. No seat, no side, no live follow:
                // the channel is the whole of what a stranger at the
                // door can see, and the staff capability is the
                // written-down exception. Checked before the bot flag
                // on purpose; a client claiming both came to watch.
                if flags & JOIN_WATCH != 0 {
                    // The fullest room: a watcher came to see people. An
                    // instance with no room refused this arrival above; the
                    // branch is here because an index into an empty list is a
                    // panic, and a door is the wrong place to keep one.
                    let Some(idx) = z.room_to_watch() else {
                        let _ = tx.try_send(Message::Binary(deny(
                            DENY_WRONG_ZONE,
                            NO_ZONE_YET,
                            Some(&seat_of),
                        )));
                        break;
                    };
                    // Kept back for the refusal below, which needs to name
                    // whoever it turned away and cannot, once the seat has
                    // gone into the room.
                    let refused = seat_of.clone();
                    let joined = z.rooms[idx].watch_join_with_presence(
                        seat_of,
                        watch_any,
                        tx.clone(),
                        presence.clone(),
                    );
                    match joined {
                        Some(_id) => {
                            credential_expires = presented_expires;
                            let a = &z.rooms[idx];
                            let mut m = vec![S2C_MAP];
                            m.extend_from_slice(&a.world.packed_map());
                            let _ = tx.try_send(Message::Binary(m));
                            let mut c = vec![S2C_SETTINGS];
                            c.extend_from_slice(&a.settings_generation.to_le_bytes());
                            c.extend_from_slice(&a.world.packed_settings());
                            let _ = tx.try_send(Message::Binary(c));
                            // The clock, so somebody arriving ninety seconds
                            // into a match knows they arrived ninety seconds
                            // into a match.
                            if let Some(m) = a.match_msg() {
                                let _ = tx.try_send(Message::Binary(m));
                            }
                            // 255 is a watcher's ship: the client
                            // learns which of its two lives this is
                            // from the welcome.
                            let mut w = vec![S2C_WELCOME, 255];
                            w.extend_from_slice(&1u32.to_le_bytes());
                            w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                            w.extend_from_slice(&(a.number as u16).to_le_bytes());
                            w.extend_from_slice(&a.settings_generation.to_le_bytes());
                            let _ = tx.try_send(Message::Binary(w));
                            a.broadcast_roster();
                        }
                        None => {
                            let _ = tx.try_send(Message::Binary(deny(
                                DENY_FULL,
                                "this room has all the watchers it wants",
                                Some(&refused),
                            )));
                        }
                    }
                    // No push_status: a watcher moves no count a
                    // directory reports.
                    continue;
                }
                let cap = z.max_players();
                // A bot goes where a bot is short, and nowhere when every
                // room has the population it asked for. It never opens a
                // room: rooms exist because people arrived.
                let room = if is_bot {
                    z.room_for_bot()
                } else {
                    z.room_wanted(want_room)
                };
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
                        Some(&seat_of),
                    )));
                    break;
                };
                // Into the room they are actually joining. Rooms keep their
                // own ladders, so putting a returning player's rating in
                // room zero would leave them unrated wherever they landed.
                z.restore_pilot(idx, &seat_of);
                // Same reason as the watcher path above: the seat goes into
                // the room, and the refusal that follows a failed seating
                // still has to say who it was for.
                let refused = seat_of.clone();
                let a = &mut z.rooms[idx];
                if let Some(new_id) =
                    a.join_with_presence(seat_of, class, cap, tx.clone(), presence.clone())
                {
                    credential_expires = presented_expires;
                    let ship = a.players[&new_id].ship;
                    let mut m = vec![S2C_MAP];
                    m.extend_from_slice(&a.world.packed_map());
                    let _ = tx.try_send(Message::Binary(m));
                    let mut c = vec![S2C_SETTINGS];
                    c.extend_from_slice(&a.settings_generation.to_le_bytes());
                    c.extend_from_slice(&a.world.packed_settings());
                    let _ = tx.try_send(Message::Binary(c));
                    if let Some(m) = a.match_msg() {
                        let _ = tx.try_send(Message::Binary(m));
                    }
                    let mut w = vec![S2C_WELCOME, ship];
                    w.extend_from_slice(&a.players[&new_id].lifecycle.to_le_bytes());
                    w.extend_from_slice(&a.world.state.tick.to_le_bytes());
                    // Which room this is. The client draws it in the corner and
                    // never draws what it asked for: a room can fill between a
                    // list being read and a key landing, and the one thing on
                    // screen that must not be a guess is where you are.
                    w.extend_from_slice(&(a.number as u16).to_le_bytes());
                    w.extend_from_slice(&a.settings_generation.to_le_bytes());
                    let _ = tx.try_send(Message::Binary(w));
                    a.broadcast_roster();
                    // Which sides this room holds, who is on them, and
                    // which of their doors are open to this arrival.
                    a.broadcast_teams();
                } else {
                    let _ = tx.try_send(Message::Binary(deny(
                        DENY_FULL,
                        "no seat in that room",
                        Some(&refused),
                    )));
                    break;
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
                //
                // From a watcher it is the other thing a hull ask can
                // mean: put me back in the game, in this one. Refused
                // by the caps if the room filled while they sat out,
                // and a refusal leaves them watching.
                if data.len() >= 2 {
                    let cls = data[1];
                    if matches!(presence.current(), Presence::Flying { .. }) {
                        let mut z = zone.lock().await;
                        let Presence::Flying { room, member } = presence.current() else {
                            continue;
                        };
                        if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                            let a = &mut z.rooms[index];
                            let ship = a.players.get(&member).map(|p| p.ship);
                            if let Some(ship) = ship {
                                let was = a.world.state.ships[ship as usize].cls;
                                a.world.set_ship_class(ship, cls);
                                // Read back, not echoed. The core refuses this
                                // for anyone dead or short of a full bar and
                                // says nothing about it, so the asking and the
                                // happening are different events and only one
                                // of them is worth a row.
                                let now = a.world.state.ships[ship as usize].cls;
                                if now != was {
                                    if let Some(s) = a.names.get(&ship).cloned() {
                                        a.note(
                                            pilot::SHIP,
                                            &s,
                                            serde_json::json!({ "from": was, "to": now }),
                                        );
                                    }
                                }
                            }
                        }
                    } else if matches!(presence.current(), Presence::Watching { .. }) {
                        let (carried, lease_args) = {
                            let z = zone.lock().await;
                            let current = presence.current();
                            let carried = match current {
                                Presence::Watching { room, member } => z
                                    .rooms
                                    .iter()
                                    .find(|a| a.number == room)
                                    .and_then(|a| a.watchers.get(&member))
                                    .map(|w| w.seat.clone()),
                                _ => None,
                            };
                            let args = if rated_lease.is_none() {
                                carried
                                    .as_ref()
                                    .filter(|s| s.account.is_some())
                                    .map(|_| {
                                        z.rated_lease_args().map(|(base, token, instance)| {
                                            (base, token, instance, z.spools.rated.clone())
                                        })
                                    })
                                    .transpose()
                            } else {
                                Ok(None)
                            };
                            (carried, args)
                        };
                        let mut candidate = None;
                        let mut standing = None;
                        if let Some((base, pool_token, instance, rated_spool)) = match lease_args {
                            Ok(v) => v,
                            Err(e) => {
                                let mut m = vec![S2C_DENIED, DENY_RATED_SESSION];
                                m.extend_from_slice(
                                    format!("cannot open a rated session: {e}").as_bytes(),
                                );
                                let _ = tx.try_send(Message::Binary(m));
                                continue;
                            }
                        } {
                            let account = carried.as_ref().and_then(|s| s.account).unwrap();
                            match RatedLease::claim(
                                base,
                                pool_token,
                                instance,
                                account,
                                session.id.clone(),
                                rated_spool,
                            )
                            .await
                            {
                                Ok(Some((lease, ratings))) => {
                                    candidate = Some(lease);
                                    standing = Some(ratings);
                                }
                                Ok(None) => {
                                    let mut m = vec![S2C_DENIED, DENY_RATED_SESSION];
                                    m.extend_from_slice(
                                        b"this account is active in another rated session",
                                    );
                                    let _ = tx.try_send(Message::Binary(m));
                                    continue;
                                }
                                Err(e) => {
                                    let mut m = vec![S2C_DENIED, DENY_RATED_SESSION];
                                    m.extend_from_slice(
                                        format!("cannot open a rated session: {e}").as_bytes(),
                                    );
                                    let _ = tx.try_send(Message::Binary(m));
                                    continue;
                                }
                            }
                        }
                        let mut z = zone.lock().await;
                        let cap = z.max_players();
                        let Presence::Watching { room, member } = presence.current() else {
                            drop(z);
                            if let Some(lease) = candidate {
                                lease.release().await;
                            }
                            continue;
                        };
                        let Some(index) = z.rooms.iter().position(|a| a.number == room) else {
                            drop(z);
                            if let Some(lease) = candidate {
                                lease.release().await;
                            }
                            continue;
                        };
                        // The rating they carried in comes back with
                        // them, exactly as it would at the door.
                        if let Some(s) = carried.as_ref() {
                            let mut current = s.clone();
                            if let Some(ratings) = standing {
                                current.carried = Some(ratings);
                            }
                            z.restore_pilot(index, &current);
                            if let Some(watcher) = z.rooms[index].watchers.get_mut(&member) {
                                watcher.seat.carried = current.carried;
                            }
                        }
                        let flew = z.rooms[index].fly(member, cls, cap).is_some();
                        if flew {
                            // A human entered the game count.
                            z.push_status();
                        }
                        drop(z);
                        if flew {
                            if candidate.is_some() {
                                rated_lease = candidate;
                            }
                        } else if let Some(lease) = candidate {
                            lease.release().await;
                        } else if let Some(lease) = rated_lease.take() {
                            // The only watcher that can arrive here still
                            // holding a lease was swept out of a safe zone and
                            // immediately asked to fly again. If the room has
                            // filled in the meantime, it stays in the stands
                            // and must stop excluding this account elsewhere.
                            lease.release().await;
                        }
                    }
                }
            }
            C2S_KIT => {
                // What this pilot wants to fly. Applied at once at a join and
                // between matches; held to the next whistle during one,
                // because a hull is locked for a match and the kit with it.
                //
                // Nothing is sent back, for the same reason a hull change
                // sends nothing: the next snapshot carries what was dealt, and
                // a refusal leaves the old kit, which is the same answer
                // either way.
                if data.len() >= 1 + crate::sim::SLOT_COUNT {
                    let mut kit = [0u8; crate::sim::SLOT_COUNT];
                    kit.copy_from_slice(&data[1..1 + crate::sim::SLOT_COUNT]);
                    if let Presence::Flying { room, member } = presence.current() {
                        let mut z = zone.lock().await;
                        if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                            let a = &mut z.rooms[index];
                            if let Some(ship) = a.players.get(&member).map(|p| p.ship) {
                                let playing = a.mode.match_state().is_some_and(|m| m.playing);
                                if playing {
                                    if let Some(s) = a.names.get_mut(&ship) {
                                        s.pending_kit = Some(kit);
                                    }
                                } else {
                                    a.set_kit(ship, &kit);
                                }
                            }
                        }
                    }
                }
            }
            C2S_WATCH => {
                // Whose eyes to borrow. From a player: sit out. From a
                // watcher: look somewhere else. Both are requests; the
                // subject byte of the next snapshot is the answer, and
                // an unlawful ask falls to the channel rather than
                // erroring. Also the watcher's keepalive: a client
                // with no inputs to send repeats its ask so the quiet
                // timeout knows the socket is alive.
                if data.len() >= 2 {
                    let want = data[1];
                    let mut z = zone.lock().await;
                    let mut release = false;
                    if let Some((room, member)) = presence.current().flying() {
                        if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                            if z.rooms[index].sit_out(member, want, watch_any, false) {
                                release = true;
                                // A human left the game count.
                                z.push_status();
                            }
                        }
                    } else if let Some((room, member)) = presence.current().watching() {
                        if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                            z.rooms[index].set_watch(member, want);
                        }
                    }
                    drop(z);
                    if release {
                        if let Some(lease) = rated_lease.take() {
                            lease.release().await;
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
                    if presence.current().flying().is_some() {
                        let want = data[1];
                        let mut z = zone.lock().await;
                        if let Some((room, member)) = presence.current().flying() {
                            if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                                let a = &mut z.rooms[index];
                                if let Some(ship) = a.players.get(&member).map(|p| p.ship) {
                                    a.join_team(ship, want);
                                }
                            }
                        }
                    }
                }
            }
            C2S_FOUND => {
                // A side of your own, if the room may hold another.
                if presence.current().flying().is_some() {
                    let mut z = zone.lock().await;
                    if let Some((room, member)) = presence.current().flying() {
                        if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                            let a = &mut z.rooms[index];
                            if let Some(ship) = a.players.get(&member).map(|p| p.ship) {
                                a.found_and_move(ship);
                            }
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
                    if presence.current().flying().is_some() {
                        let guest = data[1];
                        let mut z = zone.lock().await;
                        if let Some((room, member)) = presence.current().flying() {
                            if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                                let a = &mut z.rooms[index];
                                if let Some(ship) = a.players.get(&member).map(|p| p.ship) {
                                    a.invite(ship, guest);
                                }
                            }
                        }
                    }
                }
            }
            C2S_INPUT => {
                // Selective records repair the exact zeroes in the receipt
                // window. The snapshot receipt window beside them measures
                // the other direction on the arena's own clock.
                if let Some(packet) = input_packet(&data) {
                    if presence.current().flying().is_some() {
                        let mut z = zone.lock().await;
                        let Some((room, member)) = presence.current().flying() else {
                            continue;
                        };
                        let Some(index) = z.rooms.iter().position(|a| a.number == room) else {
                            continue;
                        };
                        let a = &mut z.rooms[index];
                        let now = a.world.state.tick.wrapping_add(1);
                        let sample_ticks = a.lag_policy.sample_ticks;
                        let Some(p) = a.players.get_mut(&member) else {
                            continue;
                        };
                        if packet.lifecycle != p.lifecycle {
                            continue;
                        }
                        p.last_input_at = now;
                        p.lag.acknowledge_snapshots(
                            packet.snapshot_ack,
                            packet.snapshot_mask,
                            now,
                            sample_ticks,
                        );
                        for (tick, buttons) in packet.records {
                            p.schedule(tick, buttons, now);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    let mut z = zone.lock().await;
    match presence.current() {
        Presence::Flying { room, member } => {
            if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                let a = &mut z.rooms[index];
                a.leave(member, pilot::why::LEFT);
                a.broadcast_roster();
            }
            // An empty room goes back, except the first: a process shrinks as
            // matches end rather than holding its high-water mark.
            z.reclaim_rooms();
            z.push_status();
        }
        Presence::Watching { room, member } => {
            if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                let a = &mut z.rooms[index];
                if a.leave_watcher(member) {
                    a.broadcast_roster();
                }
            }
        }
        Presence::Unjoined => {}
    }
    drop(z);

    if let Some(lease) = rated_lease {
        lease.release().await;
    }
}
