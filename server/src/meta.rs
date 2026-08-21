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
//! Identity verification on the join path stays offline: this service mints a
//! signed token and arenas verify it with a catalog key. Rated admission
//! also claims a renewable lease here, which is how one account is kept to one
//! active rated session across arena processes.
//!
//! It holds no email addresses or third-party identities. Pilot records contain
//! generated call signs, ratings, hashed random secrets and argon2-hashed
//! passwords. Browser error groups also carry a bounded message, stack, build,
//! page path, user agent and reported account number for thirty days.

use std::sync::Arc;

use deadpool_postgres::{Client, Pool};
use rand::Rng;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::catalog::sha256_hex;
use crate::pilot;
use crate::rating;
use crate::sim;
use crate::token::{self, Claims, ClassRating, Kind};

mod public_pilots;
mod settlement;
mod shop;

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
-- The final blow, separate from the damage credits that move ratings. Older
-- rows cannot answer this, so it is nullable; the career-stat backfill below
-- uses the largest credited share for those rows and every new row is exact.
alter table rated_events add column if not exists killer bigint;
create index if not exists rated_events_by_killer on rated_events (killer, at)
    where killer is not null;
-- The public career line. This survives the short retention on bot-only rated
-- events, which is what makes an all-time bot total possible without keeping
-- their round-the-clock combat log forever.
create table if not exists pilot_stats (
    account  bigint primary key references accounts(id) on delete cascade,
    kills    bigint not null default 0,
    deaths   bigint not null default 0,
    assists  bigint not null default 0
);
-- Seed the projection once for pilots whose fights predate it. Exact killers
-- were not present in those rows, so the largest damage share gets the kill
-- and every other contributor gets an assist. ON CONFLICT keeps later starts
-- from replaying the backfill over live counters.
with event_parties as (
    select re.victim, re.credits,
           coalesce(re.killer, top_credit.account) as killer
    from rated_events re
    left join lateral (
        select (item.credit->>'account')::bigint as account
        from jsonb_array_elements(re.credits) as item(credit)
        order by (item.credit->>'weight')::double precision desc,
                 (item.credit->>'account')::bigint
        limit 1
    ) top_credit on true
), deaths as (
    select victim as account, count(*)::bigint as n
    from event_parties group by victim
), kills as (
    select killer as account, count(*)::bigint as n
    from event_parties
    where killer is not null and killer <> victim
    group by killer
), assists as (
    select (item.credit->>'account')::bigint as account, count(*)::bigint as n
    from event_parties ep
    cross join lateral jsonb_array_elements(ep.credits) as item(credit)
    where (item.credit->>'account')::bigint <> coalesce(ep.killer, -1)
    group by (item.credit->>'account')::bigint
), participants as (
    select account from deaths
    union select account from kills
    union select account from assists
)
insert into pilot_stats (account, kills, deaths, assists)
select a.id, coalesce(k.n, 0), coalesce(d.n, 0), coalesce(s.n, 0)
from accounts a join participants p on p.account = a.id
left join kills k on k.account = a.id
left join deaths d on d.account = a.id
left join assists s on s.account = a.id
on conflict (account) do nothing;
-- What happened to a pilot, as opposed to what it did to their rating. An
-- arena is the only thing that sees a refusal at the door, a hull change or the
-- difference between quitting and being kicked, and none of it survived the
-- tick that produced it. See decisions.md 42 and the event list in
-- meta-layer.md.
--
-- No foreign key to accounts, for the reason rated_events has none: the guest
-- sweeper would otherwise cascade a week-old pilot's history away, and what
-- happened stays happened. No address column either, and that one is a
-- property to keep rather than a column nobody got round to. The arena could
-- not fill it if it wanted to.
create table if not exists pilot_events (
    id        bigserial primary key,
    -- Stamped by the arena, not defaulted here: a spool that drains an hour
    -- late would otherwise file an hour of history as having happened at once,
    -- which is exactly the outage you were trying to read.
    at        timestamptz not null default now(),
    -- One connection. Null for the rows the meta-layer writes about an account
    -- itself, which happen with no arena and no socket involved.
    session   text,
    -- The account, where there is one. Guests fly under a call sign alone.
    pilot     bigint,
    name      text not null default '',
    bot       boolean not null default false,
    kind      text not null,
    zone      text not null default '',
    instance  text not null default '',
    room      integer,
    tick      bigint not null default 0,
    detail    jsonb not null default '{}',
    event_id  bigint
);
-- Reconstructing one stay, which is the question this table exists to answer.
-- Partial, because the meta-layer's own rows carry no session and there is no
-- reason to index a null nobody will ask for.
create index if not exists pilot_events_by_session on pilot_events (session, at)
    where session is not null;
-- And one pilot's history across every stay, which is how a session gets found
-- in the first place. Partial for the same reason: most rows in a busy fleet
-- are guests, and a guest is only ever reachable through their session.
create index if not exists pilot_events_by_pilot on pilot_events (pilot, at)
    where pilot is not null;
-- Idempotency, exactly as rated_events does it: the arena mints event_id when
-- it files, delivery is at-least-once, and the second arrival of a row has to
-- be refused rather than stored twice. The meta-layer's own rows leave it null,
-- which a unique index does not mind.
create unique index if not exists pilot_events_once on pilot_events (event_id);
-- Retention reads exactly this, and both halves of it. Unlike rated_events,
-- nothing here is kept forever: a per-pilot behavior log with no expiry is a
-- different thing from a ladder, and the fleet's database is 25 GB.
create index if not exists pilot_events_sweep on pilot_events (bot, at);
-- What an account may slot beyond the baseline, over the core's flat kit
-- space: one row per slot the shop has moved. A missing row is the baseline,
-- so a new account needs no rows at all and buying something is one upsert.
--
-- The baseline itself lives in the core (`sim_base_entitlements`) rather than
-- being written out here as thirty-odd rows per account, because it is a rule
-- about the game and not a fact about anybody.
create table if not exists entitlements (
    account bigint not null references accounts(id) on delete cascade,
    slot    smallint not null,
    n       smallint not null,
    primary key (account, slot)
);
-- What a pilot has chosen to fly, per hull, as the kit's own bytes. Written by
-- the hangar and read at a join; the arena checks it against the row above and
-- against the hull before it deals it, so a stale kit from before a retune is
-- refused rather than honored.
create table if not exists kits (
    account bigint not null references accounts(id) on delete cascade,
    class   text not null,
    kit     bytea not null,
    primary key (account, class)
);
-- Rivets: bounty taken, banked. One row an account, moved by the shop and by
-- the kill rows the arenas file.
create table if not exists wallets (
    account bigint primary key references accounts(id) on delete cascade,
    rivets  bigint not null default 0
);
create table if not exists client_errors (
    fingerprint text primary key,
    first_at    timestamptz not null default now(),
    last_at     timestamptz not null default now(),
    occurrences bigint not null default 1,
    kind        text not null,
    message     text not null,
    stack       text not null default '',
    build       text not null default '',
    origin      text not null default '',
    page        text not null default '',
    user_agent  text not null default '',
    account     bigint references accounts(id) on delete cascade
);
alter table client_errors add column if not exists account bigint;
create index if not exists client_errors_by_last on client_errors (last_at desc);
create table if not exists client_debug (
    id               bigserial primary key,
    at               timestamptz not null default now(),
    kind             text not null,
    build            text not null default '',
    account          bigint references accounts(id) on delete set null,
    zone             text not null default '',
    room             integer,
    wire             text not null,
    client_tick      bigint not null,
    snapshot_tick    bigint not null,
    snapshot_seq     bigint not null,
    correction_px    double precision not null,
    predicted_x      double precision not null,
    predicted_y      double precision not null,
    reconciled_x     double precision not null,
    reconciled_y     double precision not null,
    predicted_vx     double precision not null default 0,
    predicted_vy     double precision not null default 0,
    reconciled_vx    double precision not null default 0,
    reconciled_vy    double precision not null default 0,
    local_debt_px    double precision not null default 0,
    local_debt_deg   double precision not null default 0,
    clock_adjust     integer not null default 0,
    repel_before_ticks integer not null default 0,
    repel_before_speed double precision not null default 0,
    repel_after_ticks integer not null default 0,
    repel_after_speed double precision not null default 0,
    frame_ms         double precision not null,
    snapshot_gap_ms  double precision not null,
    input_ack        bigint not null,
    input_mask       bigint not null,
    input_margin     integer not null,
    input_lead       integer not null,
    input_holes      integer not null,
    user_agent       text not null default ''
);
alter table client_debug add column if not exists predicted_vx double precision not null default 0;
alter table client_debug add column if not exists predicted_vy double precision not null default 0;
alter table client_debug add column if not exists reconciled_vx double precision not null default 0;
alter table client_debug add column if not exists reconciled_vy double precision not null default 0;
alter table client_debug add column if not exists local_debt_px double precision not null default 0;
alter table client_debug add column if not exists local_debt_deg double precision not null default 0;
alter table client_debug add column if not exists clock_adjust integer not null default 0;
alter table client_debug add column if not exists repel_before_ticks integer not null default 0;
alter table client_debug add column if not exists repel_before_speed double precision not null default 0;
alter table client_debug add column if not exists repel_after_ticks integer not null default 0;
alter table client_debug add column if not exists repel_after_speed double precision not null default 0;
create index if not exists client_debug_by_at on client_debug (at desc);
create index if not exists client_debug_by_account on client_debug (account, at desc);
-- One live rated connection per account across the fleet. Arenas renew the row
-- while the socket lives and release it on a clean departure. The timestamp is
-- a lease so a dead process cannot lock an account forever.
create table if not exists active_rated_sessions (
    account  bigint primary key references accounts(id) on delete cascade,
    session  text not null,
    instance text not null,
    touched  timestamptz not null default now()
);
create index if not exists active_rated_sessions_by_touch
    on active_rated_sessions (touched);
-- What the instance above is serving, so a friends list can say where
-- somebody is rather than only that they are somewhere. Added rather than
-- built in, because this table predates the friends page and a deployment
-- upgrading into it has rows without one.
alter table active_rated_sessions
    add column if not exists zone text not null default '';

-- Friend edges, one row per direction. The friendship is the pair: A has
-- added B and B has added A. There is no accept and no decline, because both
-- are the same press seen from the other side, and no inbox for a stranger to
-- fill. Removing takes both rows, since leaving one standing would keep a
-- removed pilot on the other's list forever.
--
-- See docs/design/friends.md.
create table if not exists friends (
    account bigint not null references accounts(id) on delete cascade,
    friend  bigint not null references accounts(id) on delete cascade,
    made    timestamptz not null default now(),
    primary key (account, friend)
);
-- The other direction is read as often as the first, because who has added
-- me is half of what the page draws.
create index if not exists friends_by_friend on friends (friend);
";

/// How long a pilot's own rows live. Long enough to answer a report weeks after
/// somebody filed it and to read a season out of the log, short enough that the
/// fleet is not accumulating a permanent record of how everybody plays.
const PILOT_EVENT_DAYS: i32 = 90;
/// And how long a bot's do. These are debugging material for our own software
/// with a half-life of about a day, and there are two orders of magnitude more
/// of them: 153 bot connections cycle through the fleet around the clock.
const BOT_EVENT_DAYS: i32 = 7;
/// Browser diagnostics are useful across a release cycle, then stale. The
/// clock restarts when a grouped error happens again so a live fault remains
/// visible while an old one falls away.
const CLIENT_ERROR_DAYS: i32 = 30;
/// Structured rollback traces have the same operational lifetime as browser
/// errors. After a release cycle they describe code nobody is running.
const CLIENT_DEBUG_DAYS: i32 = 30;
/// Password hashing is deliberately expensive. Keep that work below the point
/// where it can occupy Tokio's whole blocking pool or exhaust a small host.
const PASSWORD_WORKERS: usize = 4;
/// One person can own enough bots for a useful squad without turning account
/// registration into an unbounded namespace and database write.
const OWNED_BOT_LIMIT: i64 = 16;

pub struct Meta {
    pool: Pool,
    signing: ed25519_dalek::SigningKey,
    /// Pool tokens, for the two callers that are servers rather than players:
    /// an arena handing off rated events and the bot server claiming its
    /// roster's accounts.
    catalog: crate::catalog::Catalog,
    /// Per-address and per-name counters for routes an attacker has a reason
    /// to hammer. Guest creation burns call signs, login guesses passwords,
    /// and browser diagnostics otherwise offer a cheap public write path.
    throttle: Throttle,
    password_work: Arc<tokio::sync::Semaphore>,
}

impl Meta {
    async fn db(&self) -> Result<Client, String> {
        self.pool
            .get()
            .await
            .map_err(|e| format!("no database connection: {e}"))
    }
}

/// A secret is 32 random bytes in hex: minted, never chosen, and stored only
/// as a hash. The same shape as a pool token, for the same reasons.
fn new_secret() -> String {
    let bytes: [u8; 32] = rand::thread_rng().gen();
    token::to_hex(&bytes)
}

/// A house bot's device secret is stable for one pool identity and roster
/// individual. Restarts can ask for it again without adding another permanent
/// credential row. Rotating the pool token rotates these secrets as well.
fn house_secret(pool_token: &str, name: &str) -> String {
    sha256_hex(format!("vectorwake house bot\0{pool_token}\0{name}\0{pool_token}").as_bytes())
}

/// The words a call sign is drawn from, and this is the only place one is
/// ever drawn: no route accepts a name, because whoever proposes a name
/// chooses it, and a curated list is only safe while the server is the thing
/// doing the curating.
///
/// The register is the client's old list grown four times over: short
/// evocative nouns, eight letters at most so "Solstice 999" is the longest
/// name the scoreboard ever has to hold. Disjoint from the AI roster's names
/// in `ai.rs` and from the seven hull names, so a scoreboard never leaves
/// you wondering which of the three a word came from; the test at the bottom
/// of this file holds all four lists apart.
const CALL_WORDS: [&str; 148] = [
    "Vesper", "Talon", "Corvid", "Ember", "Quill", "Solstice", "Zephyr", "Harrow", "Lumen",
    "Basalt", "Nimbus", "Cobalt", "Fathom", "Verge", "Auric", "Sleet", "Pike", "Marrow", "Torrent",
    "Beacon", "Cinder", "Drift", "Halyard", "Ingot", "Jetty", "Kiln", "Lantern", "Mistral",
    "Noctis", "Orbit", "Plume", "Quarry", "Rill", "Sextant", "Thistle", "Umber", "Aster", "Auriga",
    "Ballast", "Bantam", "Bearing", "Bight", "Bowline", "Breaker", "Brine", "Bulwark", "Cairn",
    "Caldera", "Calyx", "Cascade", "Chevron", "Chicane", "Corona", "Crag", "Culvert", "Cutlass",
    "Cyclone", "Dapple", "Delta", "Dorado", "Dynamo", "Eclipse", "Eddy", "Ellipse", "Epoch",
    "Equinox", "Fennel", "Ferrite", "Firth", "Fjord", "Flint", "Flux", "Forge", "Fresnel",
    "Furrow", "Gale", "Galena", "Garnet", "Gimbal", "Glacier", "Gnomon", "Granite", "Gulch",
    "Gyre", "Halite", "Haven", "Helix", "Hemlock", "Icefall", "Jasper", "Karst", "Knoll", "Lagoon",
    "Lapis", "Leeward", "Lichen", "Lyra", "Mesa", "Mica", "Monsoon", "Morrow", "Nadir", "Nebula",
    "Nickel", "Onyx", "Opal", "Outcrop", "Pewter", "Pharos", "Pinion", "Polaris", "Pumice",
    "Pylon", "Quartz", "Quasar", "Radian", "Rampart", "Reef", "Rime", "Riptide", "Rudder",
    "Scoria", "Shale", "Shoal", "Sickle", "Skerry", "Sonar", "Spinel", "Squall", "Strand",
    "Stratus", "Summit", "Sundial", "Talus", "Tarn", "Tempest", "Tether", "Thermal", "Tiller",
    "Topaz", "Trellis", "Tundra", "Turbine", "Vortex", "Willow", "Wren", "Yonder", "Zircon",
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
        .map(|h| {
            argon2::Argon2::default()
                .verify_password(password.as_bytes(), &h)
                .is_ok()
        })
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
        if hits.len() >= 4096 && !hits.contains_key(key) {
            if let Some(oldest) = hits
                .iter()
                .min_by_key(|(_, (_, at))| *at)
                .map(|(key, _)| key.clone())
            {
                hits.remove(&oldest);
            }
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

struct ClientError {
    kind: String,
    message: String,
    stack: String,
    build: String,
    origin: String,
    page: String,
    user_agent: String,
    account: Option<i64>,
}

struct ClientDebug {
    kind: String,
    build: String,
    account: Option<i64>,
    zone: String,
    room: Option<i32>,
    wire: String,
    client_tick: i64,
    snapshot_tick: i64,
    snapshot_seq: i64,
    correction_px: f64,
    predicted_x: f64,
    predicted_y: f64,
    reconciled_x: f64,
    reconciled_y: f64,
    predicted_vx: f64,
    predicted_vy: f64,
    reconciled_vx: f64,
    reconciled_vy: f64,
    local_debt_px: f64,
    local_debt_deg: f64,
    clock_adjust: i32,
    repel_before_ticks: i32,
    repel_before_speed: f64,
    repel_after_ticks: i32,
    repel_after_speed: f64,
    frame_ms: f64,
    snapshot_gap_ms: f64,
    input_ack: i64,
    input_mask: i64,
    input_margin: i32,
    input_lead: i32,
    input_holes: i32,
    user_agent: String,
}

/// Remove long hexadecimal runs before a browser diagnostic reaches durable
/// storage. Device secrets and their hashes are 64 hexadecimal characters, so
/// a report that accidentally quotes one keeps the shape of the error without
/// keeping the credential.
fn redact_long_hex(input: &str) -> String {
    fn flush(out: &mut String, run: &mut String) {
        if run.len() >= 48 {
            out.push_str("[redacted]");
        } else {
            out.push_str(run);
        }
        run.clear();
    }

    let mut out = String::with_capacity(input.len());
    let mut run = String::new();
    for c in input.chars() {
        if c.is_ascii_hexdigit() {
            run.push(c);
        } else {
            flush(&mut out, &mut run);
            out.push(c);
        }
    }
    flush(&mut out, &mut run);
    out
}

fn clean_client_text(given: &str, limit: usize, multiline: bool) -> String {
    let cleaned: String = given
        .chars()
        .filter(|c| !c.is_control() || (multiline && (*c == '\n' || *c == '\t')))
        .collect();
    redact_long_hex(cleaned.trim())
        .chars()
        .take(limit)
        .collect()
}

fn client_error_of(body: &serde_json::Value) -> Result<ClientError, &'static str> {
    let field = |name: &str| body.get(name).and_then(|v| v.as_str()).unwrap_or("");
    let kind = match field("kind") {
        "promise" => "promise",
        "console" => "console",
        "resource" => "resource",
        _ => "error",
    }
    .to_string();
    let message = clean_client_text(field("message"), 512, false);
    if message.is_empty() {
        return Err("an error report needs a message");
    }
    let page = field("page")
        .split(|c| c == '?' || c == '#')
        .next()
        .unwrap_or("");
    Ok(ClientError {
        kind,
        message,
        stack: clean_client_text(field("stack"), 4096, true),
        build: clean_client_text(field("build"), 80, false),
        origin: clean_client_text(field("origin"), 120, false),
        page: clean_client_text(page, 240, false),
        user_agent: clean_client_text(field("user_agent"), 256, false),
        account: body
            .get("account")
            .and_then(|v| v.as_i64())
            .filter(|v| *v > 0),
    })
}

fn client_debug_of(body: &serde_json::Value) -> Result<ClientDebug, &'static str> {
    let text = |name: &str, limit: usize| {
        clean_client_text(
            body.get(name).and_then(|v| v.as_str()).unwrap_or(""),
            limit,
            false,
        )
    };
    let u32_field = |name: &str| {
        body.get(name)
            .and_then(|v| v.as_u64())
            .filter(|v| *v <= u32::MAX as u64)
            .map(|v| v as i64)
            .ok_or("a tick or mask is outside u32")
    };
    let integer = |name: &str, lo: i64, hi: i64| {
        body.get(name)
            .and_then(|v| v.as_i64())
            .filter(|v| *v >= lo && *v <= hi)
            .map(|v| v as i32)
            .ok_or("an integer diagnostic field is outside its range")
    };
    let number = |name: &str, lo: f64, hi: f64| {
        body.get(name)
            .and_then(|v| v.as_f64())
            .filter(|v| v.is_finite() && *v >= lo && *v <= hi)
            .ok_or("a numeric diagnostic field is outside its range")
    };

    if body.get("kind").and_then(|v| v.as_str()) != Some("local_correction") {
        return Err("unknown client diagnostic kind");
    }
    if body.get("alive_before").and_then(|v| v.as_bool()) != Some(true)
        || body.get("alive_after").and_then(|v| v.as_bool()) != Some(true)
    {
        return Err("only continuous living corrections are diagnostics");
    }
    let wire = text("wire", 8);
    if !matches!(wire.as_str(), "ws" | "wt") {
        return Err("unknown client wire");
    }
    let correction_px = number("correction_px", 0.5, 20_000_000.0)?;
    if correction_px <= 0.5 {
        return Err("a client correction must exceed the diagnostic threshold");
    }

    Ok(ClientDebug {
        kind: "local_correction".to_string(),
        build: text("build", 80),
        account: body
            .get("account")
            .and_then(|v| v.as_i64())
            .filter(|v| *v > 0),
        zone: text("zone", 80),
        room: body
            .get("room")
            .and_then(|v| v.as_i64())
            .filter(|v| *v > 0 && *v <= u16::MAX as i64)
            .map(|v| v as i32),
        wire,
        client_tick: u32_field("client_tick")?,
        snapshot_tick: u32_field("snapshot_tick")?,
        snapshot_seq: u32_field("snapshot_seq")?,
        correction_px,
        predicted_x: number("predicted_x", -20_000_000.0, 20_000_000.0)?,
        predicted_y: number("predicted_y", -20_000_000.0, 20_000_000.0)?,
        reconciled_x: number("reconciled_x", -20_000_000.0, 20_000_000.0)?,
        reconciled_y: number("reconciled_y", -20_000_000.0, 20_000_000.0)?,
        predicted_vx: number("predicted_vx", -1000.0, 1000.0)?,
        predicted_vy: number("predicted_vy", -1000.0, 1000.0)?,
        reconciled_vx: number("reconciled_vx", -1000.0, 1000.0)?,
        reconciled_vy: number("reconciled_vy", -1000.0, 1000.0)?,
        local_debt_px: number("local_debt_px", 0.0, 64.0)?,
        local_debt_deg: number("local_debt_deg", 0.0, 180.0)?,
        clock_adjust: integer("clock_adjust", -1, 1)?,
        repel_before_ticks: integer("repel_before_ticks", 0, u16::MAX as i64)?,
        repel_before_speed: number("repel_before_speed", 0.0, 1000.0)?,
        repel_after_ticks: integer("repel_after_ticks", 0, u16::MAX as i64)?,
        repel_after_speed: number("repel_after_speed", 0.0, 1000.0)?,
        frame_ms: number("frame_ms", 0.0, 3_600_000.0)?,
        snapshot_gap_ms: number("snapshot_gap_ms", 0.0, 3_600_000.0)?,
        input_ack: u32_field("input_ack")?,
        input_mask: u32_field("input_mask")?,
        input_margin: integer("input_margin", -1000, 1000)?,
        input_lead: integer("input_lead", 0, 1000)?,
        input_holes: integer("input_holes", 0, 31)?,
        user_agent: text("user_agent", 256),
    })
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
        .query_opt(
            "select kind, banned from accounts where id = $1",
            &[&account],
        )
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
        .query_opt(
            "select call_sign from names where account = $1",
            &[&account],
        )
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
        .query(
            "select class, rating, games from ratings where account = $1",
            &[&account],
        )
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

    // What this account may slot, which is the baseline plus whatever it has
    // bought. An account with an empty row owns the baseline, so a pilot who
    // has never opened the shop still flies a whole ship.
    let mut entitlements = sim::World::base_entitlements().to_vec();
    let bought = db
        .query(
            "select slot, n from entitlements where account = $1",
            &[&account],
        )
        .await
        .map_err(|e| format!("cannot read entitlements: {e}"))?;
    for r in &bought {
        let slot: i16 = r.get(0);
        let n: i16 = r.get(1);
        if let Some(c) = entitlements.get_mut(slot.max(0) as usize) {
            *c = n.clamp(0, 255) as u8;
        }
    }

    Ok(Claims {
        account: account as u64,
        kind: kind_of(kind),
        claimed: extra > 0,
        name,
        expires: token::now_secs() + token::LIFETIME_SECS,
        ratings,
        entitlements,
    })
}

/// What an account owns in one slot, which is the baseline until it buys.
async fn entitlement_of(db: &Client, account: i64, slot: i16, base: u8) -> u8 {
    db.query_opt(
        "select n from entitlements where account = $1 and slot = $2",
        &[&account, &slot],
    )
    .await
    .ok()
    .flatten()
    .map(|r| r.get::<_, i16>(0).clamp(0, 255) as u8)
    .unwrap_or(base)
}

/// What an account has banked. No row is a balance of zero, which is what an
/// account that has never been paid has.
async fn wallet_of(db: &Client, account: i64) -> i64 {
    db.query_opt("select rivets from wallets where account = $1", &[&account])
        .await
        .ok()
        .flatten()
        .map(|r| r.get(0))
        .unwrap_or(0)
}

/// What this account has chosen to fly, per hull, as the kit's own bytes.
/// A hull with no row has never been taken to the hangar, and the arena deals
/// it a starter kit.
async fn kits_of(db: &Client, account: i64) -> serde_json::Value {
    let rows = db
        .query(
            "select class, kit from kits where account = $1",
            &[&account],
        )
        .await
        .unwrap_or_default();
    let mut out = serde_json::Map::new();
    for r in &rows {
        let class: String = r.get(0);
        let kit: Vec<u8> = r.get(1);
        out.insert(class, serde_json::json!(kit));
    }
    serde_json::Value::Object(out)
}

/// Whether an account number is somebody this pilot could be friends with,
/// before anything is read from the database.
///
/// Split out because it is the half of the rule that is not SQL, and because
/// the two cases it rejects are easy to get subtly wrong: adding yourself
/// would make a self-mutual edge that reads as a friendship on the page, and a
/// zero or negative id is a client that has lost track of what it is holding.
fn names_a_pilot(me: i64, other: i64) -> Result<(), (u16, &'static str)> {
    if other <= 0 || other == me {
        return Err((400, "no such pilot"));
    }
    Ok(())
}

/// And whether there is room on the list. Separate from the read that counts
/// it so the bound itself is testable without a database.
fn room_for_one_more(held: i64) -> Result<(), (u16, &'static str)> {
    if held >= MAX_FRIENDS {
        return Err((409, "that is as many as a list holds"));
    }
    Ok(())
}

/// The most edges one account may hold. Not a social judgment: it is what
/// bounds the query, the page and the JSON. Anybody who reaches it is doing
/// something other than playing with friends.
const MAX_FRIENDS: i64 = 100;

/// The friends page, whole.
///
/// Three lists, defined against each other so the client never has to
/// subtract one from another:
///
/// - `friends`, where both directions exist, with where each one is flying.
/// - `asked`, where they have added you and you have not added back. The
///   only inbox this system has, and it holds names and nothing else.
/// - `waiting`, where you have added them and they have not added back. It is
///   the other half of the same edge and it is here because a press with no
///   visible consequence reads as a press that did nothing: adding somebody
///   took their name off the room list and put it nowhere.
/// - `here`, the pilots in the room you are in who are on none of the above,
///   so the page you make a friend on is the one you are already reading.
///
/// Every edge has exactly one home, which is what lets the client draw four
/// sections without deciding anything.
///
/// Presence is a join against `active_rated_sessions`, which an arena keeps
/// honest because a rated seat is exclusive. Watchers hold no such row, and
/// that is correct: "in a game" should mean flying. See
/// docs/design/friends.md.
async fn friends_page(db: &Client, account: i64) -> Result<serde_json::Value, String> {
    let mutual = db
        .query(
            "select f.friend, n.call_sign, s.instance, s.zone
               from friends f
               join friends b on b.account = f.friend and b.friend = f.account
               left join names n on n.account = f.friend
               left join active_rated_sessions s
                      on s.account = f.friend
                     and s.touched > now() - interval '180 seconds'
              where f.account = $1
              order by (s.instance is null), n.call_sign
              limit $2",
            &[&account, &MAX_FRIENDS],
        )
        .await
        .map_err(|e| format!("cannot read friends: {e}"))?;
    let friends: Vec<serde_json::Value> = mutual
        .iter()
        .map(|r| {
            let instance: Option<String> = r.get(2);
            let zone: Option<String> = r.get(3);
            serde_json::json!({
                "account": r.get::<_, i64>(0),
                "name": r.get::<_, Option<String>>(1).unwrap_or_default(),
                // Absent rather than false when they are not flying, so a
                // client draws "on" from the presence itself rather than from
                // a flag that could disagree with it.
                "zone": zone.unwrap_or_default(),
                "instance": instance.unwrap_or_default(),
            })
        })
        .collect();

    // Who is waiting on you. Their direction exists and yours does not.
    let inbound = db
        .query(
            "select f.account, n.call_sign
               from friends f
               left join names n on n.account = f.account
              where f.friend = $1
                and not exists (select 1 from friends b
                                 where b.account = $1 and b.friend = f.account)
              order by f.made
              limit $2",
            &[&account, &MAX_FRIENDS],
        )
        .await
        .map_err(|e| format!("cannot read who is waiting: {e}"))?;
    let asked: Vec<serde_json::Value> = inbound
        .iter()
        .map(|r| {
            serde_json::json!({
                "account": r.get::<_, i64>(0),
                "name": r.get::<_, Option<String>>(1).unwrap_or_default(),
            })
        })
        .collect();

    // And who you are waiting on, which is the same edge from the other end.
    let outbound = db
        .query(
            "select f.friend, n.call_sign
               from friends f
               left join names n on n.account = f.friend
              where f.account = $1
                and not exists (select 1 from friends b
                                 where b.account = f.friend and b.friend = $1)
              order by f.made
              limit $2",
            &[&account, &MAX_FRIENDS],
        )
        .await
        .map_err(|e| format!("cannot read who you are waiting on: {e}"))?;
    let waiting: Vec<serde_json::Value> = outbound
        .iter()
        .map(|r| {
            serde_json::json!({
                "account": r.get::<_, i64>(0),
                "name": r.get::<_, Option<String>>(1).unwrap_or_default(),
            })
        })
        .collect();

    // And whoever is in the room with you, which is only answerable while you
    // are in one. This is the whole of how a name reaches this page: there is
    // no directory of the fleet to ask and no way to search for anybody.
    let mut here: Vec<serde_json::Value> = Vec::new();
    let mine = db
        .query_opt(
            "select instance from active_rated_sessions
              where account = $1 and touched > now() - interval '180 seconds'",
            &[&account],
        )
        .await
        .map_err(|e| format!("cannot read where you are: {e}"))?;
    if let Some(row) = mine {
        let instance: String = row.get(0);
        let rows = db
            .query(
                "select s.account, n.call_sign
                   from active_rated_sessions s
                   left join names n on n.account = s.account
                  where s.instance = $1
                    and s.account <> $2
                    and s.touched > now() - interval '180 seconds'
                    and not exists (select 1 from friends f
                                     where f.account = $2 and f.friend = s.account)
                  order by n.call_sign
                  limit 64",
                &[&instance, &account],
            )
            .await
            .map_err(|e| format!("cannot read the room: {e}"))?;
        here = rows
            .iter()
            .map(|r| {
                serde_json::json!({
                    "account": r.get::<_, i64>(0),
                    "name": r.get::<_, Option<String>>(1).unwrap_or_default(),
                })
            })
            .collect();
    }

    Ok(serde_json::json!({
        "friends": friends,
        "asked": asked,
        "waiting": waiting,
        "here": here,
    }))
}

// ------------------------------------------------------------------ routes

/// Every route takes JSON and answers JSON. Hand-rolled HTTP for the same
/// reason `admin.rs` hand-rolls it: the surface is small and a framework
/// would be the larger change.
async fn route(
    meta: &Meta,
    path: &str,
    body: &serde_json::Value,
    ip: &str,
) -> (u16, serde_json::Value) {
    let hour = std::time::Duration::from_secs(3600);
    if path == "/v1/client-error"
        && (!meta.throttle.allow(&format!("client-error:{ip}"), 30, hour)
            || !meta.throttle.allow("client-error:all", 2000, hour))
    {
        return (
            429,
            serde_json::json!({ "error": "too many error reports; wait a while" }),
        );
    }
    if path == "/v1/client-debug"
        && (!meta.throttle.allow(&format!("client-debug:{ip}"), 30, hour)
            || !meta.throttle.allow("client-debug:all", 2000, hour))
    {
        return (
            429,
            serde_json::json!({ "error": "too many debug reports; wait a while" }),
        );
    }
    let mut db = match meta.db().await {
        Ok(d) => d,
        Err(e) => return (503, serde_json::json!({ "error": e })),
    };
    let s = |v: &str| {
        body.get(v)
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string()
    };
    let quarter = std::time::Duration::from_secs(900);

    if let Some(reply) = settlement::route(&meta.catalog, &mut db, path, body).await {
        return reply;
    }
    if let Some(reply) = public_pilots::route(&meta.throttle, &db, path, body, ip).await {
        return reply;
    }

    match path {
        // A browser sends this without credentials because some failures occur
        // before the account is loaded. The account ID is reported context,
        // not authentication. Repeated faults fold into one row per account,
        // build and stack so the table stays useful during a failure storm.
        "/v1/client-error" => {
            let report = match client_error_of(body) {
                Ok(report) => report,
                Err(error) => return (400, serde_json::json!({ "error": error })),
            };
            let fingerprint = sha256_hex(
                format!(
                    "{}\n{}\n{}\n{}\n{}",
                    report.kind,
                    report.message,
                    report.stack,
                    report.build,
                    report.account.unwrap_or(0)
                )
                .as_bytes(),
            );
            let stored = db
                .execute(
                    "insert into client_errors
                       (fingerprint, kind, message, stack, build, origin, page, user_agent, account)
                     values ($1, $2, $3, $4, $5, $6, $7, $8,
                             (select id from accounts where id = $9))
                     on conflict (fingerprint) do update
                     set last_at = now(), occurrences = client_errors.occurrences + 1,
                         origin = excluded.origin, page = excluded.page,
                         user_agent = excluded.user_agent",
                    &[
                        &fingerprint,
                        &report.kind,
                        &report.message,
                        &report.stack,
                        &report.build,
                        &report.origin,
                        &report.page,
                        &report.user_agent,
                        &report.account,
                    ],
                )
                .await;
            match stored {
                Ok(_) => (200, serde_json::json!({ "ok": true })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // A sampled correction on a living local hull. These stay as
        // individual rows because the sequence around a rollback is the
        // evidence; error grouping would fold it into an occurrence count and
        // throw that away.
        // Every field is bounded above before this public write reaches SQL,
        // and the reported account is context rather than authentication.
        "/v1/client-debug" => {
            let report = match client_debug_of(body) {
                Ok(report) => report,
                Err(error) => return (400, serde_json::json!({ "error": error })),
            };
            let stored = db
                .execute(
                    "insert into client_debug
                       (kind, build, account, zone, room, wire, client_tick,
                        snapshot_tick, snapshot_seq, correction_px,
                        predicted_x, predicted_y, reconciled_x,
                        reconciled_y, predicted_vx, predicted_vy,
                        reconciled_vx, reconciled_vy, local_debt_px,
                        local_debt_deg, clock_adjust, repel_before_ticks,
                        repel_before_speed, repel_after_ticks,
                        repel_after_speed, frame_ms, snapshot_gap_ms,
                        input_ack, input_mask, input_margin, input_lead,
                        input_holes, user_agent)
                     values ($1, $2, (select id from accounts where id = $3),
                             $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
                             $14, $15, $16, $17, $18, $19, $20, $21, $22,
                             $23, $24, $25, $26, $27, $28, $29, $30, $31,
                             $32, $33)",
                    &[
                        &report.kind,
                        &report.build,
                        &report.account,
                        &report.zone,
                        &report.room,
                        &report.wire,
                        &report.client_tick,
                        &report.snapshot_tick,
                        &report.snapshot_seq,
                        &report.correction_px,
                        &report.predicted_x,
                        &report.predicted_y,
                        &report.reconciled_x,
                        &report.reconciled_y,
                        &report.predicted_vx,
                        &report.predicted_vy,
                        &report.reconciled_vx,
                        &report.reconciled_vy,
                        &report.local_debt_px,
                        &report.local_debt_deg,
                        &report.clock_adjust,
                        &report.repel_before_ticks,
                        &report.repel_before_speed,
                        &report.repel_after_ticks,
                        &report.repel_after_speed,
                        &report.frame_ms,
                        &report.snapshot_gap_ms,
                        &report.input_ack,
                        &report.input_mask,
                        &report.input_margin,
                        &report.input_lead,
                        &report.input_holes,
                        &report.user_agent,
                    ],
                )
                .await;
            match stored {
                Ok(_) => (200, serde_json::json!({ "stored": true })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // Nobody signs up. The first time a client runs it asks for an
        // account and stores what it gets back, and that is the whole flow.
        // The call sign is the server's to give: a name a client could
        // choose is a name a script could choose, and unique-from-birth
        // only means something if nobody can aim the birth.
        "/v1/guest" => {
            if !meta.throttle.allow(&format!("guest:{ip}"), 20, hour) {
                return (
                    429,
                    serde_json::json!({ "error": "too many new pilots from here; wait a while" }),
                );
            }
            let account = match create_account(&db, KIND_HUMAN, None).await {
                Ok(a) => a,
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            let secret = new_secret();
            if let Err(e) =
                add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await
            {
                return (500, serde_json::json!({ "error": e }));
            }
            let name = match christen(&db, account).await {
                Ok(n) => n,
                Err(e) => return (500, serde_json::json!({ "error": e })),
            };
            note_account(
                &db,
                pilot::ACCOUNT,
                account,
                serde_json::json!({ "name": name }),
            )
            .await;
            (
                200,
                serde_json::json!({ "secret": secret, "account": account, "name": name }),
            )
        }

        // The only route a client calls in the normal case, once a session:
        // the stored device secret becomes a short-lived signed token. Also
        // where an account proves it is alive, which is the whole meaning of
        // last_seen and the only clock the guest sweeper reads.
        "/v1/session" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let _ = db
                .execute(
                    "update accounts set last_seen = now() where id = $1",
                    &[&account],
                )
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
                    (
                        200,
                        serde_json::json!({
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
                            // The hangar and the shop, which are the two
                            // screens between matches. Both ride the reply
                            // rather than the token: the entitlements are in
                            // the token because an arena checks them, and
                            // these two are for drawing.
                            "rivets": wallet_of(&db, account).await,
                            "entitlements": c.entitlements,
                            "kits": kits_of(&db, account).await,
                        }),
                    )
                }
                Err(e) if e == "banned" => (403, serde_json::json!({ "error": "banned" })),
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
        }

        // The hangar saving a kit. What is stored is what was sent, checked
        // only for shape: an arena checks it against the hull's row and the
        // account's entitlements before it deals it, and that check has to
        // happen there anyway because a zone may retune a hull after this was
        // written. Storing a kit that will not fit costs nothing and refusing
        // one that would fit some other zone costs a player their loadout.
        "/v1/kit" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let class = s("class");
            if class.is_empty() || class.len() > 32 {
                return (400, serde_json::json!({ "error": "which hull" }));
            }
            let kit: Vec<u8> = body
                .get("kit")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .map(|n| n.as_u64().unwrap_or(0).min(255) as u8)
                        .collect()
                })
                .unwrap_or_default();
            if kit.len() != sim::SLOT_COUNT {
                return (400, serde_json::json!({ "error": "that is not a kit" }));
            }
            let cost: u32 = kit.iter().map(|n| *n as u32).sum();
            if cost > sim::KIT_BUDGET as u32 {
                return (400, serde_json::json!({ "error": "over the budget" }));
            }
            let stored = db
                .execute(
                    "insert into kits (account, class, kit) values ($1, $2, $3)
                     on conflict (account, class) do update set kit = excluded.kit",
                    &[&account, &class, &kit],
                )
                .await;
            match stored {
                Ok(_) => (200, serde_json::json!({ "ok": true })),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // What is left to buy, priced. One entry a slot with a step on it,
        // with the name a person reads it by, so the client never has to
        // learn the kit space's layout to draw a shop.
        "/v1/shop" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let base = sim::World::base_entitlements();
            let mut shelf = Vec::new();
            for slot in 0..sim::SLOT_COUNT {
                let owned = entitlement_of(&db, account, slot as i16, base[slot]).await;
                let Some((next, price)) = shop::next_step(slot, owned) else {
                    continue;
                };
                shelf.push(serde_json::json!({
                    "slot": slot,
                    "label": shop::name_of(slot),
                    "price": price,
                    "note": shop::note_for(slot, owned, next),
                }));
            }
            (
                200,
                serde_json::json!({ "shelf": shelf, "rivets": wallet_of(&db, account).await }),
            )
        }

        // The friends page, whole, in one request: who you are friends with and
        // where they are, who has added you and is waiting, and who is in the
        // room with you right now.
        //
        // One route rather than three because it is one screen, and because
        // the three lists are defined against each other: somebody in your
        // room who is already a friend belongs in the first list and not the
        // third. Splitting them would make the client do that subtraction and
        // get it wrong on the frame where two replies disagree.
        //
        // See docs/design/friends.md.
        "/v1/friends" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            match friends_page(&db, account).await {
                Ok(page) => (200, page),
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
        }

        // One edge, made or dropped. `add` is the whole verb: adding somebody
        // who has already added you is what accepting is, and dropping takes
        // both directions so a removed pilot does not stay on the other's
        // list. See docs/design/friends.md.
        "/v1/friend" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let other = body
                .get("account")
                .and_then(|v| v.as_i64())
                .unwrap_or_default();
            let add = body.get("add").and_then(|v| v.as_bool()).unwrap_or(true);
            if let Err((code, why)) = names_a_pilot(account, other) {
                return (code, serde_json::json!({ "error": why }));
            }
            if add {
                // Adding is the rate-limited half. Dropping is not: a pilot
                // clearing a list they no longer want is not something to
                // stand in the way of, and it can only ever shrink.
                if !meta.throttle.allow(&format!("friend:{account}"), 60, hour) {
                    return (
                        429,
                        serde_json::json!({ "error": "too many at once; wait a while" }),
                    );
                }
                // A pilot who does not exist, or one who is banned, is not
                // somebody to be waiting on. Both answer the same way: this
                // page never says whether an account it will not add exists.
                match db
                    .query_opt("select banned from accounts where id = $1", &[&other])
                    .await
                {
                    Ok(Some(row)) if row.get::<_, bool>(0) => {
                        return (403, serde_json::json!({ "error": "no such pilot" }));
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => return (400, serde_json::json!({ "error": "no such pilot" })),
                    Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
                }
                let held: i64 = db
                    .query_one(
                        "select count(*) from friends where account = $1",
                        &[&account],
                    )
                    .await
                    .map(|r| r.get(0))
                    .unwrap_or(0);
                if let Err((code, why)) = room_for_one_more(held) {
                    return (code, serde_json::json!({ "error": why }));
                }
                if let Err(e) = db
                    .execute(
                        "insert into friends (account, friend) values ($1, $2)
                         on conflict do nothing",
                        &[&account, &other],
                    )
                    .await
                {
                    return (500, serde_json::json!({ "error": format!("{e}") }));
                }
            } else if let Err(e) = db
                .execute(
                    "delete from friends
                     where (account = $1 and friend = $2)
                        or (account = $2 and friend = $1)",
                    &[&account, &other],
                )
                .await
            {
                return (500, serde_json::json!({ "error": format!("{e}") }));
            }
            // The page back, so one press redraws without a second request
            // and without the client guessing what the edge did to the three
            // lists it is drawn from.
            match friends_page(&db, account).await {
                Ok(page) => (200, page),
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
        }

        // The week: matches won, kills and the best run, resetting Monday.
        // Read off the pilot log, which is where a kill row already lands, so
        // this is a query rather than a second tally kept in step.
        "/v1/week" => {
            let rows = db
                .query(
                    "select name,
                            count(*) filter (where kind = 'kill') as kills,
                            coalesce(max((detail->>'bounty')::int), 0) as run
                     from pilot_events
                     where not bot and kind = 'kill'
                       and at >= date_trunc('week', now() at time zone 'utc')
                     group by name
                     order by kills desc
                     limit 20",
                    &[],
                )
                .await
                .unwrap_or_default();
            let week: Vec<serde_json::Value> = rows
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "name": r.get::<_, String>(0),
                        "kills": r.get::<_, i64>(1),
                        // A bounty taken is the length of the run it ended,
                        // so the biggest one somebody collected is the
                        // longest streak they broke. Their own best run is a
                        // different number and nothing files it yet.
                        "run": r.get::<_, i32>(2),
                        "wins": 0,
                    })
                })
                .collect();
            (200, serde_json::json!({ "week": week }))
        }

        // The shop. One slot, one step, one price, and the wallet is checked
        // and debited in the same statement that raises the ceiling: two
        // clients pressing buy at once must not both be told yes.
        "/v1/buy" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            let Some(slot) = body.get("slot").and_then(|v| v.as_u64()) else {
                return (400, serde_json::json!({ "error": "which slot" }));
            };
            if slot as usize >= sim::SLOT_COUNT {
                return (400, serde_json::json!({ "error": "no such slot" }));
            }
            let base = sim::World::base_entitlements();
            let owned = entitlement_of(&db, account, slot as i16, base[slot as usize]).await;
            let Some((next, price)) = shop::next_step(slot as usize, owned) else {
                return (
                    400,
                    serde_json::json!({ "error": "nothing left to buy there" }),
                );
            };

            // One statement, so a wallet cannot be spent twice: the update
            // matches no row when the balance is short, and a caller that
            // moved nothing is a caller that could not afford it.
            let paid = db
                .execute(
                    "update wallets set rivets = rivets - $2
                     where account = $1 and rivets >= $2",
                    &[&account, &(price as i64)],
                )
                .await
                .unwrap_or(0);
            if paid == 0 {
                return (402, serde_json::json!({ "error": "not enough rivets" }));
            }
            let raised = db
                .execute(
                    "insert into entitlements (account, slot, n) values ($1, $2, $3)
                     on conflict (account, slot) do update set n = excluded.n",
                    &[&account, &(slot as i16), &(next as i16)],
                )
                .await;
            if let Err(e) = raised {
                // The wallet moved and the shelf did not, which is the one
                // ordering that costs a player something. Put it back.
                let _ = settlement::pay(&db, account, price as i64).await;
                return (500, serde_json::json!({ "error": format!("{e}") }));
            }
            note_account(
                &db,
                pilot::BOUGHT,
                account,
                serde_json::json!({ "slot": slot, "to": next, "price": price }),
            )
            .await;
            (
                200,
                serde_json::json!({
                    "slot": slot, "n": next, "rivets": wallet_of(&db, account).await,
                }),
            )
        }

        // Claiming attaches a way back in: a password on the name you
        // already hold. Nothing moves: same account, same name, same rating,
        // same history, and from here on losing the device is survivable.
        // With a valid secret this also serves as changing the password,
        // which is why the old row is dropped rather than accumulated.
        "/v1/claim" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            if !meta.throttle.allow(&format!("claim:{ip}"), 20, hour)
                || !meta
                    .throttle
                    .allow(&format!("claim-account:{account}"), 4, hour)
            {
                return (
                    429,
                    serde_json::json!({ "error": "too many password changes; wait a while" }),
                );
            }
            let password = s("password");
            if let Some(why) = password_trouble(&password) {
                return (400, serde_json::json!({ "error": why }));
            }
            let Ok(_permit) = meta.password_work.clone().try_acquire_owned() else {
                return (
                    503,
                    serde_json::json!({ "error": "password service is busy; try again" }),
                );
            };
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
            // Also what a password change looks like, since the route serves
            // both. The log says a credential moved, not which.
            note_account(&db, pilot::CLAIM, account, serde_json::json!({})).await;
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
                || !meta
                    .throttle
                    .allow(&format!("login:{}", name.to_lowercase()), 10, quarter)
            {
                return (
                    429,
                    serde_json::json!({ "error": "too many tries; wait a while" }),
                );
            }
            let miss = || {
                (
                    403,
                    serde_json::json!({ "error": "that name and password do not match" }),
                )
            };
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
            let Ok(_permit) = meta.password_work.clone().try_acquire_owned() else {
                return (
                    503,
                    serde_json::json!({ "error": "password service is busy; try again" }),
                );
            };
            let ok = tokio::task::spawn_blocking(move || verify_password(&password, &stored))
                .await
                .unwrap_or(false);
            if !ok {
                return miss();
            }
            let secret = new_secret();
            if let Err(e) =
                add_credential(&db, account, "secret", &sha256_hex(secret.as_bytes())).await
            {
                return (500, serde_json::json!({ "error": e }));
            }
            let _ = db
                .execute(
                    "update accounts set last_seen = now() where id = $1",
                    &[&account],
                )
                .await;
            // A new device holding this account. One of these is somebody
            // moving to a phone; a run of them is the shape worth being able
            // to see. The refusals are not logged: they are throttled per
            // address and per name already, and a row per guess would let a
            // guessing script size the table.
            note_account(&db, pilot::LOGIN, account, serde_json::json!({})).await;
            (
                200,
                serde_json::json!({ "secret": secret, "account": account }),
            )
        }

        // The reroll, server-side because the name is server-side now. Works
        // the same for a guest and a claimed pilot: the account number never
        // moves, so the rating and the history ride through the rename.
        "/v1/rename" => {
            let Some(account) =
                account_for(&db, "secret", &sha256_hex(s("secret").as_bytes())).await
            else {
                return (403, serde_json::json!({ "error": "no such account" }));
            };
            if !meta.throttle.allow(&format!("rename:{ip}"), 30, hour) {
                return (
                    429,
                    serde_json::json!({ "error": "that is plenty of rerolling. Try again later" }),
                );
            }
            match christen(&db, account).await {
                Ok(name) => {
                    note_account(
                        &db,
                        pilot::RENAME,
                        account,
                        serde_json::json!({ "to": name, "by": "self" }),
                    )
                    .await;
                    (200, serde_json::json!({ "name": name }))
                }
                Err(e) => (500, serde_json::json!({ "error": e })),
            }
        }

        // The bot server, holding a pool credential, claiming the account for
        // one roster individual. Idempotent: an individual is one account and
        // one career however many times the bot server restarts.
        "/v1/bot" => {
            let pool_token = s("pool_token");
            if meta.catalog.pool_for_token(&pool_token).is_none() {
                return (403, serde_json::json!({ "error": "unknown pool token" }));
            }
            let name = clean_name(&s("name"));
            if name.is_empty() {
                return (400, serde_json::json!({ "error": "a bot needs a name" }));
            }
            if !(0..4096).any(|n| crate::ai::individual(n).name == name) {
                return (400, serde_json::json!({ "error": "no such house bot" }));
            }
            let secret = house_secret(&pool_token, &name);
            let hash = sha256_hex(secret.as_bytes());
            let transaction = match db.transaction().await {
                Ok(t) => t,
                Err(e) => {
                    return (
                        500,
                        serde_json::json!({ "error": format!("cannot begin bot claim: {e}") }),
                    )
                }
            };
            if let Err(e) = transaction
                .query_one(
                    "select pg_advisory_xact_lock(hashtext($1)::bigint)",
                    &[&name],
                )
                .await
            {
                return (
                    500,
                    serde_json::json!({ "error": format!("cannot lock bot claim: {e}") }),
                );
            }
            let account = match transaction
                .query_opt(
                    "select account from credentials where method = 'house' and hash = $1",
                    &[&name],
                )
                .await
            {
                Ok(Some(row)) => row.get::<_, i64>(0),
                Ok(None) => {
                    let account: i64 = match transaction
                        .query_one(
                            "insert into accounts (kind) values ($1) returning id",
                            &[&KIND_HOUSE_BOT],
                        )
                        .await
                    {
                        Ok(row) => row.get(0),
                        Err(e) => {
                            return (
                                500,
                                serde_json::json!({ "error": format!("cannot create bot: {e}") }),
                            )
                        }
                    };
                    if let Err(e) = transaction
                        .execute(
                            "insert into credentials (method, hash, account) values ('house', $1, $2)",
                            &[&name, &account],
                        )
                        .await
                    {
                        return (500, serde_json::json!({ "error": format!("cannot identify bot: {e}") }));
                    }
                    if let Err(e) = transaction
                        .execute(
                            "insert into names (account, call_sign) values ($1, $2)",
                            &[&account, &name],
                        )
                        .await
                    {
                        return (
                            500,
                            serde_json::json!({ "error": format!("cannot name bot: {e}") }),
                        );
                    }
                    if let Some(seed) = crate::calibrated_rating(&name) {
                        if let Err(e) = transaction
                            .execute(
                                "insert into ratings (account, class, rating, games)
                                 values ($1, $2, $3, 0)
                                 on conflict (account, class) do nothing",
                                &[&account, &DEFAULT_CLASS, &seed],
                            )
                            .await
                        {
                            return (
                                500,
                                serde_json::json!({ "error": format!("cannot seed bot: {e}") }),
                            );
                        }
                    }
                    account
                }
                Err(e) => {
                    return (
                        500,
                        serde_json::json!({ "error": format!("cannot find bot: {e}") }),
                    )
                }
            };
            if let Err(e) = transaction
                .execute(
                    "delete from credentials where account = $1 and method = 'secret' and hash <> $2",
                    &[&account, &hash],
                )
                .await
            {
                return (500, serde_json::json!({ "error": format!("cannot retire old bot credential: {e}") }));
            }
            if let Err(e) = transaction
                .execute(
                    "insert into credentials (method, hash, account) values ('secret', $1, $2)
                     on conflict (method, hash) do nothing",
                    &[&hash, &account],
                )
                .await
            {
                return (
                    500,
                    serde_json::json!({ "error": format!("cannot store credential: {e}") }),
                );
            }
            if let Err(e) = transaction.commit().await {
                return (
                    500,
                    serde_json::json!({ "error": format!("cannot commit credential: {e}") }),
                );
            }
            (
                200,
                serde_json::json!({ "secret": secret, "account": account }),
            )
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
                return (
                    400,
                    serde_json::json!({ "error": "a bot cannot own a bot" }),
                );
            }
            if !claims.claimed {
                return (
                    403,
                    serde_json::json!({
                        "error": "claim your own account first; a bot needs an owner who can be found"
                    }),
                );
            }
            let name = clean_name(&s("name"));
            if name.is_empty() {
                return (400, serde_json::json!({ "error": "a bot needs a name" }));
            }
            if !meta.throttle.allow(&format!("bot-register:{ip}"), 20, hour)
                || !meta
                    .throttle
                    .allow(&format!("bot-register-owner:{owner}"), 20, hour)
            {
                return (
                    429,
                    serde_json::json!({ "error": "too many bot registrations; wait a while" }),
                );
            }
            let secret = new_secret();
            let hash = sha256_hex(secret.as_bytes());
            let transaction = match db.transaction().await {
                Ok(t) => t,
                Err(e) => {
                    return (
                        500,
                        serde_json::json!({ "error": format!("cannot begin bot registration: {e}") }),
                    )
                }
            };
            // One owner at a time. The count and insert below are one decision,
            // even when two browser tabs submit together.
            if let Err(e) = transaction
                .query_one("select pg_advisory_xact_lock($1)", &[&owner])
                .await
            {
                return (
                    500,
                    serde_json::json!({ "error": format!("cannot lock bot registration: {e}") }),
                );
            }
            let owned: i64 = match transaction
                .query_one(
                    "select count(*) from accounts where kind = $1 and owner = $2",
                    &[&KIND_THIRD_PARTY_BOT, &owner],
                )
                .await
            {
                Ok(r) => r.get(0),
                Err(e) => {
                    return (
                        500,
                        serde_json::json!({ "error": format!("cannot count bots: {e}") }),
                    )
                }
            };
            if owned >= OWNED_BOT_LIMIT {
                return (
                    409,
                    serde_json::json!({ "error": format!("one pilot may register at most {OWNED_BOT_LIMIT} bots") }),
                );
            }
            let account: i64 = match transaction
                .query_one(
                    "insert into accounts (kind, owner) values ($1, $2) returning id",
                    &[&KIND_THIRD_PARTY_BOT, &owner],
                )
                .await
            {
                Ok(r) => r.get(0),
                Err(e) => {
                    return (
                        500,
                        serde_json::json!({ "error": format!("cannot create account: {e}") }),
                    )
                }
            };
            if let Err(e) = transaction
                .execute(
                    "insert into names (account, call_sign) values ($1, $2)",
                    &[&account, &name],
                )
                .await
            {
                use deadpool_postgres::tokio_postgres::error::SqlState;
                let why = if e.code() == Some(&SqlState::UNIQUE_VIOLATION) {
                    TAKEN.to_string()
                } else {
                    format!("cannot store name: {e}")
                };
                return (
                    if why == TAKEN { 409 } else { 500 },
                    serde_json::json!({ "error": why }),
                );
            }
            if let Err(e) = transaction
                .execute(
                    "insert into credentials (method, hash, account) values ('secret', $1, $2)",
                    &[&hash, &account],
                )
                .await
            {
                return (
                    500,
                    serde_json::json!({ "error": format!("cannot store credential: {e}") }),
                );
            }
            if let Err(e) = transaction.commit().await {
                return (
                    500,
                    serde_json::json!({ "error": format!("cannot commit bot: {e}") }),
                );
            }
            (
                200,
                serde_json::json!({ "secret": secret, "account": account, "owner": owner }),
            )
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
                Some(id) => db.query_opt(&format!("{q} where a.id = $1"), &[&id]).await,
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
                    (
                        200,
                        serde_json::json!({
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
                        }),
                    )
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
                Ok(0) => (
                    400,
                    serde_json::json!({
                        "error": "no such account, or it holds the admin flag; \
                                  revoke that in the database first"
                    }),
                ),
                Ok(_) => {
                    let name: String = db
                        .query_opt(
                            "select call_sign from names where account = $1",
                            &[&account],
                        )
                        .await
                        .ok()
                        .flatten()
                        .map(|row| row.get(0))
                        .unwrap_or_default();
                    // Actions get no audit trail from the catalog, so say it
                    // here, the way the directory notes its commands.
                    println!("meta: admin {actor} set banned={banned} on {account}: {reason:?}");
                    // Beside the stdout line, because a moderation record that
                    // lives only in a container's logs is one nobody can look
                    // up. The actor is the account the secret resolved to, not
                    // anything the caller said about itself.
                    note_account(
                        &db,
                        if banned { pilot::BAN } else { pilot::UNBAN },
                        account,
                        serde_json::json!({ "by": actor, "reason": reason }),
                    )
                    .await;
                    // A database mark closes the door for future tokens. Tell
                    // every registered arena as well so a connection already
                    // through that door does not stay until it reconnects.
                    if banned && !name.is_empty() {
                        let actor_name: String = db
                            .query_opt("select call_sign from names where account = $1", &[&actor])
                            .await
                            .ok()
                            .flatten()
                            .map(|row| row.get(0))
                            .unwrap_or_else(|| format!("account {actor}"));
                        let cmd = crate::fleet::OperatorCommand {
                            instance: "*".into(),
                            verb: "kick".into(),
                            args: name,
                            actor: actor_name,
                        };
                        let frame = crate::fleet::frame(crate::fleet::O2D_COMMAND, &cmd);
                        let url = directory_url();
                        if crate::directory::ask_with(&url, frame, crate::fleet::D2O_COMMAND)
                            .await
                            .is_none()
                        {
                            println!("meta: ban saved, but the directory at {url} did not answer");
                        }
                    }
                    (
                        200,
                        serde_json::json!({ "account": account, "banned": banned }),
                    )
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
                return (
                    503,
                    serde_json::json!({
                        "error": format!("no answer from the directory at {url}")
                    }),
                );
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
                return (
                    400,
                    serde_json::json!({
                        "error": "a bot's name is how its roster identity is found; \
                                  renaming it would split the two"
                    }),
                );
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
                return (
                    400,
                    serde_json::json!({
                        "error": "a call sign needs printable characters"
                    }),
                );
            }
            match set_name(&db, account, &name).await {
                Ok(()) => {
                    println!("meta: admin {actor} renamed {account} from {was:?} to {name:?}");
                    note_account(
                        &db,
                        pilot::RENAME,
                        account,
                        serde_json::json!({ "from": was, "to": name, "by": actor }),
                    )
                    .await;
                    (200, serde_json::json!({ "account": account, "name": name }))
                }
                // The index is the arbiter, and it says this one is held.
                Err(e) if e == TAKEN => (
                    409,
                    serde_json::json!({
                        "error": format!("{name:?} is already somebody's call sign")
                    }),
                ),
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
            // Standing on the ladder, in two pieces because they answer to
            // different rules.
            //
            // `best` is the one rating a single row can honestly stand for:
            // the class this pilot has played most, ties broken by the higher
            // number so the answer is stable rather than whichever row the
            // planner reached first. It carries the provisional ones too,
            // since "still placing" is worth showing and is not the same as
            // unrated.
            //
            // `ladder` is the position, and it is computed only over pilots
            // who are out of provisional. Ranking the placing ones would push
            // everybody else down the board for a number that is not settled
            // yet, so they hold no position until they have one. Ties share a
            // position, which is what `rank` does and what a ladder means.
            //
            // Both scan `ratings`, which holds a row per account per class and
            // is therefore bounded by the account table rather than by play.
            // At that size the scan is far cheaper than the round trip; if
            // accounts ever reach the point where it is not, this wants an
            // index on (class, rating) and a materialised board.
            let provisional = rating::PROVISIONAL_GAMES as i32;
            // One page of the table. The page picks the size so a phone and a
            // desktop can ask for different amounts of the same list, and both
            // are clamped here because the number arrives from a client.
            let limit = body
                .get("limit")
                .and_then(|v| v.as_i64())
                .unwrap_or(25)
                .clamp(1, 200);
            let offset = body
                .get("offset")
                .and_then(|v| v.as_i64())
                .unwrap_or(0)
                .max(0);
            let rows = db
                .query(
                    "with ladder as (
                         select account, class,
                                rank() over (partition by class order by rating desc) as pos,
                                count(*) over (partition by class) as of_n
                         from ratings where games >= $3
                     ),
                     best as (
                         select distinct on (account) account, class, rating, games
                         from ratings
                         order by account, games desc, rating desc
                     )
                     select a.id, coalesce(n.call_sign, ''), a.kind, a.banned, a.admin,
                            exists (select 1 from credentials c
                                    where c.account = a.id and c.method = 'password'),
                            to_char(a.last_seen at time zone 'utc', 'YYYY-MM-DD HH24:MI'),
                            b.class, b.rating, b.games, l.pos, l.of_n
                     from accounts a
                     left join names n on n.account = a.id
                     left join best b on b.account = a.id
                     left join ladder l on l.account = a.id and l.class = b.class
                     where $1 = ''
                        or strpos(lower(coalesce(n.call_sign, '')), lower($1)) > 0
                        or a.id = $2
                     order by a.last_seen desc
                     limit $4 offset $5",
                    &[&q, &number, &provisional, &limit, &offset],
                )
                .await;
            // How many the filter matches in total, so the page can say which
            // slice of what it is showing. A second statement rather than a
            // window function on the first: `count(*) over ()` would make
            // every row carry it, and this predicate touches only accounts and
            // names, so it costs an index scan over a table bounded by how
            // many people have ever played rather than by how much they have.
            let total: i64 = db
                .query_one(
                    "select count(*) from accounts a
                     left join names n on n.account = a.id
                     where $1 = ''
                        or strpos(lower(coalesce(n.call_sign, '')), lower($1)) > 0
                        or a.id = $2",
                    &[&q, &number],
                )
                .await
                .map(|r| r.get(0))
                .unwrap_or(0);
            match rows {
                Ok(rs) => (
                    200,
                    serde_json::json!({
                        "total": total,
                        "offset": offset,
                        "limit": limit,
                        // The two constants the page would otherwise have to keep
                        // a copy of to draw a standing: how many games place a
                        // pilot, and which class needs no naming. Sent once per
                        // reply rather than once per row, and sent at all so that
                        // moving either one in rating.rs moves it everywhere.
                        "provisional": rating::PROVISIONAL_GAMES,
                        "default_class": DEFAULT_CLASS,
                        "pilots": rs.iter().map(|r| {
                            let kind: i16 = r.get(2);
                            // The band, computed here rather than on the page: the
                            // thresholds live in rating.rs and a second copy of
                            // them in JavaScript is a second copy to forget when
                            // they move. Null while a pilot is still placing,
                            // which is a different thing from Green and reads as
                            // one.
                            let games: Option<i32> = r.get(9);
                            let score: Option<f64> = r.get(8);
                            let tier = match (score, games) {
                                (Some(s), Some(g)) if g as u32 >= rating::PROVISIONAL_GAMES => {
                                    Some(rating::tier(s))
                                }
                                _ => None,
                            };
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
                                "class": r.get::<_, Option<String>>(7),
                                "rating": score,
                                "games": games,
                                "tier": tier,
                                "rank": r.get::<_, Option<i64>>(10),
                                "of": r.get::<_, Option<i64>>(11),
                            })
                        }).collect::<Vec<_>>(),
                    }),
                ),
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
            let account = body.get("account").and_then(|v| v.as_i64()).unwrap_or(0);
            let admin = body.get("admin").and_then(|v| v.as_bool()).unwrap_or(true);
            let secret_hash = sha256_hex(s("secret").as_bytes());
            let transaction = match db.transaction().await {
                Ok(tx) => tx,
                Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
            };
            // Every grant and revoke takes the same transaction lock. Without
            // it, two last-admin revocations can both count the other and then
            // commit a deployment with nobody able to open the panel.
            if let Err(e) = transaction
                .query_one("select pg_advisory_xact_lock(865382731)", &[])
                .await
            {
                return (500, serde_json::json!({ "error": format!("{e}") }));
            }
            let actor: i64 = match transaction
                .query_opt(
                    "select a.id from accounts a join credentials c on c.account = a.id
                     where c.hash = $1 and a.admin and not a.banned",
                    &[&secret_hash],
                )
                .await
            {
                Ok(Some(row)) => row.get(0),
                Ok(None) => return (403, serde_json::json!({ "error": "not an admin" })),
                Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
            };
            let row = transaction
                .query_opt(
                    "select a.kind, a.admin, a.banned,
                            exists (select 1 from credentials c
                                    where c.account = a.id and c.method = 'password')
                     from accounts a where a.id = $1",
                    &[&account],
                )
                .await;
            let (kind, held, banned, has_password): (i16, bool, bool, bool) = match row {
                Ok(Some(r)) => (r.get(0), r.get(1), r.get(2), r.get(3)),
                Ok(None) => return (404, serde_json::json!({ "error": "no such account" })),
                Err(e) => return (500, serde_json::json!({ "error": format!("{e}") })),
            };
            if admin && banned {
                return (
                    400,
                    serde_json::json!({ "error": "a banned account cannot be an admin" }),
                );
            }
            if admin && kind_of(kind).is_bot() {
                return (
                    400,
                    serde_json::json!({
                        "error": "a bot cannot open the panel; it has no password to sign in with"
                    }),
                );
            }
            if admin && !has_password {
                return (
                    400,
                    serde_json::json!({
                        "error": "that account has no password, so it could not sign in. \
                                  It has to claim one first"
                    }),
                );
            }
            if !admin && held {
                let others: i64 = transaction
                    .query_one(
                        "select count(*) from accounts
                         where admin and not banned and id <> $1",
                        &[&account],
                    )
                    .await
                    .map(|r| r.get(0))
                    .unwrap_or(0);
                if others == 0 {
                    return (
                        409,
                        serde_json::json!({
                            "error": "that is the last admin; granting somebody else first \
                                      keeps this deployment out of the database"
                        }),
                    );
                }
            }
            let r = transaction
                .execute(
                    "update accounts set admin = $2 where id = $1",
                    &[&account, &admin],
                )
                .await;
            match r {
                Ok(0) => (404, serde_json::json!({ "error": "no such account" })),
                Ok(_) => {
                    if let Err(e) = transaction.commit().await {
                        return (500, serde_json::json!({ "error": format!("{e}") }));
                    }
                    println!("meta: admin {actor} set admin={admin} on account {account}");
                    note_account(
                        &db,
                        if admin { pilot::GRANT } else { pilot::REVOKE },
                        account,
                        serde_json::json!({ "by": actor }),
                    )
                    .await;
                    (
                        200,
                        serde_json::json!({ "account": account, "admin": admin }),
                    )
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
                Ok(rs) => (
                    200,
                    serde_json::json!({
                        "bans": rs.iter().map(|r| serde_json::json!({
                            "account": r.get::<_, i64>(0),
                            "name": r.get::<_, String>(1),
                            "reason": r.get::<_, String>(2),
                            "last_seen": r.get::<_, String>(3),
                        })).collect::<Vec<_>>(),
                    }),
                ),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // One pilot's recent history, out of the pilot log.
        //
        // This is the half of acting on a report that the panel could not do:
        // [admin.md](admin.md) noted that an operator can act on a report and
        // not notice one, and until there was a log the acting was on the
        // reporter's word alone. Read-only, and deliberately: nothing here
        // edits, because the log is a record of what happened and an operator
        // who could revise it would be holding a different kind of thing.
        //
        // By account, or by session for the whole of one stay. A session is
        // asked for by name rather than searched, since the only way to have
        // one is to have seen it in an answer to this route.
        "/v1/admin/events" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let account = body.get("account").and_then(|v| v.as_i64());
            let session = s("session");
            let (limit, offset) = page_of(body);
            // One more than asked for, which is how the page knows there is a
            // next one. A `count(*)` would be the tidier answer and the wrong
            // one: this table takes most of 300,000 rows a day, so counting a
            // pilot's whole history to draw a footer is work that grows
            // forever to say something the extra row says for nothing.
            let probe = limit + 1;
            // Newest first, because a report is about something that just
            // happened. The page reverses what it draws.
            let q = "select to_char(pe.at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'),
                            coalesce(pe.session, ''), pe.kind,
                            coalesce(nullif(pe.name, ''), n.call_sign, ''), pe.bot,
                            pe.zone, pe.instance, pe.room, pe.tick, pe.detail
                     from pilot_events pe
                     left join names n on n.account = pe.pilot";
            let rows = if !session.is_empty() {
                db.query(
                    &format!(
                        "{q} where pe.session = $1 order by pe.at desc, pe.id desc \
                              limit $2 offset $3"
                    ),
                    &[&session, &probe, &offset],
                )
                .await
            } else if let Some(id) = account {
                db.query(
                    &format!(
                        "{q} where pe.pilot = $1 order by pe.at desc, pe.id desc \
                              limit $2 offset $3"
                    ),
                    &[&id, &probe, &offset],
                )
                .await
            } else {
                return (
                    400,
                    serde_json::json!({ "error": "an account or a session" }),
                );
            };
            match rows {
                Ok(rs) => {
                    let more = rs.len() as i64 > limit;
                    (
                        200,
                        serde_json::json!({
                            "events": rs.iter().take(limit as usize).map(|r| serde_json::json!({
                                "at": r.get::<_, String>(0),
                                "session": r.get::<_, String>(1),
                                "kind": r.get::<_, String>(2),
                                "name": r.get::<_, String>(3),
                                "bot": r.get::<_, bool>(4),
                                "zone": r.get::<_, String>(5),
                                "instance": r.get::<_, String>(6),
                                "room": r.get::<_, Option<i32>>(7),
                                "tick": r.get::<_, i64>(8),
                                "detail": r.get::<_, serde_json::Value>(9),
                            })).collect::<Vec<_>>(),
                            "offset": offset,
                            "limit": limit,
                            "more": more,
                        }),
                    )
                }
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // Browser failures, grouped by the pieces that identify one fault.
        // An account is present once the client has loaded it, and absent for
        // startup failures. It is a lead for diagnosis, not proof of who sent
        // the report, because this public route cannot authenticate a browser
        // that failed before authentication itself was ready.
        "/v1/admin/errors" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let (limit, offset) = page_of(body);
            let probe = limit + 1;
            let summary = db
                .query_one(
                    "select
                         count(*) filter (where last_at >= now() - interval '1 hour')::bigint,
                         count(*) filter (where last_at >= now() - interval '24 hours')::bigint,
                         count(*)::bigint,
                         coalesce(sum(occurrences), 0)::bigint
                     from client_errors",
                    &[],
                )
                .await;
            let rows = db
                .query(
                    "select
                         to_char(first_at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'),
                         to_char(last_at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'),
                         occurrences, kind, message, stack, build, origin, page,
                         user_agent, account
                     from client_errors
                     order by last_at desc
                     limit $1 offset $2",
                    &[&probe, &offset],
                )
                .await;
            match (summary, rows) {
                (Ok(summary), Ok(rows)) => {
                    let more = rows.len() as i64 > limit;
                    (
                        200,
                        serde_json::json!({
                            "groups_1h": summary.get::<_, i64>(0),
                            "groups_24h": summary.get::<_, i64>(1),
                            "groups": summary.get::<_, i64>(2),
                            "occurrences": summary.get::<_, i64>(3),
                            "offset": offset,
                            "limit": limit,
                            "more": more,
                            "errors": rows.iter().take(limit as usize).map(|r| serde_json::json!({
                                "first_at": r.get::<_, String>(0),
                                "last_at": r.get::<_, String>(1),
                                "occurrences": r.get::<_, i64>(2),
                                "kind": r.get::<_, String>(3),
                                "message": r.get::<_, String>(4),
                                "stack": r.get::<_, String>(5),
                                "build": r.get::<_, String>(6),
                                "origin": r.get::<_, String>(7),
                                "page": r.get::<_, String>(8),
                                "user_agent": r.get::<_, String>(9),
                                "account": r.get::<_, Option<i64>>(10),
                            })).collect::<Vec<_>>(),
                        }),
                    )
                }
                (Err(e), _) | (_, Err(e)) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // Individual client rollback reports, newest first. The same admin
        // secret gate as the browser error list keeps positions and account
        // context off the public surface. Filters are values in a fixed query,
        // never fragments of SQL supplied by the panel.
        "/v1/admin/debug" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            let (limit, offset) = page_of(body);
            let probe = limit + 1;
            let hours = body
                .get("hours")
                .and_then(|v| v.as_i64())
                .unwrap_or(24)
                .clamp(1, 24 * 30) as i32;
            let account = body
                .get("account")
                .and_then(|v| v.as_i64())
                .filter(|v| *v > 0);
            let build = clean_client_text(&s("build"), 80, false);
            let zone = clean_client_text(&s("zone"), 80, false);
            let wire = match s("wire").as_str() {
                "ws" => "ws",
                "wt" => "wt",
                _ => "",
            };
            let rows = db
                .query(
                    "select
                         to_char(at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'),
                         kind, build, account, zone, room, wire, client_tick,
                         snapshot_tick, snapshot_seq, correction_px,
                         predicted_x, predicted_y, reconciled_x,
                         reconciled_y, predicted_vx, predicted_vy,
                         reconciled_vx, reconciled_vy, local_debt_px,
                         local_debt_deg, clock_adjust, repel_before_ticks,
                         repel_before_speed, repel_after_ticks,
                         repel_after_speed, frame_ms, snapshot_gap_ms,
                         input_ack, input_mask, input_margin, input_lead,
                         input_holes, user_agent
                     from client_debug
                     where at >= now() - make_interval(hours => $1)
                       and ($2::bigint is null or account = $2)
                       and ($3 = '' or build = $3)
                       and ($4 = '' or zone = $4)
                       and ($5 = '' or wire = $5)
                     order by at desc
                     limit $6 offset $7",
                    &[&hours, &account, &build, &zone, &wire, &probe, &offset],
                )
                .await;
            match rows {
                Ok(rows) => {
                    let more = rows.len() as i64 > limit;
                    (
                        200,
                        serde_json::json!({
                            "debug": rows.iter().take(limit as usize).map(|r| serde_json::json!({
                                "at": r.get::<_, String>(0),
                                "kind": r.get::<_, String>(1),
                                "build": r.get::<_, String>(2),
                                "account": r.get::<_, Option<i64>>(3),
                                "zone": r.get::<_, String>(4),
                                "room": r.get::<_, Option<i32>>(5),
                                "wire": r.get::<_, String>(6),
                                "client_tick": r.get::<_, i64>(7),
                                "snapshot_tick": r.get::<_, i64>(8),
                                "snapshot_seq": r.get::<_, i64>(9),
                                "correction_px": r.get::<_, f64>(10),
                                "predicted_x": r.get::<_, f64>(11),
                                "predicted_y": r.get::<_, f64>(12),
                                "reconciled_x": r.get::<_, f64>(13),
                                "reconciled_y": r.get::<_, f64>(14),
                                "predicted_vx": r.get::<_, f64>(15),
                                "predicted_vy": r.get::<_, f64>(16),
                                "reconciled_vx": r.get::<_, f64>(17),
                                "reconciled_vy": r.get::<_, f64>(18),
                                "local_debt_px": r.get::<_, f64>(19),
                                "local_debt_deg": r.get::<_, f64>(20),
                                "clock_adjust": r.get::<_, i32>(21),
                                "repel_before_ticks": r.get::<_, i32>(22),
                                "repel_before_speed": r.get::<_, f64>(23),
                                "repel_after_ticks": r.get::<_, i32>(24),
                                "repel_after_speed": r.get::<_, f64>(25),
                                "frame_ms": r.get::<_, f64>(26),
                                "snapshot_gap_ms": r.get::<_, f64>(27),
                                "input_ack": r.get::<_, i64>(28),
                                "input_mask": r.get::<_, i64>(29),
                                "input_margin": r.get::<_, i32>(30),
                                "input_lead": r.get::<_, i32>(31),
                                "input_holes": r.get::<_, i32>(32),
                                "user_agent": r.get::<_, String>(33),
                            })).collect::<Vec<_>>(),
                            "offset": offset,
                            "limit": limit,
                            "more": more,
                        }),
                    )
                }
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        // The pilot log across the whole fleet, newest first.
        //
        // The other read of the same table, and a different question: the one
        // above asks what somebody did, this asks what is happening. It is
        // what [admin.md](admin.md) calls noticing, which this panel spent a
        // while deliberately not doing, and the reason it is here now is that
        // the deployment asked for it. What has not changed is that nothing
        // watches this on anybody's behalf. An operator looks, or it says
        // nothing.
        //
        // Who and what arrive as lists, because the page offers them as facets
        // you tick rather than as one choice at a time.
        //
        // People and bots are still worth keeping apart, and the default is
        // still people alone: a room runs 51 bots against a handful of
        // players, so a mixed feed is bot arrivals with the interesting rows
        // pushed off the end of it. What changed is that it is now the
        // operator's call rather than the route's. The index survives it,
        // since `pilot_events_sweep` is on (bot, at) and `bot = any($1)` over
        // a two-value domain is one range scan per value rather than a walk.
        "/v1/admin/recent" => {
            if admin_for(&db, &s("secret")).await.is_none() {
                return (403, serde_json::json!({ "error": "not an admin" }));
            }
            // Ticking neither box is a question with no answer rather than a
            // question meaning "everything", so an empty list selects nothing
            // and the page says so.
            let who: Vec<bool> = match body.get("who").and_then(|v| v.as_array()) {
                Some(a) => {
                    let mut v: Vec<bool> = a
                        .iter()
                        .filter_map(|x| x.as_str())
                        .map(|s| s == "bots")
                        .collect();
                    v.sort_unstable();
                    v.dedup();
                    v
                }
                None => vec![false],
            };
            // Bounded by time as well as by count, so a rare kind cannot turn
            // this into a walk of the whole table looking for two hundred
            // refusals that are not there.
            let hours = body
                .get("hours")
                .and_then(|v| v.as_i64())
                .unwrap_or(24)
                .clamp(1, 24 * 30) as i32;
            // An empty list of kinds means every kind, which is the opposite
            // of how `who` reads and is right for the same reason: nobody
            // ticks thirteen boxes to say "no filter", and everybody unticks
            // one population to mean it.
            let kinds: Vec<String> = body
                .get("kinds")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default();
            // The call sign falls back to the account's current one. A row
            // the arena filed carries the name as it read at the time, which
            // is the honest one; a row the meta-layer filed about an account
            // carries none at all, and `#1` is a worse answer than a name
            // when both are available.
            let q = "select to_char(pe.at at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'),
                            coalesce(pe.session, ''), pe.kind,
                            coalesce(nullif(pe.name, ''), n.call_sign, ''), pe.pilot,
                            pe.zone, pe.instance, pe.room, pe.detail
                     from pilot_events pe
                     left join names n on n.account = pe.pilot
                     where pe.bot = any($1) and pe.at > now() - make_interval(hours => $2)";
            // One more than asked for, so the footer knows whether there is a
            // next page without counting a table that takes most of 300,000
            // rows a day. See `/v1/admin/events`, which pages the same way.
            let (limit, offset) = page_of(body);
            let probe = limit + 1;
            let rows = if kinds.is_empty() {
                db.query(
                    &format!("{q} order by pe.at desc, pe.id desc limit $3 offset $4"),
                    &[&who, &hours, &probe, &offset],
                )
                .await
            } else {
                db.query(
                    &format!(
                        "{q} and pe.kind = any($3) order by pe.at desc, pe.id desc \
                              limit $4 offset $5"
                    ),
                    &[&who, &hours, &kinds, &probe, &offset],
                )
                .await
            };
            // When the newest row of each kind landed, whatever the filter
            // above selected. Without it an empty table has two very different
            // meanings that look identical: nothing matches what you asked
            // for, or nothing is arriving at all. The first is a filter to
            // widen and the second is a fleet to go and look at.
            //
            // Two scalar subqueries rather than one `group by bot`, which
            // reads as the tidier statement and is not: grouping walks every
            // row of the index to find two maxima, and a subquery per value
            // is a backward index seek that stops at the first. Measured at
            // 120,000 rows it is 0.08ms against 15ms, and the gap is the
            // whole table, so it grows with the log while this does not.
            let mut newest = serde_json::Map::new();
            if let Ok(r) = db
                .query_one(
                    "select to_char((select max(at) from pilot_events where not bot)
                                    at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS'),
                            to_char((select max(at) from pilot_events where bot)
                                    at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS')",
                    &[],
                )
                .await
            {
                for (i, who) in ["people", "bots"].iter().enumerate() {
                    if let Some(t) = r.get::<_, Option<String>>(i) {
                        newest.insert((*who).into(), serde_json::Value::String(t));
                    }
                }
            }
            match rows {
                Ok(rs) => {
                    let more = rs.len() as i64 > limit;
                    (
                        200,
                        serde_json::json!({
                            "events": rs.iter().take(limit as usize).map(|r| serde_json::json!({
                                "at": r.get::<_, String>(0),
                                "session": r.get::<_, String>(1),
                                "kind": r.get::<_, String>(2),
                                "name": r.get::<_, String>(3),
                                "pilot": r.get::<_, Option<i64>>(4),
                                "zone": r.get::<_, String>(5),
                                "instance": r.get::<_, String>(6),
                                "room": r.get::<_, Option<i32>>(7),
                                "detail": r.get::<_, serde_json::Value>(8),
                            })).collect::<Vec<_>>(),
                            "offset": offset,
                            "limit": limit,
                            "more": more,
                            "hours": hours,
                            "newest": newest,
                        }),
                    )
                }
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
                crate::directory::request(&url, crate::fleet::O2D_FLEET, crate::fleet::D2O_FLEET)
                    .await
            else {
                return (
                    503,
                    serde_json::json!({
                        "error": format!("no answer from the directory at {url}")
                    }),
                );
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
            (
                200,
                serde_json::json!({
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
                        "host_id": i.host_id,
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
                }),
            )
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
                Ok(rs) => (
                    200,
                    serde_json::json!({
                        "admins": rs.iter().map(|r| serde_json::json!({
                            "account": r.get::<_, i64>(0),
                            "name": r.get::<_, String>(1),
                            "last_seen": r.get::<_, String>(2),
                        })).collect::<Vec<_>>(),
                    }),
                ),
                Err(e) => (500, serde_json::json!({ "error": format!("{e}") })),
            }
        }

        _ => (404, serde_json::json!({ "error": "no such route" })),
    }
}

/// One line of the pilot log about an account rather than a stay: created,
/// claimed, renamed, banned. No session, no room, no arena.
///
/// Best effort by design. These sit inside routes whose job is something else,
/// and a pilot must not be refused a login because the log would not take the
/// row. A failure says so on stdout and the route carries on.
async fn note_account(db: &Client, kind: &str, account: i64, detail: serde_json::Value) {
    if let Err(e) = db
        .execute(
            "insert into pilot_events (kind, pilot, detail) values ($1, $2, $3)",
            &[&kind, &account, &detail],
        )
        .await
    {
        println!("meta: cannot note {kind} for account {account}: {e}");
    }
}

// ------------------------------------------------------------------ client

/// How much of a list a request asked for, clamped.
///
/// Both numbers arrive from a client, so neither is trusted: a limit of a
/// million is a request to read the table into memory and a negative offset is
/// a syntax error at the far end. The default is a screen's worth rather than
/// everything, because a page that has to draw its way out of a slow answer
/// has already lost.
fn page_of(body: &serde_json::Value) -> (i64, i64) {
    let limit = body
        .get("limit")
        .and_then(|v| v.as_i64())
        .unwrap_or(50)
        .clamp(1, 200);
    let offset = body
        .get("offset")
        .and_then(|v| v.as_i64())
        .unwrap_or(0)
        .max(0);
    (limit, offset)
}

/// Where a `VW_META` value actually points.
///
/// A function with a return value rather than four lines inside `call`,
/// because those four lines were wrong for a year and nothing could say so.
/// They stripped `http://` and no other scheme, so an `https://` base fell
/// through to `split_once('/')`, which found the slash inside `https://` and
/// came back with a host of `https:` and a path of `//play.vectorwake.net/...`.
/// The host then looked like it carried a port, so it was dialled as written
/// and the kernel answered `invalid port value`.
///
/// That was invisible until the fleet grew past one host. An arena beside the
/// meta-layer is pointed at loopback and never takes this path; an arena on
/// its own box is pointed at the front door over https by `provision.sh`, and
/// from that moment it could not file a rated event, could not file a pilot
/// event, and its bot server could not claim a single account. All three go
/// through here, and all three failed the same way and stayed quiet about it.
struct Endpoint {
    tls: bool,
    /// What `connect` dials. Carries the port, whether it was written down or
    /// implied by the scheme.
    addr: String,
    /// What the `Host` header says, which keeps a non-default port because
    /// that is what the header is for.
    authority: String,
    /// What the certificate has to match, which never carries a port.
    server_name: String,
    /// Any path the base carried, ahead of the route's own.
    prefix: String,
}

fn endpoint(base: &str) -> Endpoint {
    let rest = base.trim_end_matches('/');
    let (tls, rest) = match rest.strip_prefix("https://") {
        Some(r) => (true, r),
        // No scheme is http, which is how a loopback address written bare in
        // `.env` has always reached the port beside it.
        None => (false, rest.strip_prefix("http://").unwrap_or(rest)),
    };
    let (authority, prefix) = match rest.split_once('/') {
        Some((h, p)) => (h, format!("/{p}")),
        None => (rest, String::new()),
    };
    let server_name = authority.split(':').next().unwrap_or(authority).to_string();
    let addr = if authority.contains(':') {
        authority.to_string()
    } else {
        format!("{authority}:{}", if tls { 443 } else { 80 })
    };
    Endpoint {
        tls,
        addr,
        authority: authority.to_string(),
        server_name,
        prefix,
    }
}

/// The roots and the cipher suite for an outbound https call, built once.
///
/// `install_crypto` in main.rs has already named the provider by the time
/// anything calls this, which is load-bearing: rustls panics rather than
/// choosing when two are compiled in, and this binary has two.
///
/// `VW_META_CA` extends the public roots, read the same way and from the same
/// file as the database client below reads it. A front door with a publicly
/// trusted certificate needs nothing; a laptop behind Caddy's internal CA, or
/// a host whose egress is inspected, hands this one path its issuer instead of
/// being unable to file anything.
fn tls_client() -> &'static tokio_rustls::TlsConnector {
    static CONNECTOR: std::sync::OnceLock<tokio_rustls::TlsConnector> = std::sync::OnceLock::new();
    CONNECTOR.get_or_init(|| {
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        if let Ok(path) = std::env::var("VW_META_CA") {
            match std::fs::read(&path) {
                Ok(pem) => {
                    let mut rd = std::io::BufReader::new(&pem[..]);
                    let added = rustls_pemfile::certs(&mut rd)
                        .flatten()
                        .filter(|c| roots.add(c.clone()).is_ok())
                        .count();
                    println!("meta: trusting {added} certificate(s) from {path}");
                }
                Err(e) => println!("meta: cannot read VW_META_CA {path}: {e}"),
            }
        }
        let cfg = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        tokio_rustls::TlsConnector::from(Arc::new(cfg))
    })
}

/// Write the request, read until the far end closes. Generic over the socket
/// so the plaintext and TLS paths are the same code rather than two copies
/// that drift.
async fn round_trip<S>(mut s: S, req: &str) -> Result<String, String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    s.write_all(req.as_bytes())
        .await
        .map_err(|e| format!("{e}"))?;
    let mut out = Vec::new();
    if let Err(e) = s.read_to_end(&mut out).await {
        // A peer that closes a TLS connection without close_notify is a
        // truncation, and rustls reports it rather than hiding it. With a
        // whole reply already in hand that is the close it is, so the error
        // matters only when nothing arrived.
        if out.is_empty() {
            return Err(format!("{e}"));
        }
    }
    Ok(String::from_utf8_lossy(&out).to_string())
}

/// A POST to the meta-layer, hand-rolled for the same reason `admin.rs`
/// hand-rolls its responder: a handful of request shapes, and a client library
/// would be the larger change. Plaintext to a port on this host, TLS through
/// the front door when the base says https, which is how an arena on its own
/// box reaches a meta-layer that is not beside it.
///
/// This is the only way anything in this binary talks to the service, so an
/// arena's rated events, its pilot events and the bot server's account claims
/// share one parser and one set of failure messages.
pub async fn call(base: &str, path: &str, body: &str) -> Result<serde_json::Value, String> {
    let e = endpoint(base);
    let tcp = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::net::TcpStream::connect(&e.addr),
    )
    .await
    .map_err(|_| format!("{} did not answer", e.addr))?
    .map_err(|err| format!("cannot reach {}: {err}", e.addr))?;
    let req = format!(
        "POST {}{path} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        e.prefix,
        e.authority,
        body.len()
    );
    let text = if e.tls {
        let name = rustls::pki_types::ServerName::try_from(e.server_name.clone())
            .map_err(|_| format!("{} is not a name a certificate can carry", e.server_name))?;
        let s = tls_client()
            .connect(name, tcp)
            .await
            .map_err(|err| format!("cannot negotiate TLS with {}: {err}", e.addr))?;
        round_trip(s, &req).await?
    } else {
        round_trip(tcp, &req).await?
    };
    let status = text.lines().next().unwrap_or("no reply").to_string();
    let payload = text.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");
    if !status.contains(" 200 ") {
        // The body carries the reason, and the reason is the useful half: an
        // unknown pool token reads very differently from a database that is
        // down, and both arrive as a non-200.
        let why = serde_json::from_str::<serde_json::Value>(payload)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or(status);
        return Err(why);
    }
    serde_json::from_str(payload).map_err(|e| format!("unreadable reply: {e}"))
}

/// Claim or renew the fleet-wide rated seat for one account.
pub async fn claim_rated_session(
    base: &str,
    pool_token: &str,
    account: u64,
    session: &str,
    instance: &str,
    zone: &str,
) -> Result<(bool, Vec<ClassRating>), String> {
    let body = serde_json::json!({
        "pool_token": pool_token,
        "account": account,
        "session": session,
        "instance": instance,
        // What that instance is serving. The row is a presence table as well
        // as an exclusion, and a friends page that could only say "somewhere"
        // is not one. See docs/design/friends.md.
        "zone": zone,
    })
    .to_string();
    let reply = call(base, "/v1/rated-session/claim", &body).await?;
    let claimed = reply
        .get("claimed")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let ratings = reply
        .get("ratings")
        .and_then(|value| value.as_array())
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    Some(ClassRating {
                        class: row.get("class")?.as_str()?.to_string(),
                        rating: row.get("rating")?.as_f64()?,
                        games: row.get("games")?.as_u64()?.min(u32::MAX as u64) as u32,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok((claimed, ratings))
}

/// Release a rated seat. The route is idempotent, so cleanup can call it
/// after any connection ending without first proving the row still exists.
pub async fn release_rated_session(
    base: &str,
    pool_token: &str,
    account: u64,
    session: &str,
) -> Result<(), String> {
    let body = serde_json::json!({
        "pool_token": pool_token,
        "account": account,
        "session": session,
    })
    .to_string();
    call(base, "/v1/rated-session/release", &body)
        .await
        .map(|_| ())
}

/// Recheck a connected account without claiming an exclusive rated seat.
pub async fn account_standing(base: &str, pool_token: &str, account: u64) -> Result<(), String> {
    let body = serde_json::json!({
        "pool_token": pool_token,
        "account": account,
    })
    .to_string();
    call(base, "/v1/account-standing", &body).await.map(|_| ())
}

// ------------------------------------------------------------------ server

const HTTP_HEADER_MAX: usize = 16 * 1024;
const HTTP_BODY_MAX: usize = 512 * 1024;
const HTTP_DEADLINE_SECS: u64 = 10;

async fn serve(mut stream: tokio::net::TcpStream, meta: Arc<Meta>) -> std::io::Result<()> {
    match tokio::time::timeout(
        std::time::Duration::from_secs(HTTP_DEADLINE_SECS),
        serve_request(&mut stream, meta),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => {
            reply(
                &mut stream,
                408,
                &serde_json::json!({ "error": "request timed out" }),
            )
            .await
        }
    }
}

async fn serve_request(stream: &mut tokio::net::TcpStream, meta: Arc<Meta>) -> std::io::Result<()> {
    let mut request_bytes = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        request_bytes.extend_from_slice(&chunk[..n]);
        if let Some(end) = request_bytes
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
        {
            break end + 4;
        }
        if request_bytes.len() > HTTP_HEADER_MAX {
            return reply(
                stream,
                431,
                &serde_json::json!({ "error": "request headers are too large" }),
            )
            .await;
        }
    };
    if head_end > HTTP_HEADER_MAX {
        return reply(
            stream,
            431,
            &serde_json::json!({ "error": "request headers are too large" }),
        )
        .await;
    }

    let head = String::from_utf8_lossy(&request_bytes[..head_end]);
    let request = head.split("\r\n").next().unwrap_or("");
    let mut parts = request.split(' ');
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/");

    // Who is asking, for the throttles. Behind Caddy every peer is loopback
    // and the truth rides in X-Forwarded-For; anything reaching this port
    // directly could write that header itself, but reaching it directly
    // means being on the host, which is a bigger problem than a throttle.
    let ip = head
        .split("\r\n")
        .find_map(|l| {
            let l = l.to_ascii_lowercase();
            l.strip_prefix("x-forwarded-for:")
                .map(|v| v.trim().split(',').next().unwrap_or("").trim().to_string())
        })
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            stream
                .peer_addr()
                .map(|a| a.ip().to_string())
                .unwrap_or_default()
        });

    let want = match content_length(&head) {
        Ok(length) => length,
        Err(error) => {
            return reply(stream, 400, &serde_json::json!({ "error": error })).await;
        }
    };
    if want > HTTP_BODY_MAX {
        return reply(
            stream,
            413,
            &serde_json::json!({ "error": "request body is too large" }),
        )
        .await;
    }
    let mut body = request_bytes[head_end..].to_vec();
    while body.len() < want {
        let left = want - body.len();
        let take = left.min(chunk.len());
        let n = stream.read(&mut chunk[..take]).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(want);

    let (code, out) = if method == "GET" && path == "/v1/health" {
        // Deliberately answerable without the database, so a health check
        // reports the process and the database reports itself.
        (200, serde_json::json!({ "service": "meta" }))
    } else if method != "POST" {
        (405, serde_json::json!({ "error": "post json" }))
    } else {
        let parsed: serde_json::Value =
            serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null);
        route(&meta, path, &parsed, &ip).await
    };

    reply(stream, code, &out).await
}

fn content_length(head: &str) -> Result<usize, &'static str> {
    let mut found = None;
    for line in head.split("\r\n") {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if !name.eq_ignore_ascii_case("content-length") {
            continue;
        }
        if found.is_some() {
            return Err("duplicate content-length");
        }
        found = Some(
            value
                .trim()
                .parse::<usize>()
                .map_err(|_| "invalid content-length")?,
        );
    }
    Ok(found.unwrap_or(0))
}

#[cfg(test)]
mod http_tests {
    use super::content_length;

    #[test]
    fn content_length_is_strict_and_case_insensitive() {
        assert_eq!(
            content_length("POST / HTTP/1.1\r\nContent-Length: 42\r\n"),
            Ok(42)
        );
        assert_eq!(
            content_length("POST / HTTP/1.1\r\ncontent-length: nope\r\n"),
            Err("invalid content-length")
        );
        assert_eq!(
            content_length("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n"),
            Err("duplicate content-length")
        );
    }
}

async fn reply(
    stream: &mut tokio::net::TcpStream,
    code: u16,
    out: &serde_json::Value,
) -> std::io::Result<()> {
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
        408 => "408 Request Timeout",
        409 => "409 Conflict",
        413 => "413 Payload Too Large",
        429 => "429 Too Many Requests",
        431 => "431 Request Header Fields Too Large",
        502 => "502 Bad Gateway",
        503 => "503 Service Unavailable",
        _ => "500 Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        out.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(out.as_bytes()).await?;
    stream.flush().await
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
    let declared_off = std::env::var("VW_ACCOUNTS")
        .map(|v| v == "0")
        .unwrap_or(false);
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
    let Some(signing) = std::env::var("VW_META_KEY")
        .ok()
        .and_then(|k| token::signing_key_from_hex(&k))
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
    // A database that will not answer is a hard failure, for the same reason
    // an empty connection string above is one, and it is the same mistake: a
    // line printed and a return exits zero, and `restart: on-failure`
    // correctly declines to restart a process that says it finished.
    //
    // The empty-string branch learned that and these three had not. A database
    // that was unreachable for the half second this ran during a deploy left
    // the meta-layer stopped with nothing to restart it, and the fleet looked
    // healthy from outside: the page served, the games list filled, the arena
    // ran its room. What it cost was alpha standing empty, because a house bot
    // that cannot get a token holds itself out of the room rather than fly
    // untokened, so fifty seats went unfilled and nothing anywhere was red.
    //
    // Exiting hands the retrying to docker's own backoff, which is the
    // supervisor's job rather than this function's.
    let pool = match cfg.create_pool(Some(deadpool_postgres::Runtime::Tokio1), tls) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("meta: cannot build a connection pool: {e}");
            std::process::exit(1);
        }
    };
    match pool.get().await {
        Ok(db) => {
            if let Err(e) = db.batch_execute(SCHEMA).await {
                eprintln!("meta: cannot apply schema: {e}");
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("meta: cannot reach the database: {e}");
            std::process::exit(1);
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

    // The same sweeper for the pilot log, and here nothing is kept forever.
    //
    // The rated log keeps every row with a person in it because a rating is a
    // claim about that person which may have to be replayed years later. This
    // log makes no such claim: it says where somebody was and what they pressed,
    // which answers a report, an outage or a question about ship popularity for
    // as long as anybody is going to ask, and after that is just a record of how
    // people play kept by a service whose best property is holding nothing of
    // the sort. So the humans expire too, at ninety days.
    //
    // Bot rows go far sooner. There are two orders of magnitude more of them
    // and their whole value is debugging our own software this week.
    {
        let pool = pool.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let Ok(db) = pool.get().await else { continue };
                // One statement over both windows, bounded like the pass
                // above. `pilot_events_sweep` is on (bot, at), so each half is
                // its own index scan rather than a walk of the table.
                match db
                    .execute(
                        "delete from pilot_events where ctid in (
                           select ctid from pilot_events
                           where (bot and at < now() - make_interval(days => $1))
                              or (not bot and at < now() - make_interval(days => $2))
                           limit 50000)",
                        &[&BOT_EVENT_DAYS, &PILOT_EVENT_DAYS],
                    )
                    .await
                {
                    Ok(n) if n > 0 => println!("meta: retired {n} pilot event(s)"),
                    Err(e) => println!("meta: pilot log retention pass failed: {e}"),
                    _ => {}
                }
            }
        });
    }

    // Browser error groups are operational diagnostics rather than game
    // history. A fault that keeps happening remains visible, while a quiet
    // group disappears thirty days after its last occurrence.
    {
        let pool = pool.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let Ok(db) = pool.get().await else { continue };
                match db
                    .execute(
                        "delete from client_errors where ctid in (
                           select ctid from client_errors
                           where last_at < now() - make_interval(days => $1)
                           limit 5000)",
                        &[&CLIENT_ERROR_DAYS],
                    )
                    .await
                {
                    Ok(n) if n > 0 => println!("meta: retired {n} client error group(s)"),
                    Err(e) => println!("meta: client error retention pass failed: {e}"),
                    _ => {}
                }
            }
        });
    }

    // Rollback reports are useful across the release that produced them and
    // no longer. Individual rows expire on their own timestamp because they
    // are observations, not grouped faults whose lifetime refreshes.
    {
        let pool = pool.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let Ok(db) = pool.get().await else { continue };
                match db
                    .execute(
                        "delete from client_debug where ctid in (
                           select ctid from client_debug
                           where at < now() - make_interval(days => $1)
                           limit 5000)",
                        &[&CLIENT_DEBUG_DAYS],
                    )
                    .await
                {
                    Ok(n) if n > 0 => println!("meta: retired {n} client debug report(s)"),
                    Err(e) => println!("meta: client debug retention pass failed: {e}"),
                    _ => {}
                }
            }
        });
    }

    let verifying = token::to_hex(signing.verifying_key().as_bytes());
    let meta = Arc::new(Meta {
        pool,
        signing,
        catalog,
        throttle: Throttle::default(),
        password_work: Arc::new(tokio::sync::Semaphore::new(PASSWORD_WORKERS)),
    });
    // And the same for the door itself. A meta-layer that got this far and
    // cannot listen is no more use than one that never started, so it says so
    // and leaves rather than sitting there having succeeded.
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("meta: cannot bind {addr}: {e}");
            std::process::exit(1);
        }
    };
    println!("meta-layer on http://{addr}");
    println!("  verifying key {verifying}");
    println!("  put that in the catalog's [meta] block so arenas can check tokens");
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
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

    fn rated_event() -> serde_json::Value {
        serde_json::json!({
            "id": 9,
            "tick": 100,
            "victim": 11,
            "killer": 12,
            "victim_kind": 0,
            "victim_before": 1200.0,
            "victim_after": 1184.0,
            "credits": [{
                "account": 12,
                "weight": 1.0,
                "before": 1200.0,
                "after": 1216.0
            }]
        })
    }

    #[test]
    fn a_well_formed_rating_event_is_accepted() {
        assert_eq!(settlement::validate_rated_event(&rated_event()), Ok(()));
    }

    #[test]
    fn a_rating_event_cannot_credit_one_account_twice() {
        let mut event = rated_event();
        let duplicate = event["credits"][0].clone();
        event["credits"].as_array_mut().unwrap().push(duplicate);
        assert_eq!(
            settlement::validate_rated_event(&event),
            Err("duplicate credited account".into())
        );
    }

    #[test]
    fn a_rating_event_cannot_credit_its_victim() {
        let mut event = rated_event();
        event["credits"][0]["account"] = serde_json::json!(11);
        assert_eq!(
            settlement::validate_rated_event(&event),
            Err("invalid credited account".into())
        );
    }

    #[test]
    fn a_rating_event_cannot_escape_the_model_bound() {
        let mut victim = rated_event();
        victim["victim_after"] = serde_json::json!(1300.0);
        assert_eq!(
            settlement::validate_rated_event(&victim),
            Err("victim rating movement exceeds the event bound".into())
        );

        let mut attacker = rated_event();
        attacker["credits"][0]["after"] = serde_json::json!(1300.0);
        assert_eq!(
            settlement::validate_rated_event(&attacker),
            Err("credit rating movement exceeds the event bound".into())
        );
    }

    /// Nobody is their own friend. A self edge would satisfy the mutual test
    /// against itself and draw as a friendship on the page, which is a thing
    /// somebody would report as a bug in the friends list rather than as a
    /// hole in this check.
    #[test]
    fn a_pilot_cannot_add_themselves() {
        assert_eq!(names_a_pilot(7, 7), Err((400, "no such pilot")));
        assert_eq!(names_a_pilot(7, 8), Ok(()));
    }

    /// And an id a client has lost track of is refused rather than sent to the
    /// database as a lookup that happens to find nothing.
    #[test]
    fn an_account_number_has_to_be_one() {
        assert_eq!(names_a_pilot(7, 0), Err((400, "no such pilot")));
        assert_eq!(names_a_pilot(7, -3), Err((400, "no such pilot")));
    }

    /// The list has a bound, and it is what makes the page, the query and the
    /// JSON finite rather than a judgment about how many friends to have.
    #[test]
    fn a_list_is_bounded() {
        assert_eq!(room_for_one_more(0), Ok(()));
        assert_eq!(room_for_one_more(MAX_FRIENDS - 1), Ok(()));
        assert_eq!(
            room_for_one_more(MAX_FRIENDS),
            Err((409, "that is as many as a list holds"))
        );
        // Over, not merely at: a list that grew past the bound some other way
        // still refuses rather than letting one more in per request.
        assert_eq!(
            room_for_one_more(MAX_FRIENDS + 40),
            Err((409, "that is as many as a list holds"))
        );
    }

    #[test]
    fn a_call_sign_is_a_word_and_three_digits() {
        for _ in 0..200 {
            let n = new_call_sign();
            let (word, digits) = n.rsplit_once(' ').expect("a space in every name");
            assert!(CALL_WORDS.contains(&word), "{n} draws from the list");
            assert_eq!(digits.len(), 3, "{n} carries three digits");
            assert!(digits
                .parse::<u32>()
                .is_ok_and(|d| (100..1000).contains(&d)));
            // The scoreboard's widest column: nothing generated may outgrow it.
            assert!(n.len() <= 12, "{n} is wider than the scoreboard");
        }
    }

    #[test]
    fn a_meta_url_comes_apart_the_way_it_was_written() {
        // The regression. `https://play.vectorwake.net/meta` is what
        // provision.sh writes on an arena host, and it used to parse as a
        // host of "https:" dialled on a port of nothing, which took out
        // rated events, pilot events and every bot account at once.
        let e = endpoint("https://play.vectorwake.net/meta");
        assert!(e.tls, "https is TLS");
        assert_eq!(
            e.addr, "play.vectorwake.net:443",
            "443 is implied by the scheme"
        );
        assert_eq!(e.server_name, "play.vectorwake.net");
        assert_eq!(e.authority, "play.vectorwake.net");
        assert_eq!(e.prefix, "/meta", "the base's own path leads the route's");
    }

    #[test]
    fn a_loopback_meta_url_is_unchanged() {
        // What a host running both writes, in all three spellings that have
        // ever appeared in a .env. None of them is TLS and none of them
        // acquires a port it did not ask for.
        for base in [
            "http://127.0.0.1:9400",
            "127.0.0.1:9400",
            "http://127.0.0.1:9400/",
        ] {
            let e = endpoint(base);
            assert!(!e.tls, "{base} is plaintext");
            assert_eq!(e.addr, "127.0.0.1:9400", "{base}");
            assert_eq!(
                e.authority, "127.0.0.1:9400",
                "{base} keeps its port in the header"
            );
            assert_eq!(e.prefix, "", "{base} has no path of its own");
        }
    }

    #[test]
    fn a_written_port_beats_the_scheme() {
        // A front door on a port of its own, which is what a staging host or
        // a laptop running Caddy on 8443 looks like. The certificate is still
        // checked against the name alone.
        let e = endpoint("https://play.localhost:8443/meta");
        assert!(e.tls);
        assert_eq!(
            e.addr, "play.localhost:8443",
            "the written port wins over 443"
        );
        assert_eq!(
            e.server_name, "play.localhost",
            "a cert name carries no port"
        );
        assert_eq!(e.authority, "play.localhost:8443");
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
            assert!(
                !seen.contains(&name.to_lowercase()),
                "{name} is an AI regular"
            );
        }
        for name in crate::ai::FILL_NAMES {
            assert!(!seen.contains(&name.to_lowercase()), "{name} is AI fill");
        }
        for name in crate::ai::CLASS_NAMES {
            assert!(!seen.contains(&name.to_lowercase()), "{name} is a hull");
        }
        for (name, _) in crate::rating::TIERS {
            assert!(
                !seen.contains(&name.to_lowercase()),
                "{name} is a rating tier"
            );
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
    fn throttle_keys_are_bounded() {
        let throttle = Throttle::default();
        for n in 0..5000 {
            assert!(throttle.allow(
                &format!("address-{n}"),
                1,
                std::time::Duration::from_secs(3600)
            ));
        }
        assert!(throttle.hits.lock().unwrap().len() <= 4096);
    }

    #[test]
    fn a_house_bot_secret_is_stable_until_the_pool_rotates() {
        let one = house_secret("pool one", "Cantry");
        assert_eq!(one, house_secret("pool one", "Cantry"));
        assert_ne!(one, house_secret("pool two", "Cantry"));
        assert_ne!(one, house_secret("pool one", "Carrack"));
    }

    #[test]
    fn names_are_cleaned_the_way_the_arena_cleans_them() {
        assert_eq!(clean_name("  Vesper 47  "), "Vesper 47");
        assert_eq!(clean_name("bad\u{1}name"), "badname");
        assert_eq!(clean_name(&"x".repeat(80)).len(), 24);
        assert_eq!(clean_name("   "), "");
    }

    #[test]
    fn client_errors_are_bounded_and_drop_credentials() {
        let secret = "a".repeat(64);
        let body = serde_json::json!({
            "kind": "promise",
            "message": format!("request failed for {secret}"),
            "stack": format!("trace {secret}\n{}", "x".repeat(5000)),
            "build": "launch",
            "origin": "https://play.vectorwake.net",
            "page": "/arena?secret=should-not-survive#room",
            "user_agent": "Vector\u{1}Wake",
            "account": 42,
        });
        let error = client_error_of(&body).expect("a valid browser error");
        assert_eq!(error.kind, "promise");
        assert!(error.message.contains("[redacted]"));
        assert!(!error.message.contains(&secret));
        assert!(error.stack.contains("[redacted]"));
        assert!(error.stack.chars().count() <= 4096);
        assert_eq!(error.page, "/arena");
        assert_eq!(error.user_agent, "VectorWake");
        assert_eq!(error.account, Some(42));
    }

    #[test]
    fn client_errors_need_a_message_and_normalize_the_kind() {
        assert!(client_error_of(&serde_json::json!({})).is_err());
        let error = client_error_of(&serde_json::json!({
            "kind": "invented",
            "message": "broken",
            "account": -1,
        }))
        .expect("a message is enough");
        assert_eq!(error.kind, "error");
        assert_eq!(error.account, None);
    }

    #[test]
    fn client_debug_reports_are_fixed_and_bounded() {
        let report = client_debug_of(&serde_json::json!({
            "kind": "local_correction",
            "build": "abc123",
            "account": 42,
            "zone": "alpha",
            "room": 3,
            "wire": "wt",
            "client_tick": u32::MAX,
            "snapshot_tick": 100,
            "snapshot_seq": 7,
            "correction_px": 91.5,
            "predicted_x": 917.25,
            "predicted_y": 828.5,
            "reconciled_x": 870.75,
            "reconciled_y": 750.0,
            "predicted_vx": 1.25,
            "predicted_vy": -0.5,
            "reconciled_vx": 5.0,
            "reconciled_vy": 0.25,
            "local_debt_px": 40.0,
            "local_debt_deg": 2.5,
            "clock_adjust": -1,
            "repel_before_ticks": 0,
            "repel_before_speed": 0.0,
            "repel_after_ticks": 212,
            "repel_after_speed": 5.0,
            "frame_ms": 16.7,
            "snapshot_gap_ms": 240.0,
            "input_ack": 106,
            "input_mask": u32::MAX,
            "input_margin": -6,
            "input_lead": 13,
            "input_holes": 0,
            "alive_before": true,
            "alive_after": true,
            "user_agent": "Vector\u{1}Wake",
        }))
        .expect("a bounded living correction");
        assert_eq!(report.account, Some(42));
        assert_eq!(report.client_tick, u32::MAX as i64);
        assert_eq!(report.wire, "wt");
        assert_eq!(report.clock_adjust, -1);
        assert_eq!(report.repel_after_ticks, 212);
        assert_eq!(report.repel_after_speed, 5.0);
        assert_eq!(report.user_agent, "VectorWake");
    }

    #[test]
    fn client_debug_rejects_noise_and_expected_discontinuities() {
        let valid = serde_json::json!({
            "kind": "local_correction",
            "wire": "ws",
            "client_tick": 110,
            "snapshot_tick": 100,
            "snapshot_seq": 7,
            "correction_px": 1.25,
            "predicted_x": 1.0,
            "predicted_y": 2.0,
            "reconciled_x": 3.0,
            "reconciled_y": 4.0,
            "predicted_vx": 1.0,
            "predicted_vy": 0.0,
            "reconciled_vx": 0.5,
            "reconciled_vy": 0.0,
            "local_debt_px": 1.25,
            "local_debt_deg": 0.0,
            "clock_adjust": 0,
            "repel_before_ticks": 0,
            "repel_before_speed": 0.0,
            "repel_after_ticks": 0,
            "repel_after_speed": 0.0,
            "frame_ms": 17.0,
            "snapshot_gap_ms": 50.0,
            "input_ack": 106,
            "input_mask": 1,
            "input_margin": -6,
            "input_lead": 10,
            "input_holes": 0,
            "alive_before": true,
            "alive_after": true,
        });
        assert!(client_debug_of(&valid).is_ok());

        let mut too_small = valid.clone();
        too_small["correction_px"] = serde_json::json!(0.5);
        assert!(client_debug_of(&too_small).is_err());

        let mut respawn = valid.clone();
        respawn["alive_before"] = serde_json::json!(false);
        assert!(client_debug_of(&respawn).is_err());

        let mut bad_wire = valid;
        bad_wire["wire"] = serde_json::json!("invented");
        assert!(client_debug_of(&bad_wire).is_err());
    }
}
