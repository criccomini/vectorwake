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
    pub listen: String,
    /// PEM certificate chain and private key. Set both and the zone serves
    /// wss instead of ws, which a page delivered over https is required to
    /// use: browsers refuse a plain ws socket from a secure origin, and
    /// loopback is the only exception.
    /// The maps this zone plays, relative to the zone directory, in the order
    /// a room rotates through them. Empty uses the built-in arena, so a zone
    /// with no map is still a zone.
    pub maps: Vec<String>,
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
fn default_mode() -> String {
    "warzone".into()
}
fn default_flags() -> u8 {
    4
}

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
    /// Zero, or absent, spawns on the map's own spawn tiles. Above zero
    /// ignores them and drops a ship on a random tile within this many of the
    /// point instead, redrawn on every death, which is what stops a roster
    /// stacking on one tile. Size it by how many ships will share it, measured
    /// as seconds of bullet flight to the nearest enemy: Alpha runs 60 for a
    /// bit over three seconds at the 51 ships one of its rooms holds.
    pub spawn_radius: Option<u16>,
    /// Whether a client marks the map's spawn tiles. Absent draws them.
    /// Ignored by the client when `spawn_radius` is set, since then nobody
    /// arrives on them.
    pub show_spawns: Option<bool>,
    pub safe_limit: Option<u16>,
    /// Pilots this room holds, bots included, capped at 255 by the wire: a ship
    /// index is a byte everywhere it appears. Zero or absent keeps the
    /// baseline's 64, which is already four times what the original aimed a
    /// public room at. See docs/architecture/hosting.md.
    pub max_ships: Option<u8>,
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
    /// Per class: a footprint and a ladder. Anything left out keeps the
    /// baseline.
    pub ships: Vec<ShipConfig>,
    /// What a kit may hold here, for every hull alike.
    pub kit: KitConfig,
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
    /// A match game's two clocks, in seconds. Three minutes of play and
    /// fifteen seconds of podium is what `docs/design/match-game.md`
    /// settles on: long enough for a match to have a shape, short enough that
    /// a bad one is nearly over. Melee and Ladder both read them.
    pub match_seconds: Option<u16>,
    pub intermission_seconds: Option<u16>,
    /// Ladder series and run rules. Missing values are single-life play, a
    /// two-rung loss, checkpoints every five rungs, and ordinary checkpointed
    /// play. An interval of zero disables new checkpoints.
    pub ladder_first_to: Option<u16>,
    pub ladder_loss_drop: Option<u32>,
    pub ladder_checkpoint_interval: Option<u32>,
    /// What a pilot is worth the moment they spawn, and what each kill on a
    /// run adds to that. A bounty is the run rather than the kit: the kit is
    /// the same every life, so it is what a pilot has done since their last
    /// death that prices their head.
    pub bounty_base: Option<u16>,
    pub bounty_per_kill: Option<u16>,
    /// Points on top of the victim's bounty for each flag they were holding.
    pub points_per_flag: Option<u16>,
    /// How many kills without dying put a pilot on a streak, and what being on
    /// one adds to their bounty. Zero kills turns streaks off in this zone.
    pub streak_kills: Option<u16>,
    pub streak_bounty: Option<u16>,
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
    /// Connection-quality policy. Values are deliberately operator-facing:
    /// milliseconds and percentages rather than simulation units.
    pub lag: LagConfig,
}

/// Connection telemetry and stale-input limits used by the authoritative arena.
///
/// Round trip, jitter and snapshot loss are diagnostic. Gameplay restrictions
/// depend only on input packets the server has or has not received.
#[derive(Deserialize, Clone, Debug)]
#[serde(default, deny_unknown_fields)]
pub struct LagConfig {
    /// Rolling window for diagnostic path measurements.
    pub sample_ticks: u32,
    /// Exact current window reported as missed input deadlines.
    pub input_sample_ticks: u32,
    /// Time outside the combat lane before its diagnostic loss sample expires.
    pub combat_idle_ticks: u32,
    /// Consecutive ticks without any input packet before a pilot sits out.
    pub spectate_silence_ticks: u32,
}

impl Default for LagConfig {
    fn default() -> Self {
        LagConfig {
            sample_ticks: 500,
            input_sample_ticks: 50,
            combat_idle_ticks: 500,
            spectate_silence_ticks: 500,
        }
    }
}

/// One hull's zone-selectable weapon ladders.
///
/// Footprint is deliberately absent. Every hull spends the same 625 square
/// pixels of target area, and the client drawing is fitted to that baseline
/// rectangle. A zone-only override would break both contracts. Flight and kit
/// depth are shared for the same reason: thirty points buys the same ship
/// whichever silhouette carries it. See docs/design/ships.md.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct ShipConfig {
    pub name: String,
    /// What the two triggers fire: the ladder, by weapon name, first rung
    /// first. One name is a hull that never levels and `bomb = []` takes the
    /// rack out. A hull keeps its own ladder unless the file says otherwise.
    ///
    /// How far a pilot may climb one is `arena.kit` below, and it follows the
    /// longest ladder in the roster, so a zone that shortens one hull's has
    /// not quietly made a purchase worthless everywhere else.
    pub gun: Option<Vec<String>>,
    pub bomb: Option<Vec<String>>,
}

/// What a kit may hold in this arena, over the flat slot space.
///
/// One section for the zone, where this was a row per hull. Seven rows meant
/// an upgrade could be bought and then refused by the hull somebody wanted to
/// fly it on, and it meant the shelf was whatever the roster happened
/// to allow rather than whatever the game has. Anything left out keeps the
/// baseline's, which is the union of what the seven rows used to allow.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct KitConfig {
    /// Which add-ons a kit may hold on each trigger, and how many rungs of
    /// each: `gun_mods = { multi = 2, barrel = 2 }`. An add-on left out of a
    /// map that names any is a slot this arena does not have.
    pub gun_mods: HashMap<String, u8>,
    pub bomb_mods: HashMap<String, u8>,
    /// How many of each charge a kit may carry, by slot: `charges = [3, 3]`
    /// is three repels and three bursts. Slots left off keep the baseline's,
    /// and zero is a charge this arena does not have.
    pub charges: Vec<u8>,
}

/// One weapon: what a trigger makes, and what one projectile of it is. The
/// core keeps those in two tables and a zone file does not, because every
/// weapon anybody has wanted is one of each, and a name is easier to write
/// than a pair of indices.
///
/// Every field is optional and means "leave it alone". Tuning `anvil-bomb`
/// to bounce is two lines; the rest of the bomb stays the bomb.
#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
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
    /// Px from a hull center that sets it off. 0 is contact, which is a bullet.
    pub trigger: Option<i32>,
    /// Whether running out of life counts as arriving. A round whose whole
    /// life is a timer wants it; a bomb that crosses the arena untouched did
    /// not arrive.
    pub expire_ends: Option<bool>,
    /// A weapon fired where this one ended, by name.
    pub splinter: Option<String>,
    // What happens there.
    /// Energy at the center.
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
            listen: "127.0.0.1:9010".into(),
            maps: Vec::new(),
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
                mode: default_mode(),
                flags: default_flags(),
                ..Default::default()
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
        (
            ConfigWatcher {
                path,
                mtime,
                current,
            },
            err,
        )
    }

    /// Returns Some(message) when the file changed and was re-read.
    pub fn poll(&mut self) -> Option<String> {
        let m = std::fs::metadata(&self.path)
            .and_then(|m| m.modified())
            .ok();
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
bomb = []

[arena.kit]
gun_mods = { multi = 2, barrel = 2 }
"#;

    #[test]
    fn a_zone_file_parses() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert_eq!(c.name, "test zone");
        assert_eq!(c.arena.flags, 3);
        assert_eq!(c.arena.bounce, Some(12));
        assert_eq!(c.arena.ships[0].bomb, Some(Vec::new()));
        assert_eq!(c.arena.kit.gun_mods.get("barrel"), Some(&2));
    }

    #[test]
    fn omitted_settings_keep_their_defaults() {
        let c: ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        assert_eq!(
            c.arena.bounce, None,
            "an unset setting is absent, so the core's own"
        );
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
        assert_eq!(
            c.arena.bounce,
            Some(0),
            "a wall that gives nothing back is a setting"
        );
    }

    #[test]
    fn ladder_rules_parse_as_arena_settings() {
        let src = r#"
[arena]
mode = "ladder"
ladder_first_to = 5
ladder_loss_drop = 1
ladder_checkpoint_interval = 4
"#;
        let c: ZoneConfig = toml::from_str(src).expect("Ladder settings parse");
        assert_eq!(c.arena.mode, "ladder");
        assert_eq!(c.arena.ladder_first_to, Some(5));
        assert_eq!(c.arena.ladder_loss_drop, Some(1));
        assert_eq!(c.arena.ladder_checkpoint_interval, Some(4));
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
        assert!(
            toml::from_str::<ZoneConfig>(misplaced).is_err(),
            "a misplaced key must be reported"
        );
    }

    /// The zone we ship is the documentation for this format, and unknown
    /// keys are an error, so a renamed setting breaks it. Better here than on
    /// an operator's first run.
    #[test]
    fn the_reference_zone_parses() {
        let src = include_str!("../../zone/zone.toml");
        let c: ZoneConfig = toml::from_str(src).expect("the shipped zone file parses");
        assert!(
            c.arena.ships.is_empty(),
            "the reference zone tunes no hull: they differ by footprint alone"
        );
        assert_eq!(c.arena.mode, "warzone");
    }

    #[test]
    fn bans_are_names_and_ignore_case() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert!(c.is_banned("GRIEFER"), "bans ignore case");
        assert!(!c.is_banned("chris"));
    }
}
