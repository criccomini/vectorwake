//! What each process will say about itself when something asks.
//!
//! A host graph says the box is busy. It does not say which of the six
//! processes on it is busy, and that is the question that actually gets asked:
//! an afternoon went into deciding whether the arenas or the bot server were
//! spending a pegged core, and the answer came from a commit message rather
//! than from the running fleet. The bot server, which turned out to be the
//! larger half, had nothing to ask at all.
//!
//! So every process serves its own numbers, including its own processor time,
//! read out of `/proc/self` and reported per process. Attribution is then
//! exact and costs nothing: no agent, no container-level accounting, and
//! nothing to keep in step with what is running.
//!
//! Prometheus text format, because it is a line per sample and every collector
//! reads it. There is no collector yet. That is deliberate: a number nobody
//! records is still a number somebody can `curl` at three in the morning, and
//! the endpoint is the part that has to exist first.
//!
//! Bound to loopback, and only when `VW_METRICS` names an address. A process
//! with nothing set opens no port at all.
//!
//! Caddy publishes them at `/metrics/<service>`, open to anyone: what they
//! expose is population, capacity and build stamps, none of which is a secret
//! this fleet keeps. The ports themselves stay on loopback, so the Caddy
//! route is the only way in. Anything that needs authority lives behind the
//! admin panel's account flag instead, never here.

use std::fmt::Write;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

/// A monotonic count of something that happened.
pub struct Counter(AtomicU64);

impl Counter {
    pub const fn new() -> Self {
        Counter(AtomicU64::new(0))
    }
    pub fn inc(&self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
    pub fn add(&self, n: u64) {
        self.0.fetch_add(n, Ordering::Relaxed);
    }
    pub fn get(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// A number that is whatever it currently is.
///
/// Published rather than read on demand: the tick loop writes these, and the
/// scrape reads them without taking the lock the tick loop is holding. A
/// metrics endpoint that has to wait for a busy arena is a metrics endpoint
/// that stops answering exactly when it is wanted.
pub struct Gauge(AtomicI64);

impl Gauge {
    pub const fn new() -> Self {
        Gauge(AtomicI64::new(0))
    }
    pub fn set(&self, v: i64) {
        self.0.store(v, Ordering::Relaxed);
    }
    pub fn get(&self) -> i64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// Where the time went, in buckets.
///
/// A single last-tick reading is what this replaces, and the reason is a
/// mistake it caused: one sample of an arena said 2300 microseconds against
/// 150 for the arena next door, which read as one room costing fifteen times
/// what its neighbours did. Twelve samples put its median at 289. The 2300 was
/// a real tick, the one every two seconds that also rebuilds the roster, and a
/// point sample of a periodic process finds it eventually.
///
/// Buckets, count and sum say all of that at once and cannot be caught out by
/// when the reading was taken.
pub struct Histogram {
    buckets: [AtomicU64; BOUNDS.len()],
    count: AtomicU64,
    /// Microseconds, summed. Integers because a tick is measured in them and a
    /// float here would be an atomic we would have to fake.
    sum_us: AtomicU64,
}

/// Bucket ceilings in microseconds. A tick has ten thousand of them to spend,
/// so the interesting range is the two decades below that and the fact of
/// going over.
const BOUNDS: [u64; 8] = [250, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000];

impl Histogram {
    #[allow(clippy::declare_interior_mutable_const)]
    pub const fn new() -> Self {
        // `AtomicU64::new` is const, but an array of them needs a repeated
        // const expression rather than a loop.
        const Z: AtomicU64 = AtomicU64::new(0);
        Histogram {
            buckets: [Z; BOUNDS.len()],
            count: AtomicU64::new(0),
            sum_us: AtomicU64::new(0),
        }
    }

    pub fn observe_us(&self, us: u64) {
        self.count.fetch_add(1, Ordering::Relaxed);
        self.sum_us.fetch_add(us, Ordering::Relaxed);
        for (i, b) in BOUNDS.iter().enumerate() {
            if us <= *b {
                self.buckets[i].fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    fn render(&self, out: &mut String, name: &str, help: &str) {
        let _ = writeln!(out, "# HELP {name} {help}");
        let _ = writeln!(out, "# TYPE {name} histogram");
        let total = self.count.load(Ordering::Relaxed);
        for (i, b) in BOUNDS.iter().enumerate() {
            // Seconds on the wire, because that is the unit the format's own
            // conventions use, whatever we measured in.
            let le = *b as f64 / 1e6;
            let v = self.buckets[i].load(Ordering::Relaxed);
            let _ = writeln!(out, "{name}_bucket{{le=\"{le}\"}} {v}");
        }
        let _ = writeln!(out, "{name}_bucket{{le=\"+Inf\"}} {total}");
        let _ = writeln!(out, "{name}_count {total}");
        let sum = self.sum_us.load(Ordering::Relaxed) as f64 / 1e6;
        let _ = writeln!(out, "{name}_sum {sum}");
    }
}

// --- what the fleet reports -------------------------------------------------
//
// Unlabeled on purpose. Each process is its own scrape target, so which zone
// and which role a number belongs to is the target's business rather than
// something repeated on every line. `vw_build_info` carries the identity once.

/// How long a tick took, end to end: every room stepped, and the periodic work
/// that rides on the same clock.
pub static TICK: Histogram = Histogram::new();
/// Humans, declared bots, and rooms, as of the last tick.
pub static PLAYERS: Gauge = Gauge::new();
pub static BOTS: Gauge = Gauge::new();
pub static ROOMS: Gauge = Gauge::new();
/// Sockets currently held, and how many have ever been accepted.
pub static CONNECTIONS: Gauge = Gauge::new();
pub static CONNECTIONS_TOTAL: Counter = Counter::new();
/// Snapshot bytes handed to the writers. Egress is the hosting bill, so this
/// is the number that turns into money.
pub static SNAPSHOT_BYTES: Counter = Counter::new();
/// The same bytes, to the seats that are not our own bots.
///
/// Which is the number `bw/seat` is actually about. A room seats fifty-one
/// house bots against a handful of people, and those bots sit on loopback and
/// are sent the whole room by design, so an average over every seat is an
/// average over a population that costs nothing and reads everything. Dividing
/// the total by all seats reported 305 kB/s on a fleet where a real client
/// downloading 17 was the fact anybody wanted.
///
/// The seats it is divided by, held beside it so the division happens where
/// the numbers are rather than being reconstructed from two unrelated gauges.
pub static SNAPSHOT_BYTES_OUT: Counter = Counter::new();
pub static SEATS_OUT: Gauge = Gauge::new();

/// The size of the most recent snapshot handed to a writer.
///
/// The counter above is what the deployment is billed for; this is what
/// server.md means by snapshot size, which is a property of one room's state
/// rather than of an afternoon's traffic. Both are wanted and neither answers
/// for the other.
pub static SNAPSHOT_LAST: Gauge = Gauge::new();

/// A counter read as a rate.
///
/// Two of the five numbers server.md names are rates rather than levels, and
/// a level is what a `Counter` holds: `vw_snapshot_bytes_total` climbing
/// forever says nothing about whether the last minute was busy. This keeps
/// the previous reading beside its timestamp and answers with the difference,
/// which is the same arithmetic a scrape would do and which nothing here is
/// currently doing for us.
///
/// Holds its last answer for a second, so a status push that arrives because
/// somebody joined does not divide a tiny delta by a tiny window and report a
/// wild number.
pub struct Rate {
    last_total: AtomicU64,
    last_ms: AtomicU64,
    held: AtomicU64,
}

impl Rate {
    pub const fn new() -> Self {
        Rate {
            last_total: AtomicU64::new(0),
            last_ms: AtomicU64::new(0),
            held: AtomicU64::new(0),
        }
    }

    /// Units per second since the previous sample at least a second ago.
    pub fn per_sec(&self, total: u64, now_ms: u64) -> u64 {
        let then = self.last_ms.load(Ordering::Relaxed);
        if then == 0 {
            self.last_ms.store(now_ms, Ordering::Relaxed);
            self.last_total.store(total, Ordering::Relaxed);
            return 0;
        }
        let elapsed = now_ms.saturating_sub(then);
        if elapsed < 1000 {
            return self.held.load(Ordering::Relaxed);
        }
        let grew = total.saturating_sub(self.last_total.load(Ordering::Relaxed));
        let rate = grew.saturating_mul(1000) / elapsed.max(1);
        self.last_total.store(total, Ordering::Relaxed);
        self.last_ms.store(now_ms, Ordering::Relaxed);
        self.held.store(rate, Ordering::Relaxed);
        rate
    }
}

/// Snapshot bytes and lag actions as rates. See `Rate`.
pub static BYTES_RATE: Rate = Rate::new();
/// The same, over the seats a snapshot is actually filtered for.
pub static OUT_RATE: Rate = Rate::new();
pub static LAG_RATE: Rate = Rate::new();

/// Messages dropped because a client's queue was full.
///
/// `try_send` drops rather than waits, which is the right choice and an
/// invisible one: a roster that went missing this way had a scoreboard reading
/// "ship 5" for a whole session before anybody worked out why.
pub static SEND_DROPPED: Counter = Counter::new();
/// Server-authoritative restrictions applied because a connection exceeded
/// its zone's lag thresholds.
pub static LAG_ACTIONS: Counter = Counter::new();
/// The WebTransport door: whether it is open, and who has come through it.
///
/// Two numbers because they answer two different questions and only one of
/// them is about players. `WT_LISTENING` is the deployment's own: the endpoint
/// is bound and accepting, which is otherwise invisible, because an arena that
/// cannot find its certificate or cannot bind its port says so once in a log
/// and then serves WebSockets perfectly happily. A closed door here looks
/// exactly like a working game.
///
/// `WT_SESSIONS` is the open question in networking.md, made countable: every
/// QUIC failure is silent by design and costs one fallback per session, so the
/// only way to know whether the better door is one most players come through
/// is to count the ones who do. Sessions rather than joins, because it counts
/// what the transport carried rather than what the arena seated.
/// And `WT_ATTEMPTS` splits the two ways a door can be shut. It counts QUIC
/// connection attempts the moment one arrives, before any handshake, so it is
/// the answer to the only question a fallback cannot distinguish: did the
/// client's packets reach this process at all? Zero attempts against a client
/// that waited and fell back means nothing arrived, and the fault is between
/// the two. Attempts without sessions means they arrived and we turned them
/// away, and the fault is here.
pub static WT_LISTENING: Gauge = Gauge::new();
pub static WT_ATTEMPTS: Counter = Counter::new();
pub static WT_SESSIONS: Counter = Counter::new();
/// The bot server: pilots it is flying, and how many times it has had to dial
/// an arena again. Reconnects are what a restart looks like from here.
pub static BOT_PILOTS: Gauge = Gauge::new();
pub static BOT_CONNECTS: Counter = Counter::new();
/// The directory: what it has been told, and what it turned away.
pub static REGISTRATIONS: Counter = Counter::new();
pub static REFUSALS: Counter = Counter::new();

/// Holds the connection count up for as long as a connection exists.
///
/// A counter incremented on accept and decremented at the end of the reader
/// loop would be wrong, because that task returns from a dozen places: a failed
/// handshake, a refused join, a socket that simply went away. Tying the
/// decrement to the value's lifetime means every one of those paths is already
/// handled.
pub struct ConnGuard;

impl ConnGuard {
    pub fn new() -> Self {
        CONNECTIONS_TOTAL.inc();
        CONNECTIONS.0.fetch_add(1, Ordering::Relaxed);
        ConnGuard
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        CONNECTIONS.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// The same, for a pilot the bot server is flying.
pub struct PilotGuard;

impl PilotGuard {
    pub fn new() -> Self {
        BOT_PILOTS.0.fetch_add(1, Ordering::Relaxed);
        PilotGuard
    }
}

impl Drop for PilotGuard {
    fn drop(&mut self) {
        BOT_PILOTS.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Which build this is, and which process.
///
/// The commit is baked in at image build time rather than passed in at run
/// time. Passing it in would change every container's environment on every
/// deploy, and compose recreates a container whose configuration moved, which
/// would put Caddy through a restart on every push and its certificates
/// through a rate limit that has taken this game down once already.
static ROLE: OnceLock<String> = OnceLock::new();
/// Which zone this arena is currently serving.
///
/// Not a `OnceLock`, because an arena does not know at startup: it binds its
/// listener, then registers with a directory, then is told which zone to run,
/// and it can be told a different one later. Captured at boot it was empty
/// forever, which is a label that looks like an answer and is not.
static ZONE: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

pub fn describe(role: &str, zone: &str) {
    let _ = ROLE.set(role.to_string());
    set_zone(zone);
}

/// Called wherever the current zone is known, which is the tick loop. Writes
/// only on a change, so the common case is a lock and a comparison.
pub fn set_zone(zone: &str) {
    if let Ok(mut z) = ZONE.lock() {
        if *z != zone {
            z.clear();
            z.push_str(zone);
        }
    }
}

/// The commit this binary was built from, or `unknown` outside CI. Public
/// because it is not only a metrics label: an arena carries it up the
/// registration socket, which is what lets an operator see a converge that
/// updated one process and not another.
pub fn commit() -> &'static str {
    option_env!("VW_COMMIT").unwrap_or("unknown")
}

// --- what the kernel already knows ------------------------------------------

static START: OnceLock<Instant> = OnceLock::new();

#[cfg(target_os = "linux")]
fn proc_self(out: &mut String) {
    // utime and stime are fields 14 and 15 of /proc/self/stat, in clock ticks.
    // The comm field can contain spaces and brackets, so the fields are counted
    // from after the last ')' rather than from the start of the line.
    if let Ok(stat) = std::fs::read_to_string("/proc/self/stat") {
        if let Some(rest) = stat.rsplit_once(')').map(|x| x.1) {
            let f: Vec<&str> = rest.split_whitespace().collect();
            // After the ')' the first field is state, so utime is index 11.
            if f.len() > 12 {
                let hz = 100.0; // USER_HZ is 100 on every Linux we deploy to.
                let ut: f64 = f[11].parse().unwrap_or(0.0);
                let st: f64 = f[12].parse().unwrap_or(0.0);
                let _ = writeln!(
                    out,
                    "# HELP process_cpu_seconds_total Processor time used by this process.\n\
                     # TYPE process_cpu_seconds_total counter\n\
                     process_cpu_seconds_total {}",
                    (ut + st) / hz
                );
            }
        }
    }
    if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
        for line in status.lines() {
            if let Some(v) = line.strip_prefix("VmRSS:") {
                let kb: f64 = v
                    .split_whitespace()
                    .next()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0.0);
                let _ = writeln!(
                    out,
                    "# HELP process_resident_memory_bytes Resident memory.\n\
                     # TYPE process_resident_memory_bytes gauge\n\
                     process_resident_memory_bytes {}",
                    kb * 1024.0
                );
            }
        }
    }
    if let Ok(d) = std::fs::read_dir("/proc/self/fd") {
        let _ = writeln!(
            out,
            "# HELP process_open_fds Open file descriptors.\n\
             # TYPE process_open_fds gauge\n\
             process_open_fds {}",
            d.count()
        );
    }
}

#[cfg(not(target_os = "linux"))]
fn proc_self(_out: &mut String) {}

/// Everything this process has to say, as one page.
pub fn render() -> String {
    let mut out = String::with_capacity(2048);
    let _ = writeln!(
        &mut out,
        "# HELP vw_build_info The build and role of this process.\n\
         # TYPE vw_build_info gauge\n\
         vw_build_info{{commit=\"{}\",role=\"{}\",zone=\"{}\"}} 1",
        commit(),
        ROLE.get().map(|s| s.as_str()).unwrap_or("unknown"),
        ZONE.lock().map(|z| z.clone()).unwrap_or_default(),
    );
    let up = START
        .get()
        .map(|t| t.elapsed().as_secs_f64())
        .unwrap_or(0.0);
    let _ = writeln!(
        &mut out,
        "# HELP vw_uptime_seconds Seconds since this process started serving.\n\
         # TYPE vw_uptime_seconds gauge\n\
         vw_uptime_seconds {up}"
    );
    proc_self(&mut out);

    TICK.render(&mut out, "vw_tick_seconds", "Wall time for one arena tick.");

    gauge(
        &mut out,
        "vw_players",
        "Humans in this arena.",
        PLAYERS.get(),
    );
    gauge(
        &mut out,
        "vw_bots",
        "Declared bots in this arena.",
        BOTS.get(),
    );
    gauge(
        &mut out,
        "vw_rooms",
        "Rooms this instance is running.",
        ROOMS.get(),
    );
    gauge(
        &mut out,
        "vw_connections",
        "Sockets held.",
        CONNECTIONS.get(),
    );
    gauge(
        &mut out,
        "vw_bot_pilots",
        "Pilots the bot server flies.",
        BOT_PILOTS.get(),
    );
    gauge(
        &mut out,
        "vw_wt_listening",
        "1 when this arena's WebTransport endpoint is bound and accepting.",
        WT_LISTENING.get(),
    );

    counter(
        &mut out,
        "vw_connections_total",
        "Sockets accepted.",
        CONNECTIONS_TOTAL.get(),
    );
    counter(
        &mut out,
        "vw_snapshot_bytes_total",
        "Snapshot bytes queued to clients.",
        SNAPSHOT_BYTES.get(),
    );
    counter(
        &mut out,
        "vw_snapshot_bytes_out_total",
        "Snapshot bytes queued to seats that are not our own bots.",
        SNAPSHOT_BYTES_OUT.get(),
    );
    gauge(
        &mut out,
        "vw_seats_out",
        "Seats a snapshot is filtered for, which is every seat not on loopback.",
        SEATS_OUT.get(),
    );
    counter(
        &mut out,
        "vw_send_dropped_total",
        "Messages dropped on a full client queue.",
        SEND_DROPPED.get(),
    );
    counter(
        &mut out,
        "vw_lag_actions_total",
        "Weapon, objective, and spectator restrictions applied for lag.",
        LAG_ACTIONS.get(),
    );
    counter(
        &mut out,
        "vw_wt_attempts_total",
        "QUIC connection attempts that reached this arena, handshake or not.",
        WT_ATTEMPTS.get(),
    );
    counter(
        &mut out,
        "vw_wt_sessions_total",
        "WebTransport sessions accepted, against vw_connections_total for the sockets.",
        WT_SESSIONS.get(),
    );
    counter(
        &mut out,
        "vw_bot_connects_total",
        "Arena connections the bot server has opened.",
        BOT_CONNECTS.get(),
    );
    counter(
        &mut out,
        "vw_registrations_total",
        "Arenas registered with this directory.",
        REGISTRATIONS.get(),
    );
    counter(
        &mut out,
        "vw_refusals_total",
        "Registrations this directory turned away.",
        REFUSALS.get(),
    );
    out
}

fn gauge(out: &mut String, name: &str, help: &str, v: i64) {
    let _ = writeln!(out, "# HELP {name} {help}\n# TYPE {name} gauge\n{name} {v}");
}

fn counter(out: &mut String, name: &str, help: &str, v: u64) {
    let _ = writeln!(
        out,
        "# HELP {name} {help}\n# TYPE {name} counter\n{name} {v}"
    );
}

// --- the endpoint -----------------------------------------------------------

/// Start serving metrics, if this deployment asked for them.
///
/// `VW_METRICS` is a bind address and its absence is the off switch. Nothing
/// in the game depends on this task: a port already taken, a malformed
/// address, a client that hangs up mid-request, all of it is reported once and
/// then ignored, because a process that refuses to run without its metrics
/// endpoint has made observability into an outage.
pub fn spawn(role: &str, zone: &str) {
    let _ = START.set(Instant::now());
    describe(role, zone);
    let addr = match std::env::var("VW_METRICS") {
        Ok(a) if !a.is_empty() => a,
        _ => return,
    };
    tokio::spawn(async move {
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                println!("metrics: cannot bind {addr} ({e}); serving none");
                return;
            }
        };
        println!("metrics on http://{addr}/metrics");
        loop {
            let (mut stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => continue,
            };
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = [0u8; 1024];
                let n = match stream.read(&mut buf).await {
                    Ok(n) if n > 0 => n,
                    _ => return,
                };
                let head = String::from_utf8_lossy(&buf[..n]);
                let body = if head.starts_with("GET /metrics") {
                    render()
                } else {
                    String::new()
                };
                let status = if body.is_empty() {
                    "404 Not Found"
                } else {
                    "200 OK"
                };
                let res = format!(
                    "HTTP/1.1 {status}\r\n\
                     Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n\
                     Content-Length: {}\r\n\
                     Connection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(res.as_bytes()).await;
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_histogram_counts_every_bucket_at_or_above_the_sample() {
        let h = Histogram::new();
        h.observe_us(300);
        let mut s = String::new();
        h.render(&mut s, "t", "help");
        // 300 us is over the 250 bucket and under every one above it.
        assert!(s.contains("t_bucket{le=\"0.00025\"} 0"), "{s}");
        assert!(s.contains("t_bucket{le=\"0.0005\"} 1"), "{s}");
        assert!(s.contains("t_bucket{le=\"0.01\"} 1"), "{s}");
        assert!(s.contains("t_bucket{le=\"+Inf\"} 1"), "{s}");
        assert!(s.contains("t_count 1"), "{s}");
        assert!(s.contains("t_sum 0.0003"), "{s}");
    }

    #[test]
    fn a_tick_over_budget_lands_past_the_ten_millisecond_bucket() {
        let h = Histogram::new();
        h.observe_us(12_000);
        let mut s = String::new();
        h.render(&mut s, "t", "help");
        assert!(s.contains("t_bucket{le=\"0.01\"} 0"), "{s}");
        assert!(s.contains("t_bucket{le=\"0.02\"} 1"), "{s}");
    }

    #[test]
    fn the_zone_can_be_named_after_the_process_started() {
        // An arena binds its listener, then registers, then is told which zone
        // to run. Captured once at boot this label was empty for the life of
        // the process, which reads on a graph as an arena serving nothing.
        set_zone("");
        assert!(render().contains("zone=\"\""));
        set_zone("chaos");
        assert!(render().contains("zone=\"chaos\""));
        set_zone("war");
        assert!(
            render().contains("zone=\"war\""),
            "a second change must take"
        );
    }

    #[test]
    fn a_connection_guard_puts_the_count_back() {
        let before = CONNECTIONS.get();
        {
            let _a = ConnGuard::new();
            let _b = ConnGuard::new();
            assert_eq!(CONNECTIONS.get(), before + 2);
        }
        assert_eq!(
            CONNECTIONS.get(),
            before,
            "a closed socket must be given up"
        );
        assert!(
            CONNECTIONS_TOTAL.get() >= 2,
            "and still be counted as having happened"
        );
    }

    #[test]
    fn the_page_names_its_build_and_its_role() {
        describe("arena", "chaos");
        let s = render();
        assert!(s.contains("vw_build_info{"), "{s}");
        assert!(s.contains("role=\"arena\""), "{s}");
        assert!(s.contains("zone=\"chaos\""), "{s}");
        // Every metric the page emits has to carry its type, or a scrape reads
        // a counter as a gauge and every rate over it is wrong.
        for line in s.lines() {
            if line.starts_with("# HELP ") {
                let name = line.split_whitespace().nth(2).unwrap();
                assert!(
                    s.contains(&format!("# TYPE {name} ")),
                    "{name} has help and no type"
                );
            }
        }
    }

    #[test]
    fn a_rate_is_the_difference_over_the_window() {
        let r = Rate::new();
        // The first sample has nothing to subtract from and says so.
        assert_eq!(r.per_sec(1_000, 10_000), 0);
        // Two seconds later, two thousand more: a thousand a second.
        assert_eq!(r.per_sec(3_000, 12_000), 1_000);
        // Asked again inside the same second it holds its last answer rather
        // than dividing a small delta by a smaller window. A held answer does
        // not move the baseline, which is the point: the next real sample
        // measures from the last one it recorded, not from the last question.
        assert_eq!(r.per_sec(3_100, 12_400), 1_000);
        // So this window is the two seconds since 12_000, over the hundred
        // the counter grew in them.
        assert_eq!(r.per_sec(3_100, 14_000), 50);
        // And a counter that has not moved since reads zero rather than stale.
        assert_eq!(r.per_sec(3_100, 16_000), 0);
    }

    #[test]
    fn a_rate_survives_a_counter_that_went_backwards() {
        // Nothing here resets a counter, but a reader that panicked or
        // underflowed on one would take a process down for a metric.
        let r = Rate::new();
        assert_eq!(r.per_sec(500, 1_000), 0);
        assert_eq!(r.per_sec(100, 3_000), 0);
    }
}
