//! The operator surface, served by a directory on its own port.
//!
//! docs/architecture/admin.md splits this three ways, and the split is what keeps
//! it from becoming the central authority the rest of the design avoids. Seeing
//! is free: it is the view an arena server already reads. Editing is producing a
//! new catalog version, which is authorship rather than runtime. And the few
//! genuinely imperative verbs travel down the registration socket that already
//! exists, scoped so a directory can only command arenas registered with it.
//!
//! Plain HTTP here rather than the WebSocket protocol, because the client is a
//! browser and a static page wants `fetch`. The page itself is one file with no
//! external anything, so it opens from disk as readily as from a directory.

use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;

use crate::directory::Directory;

/// The page. One file, no dependencies, no build step: tables, a form, and a
/// fetch loop. It is deliberately not part of the Defold client, which draws
/// vector art and text on purpose and had its last DOM text input removed.
const PAGE: &str = include_str!("admin.html");

/// Bearer token for every mutating request, read from the environment. A human
/// holds this one, which makes it different in kind from a pool token: the powers
/// behind it include editing what every arena in the fleet runs.
fn admin_token() -> String {
    std::env::var("VW_ADMIN_TOKEN").unwrap_or_default()
}

pub fn spawn(dir: Arc<Mutex<Directory>>) {
    let addr = std::env::var("VW_ADMIN_LISTEN").unwrap_or_default();
    if addr.is_empty() {
        return;
    }
    if admin_token().is_empty() {
        println!("VW_ADMIN_LISTEN is set but VW_ADMIN_TOKEN is empty; admin stays off");
        println!("  an unauthenticated fleet editor is not a feature");
        return;
    }
    tokio::spawn(async move {
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                println!("admin: cannot bind {addr}: {e}");
                return;
            }
        };
        println!("admin surface on http://{addr}");
        println!("  read-only without a token; every verb needs VW_ADMIN_TOKEN");
        loop {
            let Ok((stream, peer)) = listener.accept().await else { continue };
            let dir = dir.clone();
            tokio::spawn(async move {
                if let Err(e) = serve(stream, dir).await {
                    let _ = e;
                }
                let _ = peer;
            });
        }
    });
}

/// One request. A hand-rolled HTTP/1.1 responder, because the whole surface is
/// three routes and pulling in a framework to serve them would be the larger
/// change.
async fn serve(mut s: tokio::net::TcpStream, dir: Arc<Mutex<Directory>>) -> std::io::Result<()> {
    let mut buf = vec![0u8; 16 * 1024];
    let n = s.read(&mut buf).await?;
    if n == 0 {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&buf[..n]).to_string();
    let mut lines = text.split("\r\n");
    let request = lines.next().unwrap_or("");
    let mut parts = request.split(' ');
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/");

    // The token arrives as a header, so it stays out of logs and out of the URL
    // bar. Compared in constant time like every other credential here.
    let mut given = String::new();
    for l in text.split("\r\n") {
        if let Some(v) = l.strip_prefix("x-vw-token: ").or_else(|| l.strip_prefix("X-VW-Token: ")) {
            given = v.trim().to_string();
        }
    }
    let body = text.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");

    let (status, ctype, out) = match (method, path) {
        ("GET", "/") | ("GET", "/index.html") => ("200 OK", "text/html; charset=utf-8", PAGE.to_string()),
        ("GET", "/api/fleet") => {
            let d = dir.lock().await;
            let payload = serde_json::json!({
                "catalog": {
                    "name": d.catalog.name,
                    "version": d.catalog.version,
                    "zones": d.catalog.order,
                    "bans": d.catalog.bans,
                    "pools": d.catalog.pools.iter().map(|p| serde_json::json!({
                        "name": p.name, "region": p.region,
                        "max_instances": p.max_instances,
                    })).collect::<Vec<_>>(),
                    "staff": d.catalog.staff.iter().map(|s| serde_json::json!({
                        "name": s.name, "capabilities": s.capabilities,
                    })).collect::<Vec<_>>(),
                },
                // The same view an arena server reads, unverified rows included:
                // an operator wants to see a misconfigured instance, which is
                // exactly what a player must not be offered.
                "instances": d.view().instances,
                "browse": d.browse(),
                "audit": d.audit,
            });
            ("200 OK", "application/json", payload.to_string())
        }
        ("POST", p) if p.starts_with("/api/command") => {
            let want = admin_token();
            if want.is_empty() || !ct_eq(&given, &want) {
                ("403 Forbidden", "application/json",
                 r#"{"error":"bad or missing X-VW-Token"}"#.to_string())
            } else {
                let req: serde_json::Value =
                    serde_json::from_str(body).unwrap_or(serde_json::Value::Null);
                let instance = req.get("instance").and_then(|v| v.as_str()).unwrap_or("");
                let verb = req.get("verb").and_then(|v| v.as_str()).unwrap_or("");
                let args = req.get("args").and_then(|v| v.as_str()).unwrap_or("");
                let actor = req.get("actor").and_then(|v| v.as_str()).unwrap_or("");
                let mut d = dir.lock().await;
                // The verb is checked before the capability, so a typo reads as a
                // typo rather than as a permissions problem. The verb list is
                // public, so saying which exist leaks nothing.
                if !crate::fleet::VERBS.contains(&verb) {
                    ("400 Bad Request", "application/json",
                     serde_json::json!({
                        "error": format!("no such verb {verb:?}; have {:?}", crate::fleet::VERBS)
                     }).to_string())
                // Named powers rather than ranks, which is ASSS's model and the
                // first caller `has_capability` has ever had.
                } else if !d.catalog.has_capability(actor, verb) {
                    (
                        "403 Forbidden",
                        "application/json",
                        serde_json::json!({
                            "error": format!("{actor:?} does not hold the {verb:?} capability")
                        })
                        .to_string(),
                    )
                } else {
                    let ok = d.command(instance, verb, args, actor);
                    ("200 OK", "application/json",
                     serde_json::json!({"sent": ok}).to_string())
                }
            }
        }
        _ => ("404 Not Found", "text/plain", "no such route\n".to_string()),
    };

    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        out.len()
    );
    s.write_all(head.as_bytes()).await?;
    s.write_all(out.as_bytes()).await?;
    s.flush().await
}

fn ct_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_is_self_contained() {
        // A static page that fetches a script from somewhere is a page that stops
        // working when somewhere is down, and an admin surface is exactly the
        // thing wanted during an outage.
        assert!(!PAGE.contains("src=\"http"), "no external script");
        assert!(!PAGE.contains("href=\"http"), "no external stylesheet");
        assert!(PAGE.contains("/api/fleet"), "it reads the view");
    }

    #[test]
    fn token_comparison_rejects_empty_and_mismatched() {
        assert!(!ct_eq("", ""), "an empty token is never valid");
        assert!(!ct_eq("abc", "abd"));
        assert!(!ct_eq("abc", "abcd"));
        assert!(ct_eq("abc", "abc"));
    }
}
