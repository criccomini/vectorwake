//! Rated-seat leases and the event projections they protect.

use deadpool_postgres::{Client, Transaction};

use crate::catalog::Catalog;
use crate::rating;

use super::DEFAULT_CLASS;

type Reply = (u16, serde_json::Value);

/// Handle the meta routes owned by settlement. Returning `None` leaves the
/// request for another domain.
pub(super) async fn route(
    catalog: &Catalog,
    db: &mut Client,
    path: &str,
    body: &serde_json::Value,
) -> Option<Reply> {
    let s = |field: &str| {
        body.get(field)
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string()
    };

    let reply = match path {
        // The cross-fleet seat lock for rated play. A claim is also a renewal
        // when the same session already owns the row. An abandoned row expires
        // after three minutes, beyond the arena's quiet-socket timeout.
        "/v1/rated-session/claim" => {
            if catalog.pool_for_token(&s("pool_token")).is_none() {
                return Some((403, serde_json::json!({ "error": "unknown pool token" })));
            }
            let Some(account) = body
                .get("account")
                .and_then(|value| value.as_i64())
                .filter(|value| *value > 0)
            else {
                return Some((
                    400,
                    serde_json::json!({ "error": "a rated session needs an account" }),
                ));
            };
            let session = s("session");
            if session.is_empty() {
                return Some((
                    400,
                    serde_json::json!({ "error": "a rated session needs an id" }),
                ));
            }
            let instance = s("instance");
            let zone = s("zone");
            let standing = db
                .query_opt("select banned from accounts where id = $1", &[&account])
                .await;
            match standing {
                Ok(Some(row)) if row.get::<_, bool>(0) => {
                    return Some((403, serde_json::json!({ "error": "banned" })));
                }
                Ok(Some(_)) => {}
                Ok(None) => {
                    return Some((403, serde_json::json!({ "error": "no such account" })));
                }
                Err(error) => {
                    return Some((
                        500,
                        serde_json::json!({
                            "error": format!("cannot read account: {error}")
                        }),
                    ));
                }
            }
            let row = db
                .query_opt(
                    "insert into active_rated_sessions
                         (account, session, instance, zone, touched)
                     values ($1, $2, $3, $4, now())
                     on conflict (account) do update
                     set session = excluded.session,
                         instance = excluded.instance,
                         zone = excluded.zone,
                         touched = now()
                     where active_rated_sessions.session = excluded.session
                        or active_rated_sessions.touched < now() - interval '180 seconds'
                     returning session",
                    &[&account, &session, &instance, &zone],
                )
                .await;
            match row {
                Ok(row) => {
                    let claimed = row.is_some();
                    let ratings = if claimed {
                        match db
                            .query(
                                "select class, rating, games from ratings where account = $1",
                                &[&account],
                            )
                            .await
                        {
                            Ok(rows) => rows
                                .iter()
                                .map(|row| {
                                    serde_json::json!({
                                        "class": row.get::<_, String>(0),
                                        "rating": row.get::<_, f64>(1),
                                        "games": row.get::<_, i32>(2).max(0),
                                    })
                                })
                                .collect::<Vec<_>>(),
                            Err(error) => {
                                return Some((
                                    500,
                                    serde_json::json!({
                                        "error": format!("cannot read rating: {error}")
                                    }),
                                ));
                            }
                        }
                    } else {
                        Vec::new()
                    };
                    (
                        200,
                        serde_json::json!({ "claimed": claimed, "ratings": ratings }),
                    )
                }
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }

        // A live watcher holds no exclusive rated seat, but a fleet ban still
        // has to close its connection. Arenas poll this narrow route while a
        // token-backed account is connected without a rated lease.
        "/v1/account-standing" => {
            if catalog.pool_for_token(&s("pool_token")).is_none() {
                return Some((403, serde_json::json!({ "error": "unknown pool token" })));
            }
            let Some(account) = body
                .get("account")
                .and_then(|value| value.as_i64())
                .filter(|value| *value > 0)
            else {
                return Some((
                    400,
                    serde_json::json!({ "error": "standing needs an account" }),
                ));
            };
            match db
                .query_opt("select banned from accounts where id = $1", &[&account])
                .await
            {
                Ok(Some(row)) if row.get::<_, bool>(0) => {
                    (403, serde_json::json!({ "error": "banned" }))
                }
                Ok(Some(_)) => (200, serde_json::json!({ "active": true })),
                Ok(None) => (403, serde_json::json!({ "error": "no such account" })),
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }

        "/v1/rated-session/release" => {
            if catalog.pool_for_token(&s("pool_token")).is_none() {
                return Some((403, serde_json::json!({ "error": "unknown pool token" })));
            }
            let Some(account) = body
                .get("account")
                .and_then(|value| value.as_i64())
                .filter(|value| *value > 0)
            else {
                return Some((
                    400,
                    serde_json::json!({ "error": "a rated session needs an account" }),
                ));
            };
            let session = s("session");
            match db
                .execute(
                    "delete from active_rated_sessions where account = $1 and session = $2",
                    &[&account, &session],
                )
                .await
            {
                Ok(_) => (200, serde_json::json!({ "released": true })),
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }

        // An arena handing off what it rated. The log is the durable artifact
        // and the ratings table is a projection of it, per
        // docs/design/rating.md.
        "/v1/events" => {
            if catalog.pool_for_token(&s("pool_token")).is_none() {
                return Some((403, serde_json::json!({ "error": "unknown pool token" })));
            }
            let class = {
                let class = s("class");
                if class.is_empty() {
                    DEFAULT_CLASS.to_string()
                } else {
                    class
                }
            };
            let zone = s("zone");
            let instance = s("instance");
            let empty = Vec::new();
            let events = body
                .get("events")
                .and_then(|value| value.as_array())
                .unwrap_or(&empty);
            let mut stored = 0usize;
            let mut rejected = Vec::new();
            let mut failed = Vec::new();
            for (index, event) in events.iter().enumerate() {
                if let Err(error) = validate_rated_event(event) {
                    rejected.push(serde_json::json!({
                        "index": index,
                        "error": error,
                    }));
                    continue;
                }
                match ingest(db, &class, &zone, &instance, event).await {
                    Ok(()) => stored += 1,
                    // A database failure is retryable. Events already committed
                    // in this batch are protected by their ids when the arena
                    // posts the batch again.
                    Err(error) => failed.push(error),
                }
            }
            if failed.is_empty() {
                if !rejected.is_empty() {
                    println!(
                        "meta: {} of {} rated events refused: {}",
                        rejected.len(),
                        events.len(),
                        rejected[0]["error"].as_str().unwrap_or("invalid event")
                    );
                }
                (
                    200,
                    serde_json::json!({ "stored": stored, "rejected": rejected }),
                )
            } else {
                println!(
                    "meta: {} of {} rated events could not be stored: {}",
                    failed.len(),
                    events.len(),
                    failed[0]
                );
                (
                    500,
                    serde_json::json!({
                        "stored": stored,
                        "rejected": rejected,
                        "failed": failed.len(),
                        "error": failed[0],
                    }),
                )
            }
        }

        // The other thing an arena hands off: what happened to the pilots in
        // it. Same envelope and same auth as the rated events above, a
        // different table at the far end, and no projection to keep in step,
        // because this log is not a source of truth for anything the game
        // reads back. See docs/architecture/meta-layer.md.
        "/v1/pilot-events" => {
            if catalog.pool_for_token(&s("pool_token")).is_none() {
                return Some((403, serde_json::json!({ "error": "unknown pool token" })));
            }
            let zone = s("zone");
            let instance = s("instance");
            let empty = Vec::new();
            let events = body
                .get("events")
                .and_then(|value| value.as_array())
                .unwrap_or(&empty);
            let mut stored = 0usize;
            let mut failed: Vec<String> = Vec::new();
            for event in events {
                match ingest_pilot(db, &zone, &instance, event).await {
                    Ok(()) => stored += 1,
                    Err(error) => failed.push(error),
                }
            }
            if failed.is_empty() {
                (200, serde_json::json!({ "stored": stored }))
            } else {
                println!(
                    "meta: {} of {} pilot events refused: {}",
                    failed.len(),
                    events.len(),
                    failed[0]
                );
                (
                    500,
                    serde_json::json!({
                        "stored": stored,
                        "failed": failed.len(),
                        "error": failed[0]
                    }),
                )
            }
        }

        _ => return None,
    };

    Some(reply)
}

/// One rated death: appended to the log, then applied to the projection.
///
/// The projection moves by the delta the arena computed rather than being
/// recomputed from the number it saw, which is what lets two instances of one
/// zone rate the same pilot without disagreeing. Addition commutes, so the
/// order two arenas arrive in does not change where a rating lands.
///
/// Log and projection move in one transaction. They are not equals, since the
/// log is the durable artifact and the rating is derived from it, but an event
/// that landed without moving anybody would leave the two disagreeing until
/// somebody recomputed, and nothing here is worth that.
///
/// Delivery is at-least-once. A spool retries a whole batch when any of it
/// fails, and a batch that committed under a lost reply is posted again, so
/// the same event arriving twice is ordinary weather rather than a fault.
/// The arena-minted id is the umbrella: the log refuses the second copy, and
/// a refused copy must not touch the projection, or every retry would bend
/// somebody's rating by a delta the log recorded once.
pub(super) fn validate_rated_event(event: &serde_json::Value) -> Result<(), String> {
    let victim = event
        .get("victim")
        .and_then(|value| value.as_i64())
        .filter(|account| *account > 0)
        .ok_or("invalid victim")?;
    event
        .get("id")
        .and_then(|value| value.as_i64())
        .ok_or("no event id")?;
    event
        .get("tick")
        .and_then(|value| value.as_u64())
        .filter(|tick| *tick <= u32::MAX as u64)
        .ok_or("invalid tick")?;
    event
        .get("victim_kind")
        .and_then(|value| value.as_u64())
        .filter(|kind| *kind <= 1)
        .ok_or("invalid victim kind")?;

    let before = event
        .get("victim_before")
        .and_then(|value| value.as_f64())
        .filter(|rating| rating.is_finite())
        .ok_or("invalid victim rating before event")?;
    let after = event
        .get("victim_after")
        .and_then(|value| value.as_f64())
        .filter(|rating| rating.is_finite())
        .ok_or("invalid victim rating after event")?;
    let movement = after - before;
    if !movement.is_finite() || movement.abs() > rating::EVENT_CAP + 1e-6 {
        return Err("victim rating movement exceeds the event bound".into());
    }

    if let Some(killer) = event.get("killer").filter(|value| !value.is_null()) {
        if !killer.as_i64().is_some_and(|account| account > 0) {
            return Err("invalid killer".into());
        }
    }
    let credits = event
        .get("credits")
        .and_then(|value| value.as_array())
        .filter(|credits| !credits.is_empty() && credits.len() < 256)
        .ok_or("invalid credits")?;
    let mut accounts = std::collections::HashSet::new();
    let mut total_weight = 0.0;
    for credit in credits {
        let account = credit
            .get("account")
            .and_then(|value| value.as_i64())
            .filter(|account| *account > 0 && *account != victim)
            .ok_or("invalid credited account")?;
        if !accounts.insert(account) {
            return Err("duplicate credited account".into());
        }
        let weight = credit
            .get("weight")
            .and_then(|value| value.as_f64())
            .filter(|weight| weight.is_finite() && *weight > 0.0 && *weight <= 1.0)
            .ok_or("invalid credit weight")?;
        total_weight += weight;
        let before = credit
            .get("before")
            .and_then(|value| value.as_f64())
            .filter(|rating| rating.is_finite())
            .ok_or("invalid credit rating before event")?;
        let after = credit
            .get("after")
            .and_then(|value| value.as_f64())
            .filter(|rating| rating.is_finite())
            .ok_or("invalid credit rating after event")?;
        let movement = after - before;
        if !movement.is_finite() || movement.abs() > rating::EVENT_CAP + 1e-6 {
            return Err("credit rating movement exceeds the event bound".into());
        }
    }
    if !total_weight.is_finite() || total_weight > 1.0 + 1e-6 {
        return Err("credit weights exceed one event".into());
    }
    Ok(())
}

async fn ingest(
    db: &mut Client,
    class: &str,
    zone: &str,
    instance: &str,
    event: &serde_json::Value,
) -> Result<(), String> {
    validate_rated_event(event)?;
    let victim = event
        .get("victim")
        .and_then(|value| value.as_i64())
        .unwrap_or(0);
    if victim == 0 {
        return Err("no victim".into());
    }
    // Refused rather than taken as-is, because an event without an id cannot
    // be deduplicated, and one arena quietly exempt from exactly-once is the
    // failure this field exists to end.
    let Some(event_id) = event.get("id").and_then(|value| value.as_i64()) else {
        return Err("no event id".into());
    };
    let before = event
        .get("victim_before")
        .and_then(|value| value.as_f64())
        .unwrap_or(0.0);
    let after = event
        .get("victim_after")
        .and_then(|value| value.as_f64())
        .unwrap_or(0.0);
    let tick = event
        .get("tick")
        .and_then(|value| value.as_i64())
        .unwrap_or(0);
    let victim_kind = event
        .get("victim_kind")
        .and_then(|value| value.as_i64())
        .unwrap_or(0) as i16;
    let killer = event.get("killer").and_then(|value| value.as_i64());
    // Absent means keep, which is the safe direction: an arena too old to
    // send this is not one whose events should quietly expire.
    let bots_only = event
        .get("bots_only")
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    let empty = Vec::new();
    let credits = event
        .get("credits")
        .and_then(|value| value.as_array())
        .unwrap_or(&empty);

    let db = db
        .transaction()
        .await
        .map_err(|error| format!("cannot open a transaction: {error}"))?;

    let stored = db
        .execute(
            "insert into rated_events
               (event_id, class, zone, instance, tick, victim, victim_kind,
                victim_before, victim_after, credits, bots_only, killer)
             values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
             on conflict (event_id) do nothing",
            &[
                &event_id,
                &class,
                &zone,
                &instance,
                &tick,
                &victim,
                &victim_kind,
                &before,
                &after,
                &serde_json::Value::Array(credits.clone()),
                &bots_only,
                &killer,
            ],
        )
        .await
        .map_err(|error| format!("cannot store event: {error}"))?;
    // A retry finding its work already done. Reported as success, because the
    // spool is asking "is this filed", and it is; applying the deltas again is
    // what this function exists to never do.
    if stored == 0 {
        return db
            .commit()
            .await
            .map_err(|error| format!("cannot commit: {error}"));
    }

    apply(&db, victim, class, after - before).await?;
    for credit in credits {
        let account = credit
            .get("account")
            .and_then(|value| value.as_i64())
            .unwrap_or(0);
        if account == 0 {
            continue;
        }
        let delta = credit
            .get("after")
            .and_then(|value| value.as_f64())
            .unwrap_or(0.0)
            - credit
                .get("before")
                .and_then(|value| value.as_f64())
                .unwrap_or(0.0);
        apply(&db, account, class, delta).await?;
    }
    // Career totals are a projection of the same exactly-once event. Keeping
    // them in this transaction means a retry cannot double-count a fight and
    // an old bot-only event can be swept without erasing the bot's career.
    db.execute(
        "insert into pilot_stats (account, deaths) values ($1, 1)
         on conflict (account) do update
         set deaths = pilot_stats.deaths + 1",
        &[&victim],
    )
    .await
    .map_err(|error| format!("cannot count death: {error}"))?;
    if let Some(killer) = killer.filter(|account| *account != victim) {
        db.execute(
            "insert into pilot_stats (account, kills) values ($1, 1)
             on conflict (account) do update
             set kills = pilot_stats.kills + 1",
            &[&killer],
        )
        .await
        .map_err(|error| format!("cannot count kill: {error}"))?;
    }
    for credit in credits {
        let account = credit
            .get("account")
            .and_then(|value| value.as_i64())
            .unwrap_or(0);
        if account == 0 || Some(account) == killer {
            continue;
        }
        db.execute(
            "insert into pilot_stats (account, assists) values ($1, 1)
             on conflict (account) do update
             set assists = pilot_stats.assists + 1",
            &[&account],
        )
        .await
        .map_err(|error| format!("cannot count assist: {error}"))?;
    }
    db.commit()
        .await
        .map_err(|error| format!("cannot commit: {error}"))
}

/// One line of the pilot log, into the table.
///
/// Simpler than its rating counterpart in the one way that matters: there is
/// no projection to keep in step, so a row is one insert and needs no
/// transaction around it. The dedup index does the same work here that it does
/// there, and a second arrival is reported as success so the arena's spool
/// lets go of it.
async fn ingest_pilot(
    db: &Client,
    zone: &str,
    instance: &str,
    event: &serde_json::Value,
) -> Result<(), String> {
    let Some(event_id) = event.get("id").and_then(|value| value.as_i64()) else {
        return Err("no event id".into());
    };
    let kind = event
        .get("kind")
        .and_then(|value| value.as_str())
        .unwrap_or_default();
    if kind.is_empty() {
        return Err("no kind".into());
    }
    // Milliseconds on the wire, a timestamp in the column. The arena has no
    // date library and does not need one to say when something happened.
    let at = event
        .get("at")
        .and_then(|value| value.as_u64())
        .unwrap_or(0) as f64
        / 1000.0;
    let session = event
        .get("session")
        .and_then(|value| value.as_str())
        .filter(|session| !session.is_empty());
    let pilot = event.get("pilot").and_then(|value| value.as_i64());
    let name = event
        .get("name")
        .and_then(|value| value.as_str())
        .unwrap_or_default();
    let bot = event
        .get("bot")
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    let room = event
        .get("room")
        .and_then(|value| value.as_i64())
        .map(|room| room as i32);
    let tick = event
        .get("tick")
        .and_then(|value| value.as_i64())
        .unwrap_or(0);
    let detail = event
        .get("detail")
        .cloned()
        .unwrap_or(serde_json::json!({}));

    let rows = db
        .execute(
            "insert into pilot_events
           (event_id, at, session, pilot, name, bot, kind, zone, instance,
            room, tick, detail)
         values ($1, to_timestamp($2::float8), $3, $4, $5, $6, $7, $8, $9,
                 $10, $11, $12)
         on conflict (event_id) do nothing",
            &[
                &event_id, &at, &session, &pilot, &name, &bot, &kind, &zone, &instance, &room,
                &tick, &detail,
            ],
        )
        .await
        .map_err(|error| format!("cannot store pilot event: {error}"))?;

    // Rivets are bounty taken, and a kill row is where a bounty is taken.
    //
    // Banked here rather than summed out of the log on demand, because the
    // log is swept and a wallet that shrank when a row aged out would be a
    // wallet nobody could trust. `rows` is what makes it safe: delivery is
    // at-least-once and the unique index refuses the second copy, so a retry
    // inserts nothing and pays nothing.
    if rows > 0 && kind == crate::pilot::KILL {
        if let Some(account) = pilot {
            let paid = detail
                .get("bounty")
                .and_then(|value| value.as_i64())
                .unwrap_or(0)
                .clamp(0, u16::MAX as i64);
            if paid > 0 {
                pay(db, account, paid).await?;
            }
        }
    }
    // And a misfire costs one, which is the smallest amount a wallet can move
    // by. It is not a fine calibrated against anything: it is there so that
    // bombing your own feet is a number going the other way rather than a
    // blank line, and one rivet against a kill worth dozens says exactly that.
    //
    // Floored at zero, unlike the kill count in the arena. A negative score is
    // a fact about a match; a negative balance is a debt, and this game does
    // not have those. Same `rows > 0` guard: delivery is at-least-once and a
    // retry must not charge twice.
    if rows > 0 && kind == crate::pilot::MISFIRE {
        if let Some(account) = pilot {
            charge(db, account, 1).await?;
        }
    }
    Ok(())
}

/// Rivets out of an account's wallet, never past empty.
///
/// An account with no row has never been paid, which is a balance of zero,
/// and zero less one is zero: no row is made, because a wallet that appears
/// the first time somebody kills themselves is a row that says nothing.
async fn charge(db: &Client, account: i64, rivets: i64) -> Result<(), String> {
    db.execute(
        "update wallets set rivets = greatest(0, rivets - $2) where account = $1",
        &[&account, &rivets],
    )
    .await
    .map(|_| ())
    .map_err(|error| format!("cannot charge rivets: {error}"))
}

/// Rivets into an account's wallet. An account with no row has never been
/// paid, which is the same thing as a balance of zero, so the first payment
/// makes the row.
pub(super) async fn pay(db: &Client, account: i64, rivets: i64) -> Result<(), String> {
    db.execute(
        "insert into wallets (account, rivets) values ($1, $2)
         on conflict (account) do update set rivets = wallets.rivets + $2",
        &[&account, &rivets],
    )
    .await
    .map(|_| ())
    .map_err(|error| format!("cannot bank rivets: {error}"))
}

/// One pilot's rating moves by one delta, and their game count by one.
async fn apply(db: &Transaction<'_>, account: i64, class: &str, delta: f64) -> Result<(), String> {
    // 1200 is where a pilot with no history starts, and it has to appear here
    // as well as in the arena: a first event has nothing to add to otherwise.
    //
    // The casts are load-bearing. Without them Postgres reads `1200.0 + $3`
    // and types the parameter as numeric, which is not the f64 being bound,
    // and every projection fails while the log keeps filling.
    db.execute(
        "insert into ratings (account, class, rating, games)
         values ($1, $2, 1200.0::float8 + $3::float8, 1)
         on conflict (account, class) do update
           set rating = ratings.rating + $3::float8, games = ratings.games + 1",
        &[&account, &class, &delta],
    )
    .await
    .map(|_| ())
    .map_err(|error| format!("cannot apply rating: {error}"))
}
