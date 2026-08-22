//! Maps an operator drew, and which of them each zone plays.
//!
//! Two questions live here and they are deliberately separate. A map is a
//! drawing with a name; a rotation is a zone naming some of those drawings in
//! an order. Editing a map nobody plays changes nothing, and reordering a
//! rotation draws nothing.
//!
//! ## Why the database rather than the repository
//!
//! The catalog on disk is the reviewed baseline: it is what a fresh deployment
//! boots with, what the tests run against, and what serves when nothing has
//! been published. What an operator draws in the panel is operational data,
//! the same kind of thing as a ban or an admin flag, and it goes where those
//! went: a table, with an author and a timestamp, changed at a click rather
//! than at a deploy.
//!
//! The alternative was the panel committing to git and CI rebuilding the
//! image, which is a multi-minute wait per map tweak, push credentials on an
//! internet-facing box, and binary blobs accreting in the history of a
//! repository that has already evicted 5 MB of them once.
//!
//! ## The core is the validator
//!
//! Nothing here parses a map. `sim::unpack_map` does, which is the same
//! function the arena and the client call, so a map that saves is a map that
//! loads: the hash in the header has to match the tiles behind it, the size
//! has to be one the array can hold, and the runs have to cover the rect
//! exactly. A hand-rolled check here would be a second opinion, and a second
//! opinion is what a desync is.

use deadpool_postgres::Client;

use super::admin_for;

type Reply = (u16, serde_json::Value);

/// The most a drawn map may weigh. The full arena packs to 28 KB and a match
/// room to under four, so this is roughly four of the largest map anybody has
/// drawn: enough that no honest map meets it, small enough that a bad caller
/// cannot fill the table with one request.
const MAX_BYTES: usize = 128 * 1024;

/// What a name may be. It reaches a filesystem-shaped world at the far end
/// (`zone.toml` names maps as file names) so it stays boring on purpose.
fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 48
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Base64, the same alphabet `fleet::b64` writes, because a map crosses two
/// wires as text: this one, and the catalog the directory hands an arena.
fn unb64(s: &str) -> Option<Vec<u8>> {
    crate::fleet::unb64(s)
}

/// Every published rotation, and the maps those rotations name.
///
/// Read whole rather than per zone: it is a handful of zones and a few hundred
/// kilobytes, it is asked for once per publish, and a partial answer is a
/// catalog that names a map it did not carry.
pub(crate) async fn published(db: &Client) -> Result<crate::fleet::Published, String> {
    let rows = db
        .query("select zone, maps from zone_maps order by zone", &[])
        .await
        .map_err(|e| format!("{e}"))?;
    let mut zones = Vec::new();
    for r in &rows {
        let zone: String = r.get(0);
        let names: Vec<String> = r.get(1);
        let mut maps = Vec::new();
        for n in &names {
            let Some(row) = db
                .query_opt("select bytes from maps where name = $1", &[n])
                .await
                .map_err(|e| format!("{e}"))?
            else {
                // A rotation naming a map that is gone is not a reason to
                // publish nothing: the zone keeps what it had, and the row
                // says so at the next edit.
                continue;
            };
            let bytes: Vec<u8> = row.get(0);
            maps.push(crate::fleet::PublishedMap {
                name: n.clone(),
                bytes_b64: crate::fleet::b64(&bytes),
            });
        }
        if !maps.is_empty() {
            zones.push(crate::fleet::PublishedZone { zone, maps });
        }
    }
    let serial: i64 = db
        .query_one(
            "select coalesce(max(serial), 0) from catalog_publishes",
            &[],
        )
        .await
        .map(|r| r.get(0))
        .unwrap_or(0);
    Ok(crate::fleet::Published {
        serial: serial.max(0) as u32,
        zones,
    })
}

/// Bump the published serial and hand back what it became. The serial is what
/// makes a publish reach an arena: the directory adds it to the catalog's own
/// version, and an arena takes the highest version it is offered.
///
/// A row per publish rather than a counter that is written over, so "when did
/// this fleet last change ground, and who did it" is a question the table can
/// answer.
async fn bump(db: &Client, by: i64, what: &str) -> Result<u32, String> {
    let row = db
        .query_one(
            "insert into catalog_publishes (actor, what) values ($1, $2) returning serial",
            &[&by, &what],
        )
        .await
        .map_err(|e| format!("{e}"))?;
    let serial: i64 = row.get(0);
    Ok(serial.max(0) as u32)
}

/// Push the current publication at the directory, so a rotation lands at the
/// next whistle rather than at the next restart.
///
/// Best effort on purpose. The database is where a publication lives; this is
/// only how it arrives early. A directory that is down or busy misses the push
/// and picks the same state up when it next asks, so a failure here is worth
/// reporting to the operator and not worth refusing the edit over.
pub(crate) async fn push(db: &Client) -> Option<String> {
    let pub_now = match published(db).await {
        Ok(p) => p,
        Err(e) => return Some(format!("cannot read what is published: {e}")),
    };
    let url = super::directory_url();
    let frame = crate::fleet::frame(crate::fleet::O2D_MAPS, &pub_now);
    match crate::directory::ask_with(&url, frame, crate::fleet::D2O_MAPS).await {
        Some(_) => None,
        None => Some(format!("no answer from the directory at {url}")),
    }
}

/// Handle the meta routes owned by maps. `None` leaves the request alone.
pub(super) async fn route(db: &Client, path: &str, body: &serde_json::Value) -> Option<Reply> {
    if !path.starts_with("/v1/admin/map") && path != "/v1/admin/zone-maps" {
        return None;
    }
    let s = |field: &str| {
        body.get(field)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let Some(actor) = admin_for(db, &s("secret")).await else {
        return Some((403, serde_json::json!({ "error": "not an admin" })));
    };

    let reply = match path {
        // Everything drawn, without the drawings: a list is for choosing from,
        // and the bytes are the one thing on the row nobody reading a list
        // needs.
        "/v1/admin/maps" => {
            let rows = match db
                .query(
                    "select m.name, m.w, m.h, octet_length(m.bytes)::int, m.hash,
                            to_char(m.edited at time zone 'utc', 'YYYY-MM-DD HH24:MI'),
                            coalesce(n.call_sign, ''),
                            coalesce(array_agg(z.zone) filter (where z.zone is not null), '{}')
                     from maps m
                     left join names n on n.account = m.author
                     left join zone_maps z on m.name = any(z.maps)
                     group by m.name, m.w, m.h, m.bytes, m.hash, m.edited, n.call_sign
                     order by m.name",
                    &[],
                )
                .await
            {
                Ok(r) => r,
                Err(e) => return Some((500, serde_json::json!({ "error": format!("{e}") }))),
            };
            let maps: Vec<serde_json::Value> = rows
                .iter()
                .map(|r| {
                    let zones: Vec<String> = r.get(7);
                    serde_json::json!({
                        "name": r.get::<_, String>(0),
                        "w": r.get::<_, i32>(1),
                        "h": r.get::<_, i32>(2),
                        "bytes": r.get::<_, i32>(3),
                        "hash": format!("{:08x}", r.get::<_, i64>(4) as u32),
                        "edited": r.get::<_, String>(5),
                        "author": r.get::<_, String>(6),
                        "zones": zones,
                    })
                })
                .collect();
            let rot = match db
                .query("select zone, maps from zone_maps order by zone", &[])
                .await
            {
                Ok(r) => r,
                Err(e) => return Some((500, serde_json::json!({ "error": format!("{e}") }))),
            };
            let rotations: Vec<serde_json::Value> = rot
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "zone": r.get::<_, String>(0),
                        "maps": r.get::<_, Vec<String>>(1),
                    })
                })
                .collect();
            (
                200,
                serde_json::json!({ "maps": maps, "rotations": rotations }),
            )
        }

        // One map, with its bytes, for the editor to open.
        "/v1/admin/map" => {
            let name = s("name");
            match db
                .query_opt("select bytes from maps where name = $1", &[&name])
                .await
            {
                Ok(Some(r)) => {
                    let bytes: Vec<u8> = r.get(0);
                    (
                        200,
                        serde_json::json!({
                            "name": name,
                            "bytes": crate::fleet::b64(&bytes),
                        }),
                    )
                }
                Ok(None) => (404, serde_json::json!({ "error": "no map by that name" })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // Draw one, or draw over one. The bytes are a packed `.vwmap`, and
        // they are checked by unpacking them with the core the arena uses.
        "/v1/admin/map/save" => {
            let name = s("name");
            if !name_ok(&name) {
                return Some((
                    400,
                    serde_json::json!({
                        "error": "a name is 1 to 48 characters of letters, digits, dash \
                                  or underscore"
                    }),
                ));
            }
            let Some(bytes) = unb64(&s("bytes")) else {
                return Some((400, serde_json::json!({ "error": "the map is not base64" })));
            };
            if bytes.is_empty() || bytes.len() > MAX_BYTES {
                return Some((
                    400,
                    serde_json::json!({
                        "error": format!("a map is 1 to {MAX_BYTES} bytes; this one is {}",
                                         bytes.len())
                    }),
                ));
            }
            // The one check that matters, and it is the arena's own.
            let map = match crate::sim::unpack_map(&bytes) {
                Ok(m) => m,
                Err(e) => {
                    return Some((
                        400,
                        serde_json::json!({ "error": format!("this is not a map the core will load: {e}") }),
                    ))
                }
            };
            let (w, h) = (map.w as i32, map.h as i32);
            let hash =
                unsafe { crate::sim::sim_map_hash(&*map as *const crate::sim::sim_map) } as i64;
            let (spawns, per_team) = map.spawns();
            if let Err(e) = db
                .execute(
                    "insert into maps (name, bytes, hash, w, h, author)
                     values ($1, $2, $3, $4, $5, $6)
                     on conflict (name) do update set
                        bytes = excluded.bytes, hash = excluded.hash,
                        w = excluded.w, h = excluded.h,
                        author = excluded.author, edited = now()",
                    &[&name, &bytes, &hash, &w, &h, &actor],
                )
                .await
            {
                return Some((500, serde_json::json!({ "error": format!("{e}") })));
            }
            println!(
                "meta: admin {actor} saved map {name} ({w}x{h}, {} bytes, {spawns} starts)",
                bytes.len()
            );
            // Saving a map a zone already plays is a publish: the drawing
            // changed under a rotation that already names it.
            let serial = match bump(db, actor, &format!("map {name}")).await {
                Ok(n) => n,
                Err(e) => return Some((500, serde_json::json!({ "error": e }))),
            };
            let warn = push(db).await;
            (
                200,
                serde_json::json!({
                    "name": name, "w": w, "h": h, "bytes": bytes.len(),
                    "hash": format!("{:08x}", hash as u32), "spawns": spawns,
                    "starts_per_team": per_team,
                    "serial": serial, "warning": warn,
                }),
            )
        }

        // Remove one, unless a zone is standing on it.
        "/v1/admin/map/delete" => {
            let name = s("name");
            let used: Vec<String> = match db
                .query("select zone from zone_maps where $1 = any(maps)", &[&name])
                .await
            {
                Ok(r) => r.iter().map(|x| x.get::<_, String>(0)).collect(),
                Err(e) => return Some((500, serde_json::json!({ "error": format!("{e}") }))),
            };
            if !used.is_empty() {
                return Some((
                    400,
                    serde_json::json!({
                        "error": format!("{} plays this map; take it out of the rotation first",
                                         used.join(", "))
                    }),
                ));
            }
            match db
                .execute("delete from maps where name = $1", &[&name])
                .await
            {
                Ok(0) => (404, serde_json::json!({ "error": "no map by that name" })),
                Ok(_) => {
                    println!("meta: admin {actor} deleted map {name}");
                    (200, serde_json::json!({ "name": name, "deleted": true }))
                }
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // What a zone plays, in the order it plays them. An empty list is a
        // zone handed back to the catalog on disk, which is the only way back:
        // a rotation that exists overrides the file, and one that does not,
        // does not.
        "/v1/admin/zone-maps" => {
            let zone = s("zone");
            if zone.is_empty() {
                return Some((400, serde_json::json!({ "error": "name a zone" })));
            }
            let names: Vec<String> = body
                .get("maps")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            if names.len() > 16 {
                return Some((
                    400,
                    serde_json::json!({ "error": "sixteen maps is more rotation than a zone needs" }),
                ));
            }
            for n in &names {
                match db
                    .query_opt("select 1 from maps where name = $1", &[n])
                    .await
                {
                    Ok(Some(_)) => {}
                    Ok(None) => {
                        return Some((
                            400,
                            serde_json::json!({ "error": format!("there is no map called {n}") }),
                        ))
                    }
                    Err(e) => return Some((500, serde_json::json!({ "error": format!("{e}") }))),
                }
            }
            let r = if names.is_empty() {
                db.execute("delete from zone_maps where zone = $1", &[&zone])
                    .await
            } else {
                db.execute(
                    "insert into zone_maps (zone, maps, by_account) values ($1, $2, $3)
                     on conflict (zone) do update set
                        maps = excluded.maps, by_account = excluded.by_account, edited = now()",
                    &[&zone, &names, &actor],
                )
                .await
            };
            if let Err(e) = r {
                return Some((500, serde_json::json!({ "error": format!("{e}") })));
            }
            println!(
                "meta: admin {actor} set zone {zone} rotation to [{}]",
                names.join(", ")
            );
            let serial = match bump(db, actor, &format!("zone {zone}")).await {
                Ok(n) => n,
                Err(e) => return Some((500, serde_json::json!({ "error": e }))),
            };
            let warn = push(db).await;
            (
                200,
                serde_json::json!({
                    "zone": zone, "maps": names, "serial": serial, "warning": warn,
                }),
            )
        }

        _ => return None,
    };
    Some(reply)
}
