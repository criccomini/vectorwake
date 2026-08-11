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
//! identities, only generated call signs, ratings, hashed random secrets and
//! argon2-hashed passwords, so what a breach discloses is a ladder plus a
//! cracking exercise that leads back to nothing but the ladder.

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
    call_sign text not null
);
-- Unique across the fleet, guests included. The index used to be partial,
-- constraining only names a claim had reserved, which was right while a name
-- was decoration and wrong the moment it became how you log in. The delete
-- clears the way for the total index by dropping the later of any two rows
-- that collide; an account stripped that way answers as Pilot N until it
-- rerolls, and only accounts from before this index can be in that state.
drop index if exists names_reserved;
alter table names drop column if exists reserved;
delete from names a using names b
    where lower(a.call_sign) = lower(b.call_sign) and a.account > b.account;
create unique index if not exists names_unique on names (lower(call_sign));
-- When this account last began a session, for the sweeper alone.
alter table accounts add column if not exists last_seen timestamptz not null default now();
-- Whether this account opens the admin panel. No route writes it: the flag
-- is set by the operator in the database itself, so there is nothing for a
-- leaked credential or a compromised neighbour process to call.
alter table accounts add column if not exists admin boolean not null default false;
-- An operator note lived here for an afternoon and was dropped: what an
-- operator writes about a pilot is a moderation record, and a text column
-- with no history, no author and no timestamp is a worse place to keep one
-- than nowhere at all.
alter table accounts drop column if exists note;
-- The key era's leftovers. A key credential has no route left to present it
-- to, and the link_codes table belonged to the same machinery.
delete from credentials where method = 'key';
drop table if exists link_codes;
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
    credits        jsonb not null,
    event_id       bigint,
    bots_only      boolean not null default false
);
create index if not exists rated_events_by_victim on rated_events (victim, at);
-- Retention reads exactly this. Partial, because the rows it will never
-- select are the ones worth keeping and there is no reason to index them:
-- a human-involving row is kept forever and the sweeper never looks at it.
alter table rated_events add column if not exists bots_only boolean not null default false;
create index if not exists rated_events_botsweep on rated_events (at) where bots_only;
-- The arena mints event_id when it files the event, and it rides through
-- every retry of the batch. Unique here is what makes ingest idempotent:
-- delivery is at-least-once, so the second arrival of an event has to be
-- refused rather than applied again. Rows from before the id existed are
-- null, which the index does not mind.
alter table rated_events add column if not exists event_id bigint;
create unique index if not exists rated_events_once on rated_events (event_id);
";

pub struct Meta {
    pool: Pool,
    signing: ed25519_dalek::SigningKey,
    /// Pool tokens, for the two callers that are servers rather than players:
    /// an arena handing off rated events and the bot server claiming its
    /// roster's accounts.
    catalog: crate::catalog::Catalog,
    /// Per-address and per-name counters for the two routes an attacker has
    /// a reason to hammer: guest creation burns call signs and login guesses
    /// passwords.
    throttle: Throttle,
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

/// The words a call sign is drawn from, and this is the only place one is
/// ever drawn: no route accepts a name, because whoever proposes a name
/// chooses it, and a curated list is only safe while the server is the thing
/// doing the curating.
///
/// The register is the client's old list grown four times over: short
/// evocative nouns, eight letters at most so "Solstice 999" is the longest
/// name the scoreboard ever has to hold. Disjoint from the AI roster's names
/// in `ai.rs` and from the eight hull names, so a scoreboard never leaves
/// you wondering which of the three a word came from; the test at the bottom
/// of this file holds all four lists apart.
const CALL_WORDS: [&str; 148] = [
    "Vesper", "Talon", "Corvid", "Ember", "Quill", "Solstice", "Zephyr",
    "Harrow", "Lumen", "Basalt", "Nimbus", "Cobalt", "Fathom", "Verge",
    "Auric", "Sleet", "Pike", "Marrow", "Torrent", "Beacon", "Cinder",
    "Drift", "Halyard", "Ingot", "Jetty", "Kiln", "Lantern", "Mistral",
    "Noctis", "Orbit", "Plume", "Quarry", "Rill", "Sextant", "Thistle",
    "Umber", "Aster", "Auriga", "Ballast", "Bantam", "Bearing", "Bight",
    "Bowline", "Breaker", "Brine", "Bulwark", "Cairn", "Caldera", "Calyx",
    "Cascade", "Chevron", "Chicane", "Corona", "Crag", "Culvert", "Cutlass",
    "Cyclone", "Dapple", "Delta", "Dorado", "Dynamo", "Eclipse", "Eddy",
    "Ellipse", "Epoch", "Equinox", "Fennel", "Ferrite", "Firth", "Fjord",
    "Flint", "Flux", "Forge", "Fresnel", "Furrow", "Gale", "Galena",
    "Garnet", "Gimbal", "Glacier", "Gnomon", "Granite", "Gulch", "Gyre",
    "Halite", "Haven", "Helix", "Hemlock", "Icefall", "Jasper", "Karst",
    "Knoll", "Lagoon", "Lapis", "Leeward", "Lichen", "Lyra", "Mesa", "Mica",
    "Monsoon", "Morrow", "Nadir", "Nebula", "Nickel", "Onyx", "Opal",
    "Outcrop", "Pewter", "Pharos", "Pinion", "Polaris", "Pumice", "Pylon",
    "Quartz", "Quasar", "Radian", "Rampart", "Reef", "Rime", "Riptide",
    "Rudder", "Scoria", "Shale", "Shoal", "Sickle", "Skerry", "Sonar",
    "Spinel", "Squall", "Strand", "Stratus", "Summit", "Sundial", "Talus",
    "Tarn", "Tempest", "Tether", "Thermal", "Tiller", "Topaz", "Trellis",
    "Tundra", "Turbine", "Vortex", "Willow", "Wren", "Yonder", "Zircon",
];

/// One draw: a word and three digits. 148 words against 900 numbers is
/// 133,200 call signs, and live occupancy is bounded by a week of guests
/// plus everyone claimed, so a draw colliding is the exception the retry in
/// `christen` exists for rather than the norm.
fn new_call_sign() -> String {
    let mut rng = rand::thread_rng();
    let word = CALL_WORDS[rng.gen_range(0..CALL_WORDS.len())];
    format!("{word} {}", rng.gen_range(100..1000))
}

/// Give an account a fresh call sign nobody else holds. The unique index is
/// the arbiter: insert, and a collision is a redraw, not an error. At the
/// occupancy a week of guests can produce, a tenth of the pool at the very
/// worst, forty draws fail together once in 10^40 tries; if this error is
/// ever seen, something other than luck is filling the table.
async fn christen(db: &Client, account: i64) -> Result<String, String> {
    use deadpool_postgres::tokio_postgres::error::SqlState;
    for _ in 0..40 {
        let name = new_call_sign();
        let r = db
            .execute(
                "insert into names (account, call_sign) values ($1, $2)
                 on conflict (account) do update set call_sign = excluded.call_sign",
                &[&account, &name],
            )
            .await;
        match r {
            Ok(_) => return Ok(name),
            Err(e) if e.code() == Some(&SqlState::UNIQUE_VIOLATION) => continue,
            Err(e) => return Err(format!("cannot store name: {e}")),
        }
    }
    Err("no free call sign in forty draws".into())
}

/// Argon2id with the library's defaults, salt included in the encoding. The
/// device secret keeps sha256 because it is 256 minted bits nobody guesses;
/// a password is chosen by a person and has to survive somebody guessing at
/// scale, which is what the memory-hard construction is for.
fn hash_password(password: &str) -> Result<String, String> {
    use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
    let salt = SaltString::generate(&mut OsRng);
    argon2::Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| format!("cannot hash password: {e}"))
}

fn verify_password(password: &str, stored: &str) -> bool {
    use argon2::password_hash::{PasswordHash, PasswordVerifier};
    PasswordHash::new(stored)
        .map(|h| argon2::Argon2::default().verify_password(password.as_bytes(), &h).is_ok())
        .unwrap_or(false)
}

/// What a password has to be before it is worth hashing: sized, and nothing
/// else. Composition rules push people toward the same dressed-up word, and
/// the floor is low deliberately: the account guards a call sign and a
/// ladder rating, and a player who wants six letters for that is right.
fn password_trouble(password: &str) -> Option<&'static str> {
    if password.len() < 6 {
        return Some("a password needs at least six characters");
    }
    if password.len() > 64 {
        return Some("sixty four characters is plenty");
    }
    None
}

/// One fixed window per key, in memory. Losing the counts on restart is
/// fine: this exists to make guessing slow and name-burning expensive, not
/// to account for anything.
#[derive(Default)]
struct Throttle {
    hits: std::sync::Mutex<std::collections::HashMap<String, (u32, std::time::Instant)>>,
}

impl Throttle {
    fn allow(&self, key: &str, limit: u32, window: std::time::Duration) -> bool {
        let now = std::time::Instant::now();
        let mut hits = self.hits.lock().unwrap();
        // Housekeeping on the way in, so an address scan cannot grow the map
        // without bound.
        if hits.len() > 4096 {
            hits.retain(|_, (_, at)| now.duration_since(*at) < window);
        }
        let entry = hits.entry(key.to_string()).or_insert((0, now));
        if now.duration_since(entry.1) >= window {
            *entry = (0, now);
        }
        entry.0 += 1;
        entry.0 <= limit
    }
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

/// Where the directory on this host answers. Loopback by default and
/// loopback in practice: the directory refuses the operator tags to anything
/// that came through a proxy, which the public `/dir` route always has.
fn directory_url() -> String {
    std::env::var("VW_META_DIRECTORY").unwrap_or_else(|_| "ws://127.0.0.1:9000".into())
}

/// The admin gate: the account behind this secret, if it holds the flag. The
/// `admin` field a session reply carries is decoration for the panel; this
/// check, run inside every admin route, is the authorization. Checked per
/// action rather than per login, so revoking the flag or banning the account
/// takes effect on the next click instead of the next session.
async fn admin_for(db: &Client, secret: &str) -> Option<i64> {
    db.query_opt(
        "select a.id from accounts a
         join credentials c on c.account = a.id and c.method = 'secret'
         where c.hash = $1 and a.admin and not a.banned",
        &[&sha256_hex(secret.as_bytes())],
    )
    .await
    .ok()
    .flatten()
    .map(|r| r.get::<_, i64>(0))
}


/// Give an account a name somebody chose. The unique index on
/// `lower(call_sign)` is the arbiter, exactly as it is for a dealt name, and
/// a collision comes back as `TAKEN` rather than as Postgres prose: a caller
/// deciding what to do about it should not be reading error strings from a
/// driver to find out what happened.
const TAKEN: &str = "that call sign is taken";

async fn set_name(db: &Client, account: i64, name: &str) -> Result<(), String> {
    use deadpool_postgres::tokio_postgres::error::SqlState;
    db.execute(
        "insert into names (account, call_sign) values ($1, $2)
         on conflict (account) do update set call_sign = excluded.call_sign",
        &[&account, &name],
    )
    .await
    .map(|_| ())
    .map_err(|e| {
        if e.code() == Some(&SqlState::UNIQUE_VIOLATION) {
            TAKEN.to_string()
        } else {
            format!("cannot store name: {e}")
        }
    })
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
async fn route(meta: &Meta, path: &str, body: &serde_json::Value, ip: &str) -> (u16, serde_json::Value) {
    let db = match meta.db().await {
        Ok(d) => d,
        Err(e) => return (503, serde_json::json!({ "error": e })),
    };
    let s = |v: &str| body.get(v).and_then(|x| x.as_str()).unwrap_or("").to_string();
    let hour = std::time::Duration::from_secs(3600);
    let quarter = std::time::Duration::from_secs(900);

    match path {
        // Nobody signs up. The first time a client runs it asks for an
        // account and stores what it gets back, and that is the whole flow.
        // The call sign is the server's to give: a name a client could
        // choose is a name a script could choose, and unique-from-birth
        // only means something if nobody can aim the birth.
        "/v1/guest" => {
            if !meta.throttle.allow(&format!("guest:{ip}"), 20, hour) {
                return (429, serde_json::json!({ "error": "too many new pilots from here; wait a while" }));
            }
            let account = match create_account(&db, KIND_HUMAN, None).await {
                Ok(a) => a,
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            let name = match christen(&db, account).await {
                Ok(n) => n,
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            (200, serde_json::json!({ "secret": secret, "account": account, "name": name }))
        }

        // The only route a client calls in the normal case, once a session:
        // the stored device secret becomes a short-lived signed token. Also
        // where an account proves it is alive, which is the whole meaning of
        // last_seen and the only clock the guest sweeper reads.
        "/v1/session" => {
            let Some(account) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let _ = db
                .execute("update accounts set last_seen = now() where id = $1", &[&account])
                .await;
            match claims_for(&db, account).await {
                Ok(c) => {
                    let token = token::mint(&meta.signing, &c);
                    // The flag rides the reply and not the token: no arena
                    // reads it, so putting it in the token would be a wire
                    // change to every arena for the panel's benefit alone.
                    // The panel uses it to decide what to draw, and every
                    // admin route re-checks the database, so a client that
                    // forges this field fools only its own screen.
                    let admin: bool = db
                        .query_one("select admin from accounts where id = $1", &[&account])
                        .await
                        .map(|r| r.get(0))
                        .unwrap_or(false);
                    (200, serde_json::json!({
                        "token": token,
                        "account": c.account,
                        "name": c.name,
                        "claimed": c.claimed,
                        "admin": admin,
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

        // Claiming attaches a way back in: a password on the name you
        // already hold. Nothing moves: same account, same name, same rating,
        // same history, and from here on losing the device is survivable.
        // With a valid secret this also serves as changing the password,
        // which is why the old row is dropped rather than accumulated.
        "/v1/claim" => {
            let Some(account) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let password = s("password");
            if let Some(why) = password_trouble(&password) {
                return (400, serde_json::json!({ "error": why }));
            }
            let hashed = match tokio::task::spawn_blocking(move || hash_password(&password)).await {
                Ok(Ok(h)) => h,
                Ok(Err(e)) => return (500, serde_json::json!({ "error": e })),
                Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
            };
            if let Err(e) = db
                .execute(
                    "delete from credentials where account = $1 and method = 'password'",
                    &[&account],
                )
                .await
            {
                return (500, serde_json::json!({ "error": format!("{e}") }));
            }
            if let Err(e) = add_credential(&db, account, "password", &hashed).await {
                return (500, serde_json::json!({ "error": e }));
            }
            (200, serde_json::json!({ "ok": true }))
        }

        // A claimed pilot arriving on a new device: name and password in, a
        // device secret of this device's own out. Each device keeps its own,
        // which is what makes one revocable without the others.
        //
        // Refusals do not say which half was wrong. A login that answers
        // "no such name" is a name oracle, and the names are the one thing
        // here that is public anyway; saying nothing costs nothing.
        "/v1/login" => {
            let name = s("name");
            if !meta.throttle.allow(&format!("login:{ip}"), 10, quarter)
                || !meta.throttle.allow(&format!("login:{}", name.to_lowercase()), 10, quarter)
            {
                return (429, serde_json::json!({ "error": "too many tries; wait a while" }));
            }
            let miss = || (403, serde_json::json!({ "error": "that name and password do not match" }));
            let Ok(Some(row)) = db
                .query_opt(
                    "select n.account, c.hash from names n
                     join credentials c on c.account = n.account and c.method = 'password'
                     where lower(n.call_sign) = lower($1)",
                    &[&name],
                )
                .await
            else {
                return miss();
            };
            let account: i64 = row.get(0);
            let stored: String = row.get(1);
            let password = s("password");
            let ok = tokio::task::spawn_blocking(move || verify_password(&password, &stored))
                .await
                .unwrap_or(false);
            if !ok {
                return miss();
            }
            let secret = new_secret();
            if let Err(e) = add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await {
                return (500, serde_json::json!({ "error": e }));
            }
            let _ = db
                .execute("update accounts set last_seen = now() where id = $1", &[&account])
                .await;
            (200, serde_json::json!({ "secret": secret, "account": account }))
        }

        // The reroll, server-side because the name is server-side now. Works
        // the same for a guest and a claimed pilot: the account number never
        // moves, so the rating and the history ride through the rename.
        "/v1/rename" => {
            let Some(account) = account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            if !meta.throttle.allow(&format!("rename:{ip}"), 30, hour) {
                return (429, serde_json::json!({ "error": "that is plenty of rerolling. Try again later" }));
            }
            match christen(&db, account).await {
                Ok(name) => (200, serde_json::json!({ "name": name })),
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
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

        // ---------------------------------------------------- admin panel
        //
        // The routes behind the account flag, called by the static page at
        // admin.<domain>. Each takes the caller's device secret and runs it
        // through `admin_for`; the hostname is not the boundary and neither
        // is anything the client claims about itself.
        //
        // The flag itself has no route. Granting and revoking are SQL run by
        // the operator on the central host, per deploy/README.md, which is
        // also why there is no VW_ADMIN_TOKEN anywhere any more: the one
        // thing it still guarded stopped being reachable over HTTP.

        // A pilot, looked up by call sign or account number. Behind the flag
        // rather than public, because standing and last_seen are between the
        // fleet and its operators.
        "/v1/admin/pilot" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let by_id = body.get("account").and_then(|v| v.as_i64());
            let q = "select a.id, coalesce(n.call_sign, ''), a.kind,
                            a.banned, coalesce(a.reason, ''), a.admin,
                            to_char(a.created at time zone 'utc', 'YYYY-MM-DD'),
                            to_char(a.last_seen at time zone 'utc', 'YYYY-MM-DD HH24:MI'),
                            exists (select 1 from credentials c
                                    where c.account = a.id and c.method <> 'secret')
                     from accounts a left join names n on n.account = a.id";
            let row = match by_id {
                Some(id) => {
                    db.query_opt(&format!("{q} where a.id = $1"), &[&id]).await
                }
                None => {
                    db.query_opt(
                        &format!("{q} where lower(n.call_sign) = lower($1)"),
                        &[&s("name")],
                    )
                    .await
                }
            };
            match row {
                Ok(Some(r)) => {
                    let kind: i16 = r.get(2);
                    (200, serde_json::json!({
                        "account": r.get::<_, i64>(0),
                        "name": r.get::<_, String>(1),
                        "kind": match kind_of(kind) {
                            Kind::Human => "human",
                            Kind::HouseBot => "house bot",
                            Kind::ThirdPartyBot => "third-party bot",
                        },
                        "banned": r.get::<_, bool>(3),
                        "reason": r.get::<_, String>(4),
                        "admin": r.get::<_, bool>(5),
                        "created": r.get::<_, String>(6),
                        "last_seen": r.get::<_, String>(7),
                        "claimed": r.get::<_, bool>(8),
                    }))
                }
                Ok(None) => (404, serde_json::json!({ "error": "no such pilot" })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // The fleet ban: a mark on the account, enforced where tokens are
        // minted, held to an admin account's secret. Refuses to touch an
        // account that holds the flag: an admin unseating an admin is a
        // decision for whoever holds the box, so it goes revoke-in-the-
        // database first, and one compromised session cannot lock the rest
        // of the operators out.
        "/v1/admin/ban" => {
            let Some(actor) = admin_for(&db, &s("secret")).await else {
                return (403, serde_json::json!({ "error": "not an admin" }));
            };
            let account = body.get("account").and_then(|v| v.as_i64()).unwrap_or(0);
            let banned = body.get("banned").and_then(|v| v.as_bool()).unwrap_or(true);
            let reason = s("reason");
            let r = db
                .execute(
                    "update accounts set banned = $2, reason = $3
                     where id = $1 and not admin",
                    &[&account, &banned, &reason],
                )
                .await;
            match r {
                Ok(0) => (400, serde_json::json!({
                    "error": "no such account, or it holds the admin flag; \
                              revoke that in the database first"
                })),
                Ok(_) => {
                    // Actions get no audit trail from the catalog, so say it
                    // here, the way the directory notes its commands.
                    println!(
                        "meta: admin {actor} set banned={banned} on {account}: {reason:?}"
                    );
                    (200, serde_json::json!({ "account": account, "banned": banned }))
                }
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // An operator verb, sent to a running arena through the directory.
        //
        // Different in kind from the ban above, and the difference is why it
        // takes this path rather than a database write: a ban is a mark on an
        // account that outlives every process, while these reach one process
        // now and mean nothing afterwards. The registration socket is where
        // they go, per admin.md, so no arena exposes an admin listener and a
        // directory can only command what has registered with it.
        //
        // The actor is read from the database here rather than taken from the
        // body. An audit row naming whoever the caller said they were would
        // be a record of nothing.
        "/v1/admin/command" => {
            let Some(actor) = admin_for(&db, &s("secret")).await else {
                return (403, serde_json::json!({ "error": "not an admin" }));
            };
            let who: String = db
                .query_opt("select call_sign from names where account = $1", &[&actor])
                .await
                .ok()
                .flatten()
                .map(|r| r.get(0))
                .unwrap_or_else(|| format!("account {actor}"));
            let cmd = crate::fleet::OperatorCommand {
                instance: s("instance"),
                verb: s("verb"),
                args: s("args"),
                actor: who.clone(),
            };
            let frame = crate::fleet::frame(crate::fleet::O2D_COMMAND, &cmd);
            let url = directory_url();
            let Some(body) =
                crate::directory::ask_with(&url, frame, crate::fleet::D2O_COMMAND).await
            else {
                return (503, serde_json::json!({
                    "error": format!("no answer from the directory at {url}")
                }));
            };
            let Ok(sent) = serde_json::from_str::<crate::fleet::CommandSent>(&body) else {
                return (502, serde_json::json!({ "error": "unreadable reply" }));
            };
            println!(
                "meta: {who} sent {:?} {:?} to {:?}: {} instance(s)",
                cmd.verb, cmd.args, cmd.instance, sent.sent
            );
            if sent.sent == 0 {
                return (400, serde_json::json!({ "error": sent.error }));
            }
            // What it did is not known yet and cannot be: the arena answers
            // the directory a moment later, and that lands in the audit log
            // the fleet view carries.
            (200, serde_json::json!({ "sent": sent.sent }))
        }

        // Give a pilot a call sign: the one an operator typed, or a fresh
        // draw from the pool when they typed nothing.
        //
        // The typed half is an exception to a rule the rest of this service
        // keeps, and it is worth being plain about which half of that rule
        // it spends. docs/design/accounts.md rests two properties on names
        // being dealt. Fleet-wide uniqueness survives untouched, because the
        // arbiter was never the generator: it is the unique index on
        // `lower(call_sign)`, and a collision is refused here the same way it
        // is refused a redraw in `christen`. The curated register does not
        // survive, because a person now chooses some of the words. That is
        // the trade, made deliberately, and it is bounded by who can make it:
        // an account with the admin flag, acting on one pilot at a time, with
        // the actor and the old and new names on the log line. No player
        // facing route accepts a proposed name, which is what decision 28's
        // argument about moderation queues was actually about.
        //
        // Not throttled the way `/v1/rename` is. That limit stands between a
        // script and the name pool, and an operator is neither.
        "/v1/admin/rename" => {
            let Some(actor) = admin_for(&db, &s("secret")).await else {
                return (403, serde_json::json!({ "error": "not an admin" }));
            };
            let account = body.get("account").and_then(|v| v.as_i64()).unwrap_or(0);
            let (kind, was): (i16, String) = match db
                .query_opt(
                    "select a.kind, coalesce(n.call_sign, '') from accounts a
                     left join names n on n.account = a.id where a.id = $1",
                    &[&account],
                )
                .await
            {
                Ok(Some(r)) => (r.get(0), r.get(1)),
                Ok(None) => return (404, serde_json::json!({ "error": "no such account" })),
                Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
            };
            // A house bot's name is its identity: the roster individual is
            // looked up by it, so renaming one would leave the scoreboard
            // disagreeing with the roster that seeded its rating.
            if kind_of(kind).is_bot() {
                return (400, serde_json::json!({
                    "error": "a bot's name is how its roster identity is found; \
                              renaming it would split the two"
                }));
            }

            let asked = s("name");
            if asked.trim().is_empty() {
                // Nothing typed means deal one, which is what the reroll
                // button sends and what a player's own reroll does.
                return match christen(&db, account).await {
                    Ok(name) => {
                        println!("meta: admin {actor} rerolled {account} from {was:?} to {name:?}");
                        (200, serde_json::json!({ "account": account, "name": name }))
                    }
                    Err(e) => (500, serde_json::json!({ "error": e })),
                };
            }

            // The same cleaning an arena applies to any name it is handed:
            // printable ASCII, no control characters, 24 at the outside. The
            // scoreboard was drawn for "Solstice 999", so a long one fits the
            // database and not the screen; that is the operator's to judge.
            let name = clean_name(&asked);
            if name.is_empty() {
                return (400, serde_json::json!({
                    "error": "a call sign needs printable characters"
                }));
            }
            match set_name(&db, account, &name).await {
                Ok(()) => {
                    println!("meta: admin {actor} renamed {account} from {was:?} to {name:?}");
                    (200, serde_json::json!({ "account": account, "name": name }))
                }
                // The index is the arbiter, and it says this one is held.
                Err(e) if e == TAKEN => (409, serde_json::json!({
                    "error": format!("{name:?} is already somebody's call sign")
                })),
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
        }

        // Pilots, filtered by what an operator has typed so far.
        //
        // Searched here rather than filtered in the page. A panel that pulls
        // every account down and greps it in the browser is fine on a
        // deployment with forty of them and wrong on the one this is built
        // for: guests are free and accumulate for a week, so the list is
        // unbounded and the filter belongs where the index is.
        //
        // `strpos` rather than `like`, so a `%` or a `_` somebody types is a
        // character to find and not a wildcard that quietly matches
        // everything.
        "/v1/admin/pilots" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let q = s("q");
            let q = q.trim();
            // A leading # is how this panel writes an account number, and
            // typing one should not stop the number being one.
            let number: i64 = q.trim_start_matches('#').parse().unwrap_or(-1);
            let q = q.to_string();
            let rows = db
                .query(
                    "select a.id, coalesce(n.call_sign, ''), a.kind, a.banned, a.admin,
                            exists (select 1 from credentials c
                                    where c.account = a.id and c.method = 'password'),
                            to_char(a.last_seen at time zone 'utc', 'YYYY-MM-DD HH24:MI')
                     from accounts a left join names n on n.account = a.id
                     where $1 = ''
                        or strpos(lower(coalesce(n.call_sign, '')), lower($1)) > 0
                        or a.id = $2
                     order by a.last_seen desc
                     limit 100",
                    &[&q, &number],
                )
                .await;
            match rows {
                Ok(rs) => (200, serde_json::json!({
                    // Said rather than inferred from the length, so a page
                    // showing a hundred rows can say whether that is all of
                    // them or the first hundred.
                    "capped": rs.len() == 100,
                    "pilots": rs.iter().map(|r| {
                        let kind: i16 = r.get(2);
                        serde_json::json!({
                            "account": r.get::<_, i64>(0),
                            "name": r.get::<_, String>(1),
                            "kind": match kind_of(kind) {
                                Kind::Human => "human",
                                Kind::HouseBot => "house bot",
                                Kind::ThirdPartyBot => "third-party bot",
                            },
                            "banned": r.get::<_, bool>(3),
                            "admin": r.get::<_, bool>(4),
                            "claimed": r.get::<_, bool>(5),
                            "last_seen": r.get::<_, String>(6),
                        })
                    }).collect::<Vec<_>>(),
                })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // Give the admin flag, or take it back.
        //
        // Behind the flag itself, which is a real change from how this
        // shipped: granting used to be SQL an operator ran on the box, so a
        // leaked panel session could act as an admin and never appoint one.
        // It can now do both. What is kept is every guard that did not
        // depend on that containment, and one new one.
        //
        // Only a claimed human may hold it. The panel signs in with a
        // password, which a guest does not have and a bot's `house`
        // credential is not, and the sweeper deletes idle guests, which is no
        // way for an operator account to end.
        //
        // And the last admin cannot be removed. Two operators disagreeing is
        // a conversation; a deployment with nobody who can open the panel is
        // a trip to the database, and the one keystroke between those two
        // states should not be this one.
        "/v1/admin/grant" => {
            let Some(actor) = admin_for(&db, &s("secret")).await else {
                return (403, serde_json::json!({ "error": "not an admin" }));
            };
            let account = body.get("account").and_then(|v| v.as_i64()).unwrap_or(0);
            let admin = body.get("admin").and_then(|v| v.as_bool()).unwrap_or(true);
            let row = db
                .query_opt(
                    "select a.kind, a.admin,
                            exists (select 1 from credentials c
                                    where c.account = a.id and c.method = 'password')
                     from accounts a where a.id = $1",
                    &[&account],
                )
                .await;
            let (kind, held, has_password): (i16, bool, bool) = match row {
                Ok(Some(r)) => (r.get(0), r.get(1), r.get(2)),
                Ok(None) => return (404, serde_json::json!({ "error": "no such account" })),
                Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
            };
            if admin && kind_of(kind).is_bot() {
                return (400, serde_json::json!({
                    "error": "a bot cannot open the panel; it has no password to sign in with"
                }));
            }
            if admin && !has_password {
                return (400, serde_json::json!({
                    "error": "that account has no password, so it could not sign in. \
                              It has to claim one first"
                }));
            }
            if !admin && held {
                let others: i64 = db
                    .query_one("select count(*) from accounts where admin and id <> $1", &[&account])
                    .await
                    .map(|r| r.get(0))
                    .unwrap_or(0);
                if others == 0 {
                    return (409, serde_json::json!({
                        "error": "that is the last admin; granting somebody else first \
                                  keeps this deployment out of the database"
                    }));
                }
            }
            let r = db
                .execute("update accounts set admin = $2 where id = $1", &[&account, &admin])
                .await;
            match r {
                Ok(0) => (404, serde_json::json!({ "error": "no such account" })),
                Ok(_) => {
                    println!("meta: admin {actor} set admin={admin} on account {account}");
                    (200, serde_json::json!({ "account": account, "admin": admin }))
                }
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // Every account currently marked, which is the half of banning the
        // panel could not show: you could mark somebody and never see the
        // list you had built.
        "/v1/admin/bans" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let rows = db
                .query(
                    "select a.id, coalesce(n.call_sign, ''), coalesce(a.reason, ''),
                            to_char(a.last_seen at time zone 'utc', 'YYYY-MM-DD HH24:MI')
                     from accounts a left join names n on n.account = a.id
                     where a.banned order by a.id desc",
                    &[],
                )
                .await;
            match rows {
                Ok(rs) => (200, serde_json::json!({
                    "bans": rs.iter().map(|r| serde_json::json!({
                        "account": r.get::<_, i64>(0),
                        "name": r.get::<_, String>(1),
                        "reason": r.get::<_, String>(2),
                        "last_seen": r.get::<_, String>(3),
                    })).collect::<Vec<_>>(),
                })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // The fleet, as the directory on this host has observed it. Relayed
        // rather than served here: the directory holds the registrations and
        // this process holds the only thing that can check an admin flag, so
        // the panel asks the one that can authorise and it asks the one that
        // knows. The directory answers this only over a socket no proxy
        // touched, which is why the address below is loopback and not the
        // public /dir route.
        //
        // Also where two silent failures become visible. A directory serving
        // an older catalog version than another is a publish that half
        // landed. And a verifying key in the catalog that is not the public
        // half of the key this process signs with means every token in the
        // fleet fails its check: pilots keep flying, as guests, rating
        // nothing, with nothing anywhere saying so.
        "/v1/admin/fleet" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let url = directory_url();
            let Some(body) =
                crate::directory::request(&url, crate::fleet::O2D_FLEET, crate::fleet::D2O_FLEET).await
            else {
                return (503, serde_json::json!({
                    "error": format!("no answer from the directory at {url}")
                }));
            };
            let Ok(view) = serde_json::from_str::<crate::fleet::View>(&body) else {
                return (502, serde_json::json!({ "error": "unreadable fleet view" }));
            };
            // The audit rides in the same reply and is passed through as it
            // arrived: it is the directory's record, and this process has
            // nothing to add to it.
            let audit = serde_json::from_str::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| v.get("audit").cloned())
                .unwrap_or_else(|| serde_json::json!([]));
            let mine = token::to_hex(meta.signing.verifying_key().as_bytes());
            (200, serde_json::json!({
                "catalog_version": view.catalog_version,
                "audit": audit,
                // Three builds to hold against each other: this process, the
                // directory that answered, and each arena below. A converge
                // that lands on one and not another leaves a fleet that
                // works and disagrees, which is invisible from every other
                // number here.
                "build": crate::metrics::commit(),
                "directory_build": view.build,
                // Said as an answer rather than as two keys to compare by eye,
                // because the whole value of the check is that nobody is
                // looking when it matters.
                "key_agrees": view.meta_key.eq_ignore_ascii_case(&mine),
                "meta_key": mine,
                "instances": view.instances.iter().map(|i| serde_json::json!({
                    "instance": i.instance,
                    "zone": i.zone,
                    "address": i.address,
                    "region": i.region,
                    "pool": i.pool,
                    "players": i.players,
                    "bots": i.bots,
                    "bots_wanted": i.bots_wanted,
                    // The rooms themselves, not a count of them. An instance
                    // holding one room of twenty and an instance holding
                    // four of five are the same number and different
                    // situations, and the fill ladder is the thing an
                    // operator is judging when they look here.
                    "rooms": i.rooms.iter().map(|r| serde_json::json!({
                        "number": r.number,
                        "players": r.players,
                        "bots": r.bots,
                        "full": r.full,
                    })).collect::<Vec<_>>(),
                    "max_rooms": i.max_rooms,
                    "build": i.build,
                    "capped": i.capped,
                    "verified": i.verified,
                    "age_ms": i.age_ms,
                    "intent": i.intent,
                    "pinned": i.pinned,
                    "pinned_by": i.pinned_by,
                    "pinned_at_ms": i.pinned_at_ms,
                    "tick_us": i.metrics.tick_us,
                    "bw_per_player": i.metrics.bw_per_player,
                    "snapshot_bytes": i.metrics.snapshot_bytes,
                    "queue_depth": i.metrics.queue_depth,
                    "lag_actions": i.metrics.lag_actions,
                })).collect::<Vec<_>>(),
            }))
        }

        // Who holds the flag, so the panel can show the set it cannot change.
        "/v1/admin/admins" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let rows = db
                .query(
                    "select a.id, coalesce(n.call_sign, ''),
                            to_char(a.last_seen at time zone 'utc', 'YYYY-MM-DD HH24:MI')
                     from accounts a left join names n on n.account = a.id
                     where a.admin order by a.id",
                    &[],
                )
                .await;
            match rows {
                Ok(rs) => (200, serde_json::json!({
                    "admins": rs.iter().map(|r| serde_json::json!({
                        "account": r.get::<_, i64>(0),
                        "name": r.get::<_, String>(1),
                        "last_seen": r.get::<_, String>(2),
                    })).collect::<Vec<_>>(),
                })),
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
///
/// Delivery is at-least-once. A spool retries a whole batch when any of it
/// fails, and a batch that committed under a lost reply is posted again, so
/// the same event arriving twice is ordinary weather rather than a fault.
/// The arena-minted id is the umbrella: the log refuses the second copy, and
/// a refused copy must not touch the projection, or every retry would bend
/// somebody's rating by a delta the log recorded once.
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
    // Refused rather than taken as-is, because an event without an id cannot
    // be deduplicated, and one arena quietly exempt from exactly-once is the
    // failure this field exists to end.
    let Some(event_id) = ev.get("id").and_then(|v| v.as_i64()) else {
        return Err("no event id".into());
    };
    let before = ev.get("victim_before").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let after = ev.get("victim_after").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let tick = ev.get("tick").and_then(|v| v.as_i64()).unwrap_or(0);
    let victim_kind = ev.get("victim_kind").and_then(|v| v.as_i64()).unwrap_or(0) as i16;
    // Absent means keep, which is the safe direction: an arena too old to
    // send this is not one whose events should quietly expire.
    let bots_only = ev.get("bots_only").and_then(|v| v.as_bool()).unwrap_or(false);
    let empty = Vec::new();
    let credits = ev.get("credits").and_then(|v| v.as_array()).unwrap_or(&empty);

    let db = db
        .transaction()
        .await
        .map_err(|e| format!("cannot open a transaction: {e}"))?;

    let stored = db
        .execute(
            "insert into rated_events
               (event_id, class, zone, instance, tick, victim, victim_kind,
                victim_before, victim_after, credits, bots_only)
             values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
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
            ],
        )
        .await
        .map_err(|e| format!("cannot store event: {e}"))?;
    // A retry finding its work already done. Reported as success, because the
    // spool is asking "is this filed", and it is; applying the deltas again is
    // what this function exists to never do.
    if stored == 0 {
        return db.commit().await.map_err(|e| format!("cannot commit: {e}"));
    }

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

    // Who is asking, for the throttles. Behind Caddy every peer is loopback
    // and the truth rides in X-Forwarded-For; anything reaching this port
    // directly could write that header itself, but reaching it directly
    // means being on the host, which is a bigger problem than a throttle.
    let head = text.split_once("\r\n\r\n").map(|(h, _)| h).unwrap_or(&text);
    let ip = head
        .split("\r\n")
        .find_map(|l| {
            let l = l.to_ascii_lowercase();
            l.strip_prefix("x-forwarded-for:")
                .map(|v| v.trim().split(',').next().unwrap_or("").trim().to_string())
        })
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            s.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default()
        });

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
        route(&meta, path, &parsed, &ip).await
    };

    let out = out.to_string();
    // Every code any route here returns. A route answering with one that is
    // missing from this list does not fail loudly: it sends the right body
    // under "500 Internal Server Error", so the caller reads a considered
    // refusal as a server fault. That is how a 409 shipped looking like a
    // crash, and it is why this list is worth keeping in step.
    let status = match code {
        200 => "200 OK",
        400 => "400 Bad Request",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        429 => "429 Too Many Requests",
        502 => "502 Bad Gateway",
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
    // A deployment with no accounts is a real configuration, and it is the one
    // the tests and the local overlay run in. It has to be *declared*, though,
    // because the failure it looks like is identical and far more likely.
    //
    // This used to print a line and return, which exits zero, which
    // `restart: on-failure` correctly declines to restart. The fleet then came
    // up healthy in every way anybody watches: the games list worked, people
    // flew, and accounts were simply gone. Everyone a guest, no rating kept,
    // nothing red. The credential lives in one file on one host, so the way to
    // reach that state is to rebuild the host and forget to paste it back.
    //
    // So an empty database is a hard failure unless somebody said they meant
    // it, the same shape as VW_REPORT=0 meaning "do not file rated events".
    let url = std::env::var("VW_META_DATABASE").unwrap_or_default();
    let declared_off = std::env::var("VW_ACCOUNTS").map(|v| v == "0").unwrap_or(false);
    if url.is_empty() {
        if declared_off {
            println!("meta: VW_ACCOUNTS=0, so this deployment keeps no accounts");
        } else {
            eprintln!("meta: VW_META_DATABASE is empty and VW_ACCOUNTS is not 0.");
            eprintln!("  Refusing to start rather than serving a fleet whose accounts");
            eprintln!("  silently do not exist: every pilot would be a guest and no");
            eprintln!("  rating would be kept, with nothing on fire to say so.");
            eprintln!("  Set the connection string, or set VW_ACCOUNTS=0 to mean it.");
            std::process::exit(1);
        }
        return;
    }
    let Some(signing) = std::env::var("VW_META_KEY").ok().and_then(|k| token::signing_key_from_hex(&k))
    else {
        eprintln!("meta: VW_META_KEY must be 64 hex characters; make one with 'vectorwake-server metakey'");
        eprintln!("  Its other half is the catalog's [meta] verifying key, so the pair");
        eprintln!("  travels with the catalog rather than being minted per host.");
        std::process::exit(1);
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

    // The guest sweeper. A guest is a human account with no password, and one
    // that has not begun a session in a week has its account deleted whole:
    // credentials, name and ratings cascade, which is what hands the call
    // sign back to the pool. Claimed accounts never expire; a password is a
    // person saying they mean to come back. The history in rated_events
    // carries no foreign key on purpose, so what happened stays happened.
    //
    // Admin-flagged accounts are never swept either. The flag is set by an
    // operator's hand in the database, and the sweeper does not unmake
    // operator decisions; an unclaimed account that was flagged by mistake
    // is the operator's to notice, not this loop's to collect.
    {
        let pool = pool.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let Ok(db) = pool.get().await else { continue };
                match db
                    .execute(
                        "delete from accounts
                         where kind = $1 and last_seen < now() - interval '7 days'
                           and not admin
                           and not exists (select 1 from credentials c
                                           where c.account = accounts.id
                                             and c.method = 'password')",
                        &[&KIND_HUMAN],
                    )
                    .await
                {
                    Ok(n) if n > 0 => println!("meta: released {n} idle guest account(s)"),
                    _ => {}
                }
            }
        });
    }

    // The retention sweeper. The log grows at a rate the players do not set:
    // bots fight at fill around the clock, which is most of ~300,000 events a
    // day, and at 400 to 500 bytes a row that fills a 25 GB database inside a
    // year. Throughput was never the problem. Space is.
    //
    // What gets dropped follows from what the log is for. A row with a person
    // in it is replayed by a model migration or a disputed rating, so it is
    // kept for good. A bot-on-bot row has done its work the moment the
    // projection applies it, and a bot's career re-seeds from calibration
    // anyway.
    //
    // A bounded delete rather than the partition drop meta-layer.md sketched.
    // Dropping a partition is cheaper per row, but it needs the table
    // partitioned by bot-only and by month together, a job to make next
    // month's partitions, and a migration to convert the table that exists.
    // At a few hundred thousand rows a day the delete is far below what one
    // vCPU does without noticing, and it is twenty lines that cannot leave a
    // month unpartitioned and silently refuse every write.
    {
        let pool = pool.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let Ok(db) = pool.get().await else { continue };
                // Bounded so one pass cannot open a transaction over a
                // backlog. An hour's production is a fraction of this, so a
                // sweeper behind after an outage still catches up.
                match db
                    .execute(
                        "delete from rated_events where ctid in (
                           select ctid from rated_events
                           where bots_only and at < now() - interval '21 days'
                           limit 50000)",
                        &[],
                    )
                    .await
                {
                    Ok(n) if n > 0 => println!("meta: retired {n} bot-only rated event(s)"),
                    Err(e) => println!("meta: retention pass failed: {e}"),
                    _ => {}
                }
            }
        });
    }

    let verifying = token::to_hex(signing.verifying_key().as_bytes());
    let meta = Arc::new(Meta { pool, signing, catalog, throttle: Throttle::default() });
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
    println!("signing key, a secret, shown once:");
    println!();
    println!("  {}", token::to_hex(&k.to_bytes()));
    println!();
    println!("verifying key, its public half, which the catalog names as");
    println!("env:VW_META_VERIFY:");
    println!();
    println!("  {}", token::to_hex(k.verifying_key().as_bytes()));
    println!();
    println!("Store both and nothing needs a commit:");
    println!();
    println!("  fleet.sh secrets put VW_META_KEY       (the first)");
    println!("  fleet.sh secrets put VW_META_VERIFY    (the second)");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_call_sign_is_a_word_and_three_digits() {
        for _ in 0..200 {
            let n = new_call_sign();
            let (word, digits) = n.rsplit_once(' ').expect("a space in every name");
            assert!(CALL_WORDS.contains(&word), "{n} draws from the list");
            assert_eq!(digits.len(), 3, "{n} carries three digits");
            assert!(digits.parse::<u32>().is_ok_and(|d| (100..1000).contains(&d)));
            // The scoreboard's widest column: nothing generated may outgrow it.
            assert!(n.len() <= 12, "{n} is wider than the scoreboard");
        }
    }

    #[test]
    fn call_words_collide_with_nothing() {
        // One namespace, four sources of names in it: players from this list,
        // the AI roster from ai.rs, the hulls the interface names beside them,
        // and the rating tiers. A shared word would make the unique index
        // refuse an AI registration, or leave a scoreboard reading as two of
        // a kind, so the lists are held apart here.
        //
        // The tiers are the subtlest of the four: a pilot called Ace 412
        // standing in the Ace tier is one word doing two unrelated jobs on
        // the same scoreboard, and nothing but this check would catch it.
        let mut seen = std::collections::HashSet::new();
        for w in CALL_WORDS {
            assert!(seen.insert(w.to_lowercase()), "{w} appears twice");
            assert!(!w.is_empty() && w.len() <= 8, "{w} outgrows the column");
        }
        for (name, _, _) in crate::ai::CALIBRATED {
            assert!(!seen.contains(&name.to_lowercase()), "{name} is an AI regular");
        }
        for name in crate::ai::FILL_NAMES {
            assert!(!seen.contains(&name.to_lowercase()), "{name} is AI fill");
        }
        for name in crate::ai::CLASS_NAMES {
            assert!(!seen.contains(&name.to_lowercase()), "{name} is a hull");
        }
        for (name, _) in crate::rating::TIERS {
            assert!(!seen.contains(&name.to_lowercase()), "{name} is a rating tier");
        }
    }

    #[test]
    fn two_secrets_differ() {
        assert_ne!(new_secret(), new_secret());
        assert_eq!(new_secret().len(), 64, "32 bytes in hex");
    }

    #[test]
    fn a_password_verifies_and_a_guess_does_not() {
        let stored = hash_password("orbital decay").expect("hashes");
        assert!(stored.starts_with("$argon2"), "self-describing encoding");
        assert!(verify_password("orbital decay", &stored));
        assert!(!verify_password("orbital  decay", &stored));
        assert!(!verify_password("", &stored));
        assert!(!verify_password("orbital decay", "not a hash at all"));
    }

    #[test]
    fn a_password_is_sized_and_nothing_else() {
        assert!(password_trouble("short").is_some());
        assert!(password_trouble(&"x".repeat(65)).is_some());
        assert!(password_trouble("just six").is_none());
        // No composition rules: spaces, words, whatever a person keeps.
        assert!(password_trouble("correct horse battery").is_none());
    }

    #[test]
    fn the_throttle_closes_and_reopens() {
        let t = Throttle::default();
        let w = std::time::Duration::from_millis(30);
        for _ in 0..5 {
            assert!(t.allow("k", 5, w), "under the limit");
        }
        assert!(!t.allow("k", 5, w), "the sixth is refused");
        assert!(t.allow("other", 5, w), "keys do not share a window");
        std::thread::sleep(w);
        assert!(t.allow("k", 5, w), "a new window opens");
    }

    #[test]
    fn names_are_cleaned_the_way_the_arena_cleans_them() {
        assert_eq!(clean_name("  Vesper 47  "), "Vesper 47");
        assert_eq!(clean_name("bad\u{1}name"), "badname");
        assert_eq!(clean_name(&"x".repeat(80)).len(), 24);
        assert_eq!(clean_name("   "), "");
    }

}
