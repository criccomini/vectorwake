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
use std::path::{Path, PathBuf};

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct ZoneConfig {
    pub name: String,
    pub description: String,
    pub listen: String,
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
    /// Per class, in settings-file units. Empty entries keep the baseline.
    pub ships: Vec<ShipConfig>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct ShipConfig {
    pub name: String,
    pub speed: i32,
    pub thrust: i32,
    pub rotation: i32,
    pub energy: i32,
    pub recharge: i32,
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
        }
    }
}

impl Default for ShipConfig {
    fn default() -> Self {
        ShipConfig { name: String::new(), speed: 0, thrust: 0, rotation: 0, energy: 0, recharge: 0 }
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
        assert_eq!(c.arena.ships[0].speed, 5200);
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
