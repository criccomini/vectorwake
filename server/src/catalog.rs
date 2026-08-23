//! The catalog: every zone a deployment offers, versioned as one artifact.
//!
//! docs/architecture/catalog.md is the schema. The load path here is deliberately
//! strict, because a catalog that half-applies is worse than one that refuses:
//! a listed zone nobody can join, or a mode that silently fell back to warzone,
//! is hard to diagnose from inside a game. Every rejection carries the reason.
//!
//! This is also the piece that retires the oldest dead keys in the project.
//! `mode` and `flags` parsed and were ignored for months while the arena was
//! hardcoded; here they decide what runs.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// What a zone declares about itself. The `[arena]` block underneath is the
/// settings surface that already existed, unchanged, which is why this reuses
/// `config::ArenaConfig` rather than restating it.
#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct ZoneDef {
    pub description: String,
    /// warzone | arena | duel. Read, unlike before.
    pub mode: String,
    /// The maps this zone plays, relative to its own directory, in the order
    /// a room rotates through them. At least one; a match game takes the next
    /// one at every whistle, so a zone with two of them never plays the same
    /// ground twice in a row.
    pub maps: Vec<String>,
    /// Pilots a room holds, bots included; the core clamps to SIM_MAX_SHIPS.
    pub max_ships: Option<u8>,
    /// Humans of those seats.
    pub max_players: Option<usize>,
    /// The concentration rule: another room or instance opens only when every
    /// live one is at or above this. Counts humans; see
    /// `ArenaServer::fill_target`.
    pub fill_target: Option<usize>,
    /// How full the bot server keeps this zone's rooms, as a share of
    /// `max_ships`. Zero is a zone with no bots.
    pub bot_fill: Option<f32>,
    /// The most simulations one process may hold for this zone. A ceiling, not
    /// a count: rooms appear on demand and are reclaimed when they empty.
    pub max_rooms: Option<usize>,
    /// The zone's own teams, by name, in the order the mode scores them. The
    /// names are what players see and are stable across rounds on purpose, so
    /// a side is a place rather than a number. An empty list is a free-for-all:
    /// no side to join, every pilot their own.
    pub teams: Vec<String>,
    /// The most sides the room may hold at once, the zone's own included.
    /// Setting this to the number of public teams is how a zone says no
    /// player may found one.
    pub max_teams: Option<u8>,
    /// People on one side, and bots on one side. There is no balance rule
    /// beyond these: the only refusal a player meets is a full team, and the
    /// bot cap is the ballast dial. See design/teams.md.
    pub max_humans_per_team: Option<u16>,
    pub max_bots_per_team: Option<u16>,
    /// `any`, the default, or `claimed` for a zone that wants a field it can
    /// vouch for. A ladder arena may reasonably care that everybody in it has
    /// chosen to be the same person tomorrow; a public room reasonably does
    /// not, since the cost of caring is a newcomer turned away in the second
    /// they arrived.
    pub admission: String,
    /// Watchers a room admits beside its players. A watcher costs the arena
    /// nothing per tick and a full player's egress, so this is a bandwidth
    /// number rather than a feel number.
    pub max_watchers: Option<usize>,
    /// How far behind the room channel runs, in ticks. The channel is the
    /// neutral view, one shared feed per room, and the delay is what keeps it
    /// from being a live map of the fight for whoever opens a second tab. A
    /// duel zone sets zero on purpose: there the audience is the mode and both
    /// pilots are equally exposed.
    pub channel_delay_ticks: Option<u32>,
    pub arena: crate::config::ArenaConfig,
    /// The text this was parsed from, kept so a directory can hand the zone to
    /// an arena verbatim rather than re-serialising it. Not a field in the file;
    /// `deny_unknown_fields` would reject it, hence `skip`.
    #[serde(skip)]
    pub raw: String,
}

impl Default for ZoneDef {
    fn default() -> Self {
        ZoneDef {
            description: String::new(),
            mode: "arena".into(),
            maps: Vec::new(),
            max_ships: None,
            max_players: None,
            fill_target: None,
            bot_fill: None,
            max_rooms: None,
            teams: Vec::new(),
            max_teams: None,
            max_humans_per_team: None,
            max_bots_per_team: None,
            admission: "any".into(),
            max_watchers: None,
            channel_delay_ticks: None,
            arena: crate::config::ArenaConfig::default(),
            raw: String::new(),
        }
    }
}

/// See `ZoneDef::fill_target`.
pub const DEFAULT_FILL_TARGET: usize = 15;
/// See `ZoneDef::bot_fill`. Four seats in five, which leaves a fifth of the
/// room as headroom so an arriving human almost never has to evict anybody.
pub const DEFAULT_BOT_FILL: f32 = 0.8;

impl ZoneDef {
    /// Fifteen, which is `General:DesiredPlaying`'s default in ASSS and the
    /// number thirty years of the original settled on for a public room. It also
    /// has to sit under the default `max_players`, or a zone that sets neither
    /// would fail its own validation.
    pub fn fill_target(&self) -> usize {
        self.fill_target.unwrap_or(DEFAULT_FILL_TARGET)
    }
    /// A share of the room, not a count, because the count that matters is the
    /// room's own size and a zone that widens its room wants the crowd to widen
    /// with it.
    pub fn bot_fill(&self) -> f32 {
        self.bot_fill.unwrap_or(DEFAULT_BOT_FILL).clamp(0.0, 1.0)
    }
    pub fn max_rooms(&self) -> usize {
        self.max_rooms.unwrap_or(1).max(1)
    }
    pub fn max_players(&self) -> usize {
        self.max_players.unwrap_or(16)
    }
    /// A byte is the whole range a side can have and 255 is `TEAM_NONE`, so
    /// this is what "as many as there can be" means. A zone that wants only
    /// its own sides writes their count here instead.
    pub fn max_teams(&self) -> u8 {
        self.max_teams
            .unwrap_or(255)
            .max(self.teams.len().min(255) as u8)
            .max(1)
    }
    /// No cap by default, in both directions: a room's real ceiling is its
    /// seats, and a zone that wants a tighter one says so.
    pub fn max_humans_per_team(&self) -> u16 {
        self.max_humans_per_team.unwrap_or(255).max(1)
    }
    pub fn max_bots_per_team(&self) -> u16 {
        self.max_bots_per_team.unwrap_or(255)
    }
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(deny_unknown_fields)]
pub struct PoolDef {
    pub name: String,
    /// `sha256:` followed by 64 hex digits, or `env:NAME` naming the variable
    /// that holds that. Never a plaintext secret either way: what is committed
    /// is a digest or the name of a place to find one.
    pub token: String,
    #[serde(default)]
    pub region: String,
    #[serde(default)]
    pub max_instances: usize,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(deny_unknown_fields)]
pub struct StaffDef {
    pub name: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(deny_unknown_fields)]
struct ZoneRef {
    name: String,
    #[serde(default)]
    dir: String,
}

/// Where accounts live, and the key that proves a session token came from
/// there. This is the one thing in the catalog an arena needs but no operator
/// authored: `vectorwake-server metakey` prints both halves, the secret one
/// goes in the meta-layer's environment and this one goes here.
///
/// It rides the catalog because the catalog is already the versioned artifact
/// every arena receives whole, which makes rotating the key a publish rather
/// than a new distribution channel.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(deny_unknown_fields)]
pub struct MetaDef {
    /// Where a client logs in. Arenas never call it.
    #[serde(default)]
    pub url: String,
    /// 64 hex characters of Ed25519 verifying key, or `env:NAME` naming the
    /// variable that holds them. Public by nature: it can check a signature and
    /// cannot make one.
    #[serde(default)]
    pub key: String,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
struct Head {
    version: u32,
    name: String,
    description: String,
    default_zone: String,
    bans: Vec<String>,
    staff: Vec<StaffDef>,
    pool: Vec<PoolDef>,
    zone: Vec<ZoneRef>,
    meta: MetaDef,
}

impl Default for Head {
    fn default() -> Self {
        Head {
            version: 0,
            name: "vectorwake".into(),
            description: String::new(),
            default_zone: String::new(),
            bans: Vec::new(),
            staff: Vec::new(),
            pool: Vec::new(),
            zone: Vec::new(),
            meta: MetaDef::default(),
        }
    }
}

/// A loaded, validated catalog. Zones keep their declared order, because the
/// selection tie-break is "first in the file" and that has to be stable.
#[derive(Clone, Debug, Default)]
pub struct Catalog {
    pub version: u32,
    pub name: String,
    pub description: String,
    pub default_zone: String,
    pub bans: Vec<String>,
    pub staff: Vec<StaffDef>,
    pub pools: Vec<PoolDef>,
    /// Empty when a deployment runs without accounts, which is a supported
    /// arrangement: everyone flies as a guest and nothing durable is written.
    pub meta: MetaDef,
    pub order: Vec<String>,
    pub zones: HashMap<String, ZoneDef>,
    /// Where each zone's files live, for resolving its map.
    pub dirs: HashMap<String, PathBuf>,
}

impl Catalog {
    /// What the two lists in a catalog are for. Nothing in this process asks
    /// yet: bans and staff are enforced at the meta layer, which reads the
    /// same file, and an arena that has to answer for itself will ask here.
    #[allow(dead_code)]
    pub fn is_banned(&self, name: &str) -> bool {
        self.bans.iter().any(|b| b.eq_ignore_ascii_case(name))
    }

    #[allow(dead_code)]
    pub fn has_capability(&self, name: &str, cap: &str) -> bool {
        self.staff
            .iter()
            .any(|s| s.name.eq_ignore_ascii_case(name) && s.capabilities.iter().any(|c| c == cap))
    }

    /// The pool a token belongs to, compared without leaking timing. The token
    /// arrives raw and the table holds `sha256:<hex>`.
    pub fn pool_for_token(&self, raw: &str) -> Option<&PoolDef> {
        let digest = sha256_hex(raw.as_bytes());
        self.pools.iter().find(|p| {
            let want = p.token.strip_prefix("sha256:").unwrap_or("");
            constant_time_eq(want.as_bytes(), digest.as_bytes())
        })
    }

    pub fn zone(&self, name: &str) -> Option<&ZoneDef> {
        self.zones.get(name)
    }

    /// Every map a zone plays, read from its own directory, in its own order.
    /// Empty if the zone names none or a file will not read: a caller that
    /// gets nothing runs the built-in arena and says so.
    pub fn map_bytes(&self, name: &str) -> Vec<Vec<u8>> {
        let Some(z) = self.zones.get(name) else {
            return Vec::new();
        };
        let Some(dir) = self.dirs.get(name) else {
            return Vec::new();
        };
        z.maps
            .iter()
            .filter_map(|m| std::fs::read(dir.join(m)).ok())
            .collect()
    }

    /// The zone an arena serves when it has been told nothing: the declared
    /// default, else the first in the file, else nothing and the built-in room.
    pub fn fallback_zone(&self) -> Option<String> {
        if !self.default_zone.is_empty() && self.zones.contains_key(&self.default_zone) {
            return Some(self.default_zone.clone());
        }
        self.order.first().cloned()
    }
}

/// The shipped catalog names two variables, so anything that loads it outside
/// a provisioned host has to supply them: the test suite, `drill`, and anybody
/// running the server from a checkout.
///
/// Fixed values, and it never unsets, so calling it from any number of threads
/// is safe in a way that setting and clearing per test is not. They are
/// obviously not real: the digest is of the word this function is named after,
/// and a verifying key of all zeroes is not on the curve, which is exactly what
/// a local run should have if it ever tries to check a signature with it.
#[cfg(any(test, debug_assertions))]
pub fn set_placeholder_identity() {
    std::env::set_var(
        "VW_POOL_DIGEST",
        format!("sha256:{}", sha256_hex(b"placeholder")),
    );
    std::env::set_var("VW_META_VERIFY", "0".repeat(64));
}

/// `env:NAME` becomes what NAME holds; anything else is itself.
///
/// Deliberately narrow. It resolves one prefix, on two fields, and an empty
/// variable is an error rather than an empty value, because both fields treat
/// empty as a meaning: no pool, or a deployment with no accounts. Arriving at
/// either by way of a variable somebody forgot to set is the wrong way to
/// arrive at it.
fn indirect(v: &str) -> Result<String, String> {
    let Some(name) = v.strip_prefix("env:") else {
        return Ok(v.to_string());
    };
    if name.is_empty() {
        return Err("\"env:\" names no variable".into());
    }
    match std::env::var(name) {
        Ok(s) if !s.is_empty() => Ok(s),
        _ => Err(format!(
            "{name} is unset or empty, and it is where this deployment's value \
             lives. fleet.sh writes it into the host's .env from the secrets \
             bucket; `fleet.sh secrets ls` says whether one is stored"
        )),
    }
}

/// Load and validate. Every `Err` is a reason an operator can act on, which is
/// the whole point of this module: docs/architecture/catalog.md lists the
/// rejections and this is where they live.
pub fn load(dir: impl AsRef<Path>) -> Result<Catalog, String> {
    let dir = dir.as_ref();
    let head_path = dir.join("catalog.toml");
    let text =
        std::fs::read_to_string(&head_path).map_err(|e| format!("{}: {e}", head_path.display()))?;
    let mut head: Head =
        toml::from_str(&text).map_err(|e| format!("{}: {e}", head_path.display()))?;

    // The two values that are this deployment rather than this game, resolved
    // before anything below looks at them, so every rejection that follows
    // applies to what a process will actually use.
    //
    // A pool digest and a verifying key are public halves, safe to commit, and
    // they were committed. The trouble is what they are paired with: the raw
    // token and the signing key reach a host in its `.env` and nowhere else, so
    // rotating identity meant editing this file, pushing, waiting for an image,
    // and then editing a `.env` per host, with a window in between where the
    // published half had moved and no host had. `env:` puts both halves in the
    // same file, from the same place, changed at the same time.
    //
    // Only the directory and the meta-layer read either of these, and both run
    // on the central host. An arena is handed the verifying key by the
    // directory over the wire, which is why nothing about distribution changes.
    for p in &mut head.pool {
        p.token = indirect(&p.token).map_err(|e| format!("pool {:?}: {e}", p.name))?;
    }
    head.meta.key = indirect(&head.meta.key).map_err(|e| format!("[meta] key: {e}"))?;

    if head.version == 0 {
        return Err("catalog.toml: version must be set and greater than zero, \
                    because an arena server takes the highest version offered"
            .into());
    }
    for p in &head.pool {
        let hex = p.token.strip_prefix("sha256:").ok_or_else(|| {
            format!(
                "pool {:?}: token must be \"sha256:<64 hex>\"; a plaintext token \
                 in the catalog is a leaked token",
                p.name
            )
        })?;
        if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("pool {:?}: token is not 64 hex digits", p.name));
        }
        if p.name.is_empty() {
            return Err("a pool needs a name; it is what an arena is told it is".into());
        }
    }
    // A key that is present and wrong is worse than one that is absent: absent
    // means a deployment without accounts, which works, and wrong means every
    // token in the fleet fails to verify at the door.
    if !head.meta.key.is_empty() && crate::token::verifying_key_from_hex(&head.meta.key).is_none() {
        return Err(
            "[meta] key must be 64 hex characters of Ed25519 verifying key; \
                    'vectorwake-server metakey' prints one"
                .into(),
        );
    }
    if head.meta.key.is_empty() && !head.meta.url.is_empty() {
        return Err(
            "[meta] url is set without a key, so no arena could check a \
                    token minted by it"
                .into(),
        );
    }

    let mut cat = Catalog {
        version: head.version,
        name: head.name,
        description: head.description,
        default_zone: head.default_zone,
        bans: head.bans,
        staff: head.staff,
        pools: head.pool,
        meta: head.meta,
        ..Default::default()
    };

    for r in &head.zone {
        if r.name.is_empty() {
            return Err("a [[zone]] needs a name".into());
        }
        if cat.zones.contains_key(&r.name) {
            return Err(format!(
                "zone {:?} is declared twice; which one a client joins would \
                 depend on parse order",
                r.name
            ));
        }
        let zdir = if r.dir.is_empty() {
            dir.join("zones").join(&r.name)
        } else {
            dir.join(&r.dir)
        };
        let zpath = zdir.join("zone.toml");
        let ztext = std::fs::read_to_string(&zpath)
            .map_err(|e| format!("zone {:?}: {}: {e}", r.name, zpath.display()))?;
        let mut z: ZoneDef = toml::from_str(&ztext)
            .map_err(|e| format!("zone {:?}: {}: {e}", r.name, zpath.display()))?;
        z.raw = ztext;
        validate_zone(&r.name, &z, &zdir)?;
        cat.order.push(r.name.clone());
        cat.dirs.insert(r.name.clone(), zdir);
        cat.zones.insert(r.name.clone(), z);
    }

    if cat.zones.is_empty() {
        return Err("a catalog with no zones offers no games".into());
    }
    if !cat.default_zone.is_empty() && !cat.zones.contains_key(&cat.default_zone) {
        return Err(format!(
            "default_zone {:?} is not a declared zone",
            cat.default_zone
        ));
    }
    Ok(cat)
}

fn validate_zone(name: &str, z: &ZoneDef, zdir: &Path) -> Result<(), String> {
    // The same dead-key failure as `mode`, one field over: a value nobody
    // implements has to be refused rather than quietly read as the default.
    if !matches!(z.admission.as_str(), "any" | "claimed") {
        return Err(format!(
            "zone {name:?}: admission {:?} is not \"any\" or \"claimed\"",
            z.admission
        ));
    }
    // A mode that falls back silently is how `arena.mode` became a dead key.
    if !crate::modes::exists(&z.mode) {
        return Err(format!(
            "zone {name:?}: mode {:?} has no implementation; {}",
            z.mode,
            crate::modes::NAMES.join(", ")
        ));
    }
    // A side with no name has nothing a menu can draw, and a zone that meant
    // a free-for-all writes no teams at all rather than an empty string.
    for (i, team) in z.teams.iter().enumerate() {
        if team.trim().is_empty() {
            return Err(format!("zone {name:?}: team {i} has no name"));
        }
    }
    if z.teams.len() > 254 {
        return Err(format!(
            "zone {name:?}: {} teams, and a side is a byte where 255 means \
             none",
            z.teams.len()
        ));
    }
    // A mode scores over the public teams, so a room that cannot hold them
    // all is a zone whose own sides do not fit in it.
    if let Some(cap) = z.max_teams {
        if (cap as usize) < z.teams.len() {
            return Err(format!(
                "zone {name:?}: max_teams {cap} is under its {} named teams",
                z.teams.len()
            ));
        }
    }
    if z.maps.is_empty() {
        return Err(format!("zone {name:?}: maps is required"));
    }
    for m in &z.maps {
        if !zdir.join(m).exists() {
            return Err(format!(
                "zone {name:?}: map {m:?} is missing; the zone would be listed \
                 and unplayable"
            ));
        }
    }
    if let Some(m) = z.max_ships {
        if m == 0 {
            return Err(format!("zone {name:?}: max_ships must be at least 1"));
        }
    }
    if z.max_rooms == Some(0) {
        return Err(format!(
            "zone {name:?}: max_rooms of zero means a process that cannot serve it"
        ));
    }
    if z.fill_target.unwrap_or(DEFAULT_FILL_TARGET) > z.max_players() {
        return Err(format!(
            "zone {name:?}: fill_target {} is above max_players {}, so the \
             concentration rule would never fire and the zone would never grow",
            z.fill_target.unwrap_or(DEFAULT_FILL_TARGET),
            z.max_players()
        ));
    }
    if let Some(f) = z.bot_fill {
        if !(0.0..=1.0).contains(&f) {
            return Err(format!(
                "zone {name:?}: bot_fill {f} is a share of max_ships, so it \
                 belongs between 0 and 1"
            ));
        }
    }
    Ok(())
}

/// SHA-256, because a token table holds digests and the only dependency this
/// crate had for hashing was none. Small, standard, and exercised by the tests
/// below against published vectors.
pub fn sha256_hex(data: &[u8]) -> String {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64) * 8;
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());

    for block in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ ((!v[4]) & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [
                t1.wrapping_add(t2),
                v[0],
                v[1],
                v[2],
                v[3].wrapping_add(t1),
                v[4],
                v[5],
                v[6],
            ];
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

/// Whether the attack is practical here is beside the point: it is one loop.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

/// `vectorwake-server catalog <dir>`: load it and say what it holds, or say why
/// it will not load. The operator-facing half of every rejection above.
pub fn run_check() {
    let dir = std::env::args().nth(2).unwrap_or_else(|| "catalog".into());
    match load(&dir) {
        Err(e) => {
            println!("catalog {dir}: {e}");
            std::process::exit(1);
        }
        Ok(c) => {
            println!("catalog {dir}: {:?} version {}", c.name, c.version);
            println!(
                "  {} pools, {} staff, {} bans",
                c.pools.len(),
                c.staff.len(),
                c.bans.len()
            );
            for name in &c.order {
                let z = &c.zones[name];
                let maps = c.map_bytes(name);
                let map: usize = maps.iter().map(|b| b.len()).sum();
                println!(
                    "  zone {name:<10} mode {:<8} {} ships / {} players, fill {}, \
                     bots {:.0}%, {} room(s), teams {}, {} map(s), {map} B",
                    z.mode,
                    z.max_ships.unwrap_or(64),
                    z.max_players(),
                    z.fill_target(),
                    z.bot_fill() * 100.0,
                    z.max_rooms(),
                    if z.teams.is_empty() {
                        "free-for-all".to_string()
                    } else {
                        z.teams.join("/")
                    },
                    maps.len()
                );
            }
            println!("  default {:?}", c.fallback_zone().unwrap_or_default());
        }
    }
}

/// `vectorwake-server token`: mint one and print the row to paste. Generated
/// rather than typed, because hashing at rest is only worth anything if the
/// input has entropy, and an operator asked to invent a token invents a short
/// one.
pub fn run_token() {
    // Exactly 32 bytes from the OS. read_exact rather than fs::read, because
    // /dev/urandom has no EOF and reading it to the end allocates until the
    // kernel kills you.
    use std::io::Read;
    let mut raw = [0u8; 32];
    let ok = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut raw))
        .is_ok();
    if !ok {
        println!("could not read 32 bytes of randomness");
        std::process::exit(1);
    }
    let token: String = raw.iter().map(|b| format!("{b:02x}")).collect();
    println!("pool token, shown once:");
    println!();
    println!("  {token}");
    println!();
    println!("Store it and everything follows: the catalog names its digest as");
    println!("env:VW_POOL_DIGEST and fleet.sh derives that from the stored token,");
    println!("so there is nothing to commit and no second value to keep.");
    println!();
    println!("  fleet.sh secrets put VW_POOL_TOKEN");
    println!();
    println!("An arena presents it as VW_TOKEN, which provisioning wires up. A");
    println!("catalog that carries its digest inline instead would say:");
    println!("  token = \"sha256:{}\"", sha256_hex(token.as_bytes()));
}

#[cfg(test)]
mod tests {
    use super::*;

    // Serialised, because these set process-wide environment and Rust runs
    // tests in threads. A second test reading a variable a first has just
    // removed is a flake that only shows up under load.
    static ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn env_indirection_resolves_and_refuses() {
        let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
        // Anything without the prefix is itself, which is every catalog
        // written before this existed.
        assert_eq!(indirect("sha256:abc").unwrap(), "sha256:abc");
        assert_eq!(indirect("").unwrap(), "");

        std::env::set_var("VW_TEST_DIGEST", "sha256:beef");
        assert_eq!(indirect("env:VW_TEST_DIGEST").unwrap(), "sha256:beef");
        std::env::remove_var("VW_TEST_DIGEST");

        // Unset, empty and unnamed are all errors rather than empty values,
        // because empty means "no accounts" and "no pool" to the checks below
        // and neither should be reachable by forgetting something.
        assert!(indirect("env:VW_TEST_DIGEST").is_err());
        std::env::set_var("VW_TEST_DIGEST", "");
        assert!(indirect("env:VW_TEST_DIGEST").is_err());
        std::env::remove_var("VW_TEST_DIGEST");
        assert!(indirect("env:").is_err());
    }

    #[test]
    fn a_resolved_digest_still_has_to_be_a_digest() {
        let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let d = tmp("indirect");
        good(&d);
        let pool = |tok: &str| {
            format!(
                "version = 3\nname = \"t\"\ndefault_zone = \"war\"\n\
                     [[zone]]\nname = \"war\"\n\
                     [[pool]]\nname = \"p\"\ntoken = \"{tok}\"\n"
            )
        };

        write(&d, "catalog.toml", &pool("env:VW_TEST_POOL"));
        std::env::set_var("VW_TEST_POOL", "not-a-digest");
        let e = load(&d).unwrap_err();
        assert!(e.contains("sha256:"), "the digest check still applies: {e}");

        // The indirection is the only thing that moved: a resolved value that
        // is a real digest loads exactly as an inline one does.
        std::env::set_var("VW_TEST_POOL", format!("sha256:{}", sha256_hex(b"letmein")));
        let c = load(&d).expect("loads");
        assert_eq!(
            c.pool_for_token("letmein").map(|p| p.name.as_str()),
            Some("p")
        );

        // And an unset variable names itself, since that is what an operator
        // has to go and set.
        std::env::remove_var("VW_TEST_POOL");
        let e = load(&d).unwrap_err();
        assert!(e.contains("VW_TEST_POOL"), "{e}");

        // The same for the meta key, whose absence means something specific
        // and so must not be reachable by forgetting a variable.
        std::env::set_var("VW_TEST_POOL", format!("sha256:{}", sha256_hex(b"letmein")));
        write(
            &d,
            "catalog.toml",
            &format!(
                "{}\n[meta]\nurl = \"https://x/meta\"\n\
                                            key = \"env:VW_TEST_VERIFY\"\n",
                pool("env:VW_TEST_POOL")
            ),
        );
        let e = load(&d).unwrap_err();
        assert!(e.contains("VW_TEST_VERIFY"), "{e}");
        std::env::set_var("VW_TEST_VERIFY", "0".repeat(64));
        assert_eq!(load(&d).expect("loads").meta.key, "0".repeat(64));

        std::env::remove_var("VW_TEST_POOL");
        std::env::remove_var("VW_TEST_VERIFY");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn sha256_matches_published_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(&b"a".repeat(1000)),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        );
    }

    #[test]
    fn a_token_finds_its_pool_and_a_wrong_one_does_not() {
        let cat = Catalog {
            pools: vec![PoolDef {
                name: "us-east".into(),
                token: format!("sha256:{}", sha256_hex(b"letmein")),
                region: "us-east".into(),
                max_instances: 4,
            }],
            ..Default::default()
        };
        assert_eq!(
            cat.pool_for_token("letmein").map(|p| p.name.as_str()),
            Some("us-east")
        );
        assert!(cat.pool_for_token("letmeout").is_none());
        assert!(cat.pool_for_token("").is_none());
    }

    fn write(dir: &Path, rel: &str, body: &str) {
        let p = dir.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, body).unwrap();
    }

    /// A catalog that loads, in a temp directory, so the rejection tests below
    /// can each break exactly one thing.
    fn good(dir: &Path) {
        write(
            dir,
            "catalog.toml",
            "version = 3\nname = \"t\"\n\
                                    default_zone = \"war\"\n\
                                    [[zone]]\nname = \"war\"\n",
        );
        write(
            dir,
            "zones/war/zone.toml",
            "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\nfill_target = 8\n",
        );
        write(
            dir,
            "zones/war/war.vwmap",
            "not really a map, but it exists",
        );
    }

    fn tmp(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("vw-cat-{tag}"));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn a_good_catalog_loads_and_keeps_its_order() {
        let d = tmp("good");
        good(&d);
        write(
            &d,
            "catalog.toml",
            "version = 3\n\
                                   [[zone]]\nname = \"war\"\n\
                                   [[zone]]\nname = \"duel\"\n",
        );
        write(
            &d,
            "zones/duel/zone.toml",
            "mode = \"duel\"\nmaps = [\"d.vwmap\"]\n\
                                           max_rooms = 100\nfill_target = 2\n\
                                           max_players = 2\n",
        );
        write(&d, "zones/duel/d.vwmap", "x");
        let c = load(&d).expect("loads");
        assert_eq!(c.version, 3);
        assert_eq!(
            c.order,
            vec!["war", "duel"],
            "declared order is the tie-break"
        );
        assert_eq!(c.zone("duel").unwrap().max_rooms(), 100);
        assert_eq!(c.zone("war").unwrap().max_rooms(), 1, "absent means one");
        assert_eq!(
            c.fallback_zone().as_deref(),
            Some("war"),
            "first when none is named"
        );
    }

    #[test]
    fn every_rejection_says_why() {
        // Each case breaks one thing and asserts the message names it, because
        // the reason is the entire value of refusing.
        // A name for the directory, what to break in it, and the word the
        // refusal has to contain.
        type Case<'a> = (&'a str, Box<dyn Fn(&Path)>, &'a str);
        let cases: Vec<Case> = vec![
            (
                "noversion",
                Box::new(|d: &Path| write(d, "catalog.toml", "[[zone]]\nname = \"war\"\n")),
                "version",
            ),
            (
                "badmode",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"soccer\"\nmaps = [\"war.vwmap\"]\n",
                    )
                }),
                "no implementation",
            ),
            (
                "nomap",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"warzone\"\nmaps = [\"gone.vwmap\"]\n",
                    )
                }),
                "missing",
            ),
            (
                "bigships",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\nmax_ships = 300\n",
                    )
                }),
                "300",
            ),
            (
                "zerorooms",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\nmax_rooms = 0\n",
                    )
                }),
                "max_rooms",
            ),
            (
                "fill",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\n\
                                                 fill_target = 40\nmax_players = 8\n",
                    )
                }),
                "fill_target",
            ),
            (
                "dupe",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "catalog.toml",
                        "version = 1\n\
                                          [[zone]]\nname = \"war\"\n\
                                          [[zone]]\nname = \"war\"\n",
                    )
                }),
                "twice",
            ),
            (
                "plaintoken",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "catalog.toml",
                        "version = 1\n\
                                          [[pool]]\nname = \"p\"\ntoken = \"hunter2\"\n\
                                          [[zone]]\nname = \"war\"\n",
                    )
                }),
                "sha256",
            ),
            (
                "namelessteam",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\n\
                                                 teams = [\"Keel\", \"\"]\n",
                    )
                }),
                "no name",
            ),
            (
                "teamsovercap",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "zones/war/zone.toml",
                        "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\n\
                                                 teams = [\"Keel\", \"Vantage\"]\n\
                                                 max_teams = 1\n",
                    )
                }),
                "max_teams",
            ),
            (
                "baddefault",
                Box::new(|d: &Path| {
                    write(
                        d,
                        "catalog.toml",
                        "version = 1\ndefault_zone = \"nope\"\n\
                                          [[zone]]\nname = \"war\"\n",
                    )
                }),
                "default_zone",
            ),
        ];
        for (tag, break_it, wanted) in cases {
            let d = tmp(tag);
            good(&d);
            break_it(&d);
            let err = load(&d).expect_err(&format!("{tag} must be rejected"));
            assert!(
                err.contains(wanted),
                "{tag}: message {err:?} does not name {wanted:?}"
            );
        }
    }

    #[test]
    fn max_ships_above_the_wire_ceiling_is_a_parse_error_not_a_clamp() {
        // u8 in the schema means 300 cannot be represented at all, which is the
        // cheapest possible enforcement of the wire's 255.
        let d = tmp("ceiling");
        good(&d);
        write(
            &d,
            "zones/war/zone.toml",
            "mode = \"warzone\"\nmaps = [\"war.vwmap\"]\nmax_ships = 255\n",
        );
        assert_eq!(load(&d).unwrap().zone("war").unwrap().max_ships, Some(255));
    }

    #[test]
    fn bans_and_capabilities_are_deployment_wide() {
        let d = tmp("staff");
        good(&d);
        write(
            &d,
            "catalog.toml",
            "version = 1\nbans = [\"griefer\"]\n\
                                   [[staff]]\nname = \"chris\"\n\
                                   capabilities = [\"ban\", \"drain\"]\n\
                                   [[zone]]\nname = \"war\"\n",
        );
        let c = load(&d).unwrap();
        assert!(c.is_banned("GRIEFER"), "bans ignore case");
        assert!(!c.is_banned("chris"));
        assert!(c.has_capability("chris", "drain"));
        assert!(
            !c.has_capability("chris", "catalog"),
            "capabilities are explicit"
        );
        assert!(!c.has_capability("nobody", "ban"));
    }
}
