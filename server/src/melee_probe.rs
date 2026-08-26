//! What a team battle looks like from inside, per pilot.
//!
//!     vectorwake-server melee [matches] [map]
//!
//! `drill` says what the roster does on a map and ranks nobody. `calibrate
//! teams` ranks hulls with every pilot held at one skill. Neither answers the
//! question a player asks after an evening in Team Battle: is the room a
//! contest between pilots, or a crossfire that eight people happen to be
//! standing in.
//!
//! So this runs the shipped format exactly: the authored pilots at their own
//! competences, in their own hulls, wearing the kit `shopper` builds for their
//! build plan, four a side, three minutes, under melee tuning on a melee map.
//! It reports each pilot's score beside the skill they were written with, how
//! many rounds were in the air while they did it, how many guns were on them
//! when they died, and how often they died without a fight to lose.
//!
//! Three variables move one thing each, so a suspicion can be tested against
//! the same room rather than argued about:
//!
//!   VW_MELEE_SIDE    pilots a side, to tell a crowd from a weapon
//!   VW_MELEE_DELAY   `multi_delay`, what a round of spray costs in cooldown
//!   VW_MELEE_SPRAY   the spray ceiling outright, above the live one or below
//!                    it, so the fan can be taken away or opened to what the
//!                    zone file asks for
//!   VW_MELEE_PLAN    one build for everybody, to tell a pilot from its kit

use crate::{ai, calibrate::spec_triggers, config, nav, pilots, shopper, sim};

const HZ: u32 = 100;

/// How long before a death still counts as part of the fight that ended it.
const LAST_BREATH: u32 = 100;

/// Where spray sits in the flat kit space, and the two weapon ladders.
const SPRAY: usize = sim::slot_mod(sim::TRIG_GUN, sim::MOD_MULTI) as usize;
const GUN_RUNG: usize = sim::slot_level(sim::TRIG_GUN) as usize;
const BOMB_RUNG: usize = sim::slot_level(sim::TRIG_BOMB) as usize;

/// The pilots a Team Battle room draws from. `bots::claim` walks the pool from
/// the front, so the authored eight are the ones a live room actually seats.
const ROSTER: usize = pilots::PROVISIONAL_LADDER_RUNG_COUNT;

/// The room, unpacked and tuned. `Arena::build` salts the same way, and the
/// salt is what makes twenty matches twenty matches rather than one repeated.
///
/// `VW_MELEE_SPRAY` lands here rather than on the caller's copy of the
/// ceiling, because `sim_set_kit` checks the arena's own and refuses a kit
/// built past it. Set rather than clamped down: the live ceiling is not
/// necessarily the one the zone asked for, since `Room::apply_config` caps
/// every add-on at `MOD_MAX` and spray's own maximum is higher. Running above
/// the live ceiling is how that difference gets a number on it.
fn open(map: &[u8], salt: u32, tuning: &config::ArenaConfig) -> sim::World {
    match sim::World::from_packed(0x5ea1 ^ salt, map) {
        Ok(mut world) => {
            crate::Room::apply_config(&mut world, tuning);
            if let Some(cap) = knob("VW_MELEE_SPRAY") {
                world.cfg.kit_ceiling[SPRAY] = (cap as u8).min(sim::mod_max(sim::MOD_MULTI));
            }
            world
        }
        Err(e) => {
            println!("melee: the map will not open: {e:?}");
            std::process::exit(1);
        }
    }
}

struct Seat {
    name: String,
    skill: f32,
    plan: pilots::BuildPlan,
    strategy: pilots::Strategy,
    multi: u8,
    /// What the thirty points bought on each ladder. A rung of nothing is the
    /// weapon the trigger already fires.
    gun_rung: u8,
    bomb_rung: u8,
    kills: u32,
    deaths: u32,
    shots: u32,
    hits: u32,
    /// Rounds that actually left a barrel, split by which trigger threw them.
    /// Counted off `EV_FIRE` rather than off the button word, because a gun is
    /// held and a bomb is a press and the two press counts cannot be compared.
    gun_rounds: u32,
    bomb_rounds: u32,
    /// Trigger presses, which is the brain's opinion rather than the core's.
    /// A bomb nobody presses and a bomb nobody is allowed to throw are
    /// different faults with the same symptom.
    bomb_presses: u32,
    repels: u32,
    /// Ticks lived and lives completed, so a mean life is a mean life.
    life_ticks: u64,
    lives: u32,
    /// Ticks from each spawn to that life's first repel, over the lives that
    /// spent one.
    first_repel_ticks: u64,
    first_repels: u32,
    /// When each of the three went, counted from the start of the match rather
    /// than the start of a life. Charges are dealt once a match and a death
    /// re-deals only the frame, so this is the whole of a pilot's supply and
    /// these are the three moments it is gone.
    spent_at: [u64; 3],
    spent_n: [u32; 3],
    /// Distinct enemies who landed something in the last second of a life,
    /// summed over deaths. One is a duel lost; three is a crossfire.
    guns_on_me: u32,
    /// Deaths where the pilot was not fighting anybody: it was traveling,
    /// leaving, recovering or idle when the round arrived.
    died_out_of_fight: u32,
}

/// Who plays this match and which side they are on.
///
/// A fixed seat order stacks the sides: the roster is written weak to strong
/// in places, so seating it in order puts the two worst pilots on one team and
/// hands the other a walkover. That reads as a skill effect and is a seating
/// effect, which is exactly the mistake this probe exists to avoid. So the
/// roster is shuffled every match and dealt alternately, and a room smaller
/// than the roster takes the front of the shuffle: over twenty matches every
/// pilot plays about as often, on both sides, beside everybody.
fn lineup(roster: usize, seats: usize, salt: u32) -> Vec<usize> {
    let mut who: Vec<usize> = (0..roster).collect();
    let mut rng = salt | 1;
    for i in (1..who.len()).rev() {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        who.swap(i, (rng % (i as u32 + 1)) as usize);
    }
    who.truncate(seats);
    who
}

fn play(
    roster: &mut [Seat],
    map: &[u8],
    tuning: &config::ArenaConfig,
    ceiling: &[u8; sim::SLOT_COUNT],
    salt: u32,
    ticks: u32,
    per_side: usize,
) -> f64 {
    let mut world = open(map, salt, tuning);
    let route = nav::Nav::build(&world.map);

    let playing = lineup(roster.len(), per_side * 2, salt);
    let mut ships: Vec<u8> = Vec::with_capacity(playing.len());
    for (i, &pilot) in playing.iter().enumerate() {
        let spec = pilots::individual(pilot);
        // Dealt alternately rather than in blocks, so a shuffle that happens
        // to come out ordered still splits the strength across both sides.
        let team = (i % 2) as u8;
        let id = world.spawn_on_map(spec.hull, team, (i / 2) as u32, 0);
        if id < 0 {
            println!("melee: the map has no start for seat {i}");
            std::process::exit(1);
        }
        let kit = shopper::build(&shopper::wants(plan_of(pilot)), ceiling);
        if !world.set_kit(id as usize, &kit) {
            println!("melee: seat {i} will not wear its kit");
            std::process::exit(1);
        }
        ships.push(id as u8);
    }
    // A live room deals every kit and then restarts: full bars, loaded
    // charges, authored starts. Anything else measures a fixture the game
    // never opens.
    world.restart();

    let mut bots: Vec<ai::Bot> = ships
        .iter()
        .zip(&playing)
        .enumerate()
        .map(|(i, (&s, &pilot))| {
            let mut b = ai::Bot::new(s, &pilots::individual(pilot));
            b.reseed(salt.wrapping_mul(2246822519) ^ (i as u32).wrapping_mul(2654435761));
            b
        })
        .collect();

    // Which trigger a fire event came from. `EV_FIRE` carries the pattern's
    // spec, so ask each hull's own table which trigger owns that spec.
    let trig_of: Vec<std::collections::HashMap<u8, usize>> = playing
        .iter()
        .map(|&pilot| spec_triggers(&world.cfg, pilots::individual(pilot).hull))
        .collect();

    // A ship number reaches the roster row that is flying it.
    let seat_of = |ship: u8| ships.iter().position(|&s| s == ship);
    let n = ships.len();
    let mut air = 0u64;
    let mut age = vec![0u32; n];
    let mut repelled = vec![false; n];
    // When each seat was last hit by each other seat, so the last second of a
    // life can be read off without keeping a log.
    let mut hit_at = vec![vec![0u32; n]; n];
    let mut doing = vec![0usize; n];

    for _ in 0..ticks {
        let mut inputs: Vec<sim::sim_input> = Vec::with_capacity(ships.len());
        for i in 0..ships.len() {
            let own = ai::own(&world, ships[i]);
            let look = bots[i].looks_due().then(|| ai::scan(&world, ships[i]));
            let buttons = bots[i].think(&own, &route, look);
            doing[i] = bots[i].doing();
            if buttons & sim::BTN_BOMB != 0 {
                roster[playing[i]].bomb_presses += 1;
            }
            inputs.push(sim::sim_input {
                ship: ships[i],
                buttons,
            });
        }
        world.step(&inputs);
        air += world.state.weapon_count as u64;
        let now = world.state.tick;

        let ev = &*world.events;
        for k in 0..ev.count as usize {
            let e = ev.e[k];
            match e.etype {
                sim::EV_FIRE => {
                    if let Some(i) = seat_of(e.a) {
                        let s = &mut roster[playing[i]];
                        s.shots += 1;
                        match trig_of[i].get(&e.b) {
                            Some(&sim::TRIG_BOMB) => s.bomb_rounds += 1,
                            _ => s.gun_rounds += 1,
                        }
                    }
                }
                sim::EV_HIT => {
                    if e.a == e.b {
                        continue;
                    }
                    if let Some(i) = seat_of(e.a) {
                        roster[playing[i]].hits += 1;
                    }
                    if let (Some(shooter), Some(victim)) = (seat_of(e.a), seat_of(e.b)) {
                        hit_at[victim][shooter] = now;
                    }
                }
                sim::EV_CHARGE => {
                    // b is the slot; slot zero is the repel everywhere this
                    // game ships.
                    if e.b == 0 {
                        if let Some(i) = seat_of(e.a) {
                            let s = &mut roster[playing[i]];
                            // The count is still the one before this charge,
                            // so it is this charge's place in the rack.
                            let nth = s.repels as usize;
                            if nth < s.spent_at.len() {
                                s.spent_at[nth] += now as u64;
                                s.spent_n[nth] += 1;
                            }
                            s.repels += 1;
                            if !repelled[i] {
                                repelled[i] = true;
                                s.first_repel_ticks += age[i] as u64;
                                s.first_repels += 1;
                            }
                        }
                    }
                }
                sim::EV_DEATH => {
                    let (victim, killer) = (e.a, e.b);
                    if let Some(i) = seat_of(victim) {
                        let recent = hit_at[i]
                            .iter()
                            .filter(|&&t| t > 0 && now.saturating_sub(t) <= LAST_BREATH)
                            .count();
                        let s = &mut roster[playing[i]];
                        s.deaths += 1;
                        s.lives += 1;
                        s.life_ticks += age[i] as u64;
                        s.guns_on_me += recent as u32;
                        // 2 is Fight. Anything else is a pilot who was not in
                        // one when the round found them.
                        if doing[i] != 2 {
                            s.died_out_of_fight += 1;
                        }
                        age[i] = 0;
                        repelled[i] = false;
                        hit_at[i].iter_mut().for_each(|t| *t = 0);
                    }
                    if killer != 255 && killer != victim {
                        let hostile = (killer as usize) < world.state.ship_count as usize
                            && world.state.ships[killer as usize].team
                                != world.state.ships[victim as usize].team;
                        if hostile {
                            if let Some(i) = seat_of(killer) {
                                roster[playing[i]].kills += 1;
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        for i in 0..ships.len() {
            if world.state.ships[ships[i] as usize].alive != 0 {
                age[i] += 1;
            }
        }
    }
    air as f64 / ticks as f64
}

fn knob(name: &str) -> Option<u16> {
    std::env::var(name).ok().and_then(|v| v.parse().ok())
}

/// The build every seat flies, when the run is asking what a build is worth
/// rather than what a pilot is. `None` is the shipped arrangement: each pilot
/// flies the plan its spec names.
fn forced_plan() -> Option<pilots::BuildPlan> {
    match std::env::var("VW_MELEE_PLAN").ok()?.as_str() {
        "gunner" => Some(pilots::BuildPlan::Gunner),
        "bomber" => Some(pilots::BuildPlan::Bomber),
        "runner" => Some(pilots::BuildPlan::Runner),
        other => {
            println!("melee: {other:?} is not a build plan: gunner, bomber, runner");
            std::process::exit(1);
        }
    }
}

fn plan_of(pilot: usize) -> pilots::BuildPlan {
    forced_plan().unwrap_or_else(|| pilots::individual(pilot).build)
}

pub fn run() {
    let a: Vec<String> = std::env::args().collect();
    let matches: u32 = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(20);
    let map_name = a.get(3).cloned().unwrap_or_else(|| "drydock".into());
    let per_side = knob("VW_MELEE_SIDE").unwrap_or(4) as usize;
    if per_side == 0 || per_side > 8 {
        println!("melee: {per_side} a side is not a game");
        std::process::exit(1);
    }

    // A probe runs from a checkout and registers nothing, so the two variables
    // the catalog names are placeholders. `catalog::set_placeholder_identity`
    // is debug-only and this is worth running in release, where twenty matches
    // take nine seconds rather than four minutes.
    std::env::set_var(
        "VW_POOL_DIGEST",
        format!("sha256:{}", crate::catalog::sha256_hex(b"placeholder")),
    );
    std::env::set_var("VW_META_VERIFY", "0".repeat(64));
    let cat = match crate::catalog::load("catalog") {
        Ok(c) => c,
        Err(e) => {
            println!("melee: {e}");
            std::process::exit(1);
        }
    };
    let Some(def) = cat.zone("melee") else {
        println!("melee: no melee zone in the catalog");
        std::process::exit(1);
    };
    let mut tuning = def.arena.clone();
    if let Some(v) = knob("VW_MELEE_DELAY") {
        tuning.multi_delay = Some(v);
    }
    let maps = cat.map_bytes("melee");
    let Some((_, bytes)) = maps.iter().find(|(n, _)| n.contains(&map_name)) else {
        println!(
            "melee: no map matching {map_name:?}; have {}",
            maps.iter()
                .map(|(n, _)| n.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
        std::process::exit(1);
    };
    let map: &[u8] = bytes;

    // The ceiling a bot flies under: the zone's own, which is what a house
    // account that has bought everything the zone sells reaches.
    let ceiling = open(map, 1, &tuning).kit_ceilings();

    let mut seats: Vec<Seat> = (0..ROSTER)
        .map(|i| {
            let spec = pilots::individual(i);
            let plan = plan_of(i);
            let kit = shopper::build(&shopper::wants(plan), &ceiling);
            Seat {
                skill: (spec.competence.aim + spec.competence.judgment) / 2.0,
                name: spec.callsign,
                plan,
                strategy: spec.behavior.strategy,
                multi: kit[SPRAY],
                gun_rung: kit[GUN_RUNG],
                bomb_rung: kit[BOMB_RUNG],
                kills: 0,
                deaths: 0,
                shots: 0,
                hits: 0,
                gun_rounds: 0,
                bomb_rounds: 0,
                bomb_presses: 0,
                repels: 0,
                life_ticks: 0,
                lives: 0,
                first_repel_ticks: 0,
                first_repels: 0,
                spent_at: [0; 3],
                spent_n: [0; 3],
                guns_on_me: 0,
                died_out_of_fight: 0,
            }
        })
        .collect();

    let ticks = tuning.match_seconds.unwrap_or(180) as u32 * HZ;
    let mut air = 0.0;
    for m in 0..matches {
        air += play(
            &mut seats,
            map,
            &tuning,
            &ceiling,
            0x5eed_1eaf ^ m.wrapping_mul(2654435761),
            ticks,
            per_side,
        );
    }
    air /= matches as f64;

    let seated = per_side * 2;
    let mins = matches as f64 * ticks as f64 / (HZ as f64 * 60.0) * seated as f64 / ROSTER as f64;
    println!(
        "melee on {map_name}: {per_side} a side, {matches} matches of {}s, \
multi_delay {}, spray ceiling {}",
        ticks / HZ,
        tuning.multi_delay.unwrap_or(50),
        ceiling[SPRAY],
    );
    println!("  {air:.1} rounds in the air on average across the whole room");
    println!();
    println!(
        "  {:<11} {:>5} {:>7} {:>3} {:>6} {:>6} {:>6} {:>6} {:>6} {:>7} {:>5} {:>7}",
        "pilot",
        "skill",
        "plan",
        "spr",
        "kills",
        "deaths",
        "k/d",
        "acc%",
        "life",
        "repel@",
        "guns",
        "cold%"
    );
    for s in &seats {
        let plan = match s.plan {
            pilots::BuildPlan::Gunner => "gunner",
            pilots::BuildPlan::Bomber => "bomber",
            pilots::BuildPlan::Runner => "runner",
        };
        println!(
            "  {:<11} {:>5.2} {:>7} {:>3} {:>6} {:>6} {:>6.2} {:>6.1} {:>5.1}s {:>6.1}s \
{:>5.2} {:>6.0}%",
            s.name,
            s.skill,
            plan,
            s.multi,
            s.kills,
            s.deaths,
            s.kills as f64 / s.deaths.max(1) as f64,
            100.0 * s.hits as f64 / s.shots.max(1) as f64,
            s.life_ticks as f64 / s.lives.max(1) as f64 / HZ as f64,
            s.first_repel_ticks as f64 / s.first_repels.max(1) as f64 / HZ as f64,
            s.guns_on_me as f64 / s.deaths.max(1) as f64,
            100.0 * s.died_out_of_fight as f64 / s.deaths.max(1) as f64,
        );
    }

    println!();
    println!(
        "  {:<11} {:>12} {:>7} {:>4} {:>4} {:>10} {:>11} {:>9}",
        "pilot", "strategy", "plan", "gun", "bmb", "gun rounds", "bomb rounds", "gun:bomb"
    );
    for s in &seats {
        println!(
            "  {:<11} {:>12} {:>7} {:>4} {:>4} {:>10} {:>11} {:>9}",
            s.name,
            format!("{:?}", s.strategy).to_lowercase(),
            match s.plan {
                pilots::BuildPlan::Gunner => "gunner",
                pilots::BuildPlan::Bomber => "bomber",
                pilots::BuildPlan::Runner => "runner",
            },
            s.gun_rung,
            s.bomb_rung,
            s.gun_rounds,
            s.bomb_rounds,
            if s.bomb_rounds == 0 {
                "never".to_string()
            } else {
                format!("{:.0}:1", s.gun_rounds as f64 / s.bomb_rounds as f64)
            },
        );
    }
    println!();

    let deaths: u32 = seats.iter().map(|s| s.deaths).sum();
    let repels: u32 = seats.iter().map(|s| s.repels).sum();
    let guns: u32 = seats.iter().map(|s| s.guns_on_me).sum();
    let cold: u32 = seats.iter().map(|s| s.died_out_of_fight).sum();
    let kd: Vec<f64> = seats
        .iter()
        .map(|s| s.kills as f64 / s.deaths.max(1) as f64)
        .collect();
    let skills: Vec<f64> = seats.iter().map(|s| s.skill as f64).collect();
    println!();
    println!(
        "  {:.1} deaths per pilot-minute, {:.2} repels per pilot-match",
        deaths as f64 / mins / ROSTER as f64,
        repels as f64 / (matches as f64 * seated as f64 / ROSTER as f64) / ROSTER as f64,
    );
    println!(
        "  {:.2} guns on a pilot when it dies, {:.0}% of deaths with no fight on",
        guns as f64 / deaths.max(1) as f64,
        100.0 * cold as f64 / deaths.max(1) as f64,
    );
    let gun_rounds: u32 = seats.iter().map(|s| s.gun_rounds).sum();
    let bomb_rounds: u32 = seats.iter().map(|s| s.bomb_rounds).sum();
    let bomb_presses: u32 = seats.iter().map(|s| s.bomb_presses).sum();
    println!(
        "  {gun_rounds} gun rounds against {bomb_rounds} bomb, which is {}, off {bomb_presses} presses of the bomb",
        if bomb_rounds == 0 {
            "a room that never bombs".to_string()
        } else {
            format!("{:.0} to one", gun_rounds as f64 / bomb_rounds as f64)
        },
    );
    let nth = |k: usize| {
        let at: u64 = seats.iter().map(|s| s.spent_at[k]).sum();
        let n: u32 = seats.iter().map(|s| s.spent_n[k]).sum();
        at as f64 / n.max(1) as f64 / HZ as f64
    };
    println!(
        "  the rack is gone at {:.0}s, {:.0}s and {:.0}s of a {}s match",
        nth(0),
        nth(1),
        nth(2),
        ticks / HZ,
    );
    println!(
        "  k/d spread {:.2} to {:.2}, skill against k/d correlates {:+.2}",
        kd.iter().cloned().fold(f64::INFINITY, f64::min),
        kd.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
        pearson(&skills, &kd),
    );
}

fn pearson(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len() as f64;
    let mx = x.iter().sum::<f64>() / n;
    let my = y.iter().sum::<f64>() / n;
    let mut num = 0.0;
    let (mut dx, mut dy) = (0.0, 0.0);
    for i in 0..x.len() {
        num += (x[i] - mx) * (y[i] - my);
        dx += (x[i] - mx) * (x[i] - mx);
        dy += (y[i] - my) * (y[i] - my);
    }
    if dx <= 0.0 || dy <= 0.0 {
        return 0.0;
    }
    num / (dx.sqrt() * dy.sqrt())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The confound this probe was nearly wrong about. Seating the roster in
    /// order puts the two weakest pilots on one side and hands the other a
    /// walkover, which reads as a skill effect and is a seating effect. Over a
    /// run every pilot has to play about as often, on both sides.
    #[test]
    fn a_run_deals_the_roster_evenly_across_both_sides() {
        let (roster, seats) = (ROSTER, 8);
        let mut played = vec![0u32; roster];
        let mut on_team = vec![[0u32; 2]; roster];
        let runs = 400;
        for m in 0..runs {
            for (i, &pilot) in lineup(roster, seats, 0x5eed_1eaf ^ m).iter().enumerate() {
                played[pilot] += 1;
                on_team[pilot][i % 2] += 1;
            }
        }
        for (pilot, &n) in played.iter().enumerate() {
            assert_eq!(n, runs, "pilot {pilot} sat out a match in a full room");
            let [a, b] = on_team[pilot];
            let skew = (a as i64 - b as i64).abs() as f64 / runs as f64;
            assert!(skew < 0.15, "pilot {pilot} favors a side: {a} against {b}");
        }
    }

    /// And a room smaller than the roster still shares the seats out, which is
    /// what makes the crowd comparison a comparison.
    #[test]
    fn a_small_room_still_shares_its_seats_out() {
        let mut played = [0u32; ROSTER];
        let runs = 800;
        for m in 0..runs {
            for &pilot in &lineup(ROSTER, 2, 0x5eed_1eaf ^ m) {
                played[pilot] += 1;
            }
        }
        let want = 2.0 * runs as f64 / ROSTER as f64;
        for (pilot, &n) in played.iter().enumerate() {
            let off = (n as f64 - want).abs() / want;
            assert!(
                off < 0.2,
                "pilot {pilot} played {n} of an expected {want:.0}"
            );
        }
    }
}
