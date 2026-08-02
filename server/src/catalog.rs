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
    /// Relative to the zone's own directory.
    pub map: String,
    /// Pilots a room holds, bots included; the core clamps to SIM_MAX_SHIPS.
    pub max_ships: Option<u8>,
    /// Humans of those seats.
    pub max_players: Option<usize>,
    /// The concentration rule: another room or instance opens only when every
    /// live one is at or above this.
    pub fill_target: Option<usize>,
    /// The most simulations one process may hold for this zone. A ceiling, not
    /// a count: rooms appear on demand and are reclaimed when they empty.
    pub max_rooms: Option<usize>,
    /// How many teams the mode may use. One is a free-for-all.
    pub teams: Option<u8>,
    /// smaller | random | none.
    pub balance: String,
    pub private_teams: bool,
    pub arena: crate::config::ArenaConfig,
}

impl Default for ZoneDef {
    fn default() -> Self {
        ZoneDef {
            description: String::new(),
            mode: "arena".into(),
            map: String::new(),
            max_ships: None,
            max_players: None,
            fill_target: None,
            max_rooms: None,
            teams: None,
            balance: "smaller".into(),
            private_teams: false,
            arena: crate::config::ArenaConfig::default(),
        }
    }
}

/// See `ZoneDef::fill_target`.
pub const DEFAULT_FILL_TARGET: usize = 15;

impl ZoneDef {
    /// Fifteen, which is `General:DesiredPlaying`'s default in ASSS and the
    /// number thirty years of the original settled on for a public room. It also
    /// has to sit under the default `max_players`, or a zone that sets neither
    /// would fail its own validation.
    pub fn fill_target(&self) -> usize {
        self.fill_target.unwrap_or(DEFAULT_FILL_TARGET)
    }
    pub fn max_rooms(&self) -> usize {
        self.max_rooms.unwrap_or(1).max(1)
    }
    pub fn max_players(&self) -> usize {
        self.max_players.unwrap_or(16)
    }
    pub fn teams(&self) -> u8 {
        self.teams.unwrap_or(2).max(1)
    }
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(deny_unknown_fields)]
pub struct PoolDef {
    pub name: String,
    /// `sha256:` followed by 64 hex digits. Never a plaintext secret.
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
    pub order: Vec<String>,
    pub zones: HashMap<String, ZoneDef>,
    /// Where each zone's files live, for resolving its map.
    pub dirs: HashMap<String, PathBuf>,
}

impl Catalog {
    pub fn is_banned(&self, name: &str) -> bool {
        self.bans.iter().any(|b| b.eq_ignore_ascii_case(name))
    }

    pub fn has_capability(&self, name: &str, cap: &str) -> bool {
        self.staff.iter().any(|s| {
            s.name.eq_ignore_ascii_case(name) && s.capabilities.iter().any(|c| c == cap)
        })
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

    /// The map bytes for a zone, read from its own directory.
    pub fn map_bytes(&self, name: &str) -> Option<Vec<u8>> {
        let z = self.zones.get(name)?;
        if z.map.is_empty() {
            return None;
        }
        std::fs::read(self.dirs.get(name)?.join(&z.map)).ok()
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

/// Load and validate. Every `Err` is a reason an operator can act on, which is
/// the whole point of this module: docs/architecture/catalog.md lists the
/// rejections and this is where they live.
pub fn load(dir: impl AsRef<Path>) -> Result<Catalog, String> {
    let dir = dir.as_ref();
    let head_path = dir.join("catalog.toml");
    let text = std::fs::read_to_string(&head_path)
        .map_err(|e| format!("{}: {e}", head_path.display()))?;
    let head: Head =
        toml::from_str(&text).map_err(|e| format!("{}: {e}", head_path.display()))?;

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

    let mut cat = Catalog {
        version: head.version,
        name: head.name,
        description: head.description,
        default_zone: head.default_zone,
        bans: head.bans,
        staff: head.staff,
        pools: head.pool,
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
        let z: ZoneDef = toml::from_str(&ztext)
            .map_err(|e| format!("zone {:?}: {}: {e}", r.name, zpath.display()))?;
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
    // A mode that falls back silently is how `arena.mode` became a dead key.
    if !crate::modes::exists(&z.mode) {
        return Err(format!(
            "zone {name:?}: mode {:?} has no implementation; {}",
            z.mode,
            crate::modes::NAMES.join(", ")
        ));
    }
    if !matches!(z.balance.as_str(), "smaller" | "random" | "none") {
        return Err(format!(
            "zone {name:?}: balance {:?} is not smaller, random or none",
            z.balance
        ));
    }
    if let Some(t) = z.teams {
        if t == 0 {
            return Err(format!(
                "zone {name:?}: teams must be at least 1; one team is a \
                 free-for-all, none is nothing"
            ));
        }
    }
    if z.map.is_empty() {
        return Err(format!("zone {name:?}: map is required"));
    }
    if !zdir.join(&z.map).exists() {
        return Err(format!(
            "zone {name:?}: map {:?} is missing; the zone would be listed and \
             unplayable",
            z.map
        ));
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(cat.pool_for_token("letmein").map(|p| p.name.as_str()), Some("us-east"));
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
        write(dir, "catalog.toml", "version = 3\nname = \"t\"\n\
                                    default_zone = \"war\"\n\
                                    [[zone]]\nname = \"war\"\n");
        write(dir, "zones/war/zone.toml",
              "mode = \"warzone\"\nmap = \"war.vwmap\"\nfill_target = 8\n");
        write(dir, "zones/war/war.vwmap", "not really a map, but it exists");
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
        write(&d, "catalog.toml", "version = 3\n\
                                   [[zone]]\nname = \"war\"\n\
                                   [[zone]]\nname = \"duel\"\n");
        write(&d, "zones/duel/zone.toml", "mode = \"duel\"\nmap = \"d.vwmap\"\n\
                                           max_rooms = 100\nfill_target = 2\n\
                                           max_players = 2\n");
        write(&d, "zones/duel/d.vwmap", "x");
        let c = load(&d).expect("loads");
        assert_eq!(c.version, 3);
        assert_eq!(c.order, vec!["war", "duel"], "declared order is the tie-break");
        assert_eq!(c.zone("duel").unwrap().max_rooms(), 100);
        assert_eq!(c.zone("war").unwrap().max_rooms(), 1, "absent means one");
        assert_eq!(c.fallback_zone().as_deref(), Some("war"), "first when none is named");
    }

    #[test]
    fn every_rejection_says_why() {
        // Each case breaks one thing and asserts the message names it, because
        // the reason is the entire value of refusing.
        let cases: Vec<(&str, Box<dyn Fn(&Path)>, &str)> = vec![
            ("noversion", Box::new(|d: &Path| {
                write(d, "catalog.toml", "[[zone]]\nname = \"war\"\n")
            }), "version"),
            ("badmode", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml", "mode = \"soccer\"\nmap = \"war.vwmap\"\n")
            }), "no implementation"),
            ("nomap", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml", "mode = \"warzone\"\nmap = \"gone.vwmap\"\n")
            }), "missing"),
            ("bigships", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml",
                      "mode = \"warzone\"\nmap = \"war.vwmap\"\nmax_ships = 300\n")
            }), "300"),
            ("zerorooms", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml",
                      "mode = \"warzone\"\nmap = \"war.vwmap\"\nmax_rooms = 0\n")
            }), "max_rooms"),
            ("fill", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml", "mode = \"warzone\"\nmap = \"war.vwmap\"\n\
                                                 fill_target = 40\nmax_players = 8\n")
            }), "fill_target"),
            ("dupe", Box::new(|d: &Path| {
                write(d, "catalog.toml", "version = 1\n\
                                          [[zone]]\nname = \"war\"\n\
                                          [[zone]]\nname = \"war\"\n")
            }), "twice"),
            ("plaintoken", Box::new(|d: &Path| {
                write(d, "catalog.toml", "version = 1\n\
                                          [[pool]]\nname = \"p\"\ntoken = \"hunter2\"\n\
                                          [[zone]]\nname = \"war\"\n")
            }), "sha256"),
            ("badbalance", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml", "mode = \"warzone\"\nmap = \"war.vwmap\"\n\
                                                 balance = \"alphabetical\"\n")
            }), "balance"),
            ("zeroteams", Box::new(|d: &Path| {
                write(d, "zones/war/zone.toml", "mode = \"warzone\"\nmap = \"war.vwmap\"\n\
                                                 teams = 0\n")
            }), "teams"),
            ("baddefault", Box::new(|d: &Path| {
                write(d, "catalog.toml", "version = 1\ndefault_zone = \"nope\"\n\
                                          [[zone]]\nname = \"war\"\n")
            }), "default_zone"),
        ];
        for (tag, break_it, wanted) in cases {
            let d = tmp(tag);
            good(&d);
            break_it(&d);
            let err = load(&d).expect_err(&format!("{tag} must be rejected"));
            assert!(err.contains(wanted),
                    "{tag}: message {err:?} does not name {wanted:?}");
        }
    }

    #[test]
    fn max_ships_above_the_wire_ceiling_is_a_parse_error_not_a_clamp() {
        // u8 in the schema means 300 cannot be represented at all, which is the
        // cheapest possible enforcement of the wire's 255.
        let d = tmp("ceiling");
        good(&d);
        write(&d, "zones/war/zone.toml",
              "mode = \"warzone\"\nmap = \"war.vwmap\"\nmax_ships = 255\n");
        assert_eq!(load(&d).unwrap().zone("war").unwrap().max_ships, Some(255));
    }

    #[test]
    fn bans_and_capabilities_are_deployment_wide() {
        let d = tmp("staff");
        good(&d);
        write(&d, "catalog.toml", "version = 1\nbans = [\"griefer\"]\n\
                                   [[staff]]\nname = \"chris\"\n\
                                   capabilities = [\"ban\", \"drain\"]\n\
                                   [[zone]]\nname = \"war\"\n");
        let c = load(&d).unwrap();
        assert!(c.is_banned("GRIEFER"), "bans ignore case");
        assert!(!c.is_banned("chris"));
        assert!(c.has_capability("chris", "drain"));
        assert!(!c.has_capability("chris", "catalog"), "capabilities are explicit");
        assert!(!c.has_capability("nobody", "ban"));
    }
}
