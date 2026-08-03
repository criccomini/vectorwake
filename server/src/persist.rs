//! Persistence.
//!
//! Ratings and the rated event log outlive the process. Everything else an
//! arena holds is a round in progress and dies with it, deliberately.
//!
//! This is a JSON file rather than the SQLite in the architecture document.
//! At one zone's worth of pilots it is the simplest thing that fully meets
//! the requirement, and the shape it stores is the event log, so moving to a
//! database later is a writer swap rather than a migration of meaning.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Every field defaults. A missing key must cost the file its key and nothing
/// else: without this, adding `games` would have made every record already on
/// disk fail to parse, and `open` treats an unparseable record as an empty one,
/// so the first deploy after the change would have quietly wiped the ladder.
#[derive(Serialize, Deserialize, Default, Clone)]
#[serde(default)]
pub struct Record {
    pub ratings: HashMap<String, f64>,
    /// Rated deaths behind each rating. A rating without its game count is a
    /// number with no confidence attached: the pilot reads as still placing,
    /// and their K goes back to a newcomer's, so the next death moves them
    /// four times as far as it should. This file used to hold the number and
    /// not the count, which meant every deploy un-settled everybody.
    pub games: HashMap<String, u32>,
}

pub struct Store {
    path: PathBuf,
    pub record: Record,
    dirty: bool,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Self {
        let path = path.as_ref().to_path_buf();
        let record = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Store { path, record, dirty: false }
    }

    pub fn rating(&self, who: &str) -> Option<f64> {
        self.record.ratings.get(who).copied()
    }

    pub fn set_rating(&mut self, who: &str, value: f64) {
        self.record.ratings.insert(who.to_string(), value);
        self.dirty = true;
    }

    pub fn games(&self, who: &str) -> u32 {
        self.record.games.get(who).copied().unwrap_or(0)
    }

    /// The count is monotone, so a room that saw fewer deaths than the record
    /// already holds cannot lower it. Two rooms of the same process both write
    /// here, and the same name in two rooms is a bot's, whose count is whatever
    /// that room has fought.
    pub fn set_games(&mut self, who: &str, value: u32) {
        let e = self.record.games.entry(who.to_string()).or_insert(0);
        if value > *e {
            *e = value;
            self.dirty = true;
        }
    }

    /// Write through a temporary file so a crash mid-write cannot leave a
    /// half-written record where a whole one used to be.
    pub fn flush(&mut self) -> std::io::Result<()> {
        if !self.dirty {
            return Ok(());
        }
        let text = serde_json::to_string_pretty(&self.record)?;
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.path)?;
        self.dirty = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("vw-{name}-{}.json", std::process::id()))
    }

    #[test]
    fn a_record_survives_a_restart() {
        let p = temp("persist");
        let _ = std::fs::remove_file(&p);
        {
            let mut s = Store::open(&p);
            s.set_rating("chris", 1337.5);
            s.set_games("chris", 40);
            s.flush().unwrap();
        }
        let s2 = Store::open(&p);
        assert_eq!(s2.rating("chris"), Some(1337.5));
        assert_eq!(s2.games("chris"), 40, "a rating without its game count is unearned");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn a_game_count_never_goes_backwards() {
        let p = temp("games");
        let _ = std::fs::remove_file(&p);
        let mut s = Store::open(&p);
        s.set_games("chris", 40);
        s.set_games("chris", 3);
        assert_eq!(s.games("chris"), 40, "a quieter room must not un-settle a pilot");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn a_missing_or_corrupt_file_starts_empty_rather_than_failing() {
        let p = temp("corrupt");
        std::fs::write(&p, "{ not json").unwrap();
        let s = Store::open(&p);
        assert!(s.record.ratings.is_empty(), "a broken file must not stop the zone");
        let _ = std::fs::remove_file(&p);
    }
}
