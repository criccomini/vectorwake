//! vectorwake zone server.
//!
//! One process ticks every room at 100 Hz and is authoritative over everything
//! that matters. Clients send inputs and nothing else; positions, damage, and
//! deaths are outputs of `sim_step` and cannot be asserted from outside.
//!
//! Browsers reach the same message protocol over WebSocket or WebTransport.

mod ai;
mod arena;
mod bodies;
mod bots;
mod calibrate;
mod catalog;
mod config;
mod delivery;
mod directory;
mod drill;
mod experiment;
mod fleet;
mod growth;
mod mapforge;
mod melee_probe;
mod meta;
mod metrics;
mod modes;
mod nav;
mod pilot;
mod pilots;
mod presence;
mod profiles;
mod protocol;
mod rating;
mod room;
mod select;
mod session;
mod sim;
mod spool;
mod token;
mod wt;

#[cfg(test)]
use std::collections::HashMap;
use std::sync::Arc;

use arena::*;
use delivery::*;
use futures_util::{SinkExt, StreamExt};
#[cfg(test)]
use presence::*;
use protocol::*;
use room::*;
pub(crate) use session::serve_client;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

const TICK_HZ: u64 = 100;
/// Unauthenticated sockets get this long for each setup phase.
const HANDSHAKE_DEADLINE_SECS: u64 = 10;
/// Pending handshakes retain a task and a file descriptor before any account
/// or frame limit can apply.
const MAX_PENDING_HANDSHAKES: usize = 256;
/// Humans a zone admits when its file says nothing. The room may hold more
/// seats than this: `max_ships` sizes the room, and this bounds how many of its
/// seats people get, which is what leaves room for the bot roster.
const DEFAULT_MAX_PLAYERS: usize = 16;

/// Whether this arena files its rated exchanges with the meta-layer.
///
/// On unless `VW_REPORT` says otherwise. That way round because reporting is
/// what the ladder is made of, and a deployment that quietly kept its results
/// to itself would be a worse surprise than one that quietly sent them: the
/// off switch has to be something an operator wrote down.
///
/// Read per call rather than cached. It is an environment variable, so it
/// cannot change under a running process, and reading it costs nothing next to
/// the clock this is on.
fn reporting_enabled() -> bool {
    reporting_from(std::env::var("VW_REPORT").ok().as_deref())
}

/// The reading, split out from the environment so it can be tested without a
/// test reaching into a variable the whole process shares.
fn reporting_from(v: Option<&str>) -> bool {
    match v {
        Some(s) => !matches!(
            s.trim().to_ascii_lowercase().as_str(),
            "0" | "off" | "false" | "no"
        ),
        None => true,
    }
}
/// Watchers a room admits when its zone says nothing. Deliberately low: a
/// watcher is a full player's egress, and egress is the fleet's whole bill.
const DEFAULT_MAX_WATCHERS: usize = 8;
/// How far the room channel runs behind: five seconds, everywhere, and not a
/// zone's to set. Enough that what a second tab sees is film rather than
/// targeting data, short enough to still read as the fight it is. A dial here
/// was a dial for turning the protection off, and the one zone that turned it
/// down to zero did not need it: watching is the shared feed now, so nobody
/// can aim it at a chosen pilot however fresh the frame is.
const CHANNEL_DELAY: u32 = 500;
/// How long the channel holds one subject, in ticks. Long enough to catch a
/// fight's arc, short enough that a room's whole cast comes round.
const CHANNEL_HOLD: u32 = 9000;

/// Run the prespecified mirrored pilot experiment.
///
///     vectorwake-server calibrate pilots [paired_scenarios] [dir] [attempt_id]
///
/// Every run writes its full report. Only a report that passes the power,
/// holdout, equivalence, ordering, and content-fingerprint gates may replace
/// `pilot-ratings.json`.
fn run_pilot_tournament() {
    let mut request = calibrate::PilotCalibrationRequest::default();
    request.paired_scenarios_per_pool = std::env::args()
        .nth(3)
        .and_then(|value| value.parse().ok())
        .unwrap_or(request.paired_scenarios_per_pool);
    let dir = std::env::args().nth(4).unwrap_or_else(|| ".".into());
    request.attempt_id = std::env::args()
        .nth(5)
        .unwrap_or_else(|| request.attempt_id.clone());
    let roster = pilots::roster();
    let plan = match calibrate::plan_pilot_calibration(&roster, &request) {
        Ok(plan) => plan,
        Err(error) => {
            println!("pilots: {error}");
            std::process::exit(1);
        }
    };
    println!(
        "pilot calibration attempt {:?}: {} paired scenarios per matchup per pool; {} required for superiority, {} for side equivalence, {} for certification",
        request.attempt_id,
        request.paired_scenarios_per_pool,
        plan.power.required_pairs,
        plan.side_power.required_pairs,
        plan.power.required_pairs.max(plan.side_power.required_pairs)
    );
    let design_fingerprint = match calibrate::pilot_design_fingerprint(&plan) {
        Ok(fingerprint) => fingerprint,
        Err(error) => {
            println!("pilots: {error}");
            std::process::exit(1);
        }
    };
    println!("pilot calibration design: {design_fingerprint}");
    if request.attempt_id != "exploratory" {
        match calibrate::pilot_attempt_registered(&plan, arena::PILOT_CALIBRATION_ATTEMPTS) {
            Ok(true) => {}
            Ok(false) => {
                println!(
                    "pilots: attempt {:?} is not the sole preregistered attempt for {design_fingerprint}",
                    request.attempt_id
                );
                std::process::exit(1);
            }
            Err(error) => {
                println!("pilots: {error}");
                std::process::exit(1);
            }
        }
    }
    let release_signing_key = if request.attempt_id == "exploratory" {
        None
    } else {
        let Some(key) = std::env::var("VW_META_KEY")
            .ok()
            .and_then(|key| token::signing_key_from_hex(&key))
        else {
            println!(
                "pilots: VW_META_KEY is required before a confirmatory run starts; no scenarios were collected"
            );
            std::process::exit(1);
        };
        let Some(expected) = std::env::var("VW_META_VERIFY")
            .ok()
            .and_then(|key| token::verifying_key_from_hex(&key))
        else {
            println!(
                "pilots: VW_META_VERIFY is required before a confirmatory run starts; no scenarios were collected"
            );
            std::process::exit(1);
        };
        if key.verifying_key() != expected {
            println!(
                "pilots: VW_META_KEY does not match VW_META_VERIFY; no scenarios were collected"
            );
            std::process::exit(1);
        }
        Some(key)
    };
    let output_dir = std::path::Path::new(&dir);
    let writable_probe = output_dir.join(format!(
        ".pilot-calibration-write-test-{}",
        std::process::id()
    ));
    let output_ready = output_dir.is_dir()
        && std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&writable_probe)
            .is_ok();
    if !output_ready {
        println!("pilots: output directory {dir:?} is missing or not writable");
        std::process::exit(1);
    }
    if let Err(error) = std::fs::remove_file(&writable_probe) {
        println!("pilots: could not finish output check in {dir:?}: {error}");
        std::process::exit(1);
    }
    for name in [
        "pilot-calibration-data.json",
        "pilot-calibration-report.json",
        "pilot-calibration.json",
        "pilot-ratings.json",
    ] {
        let path = output_dir.join(name);
        if path.exists() && std::fs::OpenOptions::new().write(true).open(&path).is_err() {
            println!("pilots: existing output {} is not writable", path.display());
            std::process::exit(1);
        }
    }
    let dataset = match calibrate::collect_pilot_calibration(&roster, &plan, true) {
        Ok(dataset) => dataset,
        Err(error) => {
            println!("pilots: {error}");
            std::process::exit(1);
        }
    };
    let dataset_path = format!("{dir}/pilot-calibration-data.json");
    let dataset_file = match std::fs::File::create(&dataset_path) {
        Ok(file) => file,
        Err(error) => {
            println!("pilots: could not create {dataset_path}: {error}");
            std::process::exit(1);
        }
    };
    let mut dataset_writer = std::io::BufWriter::new(dataset_file);
    if let Err(error) = serde_json::to_writer(&mut dataset_writer, &dataset) {
        println!("pilots: could not write {dataset_path}: {error}");
        std::process::exit(1);
    }
    if let Err(error) = std::io::Write::flush(&mut dataset_writer) {
        println!("pilots: could not finish {dataset_path}: {error}");
        std::process::exit(1);
    }
    println!("wrote {dataset_path}");

    let report = match calibrate::analyze_pilot_calibration(&roster, &plan, &dataset) {
        Ok(report) => report,
        Err(error) => {
            println!("pilots: {error}; raw observations remain in {dataset_path}");
            std::process::exit(1);
        }
    };
    let report_path = format!("{dir}/pilot-calibration-report.json");
    let report_json = serde_json::to_string_pretty(&report).expect("serialize pilot report");
    if let Err(error) = std::fs::write(&report_path, report_json) {
        println!("pilots: could not write {report_path}: {error}");
        std::process::exit(1);
    }
    println!("wrote {report_path} with status {:?}", report.status);

    if report.certified_ladder.is_none() {
        println!(
            "pilot-ratings.json was not changed: {}",
            report.reasons.join("; ")
        );
        if request.attempt_id != "exploratory" {
            std::process::exit(1);
        }
        return;
    }
    let signing_key = release_signing_key
        .as_ref()
        .expect("only a confirmatory report can be certified");
    let attestation = match calibrate::attest_pilot_calibration(
        &report,
        &dataset,
        &roster,
        arena::PILOT_CALIBRATION_ATTEMPTS,
        signing_key,
    ) {
        Ok(attestation) => attestation,
        Err(error) => {
            println!("pilot-ratings.json was not changed: report verification failed: {error}");
            std::process::exit(1);
        }
    };
    let Some(attestation) = attestation else {
        println!("pilot-ratings.json was not changed: release evidence did not verify");
        std::process::exit(1);
    };
    let attestation_path = format!("{dir}/pilot-calibration.json");
    let attestation_json =
        serde_json::to_string_pretty(&attestation).expect("serialize pilot attestation");
    if let Err(error) = std::fs::write(&attestation_path, attestation_json) {
        println!("pilots: could not write {attestation_path}: {error}");
        std::process::exit(1);
    }
    println!("wrote certified {attestation_path}");

    let certified = &attestation.certified_ladder;
    let ratings: std::collections::BTreeMap<String, f64> = certified
        .iter()
        .map(|pilot| (pilot.callsign.clone(), pilot.elo))
        .collect();
    let ratings_path = format!("{dir}/pilot-ratings.json");
    let ratings_json = serde_json::to_string_pretty(&ratings).expect("serialize certified ratings");
    if let Err(error) = std::fs::write(&ratings_path, ratings_json) {
        println!("pilots: could not write {ratings_path}: {error}");
        std::process::exit(1);
    }
    println!("wrote certified {ratings_path}");
}

/// Run one named long-form measurement without registering it as a test.
///
///     vectorwake-server calibrate diagnostics <name>
fn run_calibration_diagnostic() {
    let name = std::env::args().nth(3).unwrap_or_default();
    if let Err(error) = calibrate::run_diagnostic(&name) {
        eprintln!("calibrate diagnostics: {error}");
        std::process::exit(1);
    }
}

/// `calibrate hulls <bouts> <kit> <zone> <dir>`: every hull against every
/// other on a matched budget.
///
/// The ladder holds the roster still so it can rank pilots. This varies the
/// roster instead, which is the whole balance question in a preconstructed
/// game: do the seven ships beat each other in a cycle, or is one of them a
/// line?
///
/// It used to need a kit budget on top, because a hull was a shape and a
/// budget bought the rest of the ship. Both sides bring their own profiles
/// now, so the only thing varying between them is which two hulls are in the
/// room.
///
/// Writes `hulls.json`, which nothing loads: it is a measurement to diff a
/// change against, where `ladder.json` is an input.
/// `calibrate builds <bouts> <zone> <dir> [map]`: every runaway build against
/// the hull it was spent on.
///
/// The question the hull tournament cannot ask. A hull is no longer the whole
/// ship: seven credits move between a dozen slots at one credit a step, so a
/// roster balanced hull against hull can still have one slot everybody dumps
/// into. Since a step cannot be made expensive, a slot that wins here has to
/// be made weaker or given a lower ceiling, and `sim_slot_cap` is where the
/// ceiling lives.
///
/// A mirror on purpose: both seats are the same hull, so the only difference
/// in the room is how the credits were spent.
/// `calibrate bodies <per_side> <pairs> <zone> <out.jsonl> [stratum]`: the
/// roster measured with the build randomized under it.
///
/// The hull tournament flies every body on the identical arrival build, which
/// since decision 121 is every body flying one seventh of the question. This
/// draws a build per seat out of the whole legal space, plays each lineup
/// twice with the sides swapped, and asks whether any body's win rate leaves
/// a band declared in advance.
///
/// Equivalence rather than difference, because "no significant difference"
/// over a small sample is a statement about the sample. `bodies::MARGIN` is
/// the band and the TOST family is Holm-adjusted across the seven, so what
/// comes out is one claim about the roster.
///
/// With no `pairs`, runs the pilot: enough to measure the pair variance and
/// print the sample size the margin actually needs.
fn run_body_balance() {
    let per_side: usize = std::env::args()
        .nth(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    let pairs: u32 = std::env::args()
        .nth(4)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let zone = std::env::args().nth(5).unwrap_or_else(|| "melee".into());
    let out = std::env::args().nth(6);
    let only = std::env::args().nth(7);

    let tuning = if zone == "baseline" {
        None
    } else {
        let cat = match catalog::load("catalog") {
            Ok(c) => c,
            Err(e) => {
                println!("bodies: {e}");
                std::process::exit(1);
            }
        };
        let Some(def) = cat.zone(&zone) else {
            println!("bodies: no zone named {zone:?} in the catalog");
            std::process::exit(1);
        };
        Some(def.arena.clone())
    };

    let world = sim::World::new(1);
    let builds = bodies::builds(&world);
    let rooms = bodies::rooms(per_side, "catalog/zones/melee");
    if rooms.is_empty() {
        println!("bodies: no rooms for {per_side}v{per_side}");
        std::process::exit(1);
    }
    let names: Vec<&str> = rooms.iter().map(|r| r.name.as_str()).collect();
    println!(
        "bodies {per_side}v{per_side} under {zone} tuning on {}: {} builds in the draw",
        names.join(", "),
        builds.len()
    );

    // No count is the pilot: a short run whose only job is to say how long
    // the real one has to be.
    let pilot = pairs == 0;
    let count = if pilot { 60 } else { pairs };
    let mut lines = Vec::new();
    for stratum in bodies::STRATA {
        if only.as_deref().is_some_and(|s| s != stratum.0) {
            continue;
        }
        let began = std::time::Instant::now();
        let mut got = bodies::run(
            per_side,
            count,
            stratum,
            &rooms,
            tuning.as_ref(),
            &builds,
            true,
        );
        println!(
            "  {} {} pairs in {:.0}s, {} seats",
            stratum.0,
            count,
            began.elapsed().as_secs_f64(),
            got.len()
        );
        lines.append(&mut got);
    }

    if pilot {
        let (variance, needed) = bodies::plan(&lines);
        let decided = lines.iter().filter(|l| l.decided).count() as f64 / lines.len() as f64;
        println!(
            "
pilot: pair variance {variance:.4}, {:.0}% of matches decided",
            decided * 100.0
        );
        // A body is only in a pair if the draw seats it, so the pairs a
        // stratum needs is what it takes to give every body that many
        // appearances: one minus the chance the draw misses it every seat.
        let seats = (per_side * 2) as i32;
        let n = sim::MAX_CLASSES as f64;
        let appears = 1.0 - ((n - 1.0) / n).powi(seats);
        println!(
            "to resolve a {:.0}-point margin at power 0.90 with Holm over seven bodies: \
             {needed} pairs a body, which at {:.0}% appearance is {:.0} pairs a stratum",
            bodies::MARGIN * 100.0,
            appears * 100.0,
            needed as f64 / appears
        );
        return;
    }

    if let Some(path) = &out {
        match std::fs::File::create(path) {
            Ok(file) => {
                use std::io::Write;
                let mut file = std::io::BufWriter::new(file);
                for line in &lines {
                    let _ = writeln!(file, "{}", serde_json::to_string(line).unwrap_or_default());
                }
                println!("\nwrote {} seats to {path}", lines.len());
            }
            Err(e) => println!("bodies: {path:?} will not open: {e}"),
        }
    }

    for stratum in bodies::STRATA {
        let slice: Vec<bodies::SeatLine> = lines
            .iter()
            .filter(|l| l.stratum == stratum.0)
            .cloned()
            .collect();
        if slice.is_empty() {
            continue;
        }
        println!("\n{} skill, {per_side}v{per_side}:", stratum.0);
        println!(
            "{:<9} {:>6} {:>7} {:>15} {:>6} {:>6} {:>7} {:>7}",
            "body", "seats", "win%", "family-wise 95%", "draw%", "k/d", "dmg", "holm p"
        );
        for row in bodies::analyze(&slice) {
            println!(
                "{:<9} {:>6} {:>6.1}% {:>7.1} to {:<5.1} {:>5.0}% {:>6.2} {:>7.0} {:>7.3}{}",
                row.body,
                row.seats,
                row.win_rate * 100.0,
                row.low * 100.0,
                row.high * 100.0,
                row.draws * 100.0,
                row.kd,
                row.damage_per_seat,
                row.equivalence_p,
                if row.equivalent { "" } else { "  outside" }
            );
        }
    }
}

fn run_build_sweep() {
    let bouts: u32 = std::env::args()
        .nth(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(12);
    let zone = std::env::args().nth(4).unwrap_or_else(|| "baseline".into());
    let dir = std::env::args().nth(5).unwrap_or_else(|| ".".into());
    let map = std::env::args().nth(6).unwrap_or_else(|| "pit".into());

    let builder = match map.as_str() {
        "pit" => calibrate::Arena::Built(sim::build_pit),
        "arena" => calibrate::Arena::Built(sim::build_arena),
        path => match std::fs::read(path) {
            Ok(bytes) => calibrate::Arena::Packed(std::sync::Arc::new(bytes)),
            Err(e) => {
                println!("builds: {path:?} will not open: {e}");
                std::process::exit(1);
            }
        },
    };
    let tuning = if zone == "baseline" {
        None
    } else {
        let cat = match catalog::load("catalog") {
            Ok(c) => c,
            Err(e) => {
                println!("builds: {e}");
                std::process::exit(1);
            }
        };
        let Some(def) = cat.zone(&zone) else {
            println!("builds: no zone named {zone:?} in the catalog");
            std::process::exit(1);
        };
        Some(def.arena.clone())
    };

    const SKILL: f32 = 0.50;
    println!("builds under {zone} tuning on the {map}: {bouts} bouts each");
    let rows = calibrate::run_builds(SKILL, bouts, tuning.as_ref(), &builder, true);

    // The top of the table is the whole reading: a build well past even
    // against the ship it was spent on is a build the roster converges on.
    println!("\nthe builds that beat the ship they were spent on:");
    for r in rows.iter().take(12) {
        println!(
            "  {:>7}  {:5.1}%  {}",
            r.name,
            r.win_rate() * 100.0,
            r.spend
        );
    }
    let runaway: Vec<&calibrate::BuildRow> = rows.iter().filter(|r| r.win_rate() > 0.65).collect();
    if runaway.is_empty() {
        println!(
            "\nnothing runs away with it: no build beats its own hull's row \
past 65%, so the credits are worth about the same wherever they go."
        );
    } else {
        println!(
            "\n{} builds beat their own hull's row past 65%. Every step costs \
one, so the answer is a lower ceiling or a weaker step, never a higher price.",
            runaway.len()
        );
    }

    let doc = serde_json::json!({
        "tuning": zone,
        "map": map,
        "skill": SKILL,
        "bouts_per_build": bouts,
        "builds": rows.iter().map(|r| serde_json::json!({
            "name": r.name,
            "class": r.class,
            "spend": r.spend,
            "wins": r.wins,
            "losses": r.losses,
            "draws": r.draws,
            "win_rate": r.win_rate(),
        })).collect::<Vec<_>>(),
    });
    let path = format!("{dir}/builds.json");
    match std::fs::write(
        &path,
        serde_json::to_string_pretty(&doc).expect("serialize"),
    ) {
        Ok(()) => println!("\nwrote {path}"),
        Err(e) => println!("\ncould not write {path}: {e}"),
    }
}

fn run_hull_tournament() {
    let bouts: u32 = std::env::args()
        .nth(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(24);
    let zone = std::env::args().nth(4).unwrap_or_else(|| "baseline".into());
    let dir = std::env::args().nth(5).unwrap_or_else(|| ".".into());
    let map = std::env::args().nth(6).unwrap_or_else(|| "pit".into());

    // The pit is one room thirty-two tiles across and a pilot can see the whole
    // of it, which suits the loadout tournament and flatters exactly the hulls
    // that are meant to be strong up close. The arena has cover, lanes and
    // somewhere to run to, so a hull whose weakness is written down as "loses
    // outside two tiles" has room to lose there. Anything measured on one and
    // not the other is a fact about that room.
    let builder = match map.as_str() {
        "pit" => calibrate::Arena::Built(sim::build_pit),
        "arena" => calibrate::Arena::Built(sim::build_arena),
        // Anything else is a path to a packed map, which is how a zone's own
        // room and anything mapgen makes get measured. A roster is balanced on
        // a map or it is not balanced, and two rooms are the fewest that can
        // tell a hull from the place it was tested.
        path => match std::fs::read(path) {
            Ok(bytes) => calibrate::Arena::Packed(std::sync::Arc::new(bytes)),
            Err(e) => {
                println!("hulls: {path:?} is not `pit`, not `arena`, and will not open: {e}");
                std::process::exit(1);
            }
        },
    };

    let tuning = if zone == "baseline" {
        None
    } else {
        let cat = match catalog::load("catalog") {
            Ok(c) => c,
            Err(e) => {
                println!("hulls: {e}");
                std::process::exit(1);
            }
        };
        let Some(def) = cat.zone(&zone) else {
            println!("hulls: no zone named {zone:?} in the catalog");
            std::process::exit(1);
        };
        Some(def.arena.clone())
    };

    const SKILL: f32 = 0.50;
    let n = ai::CLASS_NAMES.len();
    println!(
        "hulls under {zone} tuning on the {map}: {} pairs, {bouts} bouts each",
        n * (n + 1) / 2
    );
    let rows = calibrate::run_hulls(SKILL, bouts, tuning.as_ref(), &builder, true);
    let doc = calibrate::report_hulls(&rows, SKILL, bouts, &zone, &map, &builder);

    let path = format!("{dir}/hulls.json");
    match std::fs::write(
        &path,
        serde_json::to_string_pretty(&doc).expect("serialize"),
    ) {
        Ok(()) => println!("\nwrote {path}"),
        Err(e) => println!("\ncould not write {path}: {e}"),
    }
}

/// `calibrate teams <matches> <per_side> <kit> <zone> <dir> [map]`: sides
/// drawn at random, scored by the seats each hull filled.
///
/// The hull tournament fights one against one, which cannot see a hull whose
/// job is to hold ground or screen somebody. This fills both sides from the
/// roster at random and asks a simpler question of every seat: did the side it
/// was on win. A hull that keeps turning up on winning teams is worth having,
/// whether or not it is the one collecting kills.
///
/// Writes `teams.json`, which nothing loads.
fn run_team_tournament() {
    let matches: u32 = std::env::args()
        .nth(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(200);
    let per_side: usize = std::env::args()
        .nth(4)
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    let zone = std::env::args().nth(5).unwrap_or_else(|| "baseline".into());
    let dir = std::env::args().nth(6).unwrap_or_else(|| ".".into());
    let map = std::env::args().nth(7).unwrap_or_else(|| "arena".into());

    if per_side == 0 || per_side > 16 {
        println!("teams: {per_side} a side is not a game");
        std::process::exit(1);
    }

    let builder = match map.as_str() {
        "pit" => calibrate::Arena::Built(sim::build_pit),
        "arena" => calibrate::Arena::Built(sim::build_arena),
        path => match std::fs::read(path) {
            Ok(bytes) => calibrate::Arena::Packed(std::sync::Arc::new(bytes)),
            Err(e) => {
                println!("teams: {path:?} is not `pit`, not `arena`, and will not open: {e}");
                std::process::exit(1);
            }
        },
    };

    // The pit seats two facing each other and nothing else. Eight ships want a
    // map with starts on it, so this refuses rather than piling them on one
    // tile and calling the result a team game.
    if matches!(builder, calibrate::Arena::Built(_)) && map == "pit" {
        println!("teams: the pit has two spawn tiles; use `arena` or a packed map");
        std::process::exit(1);
    }

    let tuning = if zone == "baseline" {
        None
    } else {
        let cat = match catalog::load("catalog") {
            Ok(c) => c,
            Err(e) => {
                println!("teams: {e}");
                std::process::exit(1);
            }
        };
        let Some(def) = cat.zone(&zone) else {
            println!("teams: no zone named {zone:?} in the catalog");
            std::process::exit(1);
        };
        Some(def.arena.clone())
    };

    const SKILL: f32 = 0.50;
    let spawn_radius = tuning.as_ref().and_then(|c| c.spawn_radius).unwrap_or(0);
    println!(
        "{per_side} a side under {zone} tuning on the {map}: {matches} matches, \
spawn radius {spawn_radius}"
    );
    let rows = calibrate::run_teams(per_side, matches, SKILL, tuning.as_ref(), &builder, true);
    let doc = calibrate::report_teams(&rows, per_side, SKILL, matches, &zone, &map, spawn_radius);

    let path = format!("{dir}/teams.json");
    match std::fs::write(
        &path,
        serde_json::to_string_pretty(&doc).expect("serialize"),
    ) {
        Ok(()) => println!("\nwrote {path}"),
        Err(e) => println!("\ncould not write {path}: {e}"),
    }
}

/// Where the directories are. `VW_DIRECTORY` names a host, which is resolved,
/// so one hostname with several records is a whole deployment and a directory can
/// be added or moved without touching an arena server. That is the DNS decision
/// in docs/architecture/discovery.md: `directory.vectorwake.net` resolves to
/// every directory of this deployment.
///
/// An explicit `ws://` or `wss://` URL is taken as given, which is what a
/// developer running one of each on a laptop wants.
async fn directory_urls() -> Vec<String> {
    let spec = std::env::var("VW_DIRECTORY").unwrap_or_default();
    if spec.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for part in spec.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        if part.starts_with("ws://") || part.starts_with("wss://") {
            out.push(part.to_string());
            continue;
        }
        // A bare host, optionally with a port. Resolve it and take every record,
        // so a round-robin name is a list of directories.
        let (host, port) = match part.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => (h, p.to_string()),
            _ => (part, "9000".to_string()),
        };
        match tokio::net::lookup_host(format!("{host}:{port}")).await {
            Ok(addrs) => {
                let mut seen = Vec::new();
                for a in addrs {
                    // wss for a real hostname, because the token is a bearer
                    // credential and the directory will refuse it in the clear.
                    // Loopback is development and stays ws.
                    let scheme = if a.ip().is_loopback() { "ws" } else { "wss" };
                    // Dial the name rather than the address so TLS verifies: the
                    // certificate is issued for the hostname, and all of a
                    // deployment's directories share it.
                    let url = if a.ip().is_loopback() {
                        format!("{scheme}://{a}")
                    } else {
                        format!("{scheme}://{host}:{port}")
                    };
                    if !seen.contains(&url) {
                        seen.push(url);
                    }
                }
                if seen.is_empty() {
                    println!("VW_DIRECTORY {part:?} resolved to nothing");
                }
                out.extend(seen);
            }
            Err(e) => println!("VW_DIRECTORY {part:?}: {e}"),
        }
    }
    // Shuffled, so a fleet of identical containers does not all prefer the same
    // directory. The order is arbitrary and only needs to differ between hosts.
    let n = out.len();
    if n > 1 {
        let seed = (fleet::now_ms() as usize).wrapping_mul(2654435761);
        out.rotate_left(seed % n);
    }
    println!("directories: {}", out.join(", "));
    out
}

/// Either kind of accepted connection, boxed so the connection handler is
/// written once. tokio implements AsyncRead and AsyncWrite for Box<T>, and a
/// trait object carries its supertraits, so this needs no glue of its own.
pub trait Conn: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Conn for T {}

/// Build a TLS acceptor from PEM files, or None when the zone is plain ws.
/// A zone that is configured for TLS and cannot load its certificate must
/// not quietly fall back to cleartext: the operator asked for wss, and
/// serving ws instead would look like it worked.
pub fn tls_acceptor(cert: &str, key: &str) -> Option<tokio_rustls::TlsAcceptor> {
    if cert.is_empty() && key.is_empty() {
        return None;
    }
    if cert.is_empty() || key.is_empty() {
        panic!("tls_cert and tls_key must be set together");
    }
    let certs: Vec<_> = rustls_pemfile::certs(&mut std::io::BufReader::new(
        std::fs::File::open(cert).unwrap_or_else(|e| panic!("tls_cert {cert}: {e}")),
    ))
    .collect::<Result<_, _>>()
    .expect("tls_cert is not a PEM certificate chain");
    let k = rustls_pemfile::private_key(&mut std::io::BufReader::new(
        std::fs::File::open(key).unwrap_or_else(|e| panic!("tls_key {key}: {e}")),
    ))
    .expect("tls_key is not readable")
    .expect("tls_key holds no private key");
    let cfg = tokio_rustls::rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, k)
        .expect("certificate and key do not match");
    Some(tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(cfg)))
}

/// Name the cryptography every outbound TLS connection will use, before any of
/// them is made.
///
/// rustls picks a provider from its crate features, and it refuses to guess
/// when more than one is compiled in: `ClientConfig::builder()` *panics* rather
/// than returning an error. Two are in this binary now, because the QUIC stack
/// behind the WebTransport door brings `aws-lc-rs` while everything already
/// here uses `ring`, and neither is wrong; what is wrong is leaving the choice
/// implicit.
///
/// It cost an outage to learn where that lands. Nothing about the arena
/// changed: it served, it registered, it filled with bots, and every test
/// passed. What broke was the one TLS *client* in the fleet, the directory's
/// dial of an arena's advertised address, which is how an instance is proven
/// before players are sent to it. The panic died inside the task that made it,
/// so no instance was ever verified, the browse reply listed a zone with
/// nothing serving it, and the games list read "no servers found" over a
/// perfectly healthy fleet.
///
/// `ring`, because that is what this binary used before QUIC arrived, so every
/// connection that worked yesterday is made the same way today. Idempotent by
/// intent: a second call answers Err and there is nothing to report.
fn install_crypto() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

#[tokio::main]
async fn main() {
    // First, before any subcommand: the directory, the bot server and the
    // meta-layer client all dial out, and a provider installed after the first
    // dial is a provider installed too late.
    install_crypto();
    if std::env::args().nth(1).as_deref() == Some("directory") {
        directory::run().await;
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("catalog") {
        catalog::run_check();
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("token") {
        catalog::run_token();
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("calibrate") {
        // The ladder ranks pilots with the roster held still. These rank the
        // roster instead, which is the question a preconstructed game asks:
        // do the seven ships beat each other in a cycle.
        if std::env::args().nth(2).as_deref() == Some("diagnostics") {
            run_calibration_diagnostic();
        } else if std::env::args().nth(2).as_deref() == Some("pilots") {
            run_pilot_tournament();
        } else if std::env::args().nth(2).as_deref() == Some("hulls") {
            run_hull_tournament();
        } else if std::env::args().nth(2).as_deref() == Some("builds") {
            run_build_sweep();
        } else if std::env::args().nth(2).as_deref() == Some("teams") {
            run_team_tournament();
        } else if std::env::args().nth(2).as_deref() == Some("bodies") {
            run_body_balance();
        } else {
            println!("calibrate needs one of: diagnostics, pilots, hulls, builds, teams, bodies");
            std::process::exit(2);
        }
        return;
    }
    // What the ladder cannot see: the roster on a real map, with walls in it.
    if std::env::args().nth(1).as_deref() == Some("drill") {
        drill::run_check();
        return;
    }
    // What a team battle looks like from inside, per pilot.
    if std::env::args().nth(1).as_deref() == Some("melee") {
        melee_probe::run();
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("mapforge") {
        mapforge::run();
        return;
    }
    // The meta-layer: accounts, ratings, and the rated event log. The one
    // process in the fleet with a database behind it, and the one every other
    // process is designed to survive the loss of.
    if std::env::args().nth(1).as_deref() == Some("meta") {
        meta::run().await;
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("metakey") {
        meta::run_keygen();
        return;
    }
    // The bot server. Same binary as the arena and the directory, and a
    // separate process for the same reason they are: one image, run with
    // different first arguments, is what a deployment of this thing is.
    //
    // It also settles what "a crate both depend on" was going to mean. The
    // calibration tournament and the live bots have to run identical code or
    // the ladder rates pilots that do not exist, and being one program makes
    // that structural rather than a rule about dependencies.
    if std::env::args().nth(1).as_deref() == Some("bots") {
        bots::run().await;
        return;
    }
    let addr_arg = std::env::args().nth(1);

    let dir = std::env::args().nth(2).unwrap_or_else(|| ".".into());
    let (watcher, err) = config::ConfigWatcher::load(format!("{dir}/zone.toml"));
    if let Some(e) = err {
        println!("no usable zone.toml ({e}); running on the built-in defaults");
    }
    // The one thing an arena's disk holds besides its instance id: rated
    // events waiting for the meta-layer.
    let spools = spool::Spools::open(&dir);
    tokio::spawn(spool::drain_loop(spools.rated.clone()));
    tokio::spawn(spool::drain_loop(spools.pilots.clone()));
    tokio::spawn(spool::drain_loop(spools.matches.clone()));
    let ladder = load_ladder(&dir);
    let seed_source = if arena::certified_pilot_attestation().is_some() {
        "the verified compiled pilot report"
    } else {
        "the provisional anchor"
    };
    println!("seeded {} bot ratings from {seed_source}", ladder.len());
    println!("zone \"{}\"", watcher.current.name);
    // The command line wins over the zone file, so an operator can move a
    // zone to another port without editing its configuration.
    let addr = addr_arg.unwrap_or_else(|| watcher.current.listen.clone());
    // Read before the watcher moves into the zone. Certificates are not
    // hot-reloaded: a listener is bound once, and swapping its identity
    // underneath live connections is not something an operator asked for.
    let cfg_tls = (
        watcher.current.tls_cert.clone(),
        watcher.current.tls_key.clone(),
    );
    let cfg_wt = (
        watcher.current.wt_listen.clone(),
        watcher.current.wt_cert.clone(),
        watcher.current.wt_key.clone(),
    );
    let zone = Arc::new(Mutex::new(ArenaServer::new(watcher, spools, ladder)));
    // The stop signal, which is how every converge ends this process: file
    // each open session's departure, then go. Compose allows ten seconds
    // between the signal and the kill, and this is a lock and a few file
    // appends. SIGKILL after a hang loses exactly what it lost before this
    // existed, which is the bounded loss the spool design already accepts.
    {
        let zone = zone.clone();
        tokio::spawn(async move {
            let mut term =
                match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                    Ok(t) => t,
                    Err(_) => return,
                };
            term.recv().await;
            zone.lock().await.file_departures();
            // The WebTransport goodbye. TCP players get theirs from the
            // kernel the moment this process dies; QUIC players get only
            // what is said before it does, and an unclosed session leaves
            // them coasting in a ghost room until the browser's idle timer
            // notices, tens of seconds later.
            wt::shutdown().await;
            println!("stopped; departures are on file");
            std::process::exit(0);
        });
    }
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("bind failed");
    let tls = tls_acceptor(&cfg_tls.0, &cfg_tls.1);
    let scheme = if tls.is_some() { "wss" } else { "ws" };
    println!("vectorwake arena server listening on {scheme}://{addr}");
    // The WebTransport door, beside the WebSocket and never instead of it.
    // Environment over zone file, the way the command line wins the listen
    // address, because in the deployed fleet these are compose's business.
    let env_or = |name: &str, fallback: String| {
        std::env::var(name)
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or(fallback)
    };
    let wt_listen = env_or("VW_WT_LISTEN", cfg_wt.0);
    let wt_cert = env_or("VW_WT_CERT", cfg_wt.1);
    let wt_key = env_or("VW_WT_KEY", cfg_wt.2);
    if !wt_listen.is_empty() {
        tokio::spawn(wt::run(wt_listen.clone(), wt_cert, wt_key, zone.clone()));
    }
    // The zone name is empty here and filled in by the tick loop, which is
    // where it is actually known. See metrics::set_zone.
    metrics::spawn("arena", "");

    // Join a fleet, if one was configured. An arena server with no directory is
    // still a whole game: it serves the built-in room or its local zone file to
    // anybody who knows its address, which is the Offline state in
    // docs/architecture/zones-and-arenas.md and the reason a discovery outage is
    // not a gameplay outage.
    {
        let mut z = zone.lock().await;
        z.fleet.instance = select::Fleet::load_instance_id(&dir);
        z.fleet.region = std::env::var("VW_REGION").unwrap_or_else(|_| "local".into());
        // What a client should dial. Defaults to the listen address, which is
        // right for a single host and wrong behind NAT, so it is overridable.
        z.fleet.address =
            std::env::var("VW_ADDRESS").unwrap_or_else(|_| format!("{scheme}://{addr}"));
        // The WebTransport address rides beside it whenever that door is
        // configured. Advertised even before the certificate exists: a client
        // that cannot raise it falls back to the address above on its own, so
        // the claim costs a fallback, never a stranded player.
        //
        // The default is the listen address, and a wildcard bind is not an
        // address anybody can dial: https://0.0.0.0:9443 costs every client
        // its three seconds of patience and then the whole session's QUIC,
        // for a door that was healthy the entire time on the real interface.
        // Nobody is served by advertising it, so a wildcard says nothing and
        // says why, and VW_WT_ADDRESS is how a host names itself.
        let wildcard = wt_listen
            .rsplit_once(':')
            .is_some_and(|(host, _)| host == "0.0.0.0" || host == "[::]" || host == "::");
        if !wt_listen.is_empty() && wildcard && std::env::var("VW_WT_ADDRESS").is_err() {
            println!(
                "  webtransport listens on {wt_listen} but that is not dialable; \
                 set VW_WT_ADDRESS to the name clients should use"
            );
        } else if !wt_listen.is_empty() {
            z.fleet.wt = env_or("VW_WT_ADDRESS", format!("https://{wt_listen}"));
            println!("  webtransport advertised at {}", z.fleet.wt);
        }
        z.fleet.willing = std::env::var("VW_ZONES")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        println!(
            "instance {} in region {:?}, reachable at {}",
            z.fleet.instance, z.fleet.region, z.fleet.address
        );
        if !z.fleet.willing.is_empty() {
            println!("  willing to serve only {:?}", z.fleet.willing);
        }
    }
    // Standalone or fleet-managed, and it decides whether this process holds a
    // game at all. Standalone opens the local file's room; under a directory
    // nothing is simulated until one names a zone, so an instance waiting for
    // work costs a listener and a heartbeat rather than a room.
    //
    // Read from what was configured rather than from what resolved. A directory
    // name that fails DNS is a directory that is down, which is the ordinary
    // deploy race, and treating it as "no directory" would open the local room
    // on a fleet arena: unlisted, unregistered, and filled to bot_fill by a bot
    // server that asks each arena directly what it wants. That is the invisible
    // game this waits to avoid, reached by the other door.
    let token = std::env::var("VW_TOKEN").unwrap_or_default();
    let dir_spec = std::env::var("VW_DIRECTORY").unwrap_or_default();
    if dir_spec.trim().is_empty() || token.is_empty() {
        if dir_spec.trim().is_empty() {
            println!("no directory configured (VW_DIRECTORY); serving standalone");
        } else {
            println!("VW_DIRECTORY is set but VW_TOKEN is empty; serving standalone");
        }
        zone.lock().await.serve_local();
    } else {
        println!("no zone yet; waiting for a directory to name one");
        let zone = zone.clone();
        let token = token.clone();
        tokio::spawn(async move {
            // Resolved in here, and retried, because the lookup happens once per
            // address and a name that is a second late at boot would otherwise
            // leave this process registered nowhere for its whole life.
            loop {
                let urls = directory_urls().await;
                if !urls.is_empty() {
                    for url in urls {
                        tokio::spawn(select::register_with(url, token.clone(), zone.clone()));
                    }
                    tokio::spawn(select::decide_loop(zone));
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            }
        });
    }

    // The arena loop. One thread owns the simulation for the duration of a
    // tick; connections only ever enqueue inputs.
    {
        let zone = zone.clone();
        tokio::spawn(async move {
            let mut ticker =
                tokio::time::interval(std::time::Duration::from_micros(1_000_000 / TICK_HZ));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut buf = vec![0u8; sim::STATE_PACK_MAX];
            let mut n: u32 = 0;
            loop {
                ticker.tick().await;
                let mut z = zone.lock().await;
                n += 1;
                if n.is_multiple_of(300) {
                    z.reload();
                }
                // Offset by one so a standalone arena reads its environment on
                // the first tick. Catalog and zone commits aim immediately;
                // this slower repeat refreshes an override and is a backstop.
                if n % 3000 == 1 {
                    z.aim_spool();
                }
                // Every room, in order. The process holds one arena per room and
                // ticks them all on this thread: at 16 us for sixty-four ships
                // and 1.6 for two, a hundred two-ship rooms is a sixth of a core, so
                // there is nothing here a pool would buy.
                let (snap, combat_snap) = snapshot_lanes(n);
                // The roster, on a slow clock rather than only when it changes.
                //
                // Every name a client shows comes from that one message, and
                // `try_send` drops it without a word when a client's queue is
                // full. Sent only on join and on somebody arriving or leaving,
                // one lost roster meant a whole session with a scoreboard of ship
                // numbers and a kill feed reading "ship 5 killed ship 8".
                // Somebody watched that happen in War, and only a page refresh
                // cleared it, because nothing was ever going to send it again.
                //
                // The message is about 125 bytes, so a player taking 20 Hz
                // snapshots at 30 KB/s pays two thousandths of that for a roster
                // that repairs itself.
                let roster = n.is_multiple_of(200);
                let t0 = std::time::Instant::now();
                let mut player_count_changed = false;
                for a in z.rooms.iter_mut() {
                    player_count_changed |= a.tick();
                    if combat_snap {
                        a.broadcast_player_snapshots(&mut buf, true);
                    }
                    if snap {
                        a.broadcast_snapshot(&mut buf);
                        a.broadcast_banner();
                    }
                    if roster {
                        // Ballast follows the people. See `rebalance_bots`.
                        a.rebalance_bots();
                        a.broadcast_roster();
                        // On the same clock and for the same reason: these go
                        // out with `try_send`, which drops rather than waits,
                        // and a client that missed one would hold a team list
                        // from before somebody moved.
                        a.broadcast_teams();
                        // A live retune can be dropped by the same full queue.
                        // Repeat the current pack until it lands.
                        a.broadcast_settings();
                    }
                }
                if player_count_changed {
                    z.push_status();
                }
                let us = t0.elapsed().as_micros() as u64;
                z.tick_us = us as u32;
                // Published every tick rather than read on a scrape, so
                // whatever asks never waits on the lock this loop is holding.
                // The histogram is the part that matters: `tick_us` alone is
                // the last tick, and the last tick is sometimes the one that
                // rebuilt the roster.
                metrics::TICK.observe_us(us);
                // The zone an arena serves is chosen after it starts, and can
                // change, so it is published from here rather than captured at
                // boot.
                metrics::set_zone(&z.zone_name);
                metrics::PLAYERS.set(z.total_players() as i64);
                metrics::BOTS.set(z.total_bots() as i64);
                metrics::ROOMS.set(z.rooms.len() as i64);

                // A drain that has finished is an instance free to choose again,
                // and an empty extra room is memory to give back.
                if n.is_multiple_of(100) {
                    z.reclaim_rooms();
                    if z.draining && z.total_players() == 0 {
                        // The last player is gone, so the watchers go too: a
                        // watcher of an empty room is a socket holding a
                        // picture of a map open.
                        for a in z.rooms.iter_mut() {
                            a.drop_watchers();
                        }
                        println!("drain complete");
                        z.draining = false;
                        if let Some((want, who, _)) = z.pinned.clone() {
                            if let Some(def) =
                                z.catalog.as_ref().and_then(|c| c.zone(&want)).cloned()
                            {
                                match z.serve_zone(&def) {
                                    Ok(()) => println!("pinned to {want:?} by {who}"),
                                    Err(e) => println!("cannot serve pinned {want:?}: {e}"),
                                }
                            }
                        }
                        z.push_status();
                    }
                }
            }
        });
    }

    let pending_handshakes = Arc::new(tokio::sync::Semaphore::new(MAX_PENDING_HANDSHAKES));
    while let Ok((stream, _)) = listener.accept().await {
        let Ok(handshake_permit) = pending_handshakes.clone().try_acquire_owned() else {
            continue;
        };
        let zone = zone.clone();
        let tls = tls.clone();
        tokio::spawn(async move {
            // The TLS handshake happens before the WebSocket one, and a
            // client that fails it is simply a client that never arrives.
            let stream: Box<dyn Conn> = match &tls {
                Some(a) => match tokio::time::timeout(
                    std::time::Duration::from_secs(HANDSHAKE_DEADLINE_SECS),
                    a.accept(stream),
                )
                .await
                {
                    Ok(Ok(s)) => Box::new(s),
                    _ => return,
                },
                None => Box::new(stream),
            };
            // Incoming frames are capped far below the library default of
            // 64 MiB, which is buffered in full per frame. Nothing a client
            // legitimately sends is bigger than a join -- a tag, a few bytes,
            // a zone name and a call sign -- so a stranger on an open port
            // gets to cost this process kilobytes, not gigabytes.
            let cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
                max_message_size: Some(C2S_MAX),
                max_frame_size: Some(C2S_MAX),
                ..Default::default()
            };
            let ws = match tokio::time::timeout(
                std::time::Duration::from_secs(HANDSHAKE_DEADLINE_SECS),
                tokio_tungstenite::accept_async_with_config(stream, Some(cfg)),
            )
            .await
            {
                Ok(Ok(w)) => w,
                _ => return,
            };
            drop(handshake_permit);
            let (mut sink, mut source) = ws.split();
            let (tx, mut rx) = mpsc::channel::<Message>(OUT_QUEUE);
            let (in_tx, inbound) = mpsc::channel::<Vec<u8>>(INBOUND_QUEUE);
            // A weak sender lets the writer wake the handler on failure
            // without keeping the inbound side alive after the reader ends.
            let writer_failed = in_tx.downgrade();

            let writer = tokio::spawn(async move {
                while let Some(msg) = rx.recv().await {
                    if sink.send(msg).await.is_err() {
                        if let Some(failed) = writer_failed.upgrade() {
                            let _ = failed.send(Vec::new()).await;
                        }
                        return;
                    }
                }
                // A proper close once the channel is done, so a refused client
                // sees a closed socket rather than a dropped one and can tell
                // "you are not welcome" from "the network ate it".
                let _ = sink.close().await;
            });

            // Frames off the socket, into the shared handler, which reads whole
            // messages and has never heard of tungstenite. The pong is answered
            // here because it is the transport speaking, not the game:
            // tungstenite queues its own pong on the sink half, which this task
            // does not hold and nothing else flushes, so a ping went unanswered
            // forever. Browsers never ping, which is why it took a harness to
            // find, and why every non-browser client was dropped at its own
            // ping timeout, forty seconds in.
            let pong = tx.clone();
            let reader = tokio::spawn(async move {
                while let Some(Ok(msg)) = source.next().await {
                    match msg {
                        Message::Binary(b) => {
                            if in_tx.send(b).await.is_err() {
                                return;
                            }
                        }
                        Message::Ping(p) => {
                            let _ = pong.try_send(Message::Pong(p));
                        }
                        Message::Close(_) => return,
                        _ => {}
                    }
                }
            });

            serve_client(zone, inbound, tx.clone(), "ws").await;
            // The handler is done with this connection; the reader must not
            // keep the socket alive waiting on a peer that already went.
            reader.abort();

            // Let the writer drain before it goes. A refusal is enqueued and then
            // the read loop breaks immediately, so aborting here threw away the
            // very byte that tells a client whether to try the next instance or
            // stop trying. Dropping our sender closes the channel, the writer
            // finishes what is in it and exits; the timeout is for the case where
            // the socket is gone and the send will never complete.
            let mut writer = writer;
            drop(tx);
            if tokio::time::timeout(std::time::Duration::from_secs(2), &mut writer)
                .await
                .is_err()
            {
                writer.abort();
            }
        });
    }
}

#[cfg(test)]
mod tests {
    mod delivery;

    use super::*;

    /// The dial the directory makes to prove an arena's address, reduced to the
    /// one call that broke: building a client TLS config. With two rustls
    /// providers compiled in and none chosen, this panics, and a panic inside
    /// the spawned verification task is silent. The fleet went unlistable that
    /// way with every other test in this file passing, so the guard belongs
    /// here rather than in a comment.
    #[test]
    fn a_wss_dial_can_build_its_tls() {
        install_crypto();
        let _ = rustls::ClientConfig::builder()
            .with_root_certificates(rustls::RootCertStore::empty())
            .with_no_client_auth();
    }

    /// Reporting is on unless somebody wrote down that it is off, and the ways
    /// of writing that down are the ways an operator would reach for. Anything
    /// else is on, including nonsense: a typo in a variable meant to silence a
    /// fleet should leave the ladder recording, not quietly stop it.
    #[test]
    fn only_a_deliberate_word_turns_reporting_off() {
        for off in ["0", "off", "false", "no", "OFF", " no ", "False"] {
            assert!(!reporting_from(Some(off)), "{off} should turn it off");
        }
        for on in ["1", "on", "true", "yes", "", "maybe", "0.0"] {
            assert!(reporting_from(Some(on)), "{on} should leave it on");
        }
        assert!(reporting_from(None), "unset reports, which is the point");
    }

    fn parse(toml_src: &str) -> config::ArenaConfig {
        let z: config::ZoneConfig = toml::from_str(toml_src).expect("zone file parses");
        z.arena
    }

    /// The tables a zone file produces, which is the only thing a client
    /// ever sees of it.
    fn tuned(toml_src: &str) -> (sim::World, Vec<String>) {
        let mut w = sim::World::new(1);
        let warn = Room::apply_config(&mut w, &parse(toml_src));
        (w, warn)
    }

    /// A zone may write any flight number it likes and gets the roster's
    /// bounds back, with a line saying so.
    ///
    /// Silence would be the bad outcome here. The apply path writes the row
    /// straight into the class, so without the clamp a zone could put a hull
    /// outside the band the whole roster was balanced inside, and without the
    /// warning it would be held there with nothing to read but a stopwatch.
    #[test]
    fn a_zone_cannot_fly_a_hull_outside_the_roster_bands() {
        let (w, warn) = tuned(
            "[arena]\n\
             [[arena.ships]]\n\
             name = \"Facet\"\n\
             speed = 9000\n\
             rotation = 900\n\
             energy = 100\n\
             recharge = 50\n",
        );
        let facet = w.cfg.classes[5];
        unsafe {
            assert_eq!(facet.max_speed, sim::sim_units_speed(sim::SPEED_BAND.1));
            assert_eq!(facet.rot, sim::sim_units_rotation(sim::ROTATION_BAND.1));
            assert_eq!(facet.max_energy, sim::sim_units_energy(sim::ENERGY_BAND.0));
            assert_eq!(
                facet.recharge,
                sim::sim_units_recharge(sim::RECHARGE_BAND.0)
            );
            // The floor of each ladder is held too, or a hull could start
            // outside the band and only be inside it at the top.
            assert_eq!(facet.init_speed, sim::sim_units_speed(sim::SPEED_BAND.1));
            assert_eq!(facet.init_energy, sim::sim_units_energy(sim::ENERGY_BAND.0));
        }
        assert_eq!(
            warn.len(),
            4,
            "every number that moved is reported: {warn:?}"
        );
        assert!(warn.iter().all(|w| w.starts_with("Facet: ")), "{warn:?}");

        // Thrust has no band, so an absurd one is the operator's business.
        let (hot, warn) = tuned(
            "[arena]\n\
             [[arena.ships]]\n\
             name = \"Facet\"\n\
             thrust = 900\n",
        );
        assert!(warn.is_empty(), "{warn:?}");
        unsafe {
            assert_eq!(hot.cfg.classes[5].thrust, sim::sim_units_thrust(900));
        }

        // And a number inside the band passes through untouched and unremarked.
        let (fine, warn) = tuned(
            "[arena]\n\
             [[arena.ships]]\n\
             name = \"Facet\"\n\
             speed = 3000\n",
        );
        assert!(warn.is_empty(), "{warn:?}");
        unsafe {
            assert_eq!(fine.cfg.classes[5].max_speed, sim::sim_units_speed(3000));
        }
    }

    /// The wormhole keys a zone can reach, read back off the core in the
    /// units the core keeps them in.
    ///
    /// `gravity_bombs` defaults on, so the test that matters is that a zone
    /// can turn it off: a boolean whose only reachable value is its default
    /// is not a setting.
    #[test]
    fn a_zone_shapes_its_own_wormholes() {
        let (base, warn) = tuned("[arena]\n");
        assert!(warn.is_empty());
        assert_eq!(
            base.cfg.gravity_bombs, 1,
            "bombs bend unless a zone says not"
        );
        assert_eq!(base.cfg.wormhole_range, 38 * 16 * 256, "38 tiles of reach");
        assert!(
            base.cfg.wormhole_top_speed > 0,
            "the ceiling lifts by default"
        );

        let (w, warn) = tuned(
            "[arena]\n\
             wormhole_pull = 2000\n\
             wormhole_range = 40\n\
             wormhole_top_speed = 250\n\
             gravity_bombs = false\n",
        );
        assert!(warn.is_empty(), "{warn:?}");
        unsafe {
            assert_eq!(w.cfg.wormhole_pull, sim::sim_units_speed(2000));
            assert_eq!(w.cfg.wormhole_top_speed, sim::sim_units_speed(250));
        }
        assert_eq!(w.cfg.wormhole_range, 40 * 256, "px in, px in the core");
        assert_eq!(w.cfg.gravity_bombs, 0, "a zone can ground its bombs");

        // Zero is no extra speed rather than a missing setting, which is the
        // whole reason the lift adds to the ceiling instead of replacing it.
        let (flat, warn) = tuned("[arena]\nwormhole_top_speed = 0\n");
        assert!(warn.is_empty());
        assert_eq!(flat.cfg.wormhole_top_speed, 0);
    }

    fn gun(w: &sim::World, cls: usize) -> (sim::sim_fire_pattern, sim::sim_weapon_spec) {
        let p = w.cfg.patterns[w.cfg.classes[cls].trigger[0][0] as usize];
        (p, w.cfg.specs[p.spec as usize])
    }

    #[test]
    fn presence_accepts_only_the_lifecycle_transition_table() {
        let (flying, joined) = Presence::Unjoined
            .transition(PresenceEvent::JoinFlying { room: 2, member: 7 })
            .expect("an unjoined connection may fly");
        assert_eq!(flying, Presence::Flying { room: 2, member: 7 });
        assert!(joined.player_count_changed);
        assert!(!joined.release_rated_lease);

        let (watching, sat_out) = flying
            .transition(PresenceEvent::SitOut {
                room: 2,
                member: 7,
                reason: SitOutWhy::Safe,
            })
            .expect("a flying connection may sit out");
        assert_eq!(watching, Presence::Watching { room: 2, member: 7 });
        assert!(sat_out.player_count_changed);
        assert!(sat_out.release_rated_lease);

        let (renumbered, renamed) = watching
            .transition(PresenceEvent::Renumber {
                from: 2,
                to: 4,
                member: 7,
            })
            .expect("a live room may be renumbered");
        assert_eq!(renumbered, Presence::Watching { room: 4, member: 7 });
        assert_eq!(renamed, PresenceEffects::default());

        let (flying_again, resumed) = renumbered
            .transition(PresenceEvent::Resume { room: 4, member: 7 })
            .expect("a watcher may resume");
        assert_eq!(flying_again, Presence::Flying { room: 4, member: 7 });
        assert!(resumed.player_count_changed);

        let (gone, disconnected) = flying_again
            .transition(PresenceEvent::Disconnect { room: 4, member: 7 })
            .expect("a flying connection may leave");
        assert_eq!(gone, Presence::Unjoined);
        assert!(disconnected.player_count_changed);
        assert!(disconnected.release_rated_lease);
        assert!(disconnected.connection_closed);

        assert!(Presence::Unjoined
            .transition(PresenceEvent::Resume { room: 4, member: 7 })
            .is_err());
        assert!(watching
            .transition(PresenceEvent::SitOut {
                room: 2,
                member: 7,
                reason: SitOutWhy::Asked,
            })
            .is_err());
        assert!(flying
            .transition(PresenceEvent::Disconnect { room: 2, member: 8 })
            .is_err());

        let (arrived_watching, effects) = Presence::Unjoined
            .transition(PresenceEvent::JoinWatching { room: 9, member: 3 })
            .expect("an unjoined connection may arrive watching");
        assert_eq!(arrived_watching, Presence::Watching { room: 9, member: 3 });
        assert_eq!(effects, PresenceEffects::default());
        let (gone, disconnected) = arrived_watching
            .transition(PresenceEvent::Disconnect { room: 9, member: 3 })
            .expect("a watcher may leave");
        assert_eq!(gone, Presence::Unjoined);
        assert!(!disconnected.player_count_changed);
        assert!(disconnected.release_rated_lease);
        assert!(disconnected.connection_closed);
    }

    /// A loose ratings file cannot bypass the compiled report gate. The seed
    /// still has to reach rooms opened after startup, so the second room proves
    /// both parts of the contract.
    #[test]
    fn an_unverified_local_ladder_cannot_seed_a_later_room() {
        let dir = std::env::temp_dir().join("vw-ladder-test");
        std::fs::create_dir_all(&dir).expect("temp dir");
        std::fs::write(dir.join("ladder.json"), r#"{"Kestrel": 1777.5}"#).expect("write");
        let ladder = load_ladder(dir.to_str().unwrap());
        assert_eq!(ladder.get("Kestrel"), None, "a point seed is not proof");
        assert_eq!(ladder.get(ai::ANCHOR), Some(&ai::ANCHOR_RATING));

        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), ladder);
        let def = wire_zone(4, 2, 8);
        z.catalog = Some(fleet::WireCatalog {
            version: 1,
            name: "test".into(),
            default_zone: "testzone".into(),
            zones: vec![def.clone()],
            ..Default::default()
        });
        z.serve_zone(&def).expect("a room");
        let room = z.open_room().expect("a second room");
        let seeded = z.rooms[room]
            .rating
            .score
            .get(ai::ANCHOR)
            .copied()
            .unwrap_or_default();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(
            seeded,
            ai::ANCHOR_RATING,
            "the later room did not receive the process's verified seed"
        );
    }

    /// A catalog this build cannot read is refused at the door, not held.
    ///
    /// The day the spectating change removed `channel_delay_ticks` without
    /// bumping the catalog version, arenas restarting into the deploy caught
    /// the outgoing directory's offer first, held zone text their own parser
    /// refused, and then defended it against the converged directory's
    /// re-offer under the same number. Both instances sat announced with no
    /// rooms and no bots until restarted. Refusing the unreadable offer means
    /// holding nothing, and holding nothing means the readable one that
    /// follows is simply taken, same version or not.
    #[test]
    fn an_unreadable_catalog_cannot_pin_its_version() {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());

        let mut stale = wire_zone(1, 2, 8);
        stale.zone_toml = "label = \"a zone for tests\"\nchannel_delay_ticks = 500\n".into();
        z.take_catalog(
            fleet::WireCatalog {
                version: 23,
                name: "test".into(),
                default_zone: "testzone".into(),
                zones: vec![stale],
                ..Default::default()
            },
            "wss://outgoing",
        );
        assert!(z.catalog.is_none(), "the unreadable offer was held");

        z.take_catalog(
            fleet::WireCatalog {
                version: 23,
                name: "test".into(),
                default_zone: "testzone".into(),
                zones: vec![wire_zone(1, 2, 8)],
                ..Default::default()
            },
            "wss://converged",
        );
        let def = z
            .catalog
            .as_ref()
            .expect("the readable offer under the same number is taken")
            .zones[0]
            .clone();
        z.serve_zone(&def).expect("and it serves");
    }

    // ---- rooms on demand ---------------------------------------------------
    //
    // The fill ladder's first two rungs live entirely inside one process, so
    // they are testable without a directory, a socket, or a second binary.

    /// A zone as a catalog would deliver it, with a real packed map so
    /// `build_room` takes the same path it takes in production.
    fn wire_zone(rooms: u32, target: u32, cap: u32) -> fleet::WireZone {
        fleet::WireZone {
            name: "testzone".into(),
            mode: "arena".into(),
            max_ships: 64,
            max_players: cap,
            fill_target: target,
            max_rooms: rooms,
            admission: "any".into(),
            bot_fill: 0.0,
            maps_b64: vec![fleet::b64(&sim::World::new(1).packed_map())],
            map_names: vec!["proving".into()],
            // A zone's name lives in the catalog that references it, never in the
            // zone's own file, so there is one place a name can be.
            zone_toml: "label = \"a zone for tests\"\n".into(),
        }
    }

    // ---- identity ----------------------------------------------------------

    /// A fixed key for both halves of the exchange, so a failure here is a
    /// failure rather than a coin flip.
    fn meta_key() -> ed25519_dalek::SigningKey {
        ed25519_dalek::SigningKey::from_bytes(&[3u8; 32])
    }

    /// A zone whose catalog carries the meta-layer's verifying key, which is
    /// the whole of what an arena needs to know who anybody is.
    fn serving_with_accounts() -> ArenaServer {
        let mut z = serving(1, 6, 16);
        if let Some(c) = z.catalog.as_mut() {
            c.meta_key = token::to_hex(meta_key().verifying_key().as_bytes());
        }
        z
    }

    fn a_token(
        kind: token::Kind,
        claimed: bool,
        name: &str,
        ratings: Vec<token::ClassRating>,
    ) -> String {
        a_token_for(4242, kind, claimed, name, ratings)
    }

    fn a_token_for(
        account: u64,
        kind: token::Kind,
        claimed: bool,
        name: &str,
        ratings: Vec<token::ClassRating>,
    ) -> String {
        token::mint(
            &meta_key(),
            &token::Claims {
                account,
                kind,
                claimed,
                name: name.into(),
                expires: token::now_secs() + 600,
                ratings,
            },
        )
    }

    #[test]
    fn a_signed_token_names_the_pilot_and_their_account() {
        let z = serving_with_accounts();
        let t = a_token(token::Kind::Human, true, "Vesper 47", vec![]);
        let seat = z
            .identify(
                &t,
                "whatever the client typed",
                false,
                &pilot::Session::new("ws"),
            )
            .expect("verifies");
        // The name comes from the token, not from the client. A pilot cannot
        // wear somebody else's call sign by asking to.
        assert_eq!(seat.name, "Vesper 47");
        assert_eq!(seat.account, Some(4242));
        assert_eq!(seat.rid, "a4242");
        assert_eq!(seat.label, token::Label::Human.to_byte());
    }

    #[test]
    fn a_guest_is_unknown_rather_than_human() {
        let z = serving_with_accounts();
        let t = a_token(token::Kind::Human, false, "Talon 3", vec![]);
        let seat = z
            .identify(&t, "", false, &pilot::Session::new("ws"))
            .expect("verifies");
        assert_eq!(
            seat.label,
            token::Label::Unknown.to_byte(),
            "an unclaimed account is somebody we cannot vouch for"
        );
        assert_eq!(
            seat.account,
            Some(4242),
            "which does not make them anonymous"
        );
    }

    #[test]
    fn a_house_bot_and_a_third_party_bot_are_told_apart() {
        let z = serving_with_accounts();
        let house = z
            .identify(
                &a_token(token::Kind::HouseBot, true, "Nine", vec![]),
                "",
                true,
                &pilot::Session::new("ws"),
            )
            .expect("verifies");
        assert_eq!(house.label, token::Label::HouseBot.to_byte());
        let theirs = z
            .identify(
                &a_token(token::Kind::ThirdPartyBot, true, "Someone", vec![]),
                "",
                true,
                &pilot::Session::new("ws"),
            )
            .expect("verifies");
        assert_eq!(theirs.label, token::Label::ThirdPartyBot.to_byte());
        // And a bot flying with no account at all is somebody else's by
        // definition, since ours all have one.
        let undeclared = z
            .identify("", "Anon", true, &pilot::Session::new("ws"))
            .expect("no token is still a seat");
        assert_eq!(undeclared.label, token::Label::ThirdPartyBot.to_byte());
        assert_eq!(undeclared.account, None);
    }

    #[test]
    fn a_declaration_that_disagrees_with_the_account_is_refused() {
        let z = serving_with_accounts();
        // A bot account that stayed quiet would sit in a human seat wearing a
        // human's label, which is the one thing the declaration exists to stop.
        let quiet_bot = a_token(token::Kind::HouseBot, true, "Nine", vec![]);
        assert!(z
            .identify(&quiet_bot, "", false, &pilot::Session::new("ws"))
            .is_err());
        // And a human account claiming the bot exemption takes a seat that the
        // cap was supposed to protect.
        let loud_human = a_token(token::Kind::Human, true, "Vesper 47", vec![]);
        assert!(z
            .identify(&loud_human, "", true, &pilot::Session::new("ws"))
            .is_err());
    }

    #[test]
    fn a_forged_or_expired_token_does_not_get_in() {
        let z = serving_with_accounts();
        let other = ed25519_dalek::SigningKey::from_bytes(&[9u8; 32]);
        let forged = token::mint(
            &other,
            &token::Claims {
                account: 1,
                kind: token::Kind::Human,
                claimed: true,
                name: "Impostor".into(),
                expires: token::now_secs() + 600,
                ratings: vec![],
            },
        );
        assert!(
            z.identify(&forged, "", false, &pilot::Session::new("ws"))
                .is_err(),
            "another key is not our key"
        );

        let stale = token::mint(
            &meta_key(),
            &token::Claims {
                account: 1,
                kind: token::Kind::Human,
                claimed: true,
                name: "Yesterday".into(),
                expires: token::now_secs() - 1,
                ratings: vec![],
            },
        );
        let why = z
            .identify(&stale, "", false, &pilot::Session::new("ws"))
            .expect_err("expired");
        assert!(
            why.contains("log in again"),
            "an expired token is a login, not an accusation"
        );
    }

    #[test]
    fn without_a_meta_layer_everybody_flies_as_a_guest() {
        // The supported no-accounts arrangement, and also what an outage looks
        // like from inside a room: play continues, nothing durable is written.
        let z = serving(1, 6, 16);
        let t = a_token(token::Kind::Human, true, "Vesper 47", vec![]);
        let seat = z
            .identify(&t, "Local Name", false, &pilot::Session::new("ws"))
            .expect("a seat regardless");
        assert_eq!(
            seat.account, None,
            "no key in the catalog, so no token is read"
        );
        assert_eq!(seat.name, "Local Name");
        assert_eq!(seat.label, token::Label::Unknown.to_byte());
    }

    #[test]
    fn a_carried_rating_seeds_the_room_and_a_new_class_does_not() {
        let mut z = serving_with_accounts();
        let t = a_token(
            token::Kind::Human,
            true,
            "Veteran",
            vec![
                token::ClassRating {
                    class: "testzone".into(),
                    rating: 1640.0,
                    games: 40,
                },
                token::ClassRating {
                    class: "hockey".into(),
                    rating: 1000.0,
                    games: 5,
                },
            ],
        );
        let seat = z
            .identify(&t, "", false, &pilot::Session::new("ws"))
            .expect("verifies");
        let rid = seat.rid.clone();
        z.restore_pilot(0, &seat);
        // The zone's own name is the class it rates into.
        assert_eq!(z.rating_class(), "testzone");
        assert_eq!(z.rooms[0].rating.rating_of(&rid), 1640.0);
        assert_eq!(
            z.rooms[0].rating.games_of(&rid),
            40,
            "a rating without its count places again"
        );
        z.rooms[0].rating.score.insert(rid.clone(), 1668.0);
        z.rooms[0].rating.games.insert(rid.clone(), 41);
        z.restore_pilot(0, &seat);
        assert_eq!(
            z.rooms[0].rating.rating_of(&rid),
            1668.0,
            "an older token is not a checkpoint over live room movement"
        );
        assert_eq!(z.rooms[0].rating.games_of(&rid), 41);

        // A pilot who has never played this zone's class arrives unrated,
        // which is what a first game in a new class is supposed to be.
        let fresh = a_token_for(
            99,
            token::Kind::Human,
            true,
            "Newcomer",
            vec![token::ClassRating {
                class: "hockey".into(),
                rating: 1900.0,
                games: 99,
            }],
        );
        let fresh = z
            .identify(&fresh, "", false, &pilot::Session::new("ws"))
            .expect("verifies");
        z.restore_pilot(0, &fresh);
        assert_eq!(z.rooms[0].rating.games_of(&fresh.rid), 0);
    }

    /// A spool aimed nowhere, which is what a room that is not handing off
    /// anywhere holds. Writes nothing, because it is not armed.
    fn test_spool() -> spool::Spools {
        spool::Spools::open("/nonexistent")
    }

    /// A zone process already serving that definition. No config file and no
    /// store file: both read defaults when the path is absent, which is what a
    /// catalog-served arena runs on anyway.
    fn serving(rooms: u32, target: u32, cap: u32) -> ArenaServer {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        let def = wire_zone(rooms, target, cap);
        z.catalog = Some(fleet::WireCatalog {
            version: 1,
            name: "test".into(),
            default_zone: "testzone".into(),
            zones: vec![def.clone()],
            ..Default::default()
        });
        z.serve_zone(&def).expect("the definition builds a room");
        z
    }

    /// The numbers this instance's rooms are wearing, in list order, which is
    /// the order they opened in and not the order they are named in.
    fn numbers(z: &ArenaServer) -> Vec<u32> {
        z.rooms.iter().map(|r| r.number).collect()
    }

    /// Seat `n` players in a room without a socket on the other end. A dropped
    /// receiver is fine: every send is `let _ =`, because a client that has gone
    /// away must not take the tick loop with it.
    fn seat(z: &mut ArenaServer, room: usize, n: usize) {
        let cap = z.max_players();
        for i in 0..n {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[room]
                .join(Seat::guest(format!("p{room}-{i}"), false), 0, cap, tx)
                .expect("a seat below the cap");
        }
    }

    /// The same, for bots, and it is the same call: a bot joins through the
    /// front door now, so a test that wants a populated room does what the bot
    /// server does rather than reaching into the arena to plant one.
    ///
    /// Returns the ship each took, since a bot's seat is chosen by the arena.
    fn seat_bots(a: &mut Room, n: usize) -> Vec<u8> {
        let mut out = Vec::new();
        for i in 0..n {
            let (tx, rx) = mpsc::channel(OUT_QUEUE);
            // Held, because a bot that is evicted is sent a yield and a closed
            // receiver would make that send fail silently in a test that is
            // about to check it happened.
            std::mem::forget(rx);
            let e = ai::individual(i);
            let id = a
                .join(Seat::guest(e.name.clone(), true), e.class, 0, tx)
                .expect("a seat for a bot");
            out.push(a.players[&id].ship);
        }
        out
    }

    // ---- bots as clients ---------------------------------------------------

    #[test]
    fn sparse_bot_heartbeats_do_not_feed_human_input_telemetry() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let ship = seat_bots(&mut a, 1)[0];
        let id = *a
            .players
            .iter()
            .find(|(_, p)| p.ship == ship)
            .map(|(id, _)| id)
            .expect("the bot remains seated");

        for elapsed in 0..60 {
            if elapsed % 50 == 0 {
                let now = a.world.state.tick.wrapping_add(1);
                a.players
                    .get_mut(&id)
                    .expect("the bot remains seated")
                    .schedule(now, 0, now);
            }
            a.tick();
        }

        let lag = &a.players[&id].lag;
        assert_eq!(lag.input_miss.sampled_ticks(), 0);
        assert_eq!(lag.input_miss.percent(), 0);
    }

    #[test]
    fn a_bot_does_not_use_up_a_human_seat() {
        // The declaration's whole point. `max_players` bounds people, and a zone
        // that holds a wide room mostly full of AI has to keep admitting every
        // human its operator allowed: an arena that counted bots against the cap
        // would refuse the second player to a room with sixty-two free seats.
        let mut z = serving(1, 4, 4);
        seat_bots(&mut z.rooms[0], 20);
        assert_eq!(z.rooms[0].humans(), 0, "twenty bots are nobody");
        assert_eq!(z.rooms[0].bot_count(), 20);

        for i in 0..4 {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            assert!(
                z.rooms[0]
                    .join(Seat::guest(format!("h{i}"), false), 0, 4, tx)
                    .is_some(),
                "human {i} was refused a seat a bot was not holding"
            );
        }
        // And the cap is still a cap.
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        assert!(z.rooms[0]
            .join(Seat::guest("overflow", false), 0, 4, tx)
            .is_none());
    }

    #[test]
    fn a_room_full_of_bots_still_has_room_for_a_person() {
        // The backstop under the bot server's headroom. It leaves a fifth of the
        // room empty so this never fires, and a burst of joins between two
        // browses can outrun that: the arena has to make its own space rather
        // than tell a player that a room full of AI is full.
        let mut z = serving(1, 4, 32);
        let seats = z.rooms[0].world.cfg.max_ships as usize;
        let seated = seat_bots(&mut z.rooms[0], seats);
        assert_eq!(seated.len(), seats, "every seat taken by a bot");

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0]
            .join(Seat::guest("latecomer", false), 0, 32, tx)
            .expect("a room of bots is not full");
        assert_eq!(z.rooms[0].humans(), 1);
        assert_eq!(
            z.rooms[0].bot_count(),
            seats - 1,
            "exactly one bot gave way"
        );
        // Everybody here spawned on top of everybody else, so every bot is in
        // somebody's sight and the ordering falls through to its tie-break,
        // which is still the newest. Which bot is chosen when they are not all
        // alike is `the_seat_taken_back_is_the_one_nobody_is_looking_at`.
        assert_eq!(
            z.rooms[0].players[&id].ship,
            *seated.last().unwrap(),
            "the seat taken is the newest bot's"
        );
    }

    #[test]
    fn the_seat_taken_back_is_the_one_nobody_is_looking_at() {
        // The arena's half of yielding is the half under time pressure: a
        // person is at the door and the seat has to exist this tick, so there
        // is no walking out the way the bot server's half does. What it can do
        // is choose well, and it holds the whole simulation, so it knows which
        // bots are dead and which have nobody near them.
        //
        // It used to take the newest, as a proxy for "least invested". That is
        // not the question. The newest bot is as likely as any other to be the
        // one currently trading shots with somebody, and vanishing out of that
        // is the pop this ordering exists to avoid.
        let mut z = serving(1, 4, 32);
        let seats = z.rooms[0].world.cfg.max_ships as usize;
        let seated = seat_bots(&mut z.rooms[0], seats);

        // One bot sent to the far corner of the map, alone. It is not the
        // newest, so newest-first cannot pick it by luck.
        let lonely = seated[seats / 2];
        {
            let s = &mut z.rooms[0].world.state.ships[lonely as usize];
            s.x = 60 * 16 * 256;
            s.y = 60 * 16 * 256;
        }

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0]
            .join(Seat::guest("latecomer", false), 0, 32, tx)
            .expect("a room of bots is not full");
        assert_eq!(
            z.rooms[0].players[&id].ship, lonely,
            "took a seat from the crowd while one stood alone"
        );

        // And a dead bot is cheaper still: it is between fights by definition,
        // and nobody is watching a wreck.
        let dead = seated[1];
        z.rooms[0].world.state.ships[dead as usize].alive = 0;
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0]
            .join(Seat::guest("another", false), 0, 32, tx)
            .expect("still not full");
        assert_eq!(
            z.rooms[0].players[&id].ship, dead,
            "took a live bot's seat with a dead one sitting there"
        );
    }

    #[test]
    fn a_seat_taken_back_from_a_bot_is_a_seat_somebody_is_sitting_in() {
        // Handing a seat over is `leave` followed by the rest of `join`, not a
        // spawn, and `leave` is what empties a seat. So an inherited one
        // arrived inactive: the core skips an inactive ship, and `sim_spawn`
        // hands the first one it finds to whoever arrives next. Two people in
        // one chair, neither of them being simulated, and nothing anywhere
        // saying so: the roster is built from `players` and reads perfectly.
        let mut z = serving(1, 4, 32);
        let seats = z.rooms[0].world.cfg.max_ships as usize;
        seat_bots(&mut z.rooms[0], seats);

        let mut taken = Vec::new();
        for who in ["first", "second"] {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            let id = z.rooms[0]
                .join(Seat::guest(who, false), 0, 32, tx)
                .expect("a room of bots is not full");
            let ship = z.rooms[0].players[&id].ship;
            assert_eq!(
                z.rooms[0].world.state.ships[ship as usize].active, 1,
                "{who} joined into a seat the simulation thinks is empty"
            );
            taken.push(ship);
        }
        assert_ne!(taken[0], taken[1], "two pilots handed the same seat");
    }

    /// Two spare instances on the live fleet each ran a full room of a zone no
    /// listing carried, for a night, at a quarter of a one-core box between
    /// them. The room came from the local file at boot, the bot server asks an
    /// arena directly what it wants rather than reading the catalog, and an
    /// arena with a room wants bots. Take the room away and the rest follows.
    #[test]
    fn an_arena_with_no_zone_is_not_a_game() {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        assert!(
            z.rooms.is_empty(),
            "a process nobody has named a zone to holds no room"
        );
        assert_eq!(z.bots_wanted(), 0, "and so asks the bot server for nobody");
        assert_eq!(z.room_for_bot(), None);
        assert_eq!(
            z.room_for_join(),
            None,
            "and has nowhere to seat an arrival"
        );
        assert_eq!(z.room_to_watch(), None, "nor anything to show a watcher");

        // Told what it is, it becomes a game.
        let def = wire_zone(1, 4, 32);
        z.serve_zone(&def).expect("the definition builds a room");
        assert_eq!(z.rooms.len(), 1);
        assert!(z.bots_wanted() > 0, "a room that exists is a room to fill");
    }

    /// The exception, and the reason the room was built at boot in the first
    /// place: with no directory to name a zone, the local file is the whole
    /// deployment and its room is the game.
    #[test]
    fn a_standalone_arena_serves_the_file_beside_it() {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_local();
        assert_eq!(z.rooms.len(), 1, "standalone opens the file's room");
        assert!(
            z.zone_name.is_empty(),
            "and takes no name, having chosen nothing"
        );
    }

    #[test]
    fn bots_yield_one_for_one_and_never_below_zero() {
        // What a player actually sees: a room held at four fifths, and their
        // arrival costing the room one bot rather than emptying it or changing
        // nothing. 64 seats at 0.8 is 51, so one human means 50 bots wanted.
        let mut z = serving(1, 4, 32);
        z.rooms[0].bot_fill = 0.8;
        assert_eq!(z.rooms[0].bot_target(), 51);
        assert_eq!(z.rooms[0].bots_wanted(), 51);

        for i in 0..3 {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[0]
                .join(Seat::guest(format!("h{i}"), false), 0, 32, tx)
                .expect("a seat");
            assert_eq!(
                z.rooms[0].bots_wanted(),
                51 - (i + 1),
                "one human in is one bot out"
            );
        }

        // Past the target the answer is zero rather than a negative number
        // wrapping into an enormous one, which is what `saturating_sub` is for.
        for i in 3..32 {
            let (tx, _rx) = mpsc::channel(OUT_QUEUE);
            z.rooms[0]
                .join(Seat::guest(format!("h{i}"), false), 0, 32, tx)
                .expect("a seat");
        }
        assert_eq!(z.rooms[0].humans(), 32);
        assert_eq!(z.rooms[0].bots_wanted(), 19);

        // A zone that wants no bots says so, and is believed.
        z.rooms[0].bot_fill = 0.0;
        assert_eq!(z.rooms[0].bots_wanted(), 0);
    }

    #[test]
    fn bots_do_not_hold_a_room_open_against_the_fill_ladder() {
        // Every count that decides anything is a count of people. A room the bot
        // server holds at four fifths would otherwise read as permanently at
        // target, so the zone would open its second room for its second player
        // and scatter the population the ladder exists to concentrate.
        let mut z = serving(2, 4, 16);
        seat_bots(&mut z.rooms[0], 30);
        assert_eq!(z.room_for_join(), Some(0), "a room of bots wants people");
        assert_eq!(z.rooms.len(), 1, "and did not grow a sibling to hold them");
        assert!(!z.status().capped, "nor does it report itself out of room");

        seat(&mut z, 0, 4);
        assert_eq!(z.room_for_join(), Some(1), "four people is the target");
    }

    #[test]
    fn draining_sends_the_bots_home() {
        // Bots would otherwise hold a draining instance at four fifths for ever:
        // `total_players` never reaches zero, the drain never completes, and the
        // instance never gets to choose another zone. Two things stop that, and
        // this is the fast one; the other is publishing a want of zero so the
        // bot server does not put back what this let go.
        let mut z = serving(1, 4, 16);
        seat_bots(&mut z.rooms[0], 12);
        seat(&mut z, 0, 2);
        assert_eq!(z.bots_wanted(), z.rooms[0].bot_target() - 2);

        let gone = z.begin_drain();
        assert_eq!(gone, 12, "every bot was told");
        assert_eq!(z.total_bots(), 0);
        assert_eq!(z.bots_wanted(), 0, "and none are asked for while draining");
        assert_eq!(z.total_players(), 2, "the people are left alone");
        assert_eq!(z.room_for_bot(), None, "a draining room takes no bots");
    }

    #[test]
    fn a_bot_goes_to_the_room_that_is_shortest_of_them() {
        // The other half of "a bot is not a player". An arrival goes to the
        // fullest room, which concentrates people; a bot going there would stack
        // the whole population into room one and leave a room opened for players
        // with nobody in it to fight.
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        z.room_for_join().expect("a second room opens");
        assert_eq!(z.rooms.len(), 2);

        seat_bots(&mut z.rooms[0], 40);
        assert_eq!(z.room_for_bot(), Some(1), "the empty room is the short one");

        // And a bot never opens a room of its own: rooms exist because people
        // arrived. Fill both to target and the answer is nobody wants one.
        let target = z.rooms[0].bot_target();
        seat_bots(&mut z.rooms[1], target);
        seat_bots(&mut z.rooms[0], target - 40);
        assert_eq!(z.room_for_bot(), None);
        assert_eq!(z.rooms.len(), 2, "and no third room was built to hold bots");
    }

    #[test]
    fn a_declared_bot_is_labeled_and_rated_as_one() {
        // Players deserve to know who they are fighting, and a rating system
        // that quietly mixes bots into your record is one nobody will trust.
        // Both come from what the client declared rather than from a roster the
        // arena holds a copy of, because the bot server draws from a much longer
        // list than the nine the tournament calibrated.
        let mut z = serving(1, 4, 16);
        let ship = seat_bots(&mut z.rooms[0], 1)[0];
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        z.rooms[0]
            .join(Seat::guest("Person", false), 0, 16, tx)
            .expect("a seat");

        let a = &z.rooms[0];
        assert!(a.names[&ship].bot, "the bot says so on the scoreboard");
        let human = a.names.iter().find(|(_, k)| k.name == "Person").unwrap();
        assert!(!human.1.bot);
        // A generated pilot is as much a bot as a calibrated one.
        let generated = ai::individual(ai::CALIBRATED.len());
        assert!(!ai::CALIBRATED.iter().any(|(n, _, _)| *n == generated.name));
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        z.rooms[0]
            .join(Seat::guest(generated.name.clone(), true), 0, 16, tx)
            .expect("a seat");
        // Marked, which is what holds its K down so a human who kills it moves
        // further than it does.
        assert!(
            z.rooms[0].rating.is_bot(&generated.name),
            "{} rates as a human",
            generated.name
        );
        assert!(!z.rooms[0].rating.is_bot("Person"));
    }

    #[test]
    fn every_individual_the_bot_server_can_fly_is_its_own_pilot() {
        // One individual, one place, which is what makes a bot's rating the
        // record of one career rather than an average over clones. The bot
        // server allocates names from this list and a repeat would put two
        // pilots on one row.
        let mut seen = std::collections::HashSet::new();
        for n in 0..300 {
            let e = ai::individual(n);
            assert!(seen.insert(e.name.clone()), "individual {n} repeats a name");
            assert!(
                (e.class as usize) < sim::MAX_CLASSES,
                "{} flies a hull that does not exist",
                e.name
            );
            assert!(e.skill > 0.0 && e.skill <= 1.0, "{} has no skill", e.name);
            assert_eq!(
                e.name,
                sanitize_name(&e.name),
                "{} needs sanitising",
                e.name
            );
        }
        // The calibrated pilots come first, because they are the pilots whose
        // ratings mean anything.
        for (i, (name, _, _)) in ai::CALIBRATED.iter().enumerate() {
            assert_eq!(&ai::individual(i).name, name);
        }
    }

    #[test]
    fn a_flag_is_somewhere_a_pilot_will_find_it() {
        // The flag game ran for four minutes on the live server with forty-two
        // kills and not one flag touched, because the flags were two hundred
        // tiles from every spawn and a pilot sees sixty. A flag nobody can reach
        // is a round nobody can win, and neither end of that says so: the arena
        // is healthy, the fighting works, the banner just never moves.
        // Measured against the middle of the map rather than against any one
        // map's spawns: the two shipped zones start their pilots in a 68-tile box
        // there, and a pilot with nothing in sight roams to the same place, so
        // "on the radar from the middle" is the property that makes a flag
        // findable however the map places its starts.
        let mut z = serving(1, 6, 16);
        let a = &mut z.rooms[0];
        a.add_default_flags();
        assert!(a.world.state.flag_count > 0, "flags were placed");
        let (mid, _) = a.world.map.mid();

        let mut spacing = f32::MAX;
        for i in 0..a.world.state.flag_count as usize {
            let f = a.world.state.flags[i];
            let (fx, fy) = (f.x as f32 / 256.0, f.y as f32 / 256.0);
            let d = ((fx - mid).powi(2) + (fy - mid).powi(2)).sqrt();
            assert!(
                d <= ai::SIGHT,
                "flag {i} is {d:.0} px from the middle, and a pilot sees {}",
                ai::SIGHT
            );
            for k in 0..i {
                let g = a.world.state.flags[k];
                let (gx, gy) = (g.x as f32 / 256.0, g.y as f32 / 256.0);
                spacing = spacing.min(((fx - gx).powi(2) + (fy - gy).powi(2)).sqrt());
            }
        }
        // And not a scrum: neighbours far enough apart that one pilot cannot sit
        // on the whole set. They were four tiles apart once, which was one fight
        // in one room and the reason they were flung to the corners.
        assert!(
            spacing >= 40.0 * 16.0,
            "flags are {spacing:.0} px apart, which one pilot covers at once"
        );
    }

    #[test]
    fn a_free_for_all_has_enemies_in_it() {
        // Chaos ran for a day with nothing able to hit anything. `teams = 1` put
        // every pilot on side zero, and every hostility test in the stack is
        // whether two sides differ: no weapon could reach a ship, no kill paid,
        // and no bot could see a target, so nine of them sat still while a
        // player flew around an arena that could not fight back.
        let mut z = serving(1, 6, 16);
        assert!(z.rooms[0].free_for_all(), "the fixture is a one-team zone");
        let seats = seat_bots(&mut z.rooms[0], 4);

        let a = &z.rooms[0];
        let mut sides = std::collections::HashSet::new();
        let mut ships = 0;
        for (i, s) in a.world.state.ships.iter().enumerate() {
            if s.active == 0 {
                continue;
            }
            ships += 1;
            assert!(sides.insert(s.team), "ship {i} shares a side with somebody");
            assert_ne!(s.team, sim::TEAM_NONE, "a pilot is never nobody's side");
        }
        assert!(ships >= 2, "a roster to fight over");

        // And the bots' own perception, which is where the symptom was: a
        // pilot with a teammate in front of them sees nobody, plans nothing,
        // and holds still. Put two together rather than trusting the map's
        // starts, so this measures the rule and not the geometry.
        let (a, b) = (seats[0], seats[1]);
        let room = &mut z.rooms[0];
        room.world.state.ships[b as usize].x = room.world.state.ships[a as usize].x + 40 * 256;
        room.world.state.ships[b as usize].y = room.world.state.ships[a as usize].y;
        assert!(ai::scan(&room.world, a).foe.is_some(), "nobody to fight");
        assert!(ai::scan(&room.world, b).foe.is_some(), "and not one-sided");

        // And a joining human is their own side too, not folded in with the
        // pilot whose seat they took.
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0]
            .join(Seat::guest("human", false), 0, 16, tx)
            .expect("a seat");
        let ship = z.rooms[0].players[&id].ship;
        let mine = z.rooms[0].world.state.ships[ship as usize].team;
        for (i, s) in z.rooms[0].world.state.ships.iter().enumerate() {
            if s.active == 0 || i as u8 == ship {
                continue;
            }
            assert_ne!(s.team, mine, "the human shares a side with ship {i}");
        }
    }

    #[test]
    fn a_pilot_who_can_see_nobody_goes_looking() {
        // The other reason the arena was full of statues. A bot with nothing in
        // sight returned no buttons at all, so it stopped where it stood and
        // stayed there for as long as the room was up.
        let mut z = serving(1, 6, 16);
        let a = &mut z.rooms[0];
        // Alone: one pilot and nobody else, so there is provably nothing for
        // them to see.
        let keep = seat_bots(a, 1)[0];
        let mut bot = ai::Bot::new(keep, 0.5);
        let route = nav::Nav::build(&a.world.map);
        let mut moved = false;
        for _ in 0..400 {
            let fresh = bot.looks_due().then(|| ai::scan(&a.world, keep));
            let buttons = bot.think(&ai::own(&a.world, keep), &route, fresh);
            a.world.step(&[sim::sim_input {
                ship: keep,
                buttons,
            }]);
            let sh = &a.world.state.ships[keep as usize];
            if sh.vx != 0 || sh.vy != 0 {
                moved = true;
                break;
            }
        }
        assert!(
            moved,
            "a pilot with nobody in sight sat still instead of looking"
        );
    }

    /// A seat is furniture, and its last occupant does not come with it.
    ///
    /// Joining cleared the stat upgrades and nothing else, so a pilot handed a
    /// used seat inherited its weapon levels, add-ons, charges, earned bounty,
    /// score and position. Leaving and rejoining is the case that makes it
    /// plain: seats come back in the order they were vacated, so a player is
    /// handed their own and the zone reads as having saved their game.
    #[test]
    fn a_quit_under_fire_settles_as_a_death() {
        let def = wire_zone(1, 6, 16);
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        let room = &mut z.rooms[0];

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let hunter = room
            .join(Seat::guest("hunter", false), 0, 16, tx)
            .expect("a seat");
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let prey = room
            .join(Seat::guest("prey", false), 0, 16, tx)
            .expect("a seat");
        let hunter_rid = room.players[&hunter].rid.clone();
        let prey_rid = room.players[&prey].rid.clone();
        let ship = room.players[&prey].ship;

        // Shot to a quarter tank this instant, then the tab closes.
        let tick = room.world.state.tick;
        room.rating
            .damage(tick, &prey_rid, &hunter_rid, 1000, false);
        let ceiling = room.world.eff_max_energy(ship as usize);
        room.world.state.ships[ship as usize].energy = ceiling / 4;
        room.leave(prey, pilot::why::LEFT);

        assert_eq!(room.rating.log.len(), 1, "the quit settled as a death");
        assert_eq!(room.rating.log[0].victim, prey_rid);
        assert!(room.rating.rating_of(&prey_rid) < 1200.0, "and it cost");
        assert!(room.rating.rating_of(&hunter_rid) > 1200.0, "and it paid");
        assert_eq!(room.channel.pending_feed.len(), 1, "and the feed says so");
        let m = &room.channel.pending_feed[0];
        assert_eq!(m[0], S2C_KILL);
        assert_eq!(m[1], ship, "the victim's seat");
        assert_eq!(m[2], room.players[&hunter].ship, "credited to the hunter");
        assert_eq!(m.len(), 15, "the quit reads exactly like any other kill");
        assert_eq!(
            u32::from_le_bytes(m[8..12].try_into().unwrap()),
            room.world.state.tick,
            "the feed names the authoritative tick"
        );
        assert_eq!(m[12], 0, "and hands nobody an assist for a quit");
    }

    #[test]
    fn a_quit_with_the_tank_holding_is_a_leave() {
        let def = wire_zone(1, 6, 16);
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        let room = &mut z.rooms[0];

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let hunter = room
            .join(Seat::guest("hunter", false), 0, 16, tx)
            .expect("a seat");
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let prey = room
            .join(Seat::guest("prey", false), 0, 16, tx)
            .expect("a seat");
        let hunter_rid = room.players[&hunter].rid.clone();
        let prey_rid = room.players[&prey].rid.clone();

        // Plinked moments ago, but the tank is where the spawn left it: a
        // pilot this healthy could have flown away instead, so the quit is
        // an ordinary leave and the pending credit dies with it.
        let tick = room.world.state.tick;
        room.rating.damage(tick, &prey_rid, &hunter_rid, 200, false);
        room.leave(prey, pilot::why::LEFT);

        assert!(room.rating.log.is_empty(), "nothing settled");
        assert_eq!(room.rating.rating_of(&prey_rid), 1200.0);
        assert_eq!(room.rating.rating_of(&hunter_rid), 1200.0);
        assert!(room.channel.pending_feed.is_empty(), "and no feed line");
    }

    /// The whole join sort, on the numbers the shipped melee zone runs.
    ///
    /// Four rules compose, and the one that matters is the second clause of
    /// the third: bots do not count as fullness. A room holding one human and
    /// seven bots is one eighth full, not full, so the next person to press
    /// Melee lands beside them and a bot stands down.
    ///
    /// The rule this replaced said humans join at match boundaries and open a
    /// new room when they cannot find one, which guaranteed the thing it was
    /// meant to prevent: two people arriving ninety seconds apart would never
    /// meet, not rarely but never. What is checked here is the property that
    /// costs: three people pressing Melee across ten minutes land in one room.
    #[test]
    fn everybody_who_presses_melee_lands_in_the_same_room() {
        // Eight seats, eight of them a person's, and a new room only when the
        // first holds eight humans. That is `max_players` and `fill_target`
        // both at eight, which is what catalog/zones/melee/zone.toml says.
        let mut z = serving(10, 8, 8);
        let first = z.room_for_join().expect("a room to start in");
        assert_eq!(first, 0);

        // The room fills with bots between arrivals, the way the bot server
        // fills it. Nobody after this should read it as full.
        seat_bots(&mut z.rooms[0], 8);
        assert_eq!(z.rooms[0].bot_count(), 8);
        assert_eq!(
            z.room_for_join(),
            Some(0),
            "a room of bots is a room with eight seats going spare"
        );

        // Seven arrivals, one at a time, each finding the room the last one
        // is in. A bot stands down for each.
        for n in 1..=7 {
            let i = z.room_for_join().expect("a room");
            assert_eq!(i, 0, "arrival {n} went somewhere else");
            seat(&mut z, i, 1);
            assert_eq!(z.rooms.len(), 1, "and opened nothing");
            assert_eq!(z.rooms[0].humans(), n);
        }

        // The eighth fills it, and only then does a ninth get a room of their
        // own. This is the concentration rule doing the one thing it is for.
        seat(&mut z, 0, 1);
        assert_eq!(z.rooms[0].humans(), 8);
        let next = z.room_for_join().expect("a second room");
        assert_eq!(next, 1, "a full room is when a sibling opens");
        assert_eq!(z.rooms.len(), 2);
    }

    /// A solo arrival takes the side with fewer humans, so four people never
    /// stack against four bots.
    #[test]
    fn a_solo_arrival_takes_the_thinner_side() {
        let mut a = room_with_teams("teams = [\"Pylon\", \"Caisson\"]\n");
        let mut sides = Vec::new();
        for n in 0..4 {
            let ship = seat_human(&mut a, &format!("p{n}"));
            sides.push(a.world.state.ships[ship as usize].team);
        }
        assert_eq!(
            sides,
            vec![0, 1, 0, 1],
            "arrivals alternate rather than piling up"
        );

        // And a side already thick with bots is not the full one, because
        // what an arrival is weighed against is the humans on it. Heads only
        // break a tie: the first person lands across from the bots, and the
        // second lands beside them, on the side with fewer people.
        let mut b = room_with_teams("teams = [\"Pylon\", \"Caisson\"]\n");
        for i in 0..3 {
            let (tx, rx) = mpsc::channel(OUT_QUEUE);
            std::mem::forget(rx);
            let id = b
                .join(Seat::guest(format!("bot{i}"), true), 0, 32, tx)
                .expect("a seat");
            let ship = b.players[&id].ship;
            b.join_team(ship, 0);
        }
        let first = seat_human(&mut b, "person");
        assert_eq!(
            b.world.state.ships[first as usize].team, 1,
            "across from the bots rather than beside them"
        );
        let second = seat_human(&mut b, "another");
        assert_eq!(
            b.world.state.ships[second as usize].team, 0,
            "three bots on a side do not make it the full one"
        );
    }

    /// A room fills between matches and the sides drift. The whistle is where
    /// that is put right, which is the job the intermission has beyond the
    /// podium.
    #[test]
    fn the_whistle_evens_the_sides_up() {
        let mut a = match_room(1, 1);
        // Four humans, all pushed onto one side, which is what a run of
        // departures leaves behind.
        let mut ships = Vec::new();
        for n in 0..4 {
            let ship = seat_human(&mut a, &format!("p{n}"));
            a.world.state.ships[ship as usize].team = 0;
            ships.push(ship);
        }
        let side = |a: &Room, t: u8| {
            ships
                .iter()
                .filter(|s| a.world.state.ships[**s as usize].team == t)
                .count()
        };
        assert_eq!((side(&a, 0), side(&a, 1)), (4, 0), "all on one side");

        while a.match_no < 2 {
            a.tick();
        }
        assert_eq!(
            (side(&a, 0), side(&a, 1)),
            (2, 2),
            "and the whistle evens them"
        );
        let mut newest = ships.clone();
        newest.sort_unstable();
        newest.reverse();
        assert!(
            newest[..2]
                .iter()
                .all(|ship| a.world.state.ships[*ship as usize].team == 1),
            "same-tick joins use the ship id as a stable mover tie-break"
        );

        let mut ordered = ships.clone();
        ordered.sort_unstable();
        let centers = [0u8, 1u8].map(|team| {
            let members: Vec<_> = ships
                .iter()
                .map(|ship| a.world.state.ships[*ship as usize])
                .filter(|row| row.team == team)
                .collect();
            (
                members.iter().map(|row| i64::from(row.x)).sum::<i64>() as i32
                    / members.len() as i32,
                members.iter().map(|row| i64::from(row.y)).sum::<i64>() as i32
                    / members.len() as i32,
            )
        });
        let mut nth = [0u32; 2];
        for ship in ordered {
            let row = a.world.state.ships[ship as usize];
            let team = row.team as usize;
            let (tx, ty) = a
                .world
                .map_spawn(row.team, nth[team])
                .expect("a team start");
            nth[team] += 1;
            let expected = (
                tx * sim::TILE_PX * 256 + sim::TILE_PX * 128,
                ty * sim::TILE_PX * 256 + sim::TILE_PX * 128,
            );
            assert_eq!(
                (row.spawn_x, row.spawn_y),
                expected,
                "the restart uses the pilot's new side"
            );
            assert_eq!((row.x, row.y), expected, "the pilot opens at that start");
            assert_eq!(
                row.heading,
                room::heading_toward((row.x, row.y), centers[1 - team]),
                "both sides face into the match"
            );
        }
    }

    /// A bot is never moved to make the sides look even. Bots fill what humans
    /// leave, so moving one evens the roster and not the fight.
    #[test]
    fn evening_the_sides_moves_people_rather_than_bots() {
        let mut a = match_room(1, 1);
        let human = seat_human(&mut a, "person");
        a.world.state.ships[human as usize].team = 0;
        let bots = seat_bots(&mut a, 4);
        for b in &bots {
            a.world.state.ships[*b as usize].team = 0;
        }

        while a.match_no < 2 {
            a.tick();
        }
        assert_eq!(
            a.world.state.ships[human as usize].team, 0,
            "one human on a side is already even, however many bots are on it"
        );
        assert!(
            bots.iter()
                .all(|b| a.world.state.ships[*b as usize].team == 0),
            "and no bot was shuffled to make a number look right"
        );
    }

    /// A room built from a zone with named sides, for the team tests below.
    fn room_with_teams(toml: &str) -> Room {
        let mut def = wire_zone(1, 16, 32);
        def.zone_toml = toml.into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        z.rooms.remove(0)
    }

    fn seat_human(a: &mut Room, name: &str) -> u8 {
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        std::mem::forget(rx);
        let id = a
            .join(Seat::guest(name.to_string(), false), 0, 32, tx)
            .expect("a seat");
        a.players[&id].ship
    }

    /// A duel room as the catalog shapes one: two seats, a side each, the
    /// melee clock. The match is short so a test can run it out.
    fn duel_room(match_seconds: u16) -> Room {
        let mut def = wire_zone(1, 2, 2);
        def.mode = "melee".into();
        def.max_ships = 2;
        def.bot_fill = 1.0;
        def.zone_toml = format!(
            "max_ships = 2\nteams = [\"Pilot\", \"Rival\"]\nmax_humans_per_team = 1\n\
             max_bots_per_team = 1\n[arena]\nmatch_seconds = {match_seconds}\n\
             intermission_seconds = 1\n"
        );
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        let mut a = z.rooms.remove(0);
        assert!(a.is_duel(), "one a side on two sides is a duel");
        assert_eq!(a.world.cfg.max_ships, 2, "two seats");
        // The first tick opens the match, as it would for a fresh room.
        a.tick();
        a
    }

    /// A duel room as the catalog serves one, running the duel mode.
    fn duel_mode_room(first_to: u16) -> Room {
        let mut def = wire_zone(1, 2, 2);
        def.mode = "duel".into();
        def.max_ships = 2;
        def.zone_toml = format!(
            "max_ships = 2\nteams = [\"Pilot\", \"Rival\"]\n\
             max_humans_per_team = 1\nmax_bots_per_team = 1\n\
             [arena]\nfirst_to = {first_to}\nmatch_seconds = 180\n\
             intermission_seconds = 15\nrespawn_delay = 200\n"
        );
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        let mut a = z.rooms.remove(0);
        a.tick();
        a
    }

    /// The round reset puts both pilots back on the ground with everything a
    /// round is entitled to, and leaves the score alone. That last part is
    /// the whole reason it is not `open_match`.
    #[test]
    fn a_duel_round_resets_the_arena_without_touching_the_score() {
        let mut a = duel_mode_room(2);
        let pilot = seat_human(&mut a, "pilot");
        let rival = seat_human(&mut a, "rival");
        assert_ne!(
            a.world.state.ships[pilot as usize].team, a.world.state.ships[rival as usize].team,
            "a side each"
        );
        a.tick();

        // A round already taken, and a rack already spent.
        a.world.state.ships[rival as usize].deaths = 1;
        a.world.state.ships[pilot as usize].kills = 1;
        let racked: Vec<u8> = a.world.state.ships[pilot as usize].charge.to_vec();
        assert!(racked.iter().any(|n| *n > 0), "a rack to spend");
        for sh in a.world.state.ships.iter_mut() {
            sh.charge = [0; sim::MAX_CHARGES];
        }
        // And the loser hurt, somewhere out on the map, with a bomb still up.
        a.world.state.ships[rival as usize].energy = 1;
        a.world.state.ships[rival as usize].x = 40 * 256;
        a.world.state.weapon_count = 1;
        let before = a.round_no;

        a.open_round();
        assert_eq!(a.round_no, before + 1);
        assert_eq!(a.world.state.weapon_count, 0, "nothing left in the air");
        for ship in [pilot, rival] {
            let sh = a.world.state.ships[ship as usize];
            assert_eq!(sh.alive, 0, "down for the tick between rounds");
            assert_eq!(sh.energy, 0, "which the snapshot wire requires");
            assert_eq!(sh.respawn_at, 1, "and back on the next one");
            assert_eq!(
                sh.charge.to_vec(),
                racked,
                "with the rack a round is entitled to"
            );
        }
        assert_eq!(
            a.world.state.ships[rival as usize].deaths, 1,
            "the rounds already taken are the score and survive the reset"
        );
        assert_eq!(a.world.state.ships[pilot as usize].kills, 1);

        // One tick, and the core's own spawn puts them back at a full bar on
        // a start, which is what makes a round open like a match does.
        a.tick();
        for ship in [pilot, rival] {
            let full = a.world.eff_max_energy(ship as usize);
            let sh = a.world.state.ships[ship as usize];
            assert_eq!(sh.alive, 1, "flying again");
            assert_eq!(sh.energy, full, "at a full bar");
        }
    }

    /// End to end through the room: a death, the two second window, a fresh
    /// round, and the second round taking the match into a podium.
    #[test]
    fn a_duel_is_played_in_rounds_and_two_of_them_take_it() {
        let mut a = duel_mode_room(2);
        let pilot = seat_human(&mut a, "pilot");
        let rival = seat_human(&mut a, "rival");
        a.tick();
        let (mine, theirs) = (
            a.world.state.ships[pilot as usize].team as usize,
            a.world.state.ships[rival as usize].team as usize,
        );

        // The room reads the score off the ships, so a death written here is
        // a death as far as the mode is concerned.
        for round in 1..=2 {
            a.world.state.ships[rival as usize].deaths += 1;
            let mut ctx = modes::ModeCtx {
                world: &mut a.world,
                team_names: &["Pilot".to_string(), "Rival".to_string()],
                banner: String::new(),
                finished: false,
                open_match: false,
                round_reset: false,
                close_match: false,
            };
            a.mode.on_death(&mut ctx, rival, pilot);
            drop(ctx);
            assert_eq!(
                a.mode.match_state().unwrap().score[mine],
                round,
                "the round is the other side's death"
            );

            let before = a.round_no;
            for _ in 0..modes::ROUND_CLOSE_TICKS + 2 {
                a.tick();
            }
            if round == 1 {
                assert_eq!(a.round_no, before + 1, "a fresh round opened");
                assert!(a.mode.match_state().unwrap().playing);
            }
        }

        let state = a.mode.match_state().unwrap();
        assert!(!state.playing, "two rounds and a lead is the match");
        assert_eq!(state.score[mine], 2);
        assert_eq!(state.score[theirs], 0);
        assert_eq!(
            a.world.state.ships[pilot as usize].alive, 0,
            "everybody benched for the podium"
        );
    }

    #[test]
    fn a_duel_arrival_lands_across_from_the_bot_that_stays() {
        // Two bots hold an empty duel room. The person at the door takes one
        // bot's seat, and used to be put beside the other: no humans on either
        // side, so the tie went to the first side, which was as likely as not
        // the one the surviving bot was on. Then the ballast rule moved the
        // bot across a few seconds later, kills and all.
        for evicted_first in [false, true] {
            let mut a = duel_room(180);
            let bots = seat_bots(&mut a, 2);
            assert_ne!(
                a.world.state.ships[bots[0] as usize].team,
                a.world.state.ships[bots[1] as usize].team,
                "a bot a side"
            );
            // Kill the bot the room should evict, so the test picks which one
            // stays rather than the eviction order.
            let (goes, stays) = if evicted_first {
                (bots[0], bots[1])
            } else {
                (bots[1], bots[0])
            };
            a.world.state.ships[goes as usize].alive = 0;
            a.world.state.ships[goes as usize].energy = 0;

            let (tx, rx) = mpsc::channel(OUT_QUEUE);
            std::mem::forget(rx);
            let id = a
                .join(Seat::guest("pilot", false), 0, 2, tx)
                .expect("a seat, taken back from a bot");
            let pilot = a.players[&id].ship;
            assert_eq!(pilot, goes, "the dead bot's seat");
            assert_eq!(a.bot_count(), 1);
            assert_ne!(
                a.world.state.ships[pilot as usize].team, a.world.state.ships[stays as usize].team,
                "and the side across from the bot that stayed"
            );
        }
    }

    #[test]
    fn a_duel_opens_a_fresh_match_when_a_seat_changes_hands() {
        let mut a = duel_room(180);
        let bots = seat_bots(&mut a, 2);
        for _ in 0..500 {
            a.tick();
        }
        // The bots have been at it: one of them is well ahead.
        a.world.state.ships[bots[0] as usize].kills = 5;
        a.world.state.ships[bots[1] as usize].deaths = 5;
        a.tick();
        let before = a.mode.match_state().unwrap();
        assert_eq!(before.score.iter().sum::<u16>(), 5);
        assert!(before.seconds_left < 180, "and the clock has run");
        let match_no = a.match_no;

        let pilot = seat_human(&mut a, "pilot");
        a.tick();
        let after = a.mode.match_state().unwrap();
        assert!(after.playing);
        assert_eq!(after.seconds_left, 180, "a whole clock");
        assert_eq!(after.score, vec![0, 0], "nothing on the board");
        assert_eq!(a.match_no, match_no + 1, "a match of its own");
        for sh in a.world.state.ships.iter().filter(|s| s.active != 0) {
            assert_eq!((sh.kills, sh.deaths), (0, 0), "nobody carries a tally in");
            assert_eq!(sh.alive, 1, "and everybody is flying");
        }
        assert!(a.names.contains_key(&pilot));
    }

    #[test]
    fn a_duel_arrival_during_the_podium_waits_for_the_next_match() {
        // Two seconds of match, one of podium. With the podium up the next
        // match opens on its own, and the arrival joins that rather than
        // cutting the podium short.
        let mut a = duel_room(2);
        seat_bots(&mut a, 2);
        for _ in 0..250 {
            a.tick();
        }
        assert!(!a.mode.match_state().unwrap().playing, "the podium is up");
        let match_no = a.match_no;

        let pilot = seat_human(&mut a, "pilot");
        a.tick();
        assert!(!a.mode.match_state().unwrap().playing, "and stays up");
        assert_eq!(
            a.world.state.ships[pilot as usize].alive, 0,
            "benched with everybody"
        );
        for _ in 0..100 {
            a.tick();
        }
        let state = a.mode.match_state().unwrap();
        assert!(state.playing, "the intermission ran out");
        assert_eq!(a.match_no, match_no + 1, "into the next match, once");
        assert_eq!(a.world.state.ships[pilot as usize].alive, 1);
    }

    #[test]
    fn a_melee_arrival_lands_across_from_the_bots_rather_than_beside_them() {
        // The same tie, in a wide room: a person arriving to one bot on the
        // first side lands on the second, where before they shared a side
        // until the ballast moved.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let bot = seat_bots(&mut a, 1)[0];
        let pilot = seat_human(&mut a, "pilot");
        assert_ne!(
            a.world.state.ships[pilot as usize].team,
            a.world.state.ships[bot as usize].team,
        );
        // And the human count still comes first: a second person lands
        // beside the bot, across from the first person, whatever the heads.
        let second = seat_human(&mut a, "second");
        assert_eq!(
            a.world.state.ships[second as usize].team,
            a.world.state.ships[bot as usize].team,
        );
    }

    /// The melee maps have to be a place the design describes, and the two
    /// numbers that decide that are geometric rather than aesthetic: the
    /// sides start apart, and there is more than one way between them.
    ///
    /// Sized in seconds of flight rather than in tiles, because that is the
    /// unit `docs/design/match-game.md` argues in: first contact five to eight
    /// seconds from the whistle. Both sides leave home at once and meet in the
    /// middle, so what that asks of a map is ten to sixteen seconds of route
    /// between the two pockets, flown at the top speed the baseline gives a
    /// hull. Read off the core rather than written down here, because a
    /// roster retune would otherwise move the thing being measured and not
    /// the measurement.
    ///
    /// This is what would catch a map redrawn from a new seed that happened to
    /// put both pockets in the same corner, which nothing else here checks and
    /// which is invisible in a generator line that says "8 spawns".
    #[test]
    fn the_melee_maps_are_two_homes_with_ground_between_them() {
        for name in ["maelstrom", "gantry", "warren", "redoubt", "ringworks"] {
            let bytes = std::fs::read(format!("../catalog/zones/melee/{name}.vwmap"))
                .unwrap_or_else(|e| panic!("{name} ships in this repository: {e}"));
            let w = sim::World::from_packed(0x5eed, &bytes).expect("a map");

            // Four starts a side, so `sim_restart` can line a side up along
            // its own pocket rather than piling four ships on one tile.
            let mut homes = [Vec::new(), Vec::new()];
            for team in 0..2u8 {
                for nth in 0..4u32 {
                    let p = w.map_spawn(team, nth).expect("a start");
                    if !homes[team as usize].contains(&p) {
                        homes[team as usize].push(p);
                    }
                }
            }
            assert_eq!(homes[0].len(), 4, "{name}: four starts for side one");
            assert_eq!(homes[1].len(), 4, "{name}: four starts for side two");

            // A pocket is somewhere, not everywhere: every start of a side is
            // within twenty tiles of its own first one.
            for (t, side) in homes.iter().enumerate() {
                for p in side {
                    let d = (((p.0 - side[0].0).pow(2) + (p.1 - side[0].1).pow(2)) as f64).sqrt();
                    assert!(
                        d <= 20.0,
                        "{name}: side {t} is scattered, not pocketed ({d:.0} tiles)"
                    );
                }
            }

            let route = nav::Nav::build(&w.map);
            let px = |p: (i32, i32)| ((p.0 * 16 + 8) as f32, (p.1 * 16 + 8) as f32);
            let legs = route.route(px(homes[0][0]), px(homes[1][0]));
            assert!(
                !legs.is_empty(),
                "{name}: a hull can fly from one home to the other"
            );
            let mut flown = 0.0f32;
            let mut at = px(homes[0][0]);
            for leg in &legs {
                flown += ((leg.0 - at.0).powi(2) + (leg.1 - at.1).powi(2)).sqrt();
                at = *leg;
            }
            // The middle of the roster, which is the honest single number now
            // that the seven fly at seven speeds: the raider crosses a room a
            // third faster than the heavy, and a map's promise is about
            // everybody who flies it. Matches what `mapforge` gates on.
            let mut probe = sim::World::from_packed(0x5eed, &bytes).expect("a map");
            let ship = probe.spawn_on_map(0, 0, 0, 0);
            assert!(ship >= 0, "{name}: a seat");
            let sh = probe.state.ships[ship as usize];
            let mut speeds: Vec<i32> = (0..probe.cfg.class_count as usize)
                .map(|c| unsafe { sim::sim_eff_speed(&probe.cfg.classes[c], &sh) })
                .collect();
            speeds.sort_unstable();
            let top = speeds[speeds.len() / 2] as f32 / 65536.0;
            let seconds = flown / (top * 100.0);
            let tiles = flown / 16.0;
            // A tenth either side of the design's window. What is measured
            // here is a router's polyline flown at a constant top speed, and
            // a pilot does neither: they cut the corners the router rounds,
            // and they spend the first second getting up to speed. The
            // estimate is worth a few per cent, so the bound is too.
            assert!(
                (6.0..=11.6).contains(&seconds),
                "{name}: the homes are {tiles:.0} tiles apart, {seconds:.1} s of \
                 flight, so first contact lands at {:.1} s rather than the three \
                 to six the design asks for",
                seconds / 2.0
            );
            println!(
                "{name}: homes {tiles:.0} tiles apart, {seconds:.1} s of flight, \
                 first contact about {:.1} s",
                seconds / 2.0
            );
        }
    }

    /// A match room built the way the shipped zone is: two maps, two sides,
    /// and the mode's clock read out of the file rather than out of a default.
    fn match_room(match_seconds: u16, intermission_seconds: u16) -> Room {
        let mut def = wire_zone(1, 8, 8);
        def.mode = "melee".into();
        // Two, and they have to be different tiles or the test that says the
        // ground changed would pass on a room that never moved.
        def.maps_b64 = vec![
            fleet::b64(&sim::World::new(1).packed_map()),
            fleet::b64(&sim::World::with_map(1, sim::build_pit).packed_map()),
        ];
        def.map_names = vec!["proving".into(), "the pit".into()];
        def.zone_toml = format!(
            "label = \"a match zone\"\nteams = [\"Pylon\", \"Caisson\"]\n\
             [arena]\nmatch_seconds = {match_seconds}\n\
             intermission_seconds = {intermission_seconds}\n"
        );
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        z.rooms.remove(0)
    }

    /// A pilot whose queue was full at the whistle is not left flying the
    /// last match's walls.
    ///
    /// The map used to be sent once, best effort, and never mentioned again.
    /// `try_send` refuses rather than waits, and a client that missed a
    /// rotation had no way to find out: it went on predicting and drawing the
    /// previous round's ground while the server bounced it off the new one.
    ///
    /// Both halves are pinned here. While the map is outstanding the tuning is
    /// held back with it, so the client keeps refusing frames instead of
    /// predicting the new match on the old ground; once its socket reads
    /// again, a tick hands over the map, the name and the rules together.
    #[test]
    fn a_refused_map_is_owed_rather_than_lost() {
        let mut a = match_room(1, 1);
        let (tx, mut rx) = mpsc::channel(OUT_QUEUE);
        let id = a
            .join(Seat::guest("pilot".to_string(), false), 0, 32, tx.clone())
            .expect("a seat");
        let before = a.map_msg();

        // Their socket has stopped reading. Nothing else is contrived here:
        // this is a queue that has run out of room, which is the whole
        // condition.
        while tx.try_send(Message::Binary(vec![0])).is_ok() {}

        // A second of play, a second of podium, and the next match opens on
        // the other map.
        while a.match_no < 2 {
            a.tick();
        }
        assert_ne!(a.map_msg(), before, "the room rotated its ground");
        assert!(
            a.players[&id].owes_map,
            "and the room knows this pilot did not take it"
        );

        // Their socket reads again, which is what makes the rest of this about
        // the hold-back rule rather than about a queue with no room in it.
        while rx.try_recv().is_ok() {}
        a.broadcast_settings();
        assert!(
            !drain(&mut rx)
                .iter()
                .any(|m| m.first() == Some(&S2C_SETTINGS)),
            "no rules for a generation whose ground they have not been given"
        );

        // And the next tick makes them whole.
        a.tick();
        let got = drain(&mut rx);
        assert!(!a.players[&id].owes_map, "the debt is paid");
        assert_eq!(
            got.iter().find(|m| m.first() == Some(&S2C_MAP)),
            Some(&a.map_msg()),
            "and it was paid with the ground the room is standing on"
        );
        assert!(
            got.iter().any(|m| m.first() == Some(&S2C_MAPNAME)),
            "the name the sky and the label are drawn from rides with it"
        );
        assert!(
            got.iter().any(|m| m.first() == Some(&S2C_SETTINGS)
                && m[1..5] == a.settings_generation.to_le_bytes()),
            "and the rules that generation of frames is packed under"
        );
    }

    /// Deploying from the menu joins the fight the menu was showing.
    ///
    /// The landing dials the room a deploy would land in and plays it behind
    /// the panel, with that room's own clock and score beside it, so the press
    /// means that match and no other. Written on the room rather than on the
    /// mode because the room is where the two halves meet, and flown the way a
    /// person actually arrives: watching, and then taking a hull.
    #[test]
    fn deploying_from_the_stands_joins_the_match_on_the_clock() {
        let mut a = match_room(180, 15);
        let bots = seat_bots(&mut a, 4);
        // The opening tick is the one that starts the match, and it restarts
        // the world; a tally written before it would be wiped by it.
        a.tick();
        a.world.state.ships[bots[0] as usize].kills = 2;

        // Half a minute of bot fight, which is what the menu is previewing.
        for _ in 0..2999 {
            a.tick();
        }
        let opened = a.match_no;
        let before = a.mode.match_state().expect("a match room has a clock");
        assert!(before.playing);
        assert_eq!(before.seconds_left, 150, "two and a half minutes left");
        assert!(before.score.iter().any(|n| *n > 0), "and a score standing");

        // Watching it, then pressing deploy: one connection, no re-dial.
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        std::mem::forget(rx);
        let watcher = a
            .watch_join(Seat::guest("pilot", false), tx)
            .expect("a place in the stands");
        a.fly(watcher, 0, 8).expect("a seat on the field");
        a.tick();

        let after = a.mode.match_state().expect("still a match room");
        assert_eq!(a.match_no, opened, "no second match opened at the door");
        assert_eq!(
            after.seconds_left, before.seconds_left,
            "the clock the menu showed is the clock they arrived on"
        );
        assert_eq!(after.score, before.score, "and the score stands");
    }

    /// The caption follows the ground: the name a client is handed beside the
    /// map is the rotation's name for whichever map the room is standing on,
    /// and a room whose maps arrived without names hands out nothing rather
    /// than a guess.
    #[test]
    fn the_map_name_names_the_map_the_room_is_on() {
        let a = match_room(1, 1);
        assert_eq!(
            a.map_name_msg(),
            Some([&[protocol::S2C_MAPNAME][..], b"proving"].concat()),
            "the first match is on the first name"
        );
        let mut a = a;
        a.close_match();
        assert_eq!(
            a.map_name_msg(),
            Some([&[protocol::S2C_MAPNAME][..], b"the pit"].concat()),
            "the whistle moves the caption with the ground"
        );

        let mut def = wire_zone(1, 8, 8);
        def.map_names = Vec::new();
        let bare = ArenaServer::build_room(&def, None).expect("a room");
        assert_eq!(bare.map_name_msg(), None, "no names, no caption");
    }

    /// The whistle at the end of a match empties the arena and moves the room
    /// to the ground the next one is played on.
    ///
    /// A podium drawn over the fight you just finished, with the wrecks and
    /// the last bomb still hanging there, is fifteen seconds of looking at
    /// something that is over. Both halves are about the wait: the map goes
    /// down before it rather than after, and nothing is left on it.
    ///
    /// Nothing anybody earned is touched by that. The tallies the podium is
    /// reading live on the ships, so the arena is cleared by benching rather
    /// than by restarting, which is what zeroes them.
    #[test]
    fn the_arena_empties_at_the_whistle_and_the_next_map_goes_down() {
        let mut a = match_room(1, 3);
        let ship = seat_human(&mut a, "pilot") as usize;
        a.tick();
        assert!(a.mode.match_state().unwrap().playing);
        let ground = a.map_at;

        // Something in the air and something on the board, so there is
        // anything to clear at all.
        a.world.state.weapon_count = 1;
        a.world.state.ships[ship].kills = 3;
        a.world.state.ships[ship].deaths = 1;
        assert_eq!(a.world.state.ships[ship].alive, 1);

        for _ in 0..120 {
            a.tick();
        }
        assert!(
            !a.mode.match_state().unwrap().playing,
            "the podium is up by now"
        );
        assert_ne!(a.map_at, ground, "the wait happens on the next map");
        assert_eq!(a.world.state.weapon_count, 0, "nothing left in the air");
        assert_eq!(a.world.state.ships[ship].alive, 0, "and nobody on the map");
        assert_eq!(
            a.world.state.ships[ship].respawn_at, 0,
            "benched rather than dead: nothing is coming back on its own"
        );
        // The whole point of benching rather than restarting.
        assert_eq!(
            (
                a.world.state.ships[ship].kills,
                a.world.state.ships[ship].deaths
            ),
            (3, 1),
            "the numbers the podium is reading survive the whistle"
        );

        // And the room a client is looking at is one it can still read.
        //
        // `sim_unpack` refuses a ship that is down with charge still in it,
        // and it is right to: alive and energy are one fact told twice, and a
        // snapshot that disagrees with itself describes a game nobody can
        // play. Benching without clearing the energy broke that on the first
        // whistle, and every client in the room was disconnected at once and
        // told the zone had sent a snapshot it could not read. So the whistle
        // is checked against the wire rather than only against the fields it
        // wrote.
        assert_eq!(
            a.world.state.ships[ship].energy, 0,
            "a ship that is down carries nothing"
        );
        let mut wire = vec![0u8; sim::STATE_PACK_MAX];
        let n = a.world.pack(&mut wire);
        assert!(n > 0, "the room packs a snapshot");
        let mut reader = sim::World::new(1);
        assert!(
            reader.apply_snapshot(&wire[..n as usize]),
            "and a client can read the one the podium is drawn over"
        );

        // And the next whistle puts everybody back on it.
        for _ in 0..400 {
            a.tick();
            if a.mode.match_state().unwrap().playing {
                break;
            }
        }
        assert!(a.mode.match_state().unwrap().playing, "a match opened");
        assert_eq!(
            a.world.state.ships[ship].alive, 1,
            "and the pilot is flying again"
        );
        assert_eq!(
            a.world.state.ships[ship].kills, 0,
            "on a board the whistle zeroed"
        );
    }

    /// The one thing a player can send another player, and the rules that
    /// keep it from becoming chat.
    ///
    /// Between matches only, one every two seconds, and an index into a list
    /// the clients hold rather than a word. That last one is what makes this
    /// a closed set rather than a channel: the room never sees text, so there
    /// is nothing here anybody could put a sentence through. See decision 28,
    /// which this does not overturn.
    #[test]
    fn a_phrase_reaches_the_room_between_matches_and_no_faster_than_it_reads() {
        let mut a = match_room(1, 3);
        let (ship, _, mut rx) = seat_rx(&mut a, "pilot");
        let heard = |rx: &mut mpsc::Receiver<Message>| -> Option<Vec<u8>> {
            drain(rx)
                .into_iter()
                .find(|m| m.first() == Some(&crate::protocol::S2C_SAID))
        };

        a.tick(); // opens the match
        assert!(a.mode.match_state().unwrap().playing);
        a.say(ship, 0);
        assert!(
            heard(&mut rx).is_none(),
            "nothing is said over a fight somebody is trying to play"
        );

        // To the whistle.
        for _ in 0..120 {
            a.tick();
        }
        assert!(!a.mode.match_state().unwrap().playing, "the podium is up");
        let _ = drain(&mut rx);

        a.say(ship, 2);
        assert_eq!(
            heard(&mut rx),
            Some(vec![crate::protocol::S2C_SAID, ship, 2]),
            "the room hears which line, and whose"
        );

        // Twice in a row is once. A line nobody can repeat faster than it can
        // be read is a line nobody can shout with.
        a.say(ship, 3);
        assert!(
            heard(&mut rx).is_none(),
            "the second one inside two seconds"
        );

        // And a number off the end of the list is nothing at all, whatever a
        // client sends. The wire carries an index and the room owns the range.
        for _ in 0..220 {
            a.tick();
            if a.mode.match_state().is_some_and(|m| m.playing) {
                break;
            }
        }
        let _ = drain(&mut rx);
        a.say(ship, crate::protocol::SAY_COUNT);
        assert!(heard(&mut rx).is_none(), "there is no phrase past the list");
    }

    /// Somebody who arrives during an intermission joins the wait, not a
    /// match that is not running.
    ///
    /// The whistle benches the room and the controls are held until the next
    /// one, so a pilot seated alive in between is the one hull on an empty map
    /// who cannot move it and can hear their own engine. Reported exactly that
    /// way: thrust audible, ship going nowhere.
    #[test]
    fn a_pilot_who_arrives_at_the_podium_waits_with_everybody_else() {
        let mut a = match_room(1, 3);
        for _ in 0..120 {
            a.tick();
        }
        assert!(
            !a.mode.match_state().unwrap().playing,
            "the podium is up by now"
        );

        let late = seat_human(&mut a, "late") as usize;
        assert_eq!(
            a.world.state.ships[late].alive, 0,
            "an arrival at the podium is benched with the rest of the room"
        );
        assert_eq!(
            a.world.state.ships[late].energy, 0,
            "and carries nothing, which is what the wire demands of a ship \
             that is down"
        );
        let mut wire = vec![0u8; sim::STATE_PACK_MAX];
        let n = a.world.pack(&mut wire);
        let mut reader = sim::World::new(1);
        assert!(
            reader.apply_snapshot(&wire[..n as usize]),
            "and the room is still one a client can read"
        );

        // And the next whistle puts them in it.
        for _ in 0..400 {
            a.tick();
            if a.mode.match_state().unwrap().playing {
                break;
            }
        }
        assert!(a.mode.match_state().unwrap().playing, "a match opened");
        assert_eq!(
            a.world.state.ships[late].alive, 1,
            "and the pilot who waited is flying it"
        );
    }

    /// Nobody flies during an intermission. That is the whole of what makes it
    /// one rather than a free-for-all under a frozen scoreboard.
    #[test]
    fn the_controls_are_held_between_matches() {
        let mut a = match_room(1, 2);
        let ship = seat_human(&mut a, "pilot") as usize;
        for _ in 0..120 {
            a.tick();
        }
        assert!(
            !a.mode.match_state().unwrap().playing,
            "the podium is up by now"
        );

        // Full thrust, held. A ship that moves is a ship taking input.
        let id = *a.players.keys().next().unwrap();
        let before = (a.world.state.ships[ship].vx, a.world.state.ships[ship].vy);
        for _ in 0..20 {
            let now = a.world.state.tick.wrapping_add(1);
            a.players
                .get_mut(&id)
                .unwrap()
                .schedule(now, sim::BTN_THRUST, now);
            a.tick();
        }
        assert_eq!(
            (a.world.state.ships[ship].vx, a.world.state.ships[ship].vy),
            before,
            "thrust does nothing while the podium is up"
        );
    }

    #[test]
    fn a_zone_names_its_own_sides_and_arrivals_spread_over_them() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        assert_eq!(a.public_teams, 2);
        assert_eq!(a.teams[&0].name, "Keel");
        assert!(a.teams[&0].public, "the zone's own are public");
        let one = seat_human(&mut a, "one");
        let two = seat_human(&mut a, "two");
        assert_ne!(
            a.world.state.ships[one as usize].team, a.world.state.ships[two as usize].team,
            "the second arrival lands on the emptier side"
        );
    }

    #[test]
    fn a_full_side_is_the_only_thing_that_refuses_a_join() {
        // The whole team policy is three caps, so this is the whole of what a
        // player can be told no about.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\nmax_humans_per_team = 1\n");
        let one = seat_human(&mut a, "one");
        let two = seat_human(&mut a, "two");
        let (first, second) = (
            a.world.state.ships[one as usize].team,
            a.world.state.ships[two as usize].team,
        );
        assert!(!a.join_team(two, first), "one a side means one a side");
        assert_eq!(
            a.world.state.ships[two as usize].team, second,
            "and no move"
        );
        // The cap counts people, not seats: a bot on that side is not in the
        // way of a human.
        seat_bots(&mut a, 2);
        assert!(!a.join_team(two, first), "still full of its one human");
    }

    #[test]
    fn a_private_side_admits_only_who_it_invited_and_dies_when_empty() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let founder = seat_human(&mut a, "founder");
        let guest = seat_human(&mut a, "guest");
        let stranger = seat_human(&mut a, "stranger");

        assert!(a.found_and_move(founder), "anyone may found one");
        let team = a.world.state.ships[founder as usize].team;
        assert!(team >= a.public_teams, "and it is not one of the zone's");
        assert!(!a.teams[&team].public);
        assert!(!a.teams[&team].name.is_empty(), "wearing a generated name");

        assert!(!a.join_team(stranger, team), "a closed door is closed");
        assert!(a.invite(founder, guest), "any member may open it");
        assert!(a.join_team(guest, team), "and then it is open");
        assert!(!a.join_team(stranger, team), "to the invited only");

        // Everyone walks away, which is how a team sheds somebody without a
        // kick, and the side stops existing behind them.
        assert!(a.join_team(founder, 0));
        assert!(a.join_team(guest, 0));
        assert!(
            !a.teams.contains_key(&team),
            "an empty private side is gone"
        );
    }

    #[test]
    fn founding_again_after_leaving_gives_a_different_name() {
        // A lone player founding, leaving, and founding again used to be
        // handed the word the reaper had just freed, so the second side was
        // called Anvil Watch exactly like the first and the menu looked stuck.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let ship = seat_human(&mut a, "one");

        let mut seen = Vec::new();
        for _ in 0..4 {
            assert!(a.found_and_move(ship));
            let team = a.world.state.ships[ship as usize].team;
            seen.push(a.teams[&team].name.clone());
            assert!(a.join_team(ship, 0), "back to the zone's own side");
        }
        let mut sorted = seen.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            seen.len(),
            "four founds, four names: {seen:?}"
        );

        // The cursor wraps rather than climbing, so the words come back round
        // instead of turning into Anvil Watch 30 in a room that churns.
        for _ in 0..20 {
            assert!(a.found_and_move(ship));
            assert!(a.join_team(ship, 0));
        }
        assert!(a.found_and_move(ship));
        let team = a.world.state.ships[ship as usize].team;
        assert_eq!(a.teams[&team].name, seen[0], "round again, no suffix");
    }

    #[test]
    fn a_zone_can_say_there_is_no_third_side() {
        // max_teams at the count of its own is how a flag round refuses to
        // seat a side its mode cannot score.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\nmax_teams = 2\n");
        let ship = seat_human(&mut a, "one");
        assert!(a.free_team_byte().is_none(), "no room for another");
        assert!(!a.found_and_move(ship), "so nobody may found one");
        assert_eq!(a.teams.len(), 2);
    }

    #[test]
    fn a_free_for_all_seats_everybody_on_a_side_of_their_own() {
        // The old shape of this was `teams = 1`, which is one side rather than
        // none: everybody on side zero, and every hostility test in the stack
        // asks whether two sides differ, so the zone ran with combat off.
        let mut a = room_with_teams("teams = []\nmax_humans_per_team = 3\n");
        assert!(a.free_for_all());
        let ships: Vec<u8> = (0..4)
            .map(|i| seat_human(&mut a, &format!("p{i}")))
            .collect();
        let sides: std::collections::HashSet<u8> = ships
            .iter()
            .map(|s| a.world.state.ships[*s as usize].team)
            .collect();
        assert_eq!(sides.len(), 4, "four pilots, four sides");
        assert!(sides.iter().all(|t| *t != sim::TEAM_NONE));

        // A pact forms by invitation and stops at the cap, which is what the
        // cap is for in a room of soloists.
        let host = ships[0];
        let team = a.world.state.ships[host as usize].team;
        for guest in &ships[1..3] {
            assert!(a.invite(host, *guest));
            assert!(a.join_team(*guest, team));
        }
        assert!(a.invite(host, ships[3]));
        assert!(
            !a.join_team(ships[3], team),
            "three is the pact this zone allows"
        );
    }

    #[test]
    fn bots_follow_the_people() {
        // Five friends take one side of a flag game. The ballast is what turns
        // that from a stomp into a raid, so it has to move after them.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        seat_bots(&mut a, 6);
        let humans: Vec<u8> = (0..4)
            .map(|i| seat_human(&mut a, &format!("p{i}")))
            .collect();
        for h in &humans {
            a.join_team(*h, 0);
        }
        assert_eq!(a.team_census(0, None).0, 4, "everybody on Keel");

        let before = a.team_census(0, None);
        for _ in 0..12 {
            a.rebalance_bots();
        }
        let (k_humans, k_bots) = a.team_census(0, None);
        let (_, v_bots) = a.team_census(1, None);
        assert_eq!(k_humans, 4, "the people stay where they chose");
        assert!(k_bots < before.1, "and the bots left with the imbalance");
        assert!(v_bots > k_bots, "for the side that needed them");
        // And it settles rather than oscillating: another dozen calls change
        // nothing once the sides are within one of each other.
        let settled = (a.team_census(0, None), a.team_census(1, None));
        for _ in 0..12 {
            a.rebalance_bots();
        }
        assert_eq!(
            (a.team_census(0, None), a.team_census(1, None)),
            settled,
            "a balanced room stops moving"
        );
    }

    #[test]
    fn a_free_for_all_list_holds_your_own_side_and_nobody_elses() {
        // Sixty-four seats is sixty-four sides here, and a menu listing
        // sixty-three strangers' private teams of one is a menu nobody can
        // use. You see the zone's own, your own, and any that invited you.
        let mut a = room_with_teams("teams = []\n");
        let me = seat_human(&mut a, "me");
        for i in 0..5 {
            seat_human(&mut a, &format!("other{i}"));
        }
        assert_eq!(a.teams.len(), 6, "six pilots, six sides");
        let m = a.teams_msg(me);
        assert_eq!(m[3], 1, "and one of them on my list");
        assert_eq!(m[1], a.world.state.ships[me as usize].team);
        assert_eq!(m[2], 0, "founding another alone would change nothing");
    }

    #[test]
    fn the_team_wire_reads_back_exactly() {
        // Same reason as the roster's: the client walks this with a cursor,
        // so a field added on one side and not the other turns every name
        // after it into gibberish.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let ship = seat_human(&mut a, "one");
        seat_bots(&mut a, 2);
        let m = a.teams_msg(ship);
        assert_eq!(m[0], S2C_TEAMS);
        assert_eq!(
            m[1], a.world.state.ships[ship as usize].team,
            "where you are"
        );
        assert_eq!(m[2], 1, "and whether you may found one");
        let count = m[3] as usize;
        assert_eq!(count, 2);
        let mut at = 4;
        let mut read = Vec::new();
        for _ in 0..count {
            let byte = m[at];
            let public = m[at + 1];
            let may_join = m[at + 2];
            let humans = m[at + 3];
            let bots = m[at + 4];
            let len = m[at + 5] as usize;
            let name = String::from_utf8(m[at + 6..at + 6 + len].to_vec()).unwrap();
            at += 6 + len;
            read.push((byte, public, may_join, humans, bots, name));
        }
        assert_eq!(at, m.len(), "the reader lands exactly on the end");
        assert_eq!(read[0].5, "Keel");
        assert_eq!(read[1].5, "Vantage");
        assert!(read.iter().all(|r| r.1 == 1), "both are the zone's own");
        assert!(read.iter().all(|r| r.2 == 1), "and both have room");
        assert_eq!(read.iter().map(|r| r.3 as u32).sum::<u32>(), 1, "one human");
        assert_eq!(read.iter().map(|r| r.4 as u32).sum::<u32>(), 2, "two bots");
    }

    /// Every reason a crossing is refused for, said to the pilot who asked.
    ///
    /// The one that matters is `NOTEAM_HURT`. A client will not send the ask
    /// on a part-full bar, so the only way to meet that refusal is to be whole
    /// when the key goes down and hurt when the message lands, which is a
    /// round arriving in between. It used to be answered with a team list that
    /// said where you already were, and a player pressing a key and being
    /// shown no change is a key that looks broken. See decision 150.
    #[test]
    fn a_refused_crossing_says_what_stopped_it() {
        fn refusal(msgs: &[Vec<u8>]) -> Option<u8> {
            msgs.iter()
                .find(|m| m.first() == Some(&S2C_NOTEAM))
                .map(|m| m[1])
        }

        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let (ship, _, mut rx) = seat_rx(&mut a, "one");
        let mine = a.world.state.ships[ship as usize].team;
        let other = u8::from(mine == 0);
        drain(&mut rx);
        let whole = a.world.state.ships[ship as usize].energy;

        // Hurt: whole when the key went down, a round short when it landed.
        a.world.state.ships[ship as usize].energy -= 1;
        assert!(!a.join_team(ship, other), "the core keeps a hurt pilot");
        assert_eq!(
            refusal(&drain(&mut rx)),
            Some(NOTEAM_HURT),
            "and the room says so rather than answering with where they are"
        );

        // Down: crossing hands out a start and a full bar, so a pilot already
        // waiting on one would be taking the better of two respawns.
        let sh = &mut a.world.state.ships[ship as usize];
        sh.energy = whole;
        sh.alive = 0;
        assert!(!a.join_team(ship, other));
        assert_eq!(refusal(&drain(&mut rx)), Some(NOTEAM_DOWN));

        // And a crossing that works says nothing, because the roster it
        // broadcasts is the answer.
        let sh = &mut a.world.state.ships[ship as usize];
        sh.alive = 1;
        sh.energy = whole;
        assert!(a.join_team(ship, other), "whole, alive, and a seat spare");
        assert_eq!(
            refusal(&drain(&mut rx)),
            None,
            "a crossing that happened is not refused"
        );
        assert_eq!(a.world.state.ships[ship as usize].team, other);
    }

    #[test]
    fn a_two_team_zone_still_has_two_teams() {
        // The other half of the same rule: a warzone must not become a
        // free-for-all with two flags in it.
        let mut def = wire_zone(1, 6, 16);
        def.mode = "warzone".into();
        def.zone_toml = "teams = [\"Keel\", \"Vantage\"]\n".into();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&def).expect("a room");
        assert!(!z.rooms[0].free_for_all());
        seat_bots(&mut z.rooms[0], 6);
        let sides: std::collections::HashSet<u8> = z.rooms[0]
            .world
            .state
            .ships
            .iter()
            .filter(|s| s.active != 0)
            .map(|s| s.team)
            .collect();
        assert_eq!(sides.len(), 2, "two sides, whatever the roster says");
    }

    #[test]
    fn the_roster_wire_reads_back_exactly() {
        // Every name anybody sees comes from this one message, and the client
        // walks it with a cursor: a field added here and not there shifts each
        // name after it into gibberish, which a client cannot tell from a room
        // genuinely full of strangers. A reader that stopped short is what once
        // showed a live player DESTROYED forever.
        //
        // So this parses the bytes the way client/arena/net.lua does, from the
        // outside, and insists on landing exactly on the end. Same rule as
        // sim_unpack, for the same reason: stopping short is both wrong and
        // silent.
        let mut z = serving(1, 9, 16);
        seat_bots(&mut z.rooms[0], 3);
        seat(&mut z, 0, 1);
        let a = &z.rooms[0];

        let m = a.roster_msg();
        assert_eq!(m[0], S2C_ROSTER);
        let n = m[1] as usize;
        assert_eq!(n, a.names.len(), "the count has to match what follows it");
        assert!(n >= 2, "the bots and the player we seated");

        // Nineteen bytes of header now, not six: the scores came here when
        // snapshots stopped carrying every seat, and a board reading a seat it
        // can no longer see reads it off this message.
        const HEAD: usize = 13;
        let mut o = 2;
        let mut read: HashMap<u8, (String, u8)> = HashMap::new();
        for _ in 0..n {
            assert!(o + HEAD <= m.len(), "an entry header ran off the end");
            let ship = m[o];
            let label = m[o + 1];
            let _rating = i16::from_le_bytes([m[o + 2], m[o + 3]]);
            let _games = m[o + 4];
            let _team = m[o + 5];
            let _kills = i16::from_le_bytes([m[o + 6], m[o + 7]]);
            let _deaths = u16::from_le_bytes([m[o + 8], m[o + 9]]);
            let _assists = u16::from_le_bytes([m[o + 10], m[o + 11]]);
            let len = m[o + 12] as usize;
            assert!(o + HEAD + len <= m.len(), "a name ran off the end");
            let name = String::from_utf8(m[o + HEAD..o + HEAD + len].to_vec())
                .expect("names are sanitised to printable ascii before they get here");
            o += HEAD + len;
            assert!(
                read.insert(ship, (name, label)).is_none(),
                "ship {ship} twice"
            );
        }
        // The watcher section: count, then label and name per watcher. Walked
        // even when empty, because the count byte is part of the wire and a
        // reader that stops before it lands one short of the end.
        assert!(o < m.len(), "the watcher count byte is missing");
        let wn = m[o] as usize;
        o += 1;
        assert_eq!(wn, a.watchers.len());
        for _ in 0..wn {
            assert!(o + 2 <= m.len(), "a watcher header ran off the end");
            let len = m[o + 1] as usize;
            assert!(o + 2 + len <= m.len(), "a watcher name ran off the end");
            o += 2 + len;
        }
        assert_eq!(o, m.len(), "the reader has to land on the end, not near it");
        let want: HashMap<u8, (String, u8)> = a
            .names
            .iter()
            .map(|(s, k)| (*s, (k.name.clone(), k.label)))
            .collect();
        assert_eq!(read, want, "every name, and what each seat is");
        assert!(
            read.values()
                .any(|(name, l)| name == "p0-0" && *l == token::Label::Unknown.to_byte()),
            "the human we seated is in it, and not labeled a bot"
        );
        assert!(
            read.values()
                .any(|(_, l)| *l == token::Label::ThirdPartyBot.to_byte()),
            "a bot that declared itself without an account is somebody else's"
        );
    }

    /// The bot server reads the same roster, and reads it the same way.
    ///
    /// Held against the writer rather than against a copy of the layout,
    /// because the failure mode is the one the test above is about: a field
    /// added on one side and not the other shifts every row after it, and
    /// the reader cannot tell a shifted row from a real one. A bot with a
    /// scrambled roster would decline the wrong fights silently.
    #[test]
    fn the_bot_server_reads_the_roster_the_arena_writes() {
        let mut z = serving(1, 9, 16);
        let bots = seat_bots(&mut z.rooms[0], 3);
        seat(&mut z, 0, 1);
        let a = &z.rooms[0];

        let mut st = crate::bots::Standings::default();
        st.read(&a.roster_msg());

        for (ship, seat) in &a.names {
            let got = st
                .of(*ship)
                .unwrap_or_else(|| panic!("no row for ship {ship}"));
            assert_eq!(
                got.rating,
                a.rating.rating_of(&seat.rid).round() as i16,
                "the rating for ship {ship}"
            );
            assert_eq!(
                got.games,
                a.rating.games_of(&seat.rid).min(255) as u8,
                "the games for ship {ship}"
            );
            assert_eq!(got.bot, seat.bot, "whether ship {ship} is somebody's AI");
        }
        assert!(
            bots.iter().all(|b| st.of(*b).is_some_and(|s| s.bot)),
            "every seated bot reads back as one"
        );

        // A seat that leaves takes its row with it rather than haunting the
        // table, which is why the read builds fresh instead of merging.
        let gone = *a.names.keys().next().expect("somebody in the room");
        let mut trimmed = crate::bots::Standings::default();
        trimmed.read(&a.roster_msg());
        let mut short = a.roster_msg();
        short[1] = 0;
        trimmed.read(&short[..2]);
        assert!(
            trimmed.of(gone).is_none(),
            "an empty roster empties the table"
        );
    }

    /// A seat whose messages the test keeps, unlike `seat_human`, because
    /// most of what spectating promises is promises about bytes.
    fn seat_rx(a: &mut Room, name: &str) -> (u8, u64, mpsc::Receiver<Message>) {
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        let id = a
            .join(Seat::guest(name.to_string(), false), 0, 32, tx)
            .expect("a seat");
        (a.players[&id].ship, id, rx)
    }

    fn drain(rx: &mut mpsc::Receiver<Message>) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        while let Ok(m) = rx.try_recv() {
            if let Message::Binary(b) = m {
                out.push(b);
            }
        }
        out
    }

    fn snapshots(msgs: &[Vec<u8>]) -> Vec<Vec<u8>> {
        msgs.iter()
            .filter(|m| m.first() == Some(&S2C_SNAPSHOT))
            .cloned()
            .collect()
    }

    /// Put a seat far outside the server's fixed fairness radius.
    fn send_far(a: &mut Room, ship: u8) {
        let sh = &mut a.world.state.ships[ship as usize];
        sh.x = 900 * 16 * 256;
        sh.y = 900 * 16 * 256;
    }

    #[test]
    fn the_fairness_radius_is_the_radar_plus_arrival_margin() {
        assert_eq!(FAIR_INTEREST, 84 * 16 * 256);
    }

    /// A pilot with a crowd around them outgrows a datagram, so the stream
    /// lane carries the ordinary snapshot rather than the rare oversized one.
    ///
    /// This is the fact `UNI_INFLIGHT` is sized against, and it is worth a test
    /// because it changed underneath that constant rather than being decided:
    /// the interest radius was measured when a snapshot was about 900 bytes,
    /// and linked gun volleys put nearly forty rounds inside it. Two permits on
    /// the stream lane then rationed the ordinary case, and a phone on alpha
    /// was ejected every few seconds with "the snapshot stream stalled".
    ///
    /// 1200 bytes is the conservative floor for a QUIC datagram on the open
    /// Internet. A browser usually offers a little more; nothing offers less.
    #[test]
    fn a_pilot_in_a_crowd_outgrows_a_datagram() {
        const DATAGRAM: usize = 1200;
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let (me, _, _rx) = seat_rx(&mut a, "crowded");

        // Bare, the snapshot is nothing: this is the state the old bound was
        // chosen in, and it still fits a datagram with room to spare.
        let mut buf = vec![0u8; sim::PACK_MAX];
        let sh = a.world.state.ships[me as usize];
        let alone =
            a.world
                .pack_around(&mut buf, sh.x, sh.y, crate::delivery::FAIR_INTEREST, me, 0);
        assert!(alone > 0, "a snapshot packs");
        assert!(
            (alone as usize) < DATAGRAM,
            "an empty room already needs a stream: {alone} bytes"
        );

        // A crowd inside the radius, which is what a fight on alpha is.
        let (btx, bty) = (sh.x / (sim::TILE_PX * 256), sh.y / (sim::TILE_PX * 256));
        for i in 0..40i32 {
            a.world.spawn(0, 1, btx + i % 7 - 3, bty + i / 7 - 3, 0);
        }
        let crowded =
            a.world
                .pack_around(&mut buf, sh.x, sh.y, crate::delivery::FAIR_INTEREST, me, 0);
        assert!(
            (crowded as usize) > DATAGRAM,
            "a crowd still fits a datagram at {crowded} bytes, so this test no \
             longer says what UNI_INFLIGHT is for"
        );
    }

    #[test]
    fn a_human_is_not_told_where_the_far_side_of_the_map_is() {
        // The cheating half, as bytes. A snapshot used to carry the position,
        // heading and energy of every ship in the arena to every client, so a
        // maphack was not an exploit, it was a rendering choice. Now a seat
        // outside the radius is absent, and absent is not "zeroed but there":
        // there is no record to read at all.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (near, _, mut rx) = seat_rx(&mut a, "near");
        let far = seat_human(&mut a, "far");
        send_far(&mut a, far);

        let mut buf = vec![0u8; sim::PACK_MAX];
        a.broadcast_snapshot(&mut buf);
        let got = snapshots(&drain(&mut rx));
        let last = got.last().expect("a snapshot arrived");

        let mut w = sim::World::new(1);
        assert!(
            w.apply_snapshot(&last[SNAPSHOT_HEADER..]),
            "the snapshot unpacks"
        );
        assert_eq!(
            w.state.ship_count, a.world.state.ship_count,
            "the seat count is still the arena's, so indices keep meaning"
        );
        assert!(
            w.state.ships[near as usize].active != 0,
            "I am in my own snapshot"
        );
        assert_eq!(
            w.state.ships[far as usize].active, 0,
            "and the far seat is not"
        );
        assert_eq!(
            (w.state.ships[far as usize].x, w.state.ships[far as usize].y),
            (0, 0),
            "with nothing left behind to read a position out of"
        );
    }

    #[test]
    fn a_charge_action_reveals_no_inventory_and_stays_inside_fair_sight() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (shooter, _, mut shooter_rx) = seat_rx(&mut a, "shooter");
        let (near, _, mut near_rx) = seat_rx(&mut a, "near");
        let (far, _, mut far_rx) = seat_rx(&mut a, "far");
        let origin = a.world.state.ships[shooter as usize];
        a.world.state.ships[near as usize].x = origin.x;
        a.world.state.ships[near as usize].y = origin.y;
        send_far(&mut a, far);
        drain(&mut shooter_rx);
        drain(&mut near_rx);
        drain(&mut far_rx);

        a.world.state.ships[shooter as usize].charge[0] = 3;
        a.world.step(&[sim::sim_input {
            ship: shooter,
            buttons: sim::BTN_USE,
        }]);
        a.score_events();

        let near_messages = drain(&mut near_rx);
        let charge = near_messages
            .iter()
            .find(|m| m.first() == Some(&S2C_CHARGE))
            .expect("a nearby observer receives the public action");
        assert_eq!(charge.len(), 15);
        assert_eq!((charge[1], charge[2]), (shooter, 0));
        assert_eq!(
            i32::from_le_bytes(charge[3..7].try_into().unwrap()),
            a.world.state.ships[shooter as usize].x,
        );
        assert!(
            drain(&mut shooter_rx)
                .iter()
                .all(|m| m.first() != Some(&S2C_CHARGE)),
            "the owner already predicts the action",
        );
        assert!(
            drain(&mut far_rx)
                .iter()
                .all(|m| m.first() != Some(&S2C_CHARGE)),
            "the action does not leak beyond fair sight",
        );
        assert_eq!(
            u32::from_le_bytes(charge[11..15].try_into().unwrap()),
            a.world.state.tick,
            "the action names the snapshot that may present it"
        );
        assert_eq!(charge.len(), 15, "no remaining inventory count travels");
    }

    /// An assist is news for one pilot. Everybody in the room reads the death,
    /// and only the seat the core credited reads that they were part of it:
    /// who else was shooting is a fact about somebody's own fight, and a feed
    /// that carried it would tell the room who is working with whom.
    #[test]
    fn an_assist_is_told_to_the_pilot_who_earned_it_and_to_nobody_else() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (finisher, _, mut finisher_rx) = seat_rx(&mut a, "finisher");
        let (helper, _, mut helper_rx) = seat_rx(&mut a, "helper");
        let (victim, _, mut victim_rx) = seat_rx(&mut a, "victim");
        drain(&mut finisher_rx);
        drain(&mut helper_rx);
        drain(&mut victim_rx);

        // The core's report of one death and of the one pilot it handed an
        // assist to, written rather than flown. What is under test here is
        // who the room tells; that the notice and the scoreboard column come
        // from one rule is the core's own test, in sim/tests/test_sim.c.
        a.world.events.count = 2;
        a.world.events.e[0] = sim::sim_event {
            etype: sim::EV_DEATH,
            a: victim,
            b: finisher,
            v: 0,
        };
        a.world.events.e[1] = sim::sim_event {
            etype: sim::EV_ASSIST,
            a: helper,
            b: victim,
            v: finisher as i32,
        };
        // The ledger the rating reads, so the exchange moves three numbers
        // and the private copy has something to say.
        let tick = a.world.state.tick;
        let (vrid, hrid, frid) = (a.rid_of(victim), a.rid_of(helper), a.rid_of(finisher));
        a.rating.damage(tick, &vrid, &hrid, 600, false);
        a.rating.damage(tick, &vrid, &frid, 400, false);
        a.score_events();

        let rated = |rid: &str| a.rating.rating_of(rid).round() as i16;
        let helped = |rx: &mut mpsc::Receiver<Message>| -> (u8, i16) {
            let msgs = drain(rx);
            let m = msgs
                .iter()
                .find(|m| m.first() == Some(&S2C_KILL))
                .expect("the death itself reaches every seat");
            assert_eq!(m.len(), 15, "the kill carries the private bytes");
            assert_eq!((m[1], m[2]), (victim, finisher), "and reads the same");
            (m[12], i16::from_le_bytes([m[13], m[14]]))
        };
        let (h, hr) = helped(&mut helper_rx);
        assert_eq!(h, 1, "the pilot who helped is told");
        assert_eq!(hr, rated(&hrid), "and what it did to their rating");
        assert!(hr > 1200, "which the shared head could not have told them");
        let (f, fr) = helped(&mut finisher_rx);
        assert_eq!(f, 0, "a kill is not also an assist");
        assert_eq!(fr, rated(&frid), "the finisher reads their own rating");
        let (v, vr) = helped(&mut victim_rx);
        assert_eq!(v, 0, "the pilot who died reads a death");
        assert_eq!(vr, rated(&vrid), "and what it cost them");
        assert!(vr < 1200);
        let stands = &a.channel.pending_feed[0];
        assert_eq!(stands[12], 0, "the copy the stands watch claims nothing");
        assert_eq!(&stands[13..15], &[0, 0], "and is rated nothing");
    }

    #[test]
    fn a_round_left_behind_travels_no_further_than_anybody_else_sees_it() {
        // The other half of the same filter. Rounds are cut by distance and
        // nothing else: whose round it is buys no exception, because every
        // round in the game is spent within seconds and near the hull that
        // fired it. The snapshot a pilot who flew off is sent says so.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (me, _, mut rx) = seat_rx(&mut a, "shooter");

        let fired_at = a.world.state.ships[me as usize];
        a.world.step(&[sim::sim_input {
            ship: me,
            buttons: sim::BTN_FIRE,
        }]);
        assert!(a.world.state.weapon_count > 0, "a round is in the world");
        assert_eq!(a.world.state.weapons[0].owner, me, "and it is this pilot's");

        // Off to the far side, well past any radius a client may ask for.
        send_far(&mut a, me);
        let sh = &a.world.state.ships[me as usize];
        let gap = ((sh.x - fired_at.x) as i64).abs();
        assert!(
            gap > FAIR_INTEREST as i64,
            "the pilot is outside fair sight"
        );

        let mut buf = vec![0u8; sim::PACK_MAX];
        a.broadcast_snapshot(&mut buf);
        let got = snapshots(&drain(&mut rx));
        let last = got.last().expect("a snapshot arrived");
        let mut w = sim::World::new(1);
        assert!(
            w.apply_snapshot(&last[SNAPSHOT_HEADER..]),
            "the snapshot unpacks"
        );
        assert_eq!(
            w.state.weapon_count, 0,
            "their own round that far behind them is not in it"
        );
    }

    #[test]
    fn declaring_yourself_a_bot_no_longer_buys_the_whole_map() {
        // The hole this closes. The exemption used to key off `Player::bot`,
        // which is what the client said about itself at join, so anybody could
        // declare from any address and be handed every ship on the map. It
        // keys off the token's label now, which a client cannot assert.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (_, _, mut rx) = seat_rx(&mut a, "claims-to-be-a-bot");
        // Same shape as a third-party bot: declared, and labelled by the token
        // rather than by the claim.
        let id = *a
            .players
            .iter()
            .find(|(_, p)| p.name == "claims-to-be-a-bot")
            .unwrap()
            .0;
        let ship = a.players[&id].ship;
        a.players.get_mut(&id).unwrap().bot = true;
        if let Some(seat) = a.names.get_mut(&ship) {
            seat.bot = true;
            seat.label = token::Label::ThirdPartyBot.to_byte();
        }
        let far = seat_human(&mut a, "far");
        send_far(&mut a, far);

        let mut buf = vec![0u8; sim::PACK_MAX];
        a.broadcast_snapshot(&mut buf);
        let got = snapshots(&drain(&mut rx));
        let last = got.last().expect("a snapshot arrived");
        let mut w = sim::World::new(1);
        assert!(w.apply_snapshot(&last[SNAPSHOT_HEADER..]));
        assert_eq!(
            w.state.ships[far as usize].active, 0,
            "a declared bot is filtered exactly like the person running it"
        );
    }

    #[test]
    fn our_own_bots_are_still_sent_the_whole_room() {
        // The exemption that has to survive: the bot server predicts a room in
        // one world shared by all its pilots, so any one bot's snapshot has to
        // be the whole room's truth. It sits on loopback, so it costs no
        // egress, and the process holding the sight is ours.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (tx, mut rx) = mpsc::channel(OUT_QUEUE);
        let mut seat = Seat::guest("house".to_string(), true);
        seat.label = token::Label::HouseBot.to_byte();
        a.join(seat, 0, 32, tx).expect("a seat");
        let far = seat_human(&mut a, "far");
        send_far(&mut a, far);

        let mut buf = vec![0u8; sim::STATE_PACK_MAX];
        a.broadcast_snapshot(&mut buf);
        let got = snapshots(&drain(&mut rx));
        let last = got.last().expect("a snapshot arrived");
        let mut w = sim::World::new(1);
        assert!(w.apply_snapshot(&last[SNAPSHOT_HEADER..]));
        assert!(
            w.state.ships[far as usize].active != 0,
            "ours sees the whole room"
        );
    }

    #[test]
    fn the_roster_still_scores_a_seat_the_snapshot_leaves_out() {
        // What keeps a scoreboard whole once snapshots stopped being. A client
        // cannot read a far seat's kills out of the simulation any more, so
        // they ride the roster, which already carried every seat in the arena
        // on a slow clock.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let _near = seat_human(&mut a, "near");
        let far = seat_human(&mut a, "far");
        send_far(&mut a, far);
        a.world.state.ships[far as usize].kills = 7;
        a.world.state.ships[far as usize].deaths = 3;
        a.world.state.ships[far as usize].assists = 5;

        let m = a.roster_msg();
        let n = m[1] as usize;
        let mut o = 2;
        let mut found = None;
        for _ in 0..n {
            let ship = m[o];
            let kills = i16::from_le_bytes([m[o + 6], m[o + 7]]);
            let deaths = u16::from_le_bytes([m[o + 8], m[o + 9]]);
            let assists = u16::from_le_bytes([m[o + 10], m[o + 11]]);
            let len = m[o + 12] as usize;
            if ship == far {
                found = Some((kills, deaths, assists));
            }
            o += 13 + len;
        }
        assert_eq!(
            found,
            Some((7, 3, 5)),
            "the far seat's score is on the roster"
        );
    }

    /// Put the camera on a chosen hull and leave it there, so a test about
    /// what a frame contains is not also a test of the picker's dice.
    fn point_camera(a: &mut Room, ship: u8) {
        a.channel.subject = Some(ship);
        a.channel.hold = CHANNEL_HOLD;
    }

    #[test]
    fn the_channels_frame_is_the_subjects_sight_exactly() {
        // Bound sight's whole guarantee, as bytes: what the stands receive is
        // a human-radius pack at the hull the camera is on, and nothing else.
        // If these ever differ, the mode has started leaking.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let target = seat_human(&mut a, "flown");
        let (_, wid, _rx) = seat_rx(&mut a, "watching");
        assert!(a.sit_out(wid, false), "a pilot can sit out");
        point_camera(&mut a, target);

        let mut buf = vec![0u8; sim::PACK_MAX];
        a.broadcast_snapshot(&mut buf);

        let frame = a.channel.ring.back().expect("a frame was packed");
        assert_eq!(frame.subject, target);
        assert_eq!(frame.msg[1], target, "the subject byte names the hull");
        let sh = &a.world.state.ships[target as usize];
        let mut fresh = vec![0u8; sim::PACK_MAX];
        let n = a
            .world
            .pack_around(&mut fresh, sh.x, sh.y, FAIR_INTEREST, 255, 0);
        assert!(n > 0);
        assert_eq!(
            &frame.msg[SNAPSHOT_HEADER..],
            &fresh[..n as usize],
            "byte for byte"
        );
    }

    #[test]
    fn the_channel_does_not_restore_the_old_160_tile_disclosure() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let target = seat_human(&mut a, "flown");
        let (_, wid, _rx) = seat_rx(&mut a, "watching");
        let hidden = seat_human(&mut a, "hidden");
        let center = a.world.state.ships[target as usize];
        a.world.state.ships[hidden as usize].x = center.x + 120 * 16 * 256;
        a.world.state.ships[hidden as usize].y = center.y;
        assert!(a.sit_out(wid, false));
        point_camera(&mut a, target);

        let mut buf = vec![0u8; sim::PACK_MAX];
        a.broadcast_snapshot(&mut buf);
        let frame = a.channel.ring.back().expect("a frame was packed");
        let mut view = sim::World::new(1);
        assert!(view.apply_snapshot(&frame.msg[SNAPSHOT_HEADER..]));
        assert_eq!(
            view.state.ships[hidden as usize].active, 0,
            "a ship inside the old 160-tile ceiling but outside fair sight stays hidden",
        );
    }

    #[test]
    fn a_bot_subject_never_puts_its_whole_room_stream_on_the_channel() {
        // The camera lands on bots: an empty-handed room has nobody else to
        // point at. A bot is sent the whole room, and sight must not be
        // inheritable, or the one seat that sees everything becomes a door.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let bots = seat_bots(&mut a, 1);
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        point_camera(&mut a, bots[0]);

        let mut buf = vec![0u8; sim::PACK_MAX];
        a.broadcast_snapshot(&mut buf);
        let frame = a.channel.ring.back().expect("a frame was packed");
        let sh = &a.world.state.ships[bots[0] as usize];
        let mut fresh = vec![0u8; sim::PACK_MAX];
        let n = a
            .world
            .pack_around(&mut fresh, sh.x, sh.y, FAIR_INTEREST, 255, 0);
        assert_eq!(
            &frame.msg[SNAPSHOT_HEADER..],
            &fresh[..n as usize],
            "human radius, always"
        );
    }

    #[test]
    fn the_stands_are_one_feed_whoever_is_in_them() {
        // Shared is the whole security model. Nobody in the gallery has a view
        // of their own to aim, so there is no lever to pull until a victim
        // comes up: a pilot who sat out from the far side, a pilot who sat out
        // from the camera's own side, and a stranger who walked in to watch
        // are all served the same bytes. And none of them moves the world.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let shown = seat_human(&mut a, "shown");
        let (mate, mid, mut mate_rx) = seat_rx(&mut a, "mate");
        let (other, oid, mut other_rx) = seat_rx(&mut a, "other");
        a.world.state.ships[mate as usize].team = a.world.state.ships[shown as usize].team;
        a.world.state.ships[other as usize].team = 1 - a.world.state.ships[shown as usize].team;
        assert!(a.sit_out(mid, false));
        assert!(a.sit_out(oid, false));
        let (tx, mut stranger_rx) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("stranger", false), tx).unwrap();
        point_camera(&mut a, shown);
        // These pilots send no inputs, and the run below is longer than the
        // ladder's patience for that. Being benched mid-test would empty the
        // room the camera is pointed at.
        a.lag_policy.spectate_silence_ticks = u32::MAX;

        let h0 = a.world.hash();
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..(CHANNEL_DELAY / SNAPSHOT_EVERY + 2) {
            for _ in 0..SNAPSHOT_EVERY {
                a.tick();
            }
            a.broadcast_snapshot(&mut buf);
        }
        assert_ne!(a.world.hash(), h0, "the room ran");

        // Identical but for the one field the fan-out patches per watcher:
        // the lifecycle, which says which of this socket's lives the frame
        // belongs to and is nobody else's business.
        let served = |rx: &mut mpsc::Receiver<Message>| -> Vec<Vec<u8>> {
            snapshots(&drain(rx))
                .into_iter()
                .map(|mut m| {
                    m[3..7].fill(0);
                    m
                })
                .collect()
        };
        let mine = served(&mut mate_rx);
        assert!(!mine.is_empty(), "the ring warmed up and served");
        assert_eq!(
            mine,
            served(&mut other_rx),
            "the far side sees exactly what the near side does"
        );
        assert_eq!(
            mine,
            served(&mut stranger_rx),
            "and so does somebody who never flew here"
        );

        let h1 = a.world.hash();
        a.broadcast_snapshot(&mut buf);
        assert_eq!(a.world.hash(), h1, "watching is read-only on the world");
    }

    #[test]
    fn the_channel_runs_five_seconds_behind_wherever_it_is() {
        // Not a dial any more. A zone that could turn the delay down could
        // turn the protection off, and the one that set zero did it because
        // its audience was the mode; the shared feed answers that without
        // handing anybody a fresh map of the room.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        seat_human(&mut a, "flown");
        let (tx, mut rx) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("one", false), tx).unwrap();
        a.lag_policy.spectate_silence_ticks = u32::MAX;

        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..(CHANNEL_DELAY / SNAPSHOT_EVERY + 2) {
            for _ in 0..SNAPSHOT_EVERY {
                a.tick();
            }
            a.broadcast_snapshot(&mut buf);
        }

        let served = snapshots(&drain(&mut rx));
        assert!(!served.is_empty(), "the ring warmed up and served");
        for m in &served {
            let frame = u32::from_le_bytes(
                m[SNAPSHOT_HEADER..SNAPSHOT_HEADER + 4]
                    .try_into()
                    .expect("snapshot tick"),
            );
            assert!(
                frame + CHANNEL_DELAY <= a.world.state.tick,
                "a served frame is at least five seconds behind the room: \
                 frame {frame}, now {}",
                a.world.state.tick
            );
        }
    }

    /// Every match message a stream carried, oldest first, as the seconds its
    /// clock read.
    fn clocks(msgs: &[Vec<u8>]) -> Vec<u8> {
        msgs.iter()
            .filter(|m| m.first() == Some(&S2C_MATCH))
            .map(|m| m[2])
            .collect()
    }

    #[test]
    fn the_clock_the_stands_read_belongs_to_the_frame_under_it() {
        // The fault this fixes, as it was reported: watching a match, the last
        // five seconds ticked away over ships still fighting, and the
        // death that ended the match arrived under a clock already counting
        // the next one down. The picture ran five seconds behind and the
        // clock over it did not.
        let mut a = match_room(60, 4);
        let (_, _pid, mut cockpit_rx) = seat_rx(&mut a, "pilot");
        let (tx, mut stands_rx) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        // Nobody here sends input, and this runs well past the ladder's
        // patience for that. See `spectate_silence_ticks`.
        a.lag_policy.spectate_silence_ticks = u32::MAX;

        // Drained every pass rather than at the end: an output queue holds
        // forty and drops the rest, so a whole run read afterward is the
        // opening seconds of it.
        let mut cockpit: Vec<u8> = Vec::new();
        let mut stands: Vec<u8> = Vec::new();
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..(CHANNEL_DELAY / SNAPSHOT_EVERY * 2) {
            for _ in 0..SNAPSHOT_EVERY {
                a.tick();
            }
            a.broadcast_snapshot(&mut buf);
            cockpit.extend(clocks(&drain(&mut cockpit_rx)));
            stands.extend(clocks(&drain(&mut stands_rx)));
        }

        assert!(stands.len() > 1, "the ring warmed up and served the clock");
        assert_eq!(
            stands,
            cockpit[..stands.len()],
            "the stands read the same clock the cockpit did, later"
        );
        let delay = (CHANNEL_DELAY / modes::TICKS_PER_SECOND) as u8;
        assert_eq!(
            *stands.last().expect("a clock in the stands"),
            *cockpit.last().expect("a clock in the cockpit") + delay,
            "and it is behind by exactly the delay on the picture"
        );
    }

    #[test]
    fn the_ground_the_stands_are_given_is_the_one_their_frames_are_packed_on() {
        // A whistle changes the map and bumps the settings generation. Sent
        // live, both landed five seconds before the frames they described,
        // and a client refuses a snapshot whose generation is not the one it
        // holds: a rotation blanked the stands for the whole delay, and the
        // seconds before it were drawn on the wrong ground.
        let mut a = match_room(1, 1);
        seat_human(&mut a, "pilot");
        let (_, wid, mut rx) = seat_rx(&mut a, "gallery");
        assert!(a.sit_out(wid, false), "a pilot can sit out");
        a.lag_policy.spectate_silence_ticks = u32::MAX;

        let mut seen: Vec<Vec<u8>> = drain(&mut rx);
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..(CHANNEL_DELAY / SNAPSHOT_EVERY * 3) {
            for _ in 0..SNAPSHOT_EVERY {
                a.tick();
            }
            a.broadcast_snapshot(&mut buf);
            seen.extend(drain(&mut rx));
        }

        let mut holding: Option<u32> = None;
        let (mut frames, mut rotations) = (0, 0);
        for m in &seen {
            match m.first() {
                Some(&S2C_SETTINGS) => {
                    let g = u32::from_le_bytes(m[1..5].try_into().expect("a generation"));
                    if holding.is_some_and(|had| had != g) {
                        rotations += 1;
                    }
                    holding = Some(g);
                }
                Some(&S2C_SNAPSHOT) => {
                    let g = u32::from_le_bytes(m[7..11].try_into().expect("a generation"));
                    assert_eq!(
                        Some(g),
                        holding,
                        "a frame packed under rules the stands were not holding yet"
                    );
                    frames += 1;
                }
                _ => {}
            }
        }
        assert!(rotations > 0, "the ground changed while they watched");
        assert!(frames > 0, "and they were served frames across it");
    }

    #[test]
    fn a_seat_taken_from_the_stands_comes_with_the_ground_the_room_is_on() {
        // The landing joins by watching the channel and then asking for a
        // hull on the same socket, and the channel runs CHANNEL_DELAY behind
        // the room. A whistle inside that window changed the map and the
        // generation for everybody in a hull while the stands were still
        // being shown the last match. The seat used to come with a welcome
        // and nothing else, so a pilot who pressed deploy in those seconds
        // held the old ground and flew the new match on its walls.
        let mut a = match_room(60, 4);
        seat_human(&mut a, "pilot");
        let (tx, mut rx) = mpsc::channel(OUT_QUEUE);
        let wid = a
            .watch_join(Seat::guest("deploy", false), tx)
            .expect("a place in the stands");
        a.lag_policy.spectate_silence_ticks = u32::MAX;

        // Long enough for the stands to hold a served copy of the ground.
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..(CHANNEL_DELAY / SNAPSHOT_EVERY * 2) {
            for _ in 0..SNAPSHOT_EVERY {
                a.tick();
            }
            a.broadcast_snapshot(&mut buf);
            drain(&mut rx);
        }

        let stale_map = a.map_msg();
        let stale_generation = a.settings_generation;
        a.close_match();
        assert_ne!(a.map_msg(), stale_map, "the whistle changed the ground");
        assert_ne!(
            a.settings_generation, stale_generation,
            "and the generation"
        );

        // One frame into the window: the stands are still shown the old match.
        for _ in 0..SNAPSHOT_EVERY {
            a.tick();
        }
        a.broadcast_snapshot(&mut buf);
        let shown = drain(&mut rx);
        assert!(
            !shown.iter().any(|m| m.first() == Some(&S2C_MAP)),
            "the channel has not served the new ground yet"
        );

        a.fly(wid, 0, 8).expect("a seat on the field");
        let got = drain(&mut rx);
        let map_at = got
            .iter()
            .position(|m| m.first() == Some(&S2C_MAP))
            .expect("the seat comes with the map");
        assert_eq!(got[map_at], a.map_msg(), "and it is the map the room is on");
        assert!(
            got.iter()
                .any(|m| m.first() == Some(&protocol::S2C_MAPNAME)),
            "with its name"
        );
        let settings_at = got
            .iter()
            .position(|m| m.first() == Some(&S2C_SETTINGS))
            .expect("and the rules");
        let generation =
            u32::from_le_bytes(got[settings_at][1..5].try_into().expect("a generation"));
        assert_eq!(
            generation, a.settings_generation,
            "under the generation the frames to come are packed under"
        );
        let welcome_at = got
            .iter()
            .position(|m| m.first() == Some(&S2C_WELCOME))
            .expect("a welcome");
        assert!(
            map_at < welcome_at && settings_at < welcome_at,
            "ground and rules before the welcome, the way the door hands them out"
        );
    }

    #[test]
    fn the_door_to_the_stands_hands_out_the_clock_the_channel_is_showing() {
        // Somebody arriving used to be set up from the live room and then
        // served a five second old picture, so their first seconds in the
        // stands disagreed with themselves.
        let mut a = match_room(60, 4);
        seat_human(&mut a, "pilot");
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("first", false), tx).unwrap();
        a.lag_policy.spectate_silence_ticks = u32::MAX;

        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..(CHANNEL_DELAY / SNAPSHOT_EVERY * 2) {
            for _ in 0..SNAPSHOT_EVERY {
                a.tick();
            }
            a.broadcast_snapshot(&mut buf);
        }

        let live = a.match_msg().expect("a match zone has a clock");
        let door = a.channel_sync();
        let shown = door
            .iter()
            .find(|m| m.first() == Some(&S2C_MATCH))
            .expect("the door hands out a clock");
        let delay = (CHANNEL_DELAY / modes::TICKS_PER_SECOND) as u8;
        assert_eq!(
            shown[2],
            live[2] + delay,
            "the door's clock is the one over the picture, not the one in the room"
        );
        assert!(
            door.iter().any(|m| m.first() == Some(&S2C_MAP)),
            "and the ground that picture is packed on"
        );
    }

    #[test]
    fn watchers_enter_presence_without_moving_the_counts_the_room_polices() {
        let mut z = serving(1, 9, 16);
        seat(&mut z, 0, 2);
        let a = &mut z.rooms[0];
        let humans = a.humans();
        let bots_wanted = a.bots_wanted();
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        assert_eq!(a.humans(), humans, "not a human in the cap's sense");
        assert_eq!(a.bots_wanted(), bots_wanted, "and no ballast moves for one");
        assert_eq!(z.total_players(), 2, "the flying count stays put");
        assert_eq!(
            z.status().spectators,
            1,
            "the public presence includes them"
        );
    }

    #[test]
    fn sitting_out_and_flying_again_is_a_despawn_and_a_spawn() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (ship, id, mut rx) = seat_rx(&mut a, "pilot");
        let presence = a.players[&id].presence.clone();
        assert_eq!(
            presence.current(),
            Presence::Flying {
                room: a.number,
                member: id,
            }
        );
        assert!(a.sit_out(id, false));
        assert_eq!(
            presence.current(),
            Presence::Watching {
                room: a.number,
                member: id,
            }
        );
        assert_eq!(
            a.world.state.ships[ship as usize].active, 0,
            "the hull despawned"
        );
        assert_eq!(a.humans(), 0);
        assert!(a.names.is_empty(), "the seat is genuinely empty");

        a.renumber(4);
        assert_eq!(
            presence.current(),
            Presence::Watching {
                room: 4,
                member: id,
            },
            "a live connection follows its stable room number",
        );
        let new_id = a.fly(id, 0, 16).expect("a seat was free");
        assert_eq!(new_id, id, "the connection keeps one member id");
        assert_eq!(
            presence.current(),
            Presence::Flying {
                room: 4,
                member: id,
            }
        );
        assert_eq!(a.humans(), 1);
        assert!(a.watchers.is_empty(), "the watcher row went with the spawn");

        // The client is told which of its two lives each is: welcome 255 on
        // the way out, welcome with a ship on the way back.
        let welcomes: Vec<u8> = drain(&mut rx)
            .iter()
            .filter(|m| m.first() == Some(&S2C_WELCOME))
            .map(|m| m[1])
            .collect();
        assert_eq!(welcomes.first(), Some(&255));
        assert_eq!(*welcomes.last().unwrap(), a.players[&new_id].ship);
    }

    /// The reference arena with a patch of safe floor in the middle of it, and
    /// the tile the tests park on. A `fn` rather than a closure because that is
    /// what `with_map` takes: the map is built once, before anything holds it.
    const SAFE_TILE: i32 = 256;
    fn safe_patch(m: &mut sim::sim_map) {
        sim::build_arena(m);
        for ty in (SAFE_TILE as usize - 4)..(SAFE_TILE as usize + 5) {
            for tx in (SAFE_TILE as usize - 4)..(SAFE_TILE as usize + 5) {
                m.tile[ty * sim::MAP_TILES + tx] = 2; // SIM_TILE_SAFE
            }
        }
    }

    /// Parking in a safe zone costs the seat.
    ///
    /// A safe zone is the one place nothing can reach you and you cannot shoot
    /// out of, so a pilot sitting in one is holding a seat in a capped room at
    /// no risk to themselves and no cost to anybody but the person at the door.
    /// The room moves them to the stands rather than disconnecting them.
    ///
    /// The three things worth pinning are the eviction, that leaving resets the
    /// clock rather than pausing it, and that bots are exempt: a room that
    /// evicted its own population would empty itself of the thing it is filled
    /// with.
    #[test]
    fn sitting_in_a_safe_zone_costs_the_seat() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        // A map with somewhere safe to sit. Swapped in before anybody is
        // seated, since the ships live in the world being replaced.
        a.world = sim::World::with_map(1, safe_patch);
        a.world.cfg.safe_limit = 10;
        let (tx, ty) = (SAFE_TILE, SAFE_TILE);
        let mid = |t: i32| (t * sim::TILE_PX + sim::TILE_PX / 2) * 256;

        let ship = seat_human(&mut a, "parked");
        let id = *a.players.iter().find(|(_, p)| p.ship == ship).unwrap().0;
        {
            let sh = &mut a.world.state.ships[ship as usize];
            sh.x = mid(tx);
            sh.y = mid(ty);
            sh.vx = 0;
            sh.vy = 0;
        }
        for _ in 0..8 {
            a.sweep_safe();
            // The hull does not move: sweep_safe is the only thing under test
            // and a real tick would fly it out of the tile it is parked on.
            let sh = &mut a.world.state.ships[ship as usize];
            sh.x = mid(tx);
            sh.y = mid(ty);
        }
        assert!(a.players.contains_key(&id), "eight of ten is still flying");
        assert_eq!(a.players[&id].safe, 8, "and the clock is running");

        // Out for one tick, and the whole thing starts over.
        a.world.state.ships[ship as usize].x = mid(tx + 8);
        a.sweep_safe();
        assert_eq!(a.players[&id].safe, 0, "leaving resets rather than pauses");

        // Long enough to be sure, rather than exactly the limit: the point is
        // that it happens, and pinning the off-by-one would be pinning the
        // loop this test is written around rather than the rule.
        let mut changed = false;
        for _ in 0..30 {
            let sh = &mut a.world.state.ships[ship as usize];
            sh.x = mid(tx);
            sh.y = mid(ty);
            changed |= a.sweep_safe();
        }
        assert!(changed, "the room reports the population change");
        assert!(!a.players.contains_key(&id), "the seat went back");
        assert!(a.watchers.contains_key(&id), "and they are in the stands");
    }

    #[tokio::test]
    async fn a_safe_zone_spectator_can_take_the_same_hull_back() {
        let zone = Arc::new(Mutex::new(serving(1, 6, 16)));
        let (in_tx, inbound) = mpsc::channel(INBOUND_QUEUE);
        let (out_tx, mut outbound) = mpsc::channel(OUT_QUEUE);
        let task = tokio::spawn(serve_client(zone.clone(), inbound, out_tx, "test"));

        let name = b"parked";
        let zone_name = b"testzone";
        let mut join = vec![
            C2S_JOIN,
            0,
            CLIENT_PROTOCOL,
            0,
            zone_name.len() as u8,
            name.len() as u8,
            0,
        ];
        join.extend_from_slice(zone_name);
        join.extend_from_slice(name);
        in_tx
            .send(join)
            .await
            .expect("the join reaches the socket task");

        let first = loop {
            let message = tokio::time::timeout(std::time::Duration::from_secs(1), outbound.recv())
                .await
                .expect("the join is answered")
                .expect("the connection stays open");
            let Message::Binary(bytes) = message else {
                continue;
            };
            if bytes.first() == Some(&S2C_WELCOME) {
                break bytes;
            }
        };
        assert_ne!(first[1], 255, "the pilot starts in a hull");

        let id = {
            let mut z = zone.lock().await;
            let id = *z.rooms[0].players.keys().next().expect("the joined pilot");
            assert!(
                z.rooms[0].sit_out(id, true),
                "the safe-zone sweep moves it to the stands",
            );
            id
        };

        let watching = loop {
            let message = tokio::time::timeout(std::time::Duration::from_secs(1), outbound.recv())
                .await
                .expect("the sweep is announced")
                .expect("the connection stays open");
            let Message::Binary(bytes) = message else {
                continue;
            };
            if bytes.first() == Some(&S2C_WELCOME) && bytes[1] == 255 {
                break bytes;
            }
        };

        // Class zero is exactly what the pilot had before the sweep. The old
        // socket state swallowed this first request and only a later watcher
        // message made another class work.
        in_tx
            .send(vec![C2S_SHIP, 0])
            .await
            .expect("the same hull request reaches the socket task");
        let returned = loop {
            let message = tokio::time::timeout(std::time::Duration::from_secs(1), outbound.recv())
                .await
                .expect("taking a hull is answered")
                .expect("the connection stays open");
            let Message::Binary(bytes) = message else {
                continue;
            };
            if bytes.first() == Some(&S2C_WELCOME) && bytes[1] != 255 {
                break bytes;
            }
        };

        {
            let z = zone.lock().await;
            let room = &z.rooms[0];
            assert!(!room.watchers.contains_key(&id), "the watcher row is gone");
            let player = room
                .players
                .values()
                .next()
                .expect("the pilot is flying again");
            assert_eq!(
                room.world.state.ships[player.ship as usize].cls, 0,
                "the same hull was accepted",
            );
            assert_eq!(returned[1], player.ship, "the welcome names the new seat");
        }

        let life = |message: &[u8]| u32::from_le_bytes(message[2..6].try_into().unwrap());
        assert_eq!(life(&first), 1);
        assert_eq!(life(&watching), 2);
        assert_eq!(life(&returned), 3);

        drop(in_tx);
        task.await.expect("the socket task exits cleanly");
    }

    #[tokio::test]
    async fn a_transport_failure_runs_the_same_cleanup_as_a_disconnect() {
        let zone = Arc::new(Mutex::new(serving(1, 6, 16)));
        let (in_tx, inbound) = mpsc::channel(INBOUND_QUEUE);
        let (out_tx, mut outbound) = mpsc::channel(OUT_QUEUE);
        let task = tokio::spawn(serve_client(zone.clone(), inbound, out_tx, "test"));
        let name = b"vanishing";
        let zone_name = b"testzone";
        let mut join = vec![
            C2S_JOIN,
            0,
            CLIENT_PROTOCOL,
            0,
            zone_name.len() as u8,
            name.len() as u8,
            0,
        ];
        join.extend_from_slice(zone_name);
        join.extend_from_slice(name);
        in_tx.send(join).await.unwrap();
        loop {
            let Message::Binary(message) = outbound.recv().await.unwrap() else {
                continue;
            };
            if message.first() == Some(&S2C_WELCOME) {
                break;
            }
        }
        assert_eq!(zone.lock().await.total_players(), 1);

        in_tx.send(Vec::new()).await.unwrap();
        task.await.expect("the connection handler exits");
        assert_eq!(zone.lock().await.total_players(), 0);
    }

    #[test]
    fn a_bot_may_sit_in_a_safe_zone_forever() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        a.world = sim::World::with_map(1, safe_patch);
        a.world.cfg.safe_limit = 5;
        let (tx_t, ty_t) = (SAFE_TILE, SAFE_TILE);
        let mid = |t: i32| (t * sim::TILE_PX + sim::TILE_PX / 2) * 256;
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        std::mem::forget(rx);
        let id = a
            .join(Seat::guest("vX-9".to_string(), true), 0, 32, tx)
            .expect("a seat");
        let ship = a.players[&id].ship;
        for _ in 0..50 {
            let sh = &mut a.world.state.ships[ship as usize];
            sh.x = mid(tx_t);
            sh.y = mid(ty_t);
            a.sweep_safe();
        }
        assert!(
            a.players.contains_key(&id),
            "the room asks for a bot's seat when a human wants it, not on a timer"
        );
    }

    #[test]
    fn a_room_full_of_watchers_refuses_the_next_one() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        a.max_watchers = 1;
        let (tx, _r1) = mpsc::channel(OUT_QUEUE);
        assert!(a.watch_join(Seat::guest("one", false), tx).is_some());
        let (tx, _r2) = mpsc::channel(OUT_QUEUE);
        assert!(
            a.watch_join(Seat::guest("two", false), tx).is_none(),
            "the cap is a bandwidth number and it holds"
        );
    }

    #[test]
    fn sitting_out_needs_the_same_full_bar_as_a_hull_change() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (ship, id, _rx) = seat_rx(&mut a, "wounded");
        let full = a.world.eff_max_energy(ship as usize);
        a.world.state.ships[ship as usize].energy = full - 1;
        assert!(!a.sit_out(id, false), "a wounded pilot keeps the hull");
        assert!(a.players.contains_key(&id));
        assert!(!a.watchers.contains_key(&id));

        a.world.state.ships[ship as usize].energy = full;
        assert!(a.sit_out(id, false), "a whole pilot may sit out");
    }

    #[test]
    fn sitting_out_counts_against_the_watcher_limit() {
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        a.max_watchers = 1;
        let (tx, _keep) = mpsc::channel(OUT_QUEUE);
        a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        let (_, id, _rx) = seat_rx(&mut a, "pilot");
        assert!(!a.sit_out(id, false));
        assert!(
            a.players.contains_key(&id),
            "the cap refuses without despawning"
        );
        assert_eq!(a.watchers.len(), 1);
    }

    #[test]
    fn the_tally_means_somebody_is_looking_not_that_a_camera_is_pointed() {
        // The distinction this pins is the whole of what the mark is worth. A
        // channel with no audience still picks a subject and still fills its
        // ring, because a watcher arriving should land in a warm picture; a
        // pilot alone in that room is being seen by nobody and must be told
        // nothing. And the channel runs behind, so being picked is seconds
        // away from being shown.
        let mut a = room_with_teams("teams = [\"Keel\"]\n");
        let (ship, _, mut rx) = seat_rx(&mut a, "starred");
        // Warming the ring takes longer than the lag ladder's patience with a
        // pilot who sends nothing, and a benched pilot is no camera subject.
        a.lag_policy.spectate_silence_ticks = u32::MAX;
        let mut buf = vec![0u8; sim::PACK_MAX];

        // Drained as we go: the outbound queue is bounded and drops rather
        // than waits, so a test that only looked at the end would be reading
        // whatever survived instead of what was sent.
        let mut said: Vec<u8> = Vec::new();
        let mut run =
            |a: &mut Room, rx: &mut mpsc::Receiver<Message>, said: &mut Vec<u8>, n: usize| {
                for _ in 0..n {
                    for _ in 0..SNAPSHOT_EVERY {
                        a.tick();
                    }
                    a.broadcast_snapshot(&mut buf);
                    for m in drain(rx) {
                        if m.first() == Some(&S2C_ONAIR) {
                            said.push(m[1]);
                        }
                    }
                }
            };

        // Long enough for the ring to warm and start serving.
        run(
            &mut a,
            &mut rx,
            &mut said,
            (CHANNEL_DELAY / SNAPSHOT_EVERY) as usize + 2,
        );
        assert_eq!(a.channel.subject, Some(ship), "the camera did pick them");
        assert_eq!(
            a.channel.showing,
            Some(ship),
            "and the ring is serving them"
        );
        assert!(a.on_air.is_empty(), "but there is no audience");
        assert!(said.is_empty(), "so they were told nothing: {said:?}");

        // Somebody arrives on the channel.
        let (tx, _keep) = mpsc::channel(OUT_QUEUE);
        let w = a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        run(&mut a, &mut rx, &mut said, 5);
        assert!(a.on_air.contains(&ship), "now somebody is looking");
        assert_eq!(said, vec![1], "told once, on the edge");

        // And leaves.
        assert!(a.leave_watcher(w));
        run(&mut a, &mut rx, &mut said, 5);
        assert!(a.on_air.is_empty());
        assert_eq!(said, vec![1, 0], "and told once when it stopped");
    }

    #[test]
    fn a_watcher_is_told_which_side_is_theirs() {
        // A watcher's screen is colored from their own side, so a watcher who
        // does not know it reads every hull in the room as an enemy's. Walked
        // the way client/arena/net.lua walks it, and landing on the end.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let (ship, id, _rx) = seat_rx(&mut a, "sat-out");
        let mine = a.world.state.ships[ship as usize].team;
        assert!(a.sit_out(id, false));

        let m = a.watcher_teams_msg(&a.watchers[&id]);
        assert_eq!(m[0], S2C_TEAMS);
        assert_eq!(m[1], mine, "the side they were on when they sat out");
        assert_eq!(m[2], 0, "and no founding from the gallery");
        let count = m[3] as usize;
        let mut o = 4;
        for _ in 0..count {
            assert_eq!(m[o + 2], 0, "no door is open to a watcher");
            let len = m[o + 5] as usize;
            o += 6 + len;
        }
        assert_eq!(o, m.len(), "the reader lands on the end, not near it");

        // And somebody who arrived to watch gets the same message with a real
        // side in it, because they were seated on one at the door.
        let (tx, _keep) = mpsc::channel(OUT_QUEUE);
        let w = a.watch_join(Seat::guest("stranger", false), tx).unwrap();
        let theirs = a.watcher_teams_msg(&a.watchers[&w])[1];
        assert!(a.teams.get(&theirs).is_some_and(|t| t.public));
    }

    #[test]
    fn arriving_to_watch_seats_you_the_way_arriving_to_fly_does() {
        // Reported from Alpha: joining as a spectator left you off the sides
        // entirely, while joining in a hull and then sitting out kept the side
        // you were on. Two doors into the same room, two different answers to
        // "whose side am I on", and the one the spectator got made every hull
        // in the room read as an enemy's.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let one = seat_human(&mut a, "one");
        let taken = a.world.state.ships[one as usize].team;

        let (tx, _keep) = mpsc::channel(OUT_QUEUE);
        let w = a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        let side = a.watchers[&w]
            .team
            .expect("a side, the same as any arrival");
        assert!(
            a.teams[&side].public,
            "one of the zone's own, not a private one"
        );
        assert_ne!(
            side, taken,
            "the emptier one, which is how a pilot lands too"
        );
        // And they weigh nothing while they sit there: a watcher holds no seat,
        // so the balance the caps measure cannot see them.
        assert_eq!(a.team_census(side, None), (0, 0));
    }

    #[test]
    fn a_free_for_all_still_seats_a_watcher_nowhere() {
        // The one room where having no side is the truth rather than a hole:
        // every pilot is a private side of one, so there is nothing to share
        // and the channel is the whole of what anybody watching can see.
        let mut a = room_with_teams("teams = []\n");
        assert!(a.free_for_all());
        seat_human(&mut a, "flying");
        let (tx, _keep) = mpsc::channel(OUT_QUEUE);
        let w = a.watch_join(Seat::guest("gallery", false), tx).unwrap();
        assert_eq!(a.watchers[&w].team, None);
        assert_eq!(a.watcher_teams_msg(&a.watchers[&w])[1], 255);
    }

    #[test]
    fn taking_a_hull_again_lands_you_back_on_the_side_you_watched_with() {
        // Sitting out and flying again used to move you across the room: `fly`
        // went through the same seating an arrival gets, so it re-picked the
        // emptiest side and the side you had spent the last minute watching
        // with counted for nothing.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
        let (ship, id, _rx) = seat_rx(&mut a, "pilot");
        // On the second side, which is the one a fresh arrival into this room
        // would not pick: a tie goes to the first.
        a.world.state.ships[ship as usize].team = 1;

        assert!(a.sit_out(id, false));
        assert_eq!(a.watchers[&id].team, Some(1));
        assert_eq!(
            a.seat_team(ship, &Seat::guest("pilot", false)),
            0,
            "what a re-pick would have said"
        );

        let new_id = a.fly(id, 0, 16).expect("a seat was free");
        let back = a.players[&new_id].ship;
        assert_eq!(a.world.state.ships[back as usize].team, 1, "their own side");
    }

    #[test]
    fn a_side_that_filled_up_while_you_watched_does_not_refuse_you_the_room() {
        // The preference is a preference. A watcher whose side took on its last
        // permitted pilot while they sat there is still somebody who wants to
        // fly, so the seating falls back to the ordinary rule rather than
        // holding them in the gallery.
        let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\nmax_humans_per_team = 1\n");
        let (ship, id, _rx) = seat_rx(&mut a, "pilot");
        let mine = a.world.state.ships[ship as usize].team;
        assert!(a.sit_out(id, false));

        let taker = seat_human(&mut a, "taker");
        assert_eq!(
            a.world.state.ships[taker as usize].team, mine,
            "their chair"
        );

        let new_id = a.fly(id, 0, 16).expect("a seat was free");
        let back = a.players[&new_id].ship;
        assert_ne!(
            a.world.state.ships[back as usize].team, mine,
            "the other side"
        );
    }

    #[test]
    fn a_zone_can_ask_for_claimed_pilots() {
        let mut z = serving_with_accounts();
        assert!(
            !z.wants_claimed(),
            "a public room admits anybody, which is the default"
        );
        if let Some(c) = z.catalog.as_mut() {
            c.zones[0].admission = "claimed".into();
        }
        let def = z.catalog.as_ref().unwrap().zones[0].clone();
        z.serve_zone(&def).expect("a room");
        assert!(z.wants_claimed());
        // The bar is on the label, so it is on the account rather than on
        // anything the client said about itself.
        let guest = z
            .identify(
                &a_token(token::Kind::Human, false, "Talon 3", vec![]),
                "",
                false,
                &pilot::Session::new("ws"),
            )
            .expect("verifies");
        assert_eq!(guest.label, token::Label::Unknown.to_byte());
        let claimed = z
            .identify(
                &a_token(token::Kind::Human, true, "Vesper 47", vec![]),
                "",
                false,
                &pilot::Session::new("ws"),
            )
            .expect("verifies");
        assert_eq!(claimed.label, token::Label::Human.to_byte());
    }

    #[test]
    fn only_a_certified_ladder_can_seed_accounts_beyond_the_anchor() {
        assert_eq!(
            calibrated_rating(ai::ANCHOR),
            Some(ai::ANCHOR_RATING),
            "the anchor is a definition, not a measurement"
        );
        for (name, _, _) in ai::CALIBRATED {
            if name != ai::ANCHOR {
                assert_eq!(
                    calibrated_rating(name),
                    None,
                    "{name} has no certified prior in the checked-in seed"
                );
            }
        }
        // The roster is longer than the calibrated group, and the rest earn
        // their number in play.
        let generated = ai::individual(ai::CALIBRATED.len());
        assert!(calibrated_rating(&generated.name).is_none());

        let synthetic = HashMap::from([("Kestrel".to_string(), 1042.5)]);
        assert_eq!(
            crate::arena::calibrated_rating_from("Kestrel", &synthetic),
            Some(1042.5),
            "an authored pilot reads its measured prior"
        );
    }

    #[test]
    fn a_settled_pilot_is_still_settled_in_a_fresh_process() {
        // The bug this covers outlived the file it was found in: a rating
        // restored without its game count reads as placing, and the pilot's
        // next death moves them by a newcomer's K. The record now arrives in
        // the token rather than from a file beside the process, so the same
        // property is asserted against the thing that carries it.
        let mut z = serving_with_accounts();
        let t = a_token_for(
            77,
            token::Kind::Human,
            true,
            "Veteran",
            vec![token::ClassRating {
                class: "testzone".into(),
                rating: 1640.0,
                games: 40,
            }],
        );
        let seat = z
            .identify(&t, "", false, &pilot::Session::new("ws"))
            .expect("verifies");
        let rid = seat.rid.clone();
        assert_eq!(z.rooms[0].rating.games_of(&rid), 0, "not until they join");
        z.restore_pilot(0, &seat);
        assert_eq!(z.rooms[0].rating.rating_of(&rid), 1640.0);
        assert_eq!(z.rooms[0].rating.games_of(&rid), 40);
        assert!(
            z.rooms[0].rating.tier_of(&rid).is_some(),
            "a settled pilot is shown a tier, not 'placing'"
        );
    }

    #[test]
    fn a_rated_death_between_accounts_is_handed_off() {
        let d = std::env::temp_dir().join(format!("vw-handoff-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let spools = spool::Spools::open(d.to_str().unwrap());
        spools.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        let sp = spools.rated.clone();

        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, spools, HashMap::new());
        z.serve_zone(&wire_zone(1, 6, 16)).expect("a room");
        let a = &mut z.rooms[0];
        a.accounts.insert("a1".into(), 1);
        a.accounts.insert("a2".into(), 2);

        a.hand_off(
            &rating::RatedEvent {
                tick: 100,
                victim: "a2".into(),
                victim_before: 1200.0,
                victim_after: 1184.0,
                credits: vec![("a1".into(), 1.0, 1200.0, 1216.0)],
            },
            Some("a1"),
        );
        {
            let s = sp.lock().unwrap();
            assert_eq!(s.len(), 1, "both had accounts, so the event travels");
            assert_eq!(s.last().and_then(|event| event.killer), Some(1));
        }

        // A guest contributes nothing durable, because there is nobody to file
        // it against. The event is dropped rather than sent half-formed.
        a.hand_off(
            &rating::RatedEvent {
                tick: 200,
                victim: "a2".into(),
                victim_before: 1184.0,
                victim_after: 1170.0,
                credits: vec![("some guest".into(), 1.0, 1200.0, 1214.0)],
            },
            Some("some guest"),
        );
        // And a guest victim is not an event at all: the negative half of the
        // exchange has nowhere to land.
        a.hand_off(
            &rating::RatedEvent {
                tick: 300,
                victim: "another guest".into(),
                victim_before: 1200.0,
                victim_after: 1184.0,
                credits: vec![("a1".into(), 1.0, 1200.0, 1216.0)],
            },
            Some("a1"),
        );
        assert_eq!(
            sp.lock().unwrap().len(),
            1,
            "neither half-formed event travelled"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn only_a_death_with_no_person_in_it_is_marked_droppable() {
        // Retention deletes on this one flag and nothing else, so getting it
        // backwards would either fill the disk it exists to protect or quietly
        // expire the human careers a model migration replays.
        let d = std::env::temp_dir().join(format!("vw-botsonly-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let spools = spool::Spools::open(d.to_str().unwrap());
        spools.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        let sp = spools.rated.clone();

        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, spools, HashMap::new());
        z.serve_zone(&wire_zone(1, 6, 16)).expect("a room");
        let a = &mut z.rooms[0];
        for (rid, account) in [("bot1", 1u64), ("bot2", 2), ("human", 3)] {
            a.accounts.insert(rid.into(), account);
        }
        a.rating.mark_bot("bot1");
        a.rating.mark_bot("bot2");

        let ev = |victim: &str, killer: &str| rating::RatedEvent {
            tick: 100,
            victim: victim.into(),
            victim_before: 1200.0,
            victim_after: 1184.0,
            credits: vec![(killer.into(), 1.0, 1200.0, 1216.0)],
        };
        let flag_of = |sp: &std::sync::Arc<std::sync::Mutex<spool::Spool<spool::Event>>>| {
            sp.lock().unwrap().last().expect("an event").bots_only
        };

        a.hand_off(&ev("bot2", "bot1"), Some("bot1"));
        assert!(flag_of(&sp), "machines all the way down, so it may expire");

        a.hand_off(&ev("bot2", "human"), Some("human"));
        assert!(
            !flag_of(&sp),
            "a person did the killing, so the row is a career"
        );

        a.hand_off(&ev("human", "bot1"), Some("bot1"));
        assert!(
            !flag_of(&sp),
            "a person did the dying, which counts the same"
        );

        // The case the loop could get wrong: one human buried in a crowd of
        // machines is still a human, and an `all` that stopped at the first
        // bot would drop the row that proves it.
        a.hand_off(
            &rating::RatedEvent {
                tick: 400,
                victim: "bot2".into(),
                victim_before: 1200.0,
                victim_after: 1184.0,
                credits: vec![
                    ("bot1".into(), 0.5, 1200.0, 1208.0),
                    ("human".into(), 0.5, 1200.0, 1208.0),
                ],
            },
            Some("human"),
        );
        assert!(!flag_of(&sp), "one person among the machines keeps the row");
        let _ = std::fs::remove_dir_all(&d);
    }

    // ---- the pilot log -------------------------------------------------

    /// An arena with both spools armed at an address nothing answers on, so
    /// rows are written and never drained. Returns the zone and the pilot
    /// spool to read back.
    fn logging_arena(
        name: &str,
    ) -> (
        ArenaServer,
        std::sync::Arc<std::sync::Mutex<spool::Spool<pilot::Event>>>,
        std::path::PathBuf,
    ) {
        let d = std::env::temp_dir().join(format!("vw-pilotlog-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let spools = spool::Spools::open(d.to_str().unwrap());
        spools.aim("http://127.0.0.1:1", "tok", "chaos", "arena", "i1");
        let pilots = spools.pilots.clone();
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, spools, HashMap::new());
        z.serve_zone(&wire_zone(1, 6, 16)).expect("a room");
        (z, pilots, d)
    }

    /// Every row filed so far, oldest first.
    fn rows(p: &std::sync::Arc<std::sync::Mutex<spool::Spool<pilot::Event>>>) -> Vec<pilot::Event> {
        let s = p.lock().unwrap();
        (0..s.len()).filter_map(|i| s.nth(i).cloned()).collect()
    }

    fn kinds(evs: &[pilot::Event]) -> Vec<&str> {
        evs.iter().map(|e| e.kind.as_str()).collect()
    }

    /// The five ways a seat can end were one funnel with no reason on it, so
    /// afterwards a quit and a kick were the same absence. This is the whole
    /// point of the log, so it is the first thing asserted.
    #[test]
    fn a_departure_records_which_kind_it_was() {
        let (mut z, pilots, d) = logging_arena("why");
        let cap = z.max_players();
        let a = &mut z.rooms[0];

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let quitter = a.join(Seat::guest("Quitter", false), 0, cap, tx).unwrap();
        a.leave(quitter, pilot::why::LEFT);

        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let kicked = a.join(Seat::guest("Kicked", false), 0, cap, tx).unwrap();
        a.leave(kicked, pilot::why::KICKED);

        // A bot's seat taken back for somebody at the door, which is the room
        // deciding rather than the pilot.
        seat_bots(a, 1);
        a.evict_bot().expect("a bot to evict");

        let filed = rows(&pilots);
        let departures: Vec<(&str, &str)> = filed
            .iter()
            .filter(|e| e.kind == pilot::LEAVE)
            .map(|e| {
                (
                    e.name.as_str(),
                    e.detail.get("why").and_then(|v| v.as_str()).unwrap_or(""),
                )
            })
            .collect();
        assert_eq!(
            departures,
            vec![
                ("Quitter", pilot::why::LEFT),
                ("Kicked", pilot::why::KICKED),
                (ai::individual(0).name.as_str(), pilot::why::EVICTED),
            ],
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// One connection is one session through every lifecycle state. Sitting
    /// out retires the simulation seat, but the room member id and log session
    /// both remain stable when the pilot flies again.
    #[test]
    fn a_stay_keeps_one_session_across_sitting_out() {
        let (mut z, pilots, d) = logging_arena("session");
        let cap = z.max_players();
        let a = &mut z.rooms[0];
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        std::mem::forget(rx);
        let id = a.join(Seat::guest("Wanderer", false), 0, cap, tx).unwrap();

        assert!(a.sit_out(id, false), "gives up the hull");
        let back = a.fly(id, 1, cap).expect("and takes one again");
        assert_eq!(back, id, "the connection keeps one room member id");
        a.leave(back, pilot::why::LEFT);

        let filed = rows(&pilots);
        assert_eq!(
            kinds(&filed),
            vec![
                pilot::JOIN,
                pilot::SIT_OUT,
                pilot::LEAVE,
                pilot::FLY,
                pilot::LEAVE
            ],
            "the sit-out files its own row and the departure it is made of",
        );
        let one: std::collections::HashSet<&str> =
            filed.iter().map(|e| e.session.as_str()).collect();
        assert_eq!(one.len(), 1, "all of it is one stay");
        assert!(filed.iter().all(|e| e.name == "Wanderer"));
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The core refuses a hull change for anyone dead or short of a full bar
    /// and says nothing about it. Only what took effect is a row, or the log
    /// would mostly hold hurt pilots pressing a key that did nothing.
    #[test]
    fn only_a_hull_change_that_happened_is_written_down() {
        let (mut z, pilots, d) = logging_arena("ship");
        let cap = z.max_players();
        let a = &mut z.rooms[0];
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = a.join(Seat::guest("Swapper", false), 0, cap, tx).unwrap();
        let ship = a.players[&id].ship;

        // Hurt, so the core will not swap them.
        a.world.state.ships[ship as usize].energy = 1;
        let was = a.world.state.ships[ship as usize].cls;
        a.world.set_ship_class(ship, 3, None);
        assert_eq!(
            a.world.state.ships[ship as usize].cls, was,
            "refused, as set up"
        );

        let filed = rows(&pilots);
        assert_eq!(
            kinds(&filed),
            vec![pilot::JOIN],
            "the refusal is not an event"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A guest has no account, and the row still has to be worth keeping: the
    /// call sign is the only handle they have.
    #[test]
    fn a_guest_is_logged_under_a_name_and_no_account() {
        let (mut z, pilots, d) = logging_arena("guest");
        let cap = z.max_players();
        let a = &mut z.rooms[0];
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        a.join(Seat::guest("Pilot 12", false), 0, cap, tx).unwrap();

        let filed = rows(&pilots);
        assert_eq!(filed.len(), 1);
        assert_eq!(filed[0].pilot, None, "no account to file it against");
        assert_eq!(filed[0].name, "Pilot 12");
        assert_eq!(
            filed[0].room,
            Some(a.number),
            "the number, not the list position"
        );
        assert!(
            filed[0].at > 1_700_000_000_000,
            "stamped by the arena, in millis"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A room with nowhere to send writes nothing at all, which is the same
    /// off switch the rated spool has. It also must not spend a session's
    /// budget while doing it.
    #[test]
    fn without_a_meta_layer_the_log_is_silent() {
        let (cfg, _) = config::ConfigWatcher::load("/nonexistent/zone.toml");
        let mut z = ArenaServer::new(cfg, test_spool(), HashMap::new());
        z.serve_zone(&wire_zone(1, 6, 16)).expect("a room");
        let cap = z.max_players();
        let seat = Seat::guest("Nobody", false);
        let session = seat.session.clone();
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0].join(seat, 0, cap, tx).unwrap();
        z.rooms[0].leave(id, pilot::why::LEFT);
        assert_eq!(z.spools.pilots.lock().unwrap().len(), 0);
        assert_eq!(session.filed(), 0, "and no allowance was spent on nothing");
    }

    /// A pilot arrives with their hull's rack full, and a whistle fills it
    /// again.
    ///
    /// Both are moments the design says fill a rack, and both go through
    /// `deal_seat`. It dealt the frame without the ammunition, and because
    /// `join` builds a seat by hand rather than through `sim_spawn` and clears
    /// the counts on the way, nothing put them back: every pilot flew every
    /// match with no charges at all, dim in the corner and doing nothing when
    /// the key was pressed.
    ///
    /// Read off the simulation rather than a message, because what a client
    /// draws is what the snapshot carries and what the snapshot carries is
    /// this.
    #[test]
    fn a_pilot_arrives_with_their_hull_s_rack_and_a_whistle_fills_it_again() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vane\"]\n");
        let (ship, _, _rx) = seat_rx(&mut a, "Arrival");

        // Whatever this hull carries, off the same table the roster is written
        // in, so the test does not pin a tuning number a balance pass moves.
        let cls = a.world.state.ships[ship as usize].cls;
        let profile = a.world.profile(cls);
        let want: Vec<u8> = (0..sim::MAX_CHARGES)
            .map(|k| profile[sim::slot_charge(k) as usize])
            .collect();
        assert!(
            want.iter().any(|n| *n > 0),
            "the hull under test carries no charges, so this proves nothing"
        );

        let held: Vec<u8> = a.world.state.ships[ship as usize].charge.to_vec();
        assert_eq!(held, want, "a pilot arrives with their hull's rack");

        // Spent, then a whistle. The rack comes back because a match start is
        // the other moment that fills one.
        for k in 0..sim::MAX_CHARGES {
            a.world.state.ships[ship as usize].charge[k] = 0;
        }
        a.close_match();
        a.open_match();
        let after: Vec<u8> = a.world.state.ships[ship as usize].charge.to_vec();
        assert_eq!(after, want, "and a whistle fills it again");

        // And a death does not, which is the rule the refill is bounded by: a
        // pilot who has spent both repels flies the rest of the match without
        // them and cannot reload by dying. A respawn is the core's own path
        // and deals the frame alone, which is what this asks for directly:
        // driving a real death here would need a step loop and would be
        // asking the same question through more machinery.
        for k in 0..sim::MAX_CHARGES {
            a.world.state.ships[ship as usize].charge[k] = 0;
        }
        a.world.deal_kit(ship as usize, false);
        let after_death: Vec<u8> = a.world.state.ships[ship as usize].charge.to_vec();
        assert!(
            after_death.iter().all(|n| *n == 0),
            "a respawn must not refill the rack, got {after_death:?}"
        );
    }

    /// A pilot joins a room, reads back what the room sent them the way a
    /// client reads it, and spends a charge.
    ///
    /// This is the seam two shipped bugs came through, and both were invisible
    /// to the tests either side of it. The room's own tests assert what the
    /// room holds; the client's tests stub the simulation and assert what a
    /// stubbed one answers. Nothing joined a room, took the bytes it sent, and
    /// read them back with the core the client links.
    ///
    /// So this does the client's half in Rust. The map, the settings and the
    /// snapshot go through the same three unpack calls the client makes, in
    /// the same order, and the body offsets are read out of the client's own
    /// source rather than written down here. A header that moves on one side
    /// and not the other is what a join hang is made of.
    ///
    /// One of the two is beyond it: a C export deleted with a Lua caller still
    /// on it, which no amount of Rust can see. `constant_drift_test.lua`
    /// guards that side.
    #[test]
    fn a_pilot_joins_reads_the_wire_and_spends_a_charge() {
        let mut a = room_with_teams("teams = [\"Keel\", \"Vane\"]\n");
        // A match already running when this pilot arrives, which is both the
        // ordinary way to join a busy arena and the case the shipped bug
        // lived in. A whistle deals every seat in the room, so a pilot who
        // arrives on one is dealt twice and the second deal covers for the
        // first; a pilot who walks into a match in progress is dealt once,
        // and that once is the only chance their rack has to be filled.
        // Their receiver is held rather than dropped, because a closed queue
        // is a refused send and a room reads that as a client owed the map.
        let (_, _, _bystander) = seat_rx(&mut a, "Bystander");
        a.open_match();
        let (me, id, mut rx) = seat_rx(&mut a, "Arrival");
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..8 {
            a.tick();
        }
        a.broadcast_snapshot(&mut buf);
        let msgs = drain(&mut rx);

        // The ground and the tuning as the door hands them out. `Room::join`
        // seats a pilot; the socket around it sends these two, through these
        // same accessors, before the first snapshot goes anywhere.
        let map_msg = a.map_msg();
        let settings_msg = a.settings_msg();
        assert_eq!(map_msg.first(), Some(&S2C_MAP));
        assert_eq!(settings_msg.first(), Some(&S2C_SETTINGS));
        // Addressed to this seat. A snapshot names its subject in byte two,
        // and a room sends one per recipient.
        let snap = msgs
            .iter()
            .find(|m| m.first() == Some(&S2C_SNAPSHOT) && m.get(1) == Some(&me))
            .expect("the room sent this seat no snapshot")
            .clone();

        // Where each body begins, read off the client rather than asserted
        // here. `net.lua` slices both, and if it starts slicing somewhere else
        // this test wants to know before a player does.
        let client = std::fs::read_to_string("../client/arena/net.lua")
            .or_else(|_| std::fs::read_to_string("client/arena/net.lua"))
            .expect("the client's net.lua, which this test reads its offsets from");
        let body_at = |after: &str, what: &str| -> usize {
            let at = client
                .find(after)
                .unwrap_or_else(|| panic!("cannot find the client's {what} in net.lua"));
            let tail = &client[at + after.len()..];
            let digits: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
            let one_based: usize = digits
                .parse()
                .unwrap_or_else(|_| panic!("the client's {what} is not a number"));
            one_based - 1
        };
        // `local body = string.sub(s, 33)` and `sim.apply_settings(string.sub(s, 6))`.
        let snap_body = body_at("local body = string.sub(s, ", "snapshot body offset");
        let settings_body = body_at("sim.apply_settings(string.sub(s, ", "settings body offset");

        // The gate that drops a snapshot in silence: a client keeps the
        // generation the settings arrived under and ignores every snapshot
        // that does not carry it. Disagreeing here is a join that hangs with
        // no error anywhere.
        let u32_at = |m: &[u8], at: usize| -> u32 {
            u32::from_le_bytes([m[at], m[at + 1], m[at + 2], m[at + 3]])
        };
        assert_eq!(
            u32_at(&settings_msg, 1),
            u32_at(&snap, 7),
            "the settings generation and the snapshot's disagree, so a client \
             would drop every snapshot without saying why"
        );

        // The client's half now, through the core the client links.
        let mut seen = sim::World::from_packed(1, &map_msg[1..]).expect("the room's map");
        assert!(
            seen.apply_settings(&settings_msg[settings_body..]),
            "the room's settings did not unpack"
        );
        assert!(
            seen.apply_snapshot(&snap[snap_body..]),
            "the room's snapshot did not unpack"
        );

        // What a pilot who just joined is actually holding.
        let sh = &seen.state.ships[me as usize];
        assert_eq!(sh.active, 1, "the seat is occupied");
        assert_eq!(sh.alive, 1, "and alive");
        assert!(sh.energy > 0, "with a bar");

        let profile = seen.profile(sh.cls);
        let want: Vec<u8> = (0..sim::MAX_CHARGES)
            .map(|k| profile[sim::slot_charge(k) as usize])
            .collect();
        assert!(
            want.iter().any(|n| *n > 0),
            "the hull under test carries no charges, so this proves nothing"
        );
        assert_eq!(
            sh.charge.to_vec(),
            want,
            "a pilot arrives holding their hull's rack, and the snapshot says so"
        );

        // And can spend one.
        let kind = (0..sim::MAX_CHARGES)
            .find(|k| want[*k] > 0)
            .expect("a kind to spend");
        let before = a.world.state.ships[me as usize].charge[kind];
        for _ in 0..24 {
            let now = a.world.state.tick.wrapping_add(1);
            if let Some(p) = a.players.get_mut(&id) {
                p.schedule(now, sim::btn_charge(kind), now);
            }
            a.tick();
            if a.world.state.ships[me as usize].charge[kind] < before {
                break;
            }
        }
        assert!(
            a.world.state.ships[me as usize].charge[kind] < before,
            "pressing the charge key spent nothing: held {before}, still {}",
            a.world.state.ships[me as usize].charge[kind]
        );
    }

    /// Combat is the story of a session, and the log left it out for a day:
    /// a join and a leave with an hour of silence between them. A death files
    /// a row for each pilot in it, machines included, because a roster
    /// individual is an account with a career.
    #[test]
    fn a_death_is_two_rows_for_every_pilot_in_it() {
        let (mut z, pilots, d) = logging_arena("death");
        let cap = z.max_players();
        let a = &mut z.rooms[0];
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let hunter = a.join(Seat::guest("Hunter", false), 0, cap, tx).unwrap();
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let prey = a.join(Seat::guest("Prey", false), 0, cap, tx).unwrap();
        let (hs, ps) = (a.players[&hunter].ship, a.players[&prey].ship);
        let bots = seat_bots(a, 2);

        a.note_death(ps, hs, 119);
        let filed = rows(&pilots);
        let combat: Vec<(&str, &str)> = filed
            .iter()
            .filter(|e| e.kind == pilot::DIED || e.kind == pilot::KILL)
            .map(|e| (e.kind.as_str(), e.name.as_str()))
            .collect();
        assert_eq!(combat, vec![("died", "Prey"), ("kill", "Hunter")]);
        assert_eq!(
            filed.iter().find(|e| e.kind == pilot::DIED).unwrap().detail["by"],
            "Hunter",
        );

        a.note_death(bots[0], bots[1], 59);
        let with_bots = rows(&pilots);
        assert_eq!(
            with_bots.len(),
            filed.len() + 2,
            "a machine's death is a row and so is the kill that took it"
        );
        assert!(
            with_bots[with_bots.len() - 1].bot && with_bots[with_bots.len() - 2].bot,
            "and both are marked as machines, which is what keeps them out \
             of the week's table"
        );
        let filed = with_bots;

        // A self-kill is a death and a misfire, and the misfire is filed
        // against the pilot who threw it, which is the same pilot. Not a
        // kill: crediting the victim with their own destruction would say
        // it twice.
        a.note_death(hs, hs, 0);
        let after = rows(&pilots);
        assert_eq!(after.len(), filed.len() + 2);
        assert_eq!(
            (
                after[after.len() - 2].kind.as_str(),
                after[after.len() - 2].name.as_str()
            ),
            ("died", "Hunter"),
        );
        assert_eq!(
            (
                after.last().unwrap().kind.as_str(),
                after.last().unwrap().name.as_str()
            ),
            ("misfire", "Hunter"),
        );
        assert_eq!(
            after.last().unwrap().detail["own"],
            serde_json::json!(true),
            "and it says whose hull it was"
        );
        let filed = after;

        // And a teammate's death is the same mistake pointed at somebody
        // else. It filed a `kill` paying nothing before, which the week's
        // table counted as a kill.
        let team = a.world.state.ships[hs as usize].team;
        a.world.state.ships[ps as usize].team = team;
        a.note_death(ps, hs, 0);
        let after = rows(&pilots);
        assert_eq!(after.len(), filed.len() + 2);
        assert_eq!(
            (
                after.last().unwrap().kind.as_str(),
                after.last().unwrap().name.as_str()
            ),
            ("misfire", "Hunter"),
        );
        assert_eq!(
            after.last().unwrap().detail["own"],
            serde_json::json!(false),
            "somebody else's, this time"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A converge used to cut every open session's story short: the join was
    /// on file and the departure never happened, because a killed process
    /// runs no socket cleanup. The stop path writes them all down, and it
    /// does not settle anybody's fight as a quit on the way, because the
    /// process leaving is not the pilot leaving.
    #[test]
    fn a_restart_files_every_departure_without_charging_a_quit() {
        let (mut z, pilots, d) = logging_arena("restart");
        let cap = z.max_players();
        let a = &mut z.rooms[0];
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let id = a.join(Seat::guest("Bystander", false), 0, cap, tx).unwrap();
        let ship = a.players[&id].ship;
        // Mid-fight when the deploy lands: alive, nearly dead, ledger hot.
        a.rating
            .damage(a.world.state.tick, "Bystander", "Somebody", 500, false);
        a.world.state.ships[ship as usize].energy = 1;

        z.file_departures();
        let filed = rows(&pilots);
        let end = filed
            .iter()
            .find(|e| e.kind == pilot::LEAVE)
            .expect("a departure on file");
        assert_eq!(end.detail["why"], pilot::why::RESTART);
        assert_eq!(
            end.detail["quit_loss"], false,
            "a deploy is not the pilot quitting a fight",
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// One pilot cannot make the fleet's database grow without bound. Sitting
    /// out and flying again is free and can be done in a loop, so the ceiling
    /// is on the connection rather than on any one thing it does.
    #[test]
    fn one_connection_cannot_file_without_limit() {
        let (mut z, pilots, d) = logging_arena("cap");
        let cap = z.max_players();
        let a = &mut z.rooms[0];
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        std::mem::forget(rx);
        let mut id = a.join(Seat::guest("Loop", false), 0, cap, tx).unwrap();
        for _ in 0..pilot::PER_SESSION {
            assert!(a.sit_out(id, false));
            id = a.fly(id, 0, cap).expect("a seat is still there");
        }
        let filed = rows(&pilots);
        assert_eq!(
            filed.len(),
            pilot::PER_SESSION as usize,
            "the loop is bounded at the cap, not by how long somebody keeps going",
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_room_fills_before_a_second_one_opens() {
        // Rung one: the fullest room below cap. A room holding four of a target
        // of six wants the next arrival, not a sibling with nobody in it.
        let mut z = serving(4, 6, 16);
        assert_eq!(z.rooms.len(), 1, "one room to start");
        for _ in 0..6 {
            let i = z.room_for_join().expect("room");
            assert_eq!(
                i, 0,
                "everything lands in the first room until it hits target"
            );
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 1, "still one room at exactly the target");

        // The seventh is the first arrival every room could refuse to concentrate.
        let i = z.room_for_join().expect("room");
        assert_eq!(i, 1, "so a second room opens for them");
        assert_eq!(z.rooms.len(), 2);
    }

    /// A room's number is its own, and it keeps it while it lives.
    ///
    /// Every one of these was true of the position in the list too, right up
    /// until a room was reclaimed, which is the whole reason a number exists.
    #[test]
    fn a_room_number_survives_the_room_below_it_closing() {
        let mut z = serving(4, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(
            numbers(&z),
            vec![1, 2, 3],
            "dense, in the order they opened"
        );
        let third = z
            .rooms
            .iter()
            .position(|r| r.number == 3)
            .expect("room three");
        let third_id = *z.rooms[third].players.keys().next().expect("its pilot");
        let third_presence = z.rooms[third].players[&third_id].presence.clone();
        // Empty the middle one and let it go.
        let mid = z
            .rooms
            .iter()
            .position(|r| r.number == 2)
            .expect("room two");
        let ids: Vec<u64> = z.rooms[mid].players.keys().copied().collect();
        for id in ids {
            z.rooms[mid].leave(id, pilot::why::LEFT);
        }
        z.reclaim_rooms();
        assert_eq!(numbers(&z), vec![1, 3], "the survivors keep their names");
        // And the position of room three has moved under it, which is exactly
        // what a join keyed on position would get wrong.
        assert_eq!(
            z.rooms.iter().position(|r| r.number == 3),
            Some(1),
            "room three sits where room two used to"
        );
        assert_eq!(
            third_presence.current(),
            Presence::Flying {
                room: 3,
                member: third_id,
            }
        );
        assert!(
            z.rooms[1].players.contains_key(&third_id),
            "the stable member address still reaches the shifted room",
        );
    }

    #[test]
    fn a_room_with_a_watcher_is_not_reclaimed() {
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let second = z.room_for_join().expect("a second room");
        seat(&mut z, second, 1);
        let number = z.rooms[second].number;
        let id = *z.rooms[second].players.keys().next().expect("the pilot");
        assert!(z.rooms[second].sit_out(id, false));

        z.reclaim_rooms();

        assert!(
            z.rooms.iter().any(|room| room.number == number),
            "watching is still membership in the room",
        );
    }

    #[test]
    fn a_freed_number_is_handed_out_again_lowest_first() {
        // Dense on purpose. A zone that has run all day should still be
        // offering room two rather than room ninety.
        let mut z = serving(4, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        let mid = z
            .rooms
            .iter()
            .position(|r| r.number == 2)
            .expect("room two");
        let ids: Vec<u64> = z.rooms[mid].players.keys().copied().collect();
        for id in ids {
            z.rooms[mid].leave(id, pilot::why::LEFT);
        }
        z.reclaim_rooms();
        let i = z.room_for_join().expect("room");
        seat(&mut z, i, 1);
        assert_eq!(numbers(&z), vec![1, 3, 2], "two comes back before four");
    }

    #[test]
    fn a_named_room_is_a_request_and_never_a_refusal() {
        let mut z = serving(3, 1, 2);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(numbers(&z), vec![1, 2, 3]);
        // Asking for one that exists and has a seat gets it.
        let i = z.room_wanted(3).expect("room three");
        assert_eq!(z.rooms[i].number, 3);
        // Fill it, and the same ask is answered by the ladder rather than
        // turned away: the player asked to play, and named a room to say it.
        seat(&mut z, i, 1);
        let i = z.room_wanted(3).expect("somewhere");
        assert_ne!(z.rooms[i].number, 3, "room three is full");
        // A number nothing here holds is the same kind of miss.
        assert!(
            z.room_wanted(99).is_some(),
            "a stale number still seats you"
        );
        // And zero is what an arrival that was never shown a list says.
        assert!(z.room_wanted(0).is_some());
    }

    #[test]
    fn two_instances_settle_a_number_without_speaking() {
        // Both opened a room inside one status window and both chose two.
        // Neither asks the other anything; each applies the same rule to the
        // ids they already hold, and only the larger moves.
        let mut z = serving(4, 1, 16);
        z.fleet.instance = "bbbb".into();
        // Twice: the first arrival fills the room that already exists, and only
        // an arrival meeting a room at its target opens another.
        for _ in 0..2 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(numbers(&z), vec![1, 2]);
        z.fleet.views.insert(
            "dir".into(),
            fleet::View {
                instances: vec![fleet::Observed {
                    instance: "aaaa".into(),
                    zone: z.zone_name.clone(),
                    rooms: vec![
                        fleet::RoomView {
                            number: 1,
                            ..Default::default()
                        },
                        fleet::RoomView {
                            number: 2,
                            ..Default::default()
                        },
                    ],
                    ..Default::default()
                }],
                ..Default::default()
            },
        );
        z.settle_room_numbers();
        assert_eq!(numbers(&z), vec![3, 4], "the larger id moved off both");

        // The other side of the same collision does nothing at all.
        let mut y = serving(4, 1, 16);
        y.fleet.instance = "aaaa".into();
        for _ in 0..2 {
            let i = y.room_for_join().expect("room");
            seat(&mut y, i, 1);
        }
        y.fleet.views.insert(
            "dir".into(),
            fleet::View {
                instances: vec![fleet::Observed {
                    instance: "bbbb".into(),
                    zone: y.zone_name.clone(),
                    rooms: vec![
                        fleet::RoomView {
                            number: 1,
                            ..Default::default()
                        },
                        fleet::RoomView {
                            number: 2,
                            ..Default::default()
                        },
                    ],
                    ..Default::default()
                }],
                ..Default::default()
            },
        );
        y.settle_room_numbers();
        assert_eq!(numbers(&y), vec![1, 2], "the smaller id keeps what it had");
    }

    #[test]
    fn a_new_room_dodges_the_numbers_the_rest_of_the_fleet_is_using() {
        let mut z = serving(4, 1, 16);
        z.fleet.instance = "zzzz".into();
        z.fleet.views.insert(
            "dir".into(),
            fleet::View {
                instances: vec![fleet::Observed {
                    instance: "aaaa".into(),
                    zone: z.zone_name.clone(),
                    rooms: vec![fleet::RoomView {
                        number: 2,
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            },
        );
        // The first room this instance holds already took one, so the fleet's
        // two is only dodged by the room that opens next.
        assert_eq!(numbers(&z), vec![1], "one was free and is ours");
        let mut opened = 0;
        for _ in 0..2 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
            opened = z.rooms[i].number;
        }
        assert_eq!(opened, 3, "two belongs to another instance of this zone");
    }

    #[test]
    fn the_status_lists_the_rooms_rather_than_counting_them() {
        let mut z = serving(3, 1, 2);
        for _ in 0..2 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        // Fill the first, so one row says full and the other does not.
        let first = z
            .rooms
            .iter()
            .position(|r| r.number == 1)
            .expect("room one");
        seat(&mut z, first, 1);
        let st = z.status();
        assert_eq!(st.rooms.len(), 2);
        let one = st.rooms.iter().find(|r| r.number == 1).expect("one");
        assert!(one.full, "two of two seats");
        let two = st.rooms.iter().find(|r| r.number == 2).expect("two");
        assert!(!two.full);
        assert_eq!(two.players, 1);
    }

    #[test]
    fn the_room_ceiling_holds_and_players_stack_past_the_target() {
        // `max_rooms` is a ceiling, not a target: once it is reached the fill
        // target stops mattering and rooms take players up to `max_players`.
        let mut z = serving(2, 2, 5);
        for _ in 0..10 {
            let Some(i) = z.room_for_join() else { break };
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 2, "never a third room");
        assert_eq!(z.total_players(), 10, "two rooms of five");
        assert!(z.status().capped, "and the instance says so");
        assert_eq!(z.room_for_join(), None, "the eleventh is sent elsewhere");
    }

    #[test]
    fn an_emptied_room_goes_back_but_never_the_first() {
        let mut z = serving(3, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 3, "a target of one grows a room per player");

        // Empty the last two. The first stays whatever happens: an instance
        // serving a zone always has a room, or it is not an instance of it.
        for r in 1..3 {
            let ids: Vec<u64> = z.rooms[r].players.keys().copied().collect();
            for id in ids {
                z.rooms[r].leave(id, pilot::why::LEFT);
            }
        }
        z.reclaim_rooms();
        assert_eq!(z.rooms.len(), 1, "the empty ones are given back");

        let ids: Vec<u64> = z.rooms[0].players.keys().copied().collect();
        for id in ids {
            z.rooms[0].leave(id, pilot::why::LEFT);
        }
        z.reclaim_rooms();
        assert_eq!(z.rooms.len(), 1, "and the first survives being empty");
    }

    #[test]
    fn every_room_runs_the_same_game() {
        // Rooms differing would make which room you landed in matter, which is
        // the one thing the fill ladder is allowed to decide for a player.
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let i = z.room_for_join().expect("a second room");
        assert_eq!(i, 1);
        assert_eq!(
            z.rooms[0].world.cfg.max_ships,
            z.rooms[1].world.cfg.max_ships
        );
        assert_eq!(z.rooms[0].public_teams, z.rooms[1].public_teams);
        assert_eq!(
            z.rooms[0].bot_fill, z.rooms[1].bot_fill,
            "including how full of bots each is meant to be"
        );
        assert_eq!(z.rooms[0].world.packed_map(), z.rooms[1].world.packed_map());
        // The same tiles, not a copy of them. A megabyte per room would make
        // `max_rooms` a memory limit rather than the blast-radius limit it is
        // meant to be, and would put the per-room figure in hosting.md out by
        // a factor of thirteen.
        assert!(
            std::sync::Arc::ptr_eq(&z.rooms[0].world.map, &z.rooms[1].world.map),
            "rooms of one zone share one map"
        );
        // Two references a room: the entry in the list of maps its zone
        // rotates through, and the one its world is currently playing on.
        // Nothing else may hold one, which is the property this number is
        // here to pin.
        assert_eq!(
            std::sync::Arc::strong_count(&z.rooms[0].world.map),
            2 * z.rooms.len(),
            "one list entry and one world a room, and no copies"
        );
    }

    #[test]
    fn a_hundred_rooms_share_one_map() {
        // What M7.5 asks for: a small-room zone grows to its ceiling in one
        // process, and the geometry is paid for once.
        let mut z = serving(100, 1, 2);
        for _ in 0..100 {
            let Some(i) = z.room_for_join() else { break };
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 100, "the ceiling is reachable");
        assert_eq!(z.total_players(), 100);
        let map = z.rooms[0].world.map.clone();
        for (n, r) in z.rooms.iter().enumerate() {
            assert!(
                std::sync::Arc::ptr_eq(&map, &r.world.map),
                "room {n} shares it"
            );
            for (k, m) in r.maps.iter().enumerate() {
                assert!(
                    z.rooms[0]
                        .maps
                        .get(k)
                        .is_some_and(|first| std::sync::Arc::ptr_eq(first, m)),
                    "room {n} shares the zone's map {k} rather than unpacking it"
                );
            }
        }
    }

    #[test]
    fn changing_zone_replaces_every_room() {
        let mut z = serving(3, 1, 16);
        for _ in 0..3 {
            let i = z.room_for_join().expect("room");
            seat(&mut z, i, 1);
        }
        assert_eq!(z.rooms.len(), 3);
        let other = fleet::WireZone {
            name: "elsewhere".into(),
            ..wire_zone(3, 1, 16)
        };
        z.serve_zone(&other).expect("it builds");
        assert_eq!(z.zone_name, "elsewhere");
        assert_eq!(z.rooms.len(), 1, "the old rooms served the old game");
        assert_eq!(z.total_players(), 0);
    }

    #[test]
    fn a_kick_reaches_a_player_in_any_room() {
        let mut z = serving(2, 1, 16);
        seat(&mut z, 0, 1);
        let i = z.room_for_join().expect("a second room");
        seat(&mut z, i, 1);
        // p1-0 is in room one, which the operator neither knows nor should.
        let (outcome, _why) = z.run_command(&fleet::Command {
            command_id: 1,
            verb: "kick".into(),
            args: "p1-0".into(),
            actor: "tester".into(),
        });
        assert_eq!(outcome, "done");
        assert_eq!(z.total_players(), 1);
    }

    #[test]
    fn a_client_that_stops_reading_costs_a_bounded_amount() {
        // The queue used to be unbounded, so a client that stopped reading made
        // the process allocate for as long as it stayed connected. A snapshot is
        // a whole state pack, so dropping one is correct: the next supersedes it.
        let mut z = serving(1, 2, 4);
        let (tx, rx) = mpsc::channel(OUT_QUEUE);
        let id = z.rooms[0]
            .join(Seat::guest("stalled", false), 0, 4, tx)
            .expect("a seat");
        let mut buf = vec![0u8; sim::PACK_MAX];
        for _ in 0..OUT_QUEUE * 10 {
            z.rooms[0].tick();
            z.rooms[0].broadcast_snapshot(&mut buf);
        }
        assert_eq!(rx.len(), OUT_QUEUE, "the queue stops at the bound");
        assert_eq!(
            z.status().metrics.queue_depth,
            OUT_QUEUE as u32,
            "and an operator can see which connection is drowning"
        );
        // Still in the room, still simulated: falling behind is not an eviction.
        assert!(z.rooms[0].players.contains_key(&id));
    }

    #[test]
    fn churn_does_not_grow_the_roster_or_the_ship_count() {
        // The leak this pins was found by joining and leaving a live arena for
        // two minutes: a zone configured for nine bots reached sixteen, on its
        // way to sixty-four. `leave` handed every departing player's ship to a
        // fresh bot, while `join` only took a bot when one was there to take, so
        // each player who spawned into a new slot left a bot behind them.
        //
        // Nothing reported it. Status was green, the arena was serving, and the
        // only outward sign was a browse list advertising more AI every hour and
        // a tick cost quietly climbing. The backfill went with the in-process
        // roster and cannot come back; what stays worth pinning is that seats
        // are reused, since a room growing a slot per arrival reaches
        // `max_ships` and starts refusing people who could have had the seat
        // that just went cold.
        let mut z = serving(1, 4, 32);
        let bots0 = 9;
        seat_bots(&mut z.rooms[0], bots0);
        let ships0 = z.rooms[0].world.state.ship_count;

        for _round in 0..6 {
            let mut seated = Vec::new();
            let cap = z.max_players();
            for i in 0..(bots0 + 5) {
                let (tx, _rx) = mpsc::channel(OUT_QUEUE);
                if let Some(id) =
                    z.rooms[0].join(Seat::guest(format!("churn{i}"), false), 0, cap, tx)
                {
                    seated.push(id);
                }
            }
            for id in seated {
                z.rooms[0].leave(id, pilot::why::LEFT);
            }
        }

        assert_eq!(
            z.rooms[0].bot_count(),
            bots0,
            "the bots that were here stayed, and nobody made more"
        );
        assert_eq!(z.rooms[0].humans(), 0);
        // The count is a high-water mark and may have risen once to hold the
        // extra concurrent players, but it must not climb every round: the core
        // hands an inactive slot to the next arrival.
        let ships1 = z.rooms[0].world.state.ship_count;
        assert!(
            u16::from(ships1) <= u16::from(ships0) + (bots0 + 5) as u16,
            "ship_count {ships1} grew past one peak from {ships0}"
        );
        let active = (0..ships1 as usize)
            .filter(|&i| z.rooms[0].world.state.ships[i].active != 0)
            .count();
        assert_eq!(active, bots0, "only the bots are left flying");
    }

    #[test]
    fn a_name_is_printable_bounded_and_never_empty() {
        // The wire hands us arbitrary bytes and a name travels further than
        // anything else a client controls: rosters, logs, the ratings file,
        // an operator's kick argument.
        assert_eq!(
            sanitize_name("Kestrel"),
            "Kestrel",
            "a normal name is untouched"
        );
        assert_eq!(sanitize_name("two  words"), "two words");
        assert_eq!(sanitize_name("  padded\t"), "padded");
        assert_eq!(
            sanitize_name("evil\nname"),
            "evil name",
            "a newline would forge a log line; it becomes a space"
        );
        // The ESC byte is what arms a terminal escape sequence; with it gone
        // the "[2J" left behind is inert text, which is the property that
        // matters when a name is printed into a log.
        assert_eq!(sanitize_name("a\u{1b}[2Jb\u{0}c"), "a[2Jbc");
        assert_eq!(sanitize_name("").as_str(), "pilot");
        assert_eq!(
            sanitize_name("\u{200b}\u{202e}").as_str(),
            "pilot",
            "invisible unicode cannot be a whole name"
        );
        let huge = "x".repeat(10_000_000);
        assert_eq!(
            sanitize_name(&huge).len(),
            24,
            "10 MB of name stores 24 bytes"
        );
        // The cap matches the roster wire format, so what is stored is what
        // every other player is shown.
        assert_eq!(sanitize_name(&huge).len(), 24);
    }

    #[test]
    fn a_hostile_name_lands_sanitized_in_the_room() {
        let mut z = serving(1, 4, 8);
        let (tx, _rx) = mpsc::channel(OUT_QUEUE);
        let cap = z.max_players();
        let id = z.rooms[0]
            .join(
                Seat::guest(sanitize_name("bad\r\nguy\u{7f}"), false),
                0,
                cap,
                tx,
            )
            .expect("a seat");
        assert_eq!(z.rooms[0].players[&id].name, "bad guy");
    }

    #[test]
    fn a_joining_player_is_told_the_zone_they_picked() {
        // Not the local file's name: this process is serving a catalog zone, and
        // the name in the browse list is the name they chose from. The name is
        // the whole message, since a zone has no sentence to send after it.
        let z = serving(1, 6, 16);
        let msg = z.zone_msg();
        let text = String::from_utf8_lossy(&msg[1..]).to_string();
        assert_eq!(text, "testzone", "{text:?}");
    }

    #[test]
    fn a_named_baseline_weapon_is_tuned_in_place() {
        let (w, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "bomb"
            on_wall = "bounce"
            bounces = 3
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let p = w.cfg.patterns[w.cfg.classes[anvil].trigger[1][0] as usize];
        let sp = w.cfg.specs[p.spec as usize];
        assert_eq!((sp.on_wall, sp.bounces), (1, 3), "the bomb bounces now");
        assert!(sp.blast > 0, "and is otherwise still the bomb");
        // For everybody, because there is one bomb in the room: a weapon
        // belongs to the arena now rather than to a hull.
        for c in 0..sim::MAX_CLASSES {
            assert_eq!(
                w.cfg.classes[c].trigger[1][0], w.cfg.classes[anvil].trigger[1][0],
                "every hull throws the bomb the zone tuned"
            );
        }
        // And the other trigger did not move.
        let (_, apex) = gun(&w, ai::class_index("Apex").unwrap());
        assert_eq!(apex.on_wall, 0);
    }

    #[test]
    fn an_unknown_name_is_a_new_weapon_the_arena_can_carry() {
        // A name the baseline never built makes a weapon, and naming an empty
        // charge slot fills that slot with it at once, which is how a zone
        // adds a third thing to throw. There is no hull to hang it on: what
        // leaves a ship is the arena's and the build's.
        let (w, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "charge-3"
            speed = 1500
            life = 60
            damage = 40
            count = 16
            spread = 22
            energy = 300
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        let pat = w.cfg.charge[2];
        assert_ne!(pat, sim::NO_PATTERN, "the third slot is filled");
        let p = w.cfg.patterns[pat as usize];
        let sp = w.cfg.specs[p.spec as usize];
        assert_eq!(p.count, 16);
        assert_eq!(sp.life, 60);
        assert_eq!(
            sp.splinter,
            sim::NO_PATTERN,
            "a new weapon splinters into nothing"
        );
        // Degrees, because nobody thinks in sixty-five thousandths of a turn.
        assert_eq!(p.spacing, (22 * 65536 / 360) as u16);
        let fresh = sim::World::new(1);
        assert_eq!(
            fresh.cfg.charge[2],
            sim::NO_PATTERN,
            "and the baseline leaves that slot empty"
        );
    }

    #[test]
    fn a_weapon_can_splinter_into_one_written_after_it() {
        let (w, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "bomb"
            splinter = "shrapnel"

            [[arena.weapons]]
            name = "shrapnel"
            speed = 1200
            life = 40
            damage = 50
            count = 8
            spread = 45
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let bomb = w.cfg.patterns[w.cfg.classes[anvil].trigger[1][0] as usize];
        let into = w.cfg.specs[bomb.spec as usize].splinter;
        assert_ne!(into, sim::NO_PATTERN, "the bomb splinters");
        assert_eq!(
            w.cfg.patterns[into as usize].count, 8,
            "into eight fragments"
        );
    }

    #[test]
    fn what_the_file_cannot_have_is_reported_rather_than_guessed() {
        let (_, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "odd"
            on_wall = "sideways"
            splinter = "nothing-called-this"

            [[arena.ships]]
            name = "Trapezoid"
        "#,
        );
        assert_eq!(warn.len(), 3, "{warn:?}");
        assert!(warn.iter().any(|w| w.contains("sideways")));
        assert!(warn.iter().any(|w| w.contains("nothing-called-this")));
        assert!(warn.iter().any(|w| w.contains("Trapezoid")));
    }

    /// A rung above the first is named for its level, so a zone tunes one
    /// step of a ladder without touching the steps either side of it.
    #[test]
    fn a_rung_above_the_first_is_named_for_its_level() {
        let (w, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "bomb-3"
            blast = 96
            energy = 600
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        let anvil = ai::class_index("Anvil").unwrap();
        let rungs = w.cfg.classes[anvil].trigger[1];
        let top = w.cfg.specs[w.cfg.patterns[rungs[2] as usize].spec as usize];
        let base = w.cfg.specs[w.cfg.patterns[rungs[0] as usize].spec as usize];
        assert_eq!(top.blast, 96 * 256, "the third rung got the blast it named");
        assert_eq!(base.blast, 80 * 256, "and the first kept BombExplodePixels");
        let top_p = w.cfg.patterns[rungs[2] as usize];
        let base_p = w.cfg.patterns[rungs[0] as usize];
        assert!(top_p.energy > base_p.energy, "and it costs more to let go");
    }

    #[test]
    fn a_zone_sets_its_room_size() {
        let mut w = sim::World::new(1);
        assert_eq!(w.cfg.max_ships, 64, "the baseline's room");
        Room::apply_config(&mut w, &parse("[arena]\nmax_ships = 200\n"));
        assert_eq!(w.cfg.max_ships, 200, "a zone can widen it");
        // Reload builds from the baseline first, so dropping the line reverts.
        Room::apply_config(&mut w, &parse("[arena]\n"));
        assert_eq!(w.cfg.max_ships, 64, "and removing the line puts it back");
    }

    /// Every zone the shipped catalog offers, applied to a fresh room.
    ///
    /// A weapon or a hull a zone file names and the core does not is a warning
    /// on a running server and nothing else, so the zone goes live with part of
    /// its tuning silently missing. The catalog is the deployment, and these
    /// files are the only ones anybody actually plays.
    #[test]
    fn every_shipped_zone_applies_with_nothing_left_over() {
        catalog::set_placeholder_identity();
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../catalog");
        let cat = catalog::load(dir).expect("the catalog we ship loads");
        assert!(!cat.order.is_empty(), "the deployment serves something");
        for name in &cat.order {
            let mut w = sim::World::new(1);
            let warn = Room::apply_config(&mut w, &cat.zone(name).unwrap().arena);
            assert!(warn.is_empty(), "zone {name}: {warn:?}");
        }
    }

    /// One game, five rooms: every zone we ship flies the same ship into the
    /// same wall, and what a zone file changes is what the room is *for*.
    ///
    /// That claim used to be enforced by copying twenty settings into each new
    /// zone file and hoping the next tuning pass edited all five. It is the
    /// baseline's now, and this is what says so: apply a zone, blank the
    /// handful of fields a zone is allowed to differ on, and everything left
    /// has to be identical across the catalog. A zone that quietly tunes the
    /// gun fails here rather than in a player's hands, and a genuinely new
    /// per-zone rule fails too, until it is named in the list below and thereby
    /// argued for.
    #[test]
    fn every_shipped_zone_flies_the_same_ship() {
        catalog::set_placeholder_identity();
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../catalog");
        let cat = catalog::load(dir).expect("the catalog we ship loads");
        let mut digests: Vec<(String, Vec<u8>)> = Vec::new();
        for name in &cat.order {
            let mut w = sim::World::new(1);
            Room::apply_config(&mut w, &cat.zone(name).unwrap().arena);
            // What a zone says about its own room rather than about the game
            // in it: how long you wait to fly again and where you arrive, the
            // flag rules that separate Turf from War, the greens that make
            // Free Roam persistent, and how many seats there are.
            w.cfg.respawn_delay = 0;
            w.cfg.spawn_radius = 0;
            w.cfg.flag_radius = 0;
            w.cfg.flag_drop_cooldown = 0;
            w.cfg.flag_carry = 0;
            w.cfg.flag_carry_ticks = 0;
            w.cfg.green_target = 0;
            w.cfg.green_life = 0;
            w.cfg.green_every = 0;
            w.cfg.green_near = 0;
            w.cfg.green_far = 0;
            w.cfg.green_radius = 0;
            w.cfg.green_weight = [0; sim::SLOT_COUNT];
            w.cfg.max_ships = 0;
            digests.push((name.clone(), w.packed_settings()));
        }
        let (first, want) = &digests[0];
        for (name, got) in &digests[1..] {
            assert_eq!(
                got, want,
                "{name} and {first} disagree about the ship, the weapons or the wall"
            );
        }
    }

    /// The other half of that rule: a shipped zone writes a setting only where
    /// it wants a different answer from the baseline's.
    ///
    /// A key that restates the baseline is not harmless. It reads as a
    /// decision this zone made, so the next tuning pass has to work out
    /// whether the zone meant it, and it is how the five files filled up with
    /// twenty settings apiece in the first place. Each key gets applied on its
    /// own here and has to move something.
    #[test]
    fn a_shipped_zone_writes_only_what_it_changes() {
        catalog::set_placeholder_identity();
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../catalog");
        let cat = catalog::load(dir).expect("the catalog we ship loads");
        let baseline = {
            let w = sim::World::new(1);
            w.packed_settings()
        };
        // Keys that are the room's rather than the simulation's: the mode,
        // its clocks, the rounds that take a duel, how many of the map's
        // stands to play, and the connection policy. None of them reach the
        // settings a client is sent, so they cannot be checked this way and
        // are not what this test is about.
        const NOT_SETTINGS: [&str; 7] = [
            "mode",
            "flags",
            "match_seconds",
            "intermission_seconds",
            "turf_seconds",
            "first_to",
            "lag",
        ];
        for name in &cat.order {
            let src = std::fs::read_to_string(format!("{dir}/zones/{name}/zone.toml")).unwrap();
            let doc: toml::Value = toml::from_str(&src).unwrap();
            let Some(arena) = doc.get("arena").and_then(|a| a.as_table()) else {
                continue;
            };
            for (key, value) in arena {
                if NOT_SETTINGS.contains(&key.as_str()) {
                    continue;
                }
                let mut one = toml::map::Map::new();
                one.insert(key.clone(), value.clone());
                let mut doc = toml::map::Map::new();
                doc.insert("arena".into(), toml::Value::Table(one));
                let doc = toml::to_string(&toml::Value::Table(doc)).unwrap();
                let (w, warn) = tuned(&doc);
                assert!(warn.is_empty(), "{name}: {key}: {warn:?}");
                assert_ne!(
                    w.packed_settings(),
                    baseline,
                    "{name} writes {key}, which is already what the baseline says: \
                     delete the line rather than restating it"
                );
            }
        }
    }

    #[test]
    fn a_zone_prices_multifire() {
        let (w, warn) = tuned(
            r#"
            [arena]
            multi_energy = 200
            multi_delay = 25
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.mod_multi_energy, 200);
        assert_eq!(w.cfg.mod_multi_delay, 25);

        // Untouched, these are the original's per round: MultiFireEnergy 30
        // against BulletFireEnergy 20 and MultiFireDelay 50 against
        // BulletFireDelay 25, over the two extra rounds it bought. Reading the
        // fields on either side too, because two u16s landing in the wrong
        // place is exactly how this mirror drifts.
        let (w, _) = tuned(
            r#"
            [arena]
            mode = "warzone"
        "#,
        );
        assert_eq!(w.cfg.mod_multi_energy, 25);
        assert_eq!(w.cfg.mod_multi_delay, 50);
        assert_eq!(w.cfg.mod_spread, 910, "five degrees, still");
        assert_eq!(w.cfg.bounce, 12, "and the field past the splinters");
    }

    /// `mode` and `flags` were documented keys that nobody read: the arena
    /// built a four-flag warzone whatever the file said.
    #[test]
    fn a_zone_picks_its_mode_and_how_many_flags_it_plays_for() {
        let cfg: config::ZoneConfig =
            toml::from_str("[arena]\nmode = \"arena\"\nflags = 2\n").unwrap();
        let a = Room::new_from(&cfg);
        assert_eq!(a.mode.name(), "arena");
        assert_eq!(a.world.state.flag_count, 2);

        let cfg: config::ZoneConfig = toml::from_str("name = \"bare\"").unwrap();
        let a = Room::new_from(&cfg);
        assert_eq!(
            a.mode.name(),
            "warzone",
            "and a file that says nothing is a warzone"
        );
        assert_eq!(a.world.state.flag_count, 4);
    }

    #[test]
    fn a_catalog_room_uses_the_configured_number_of_flags() {
        let stands = [(500u16, 500), (520, 500), (500, 520), (520, 520)];
        let mut zone = wire_zone(1, 6, 16);
        zone.mode = "warzone".into();
        zone.maps_b64 = vec![fleet::b64(
            &sim::World::arena_with_stands(1, &stands).packed_map(),
        )];
        zone.zone_toml = "teams = [\"Keel\", \"Vantage\"]\n[arena]\nflags = 2\n".into();

        let room = ArenaServer::build_room(&zone, None).expect("room");

        assert_eq!(room.mode.name(), "warzone");
        assert_eq!(room.world.state.flag_count, 2, "two of the four it draws");
    }

    /// Where the flags stand is the map's. This built the arena's own four
    /// quadrant tiles for any warzone, whatever ground it was on, which put
    /// four flags out past the wall of every zone map we ship; and it laid
    /// none at all for a game whose flags are the map's whole objective.
    #[test]
    fn a_catalog_room_stands_its_flags_where_the_map_draws_them() {
        let stands = [(480u16, 512), (544, 512), (512, 480)];
        let mut zone = wire_zone(1, 6, 16);
        zone.mode = "turf".into();
        zone.maps_b64 = vec![fleet::b64(
            &sim::World::arena_with_stands(1, &stands).packed_map(),
        )];
        zone.zone_toml = "teams = [\"Keel\", \"Vantage\"]\n[arena]\nflag_carry = false\n".into();

        let room = ArenaServer::build_room(&zone, None).expect("room");

        assert_eq!(room.mode.name(), "turf");
        assert_eq!(room.world.state.flag_count, 3, "one per stand, and no more");
        let mut where_they_are: Vec<(i32, i32)> = (0..3)
            .map(|i| {
                let f = room.world.state.flags[i];
                (f.x / (16 * 256), f.y / (16 * 256))
            })
            .collect();
        where_they_are.sort();
        assert_eq!(where_they_are, vec![(480, 512), (512, 480), (544, 512)]);
    }

    /// The turf zone as it ships, played: stands off the map, claimed by
    /// flying over one, and a clock that pays whoever is holding them.
    ///
    /// End to end on purpose. Every piece of this was tested on its own and
    /// the pieces are in four files, so what is under test here is that the
    /// zone file, the map, the mode and the core agree about what game is
    /// being played.
    #[test]
    fn the_shipped_turf_zone_plays_turf() {
        let dir = "../catalog/zones/turf";
        let def: catalog::ZoneDef = toml::from_str(
            &std::fs::read_to_string(format!("{dir}/zone.toml")).expect("the turf zone"),
        )
        .expect("it parses");
        let map = std::fs::read(format!("{dir}/{}", def.maps[0])).expect("its first map");

        let mut zone = wire_zone(1, 8, 8);
        zone.mode = def.mode.clone();
        zone.maps_b64 = vec![fleet::b64(&map)];
        zone.zone_toml = std::fs::read_to_string(format!("{dir}/zone.toml")).unwrap();
        let mut room = ArenaServer::build_room(&zone, None).expect("a room");

        assert_eq!(room.mode.name(), "turf");
        assert_eq!(room.world.state.flag_count, 6, "six stands off the map");
        assert_eq!(room.world.cfg.flag_carry, 0, "and none of them travel");

        // A pilot of each side, put on a stand apiece. Standing on it is the
        // whole of the input: turf is claimed by being there.
        let (a, b) = (room.world.state.flags[0], room.world.state.flags[1]);
        assert!(room.world.spawn_at(0, 0, a.x, a.y, 0) >= 0);
        assert!(room.world.spawn_at(0, 1, b.x, b.y, 0) >= 0);

        for _ in 0..1_000 {
            room.world.step(&[]);
            let mut ctx = modes::ModeCtx {
                world: &mut room.world,
                team_names: &[String::from("Keel"), String::from("Vantage")],
                banner: String::new(),
                finished: false,
                open_match: false,
                round_reset: false,
                close_match: false,
            };
            room.mode.tick(&mut ctx);
        }

        assert_eq!(room.world.state.flags[0].team, 0, "one side has its stand");
        assert_eq!(room.world.state.flags[1].team, 1, "and the other has its");
        for f in 0..2 {
            assert_eq!(room.world.state.flags[f].carried, 0, "carried by nobody");
        }
        let score = room.mode.match_state().expect("turf has a clock").score;
        assert_eq!(
            score,
            vec![2, 2],
            "ten seconds of a five second period, one stand each"
        );
    }

    /// The War zone as it ships: four flags off the map, carried by whoever
    /// takes one, and put down on their own after the carry clock runs out.
    #[test]
    fn the_shipped_war_zone_carries_its_flags_and_puts_them_down() {
        let dir = "../catalog/zones/war";
        let toml_text = std::fs::read_to_string(format!("{dir}/zone.toml")).expect("the war zone");
        let def: catalog::ZoneDef = toml::from_str(&toml_text).expect("it parses");
        let map = std::fs::read(format!("{dir}/{}", def.maps[0])).expect("its first map");

        let mut zone = wire_zone(1, 8, 8);
        zone.mode = def.mode.clone();
        zone.maps_b64 = vec![fleet::b64(&map)];
        zone.zone_toml = toml_text;
        let mut room = ArenaServer::build_room(&zone, None).expect("a room");

        assert_eq!(room.mode.name(), "warzone");
        assert_eq!(room.world.state.flag_count, 4, "four flags off the map");
        assert_eq!(room.world.cfg.flag_carry, 1, "and they travel");
        assert_eq!(
            room.world.cfg.flag_carry_ticks, 3_000,
            "thirty seconds of carrying"
        );

        let f = room.world.state.flags[0];
        assert!(room.world.spawn_at(0, 0, f.x, f.y, 0) >= 0);
        room.world.step(&[]);
        assert_eq!(room.world.state.flags[0].carried, 1, "taken by flying over");
        assert_eq!(room.world.state.flags[0].team, 0);

        // Held, and then not. Nobody kills the carrier: the clock does it.
        for _ in 0..2_900 {
            room.world.step(&[]);
        }
        assert_eq!(room.world.state.flags[0].carried, 1, "still held at 29s");
        for _ in 0..200 {
            room.world.step(&[]);
        }
        assert_eq!(room.world.state.flags[0].carried, 0, "put down at 30s");
        assert_eq!(
            room.world.state.flags[0].team, 0,
            "still owned by that side"
        );
    }

    /// Every room this server builds gets a prize stream of its own, and no
    /// two rooms get the same one.
    ///
    /// The core sows nothing without one, so the room that skipped this would
    /// be a Free Roam with no greens in it. The failure this guards against is
    /// the other one: rolling them from `sim_state::rng`, which is a public
    /// constant at `sim_init` and rides in every snapshot after, so a client
    /// could work out where the next green was going to land and go and stand
    /// there. Decision 44.
    #[test]
    fn every_room_rolls_its_greens_from_a_stream_of_its_own() {
        let dir = "../catalog/zones/roam";
        let toml_text = std::fs::read_to_string(format!("{dir}/zone.toml")).expect("the roam zone");
        let def: catalog::ZoneDef = toml::from_str(&toml_text).expect("it parses");
        let map = std::fs::read(format!("{dir}/{}", def.maps[0])).expect("its map");
        let mut zone = wire_zone(1, 64, 64);
        zone.mode = def.mode.clone();
        zone.maps_b64 = vec![fleet::b64(&map)];
        zone.zone_toml = toml_text;

        let a = ArenaServer::build_room(&zone, None).expect("a room");
        let b = ArenaServer::build_room(&zone, None).expect("another room");
        assert_ne!(a.world.state.prize_rng, 0, "a room is given a stream");
        assert_ne!(
            a.world.state.prize_rng, b.world.state.prize_rng,
            "and it is not the same one twice"
        );
        assert_ne!(
            a.world.state.prize_rng, a.world.state.rng,
            "nor the one every snapshot publishes"
        );
    }

    /// A map swap takes the greens with it and keeps the stream that rolls
    /// them. A green lies on ground the next map may have made wall, so it
    /// goes the way a flag and a round in the air already did; the stream is
    /// the room's rather than the ground's, and rerolling it every rotation
    /// would hand a patient client somewhere to start guessing again.
    #[test]
    fn a_map_swap_clears_the_greens_and_keeps_the_stream() {
        let mut world = sim::World::new(0x5eed);
        world.seed_prizes(0xabcdef01);
        world.state.green_count = 3;
        world.state.greens[0].active = 1;
        world.state.green_at = 42;

        let other = std::sync::Arc::clone(&world.map);
        world.set_map(other);

        assert_eq!(world.state.green_count, 0, "the field is swept");
        assert_eq!(world.state.green_at, 0, "and its clock restarts");
        assert_eq!(
            world.state.prize_rng, 0xabcdef01,
            "the stream is the room's and stays"
        );
    }

    /// The free roam zone as it ships: greens appear near the pilot they were
    /// put out for, and flying into one raises what that pilot is flying.
    #[test]
    fn the_shipped_roam_zone_puts_greens_where_the_people_are() {
        let dir = "../catalog/zones/roam";
        let toml_text = std::fs::read_to_string(format!("{dir}/zone.toml")).expect("the roam zone");
        let def: catalog::ZoneDef = toml::from_str(&toml_text).expect("it parses");
        let map = std::fs::read(format!("{dir}/{}", def.maps[0])).expect("its map");

        let mut zone = wire_zone(1, 64, 64);
        zone.mode = def.mode.clone();
        zone.maps_b64 = vec![fleet::b64(&map)];
        zone.zone_toml = toml_text;
        let mut room = ArenaServer::build_room(&zone, None).expect("a room");

        assert_eq!(room.mode.name(), "arena", "no clock, no podium");
        assert_eq!(room.world.cfg.green_target, 24, "two dozen out at once");
        assert!(
            room.world.cfg.green_weight.iter().any(|w| *w > 0),
            "and a table saying what one may be"
        );

        // One pilot, in the middle of a thousand tiles. Everything a green
        // does is measured against where they are.
        let seat = room.world.spawn(0, 0, 512, 512, 0);
        assert!(seat >= 0);
        let (px, py) = {
            let sh = room.world.state.ships[seat as usize];
            (sh.x as i64, sh.y as i64)
        };

        let mut seen = 0;
        for _ in 0..6_000 {
            room.world.step(&[]);
            seen = (0..room.world.state.green_count as usize)
                .filter(|i| room.world.state.greens[*i].active == 1)
                .count();
            if seen >= 4 {
                break;
            }
        }
        assert!(seen >= 4, "greens are put out, {seen} of them");

        let near = room.world.cfg.green_near as i64;
        let far = room.world.cfg.green_far as i64;
        for i in 0..room.world.state.green_count as usize {
            let g = room.world.state.greens[i];
            if g.active == 0 {
                continue;
            }
            let (dx, dy) = (g.x as i64 - px, g.y as i64 - py);
            let d2 = dx * dx + dy * dy;
            assert!(
                d2 >= near * near && d2 <= far * far,
                "every green is in the ring around the pilot it appeared for"
            );
            assert!(
                room.world.cfg.green_weight[g.slot as usize] > 0,
                "and is something the zone's table allows"
            );
        }

        // Taking one reports what it filled. Whether the pilot is any better
        // for it is the roll's business: a green that lands on a slot already
        // at its hull's ceiling is still taken, which is what stops one
        // nobody can use sitting on a route forever.
        let g = (0..room.world.state.green_count as usize)
            .find(|i| room.world.state.greens[*i].active == 1)
            .expect("one to take");
        let (gx, gy, slot) = {
            let it = room.world.state.greens[g];
            (it.x, it.y, it.slot)
        };
        room.world.state.ships[seat as usize].x = gx;
        room.world.state.ships[seat as usize].y = gy;
        room.world.step(&[]);
        assert_eq!(room.world.state.greens[g].active, 0, "the green is taken");
        let took = room.world.events.e[..room.world.events.count as usize]
            .iter()
            .find(|e| e.etype == sim::EV_GREEN)
            .expect("and says so");
        assert_eq!(took.a, seat as u8, "by the pilot who flew into it");
        assert_eq!(took.b, slot, "naming the slot it filled");
    }

    /// A map that draws no stands is not a flag game and gets no flags. The
    /// melee zone is the one that proves it matters: it named no flag count,
    /// took the default four, and carried four unreachable pennants across
    /// the top of its HUD for a game it was not playing.
    #[test]
    fn a_map_with_no_stands_has_no_flags() {
        let mut zone = wire_zone(1, 6, 16);
        zone.mode = "melee".into();
        zone.zone_toml = "teams = [\"Keel\", \"Vantage\"]\n".into();

        let room = ArenaServer::build_room(&zone, None).expect("room");

        assert_eq!(room.world.state.flag_count, 0);
    }

    #[test]
    fn an_invalid_hull_number_is_refused_instead_of_selecting_the_last_hull() {
        let mut world = sim::World::new(1);
        assert_eq!(world.spawn(0, 0, 512, 512, 0), 0);
        assert!(!world.set_ship_class(0, u8::MAX, None));
        assert_eq!(world.state.ships[0].cls, 0);
    }

    #[test]
    fn a_tuning_reload_does_not_replace_an_active_objective() {
        let cfg: config::ZoneConfig =
            toml::from_str("[arena]\nmode = \"warzone\"\nflags = 2\n").unwrap();
        let mut room = Room::new_from(&cfg);
        room.world.state.flags[0].team = 1;

        let changed = parse("[arena]\nmode = \"arena\"\nflags = 4\nfriction = 9\n");
        Room::apply_config(&mut room.world, &changed);

        assert_eq!(room.mode.name(), "warzone");
        assert_eq!(room.world.state.flag_count, 2);
        assert_eq!(room.world.state.flags[0].team, 1);
        assert_eq!(room.world.cfg.friction, 9);
    }

    /// A build reaches the arena, survives a whistle, and cannot be spent
    /// past the budget however it arrives.
    ///
    /// The whistle is the half worth pinning. A match start re-deals every
    /// seat, and it re-deals from the ship rather than from the hull's row,
    /// so a pilot who spent their credits before the match still has them
    /// afterwards. The last kit lost exactly this and nobody noticed until
    /// a player flew a bare hull for a whole match.
    #[test]
    fn a_build_reaches_the_arena_and_survives_a_whistle() {
        let cfg: config::ZoneConfig = toml::from_str("[arena]\nmode = \"arena\"\n").unwrap();
        let mut room = Room::new_from(&cfg);
        let apex = 0u8;
        let ship = room.world.spawn(apex, 0, 8, 8, 0) as u8;

        // Four rounds off the gun and one repel, which is the Apex's four
        // credits spent somewhere else.
        let mut mine = [0u8; sim::SLOT_COUNT];
        mine[sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize] = 3;
        mine[sim::slot_charge(sim::CHARGE_REPEL) as usize] = 1;
        room.set_ship_kit(ship, apex, &mine);
        let sh = &room.world.state.ships[ship as usize];
        assert_eq!(sim::mod_get(sh.mods[sim::TRIG_GUN], sim::MOD_MULTI), 3);
        assert_eq!(sh.charge[sim::CHARGE_REPEL], 1);

        // A whistle deals it back, ammunition and all, from the ship.
        room.world.restart();
        room.deal_seat(ship);
        let sh = &room.world.state.ships[ship as usize];
        assert_eq!(
            sim::mod_get(sh.mods[sim::TRIG_GUN], sim::MOD_MULTI),
            3,
            "a whistle re-deals the build the pilot spent, not the hull's row"
        );
        assert_eq!(sh.charge[sim::CHARGE_REPEL], 1);

        // And nothing a client can send spends more than a player has.
        let greedy = [9u8; sim::SLOT_COUNT];
        room.set_ship_kit(ship, apex, &greedy);
        let kit = room.world.state.ships[ship as usize].kit;
        assert_eq!(
            kit.iter().map(|&n| n as u16).sum::<u16>(),
            u16::from(sim::KIT_CREDITS)
        );
    }

    /// A build naming a hull the pilot is not in is a hull change carrying
    /// it, so the two never arrive separately and deal the wrong row in
    /// between.
    #[test]
    fn a_build_for_another_hull_carries_the_hull_change() {
        let cfg: config::ZoneConfig = toml::from_str("[arena]\nmode = \"arena\"\n").unwrap();
        let mut room = Room::new_from(&cfg);
        let ship = room.world.spawn(0, 0, 8, 8, 0) as u8;
        let wedge = 1u8;

        let mut bomber = [0u8; sim::SLOT_COUNT];
        bomber[sim::slot_mod(sim::TRIG_BOMB, sim::MOD_SHRAPNEL) as usize] = 2;
        room.set_ship_kit(ship, wedge, &bomber);

        let sh = &room.world.state.ships[ship as usize];
        assert_eq!(sh.cls, wedge, "the hull came with the build");
        assert_eq!(
            sim::mod_get(sh.mods[sim::TRIG_BOMB], sim::MOD_SHRAPNEL),
            2,
            "and it arrived carrying what was spent on it"
        );
    }

    /// A build changed under the hull a pilot is already in is a ship change
    /// like any other: the same gate and the same respawn.
    ///
    /// Without this, the ship menu costs two different things depending on
    /// which part of it a pilot touched. Climbing into another hull is paid
    /// for with a full bar and a trip back to the start; trading a repel for
    /// a rung used to be free and instant, which makes a refit the way out of
    /// a fight that is going badly.
    #[test]
    fn a_build_changed_in_the_air_is_a_ship_change() {
        let cfg: config::ZoneConfig = toml::from_str("[arena]\nmode = \"arena\"\n").unwrap();
        let mut room = Room::new_from(&cfg);
        let apex = 0u8;
        let ship = room.world.spawn(apex, 0, 8, 8, 0) as u8;

        // Everything on one weapon, which is a row no hull arrives wearing.
        let was = room.world.state.ships[ship as usize].kit;
        let mut mine = [0u8; sim::SLOT_COUNT];
        mine[sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize] = sim::KIT_CREDITS;
        assert_ne!(mine, was, "the row asked for is not the row on the ship");

        // Hurt, and the row stays where it was: the core refuses a ship to
        // anybody short of a full bar and says nothing about it.
        room.world.state.ships[ship as usize].energy -= 1;
        room.world.state.ships[ship as usize].y += 4096;
        room.set_ship_kit(ship, apex, &mine);
        assert_eq!(
            room.world.state.ships[ship as usize].kit, was,
            "a damaged pilot cannot refit"
        );

        // Whole, and it lands, at the price a ship costs: back at the start.
        let full = room.world.eff_max_energy(ship as usize);
        room.world.state.ships[ship as usize].energy = full;
        room.set_ship_kit(ship, apex, &mine);
        let sh = &room.world.state.ships[ship as usize];
        assert_ne!(sh.kit, was, "and a whole one refits");
        assert_eq!(sh.cls, apex, "on the hull they never left");
        assert_eq!(sh.y, sh.spawn_y, "having paid a respawn for it");
    }

    /// And a build for a pilot who is not in the air is dealt in place, which
    /// is how one arrives with a pilot who joined during a podium: the seat is
    /// benched, there is no fight to leave and no bar to have, and the whistle
    /// deals what the seat is wearing.
    #[test]
    fn a_build_for_a_benched_seat_is_dealt_in_place() {
        let cfg: config::ZoneConfig = toml::from_str("[arena]\nmode = \"arena\"\n").unwrap();
        let mut room = Room::new_from(&cfg);
        let apex = 0u8;
        let ship = room.world.spawn(apex, 0, 8, 8, 0) as u8;
        room.world.state.ships[ship as usize].alive = 0;
        room.world.state.ships[ship as usize].energy = 0;

        let was = room.world.state.ships[ship as usize].kit;
        let mut mine = [0u8; sim::SLOT_COUNT];
        mine[sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize] = sim::KIT_CREDITS;
        room.set_ship_kit(ship, apex, &mine);
        let sh = &room.world.state.ships[ship as usize];
        assert_ne!(sh.kit, was, "a benched seat takes its owner's build");
        assert_eq!(sh.alive, 0, "and stays benched for it");
    }

    /// The zone we ship is the documentation for this format. Parsing it is
    /// half the check; the other half is that every name in it resolves, since
    /// a weapon or an add-on the file cannot have is a warning rather than an
    /// error and would otherwise go out unnoticed.
    #[test]
    fn the_reference_zone_applies_without_a_complaint() {
        let (_, warn) = tuned(include_str!("../../zone/zone.toml"));
        assert!(warn.is_empty(), "{warn:?}");
    }

    /// The bomb rules the original spells out, as settings rather than as
    /// numbers compiled into the baseline.
    #[test]
    fn a_zone_writes_its_own_bomb_rules() {
        let (w, warn) = tuned(
            r#"
            [arena]
            prox_step = 32
            shrap_inactive = 100
            shrap_inactive_ticks = 5
            mod_spread = 30
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.prox_step, 32 * 256, "two tiles wider a bomb level");
        assert_eq!(w.cfg.shrap_inactive, unsafe { sim::sim_units_energy(100) });
        assert_eq!(w.cfg.shrap_inactive_ticks, 5);
        assert_eq!(w.cfg.mod_spread, (30 * 65536 / 360) as u16);

        // And untouched they are the original's: ProximityDistance gains a
        // tile a level, InactiveShrapDamage is 3 over a quarter second.
        let (w, _) = tuned("[arena]\nmode = \"warzone\"\n");
        assert_eq!(w.cfg.prox_step, 16 * 256);
        assert_eq!(w.cfg.shrap_inactive, unsafe { sim::sim_units_energy(3) });
        assert_eq!(w.cfg.shrap_inactive_ticks, 25);
    }

    /// The weapons that sit in a settings slot rather than on a hull. These
    /// were the only ones in the zone nothing could reach: the repel's radius
    /// and the fragments a bomb breaks into were ours and nobody else's.
    #[test]
    fn a_zone_tunes_the_charges_and_the_shrapnel() {
        let (w, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "charge-1"
            blast = 200
            push = 1000

            [[arena.weapons]]
            name = "shrapnel-2"
            count = 12
            damage = 30
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        let repel = w.cfg.specs[w.cfg.patterns[w.cfg.charge[0] as usize].spec as usize];
        assert_eq!(repel.blast, 200 * 256, "a shorter shove");
        assert_eq!(repel.push, unsafe { sim::sim_units_speed(1000) });
        let shell = w.cfg.patterns[w.cfg.mod_splinter[2] as usize];
        assert_eq!(shell.count, 12, "a second rung of shrapnel is twelve now");
        assert_eq!(
            w.cfg.patterns[w.cfg.mod_splinter[1] as usize].count, 2,
            "and the rung below it is untouched, at ShrapnelRate"
        );
    }

    /// The ladder is the arena's, so tuning a rung reaches every hull and
    /// there is no per-hull ladder left to write.
    #[test]
    fn a_ladder_is_the_arenas_rather_than_a_hulls() {
        let (w, warn) = tuned(
            r#"
            [[arena.weapons]]
            name = "gun-2"
            damage = 400
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        for c in 0..sim::MAX_CLASSES {
            let rungs = w.cfg.classes[c].trigger[0];
            assert_ne!(rungs[2], sim::NO_PATTERN, "three rungs to climb");
            assert_eq!(rungs[3], sim::NO_PATTERN, "and the ladder ends there");
            let second = w.cfg.specs[w.cfg.patterns[rungs[1] as usize].spec as usize];
            assert_eq!(second.damage, unsafe { sim::sim_units_energy(400) });
        }
    }

    /// A zone may replace a hull's weapon ladder, but not its footprint. The
    /// latter has one fixed target-area budget and a client drawing fitted to
    /// it, so changing it on the server would break both contracts.
    #[test]
    fn a_zone_cannot_replace_a_hulls_footprint() {
        let source = r#"
            [[arena.ships]]
            name = "Apex"
            fore = 20
            aft = 12
            width = 18
        "#;
        assert!(
            toml::from_str::<config::ZoneConfig>(source).is_err(),
            "footprint belongs to the shared roster rather than one zone"
        );
    }

    /// Absent and zero are different things. Every setting the core owns is
    /// absent-means-baseline, which leaves zero free to mean zero: a wall that
    /// gives nothing back, doors that never open, a wormhole with no pull.
    #[test]
    fn zero_is_a_setting_rather_than_a_missing_one() {
        let (w, warn) = tuned(
            r#"
            [arena]
            bounce = 0
            door_period = 0
            flag_radius = 30
            flag_drop_cooldown = 50
            door_open = 100
            wormhole_pull = 40
            wormhole_range = 500
        "#,
        );
        assert!(warn.is_empty(), "{warn:?}");
        assert_eq!(w.cfg.bounce, 0, "a wall that eats everything that hits it");
        assert_eq!(w.cfg.door_period, 0);
        assert_eq!(w.cfg.flag_radius, 30 * 256);
        assert_eq!(w.cfg.flag_drop_cooldown, 50);
        assert_eq!(w.cfg.door_open, 100);
        assert_eq!(w.cfg.wormhole_pull, unsafe { sim::sim_units_speed(40) });
        assert_eq!(w.cfg.wormhole_range, 500 * 256);

        // Left out, each is the core's own.
        let (w, _) = tuned("[arena]\nmode = \"warzone\"\n");
        assert_eq!(w.cfg.bounce, 12);
        assert_eq!(w.cfg.door_period, 600);
        assert_eq!(w.cfg.flag_radius, 18 * 256);
    }

    /// The reason apply_config rebuilds from the baseline. An operator saves
    /// the file repeatedly; the arena has to end up where the file says, not
    /// where every version of it since boot has said.
    #[test]
    fn applying_a_file_twice_is_applying_it_once() {
        let src = r#"
            [[arena.weapons]]
            name = "shrapnel"
            speed = 1200
            count = 8

            [[arena.weapons]]
            name = "bomb"
            splinter = "shrapnel"
        "#;
        let mut w = sim::World::new(1);
        Room::apply_config(&mut w, &parse(src));
        let (specs, patterns) = (w.cfg.spec_count, w.cfg.pattern_count);
        for _ in 0..5 {
            Room::apply_config(&mut w, &parse(src));
        }
        assert_eq!(
            (w.cfg.spec_count, w.cfg.pattern_count),
            (specs, patterns),
            "a reload does not append a row every time"
        );
    }

    /// The zones we ship are the worked example of this format, and the half of
    /// it that goes wrong quietly is the names: a weapon no hull has, an add-on
    /// spelled wrong, a charge that is not a charge. None of those is a parse
    /// error. They are a line in a warning list nobody is reading at three in
    /// the morning, and a setting that reached the fleet and did nothing.
    #[test]
    fn every_shipped_zone_applies_without_a_warning() {
        crate::catalog::set_placeholder_identity();
        let cat = crate::catalog::load("../catalog").expect("the shipped catalog loads");
        for name in &cat.order {
            let mut w = sim::World::new(1);
            let warn = Room::apply_config(&mut w, &cat.zones[name].arena);
            assert!(
                warn.is_empty(),
                "zone {name:?} applies with warnings: {warn:?}"
            );
        }
    }

    /// Team Battle's four departures from the shipped weapons, read off the
    /// applied world rather than off the file.
    ///
    /// A warning is not the failure mode these have. Three of them are weapon
    /// blocks addressed by rung name, and a name nothing answers to is not an
    /// error: the first pass builds a brand new weapon under it, wires it to
    /// no trigger and no slot, and reports nothing. So renaming a rung would
    /// leave this zone parsing cleanly with bullets that stop at the first
    /// wall. The assertions below are what notices.
    #[test]
    fn team_battle_tunes_the_wall_the_gun_and_the_burst() {
        crate::catalog::set_placeholder_identity();
        let cat = crate::catalog::load("../catalog").expect("the shipped catalog loads");
        let mut w = sim::World::new(1);
        let warn = Room::apply_config(&mut w, &cat.zones["melee"].arena);
        assert!(warn.is_empty(), "melee applies with warnings: {warn:?}");

        // A wall keeps a quarter of what hits it, and a sit is capped at the
        // widest a uint16_t goes.
        assert_eq!(w.cfg.bounce, 12);
        assert_eq!(w.cfg.safe_limit, 65535);

        // Every rung of the gun carries a wall count no bullet can spend. The
        // rounds still end on walls until a pilot buys the add-on, which is
        // what leaves `on_wall` alone here.
        for rung in 0..3 {
            let pat = w.cfg.classes[0].trigger[sim::TRIG_GUN][rung];
            assert_ne!(pat, sim::NO_PATTERN, "the gun has a rung {rung}");
            let spec = w.cfg.specs[w.cfg.patterns[pat as usize].spec as usize];
            assert_eq!(spec.bounces, 255, "gun rung {rung} ricochets");
            assert_eq!(spec.on_wall, 0, "gun rung {rung} is bought, not given");
        }

        // Alpha Zone's BurstDamageLevel.
        let burst = w.cfg.charge[sim::CHARGE_BURST];
        assert_ne!(
            burst,
            sim::NO_PATTERN,
            "the burst is a charge this zone fills"
        );
        let spec = w.cfg.specs[w.cfg.patterns[burst as usize].spec as usize];
        assert_eq!(spec.damage, sim::units_energy(515));
    }

    /// The whole commit path over the shipped catalog, exactly as the decide
    /// loop runs it: wire form, packed map bytes, zone text and all. The
    /// apply test above reads the files; this one proves an arena handed them
    /// over the wire can actually open a room, which is the half that broke
    /// the day the fleet shipped zone text its own arenas refused to parse.
    #[test]
    fn every_shipped_zone_serves() {
        crate::catalog::set_placeholder_identity();
        let cat = crate::catalog::load("../catalog").expect("the shipped catalog loads");
        let wire = crate::directory::Directory::new(cat).wire_catalog();
        assert!(!wire.zones.is_empty(), "the wire catalog names zones");
        for z in &wire.zones {
            let room = ArenaServer::build_room(z, None)
                .unwrap_or_else(|e| panic!("zone {:?} refuses to serve: {e}", z.name));
            assert!(
                !room.maps.is_empty(),
                "zone {:?} opened without maps",
                z.name
            );
        }
    }
}

#[cfg(test)]
mod one_tick_weapons {
    use crate::sim;

    /// A repel is in the state for exactly one tick, which is why the client
    /// cannot be sent one.
    ///
    /// It is spawned in the ship phase and ends in the weapon phase of the
    /// very next step, so the only snapshot that can carry it is one packed on
    /// the tick it was fired. At `SNAPSHOT_EVERY` of 5 that is one shove in
    /// five with a picture on it. The explicit public charge event covers the
    /// other four without shipping the firer's private inventory.
    ///
    /// This is here to fail if that stops being true, because the day a repel
    /// lives long enough to be packed is the day the client should go back to
    /// drawing it from the weapon like everything else.
    #[test]
    fn a_repel_is_gone_before_a_snapshot_can_carry_it() {
        let mut w = sim::World::new(7);
        let a = w.spawn(0, 0, 30, 30, 0);
        assert!(a >= 0);
        w.state.ships[a as usize].charge[0] = 3;
        for _ in 0..30 {
            w.step(&[]);
        }
        let mut buf = vec![0u8; sim::STATE_PACK_MAX];
        let mut carried = Vec::new();
        for t in 0..12 {
            let buttons = if t == 0 { sim::BTN_USE } else { 0 };
            w.step(&[sim::sim_input {
                ship: a as u8,
                buttons,
            }]);
            let n = w.pack(&mut buf);
            let mut view = sim::World::new(1);
            view.apply_snapshot(&buf[..n as usize]);
            if view.state.weapon_count > 0 {
                carried.push(t);
            }
        }
        assert_eq!(
            carried,
            vec![0],
            "a repel should be packable on exactly the tick it is fired"
        );
    }
}
