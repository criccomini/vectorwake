use std::sync::Arc;

use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

use crate::arena::{sanitize_name, ArenaServer, RatedLease, StandingCheck};
use crate::presence::*;
use crate::protocol::*;
use crate::room::{file_event, Seat};
use crate::{fleet, metrics, pilot, token};

mod commands;

/// A connection that sends nothing is gone. Watchers heartbeat every thirty
/// seconds, so this leaves one half-interval of scheduling slack.
pub(crate) const SESSION_QUIET: std::time::Duration = std::time::Duration::from_secs(45);

fn complete_join_payload(data: &[u8]) -> bool {
    if data.len() < C2S_JOIN_HEADER {
        return false;
    }
    let payload = data[4] as usize + data[5] as usize;
    data.len() >= C2S_JOIN_HEADER + payload
}

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
                        lease.release();
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
                lease.release();
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
                if !complete_join_payload(&data) {
                    let _ = tx.try_send(Message::Binary(deny(
                        DENY_VERSION,
                        "malformed join message",
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
                        let spools = z.spools.clone();
                        drop(z);
                        let claimed = RatedLease::claim(
                            base,
                            pool_token,
                            instance,
                            account,
                            session.id.clone(),
                            spools,
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
                // Arrived to watch. The room channel is the whole of
                // what anybody in the stands can see, whoever they are.
                // Checked before the bot flag on purpose; a client
                // claiming both came to watch.
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
                        tx.clone(),
                        presence.clone(),
                    );
                    match joined {
                        Some(_id) => {
                            credential_expires = presented_expires;
                            let a = &mut z.rooms[idx];
                            // The ground, the rules, the clock and the
                            // scoreboard as the channel is showing them, not
                            // as the room has them: what arrives next is a
                            // frame from five seconds ago, and a screen set
                            // up from the live room would spend those five
                            // seconds disagreeing with its own picture. One
                            // match packet owns the clock and the result, so
                            // join sync cannot split them.
                            for m in a.channel_sync() {
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
                            // They came through the door asking for the stands.
                            w.push(WHY_NONE);
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
                    z.room_for_bot_request(want_room, &seat_of)
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
                // own rating tables, so putting a returning player's rating in
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
                    // The room's own accessors rather than the same two
                    // headers written out a second time. They were spelled
                    // inline here, which made this the one place a wire could
                    // change on the broadcast path and not on the door.
                    let mut landed = tx.try_send(Message::Binary(a.map_msg())).is_ok();
                    if let Some(n) = a.map_name_msg() {
                        landed &= tx.try_send(Message::Binary(n)).is_ok();
                    }
                    landed &= tx.try_send(Message::Binary(a.settings_msg())).is_ok();
                    // A fresh socket has an empty queue, so this practically
                    // always lands. When it does not, the room owes them the
                    // ground and keeps offering it rather than seating a pilot
                    // who has no map to predict against at all.
                    if !landed {
                        if let Some(p) = a.players.get_mut(&new_id) {
                            p.owes_map = true;
                        }
                    }
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
                    w.push(WHY_NONE);
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
            C2S_KIT => {
                // A ship: the hull it names and the build spent on it. Read
                // as pairs, a count of spent slots then a slot and a count
                // for each.
                //
                // This is the whole of a ship change now. From a pilot in the
                // air the room applies it under the core's gate, a full bar
                // and a respawn, whether what moved is the hull or the row;
                // from a benched one it is dealt in place. See
                // `Room::set_ship_kit`, which is where that choice is made.
                //
                // Nothing is validated here beyond the shape, and that is
                // deliberate rather than lax. The core fits every build to
                // the ceilings and the budget, so a client sending a slot
                // twice, a count of two hundred, or seven credits in each of
                // twenty-three slots gets a legal build back rather than an
                // error, and the arena deals the fitted row. What a hostile
                // client cannot do is spend more than a player, and what it
                // cannot do is reload: a build dealt either way clamps the
                // rack down and never up.
                //
                // Only from a pilot in a seat. A watcher asking to spend
                // credits is asking about a ship they are not in, and the
                // way back into one is `C2S_SHIP`, which their client sends
                // first.
                //
                // The room answers a ship it would not deal, which it does
                // for itself: `Room::set_ship_kit` sends `S2C_NOSHIP` with
                // the reason on the way out. See decision 162.
                if data.len() >= 3 {
                    let cls = data[1];
                    let spent = data[2] as usize;
                    let mut kit = [0u8; crate::sim::SLOT_COUNT];
                    if data.len() >= 3 + spent * 2 {
                        for at in 0..spent {
                            let slot = data[3 + at * 2] as usize;
                            let count = data[4 + at * 2];
                            if slot < crate::sim::SLOT_COUNT {
                                kit[slot] = kit[slot].saturating_add(count);
                            }
                        }
                        if let Presence::Flying { room, member } = presence.current() {
                            let mut z = zone.lock().await;
                            if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                                let a = &mut z.rooms[index];
                                if let Some(ship) = a.players.get(&member).map(|p| p.ship) {
                                    a.set_ship_kit(ship, cls, &kit);
                                }
                            }
                        }
                    }
                }
            }
            C2S_SHIP => {
                // A hull change, in place. The core refuses it unless
                // the pilot is alive and at a full bar, which is what
                // stops it being an escape from a fight: a fresh ship
                // is a fresh bar.
                //
                // Nothing is sent back, and this is the one hull ask
                // where that is still right. A pilot changing ship in
                // a match sends `C2S_KIT`, because a build belongs to
                // a hull, and that is the path decision 162 gave an
                // answer to. What reaches here from a seat is a client
                // naming a hull with no build behind it, which this
                // one stopped doing.
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
                                a.set_ship_class(ship, cls);
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
                                            (base, token, instance, z.spools.clone())
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
                        if let Some((base, pool_token, instance, spools)) = match lease_args {
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
                                spools,
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
                                lease.release();
                            }
                            continue;
                        };
                        let Some(index) = z.rooms.iter().position(|a| a.number == room) else {
                            drop(z);
                            if let Some(lease) = candidate {
                                lease.release();
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
                            lease.release();
                        } else if let Some(lease) = rated_lease.take() {
                            // The only watcher that can arrive here still
                            // holding a lease was swept out of a safe zone and
                            // immediately asked to fly again. If the room has
                            // filled in the meantime, it stays in the stands
                            // and must stop excluding this account elsewhere.
                            lease.release();
                        }
                    }
                }
            }
            C2S_SAY => {
                commands::say(&zone, &presence, &data).await;
            }
            C2S_WATCH => {
                // Sit out, from a pilot who is flying. A request rather
                // than an assertion: the next welcome is the answer, and
                // a room whose gallery is full leaves them in their hull.
                // From somebody already watching it is the keepalive and
                // nothing else, since there is one feed and they are on
                // it: a client with no inputs to send repeats the ask so
                // the quiet timeout knows the socket is alive.
                let mut z = zone.lock().await;
                let mut release = false;
                if let Some((room, member)) = presence.current().flying() {
                    if let Some(index) = z.rooms.iter().position(|a| a.number == room) {
                        if z.rooms[index].sit_out(member, false) {
                            release = true;
                            // A human left the game count.
                            z.push_status();
                        }
                    }
                }
                drop(z);
                if release {
                    if let Some(lease) = rated_lease.take() {
                        lease.release();
                    }
                }
            }
            C2S_TEAM => {
                commands::team(&zone, &presence, &data).await;
            }
            C2S_FOUND => {
                commands::found(&zone, &presence).await;
            }
            C2S_INVITE => {
                commands::invite(&zone, &presence, &data).await;
            }
            C2S_INPUT => {
                commands::input(&zone, &presence, &data).await;
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
        lease.release();
    }
}

#[cfg(test)]
mod tests {
    use super::complete_join_payload;

    #[test]
    fn a_join_must_contain_every_declared_payload_byte() {
        assert!(complete_join_payload(&[1, 0, 0, 0, 1, 1, 0, b'z', b'n']));
        assert!(!complete_join_payload(&[1, 0, 0, 0, 1, 1, 0, b'z']));
        assert!(!complete_join_payload(&[1, 0, 0, 0, 0, 0]));
    }
}
