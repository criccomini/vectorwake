//! Zone configuration.
//!
//! A zone is a directory with a `zone.toml` in it, the shape
//! docs/architecture/content-pipeline.md describes. Everything an operator
//! tunes lives there rather than in our source, which is the whole claim
//! behind zones-are-content.
//!
//! Settings reload without a restart, because operators tune constantly and
//! taking an arena down to change a bounce factor is how you lose players.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct ZoneConfig {
    pub name: String,
    pub description: String,
    pub listen: String,
    /// PEM certificate chain and private key. Set both and the zone serves
    /// wss instead of ws, which a page delivered over https is required to
    /// use: browsers refuse a plain ws socket from a secure origin, and
    /// loopback is the only exception.
    /// A map file, relative to the zone directory. Empty uses the built-in
    /// arena, so a zone with no map is still a zone.
    pub map: String,
    pub tls_cert: String,
    pub tls_key: String,
    pub max_players: usize,
    pub arena: ArenaConfig,
    pub staff: Vec<Staff>,
    pub bans: Vec<String>,
    pub bots: Vec<BotConfig>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct ArenaConfig {
    pub mode: String,
    pub flags: u8,
    /// Restitution out of 16: how much speed a wall gives back.
    pub bounce: i32,
    /// Speed retained along a wall, out of 16.
    pub friction: i32,
    pub respawn_delay: u16,
    pub prize_delay: u16,
    pub prize_max: u16,
    /// Per class, in settings-file units. Anything left out keeps the
    /// baseline.
    pub ships: Vec<ShipConfig>,
    /// Weapons, by name. A name the baseline already built (`apex-gun`,
    /// `anvil-bomb`, `anvil-bomb-2` for the rung above it) tunes that weapon;
    /// any other name creates one, which a hull can then carry or another
    /// weapon can splinter into.
    pub weapons: Vec<WeaponConfig>,
    /// What one rung of each add-on is worth, by add-on name. Units are the
    /// field each moves: barrels, walls, px of fuse, ticks of stall, px/s/10
    /// of shove. Anything left out keeps the baseline's.
    pub mod_step: HashMap<String, i32>,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct ShipConfig {
    pub name: String,
    pub speed: Option<i32>,
    pub thrust: Option<i32>,
    pub rotation: Option<i32>,
    pub energy: Option<i32>,
    pub recharge: Option<i32>,
    /// What the two triggers fire, by weapon name. Setting this replaces the
    /// hull's whole ladder with that one weapon, so it stops levelling; a
    /// hull keeps its own unless the file says otherwise, and `bomb = ""`
    /// takes the rack out.
    pub gun: Option<String>,
    pub bomb: Option<String>,
    /// Which add-ons this hull may hold on each trigger, and how many rungs
    /// of each: `gun_mods = { multi = 2, freeze = 1 }`. This is the roster's
    /// half of the tech tree -- shrapnel belongs to bombers, and no run of
    /// luck with the greens should change that.
    pub gun_mods: HashMap<String, u8>,
    pub bomb_mods: HashMap<String, u8>,
}

/// One weapon: what a trigger makes, and what one projectile of it is. The
/// core keeps those in two tables and a zone file does not, because every
/// weapon anybody has wanted is one of each, and a name is easier to write
/// than a pair of indices.
///
/// Every field is optional and means "leave it alone". Tuning `anvil-bomb`
/// to bounce is two lines; the rest of the bomb stays the bomb.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct WeaponConfig {
    pub name: String,
    // How it flies.
    /// px/s/10, as ship speeds are.
    pub speed: Option<i32>,
    /// Ticks before it runs out.
    pub life: Option<u16>,
    /// "end", "bounce" or "pass".
    pub on_wall: Option<String>,
    /// Walls survived, when bouncing.
    pub bounces: Option<u8>,
    // What counts as arriving somewhere.
    /// Px from a hull that sets it off. 0 is contact, which is a bullet.
    pub trigger: Option<i32>,
    /// Whether running out of life counts as arriving. A mine's whole life
    /// is its timer; a bomb that crosses the arena untouched did not arrive.
    pub expire_ends: Option<bool>,
    /// A weapon fired where this one ended, by name.
    pub splinter: Option<String>,
    // What happens there.
    /// Energy at the centre.
    pub damage: Option<i32>,
    /// Px of blast, falling off to nothing at the rim. 0 lands on one hull.
    pub blast: Option<i32>,
    /// Px/s/10 shoved outward at the centre. Damage is optional; this is
    /// the whole of a repel.
    pub push: Option<i32>,
    /// Ticks of suppressed recharge on whoever it reaches.
    pub stall: Option<u16>,
    // What one pull of the trigger makes.
    pub count: Option<u8>,
    /// Degrees between them. A full turn divided by the count is a rosette.
    pub spread: Option<i32>,
    /// Energy the shot costs -- the shot's, not each projectile's.
    pub energy: Option<i32>,
    /// Ticks of cooldown.
    pub delay: Option<u16>,
    /// Px/s/10 backwards on the ship that fired.
    pub recoil: Option<i32>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct Staff {
    pub name: String,
    /// Capability names, per docs/research/asss-server.md: authority is a
    /// set of powers rather than a rank.
    pub capabilities: Vec<String>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct BotConfig {
    pub name: String,
    pub class: u8,
    pub team: u8,
    pub skill: f32,
    pub x: i32,
    pub y: i32,
}

impl Default for ZoneConfig {
    fn default() -> Self {
        ZoneConfig {
            name: "vectorwake".into(),
            description: "an unconfigured zone".into(),
            listen: "127.0.0.1:9010".into(),
            map: String::new(),
            tls_cert: String::new(),
            tls_key: String::new(),
            max_players: 16,
            arena: ArenaConfig::default(),
            staff: Vec::new(),
            bans: Vec::new(),
            bots: Vec::new(),
        }
    }
}

impl Default for ArenaConfig {
    fn default() -> Self {
        ArenaConfig {
            mode: "warzone".into(),
            flags: 4,
            bounce: 10,
            friction: 14,
            respawn_delay: 300,
            prize_delay: 100,
            prize_max: 20,
            ships: Vec::new(),
            weapons: Vec::new(),
            mod_step: HashMap::new(),
        }
    }
}

impl Default for Staff {
    fn default() -> Self {
        Staff { name: String::new(), capabilities: Vec::new() }
    }
}

impl Default for BotConfig {
    fn default() -> Self {
        BotConfig { name: String::new(), class: 0, team: 1, skill: 0.5, x: 512, y: 512 }
    }
}

impl ZoneConfig {
    pub fn is_banned(&self, name: &str) -> bool {
        self.bans.iter().any(|b| b.eq_ignore_ascii_case(name))
    }

    pub fn has_capability(&self, name: &str, cap: &str) -> bool {
        self.staff
            .iter()
            .any(|s| s.name.eq_ignore_ascii_case(name) && s.capabilities.iter().any(|c| c == cap))
    }
}

/// Watches a config file and reloads it when it changes on disk.
pub struct ConfigWatcher {
    path: PathBuf,
    mtime: Option<std::time::SystemTime>,
    pub current: ZoneConfig,
}

impl ConfigWatcher {
    pub fn load(path: impl AsRef<Path>) -> (Self, Option<String>) {
        let path = path.as_ref().to_path_buf();
        let (current, err) = read(&path);
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        (ConfigWatcher { path, mtime, current }, err)
    }

    /// Returns Some(message) when the file changed and was re-read.
    pub fn poll(&mut self) -> Option<String> {
        let m = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        if m == self.mtime {
            return None;
        }
        self.mtime = m;
        let (cfg, err) = read(&self.path);
        match err {
            // A broken edit keeps the running configuration rather than
            // dropping an arena because somebody fumbled a bracket.
            Some(e) => Some(format!("config reload failed, keeping the old one: {e}")),
            None => {
                self.current = cfg;
                Some("config reloaded".into())
            }
        }
    }
}

fn read(path: &Path) -> (ZoneConfig, Option<String>) {
    match std::fs::read_to_string(path) {
        Ok(text) => match toml::from_str::<ZoneConfig>(&text) {
            Ok(c) => (c, None),
            Err(e) => (ZoneConfig::default(), Some(e.to_string())),
        },
        Err(e) => (ZoneConfig::default(), Some(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
name = "test zone"
listen = "0.0.0.0:9100"
bans = ["griefer"]

[arena]
mode = "warzone"
flags = 3
bounce = 12

[[arena.ships]]
name = "Apex"
speed = 5200

[[staff]]
name = "chris"
capabilities = ["ban", "setmode"]

[[bots]]
name = "Kestrel"
class = 0
skill = 0.4
"#;

    #[test]
    fn a_zone_file_parses() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert_eq!(c.name, "test zone");
        assert_eq!(c.arena.flags, 3);
        assert_eq!(c.arena.bounce, 12);
        assert_eq!(c.arena.ships[0].speed, Some(5200));
        assert_eq!(c.bots[0].name, "Kestrel");
    }

    #[test]
    fn omitted_settings_keep_their_defaults() {
        let c: ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        assert_eq!(c.arena.bounce, 10, "an unset value is the baseline, not zero");
        assert_eq!(c.arena.mode, "warzone");
        assert_eq!(c.max_players, 16);
    }

    #[test]
    fn a_key_in_the_wrong_table_is_an_error_not_a_shrug() {
        // TOML puts a bare key into the most recent table, so a `bans` line
        // written below [[staff]] becomes staff.bans. Silently ignoring it
        // would leave an operator convinced they had banned somebody.
        let misplaced = r#"
name = "z"
[[staff]]
name = "chris"
capabilities = []
bans = ["griefer"]
"#;
        assert!(toml::from_str::<ZoneConfig>(misplaced).is_err(),
                "a misplaced key must be reported");
    }

    #[test]
    fn bans_and_capabilities_are_names_not_ranks() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert!(c.is_banned("GRIEFER"), "bans ignore case");
        assert!(!c.is_banned("chris"));
        assert!(c.has_capability("chris", "ban"));
        assert!(!c.has_capability("chris", "shutdown"), "capabilities are explicit");
        assert!(!c.has_capability("nobody", "ban"));
    }
}
