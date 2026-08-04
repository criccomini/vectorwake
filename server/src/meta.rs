//! The meta-layer: accounts, ratings, and the rated event log.
//!
//! `vectorwake-server meta`, the fourth face of this binary. It owns
//! everything durable about a pilot and nothing about a room, which is what
//! lets every other process in the fleet stay disposable.
//!
//! docs/architecture/meta-layer.md is the design and docs/design/accounts.md
//! is the account model. Two properties are worth keeping in mind while
//! reading:
//!
//! Nothing on the join path calls this service. It mints a signed token, and
//! arenas verify the signature with a key the catalog carries, so an outage
//! here costs claiming and persistence but never play.
//!
//! It holds no personal data. There are no email addresses and no third-party
//! identities, only generated call signs, ratings, and hashed random secrets,
//! so what a breach discloses is a ladder.

use std::sync::Arc;

use deadpool_postgres::{Client, Pool};
use rand::Rng;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::catalog::sha256_hex;
use crate::token::{self, ClassRating, Claims, Kind};

/// The default mode class. A zone declares which class it rates into, and a
/// pilot carries one rating per class, per docs/design/rating.md.
pub const DEFAULT_CLASS: &str = "arena";

/// Account kinds as they sit in the database. The wire and the token use the
/// same numbering, so a kind never needs translating between layers.
const KIND_HUMAN: i16 = 0;
const KIND_HOUSE_BOT: i16 = 1;
const KIND_THIRD_PARTY_BOT: i16 = 2;

fn kind_of(n: i16) -> Kind {
    match n {
        KIND_HOUSE_BOT => Kind::HouseBot,
        KIND_THIRD_PARTY_BOT => Kind::ThirdPartyBot,
        _ => Kind::Human,
    }
}

/// Applied at every startup. Idempotent by construction, because the
/// alternative is a migration tool for a schema that has one author and one
/// deployment.
const SCHEMA: &str = "
create table if not exists accounts (
    id       bigserial primary key,
    kind     smallint not null,
    owner    bigint references accounts(id),
    created  timestamptz not null default now(),
    banned   boolean not null default false,
    reason   text
);
create table if not exists credentials (
    method   text not null,
    hash     text not null,
    account  bigint not null references accounts(id) on delete cascade,
    created  timestamptz not null default now(),
    primary key (method, hash)
);
create index if not exists credentials_by_account on credentials (account);
create table if not exists names (
    account   bigint primary key references accounts(id) on delete cascade,
    call_sign text not null,
    reserved  boolean not null default false
);
create unique index if not exists names_reserved
    on names (lower(call_sign)) where reserved;
create table if not exists ratings (
    account  bigint not null references accounts(id) on delete cascade,
    class    text not null,
    rating   double precision not null,
    games    integer not null,
    primary key (account, class)
);
create table if not exists rated_events (
    id             bigserial primary key,
    at             timestamptz not null default now(),
    class          text not null,
    zone           text not null,
    instance       text not null,
    tick           bigint not null,
    victim         bigint not null,
    victim_kind    smallint not null,
    victim_before  double precision not null,
    victim_after   double precision not null,
    credits        jsonb not null
);
create index if not exists rated_events_by_victim on rated_events (victim, at);
create table if not exists link_codes (
    code     text primary key,
    account  bigint not null references accounts(id) on delete cascade,
    expires  timestamptz not null
);
";

pub struct Meta {
    pool: Pool,
    signing: ed25519_dalek::SigningKey,
    /// Pool tokens, for the two callers that are servers rather than players:
    /// an arena handing off rated events and the bot server claiming its
    /// roster's accounts.
    catalog: crate::catalog::Catalog,
}

impl Meta {
    async fn db(&self) -> Result<Client, String> {
        self.pool.get().await.map_err(|e| format!("no database connection: {e}"))
    }
}

/// A secret is 32 random bytes in hex: minted, never chosen, and stored only
/// as a hash. The same shape as a pool token, for the same reasons.
fn new_secret() -> String {
    let bytes: [u8; 32] = rand::thread_rng().gen();
    token::to_hex(&bytes)
}

/// Crockford's alphabet without the letters that get misread aloud or in
/// handwriting, because this is the one credential in the system a human is
/// expected to copy down.
const KEY_ALPHABET: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// The account key: 20 characters of base32 in five groups, which is 100 bits
/// of entropy in a shape that fits a password manager or a sticky note.
fn new_account_key() -> String {
    let mut rng = rand::thread_rng();
    let mut out = String::from("VW");
    for group in 0..5 {
        let _ = group;
        out.push('-');
        for _ in 0..4 {
            out.push(KEY_ALPHABET[rng.gen_range(0..KEY_ALPHABET.len())] as char);
        }
    }
    out
}

/// Typed by a person, so it is compared with the dashes and case they did not
/// necessarily reproduce.
fn normalize_key(given: &str) -> String {
    given
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// Six digits, short-lived and single use. Long enough that guessing one
/// inside its lifetime is not worth attempting, short enough to read off one
/// screen and type into another.
fn new_link_code() -> String {
    let mut rng = rand::thread_rng();
    (0..6).map(|_| char::from(b'0' + rng.gen_range(0..10))).collect()
}

/// Names arrive from a client and go into a roster every other player reads,
/// so they get the same treatment the arena gives them: printable ASCII, and
/// short.
fn clean_name(given: &str) -> String {
    let s: String = given
        .chars()
        .filter(|c| c.is_ascii_graphic() || *c == ' ')
        .take(24)
        .collect();
    let s = s.trim().to_string();
    if s.is_empty() {
        String::new()
    } else {
        s
    }
}

// ---------------------------------------------------------------- accounts

async fn create_account(db: &Client, kind: i16, owner: Option<i64>) -> Result<i64, String> {
    db.query_one(
        "insert into accounts (kind, owner) values ($1, $2) returning id",
        &[&kind, &owner],
    )
    .await
    .map(|r| r.get::<_, i64>(0))
    .map_err(|e| format!("cannot create account: {e}"))
}

async fn add_credential(db: &Client, account: i64, method: &str, hash: &str) -> Result<(), String> {
    db.execute(
        "insert into credentials (method, hash, account) values ($1, $2, $3)
         on conflict (method, hash) do nothing",
        &[&method, &hash, &account],
    )
    .await
    .map(|_| ())
    .map_err(|e| format!("cannot store credential: {e}"))
}

async fn account_for(db: &Client, method: &str, hash: &str) -> Option<i64> {
    db.query_opt(
        "select account from credentials where method = $1 and hash = $2",
        &[&method, &hash],
    )
    .await
    .ok()
    .flatten()
    .map(|r| r.get::<_, i64>(0))
}

async fn set_name(db: &Client, account: i64, name: &str) -> Result<(), String> {
    db.execute(
        "insert into names (account, call_sign) values ($1, $2)
         on conflict (account) do update set call_sign = excluded.call_sign",
        &[&account, &name],
    )
    .await
    .map(|_| ())
    .map_err(|e| format!("cannot store name: {e}"))
}

/// Everything a token needs about an account, in one round trip each.
async fn claims_for(db: &Client, account: i64) -> Result<Claims, String> {
    let row = db
        .query_opt("select kind, banned from accounts where id = $1", &[&account])
        .await
        .map_err(|e| format!("cannot read account: {e}"))?
        .ok_or_else(|| "no such account".to_string())?;
    let kind: i16 = row.get(0);
    let banned: bool = row.get(1);
    // A ban is enforced here, at the one door every session comes through,
    // which is why no arena carries a fleet ban list.
    if banned {
        return Err("banned".into());
    }

    let name: String = db
        .query_opt("select call_sign from names where account = $1", &[&account])
        .await
        .map_err(|e| format!("cannot read name: {e}"))?
        .map(|r| r.get(0))
        .unwrap_or_else(|| format!("Pilot {account}"));

    // A guest holds one credential, the secret its client keeps. Anything
    // beyond that is a claim, and a claim is what the human label means.
    let extra: i64 = db
        .query_one(
            "select count(*) from credentials where account = $1 and method <> 'secret'",
            &[&account],
        )
        .await
        .map_err(|e| format!("cannot count credentials: {e}"))?
        .get(0);

    let rows = db
        .query("select class, rating, games from ratings where account = $1", &[&account])
        .await
        .map_err(|e| format!("cannot read ratings: {e}"))?;
    let ratings = rows
        .iter()
        .map(|r| ClassRating {
            class: r.get(0),
            rating: r.get(1),
            games: r.get::<_, i32>(2).max(0) as u32,
        })
        .collect();

    Ok(Claims {
        account: account as u64,
        kind: kind_of(kind),
        claimed: extra > 0,
        name,
        expires: token::now_secs() + token::LIFETIME_SECS,
        ratings,
    })
}

// ------------------------------------------------------------------ routes

/// Every route takes JSON and answers JSON. Hand-rolled HTTP for the same
/// reason `admin.rs` hand-rolls it: the surface is small and a framework
/// would be the larger change.
async fn route(meta: &Meta, path: &str, body: &serde_json::Value) -> (u16, serde_json::Value) {
    let db = match meta.db().await {
        Ok(d) => d,
        Err(e) => return (503, serde_json::json!({ "error": e })),
    };
    let s = |v: &str| body.get(v).and_then(|x| x.as_str()).unwrap_or("").to_string();

    match path {
        // Nobody signs up. The first time a client runs it asks for an
        // account and stores what it gets back, and that is the whole flow.
        "/v1/guest" => {
            let account = match create_account(&db, KIND_HUMAN, None).await {
                Ok(a) => a,
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            // The client generates the call sign, so there is one word list in
            // the codebase rather than two that can drift apart.
            let mut name = clean_name(&s("name"));
            if name.is_empty() {
                name = format!("Pilot {account}");
            }
            if let Err(e) = set_name(&db, account, &name).await {
                return (500, serde_json::json!({ "error": e }));
            }
            (200, serde_json::json!({ "secret": secret, "account": account, "name": name }))
        }

        // The only route a client calls in the normal case, once a session.
        "/v1/login" => {
            let Some(account) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            match claims_for(&db, account).await {
                Ok(c) => {
                    let token = token::mint(&meta.signing, &c);
                    (200, serde_json::json!({
                        "token": token,
                        "account": c.account,
                        "name": c.name,
                        "claimed": c.claimed,
                        "bot": c.kind.is_bot(),
                        "expires": c.expires,
                        "ratings": c.ratings.iter().map(|r| serde_json::json!({
                            "class": r.class, "rating": r.rating, "games": r.games,
                        })).collect::<Vec<_>>(),
                    }))
                }
                Err(e) if e == "banned" => (403, serde_json::json!({ "error": "banned" })),
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
        }

        // Claiming attaches a way back in. Nothing moves: same account, same
        // rating, same history, and from here on losing the device is
        // survivable.
        "/v1/claim" => {
            let Some(account) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let key = new_account_key();
            let hash = sha256_hex(normalize_key(&key).as_bytes());
            if let Err(e) = add_credential(&db, account, "key", &hash).await {
                return (500, serde_json::json!({ "error": e }));
            }
            // A claimed name is reserved fleet-wide. The index is partial, so
            // two guests may share a call sign and two claimed pilots may not,
            // and a collision leaves the claim standing with the name it had.
            let reserved = db
                .execute("update names set reserved = true where account = $1", &[&account])
                .await
                .is_ok();
            (200, serde_json::json!({ "key": key, "reserved": reserved }))
        }

        // The account key on a new device. Each device ends up with its own
        // secret, which is what makes one revocable without the others.
        "/v1/redeem" => {
            let hash = sha256_hex(normalize_key(&s("key")).as_bytes());
            let Some(account) = account_for(&db, "key", &hash).await else {
                return (403, serde_json::json!({ "error": "no such key" }));
            };
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            (200, serde_json::json!({ "secret": secret, "account": account }))
        }

        // A logged-in session offers a code; another device takes it. This is
        // the routine path between devices and platforms, with the key as the
        // backstop rather than the everyday tool.
        "/v1/link/new" => {
            let Some(account) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let code = new_link_code();
            let r = db
                .execute(
                    "insert into link_codes (code, account, expires)
                     values ($1, $2, now() + interval '10 minutes')
                     on conflict (code) do update set account = excluded.account,
                                                      expires = excluded.expires",
                    &[&code, &account],
                )
                .await;
            match r {
                Ok(_) => (200, serde_json::json!({ "code": code, "seconds": 600 })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        "/v1/link/redeem" => {
            let code = s("code");
            // Single use: the delete is the check, so two devices racing on one
            // code cannot both win.
            let row = db
                .query_opt(
                    "delete from link_codes where code = $1 and expires > now() returning account",
                    &[&code],
                )
                .await;
            let Ok(Some(row)) = row else {
                return (403, serde_json::json!({ "error": "no such code" }));
            };
            let account: i64 = row.get(0);
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            (200, serde_json::json!({ "secret": secret, "account": account }))
        }

        // The bot server, holding a pool credential, claiming the account for
        // one roster individual. Idempotent: an individual is one account and
        // one career however many times the bot server restarts.
        "/v1/bot" => {
            if meta.catalog.pool_for_token(&s("pool_token")).is_none() {
                return (403, serde_json::json!({ "error": "unknown pool token" }));
            }
            let name = clean_name(&s("name"));
            if name.is_empty() {
                return (400, serde_json::json!({ "error": "a bot needs a name" }));
            }
            let account = match account_for(&db, "house", &name).await {
                Some(a) => a,
                None => match create_account(&db, KIND_HOUSE_BOT, None).await {
                    Ok(a) => {
                        if let Err(e) = add_credential(&db, a, "house", &name).await {
                            return (500, serde_json::json!({ "error": e }));
                        }
                        if let Err(e) = set_name(&db, a, &name).await {
                            return (500, serde_json::json!({ "error": e }));
                        }
                        let _ = db
                            .execute("update names set reserved = true where account = $1", &[&a])
                            .await;
                        // A new individual starts where the offline tournament
                        // put it rather than at the default, which is what
                        // gives a fresh deployment a sane ladder before a
                        // single human has played. The pinned anchor is the
                        // case that matters most: everything else in the fleet
                        // is measured against it, so it has to be at its rating
                        // from the first tick and not climb to it.
                        if let Some(seed) = crate::calibrated_rating(&name) {
                            let _ = db
                                .execute(
                                    "insert into ratings (account, class, rating, games)
                                     values ($1, $2, $3, 0)
                                     on conflict (account, class) do nothing",
                                    &[&a, &DEFAULT_CLASS, &seed],
                                )
                                .await;
                        }
                        a
                    }
                    Err(e) => return (500, serde_json::json!({ "error": e })),
                },
            };
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            (200, serde_json::json!({ "secret": secret, "account": account }))
        }

        // Somebody else's bot, registered by the person who answers for it.
        // Anyone may declare a bot at join and be labeled honestly; what this
        // buys is an account, which is what a rating needs to outlive a room.
        // The owner has to be claimed, because an owner who can evaporate by
        // clearing local storage is not accountable for anything.
        "/v1/bot/register" => {
            let Some(owner) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let claims = match claims_for(&db, owner).await {
                Ok(c) => c,
                Err(e) if e == "banned" => return (403, serde_json::json!({ "error": "banned" })),
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            if claims.kind.is_bot() {
                return (400, serde_json::json!({ "error": "a bot cannot own a bot" }));
            }
            if !claims.claimed {
                return (403, serde_json::json!({
                    "error": "claim your own account first; a bot needs an owner who can be found"
                }));
            }
            let name = clean_name(&s("name"));
            if name.is_empty() {
                return (400, serde_json::json!({ "error": "a bot needs a name" }));
            }
            let account = match create_account(&db, KIND_THIRD_PARTY_BOT, Some(owner)).await {
                Ok(a) => a,
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            if let Err(e) = set_name(&db, account, &name).await {
                return (500, serde_json::json!({ "error": e }));
            }
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            (200, serde_json::json!({ "secret": secret, "account": account, "owner": owner }))
        }

        // An arena handing off what it rated. The log is the durable artifact
        // and the ratings table is a projection of it, per
        // docs/design/rating.md.
        "/v1/events" => {
            if meta.catalog.pool_for_token(&s("pool_token")).is_none() {
                return (403, serde_json::json!({ "error": "unknown pool token" }));
            }
            let class = {
                let c = s("class");
                if c.is_empty() { DEFAULT_CLASS.to_string() } else { c }
            };
            let zone = s("zone");
            let instance = s("instance");
            let empty = Vec::new();
            let events = body.get("events").and_then(|v| v.as_array()).unwrap_or(&empty);
            let mut db = db;
            let mut stored = 0usize;
            let mut failed = Vec::new();
            for ev in events {
                match ingest(&mut db, &class, &zone, &instance, ev).await {
                    Ok(()) => stored += 1,
                    // Said out loud rather than counted silently. An arena that
                    // cannot hand off keeps its batch and retries, and a
                    // projection that stopped moving while the log filled is
                    // exactly the failure that hides for a week.
                    Err(e) => failed.push(e),
                }
            }
            if failed.is_empty() {
                (200, serde_json::json!({ "stored": stored }))
            } else {
                println!("meta: {} of {} events refused: {}", failed.len(), events.len(), failed[0]);
                (500, serde_json::json!({ "stored": stored, "failed": failed.len(), "error": failed[0] }))
            }
        }

        // A fleet ban, held by the operator's admin credential rather than a
        // pool token, because this one is a human decision about a person.
        "/v1/ban" => {
            let want = std::env::var("VW_ADMIN_TOKEN").unwrap_or_default();
            if want.is_empty() || s("admin_token") != want {
                return (403, serde_json::json!({ "error": "bad admin token" }));
            }
            let account = body.get("account").and_then(|v| v.as_i64()).unwrap_or(0);
            let banned = body.get("banned").and_then(|v| v.as_bool()).unwrap_or(true);
            let reason = s("reason");
            let r = db
                .execute(
                    "update accounts set banned = $2, reason = $3 where id = $1",
                    &[&account, &banned, &reason],
                )
                .await;
            match r {
                Ok(n) => (200, serde_json::json!({ "changed": n })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        _ => (404, serde_json::json!({ "error": "no such route" })),
    }
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
async fn ingest(
    db: &mut Client,
    class: &str,
    zone: &str,
    instance: &str,
    ev: &serde_json::Value,
) -> Result<(), String> {
    let victim = ev.get("victim").and_then(|v| v.as_i64()).unwrap_or(0);
    if victim == 0 {
        return Err("no victim".into());
    }
    let before = ev.get("victim_before").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let after = ev.get("victim_after").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let tick = ev.get("tick").and_then(|v| v.as_i64()).unwrap_or(0);
    let victim_kind = ev.get("victim_kind").and_then(|v| v.as_i64()).unwrap_or(0) as i16;
    let empty = Vec::new();
    let credits = ev.get("credits").and_then(|v| v.as_array()).unwrap_or(&empty);

    let db = db
        .transaction()
        .await
        .map_err(|e| format!("cannot open a transaction: {e}"))?;

    db.execute(
        "insert into rated_events
           (class, zone, instance, tick, victim, victim_kind, victim_before, victim_after, credits)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        &[
            &class,
            &zone,
            &instance,
            &tick,
            &victim,
            &victim_kind,
            &before,
            &after,
            &serde_json::Value::Array(credits.clone()),
        ],
    )
    .await
    .map_err(|e| format!("cannot store event: {e}"))?;

    apply(&db, victim, class, after - before).await?;
    for c in credits {
        let who = c.get("account").and_then(|v| v.as_i64()).unwrap_or(0);
        if who == 0 {
            continue;
        }
        let d = c.get("after").and_then(|v| v.as_f64()).unwrap_or(0.0)
            - c.get("before").and_then(|v| v.as_f64()).unwrap_or(0.0);
        apply(&db, who, class, d).await?;
    }
    db.commit().await.map_err(|e| format!("cannot commit: {e}"))
}

/// One pilot's rating moves by one delta, and their game count by one.
async fn apply(
    db: &deadpool_postgres::Transaction<'_>,
    account: i64,
    class: &str,
    delta: f64,
) -> Result<(), String> {
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
    .map_err(|e| format!("cannot apply rating: {e}"))
}

// ------------------------------------------------------------------ client

/// A POST to the meta-layer, hand-rolled over a plain socket for the same
/// reason `admin.rs` hand-rolls its responder: a handful of request shapes, and
/// a client library would be the larger change. TLS is Caddy's job on a real
/// deployment, as it already is for every other listener in the fleet.
///
/// This is the only way anything in this binary talks to the service, so an
/// arena's rated events and the bot server's account claims share one parser
/// and one set of failure messages.
pub async fn call(base: &str, path: &str, body: &str) -> Result<serde_json::Value, String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let rest = base.trim_end_matches('/');
    let rest = rest.strip_prefix("http://").unwrap_or(rest);
    let (host, prefix) = match rest.split_once('/') {
        Some((h, p)) => (h, format!("/{p}")),
        None => (rest, String::new()),
    };
    let addr = if host.contains(':') { host.to_string() } else { format!("{host}:80") };
    let mut s = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::net::TcpStream::connect(&addr),
    )
    .await
    .map_err(|_| format!("{addr} did not answer"))?
    .map_err(|e| format!("cannot reach {addr}: {e}"))?;
    let req = format!(
        "POST {prefix}{path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).await.map_err(|e| format!("{e}"))?;
    let mut out = Vec::new();
    s.read_to_end(&mut out).await.map_err(|e| format!("{e}"))?;
    let text = String::from_utf8_lossy(&out).to_string();
    let status = text.lines().next().unwrap_or("no reply").to_string();
    let payload = text.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");
    if !status.contains(" 200 ") {
        // The body carries the reason, and the reason is the useful half: an
        // unknown pool token reads very differently from a database that is
        // down, and both arrive as a non-200.
        let why = serde_json::from_str::<serde_json::Value>(payload)
            .ok()
            .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(|s| s.to_string()))
            .unwrap_or(status);
        return Err(why);
    }
    serde_json::from_str(payload).map_err(|e| format!("unreadable reply: {e}"))
}

// ------------------------------------------------------------------ server

async fn serve(mut s: tokio::net::TcpStream, meta: Arc<Meta>) -> std::io::Result<()> {
    let mut buf = vec![0u8; 64 * 1024];
    let n = s.read(&mut buf).await?;
    if n == 0 {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&buf[..n]).to_string();
    let request = text.split("\r\n").next().unwrap_or("");
    let mut parts = request.split(' ');
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/");
    let body = text.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");

    // A body can outrun one read. Everything here is small, so the fix is to
    // keep reading until the declared length arrives rather than to stream.
    let want: usize = text
        .split("\r\n")
        .find_map(|l| {
            let l = l.to_ascii_lowercase();
            l.strip_prefix("content-length:").map(|v| v.trim().parse().unwrap_or(0))
        })
        .unwrap_or(0);
    let mut body = body.to_string();
    while body.len() < want {
        let n = s.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        body.push_str(&String::from_utf8_lossy(&buf[..n]));
    }

    let (code, out) = if method == "GET" && path == "/v1/health" {
        // Deliberately answerable without the database, so a health check
        // reports the process and the database reports itself.
        (200, serde_json::json!({ "service": "meta" }))
    } else if method != "POST" {
        (405, serde_json::json!({ "error": "post json" }))
    } else {
        let parsed: serde_json::Value =
            serde_json::from_str(&body).unwrap_or(serde_json::Value::Null);
        route(&meta, path, &parsed).await
    };

    let out = out.to_string();
    let status = match code {
        200 => "200 OK",
        400 => "400 Bad Request",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        503 => "503 Service Unavailable",
        _ => "500 Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        out.len()
    );
    s.write_all(head.as_bytes()).await?;
    s.write_all(out.as_bytes()).await?;
    s.flush().await
}

/// `vectorwake-server meta [catalog-dir]`
pub async fn run() {
    crate::metrics::spawn("meta", "");
    let dir = std::env::args().nth(2).unwrap_or_else(|| ".".into());
    let addr = std::env::var("VW_META_LISTEN").unwrap_or_else(|_| "0.0.0.0:7400".into());
    let url = std::env::var("VW_META_DATABASE").unwrap_or_default();
    if url.is_empty() {
        println!("meta: VW_META_DATABASE is empty; nothing to store into");
        return;
    }
    let Some(signing) = std::env::var("VW_META_KEY").ok().and_then(|k| token::signing_key_from_hex(&k))
    else {
        println!("meta: VW_META_KEY must be 64 hex characters; make one with 'vectorwake-server metakey'");
        return;
    };

    // The catalog is read for its pool tokens alone, which are what an arena
    // and the bot server authenticate with. A meta-layer that cannot read one
    // still serves players; it just cannot accept a server.
    let catalog = crate::catalog::load(&dir).unwrap_or_else(|e| {
        println!("meta: no catalog at {dir:?} ({e}); server routes will refuse");
        Default::default()
    });

    // TLS on the database connection, because a bought database is reached
    // over somebody else's network. Vultr's managed Postgres refuses a
    // cleartext connection outright, so this is not a hardening pass but the
    // difference between connecting and not.
    //
    // `sslmode` in the connection string decides whether it is used:
    // `require` for a managed database, and the default `prefer` on a laptop
    // falls back to cleartext against a container that offers no TLS. One code
    // path either way.
    let tls = {
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        // A provider that is not publicly trusted, which some managed
        // databases use. The file goes beside the process and its path in the
        // environment; without one, public roots are all we trust.
        if let Ok(path) = std::env::var("VW_META_CA") {
            match std::fs::read(&path) {
                Ok(pem) => {
                    let mut rd = std::io::BufReader::new(&pem[..]);
                    let mut added = 0;
                    for cert in rustls_pemfile::certs(&mut rd).flatten() {
                        if roots.add(cert).is_ok() {
                            added += 1;
                        }
                    }
                    println!("meta: trusting {added} certificate(s) from {path}");
                }
                Err(e) => println!("meta: cannot read VW_META_CA {path}: {e}"),
            }
        }
        let cfg = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        tokio_postgres_rustls::MakeRustlsConnect::new(cfg)
    };

    let mut cfg = deadpool_postgres::Config::new();
    cfg.url = Some(url);
    let pool = match cfg.create_pool(Some(deadpool_postgres::Runtime::Tokio1), tls) {
        Ok(p) => p,
        Err(e) => {
            println!("meta: cannot build a connection pool: {e}");
            return;
        }
    };
    match pool.get().await {
        Ok(db) => {
            if let Err(e) = db.batch_execute(SCHEMA).await {
                println!("meta: cannot apply schema: {e}");
                return;
            }
        }
        Err(e) => {
            println!("meta: cannot reach the database: {e}");
            return;
        }
    }

    let verifying = token::to_hex(signing.verifying_key().as_bytes());
    let meta = Arc::new(Meta { pool, signing, catalog });
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            println!("meta: cannot bind {addr}: {e}");
            return;
        }
    };
    println!("meta-layer on http://{addr}");
    println!("  verifying key {verifying}");
    println!("  put that in the catalog's [meta] block so arenas can check tokens");
    loop {
        let Ok((stream, _)) = listener.accept().await else { continue };
        let meta = meta.clone();
        tokio::spawn(async move {
            let _ = serve(stream, meta).await;
        });
    }
}

/// `vectorwake-server metakey`, which prints a fresh signing key and the
/// verifying key that goes in the catalog beside it. Generated, never typed.
pub fn run_keygen() {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill(&mut bytes);
    let k = ed25519_dalek::SigningKey::from_bytes(&bytes);
    println!("VW_META_KEY={}", token::to_hex(&k.to_bytes()));
    println!();
    println!("[meta]");
    println!("key = \"{}\"", token::to_hex(k.verifying_key().as_bytes()));
    println!();
    println!("The first line is a secret and belongs in the meta-layer's environment.");
    println!("The second goes in catalog.toml, where every arena reads it.");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_account_key_is_readable_and_case_insensitive() {
        let k = new_account_key();
        assert!(k.starts_with("VW-"), "{k} names the game it belongs to");
        assert_eq!(k.len(), 2 + 5 * 5, "five groups of four");
        // A person types this, so it has to survive lowercase and lost dashes.
        assert_eq!(normalize_key(&k), normalize_key(&k.to_lowercase()));
        assert_eq!(normalize_key(&k), normalize_key(&k.replace('-', "")));
        assert_eq!(normalize_key(&k).len(), 22);
    }

    #[test]
    fn keys_do_not_use_letters_that_get_misread() {
        // I, L, O and U are absent on purpose: the first three are misread as
        // digits and the fourth turns a random string into a word somebody
        // has to read aloud.
        for _ in 0..50 {
            let k = new_account_key();
            for c in k.chars().filter(|c| c.is_ascii_alphabetic()) {
                assert!(!"ILOU".contains(c), "{k} holds an ambiguous letter");
            }
        }
    }

    #[test]
    fn two_keys_differ() {
        assert_ne!(new_account_key(), new_account_key());
        assert_ne!(new_secret(), new_secret());
        assert_eq!(new_secret().len(), 64, "32 bytes in hex");
    }

    #[test]
    fn a_link_code_is_six_digits() {
        let c = new_link_code();
        assert_eq!(c.len(), 6);
        assert!(c.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn names_are_cleaned_the_way_the_arena_cleans_them() {
        assert_eq!(clean_name("  Vesper 47  "), "Vesper 47");
        assert_eq!(clean_name("bad\u{1}name"), "badname");
        assert_eq!(clean_name(&"x".repeat(80)).len(), 24);
        assert_eq!(clean_name("   "), "");
    }
}
