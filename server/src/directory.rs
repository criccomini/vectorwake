//! The zone directory.
//!
//! A player needs to find a game before they can join one. This is the piece
//! that answers "what is running right now": a small service that holds a
//! list of zone addresses, asks each one how it is doing, and hands the
//! answers to anybody who asks.
//!
//! It speaks the same WebSocket protocol the zones do, so a client already
//! able to talk to a zone needs no second transport to talk to the directory,
//! and a zone needs no HTTP endpoint bolted onto it. A directory is not
//! authoritative over anything and holds no state worth losing: if it is down,
//! a player who knows an address can still connect straight to it.

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message;

/// What a zone says about itself.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Status {
    pub name: String,
    pub description: String,
    /// Humans, then AI. A room that is all bots is still worth joining, and a
    /// player deserves to know which kind of room it is before they arrive.
    pub players: u32,
    pub bots: u32,
    pub arenas: u32,
}

/// One row of the directory as a client sees it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    pub address: String,
    /// None until the first successful poll, and again after a zone stops
    /// answering. A listed zone that is down is information, not an error.
    pub status: Option<Status>,
}

#[derive(Debug, Deserialize)]
struct ZoneRef {
    address: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DirectoryConfig {
    #[serde(default = "default_name")]
    name: String,
    #[serde(default)]
    zone: Vec<ZoneRef>,
}

fn default_name() -> String {
    "vectorwake directory".into()
}

pub struct Directory {
    pub name: String,
    pub entries: Vec<Entry>,
}

impl Directory {
    /// Read the zone list. A missing or unreadable file yields an empty
    /// directory rather than a failure: an operator running one zone should
    /// not need a directory at all.
    pub fn load(path: &str) -> (Self, Option<String>) {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => {
                return (
                    Directory { name: default_name(), entries: Vec::new() },
                    Some(e.to_string()),
                )
            }
        };
        match toml::from_str::<DirectoryConfig>(&text) {
            Ok(c) => (
                Directory {
                    name: c.name,
                    entries: c
                        .zone
                        .into_iter()
                        .map(|z| Entry { address: z.address, status: None })
                        .collect(),
                },
                None,
            ),
            Err(e) => (
                Directory { name: default_name(), entries: Vec::new() },
                Some(e.to_string()),
            ),
        }
    }

    pub fn as_json(&self) -> String {
        serde_json::to_string(&self.entries).unwrap_or_else(|_| "[]".into())
    }
}

/// Ask one zone how it is doing. Any failure is simply "no answer": a zone
/// being down, slow, or speaking nonsense are the same thing to a directory.
pub async fn poll(address: &str, request: u8) -> Option<Status> {
    let connect = tokio_tungstenite::connect_async(address);
    let (mut ws, _) = tokio::time::timeout(std::time::Duration::from_secs(4), connect)
        .await
        .ok()?
        .ok()?;
    ws.send(Message::Binary(vec![request])).await.ok()?;

    // One reply, or nothing. A zone that wants to send other traffic first is
    // welcome to; we read until the status arrives or the budget runs out.
    let deadline = std::time::Duration::from_secs(4);
    let read = async {
        while let Some(Ok(msg)) = ws.next().await {
            if let Message::Binary(b) = msg {
                if b.len() > 1 && b[0] == STATUS_REPLY {
                    return serde_json::from_slice::<Status>(&b[1..]).ok();
                }
            }
        }
        None
    };
    tokio::time::timeout(deadline, read).await.ok().flatten()
}

/// The reply byte a zone tags its status with. Kept here so the directory and
/// the zone cannot disagree about it.
pub const STATUS_REPLY: u8 = 8;
pub const STATUS_REQUEST: u8 = 4;

/// Refresh every zone, concurrently. Slow zones cannot hold up the sweep.
pub async fn refresh(dir: &Arc<Mutex<Directory>>) {
    let addresses: Vec<String> = {
        let d = dir.lock().await;
        d.entries.iter().map(|e| e.address.clone()).collect()
    };
    let polled: Vec<(String, Option<Status>)> =
        futures_util::future::join_all(addresses.into_iter().map(|a| async move {
            let s = poll(&a, STATUS_REQUEST).await;
            (a, s)
        }))
        .await;

    let map: HashMap<String, Option<Status>> = polled.into_iter().collect();
    let mut d = dir.lock().await;
    for e in d.entries.iter_mut() {
        if let Some(s) = map.get(&e.address) {
            e.status = s.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_directory_file_parses() {
        let toml = r#"
            name = "first light"
            [[zone]]
            address = "ws://127.0.0.1:9040"
            [[zone]]
            address = "ws://127.0.0.1:9041"
        "#;
        let c: DirectoryConfig = toml::from_str(toml).expect("parses");
        assert_eq!(c.name, "first light");
        assert_eq!(c.zone.len(), 2);
    }

    #[test]
    fn a_missing_file_is_an_empty_directory_not_a_failure() {
        let (d, err) = Directory::load("/nonexistent/directory.toml");
        assert!(err.is_some(), "the reason is reported");
        assert!(d.entries.is_empty(), "and the zone still runs");
    }

    #[test]
    fn a_zone_that_never_answered_is_listed_as_unknown() {
        // A listed zone being down is information a player wants, not a row
        // to hide.
        let d = Directory {
            name: "d".into(),
            entries: vec![Entry { address: "ws://x".into(), status: None }],
        };
        let json = d.as_json();
        assert!(json.contains("\"status\":null"), "got {json}");
    }
}
