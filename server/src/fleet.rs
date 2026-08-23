//! The registration channel: the messages a directory and an arena server say
//! to each other, and the view they build out of them.
//!
//! docs/architecture/discovery.md is the protocol. Tags live at 0x40 and up, in
//! their own space, so a message arriving on the wrong socket is a recognisable
//! mistake rather than a plausible one. Bodies are JSON because this channel
//! carries a handful of messages a second between servers rather than snapshots
//! at 20 Hz to thousands of clients.
//!
//! Both halves live here so neither can drift from the other: one file to read
//! when asking what a field means.

use serde::{Deserialize, Serialize};

/// Arena to directory.
pub const A2D_REGISTER: u8 = 0x40;
pub const A2D_STATUS: u8 = 0x41;
pub const A2D_INTENT: u8 = 0x42;
pub const A2D_ACK: u8 = 0x43;

/// Directory to arena.
pub const D2A_ACCEPTED: u8 = 0x50;
pub const D2A_REJECTED: u8 = 0x51;
pub const D2A_VIEW: u8 = 0x52;
pub const D2A_CATALOG: u8 = 0x53;
pub const D2A_COMMAND: u8 = 0x54;

/// Operator to directory, and back. A third space rather than a byte borrowed
/// from either of the two above, for the reason this file's header gives: a
/// message on the wrong socket should be an obvious mistake. This one asks for
/// the same `View` an arena is pushed, which carries the rows a browse reply
/// leaves out, so the directory answers it only for a peer that reached it
/// without going through the proxy. See `serve_registration`.
pub const O2D_FLEET: u8 = 0x60;
pub const D2O_FLEET: u8 = 0x61;
/// And an operator asking a directory to send one of `VERBS` to an instance
/// it holds. The reply says only whether it went, because the outcome comes
/// back from the arena as an `Ack` a moment later and lands in the audit log
/// the fleet view carries. Same gate as `O2D_FLEET`.
pub const O2D_COMMAND: u8 = 0x62;
pub const D2O_COMMAND: u8 = 0x63;
/// And an operator handing a directory the maps an admin drew, with the zone
/// rotations that name them. Same gate as the two above, and the same reason:
/// the meta-layer is the only process that can tell an operator from anybody
/// else, so it speaks for them over loopback.
///
/// A push rather than a pull because a rotation should land at the next
/// whistle rather than the next restart. It is not how a publication survives,
/// though: that is the meta-layer's table, and a directory that missed a push
/// asks for the current one when it next comes up.
pub const O2D_MAPS: u8 = 0x64;
pub const D2O_MAPS: u8 = 0x65;

/// Every operator verb. The admin surface checks against this so a typo is a
/// refusal rather than a message an arena answers with `unknown_verb`.
pub const VERBS: [&str; 5] = ["kick", "drain", "pin", "unpin", "restart"];

/// The registration protocol's own version, answered with `version_unsupported`
/// rather than guessed at. Without this field every later change is a flag day.
pub const PROTOCOL: u32 = 1;

/// How often an arena pushes status even when nothing changed, and how long
/// either side waits before calling a silent peer dead. Short enough that a
/// delisting is prompt, long enough that a garbage collection pause is not
/// fatal.
pub const HEARTBEAT_MS: u64 = 5_000;
pub const DEAD_AFTER_MS: u64 = 30_000;

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Register {
    pub token: String,
    /// Minted once at first boot and persisted, so a restart keeps its identity.
    /// Not derived from the token, because many instances share one.
    pub instance: String,
    /// What a client should dial. A claim the directory verifies rather than a
    /// fact it accepts.
    pub address: String,
    /// The same instance's WebTransport door, empty when it has none. Not
    /// verified the way `address` is: a client that cannot reach it falls back
    /// to the WebSocket address on its own, so a dead claim here costs a
    /// fallback rather than a stranded player.
    #[serde(default)]
    pub wt: String,
    pub region: String,
    /// A label for the admin view when one credential covers several blocks.
    /// Never an authorisation: the pool in `Accepted` comes from the token row.
    #[serde(default)]
    pub pool_hint: String,
    /// Zones this instance will serve. Empty means all of them, which is what a
    /// block of identical containers wants.
    #[serde(default)]
    pub willing: Vec<String>,
    pub version: u32,
    /// The provider's id for the machine this process is on, when the host
    /// knows one. Read from the metadata service at provisioning and passed
    /// in, rather than fetched here: an arena has no business making a
    /// network call to learn something that does not change.
    ///
    /// It buys the admin panel a link to the console page for the box, which
    /// is the click after deciding a host rather than a process is the
    /// problem. Empty on a laptop and on any provider whose metadata names
    /// the field differently, which costs a link and nothing else.
    #[serde(default)]
    pub host_id: String,
    /// The commit this arena was built from.
    ///
    /// `version` above is the registration protocol's and answers whether the
    /// two ends can speak; this answers which build is running, which is a
    /// different question and the one an operator actually asks. A converge
    /// that updated the directory and not an arena leaves a fleet that works
    /// and disagrees, and until this travelled the only way to see it was to
    /// read two metrics endpoints and compare by eye.
    #[serde(default)]
    pub build: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Metrics {
    pub tick_us: u32,
    pub bw_per_player: u32,
    pub snapshot_bytes: u32,
    pub queue_depth: u32,
    pub lag_actions: u32,
}

/// One room of a zone, as the process holding it reports it.
///
/// `number` is the room's name in the only sense a player has for one. It is
/// chosen when the room opens, from the numbers no live room of that zone is
/// already using, and it is the room's until it closes. Nothing derives it from
/// a position in a list: a directory sorts its instances by how full they are,
/// so a number read off that order would change every time anybody joined
/// anything, and "meet me in room three" has to survive a stranger leaving.
///
/// Two processes can still choose the same number, when both open a room inside
/// the same status window and neither has seen the other's yet. That is settled
/// without a conversation: see `ArenaServer::settle_room_numbers`.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct RoomView {
    pub number: u32,
    pub players: u32,
    pub bots: u32,
    /// No seat left for a person. The bots do not count against this: the bot
    /// server stands one down when somebody arrives.
    pub full: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Status {
    pub zone: String,
    /// Humans. Declared bots are counted beside them and never inside, because
    /// every rule that reads this one, the fill target, the player cap and the
    /// drain, is a rule about people.
    pub players: u32,
    /// Humans watching rather than flying. Kept outside `players` so a
    /// spectator appears in public population without taking a ship seat.
    #[serde(default)]
    pub spectators: u32,
    pub bots: u32,
    /// How many bots this instance would like to have across all its rooms, so
    /// the bot server does no arithmetic about a zone it never reads the
    /// configuration of. Zero while draining, which is what lets a drain finish.
    #[serde(default)]
    pub bots_wanted: u32,
    /// Every room this process currently holds for its zone, and the cap from
    /// the catalog. Both, because the fill ladder needs to know about headroom
    /// and not only about occupancy.
    ///
    /// The rooms themselves rather than a count of them. A count was what this
    /// carried, and then the client needed to list rooms and choose one, which
    /// no reader could do from a number. Two fields would be two things that can
    /// disagree about the same process, so the count is `rooms.len()`.
    #[serde(default)]
    pub rooms: Vec<RoomView>,
    pub max_rooms: u32,
    /// Whether every room it holds is at or above the zone's fill target. This
    /// is the arena's own answer to "am I out of room", which keeps the rule in
    /// one place rather than recomputed by every reader.
    pub capped: bool,
    #[serde(default)]
    pub metrics: Metrics,
    /// An operator pin, when one is set: the zone, who set it, and when. Empty
    /// otherwise.
    ///
    /// It travels because a pin is the one piece of arena state that policy
    /// cannot explain. An instance sitting on a zone the selection rules would
    /// not have chosen looks like a fault until you know somebody put it
    /// there, and admin.md asks for exactly that sentence: pinned to Chaos by
    /// chris at 14:02. Two directories can send conflicting pins, and this is
    /// what turns that into visible operator error rather than a mystery.
    #[serde(default)]
    pub pinned: String,
    #[serde(default)]
    pub pinned_by: String,
    #[serde(default)]
    pub pinned_at_ms: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Intent {
    pub zone: String,
    /// The announcer's own expiry, in milliseconds from now. It travels in the
    /// message so a crashed announcer stops reserving a zone on a timer rather
    /// than holding it empty forever.
    pub expires_ms: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Ack {
    pub command_id: u64,
    /// done | refused | unknown_verb. The last is what lets a directory be
    /// newer than an arena without either pretending.
    pub outcome: String,
    #[serde(default)]
    pub detail: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Accepted {
    pub pool: String,
    pub catalog_version: u32,
    /// Serialised catalog, so an arena needs no filesystem of its own.
    pub catalog: WireCatalog,
    pub verified: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Rejected {
    /// unknown_token | pool_full | unverified | bad_address | version_unsupported
    pub reason: String,
    #[serde(default)]
    pub detail: String,
}

/// One instance as a directory observed it. Only ever its own observations: a
/// directory never relays another's account of a third party, which is what
/// bounds a lying arena to lying about itself.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Observed {
    pub instance: String,
    pub zone: String,
    pub address: String,
    pub region: String,
    pub players: u32,
    pub bots: u32,
    #[serde(default)]
    pub bots_wanted: u32,
    #[serde(default)]
    pub rooms: Vec<RoomView>,
    pub max_rooms: u32,
    pub capped: bool,
    pub verified: bool,
    /// Milliseconds since this directory last heard from it.
    pub age_ms: u64,
    /// An unexpired announcement, if it has one.
    #[serde(default)]
    pub intent: String,
    #[serde(default)]
    pub intent_ms: u64,
    #[serde(default)]
    pub pool: String,
    #[serde(default)]
    pub metrics: Metrics,
    /// The build this instance registered with, passed through.
    #[serde(default)]
    pub build: String,
    /// And the machine it says it is on. See `Register::host_id`.
    #[serde(default)]
    pub host_id: String,
    /// The pin this instance reports, passed through as it arrived. See
    /// `Status::pinned`.
    #[serde(default)]
    pub pinned: String,
    #[serde(default)]
    pub pinned_by: String,
    #[serde(default)]
    pub pinned_at_ms: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct View {
    pub instances: Vec<Observed>,
    /// The catalog version this directory is serving. An arena already takes
    /// the highest version any directory offers, so it has no use for this;
    /// an operator does, because two directories on different versions is a
    /// state the fleet resolves silently and correctly and which still means
    /// somebody's publish only half landed.
    #[serde(default)]
    pub catalog_version: u32,
    /// The verifying key this directory's catalog names, so an operator can
    /// see it agree with the key the meta-layer actually signs with. They can
    /// disagree, and when they do every token in the fleet fails its check and
    /// every pilot quietly becomes a guest, which looks like nothing at all.
    #[serde(default)]
    pub meta_key: String,
    /// The build this directory is running, so the panel can hold every
    /// process in the deployment against one another.
    #[serde(default)]
    pub build: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Command {
    pub command_id: u64,
    /// kick | drain | pin | unpin | restart
    pub verb: String,
    #[serde(default)]
    pub args: String,
    /// Who asked, for the log at both ends.
    #[serde(default)]
    pub actor: String,
}

/// An operator asking a directory to command an instance. The directory turns
/// this into the `Command` above, which is why there is no `command_id` here:
/// the directory numbers its own commands, so an operator cannot choose an id
/// and cannot collide with one.
///
/// `instance` empty or `*` means every instance registered with that
/// directory. A kick wants that, because an operator naming a pilot knows the
/// call sign and not the process holding them.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct OperatorCommand {
    #[serde(default)]
    pub instance: String,
    pub verb: String,
    #[serde(default)]
    pub args: String,
    /// Who asked. Filled in by the meta-layer from the account behind the
    /// secret, never by the caller: an actor a client could choose is a name
    /// in an audit log that means nothing.
    #[serde(default)]
    pub actor: String,
}

/// What the directory says about a command it was asked to send: how many
/// instances it went to, and why not when none did. The outcome is not here
/// and cannot be, because the arena answers with an `Ack` a moment later; it
/// lands in the audit log the fleet view carries.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct CommandSent {
    pub sent: u32,
    #[serde(default)]
    pub error: String,
}

/// One map as it travels from the meta-layer to a directory: the name a
/// rotation calls it by, and the packed `.vwmap` behind that name.
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct PublishedMap {
    pub name: String,
    pub bytes_b64: String,
}

/// What one zone plays, in the order it plays them.
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct PublishedZone {
    pub zone: String,
    pub maps: Vec<PublishedMap>,
}

/// Everything an operator has published, and how many times they have
/// published anything.
///
/// The serial is what makes it arrive. A directory serves `catalog.version +
/// serial`, and an arena takes the highest version it is offered, so a publish
/// reaches a fleet through the machinery a catalog edit already used. It only
/// ever counts up, so a directory that missed one is behind rather than wrong,
/// and rolling back is a further publish rather than a smaller number.
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct Published {
    pub serial: u32,
    pub zones: Vec<PublishedZone>,
}

impl Published {
    /// The maps this publication gives a zone, already decoded, or nothing
    /// when it says nothing about that zone. Nothing means the catalog on disk
    /// keeps the zone, which is what makes a rotation removable.
    pub fn zone(&self, name: &str) -> Option<Vec<Vec<u8>>> {
        let z = self.zones.iter().find(|z| z.zone == name)?;
        let maps: Vec<Vec<u8>> = z.maps.iter().filter_map(|m| unb64(&m.bytes_b64)).collect();
        if maps.len() == z.maps.len() && !maps.is_empty() {
            Some(maps)
        } else {
            None
        }
    }
}

/// The catalog as it travels. A subset of what is on disk: the zone definitions
/// an arena needs to serve a game, plus the bans and staff it must enforce, and
/// none of the pool tokens, which an arena has no business holding.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct WireCatalog {
    pub version: u32,
    pub name: String,
    pub default_zone: String,
    pub bans: Vec<String>,
    pub staff: Vec<WireStaff>,
    /// The Ed25519 verifying key for session tokens, hex, empty on a
    /// deployment without accounts. This is why an arena can check who a pilot
    /// is without asking anybody: the key it needs arrives with the zones it
    /// serves. Public by nature, so it travels in the clear like everything
    /// else here, unlike the pool tokens that deliberately do not.
    #[serde(default)]
    pub meta_key: String,
    /// Where the meta-layer answers. An arena posts rated events here and
    /// never anything else; it is the client that logs in.
    #[serde(default)]
    pub meta_url: String,
    /// Declared order preserved: the selection tie-break is "first in the file".
    pub zones: Vec<WireZone>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct WireStaff {
    pub name: String,
    pub capabilities: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct WireZone {
    pub name: String,
    pub description: String,
    pub mode: String,
    pub max_ships: u8,
    pub max_players: u32,
    pub fill_target: u32,
    /// A share of `max_ships`, which is how full the bot server holds a room of
    /// this zone. The arena turns it into a count and reports that, so nothing
    /// downstream has to know the room's size.
    #[serde(default)]
    pub bot_fill: f32,
    pub max_rooms: u32,
    /// See `catalog::ZoneDef::admission`.
    #[serde(default)]
    pub admission: String,
    /// The packed maps, base64 so the whole catalog stays one JSON document,
    /// in the order a room rotates through them. A full-size map packs to a
    /// couple of kilobytes, so this is cheap even at several.
    pub maps_b64: Vec<String>,
    /// The zone's whole `zone.toml`, verbatim. The arena parses it with the same
    /// parser the catalog loader uses, so there is exactly one schema and one
    /// code path for a zone definition however it arrived. Re-serialising the
    /// settings block instead would have been a second implementation of the
    /// surface most likely to grow.
    pub zone_toml: String,
}

impl WireCatalog {
    pub fn zone(&self, name: &str) -> Option<&WireZone> {
        self.zones.iter().find(|z| z.name == name)
    }
    pub fn is_banned(&self, name: &str) -> bool {
        self.bans.iter().any(|b| b.eq_ignore_ascii_case(name))
    }
    pub fn has_capability(&self, name: &str, cap: &str) -> bool {
        self.staff
            .iter()
            .any(|s| s.name.eq_ignore_ascii_case(name) && s.capabilities.iter().any(|c| c == cap))
    }
}

/// Frame a message: one tag byte, then JSON.
pub fn frame<T: Serialize>(tag: u8, body: &T) -> Vec<u8> {
    let mut out = vec![tag];
    match serde_json::to_vec(body) {
        Ok(b) => out.extend_from_slice(&b),
        Err(_) => out.extend_from_slice(b"{}"),
    }
    out
}

/// Unframe one, or `None` if it is not the tag expected or not readable. A
/// malformed message from a peer is a message ignored, never a panic.
pub fn parse<T: for<'de> Deserialize<'de>>(data: &[u8], tag: u8) -> Option<T> {
    if data.first() != Some(&tag) || data.len() < 2 {
        return None;
    }
    serde_json::from_slice(&data[1..]).ok()
}

pub fn tag_of(data: &[u8]) -> Option<u8> {
    data.first().copied()
}

/// Base64, for the map inside the wire catalog. Small enough to write out that
/// pulling in a crate for it would be the larger change.
pub fn b64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        s.push(T[(n >> 18) as usize & 63] as char);
        s.push(T[(n >> 12) as usize & 63] as char);
        s.push(if c.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        s.push(if c.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    s
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    let val = |c: u8| -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => (c - b'A') as u32,
            b'a'..=b'z' => (c - b'a') as u32 + 26,
            b'0'..=b'9' => (c - b'0') as u32 + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        })
    };
    let raw: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if !raw.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(raw.len() / 4 * 3);
    for c in raw.chunks(4) {
        let pad = c.iter().filter(|&&b| b == b'=').count();
        let mut n = 0u32;
        for (i, &b) in c.iter().enumerate() {
            n |= if b == b'=' { 0 } else { val(b)? } << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if pad < 2 {
            out.push((n >> 8) as u8);
        }
        if pad < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

/// Wall-clock milliseconds. Used for observation ages and intent expiry, both of
/// which are about "how stale" rather than about simulation time, so the sim's
/// tick counter is the wrong clock.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_framed_message_round_trips_and_a_wrong_tag_does_not() {
        let r = Register {
            token: "t".into(),
            instance: "i".into(),
            address: "ws://h:1".into(),
            region: "local".into(),
            version: PROTOCOL,
            ..Default::default()
        };
        let bytes = frame(A2D_REGISTER, &r);
        assert_eq!(bytes[0], 0x40);
        let back: Register = parse(&bytes, A2D_REGISTER).expect("parses");
        assert_eq!(back.instance, "i");
        assert!(
            parse::<Register>(&bytes, A2D_STATUS).is_none(),
            "a message read as the wrong tag is refused, not misread"
        );
        assert!(
            parse::<Register>(&[0x40], A2D_REGISTER).is_none(),
            "a tag alone is not a body"
        );
        assert!(parse::<Register>(&[], A2D_REGISTER).is_none());
    }

    #[test]
    fn the_tag_spaces_do_not_overlap() {
        // The client protocol is 1..=10. Nothing here may collide with it, or a
        // message on the wrong socket becomes plausible instead of obvious.
        for t in [
            A2D_REGISTER,
            A2D_STATUS,
            A2D_INTENT,
            A2D_ACK,
            D2A_ACCEPTED,
            D2A_REJECTED,
            D2A_VIEW,
            D2A_CATALOG,
            D2A_COMMAND,
        ] {
            assert!(
                t >= 0x40,
                "tag {t:#x} is inside the client protocol's range"
            );
        }
    }

    #[test]
    fn base64_round_trips_every_length_of_tail() {
        for n in 0..40usize {
            let data: Vec<u8> = (0..n).map(|i| (i * 37 % 251) as u8).collect();
            let s = b64(&data);
            assert_eq!(unb64(&s).as_deref(), Some(&data[..]), "length {n}");
        }
        assert_eq!(b64(b"a"), "YQ==");
        assert_eq!(b64(b"ab"), "YWI=");
        assert_eq!(b64(b"abc"), "YWJj");
        assert!(unb64("!!!!").is_none(), "not base64");
        assert!(unb64("YQ=").is_none(), "truncated");
    }

    #[test]
    fn a_wire_catalog_carries_no_tokens() {
        // An arena has no business holding a credential that lets something
        // register. Asserted here because the omission is easy to undo when
        // somebody adds a field.
        let json = serde_json::to_string(&WireCatalog::default()).unwrap();
        assert!(
            !json.contains("token"),
            "wire catalog must not carry tokens: {json}"
        );
        assert!(!json.contains("pool"), "nor the pool table: {json}");
    }
}
