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
    /// A UDP address to serve WebTransport on, beside the WebSocket listener.
    /// Empty means none. Unlike `listen` there is no cleartext form: QUIC is
    /// TLS or nothing, so `wt_cert` and `wt_key` must name a certificate. Both
    /// take glob patterns, because in the deployed fleet they point into
    /// Caddy's certificate store and the issuer's directory name is Caddy's
    /// business, not ours. VW_WT_LISTEN, VW_WT_CERT and VW_WT_KEY override
    /// these the way the command line overrides `listen`.
    pub wt_listen: String,
    pub wt_cert: String,
    pub wt_key: String,
    pub max_players: usize,
    pub arena: ArenaConfig,
    pub bans: Vec<String>,
}

/// The two keys under `[arena]` that are the arena's own rather than the
/// simulation's, and so have a value rather than an absence for a default.
/// They are named here once and read from both directions: serde uses them
/// for a file that leaves the key out, and ZoneConfig for a file with no
/// `[arena]` table at all.
fn default_mode() -> String { "warzone".into() }
fn default_flags() -> u8 { 4 }

/// Everything the core calls a setting, in the units an operator thinks in:
/// px, px/s/10, energy, ticks, degrees.
///
/// Every field is an option and every option means "leave it alone", so a
/// short file is a legal file and a deleted line goes back to the baseline on
/// the next reload rather than staying in force. Zero is a value like any
/// other -- `bounce = 0` is a wall that eats all the speed that hits it --
/// which is why absent and zero are different things here.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct ArenaConfig {
    #[serde(default = "default_mode")]
    pub mode: String,
    #[serde(default = "default_flags")]
    pub flags: u8,
    /// Restitution out of 16: how much speed a wall gives back.
    pub bounce: Option<i32>,
    /// Speed retained along a wall, out of 16.
    pub friction: Option<i32>,
    pub respawn_delay: Option<u16>,
    pub safe_limit: Option<u16>,
    /// Pilots this room holds, bots included, capped at 255 by the wire: a ship
    /// index is a byte everywhere it appears. Zero or absent keeps the
    /// baseline's 64, which is already four times what the original aimed a
    /// public room at. See docs/architecture/hosting.md.
    pub max_ships: Option<u8>,
    pub prize_delay: Option<u16>,
    pub prize_max: Option<u16>,
    /// Ticks a green waits on the floor to be collected.
    pub prize_life: Option<u16>,
    /// Px a ship picks a green up from.
    pub prize_radius: Option<i32>,
    /// Tile bounds greens spawn within, so a zone can keep them out of its
    /// border or confine them to a middle.
    pub prize_lo: Option<i32>,
    pub prize_hi: Option<i32>,
    /// Px a flag is taken from, and ticks a dropped one is untouchable.
    pub flag_radius: Option<i32>,
    pub flag_drop_cooldown: Option<u16>,
    /// A door's cycle, in ticks, and how much of it stands open. Zero for the
    /// period leaves every door shut.
    pub door_period: Option<u16>,
    pub door_open: Option<u16>,
    /// A wormhole's pull at the mouth in px/s/10, and the px beyond which it
    /// does not reach.
    pub wormhole_pull: Option<i32>,
    pub wormhole_range: Option<i32>,
    /// Per class, in settings-file units. Anything left out keeps the
    /// baseline.
    pub ships: Vec<ShipConfig>,
    /// Weapons, by name. A name the baseline already built (`apex-gun`,
    /// `anvil-bomb`, `anvil-bomb-2` for the rung above it, `charge-1` for the
    /// repel, `shrapnel-2` for what a second rung of shrapnel breaks into)
    /// tunes that weapon; any other name creates one, which a hull can then
    /// carry or another weapon can splinter into.
    pub weapons: Vec<WeaponConfig>,
    /// What one rung of each add-on is worth, by add-on name. Units are the
    /// field each moves: barrels, walls, px of fuse, ticks of stall, px/s/10
    /// of shove. Anything left out keeps the baseline's.
    pub mod_step: HashMap<String, i32>,
    /// Degrees a multifire add-on fans to, when the pattern it transforms has
    /// no spread of its own.
    pub mod_spread: Option<i32>,
    /// How often a green turns out to be each thing, by prize name: the five
    /// stats, `gun-level` and `bomb-level`, and `gun-multi`, `bomb-shrapnel`
    /// and the rest. Relative rather than percentages, and read against the
    /// pool of whichever hull took the green, so this is the shape of the
    /// tree rather than its arithmetic.
    pub prize_weight: HashMap<String, u16>,
    /// Out of a thousand, how often a green takes something back instead of
    /// giving it. Rust can only corrode what a pilot is holding, so it costs
    /// the loaded and never the newly spawned.
    pub rust: Option<u16>,
    /// Greens a ship is handed the moment it spawns, rolled the same way one
    /// found on the floor is. Zero starts pilots plain.
    pub spawn_prizes: Option<u16>,
    /// What a kill adds to the killer's own bounty, so a pilot on a streak
    /// becomes a target without having touched a green.
    pub bounty_per_kill: Option<u16>,
    /// Points on top of the victim's bounty for each flag they were holding.
    pub points_per_flag: Option<u16>,
    /// What a rung of multifire adds to the cost of pulling the trigger, as a
    /// percentage of the shot's own energy and cooldown. The original's are 50
    /// and 100: three rounds for half again the energy and twice the wait.
    pub multi_energy: Option<u16>,
    pub multi_delay: Option<u16>,
    /// Px the proximity fuse widens by for each level of the bomb carrying
    /// it, on top of whatever a rung of the add-on is worth.
    pub prox_step: Option<i32>,
    /// BombExplodeDelay: ticks an armed proximity fuse waits for its target to
    /// start pulling away before it goes off regardless.
    pub prox_delay: Option<u16>,
    /// BombSafety: whether a proximity bomb refuses to fire with an enemy
    /// already inside the fuse's distance.
    pub bomb_safety: Option<bool>,
    /// BBombDamagePercent, per thousand: what a hull whose bombs may bounce
    /// pays for the privilege, on every bomb it throws.
    pub bbomb_damage: Option<u16>,
    /// What a fragment does while it is still inside the hull the bomb went
    /// off against, and how long that lasts in ticks. Without it a bomb lands
    /// twice at point blank: once as a blast, again as a ring of shrapnel
    /// born already touching its victim.
    pub shrap_inactive: Option<i32>,
    pub shrap_inactive_ticks: Option<u16>,
}

/// One hull. Each stat is a ceiling, a floor a fresh ship starts at, and the
/// step one green adds -- the original's MaximumSpeed, InitialSpeed and
/// UpgradeSpeed, under those names.
///
/// Setting only the ceiling moves the floor and the step with it, in
/// proportion, so raising a hull's top speed does not quietly make it start
/// slower relative to where it can get. Setting a floor or a step outright
/// wins over that.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct ShipConfig {
    pub name: String,
    pub speed: Option<i32>,
    pub initial_speed: Option<i32>,
    pub upgrade_speed: Option<i32>,
    pub thrust: Option<i32>,
    pub initial_thrust: Option<i32>,
    pub upgrade_thrust: Option<i32>,
    pub rotation: Option<i32>,
    pub initial_rotation: Option<i32>,
    pub upgrade_rotation: Option<i32>,
    pub energy: Option<i32>,
    pub initial_energy: Option<i32>,
    pub upgrade_energy: Option<i32>,
    pub recharge: Option<i32>,
    pub initial_recharge: Option<i32>,
    pub upgrade_recharge: Option<i32>,
    /// The hull's footprint, px from the point it turns about: reach past
    /// the nose, behind the tail, and to either side. The collision box
    /// follows the ship's heading, so these are the shape a wall stops and
    /// a weapon has to reach. Defaults are measured off the drawn hulls in
    /// sim/src/baseline.c; a zone overriding one should keep the diagonal
    /// (sqrt of fore^2 + width^2) inside 23 px or its maps owe the roster
    /// gaps the shipped ones were never checked for.
    pub fore: Option<i32>,
    pub aft: Option<i32>,
    pub width: Option<i32>,
    /// What the two triggers fire: the ladder, by weapon name, first rung
    /// first. One name is a hull that never levels and `bomb = []` takes the
    /// rack out. A hull keeps its own ladder unless the file says otherwise.
    pub gun: Option<Vec<String>>,
    pub bomb: Option<Vec<String>>,
    /// Which add-ons this hull may hold on each trigger, and how many rungs
    /// of each: `gun_mods = { multi = 2, freeze = 1 }`. This is the roster's
    /// half of the tech tree -- shrapnel belongs to bombers, and no run of
    /// luck with the greens should change that.
    pub gun_mods: HashMap<String, u8>,
    pub bomb_mods: HashMap<String, u8>,
    /// How many of each charge this hull may carry, by slot: `charges =
    /// [3, 3]` is three repels and three bursts. Slots left off keep the
    /// baseline's, and zero is a hull that never gets one.
    pub charges: Vec<u8>,
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
    /// Px from a hull centre that sets it off. 0 is contact, which is a bullet.
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
    /// Px/s/10 everything hostile inside the reach is set to. Not an impulse
    /// and not distance-scaled: the far edge is shoved as hard as the middle.
    /// Damage is optional; this is the whole of a repel.
    pub push: Option<i32>,
    /// Ticks a shoved ship may fly at that speed before its own ceiling takes
    /// over. Without it the shove is undone on the next tick, since `push` is
    /// meant to be faster than any hull.
    pub push_time: Option<u16>,
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

impl Default for ZoneConfig {
    fn default() -> Self {
        ZoneConfig {
            name: "vectorwake".into(),
            description: "an unconfigured zone".into(),
            listen: "127.0.0.1:9010".into(),
            map: String::new(),
            tls_cert: String::new(),
            tls_key: String::new(),
            wt_listen: String::new(),
            wt_cert: String::new(),
            wt_key: String::new(),
            max_players: 16,
            // A file with no [arena] table at all still gets a mode and a set
            // of flags; everything else in there is absent, which the core
            // reads as its own baseline.
            arena: ArenaConfig {
                mode: default_mode(), flags: default_flags(), ..Default::default()
            },
            bans: Vec::new(),
        }
    }
}

impl ZoneConfig {
    pub fn is_banned(&self, name: &str) -> bool {
        self.bans.iter().any(|b| b.eq_ignore_ascii_case(name))
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
"#;

    #[test]
    fn a_zone_file_parses() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert_eq!(c.name, "test zone");
        assert_eq!(c.arena.flags, 3);
        assert_eq!(c.arena.bounce, Some(12));
        assert_eq!(c.arena.ships[0].speed, Some(5200));
    }

    #[test]
    fn omitted_settings_keep_their_defaults() {
        let c: ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        assert_eq!(c.arena.bounce, None, "an unset setting is absent, so the core's own");
        assert_eq!(c.arena.mode, "warzone");
        assert_eq!(c.max_players, 16);
    }

    #[test]
    fn a_table_with_no_mode_in_it_is_still_a_warzone() {
        // The two keys that are the arena's rather than the core's have a
        // value for a default, whether the file writes an [arena] table or
        // not. Everything else in there is absent when unset, which is a
        // different thing from zero.
        let c: ZoneConfig = toml::from_str("[arena]\nbounce = 0\n").unwrap();
        assert_eq!(c.arena.mode, "warzone");
        assert_eq!(c.arena.flags, 4);
        assert_eq!(c.arena.bounce, Some(0), "a wall that gives nothing back is a setting");
    }

    #[test]
    fn a_key_in_the_wrong_table_is_an_error_not_a_shrug() {
        // TOML puts a bare key into the most recent table, so a `bans` line
        // written below [[arena.ships]] becomes a field of that ship. Silently
        // ignoring it would leave an operator convinced they had banned
        // somebody.
        let misplaced = r#"
name = "z"
[[arena.ships]]
name = "Apex"
bans = ["griefer"]
"#;
        assert!(toml::from_str::<ZoneConfig>(misplaced).is_err(),
                "a misplaced key must be reported");
    }

    /// The zone we ship is the documentation for this format, and unknown
    /// keys are an error, so a renamed setting breaks it. Better here than on
    /// an operator's first run.
    #[test]
    fn the_reference_zone_parses() {
        let src = include_str!("../../zone/zone.toml");
        let c: ZoneConfig = toml::from_str(src).expect("the shipped zone file parses");
        assert_eq!(c.arena.ships.len(), 2);
        assert_eq!(c.arena.mode, "warzone");
    }

    #[test]
    fn bans_are_names_and_ignore_case() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert!(c.is_banned("GRIEFER"), "bans ignore case");
        assert!(!c.is_banned("chris"));
    }
}
