//! Record a real fight to a file, so something outside the server can draw it.
//!
//!     vectorwake-server battlecap <zone> <seconds> <bots> <out.vwcap>
//!
//! Same room and same brains as [`crate::drill`]: a zone's own map, the AI
//! roster flying it, two teams. What this adds is that every tick is written
//! down, positions, rounds, events and all, which is the difference between a
//! number about a fight and a fight somebody can look at.
//!
//! It exists for `.design/ships3d`, which renders the hulls with a third
//! dimension under them and needed a battle to put them in that nobody had
//! posed. Nothing in the shipping game reads a `.vwcap`.

use crate::{ai, nav, sim};
use std::io::Write;

const HZ: u32 = 100;

fn u16le(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn u32le(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn i32le(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&v.to_le_bytes());
}

/// Fly `bots` pilots on `map` for `ticks` and write every one of them down.
pub fn record(
    map: std::sync::Arc<sim::sim_map>,
    bots: usize,
    ticks: u32,
    seed: u32,
    every: u32,
) -> Vec<u8> {
    let route = nav::Nav::build(&map);
    let mut w = sim::World::on_shared_map(seed, map);
    let mut out: Vec<u8> = Vec::new();

    out.extend_from_slice(b"VWCAP1");
    let (mw, mh) = (w.map.w, w.map.h);
    u16le(&mut out, mw);
    u16le(&mut out, mh);
    for ty in 0..mh as usize {
        for tx in 0..mw as usize {
            out.push(w.map.tile[ty * sim::MAP_TILES + tx]);
        }
    }

    // What each projectile spec is, so a renderer can tell a bullet from a
    // bomb without knowing anything about ladders. The same walk drill does.
    let mut spec_kind = [0u8; 256];
    let mut spec_blast = [0i32; 256];
    {
        let c = &w.cfg;
        for (s, blast) in spec_blast
            .iter_mut()
            .enumerate()
            .take(c.spec_count as usize)
        {
            *blast = c.specs[s].blast;
        }
        let mut mark = |pat: u8, kind: u8| {
            if pat != u8::MAX {
                if let Some(p) = c.patterns.get(pat as usize) {
                    spec_kind[p.spec as usize] = kind;
                }
            }
        };
        for cls in 0..c.class_count as usize {
            for r in 0..sim::MAX_RUNGS {
                mark(c.classes[cls].trigger[sim::TRIG_BOMB][r], 1);
            }
        }
        mark(c.charge[sim::CHARGE_MINE], 2);
    }
    out.push(255);
    for s in 0..255usize {
        out.push(spec_kind[s]);
        i32le(&mut out, spec_blast[s]);
    }

    let mut brains = Vec::new();
    for i in 0..bots {
        let e = ai::individual(i);
        let ship = w.spawn_on_map(e.class, (i % 2) as u8, i as u32, 0) as u8;
        let mut b = ai::Bot::new(ship, e.skill);
        b.reseed(seed ^ (i as u32).wrapping_mul(2654435761));
        brains.push(b);
    }

    // Frame count is patched in once the run is over: how many frames a fight
    // has is not a thing you know before flying it.
    let frames_at = out.len();
    u32le(&mut out, 0);
    let mut frames = 0u32;
    let mut inputs = Vec::with_capacity(bots);
    let mut thrusting = vec![0u8; sim::MAX_SHIPS];

    for tick in 0..ticks {
        inputs.clear();
        for b in brains.iter_mut() {
            let ship = b.ship;
            let fresh = b.looks_due().then(|| ai::scan(&w, ship));
            let o = ai::own(&w, ship);
            let buttons = b.think(&o, &route, fresh);
            thrusting[ship as usize] = u8::from(buttons & sim::BTN_THRUST != 0);
            inputs.push(sim::sim_input { ship, buttons });
        }
        w.step(&inputs);
        if tick % every != 0 {
            continue;
        }
        frames += 1;
        u32le(&mut out, w.state.tick);
        out.push(w.state.ship_count);
        for (i, thrust) in thrusting
            .iter()
            .enumerate()
            .take(w.state.ship_count as usize)
        {
            let s = &w.state.ships[i];
            out.push(s.cls);
            out.push(s.team);
            out.push(s.alive);
            out.push(*thrust);
            i32le(&mut out, s.x);
            i32le(&mut out, s.y);
            u16le(&mut out, s.heading);
            i32le(&mut out, s.energy);
        }
        u16le(&mut out, w.state.weapon_count);
        for i in 0..w.state.weapon_count as usize {
            let p = &w.state.weapons[i];
            out.push(p.spec);
            out.push(p.team);
            out.push(p.level);
            i32le(&mut out, p.x);
            i32le(&mut out, p.y);
            i32le(&mut out, p.vx);
            i32le(&mut out, p.vy);
            u16le(&mut out, p.life);
        }
        let ev = &*w.events;
        let n = ev.count.min(255) as usize;
        out.push(n as u8);
        for e in ev.e.iter().take(n) {
            out.push(e.etype);
            out.push(e.a);
            out.push(e.b);
            i32le(&mut out, e.v);
        }
    }
    out[frames_at..frames_at + 4].copy_from_slice(&frames.to_le_bytes());
    out
}

pub fn run() {
    let a: Vec<String> = std::env::args().collect();
    let zone = a.get(2).cloned().unwrap_or_else(|| "melee".into());
    let secs: u32 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(45);
    let bots: usize = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(8);
    let path = a.get(5).cloned().unwrap_or_else(|| "battle.vwcap".into());
    let map_i: usize = a.get(6).and_then(|s| s.parse().ok()).unwrap_or(0);
    let seed: u32 = a.get(7).and_then(|s| s.parse().ok()).unwrap_or(0xd2111);

    #[cfg(debug_assertions)]
    crate::catalog::set_placeholder_identity();
    let cat = match crate::catalog::load("catalog") {
        Ok(c) => c,
        Err(e) => {
            println!("battlecap: {e}");
            std::process::exit(1);
        }
    };
    let maps = cat.map_bytes(&zone);
    let Some((name, bytes)) = maps.get(map_i % maps.len().max(1)) else {
        println!("battlecap: zone {zone:?} has no map");
        std::process::exit(1);
    };
    let map = match sim::unpack_map(bytes) {
        Ok(m) => m,
        Err(e) => {
            println!("battlecap: zone {zone:?}: {e}");
            std::process::exit(1);
        }
    };
    let (mw, mh) = (map.w, map.h);
    let blob = record(map, bots, secs * HZ, seed, 1);
    match std::fs::File::create(&path).and_then(|mut f| f.write_all(&blob)) {
        Ok(()) => println!(
            "battlecap: {zone}/{name} {mw}x{mh}, {bots} bots, {secs}s -> {path} ({} KiB)",
            blob.len() / 1024
        ),
        Err(e) => {
            println!("battlecap: cannot write {path}: {e}");
            std::process::exit(1);
        }
    }
}
