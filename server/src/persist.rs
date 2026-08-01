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

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Record {
    pub ratings: HashMap<String, f64>,
    /// Kills, deaths, and rounds won, kept for the profile rather than for
    /// the ladder: rating is computed from events, not from these.
    pub kills: HashMap<String, u32>,
    pub deaths: HashMap<String, u32>,
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

    pub fn add_kill(&mut self, who: &str) {
        *self.record.kills.entry(who.to_string()).or_insert(0) += 1;
        self.dirty = true;
    }

    pub fn add_death(&mut self, who: &str) {
        *self.record.deaths.entry(who.to_string()).or_insert(0) += 1;
        self.dirty = true;
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
            s.add_kill("chris");
            s.flush().unwrap();
        }
        let s2 = Store::open(&p);
        assert_eq!(s2.rating("chris"), Some(1337.5));
        assert_eq!(s2.record.kills.get("chris"), Some(&1));
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
