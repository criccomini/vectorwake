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
    "flags".into()
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
    /// How many of the map's flag stands this zone plays, absent meaning all
    /// of them. Flags can come down but not up: where they stand is the
    /// map's, and a zone asking for more than the ground offers is told so.
    pub flags: Option<u8>,
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
    /// Whether taking a flag picks it up. True is War, where a flag rides its
    /// taker; false is Turf, where a stand changes hands where it stands and
    /// flying over one is the whole of claiming it.
    pub flag_carry: Option<bool>,
    /// Seconds one pilot may hold a flag before it drops on its own, keeping
    /// their side. Absent or zero is no limit. Only a carrying zone reads it.
    pub flag_carry_seconds: Option<u16>,
    /// Greens the room keeps out at once. Absent or zero is a zone with none,
    /// which is every match game: there a pilot flies the build they chose.
    pub greens: Option<u8>,
    /// Seconds one lies there before going out, and seconds between two being
    /// put out.
    pub green_seconds: Option<u16>,
    pub green_every_seconds: Option<u16>,
    /// The ring around a live pilot a green may appear in, in tiles. Outside
    /// the first so it is a trip rather than a gift; inside the second so it
    /// lands on their radar. See docs/design/maps.md for what placing them by
    /// area did instead.
    pub green_near_tiles: Option<i32>,
    pub green_far_tiles: Option<i32>,
    /// Px a green is taken from, past the hull's own edge.
    pub green_radius: Option<i32>,
    /// What a green may be, by kit slot name, and how often each is rolled
    /// against the sum of them all. An empty table is no greens whatever
    /// `greens` says, since there would be nothing for one to be.
    pub green_weights: HashMap<String, u8>,
    /// A door's cycle, in ticks, and how much of it stands open. Zero for the
    /// period leaves every door shut.
    pub door_period: Option<u16>,
    pub door_open: Option<u16>,
    /// A wormhole's pull one tile from its center in px/s/10, falling off as
    /// the square of the distance, and the px beyond which it does not reach
    /// at all. The reach is its own number rather than a consequence of the
    /// strength, so a zone can ask for a well that is strong and small.
    pub wormhole_pull: Option<i32>,
    pub wormhole_range: Option<i32>,
    /// px/s/10 added to a hull's ceiling while a well has hold of it, which is
    /// what lets one throw a ship rather than only aim it. Zero is no extra
    /// speed. Small by design: it applies anywhere in the field.
    pub wormhole_top_speed: Option<i32>,
    /// GravityBombs: whether the pull reaches thrown rounds as well as hulls.
    /// A round counts as thrown when it has a blast, so bombs bend across a
    /// well and bullets do not.
    pub gravity_bombs: Option<bool>,
    /// Per class: a flight row, which is the whole of what a hull is.
    /// Anything left out keeps the baseline's, which is the shipped roster.
    pub ships: Vec<ShipConfig>,
    /// Weapons, by name. A name the baseline already built (`gun`, `bomb`,
    /// `bomb-2` for the rung above it, `charge-1` for the repel, `shrapnel-2`
    /// for what a second rung of shrapnel breaks into) tunes that weapon for
    /// the room; any other name creates one, which another weapon can
    /// splinter into or a charge slot can hold.
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
    /// a bad one is nearly over. Only a match game reads them, and a flag
    /// game reads only the second: its match runs until somebody holds every
    /// flag, so it has no length to state.
    pub match_seconds: Option<u16>,
    pub intermission_seconds: Option<u16>,
    /// Rounds that take a duel. Two by default: a match is then three rounds
    /// at most, and losing the opening exchange leaves a pilot one round from
    /// level rather than watching out a decided fight. Only Duel reads it.
    pub first_to: Option<u16>,
    /// How many kills without dying put a pilot on a streak. Zero turns
    /// streaks off in this zone.
    pub streak_kills: Option<u16>,
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

/// One hull's flight row, which is the whole of what a hull is.
///
/// No weapon and no build. Both used to be here, a ladder and a profile per
/// hull, and a hull that decides what a pilot carries is a hull deciding what
/// they fly: the loadout is the pilot's now and the weapons are the arena's.
/// A zone tunes a weapon by name under `[[arena.weapons]]` and everybody in
/// the room gets it.
///
/// Footprint is deliberately absent too. Every hull spends the same 625
/// square pixels of target area, and the client drawing is fitted to that
/// baseline rectangle, so a zone-only override would break both contracts.
/// See docs/design/ships.md.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, deny_unknown_fields)]
pub struct ShipConfig {
    pub name: String,

    /// This hull's flight, in the settings file's own units: px/s/10, tenths
    /// of the documented thrust unit, 400 to a full turn a second, energy,
    /// and energy a second times ten. What a hull flies at, flat: nobody
    /// upgrades one, so there is no floor and step to write.
    pub speed: Option<i32>,
    pub thrust: Option<i32>,
    pub rotation: Option<i32>,
    pub energy: Option<i32>,
    pub recharge: Option<i32>,
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
            // A file with no [arena] table at all still gets a mode;
            // everything else in there is absent, which the core reads as its
            // own baseline and the flag count reads as the map's own stands.
            arena: ArenaConfig {
                mode: default_mode(),
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
mode = "flags"
flags = 3
bounce = 12

[[arena.ships]]
name = "Apex"
speed = 3700
rotation = 260
"#;

    #[test]
    fn a_zone_file_parses() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert_eq!(c.name, "test zone");
        assert_eq!(c.arena.flags, Some(3));
        assert_eq!(c.arena.bounce, Some(12));
        assert_eq!(c.arena.ships[0].speed, Some(3700));
        assert_eq!(c.arena.ships[0].rotation, Some(260));
    }

    #[test]
    fn omitted_settings_keep_their_defaults() {
        let c: ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        assert_eq!(
            c.arena.bounce, None,
            "an unset setting is absent, so the core's own"
        );
        assert_eq!(c.arena.mode, "flags");
        assert_eq!(c.max_players, 16);
    }

    #[test]
    fn a_table_with_no_mode_in_it_is_still_a_flag_game() {
        // The mode is the arena's own rather than the core's and has a value
        // for a default, whether the file writes an [arena] table or not.
        // Everything else in there is absent when unset, which is a different
        // thing from zero: the flag count absent is every stand the map draws,
        // and zero would be a flag game with no flags in it.
        let c: ZoneConfig = toml::from_str("[arena]\nbounce = 0\n").unwrap();
        assert_eq!(c.arena.mode, "flags");
        assert_eq!(c.arena.flags, None);
        assert_eq!(
            c.arena.bounce,
            Some(0),
            "a wall that gives nothing back is a setting"
        );
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
        assert_eq!(c.arena.mode, "flags");
    }

    #[test]
    fn bans_are_names_and_ignore_case() {
        let c: ZoneConfig = toml::from_str(SAMPLE).unwrap();
        assert!(c.is_banned("GRIEFER"), "bans ignore case");
        assert!(!c.is_banned("chris"));
    }
}
