use crate::directory;

// Client to server
/// `[C2S_JOIN, class, protocol, flags, zone_len, name_len, room]
/// zone name token`
///
/// `room` is which room of the zone to land in, by the number the server gave
/// it, and zero for "whichever the fill ladder picks", which is what every
/// arrival that has not been shown a list says.
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
pub(crate) const C2S_JOIN: u8 = 1;
/// Room zero asks the arena to choose. Every named room must fit in the join's
/// single room byte.
pub(crate) const MAX_ROOM_NUMBER: u32 = u8::MAX as u32;
/// How long that fixed part is.
///
/// Named because this process holds two senders of it, a player's client in
/// `net.lua` and the bot server in `bots.rs`, and a field added to the header
/// reaches the parser and whichever of them somebody remembered. `room` was
/// added and reached one, and every bot in the fleet was then called "pilot":
/// its name was read a byte late, ran off the end of a message carrying no
/// session token, came back empty, and an empty name is the one thing
/// `sanitize_name` answers with that word.
pub(crate) const C2S_JOIN_HEADER: usize = 7;
/// `[C2S_INPUT, count, lifecycle, snapshot ack, snapshot mask,
/// (tick, buttons)...]`.
/// Records name their own ticks, so a packet can repair a hole without spending
/// its whole budget on the consecutive states around it. The snapshot receipt
/// window gives the arena downlink loss and round-trip samples on its own clock.
pub(crate) const C2S_INPUT: u8 = 2;
pub(crate) const INPUT_HISTORY: usize = 4;

pub(crate) fn input_message(
    lifecycle: u32,
    snapshot_ack: u32,
    snapshot_mask: u32,
    records: &[(u32, u16)],
) -> Vec<u8> {
    assert!(!records.is_empty() && records.len() <= INPUT_HISTORY);
    let mut msg = Vec::with_capacity(14 + records.len() * 6);
    msg.push(C2S_INPUT);
    msg.push(records.len() as u8);
    msg.extend_from_slice(&lifecycle.to_le_bytes());
    msg.extend_from_slice(&snapshot_ack.to_le_bytes());
    msg.extend_from_slice(&snapshot_mask.to_le_bytes());
    for &(tick, buttons) in records {
        msg.extend_from_slice(&tick.to_le_bytes());
        msg.extend_from_slice(&buttons.to_le_bytes());
    }
    msg
}

pub(crate) struct InputPacket {
    pub(crate) lifecycle: u32,
    pub(crate) snapshot_ack: u32,
    pub(crate) snapshot_mask: u32,
    pub(crate) records: Vec<(u32, u16)>,
}

pub(crate) fn input_packet(data: &[u8]) -> Option<InputPacket> {
    let count = *data.get(1)? as usize;
    if count == 0 || count > INPUT_HISTORY || data.len() != 14 + count * 6 {
        return None;
    }
    let lifecycle = u32::from_le_bytes(data.get(2..6)?.try_into().ok()?);
    let snapshot_ack = u32::from_le_bytes(data.get(6..10)?.try_into().ok()?);
    let snapshot_mask = u32::from_le_bytes(data.get(10..14)?.try_into().ok()?);
    let mut records = Vec::with_capacity(count);
    for at in 0..count {
        let start = 14 + at * 6;
        let tick = u32::from_le_bytes(data.get(start..start + 4)?.try_into().ok()?);
        let buttons = u16::from_le_bytes(data.get(start + 4..start + 6)?.try_into().ok()?);
        records.push((tick, buttons));
    }
    Some(InputPacket {
        lifecycle,
        snapshot_ack,
        snapshot_mask,
        records,
    })
}
pub(crate) const C2S_SHIP: u8 = 5;
/// The three asks a pilot can make about sides, all of them requests rather
/// than assertions: cross to a side, found one, invite somebody to mine. None
/// is answered directly. The team list that follows says what happened, the
/// same way a snapshot answers a hull change. See design/teams.md.
pub(crate) const C2S_TEAM: u8 = 6;
pub(crate) const C2S_FOUND: u8 = 7;
pub(crate) const C2S_INVITE: u8 = 8;
/// 10 was `C2S_ATTACH`, riding a teammate as a gunner. Gunners are gone: at
/// four a side, two pilots on one hull is a quarter of a team's guns parked.
/// The number is left unused rather than reissued, so an old client asking
/// for it is refused rather than being understood as something else.
/// `[C2S_WATCH]`: sit out. One byte, because there is nothing to name: the
/// room channel is the whole of what a watcher can see, so the only question
/// this message ever asked has one answer.
///
/// A request like the team asks, not an assertion: the answer is the next
/// welcome, and a room whose gallery is full leaves the pilot in their hull.
/// From somebody already watching it is the keepalive, since a client with no
/// inputs to send has nothing else to prove the socket is alive with.
///
/// It used to carry a ship: whose eyes to borrow. Live sight of a stranger is
/// the one thing this mode must never hand out, so a hostile ask already fell
/// to the channel; then same-side follow and the staff grant went too, and a
/// byte whose every value meant the channel is a byte saying nothing.
pub(crate) const C2S_WATCH: u8 = 9;
/// `[C2S_KIT, class, spent, (slot, count) * spent]`: the build this pilot
/// spends their credits on, for the hull they name.
///
/// The class byte is not redundant. A build belongs to a hull, and a pilot
/// who picks a ship and edits it sends two messages that may cross; naming
/// the hull it was spent on lets a room drop one that arrived for a ship the
/// pilot is no longer in, rather than dealing an Anvil's row to a Cipher.
///
/// Slot and count are sent as pairs rather than as the whole vector for the
/// same reason the snapshot does it: a build is mostly zeroes, and seven
/// credits cannot reach more than seven slots. Nothing here is trusted. The
/// core fits whatever arrives to the ceilings and the budget, so a hostile
/// client cannot spend more than a player can, and the arena deals the
/// fitted row rather than the asked one.
///
/// The tag is 10, which is the number the last kit used before ships were
/// preconstructed. Reissuing it is safe because the version byte is checked
/// before any tag is read: a client old enough to remember the other meaning
/// is refused at the door.
pub(crate) const C2S_KIT: u8 = 10;
/// `[C2S_SAY, phrase]`: say one of the fixed things. One byte, and it names a
/// line rather than carrying one, which is the whole design:
/// [decision 28](../../docs/architecture/decisions.md) says no chat, and this
/// does not become chat by adding entries. Refused while a match is running,
/// because the podium is where it is for.
pub(crate) const C2S_SAY: u8 = 11;
/// How many there are. A phrase past the end is a client talking about a list
/// this arena does not have, and is dropped rather than clamped: clamping
/// would put words in somebody's mouth.
pub(crate) const SAY_COUNT: u8 = 6;
/// This client is a bot and says so. Everything that follows from the
/// declaration is in the arena's favor, which is why a well-behaved bot sets
/// it: a declared bot is labeled in the roster, sits outside the human cap, and
/// is asked to leave before a human is ever refused a seat. Anybody may set it.
/// See docs/architecture/ai-runtime.md.
pub(crate) const JOIN_BOT: u8 = 1;
/// This client came to watch, not to fly. The class byte is ignored, no ship
/// is spawned, and the seat taken is a watcher's: outside `max_players`,
/// outside the bot arithmetic, invisible to the simulation.
pub(crate) const JOIN_WATCH: u8 = 2;
/// The client wire, which versions separately from the arena-to-directory one in
/// `fleet.rs`: they change for different reasons and are spoken by different
/// programs. Bump when a message's layout changes, so a stale build is told its
/// build is stale rather than left to misparse a snapshot.
///
/// 6 added spectating: the watcher section on the roster, the subject byte's
/// wider meaning, and `S2C_ONAIR`.
///
/// 8 filtered snapshots: a presence bitmap ahead of the ship records, rounds
/// culled to the interest radius, and the scores moved onto the roster so a
/// board can still name a seat it is no longer shown. Every one of those is a
/// layout change, and a build that misread any of them would draw an arena
/// that is not there, so the bump is what turns a deploy race into a refusal
/// and a reload rather than a garbled room.
///
/// 9 split public ship records from owner-only inventory and weapon state.
///
/// 10 made energy and its capacity rung part of the public record again. They
/// form the health bar that visible opponents use to read a fight, not private
/// loadout information.
///
/// 11 repeats recent inputs and timestamps combat events. A stale client would
/// otherwise lose one-tick controls and present news ahead of its snapshot.
///
/// 12 adds selective input and snapshot acknowledgments, server lag policy,
/// and the nearby-combat snapshot lane.
///
/// 13 carries the gunner limits and carrier movement penalties in zone
/// settings. Older clients predicted a carrier as if nobody were attached.
///
/// 14 gives every flying or watching life and every settings revision a
/// generation. Delayed packets can no longer cross either boundary.
///
/// 15 links the rounds fired in one gun volley. A hull hit removes its
/// siblings, matching SVS multifire without affecting wall collisions.
/// 18 appends the public match artifact id to the intermission message.
///
/// 19 makes match state self-describing and carries Ladder progress in the
/// same packet. Older clients would misread its flags and must not enter.
/// 20 adds the bot build field to a join so a certified Ladder can refuse a
/// controller from another deployment revision.
///
/// 21 puts a byte on the end of every kill saying whether the pilot it was
/// sent to was credited with an assist. A client built for 20 would read the
/// message it wants and ignore a byte; one built for 21 against a zone
/// serving 20 would find every kill a byte short and print no feed at all,
/// which is the direction this number exists to refuse.
///
/// 22 carries kill streaks: two more bytes in every ship record, two more
/// numbers in the settings, and `S2C_STREAK`. An older client would read the
/// snapshot's ship tail off by two bytes from the first streaking pilot's
/// record onward, which is the class of fault that once showed a healthy
/// fleet as DESTROYED.
///
/// 23 takes the ship byte off `C2S_WATCH`. Spectating is the room channel and
/// nothing else now, so a client built for 22 would send a subject this zone
/// has no way to honor and sit waiting for a view it will never be given.
///
/// 24 changes what the five flight-stat counts mean. Old tabs would send a
/// legal byte vector that resolves to a different ship, so they must reload
/// before joining or saving a kit under the new row.
///
/// 30 takes duels out. `S2C_MATCH` loses its per-pilot card, so the clock, the
/// score and the result artifact are the whole of that message again, and
/// `C2S_JOIN` loses the build-claim field a certified duel zone used to check
/// its house opponents against. A client built for 29 would go looking for a
/// card behind a flag bit nothing sets, and would write a join header one byte
/// long for this door.
///
/// 31 makes a ship preconstructed. `C2S_KIT` is gone, and so are the two
/// numbers a kill used to pay: `S2C_ROSTER` drops points and bounty, and
/// `S2C_KILL` drops what the kill was worth. A client built for 30 would read
/// four bytes of somebody else's row out of every roster and print a payout
/// off the end of a kill.
///
/// 32 gives a pilot their credits back. `C2S_KIT` returns on tag 10 carrying
/// a build as spent slots, and a hull's profile becomes the row a pilot
/// starts on rather than the row they are stuck with. A client built for 31
/// would fly whatever the hull's profile is and never send a build, which is
/// the game 31 played, so the refusal is what tells them to reload rather
/// than leaving them quietly unable to spend anything.
///
/// 33 puts a reason on the end of every welcome, so a pilot the room moves to
/// the stands is told why. A client built for 32 reads the message it wants
/// and ignores a byte, so this one is not refusing a misparse the way 22 and
/// 31 did: it is there so the fleet and the page cannot sit one build apart on
/// a wire field, which is how the DESTROYED outage above happened.
///
/// 34 puts the greens in the snapshot. A count and eleven bytes apiece follow
/// the flags, which is squarely a misparse for a client built for 33: it stops
/// reading where the flags end, and `sim_unpack` treats a short read as an
/// error exactly as it treats a long one, so every snapshot from a room with
/// greens in it would be refused rather than misread. Every match game runs
/// none, so on those the only difference is a zero byte; Free Roam is the zone
/// a stale client could not join at all.
///
/// 35 names every round. A two byte counter rides ahead of the weapon
/// records and each record ends in the name it was dealt from that counter,
/// which is what a client uses to tell one snapshot's rounds from the next
/// now that a repel can hand a round its whole life back. A client built for
/// 34 would read the counter as a weapon count and the rest as records, which
/// is a misparse, so the number moves.
///
/// 36 puts a flag's `held` clock on the wire, two bytes after its cooldown.
/// `sim_hash` had always covered it, and the hash is what a pack round trip is
/// checked against, so it was owed; the client needs it to draw the carry
/// limit, which it cannot count for itself when it joins mid carry. A client
/// built for 35 would read those two bytes as the head of the next flag.
///
/// 37 answers a refused crossing. `S2C_NOTEAM` is a new tag, so a client built
/// for 36 would skip it rather than misread anything, and the number moves for
/// the reason 33's did: this is a wire field the fleet and the page have to
/// agree on, and a build that cannot hear the answer goes on showing the
/// silence this message exists to end.
pub(crate) const CLIENT_PROTOCOL: u8 = 37;

/// The biggest message a client may send. The largest legitimate one is a join:
/// tag, class, protocol, a zone name and a call sign. 8 KB is two orders of
/// magnitude of headroom.
pub(crate) const C2S_MAX: usize = 8 * 1024;
/// Asked by the directory, and by any client that wants to know what a zone
/// is before committing to it. Answerable without joining.
pub(crate) const C2S_STATUS: u8 = directory::STATUS_REQUEST;

// Server to client
/// `[S2C_WELCOME, ship, lifecycle, tick, room, settings generation, why]`, the
/// numbers little-endian and `ship` 255 for a watcher.
///
/// `why` is how this seat came about, and it is the room's answer rather than
/// the client's: the two ways to end up in the stands without asking look
/// identical from the far end, and a client left to work it out would have to
/// pair the swap up with a lag notice by timing. Zero on every welcome a pilot
/// brought about themselves, which is most of them.
pub(crate) const S2C_WELCOME: u8 = 1;
/// Nothing to explain: a join, a hull taken from the stands, a seat given up
/// by the pilot sitting in it, or a client that came through the door asking
/// to watch.
pub(crate) const WHY_NONE: u8 = 0;
/// The safe-zone timer moved them for loitering.
pub(crate) const WHY_SAFE: u8 = 1;
/// Their input stopped arriving for `spectate_silence_ticks` and the room gave
/// the seat up on their behalf.
pub(crate) const WHY_LAG: u8 = 2;
pub(crate) const S2C_SNAPSHOT: u8 = 2;
pub(crate) const SNAPSHOT_HEADER: usize = 32;
pub(crate) const SNAPSHOT_FLYING: u8 = 0;
pub(crate) const SNAPSHOT_WATCHING: u8 = 1;
pub(crate) const S2C_ROSTER: u8 = 3;
/// `[S2C_KILL, victim, killer, victim rating, killer rating, contributors,
/// tick, you helped]`, the ratings little-endian.
///
/// Nothing about a payout, because a kill pays nothing: bounty priced one and
/// points banked it, and both went with the shop.
///
/// Broadcast, with one exception: the last byte is built per recipient and is
/// 1 only on the copy sent to a pilot the core credited with an assist for
/// this death. Everybody else, watchers and the room channel included, is
/// sent a zero, so an assist is a thing you are told about your own fight and
/// nobody reads off somebody else's.
///
/// A byte on the death rather than a message of its own, because it is not a
/// second event: it qualifies a line the feed is already about to print, and
/// a separate message would have to be paired back up with that line by tick
/// and victim at the far end.
pub(crate) const S2C_KILL: u8 = 4;
pub(crate) const S2C_BANNER: u8 = 5;
pub(crate) const S2C_ZONE: u8 = 6;
pub(crate) const S2C_DENIED: u8 = 7;
/// Why a join was refused. Three of these mean "try another instance" and three
/// mean "stop trying", which is the distinction a client cannot make from a
/// sentence. See the refusal table in docs/architecture/zones-and-arenas.md.
pub(crate) const DENY_FULL: u8 = 1;
pub(crate) const DENY_DRAINING: u8 = 2;
pub(crate) const DENY_WRONG_ZONE: u8 = 3;
pub(crate) const DENY_BANNED: u8 = 4;
pub(crate) const DENY_VERSION: u8 = 5;
pub(crate) const DENY_RATED_SESSION: u8 = 6;
/// What an instance that has not been told which zone it is says at its door,
/// written once because both doors say it: the join, and the watcher behind it.
pub(crate) const NO_ZONE_YET: &str = "this instance is not serving a zone yet; re-browse";
pub(crate) const S2C_STATUS: u8 = directory::STATUS_REPLY;
/// The map, run-length encoded, sent before the first snapshot. A client
/// predicts collisions locally, so it needs the room before it needs anyone
/// in it.
pub(crate) const S2C_MAP: u8 = 9;
/// The tuning, sent straight after the map and again whenever an operator
/// reloads the zone file. A client that predicts on its own compiled
/// defaults is predicting a different game the moment a zone tunes anything.
pub(crate) const S2C_SETTINGS: u8 = 10;
/// Your seat is wanted. Sent to a declared bot when a human needs the room it
/// is standing in, and to every bot when the instance starts draining.
///
/// The seat is already gone by the time this arrives: it is a courtesy, not a
/// request, so that a bot leaves cleanly rather than being deduced from a
/// simulation it is no longer in. A client that ignores it holds a socket and
/// nothing else.
pub(crate) const S2C_YIELD: u8 = 11;
/// Every side in the room, what it is called, who is on it, and whether this
/// particular client may enter it. Built per recipient rather than broadcast
/// as one buffer, because the last of those is a different answer for every
/// pilot: a private side is a door only the invited can see open.
pub(crate) const S2C_TEAMS: u8 = 12;
/// `[S2C_ONAIR, 0|1]`: the frame going out is centered on you and somebody is
/// in the stands to see it, or that has stopped being true. Sent to the
/// subject and nobody else. The channel is a shared feed whose subject does
/// not choose to be watched, so the least the room owes them is knowing it:
/// two minutes on camera is something a pilot can play around, and only if
/// they are told.
pub(crate) const S2C_ONAIR: u8 = 13;
/// `[S2C_MATCH, flags, seconds left, sides, score per side as u16,
/// optional artifact id as u64]`.
///
/// Flag bit 0 says the match is playing and bit 1 says an artifact follows the
/// scores.
///
/// One packet owns the clock, the score and the result artifact. Queue
/// pressure can delay the newest answer, but it cannot combine halves from two
/// different states.
///
/// Sent at a join, at every whistle, and whenever either number moves, so a
/// three minute match costs about two hundred of these.
pub(crate) const S2C_MATCH: u8 = 14;
pub(crate) const MATCH_PLAYING: u8 = 1 << 0;
pub(crate) const MATCH_HAS_ARTIFACT: u8 = 1 << 1;
/// `[S2C_CHARGE, ship, slot, x, y, tick]`, a public action without the private
/// inventory count. Sent only to views whose fixed fairness circle contains
/// the firing ship; x and y are signed Q8 positions.
pub(crate) const S2C_CHARGE: u8 = 15;
/// `[S2C_LAG, state, reserved zero, ping, jitter, three diagnostics]`.
/// The arena sends it on policy changes and periodically while a restriction
/// remains active, so a player is never left guessing why an action was denied.
pub(crate) const S2C_LAG: u8 = 16;
/// `[S2C_SAID, ship, phrase]`: somebody said one of the fixed things, between
/// matches. The phrase is an index into a list both ends hold, never text: the
/// wire cannot carry a word this arena did not ship, so there is nothing to
/// moderate and nothing to report. See docs/design/match-game.md.
pub(crate) const S2C_SAID: u8 = 17;
/// `[S2C_MAPNAME, name]`: what the rotation calls the map that just arrived,
/// as UTF-8, sent straight after every S2C_MAP. Its own message rather than a
/// field on the map, which is packed bytes the sim core hashes: a name is
/// presentation, and a client that predates it ignores the kind unread.
pub(crate) const S2C_MAPNAME: u8 = 18;
/// `[S2C_STREAK, ship, kills, tick as u32]`: this pilot has reached the zone's
/// streak, which is that many kills without dying. Sent once, on the kill that
/// got them there, and carrying the tick for the same reason a kill does: the
/// feed line has to land with the death that caused it rather than ahead of
/// the snapshot that shows it.
///
/// The arena's message rather than the client's own reading of the counter. A
/// client predicts, and a prediction that rolled back over the kill would
/// announce the streak again on every replay of it.
pub(crate) const S2C_STREAK: u8 = 19;
/// `[S2C_NOTEAM, why]`: the side you asked for is not yours, and this is what
/// stopped it. Sent to the one pilot who asked, beside the team list that
/// already goes back to them.
///
/// The list was the whole of the answer until now, on the grounds that it
/// still says where you are, which is what the client asked about. It is not
/// enough. `C2S_TEAM` is sent when the client has just seen a full bar, and
/// the core will not let a hurt pilot leave where they stand, so the ask that
/// loses that race is the ordinary one: you press with a full bar, a round
/// lands while the message is in flight, and the room keeps you where you are
/// without a word. The client had already played its yes and put the card
/// away by then, so what a player got was a confirmation and no change.
///
/// A reason on the wire rather than a clock in the client. A client can see
/// that its side did not change, but not whether the room refused or has yet
/// to answer, and telling those apart by waiting is the kind of conclusion
/// about the shared world that decision 40 says a client does not draw.
pub(crate) const S2C_NOTEAM: u8 = 20;
/// No such side. It was reaped between the reading and the ask, which a
/// private side with one member does the moment they leave it.
pub(crate) const NOTEAM_GONE: u8 = 1;
/// A private side that has not invited you.
pub(crate) const NOTEAM_PRIVATE: u8 = 2;
/// Every seat on it is taken.
pub(crate) const NOTEAM_FULL: u8 = 3;
/// You are waiting to respawn. Crossing hands out a fresh start and a full
/// bar, so a pilot who is already down would be taking the better of two
/// respawns.
pub(crate) const NOTEAM_DOWN: u8 = 4;
/// Your bar is not full. This is the one that arrives after a client thought
/// it had checked: the bar was full when the key went down.
pub(crate) const NOTEAM_HURT: u8 = 5;
