// ---- input scheduling --------------------------------------------------

use super::*;

fn a_player() -> Player {
    let (tx, rx) = mpsc::channel(OUT_QUEUE);
    // Held so the sender does not see a closed channel, though nothing here
    // sends: these tests are about which tick a button lands on.
    std::mem::forget(rx);
    Player {
        ship: 0,
        lifecycle: 1,
        buttons: 0,
        pending: Default::default(),
        input_ack: 0,
        input_mask: 0,
        input_receipts: 0,
        input_seen: false,
        applied_tick: 0,
        applied_input: false,
        last_input_at: 100,
        combat_until: None,
        lag: LagTracker::waiting_for_input(),
        name: "probe".into(),
        rid: "probe".into(),
        bot: false,
        safe: 0,
        owes_map: false,
        joined: 0,
        tx,
        presence: PresenceHandle::new(),
    }
}

/// The point of the whole exercise. A client running its clock ahead sends
/// an input before the tick it belongs to, and it has to wait there rather
/// than taking effect on arrival, or the two ends brake on different ticks.
#[test]
fn an_input_waits_for_the_tick_it_names() {
    let mut p = a_player();
    p.schedule(105, sim::BTN_FIRE, 100);
    for t in 100..105 {
        assert_eq!(p.buttons_at(t), 0, "fire took effect early, on tick {t}");
    }
    assert_eq!(p.buttons_at(105), sim::BTN_FIRE, "fire missed its own tick");
    // And stays held afterwards, because a key held down is the common case
    // and a tick with nothing scheduled must not read as hands off.
    assert_eq!(p.buttons_at(106), sim::BTN_FIRE);
    assert_eq!(p.buttons_at(120), sim::BTN_FIRE);
}

/// A client with no lead, which is every client until one ships with it.
/// Its inputs name ticks that have already run, and the honest answer is to
/// apply them now: the server must not rewind the room for one late packet.
#[test]
fn an_input_that_arrives_late_applies_now() {
    let mut p = a_player();
    p.schedule(90, sim::BTN_THRUST, 100);
    assert_eq!(p.buttons_at(100), sim::BTN_THRUST);
    assert!(p.pending.is_empty(), "a late input has nothing to wait for");
}

/// Two late inputs that swapped in flight, which the WebSocket could not
/// do and a datagram does.
///
/// The newer one is already applied when the older one turns up, and a
/// packet describing a tick that has been and gone must not undo it: the
/// pilot pressed fire on 201 and would have watched it come back released
/// because 200 arrived second.
#[test]
fn a_late_input_does_not_undo_a_newer_one() {
    let mut p = a_player();
    p.schedule(201, sim::BTN_FIRE, 203);
    p.schedule(200, 0, 203);
    assert_eq!(
        p.buttons_at(203),
        sim::BTN_FIRE,
        "a stale datagram put the buttons back"
    );
    // And the lane still works forwards: the next tick's input lands.
    p.schedule(204, 0, 204);
    assert_eq!(p.buttons_at(204), 0);
}

#[test]
fn a_repeat_of_the_last_consumed_tick_is_ignored() {
    let mut p = a_player();
    p.schedule(201, sim::BTN_FIRE, 203);
    assert_eq!(p.buttons_at(203), sim::BTN_FIRE);
    p.schedule(201, 0, 204);
    assert_eq!(
        p.buttons_at(204),
        sim::BTN_FIRE,
        "a repeated history entry undid the tick already consumed"
    );
}

#[test]
fn an_input_message_carries_selective_repair_records() {
    let records = [(40, 1), (42, 4), (47, 8)];
    let msg = input_message(7, 12, 0b1011, &records);
    let packet = input_packet(&msg).expect("valid input packet");
    assert_eq!(packet.lifecycle, 7);
    assert_eq!(packet.snapshot_ack, 12);
    assert_eq!(packet.snapshot_mask, 0b1011);
    assert_eq!(packet.records, records);
    assert!(input_packet(&[C2S_INPUT, 0, 0, 0, 0, 0, 0, 0, 0, 0]).is_none());
    assert_eq!(
        input_packet(&[C2S_INPUT, 5, 0, 0, 0, 0, 0, 0, 0, 0]).map(|packet| packet.records),
        None
    );
}

#[test]
fn input_receipts_preserve_holes_and_accept_repairs() {
    let mut p = a_player();
    p.schedule(40, 1, 30);
    p.schedule(42, 4, 30);
    assert_eq!(p.input_ack, 42);
    assert_eq!(p.input_mask & 0b111, 0b101, "tick 41 remains a hole");
    p.schedule(41, 2, 30);
    assert_eq!(p.input_mask & 0b111, 0b111, "the selective repair lands");
}

#[test]
fn input_synchronization_requires_current_and_future_ticks() {
    let mut p = a_player();
    p.schedule(100, 1, 99);
    p.schedule(101, 1, 99);
    assert!(
        !p.input_window_ready(100),
        "touching the arena clock is not yet a stable input stream"
    );
    p.schedule(102, 1, 99);
    assert!(p.input_window_ready(100));
}

#[test]
fn timely_inputs_outlive_the_wire_repair_window() {
    let mut p = a_player();
    let now = 100;
    for tick in now..=now + 35 {
        p.schedule(tick, sim::BTN_THRUST, now);
    }

    assert_eq!(p.input_ack, now + 35);
    assert!(
        p.input_window_ready(now),
        "a valid 35-tick lead must not become 100% missed input"
    );
    assert!(p.received_input(now));
}

#[test]
fn inputs_and_receipts_cross_the_tick_rollover() {
    let mut p = a_player();
    p.last_input_at = u32::MAX - 2;
    p.schedule(u32::MAX, sim::BTN_THRUST, u32::MAX - 2);
    p.schedule(0, sim::BTN_BOMB, u32::MAX - 2);
    p.schedule(1, sim::BTN_FIRE, u32::MAX - 2);

    assert_eq!(p.buttons_at(u32::MAX), sim::BTN_THRUST);
    assert_eq!(p.buttons_at(0), sim::BTN_BOMB);
    assert_eq!(p.buttons_at(1), sim::BTN_FIRE);
    assert_eq!(p.input_ack, 1);
    assert!(p.received_input(u32::MAX));
    assert!(p.received_input(0));
    assert!(p.received_input(1));
}

#[test]
fn silence_releases_dangerous_controls_then_everything() {
    let mut p = a_player();
    p.buttons = sim::BTN_THRUST | sim::BTN_FIRE | sim::BTN_BOMB;
    p.last_input_at = 100;

    assert_eq!(
        p.buttons_at(125),
        sim::BTN_THRUST,
        "weapons stop before a suspended browser can keep firing"
    );
    assert_eq!(p.buttons_at(200), 0, "all held controls eventually release");
}

#[test]
fn snapshot_receipts_measure_round_trip_on_the_server_clock() {
    let mut lag = LagTracker::default();
    let first = lag.sent_snapshot(100, false, 500);
    let second = lag.sent_snapshot(105, true, 500);
    lag.acknowledge_snapshots(second, 0b11, 113, 500);
    assert_eq!(first, 1);
    assert_eq!(second, 2);
    assert_eq!(lag.rtt_ticks, 8.0, "the newest snapshot took eight ticks");
    assert!(lag.snapshots.iter().all(|s| s.received));

    let third = lag.sent_snapshot(120, false, 500);
    lag.acknowledge_snapshots(third, 1, 140, 500);
    assert!(
        (lag.rtt_ticks - 18.588_235).abs() < 0.000_001,
        "the newer sample represents the fifteen server ticks since the prior one"
    );
    assert_eq!(lag.jitter_ticks, 12.0, "jitter follows the RTT delta");
}

#[test]
fn snapshot_receipts_cross_sequence_and_tick_rollovers() {
    let mut lag = LagTracker {
        snapshot_seq: u32::MAX - 1,
        ..Default::default()
    };
    let before = lag.sent_snapshot(u32::MAX - 2, false, 500);
    let after = lag.sent_snapshot(1, false, 500);

    assert_eq!(before, u32::MAX);
    assert_eq!(after, 1, "zero remains the no-receipt sentinel");
    lag.acknowledge_snapshots(after, 0b11, 3, 500);
    assert_eq!(lag.snapshots.len(), 2);
    assert!(lag.snapshots.iter().all(|snapshot| snapshot.received));
    assert_eq!(lag.rtt_ticks, 2.0);
}

#[test]
fn loss_windows_measure_ticks_instead_of_packet_cadence() {
    fn sample(step: u32) -> LossRate {
        let mut rate = LossRate::default();
        for _ in 0..100 / step {
            rate.observe(true, 500, step);
        }
        for _ in 0..100 / step {
            rate.observe(false, 500, step);
        }
        rate
    }

    let input = sample(1);
    let combat = sample(COMBAT_SNAPSHOT_EVERY);
    let ordinary = sample(SNAPSHOT_EVERY);
    assert_eq!(input.sampled_ticks, 200);
    assert_eq!(combat.sampled_ticks, 200);
    assert_eq!(ordinary.sampled_ticks, 200);
    assert!((input.value - combat.value).abs() < f64::EPSILON);
    assert!((input.value - ordinary.value).abs() < f64::EPSILON);
}

#[test]
fn rtt_windows_measure_ticks_instead_of_snapshot_count() {
    fn sample(step: u32, combat: bool) -> LagTracker {
        let mut lag = LagTracker::default();
        for tick in (step..=100).step_by(step as usize) {
            let sequence = lag.sent_snapshot(tick, combat, 500);
            lag.acknowledge_snapshots(sequence, 1, tick + 10, 500);
        }
        lag
    }

    let combat = sample(COMBAT_SNAPSHOT_EVERY, true);
    let ordinary = sample(SNAPSHOT_EVERY, false);
    assert_eq!(combat.rtt_sampled_ticks, 100);
    assert_eq!(ordinary.rtt_sampled_ticks, 100);
    assert_eq!(combat.rtt_ticks, ordinary.rtt_ticks);
}

#[test]
fn an_ack_older_than_the_last_is_a_reordered_packet() {
    // Inputs ride datagrams and arrive out of order. An older ack taken as
    // new measured the retained window from its own stale number, which
    // wrapped for every snapshot in it, and the whole window was popped and
    // counted lost.
    let mut lag = LagTracker::default();
    let mut seqs = Vec::new();
    for tick in 1..=40 {
        seqs.push(lag.sent_snapshot(tick * 5, false, 500));
    }
    // Everything seen so far, which sets the baseline and keeps 32 in hand.
    lag.acknowledge_snapshots(seqs[39], u32::MAX, 210, 500);
    for tick in 41..=45 {
        seqs.push(lag.sent_snapshot(tick * 5, false, 500));
    }
    lag.acknowledge_snapshots(seqs[44], 1, 240, 500);
    let retained = lag.snapshots.len();
    assert!(
        retained >= 30,
        "recent sends are still in flight: {retained}"
    );
    assert_eq!(lag.down_loss.percent(), 0);
    // A datagram from before the window, arriving late.
    lag.acknowledge_snapshots(seqs[5], 1, 241, 500);
    assert_eq!(
        lag.snapshots.len(),
        retained,
        "a stale ack leaves the window alone"
    );
    assert_eq!(lag.down_loss.percent(), 0, "and counts nothing lost");
}

#[test]
fn first_snapshot_receipt_establishes_the_loss_baseline() {
    let mut lag = LagTracker::default();
    let mut last = 0;
    for tick in 1..=100 {
        last = lag.sent_snapshot(tick, false, 500);
    }

    assert_eq!(
        lag.down_loss.sampled_ticks, 0,
        "startup is not measured as loss"
    );
    lag.acknowledge_snapshots(last, 1, 110, 500);
    assert_eq!(lag.snapshots.len(), 1, "unknown startup sends are dropped");
    assert!(lag.snapshots.front().is_some_and(|sent| sent.received));
    assert_eq!(lag.down_loss.sampled_ticks, 0);
    assert_eq!(lag.down_loss.percent(), 0);
}

#[test]
fn input_misses_are_diagnostic_after_synchronization() {
    let cfg = config::LagConfig {
        input_sample_ticks: 5,
        ..Default::default()
    };
    let mut lag = LagTracker::waiting_for_input();
    assert!(
        lag.tick(&cfg, false, 10_000, 0).decision == LagDecision::default(),
        "seat age alone cannot turn loading time into input loss"
    );

    lag.synchronize_input();
    assert!(lag.input_synchronized);
    assert_eq!(lag.input_miss.sampled_ticks(), 0);
    for now in 1..=5 {
        lag.observe_input(true, cfg.input_sample_ticks);
        assert!(
            lag.tick(&cfg, false, now, 0).decision == LagDecision::default(),
            "missed tick deadlines are telemetry, not punishment"
        );
    }
    assert_eq!(lag.input_miss.percent(), 100);
}

#[test]
fn input_silence_restricts_then_recovers_immediately() {
    let cfg = config::LagConfig::default();
    assert_eq!(cfg.spectate_silence_ticks, 500);
    let mut lag = LagTracker::default();

    assert!(lag.tick(&cfg, false, 1, INPUT_RELEASE_TICKS - 1).decision == LagDecision::default());
    assert!(
        lag.tick(&cfg, false, 2, INPUT_RELEASE_TICKS)
            .decision
            .no_flags
    );
    assert!(
        lag.tick(&cfg, false, 3, 0).decision == LagDecision::default(),
        "one fresh packet clears the stale-input restriction"
    );
    let severe = lag
        .tick(&cfg, false, 4, cfg.spectate_silence_ticks)
        .decision;
    assert!(severe.no_flags && severe.spectate);
}

#[test]
fn path_measurements_never_restrict_gameplay() {
    let cfg = config::LagConfig::default();
    let mut lag = LagTracker {
        rtt_ticks: 500.0,
        jitter_ticks: 500.0,
        combat_active: true,
        ..Default::default()
    };
    lag.down_loss.value = 1.0;
    lag.combat_loss.value = 1.0;

    assert!(
        lag.tick(&cfg, false, 1, 0).decision == LagDecision::default(),
        "RTT, jitter and snapshot loss are diagnostics only"
    );
}

#[test]
fn combat_loss_is_reported_only_while_the_combat_lane_is_active() {
    let cfg = config::LagConfig {
        sample_ticks: 1,
        combat_idle_ticks: 3,
        ..Default::default()
    };
    let mut lag = LagTracker::default();
    lag.combat_loss.value = 0.216;
    lag.combat_loss.sampled_ticks = 1;
    lag.sent_snapshot(1, true, cfg.sample_ticks);

    assert!(lag.tick(&cfg, false, 1, 0).decision == LagDecision::default());
    assert_eq!(lag.combat_percent(), 22);

    lag.sent_snapshot(2, false, cfg.sample_ticks);
    assert_eq!(
        lag.combat_percent(),
        0,
        "idle combat loss is not current loss"
    );
    assert!(lag.tick(&cfg, false, 2, 0).decision == LagDecision::default());
    assert!(lag.tick(&cfg, false, 3, 0).decision == LagDecision::default());
    assert!(lag.tick(&cfg, false, 4, 0).decision == LagDecision::default());
    assert_eq!(lag.combat_loss.percent(), 0, "the stale sample expires");

    for tick in 3..=34 {
        lag.sent_snapshot(tick, false, cfg.sample_ticks);
    }
    lag.acknowledge_snapshots(34, u32::MAX, 35, cfg.sample_ticks);
    assert_eq!(
        lag.combat_loss.percent(),
        0,
        "an old combat snapshot cannot repopulate an expired sample"
    );

    lag.sent_snapshot(36, true, cfg.sample_ticks);
    assert_eq!(lag.combat_percent(), 0, "a later fight starts clean");
}

#[test]
fn ordinary_loss_remains_diagnostic_on_both_lanes() {
    let cfg = config::LagConfig {
        sample_ticks: 1,
        ..Default::default()
    };
    let mut lag = LagTracker::default();
    lag.down_loss.value = 0.33;
    lag.down_loss.sampled_ticks = 3;
    lag.sent_snapshot(1, true, cfg.sample_ticks);

    assert!(lag.tick(&cfg, false, 1, 0).decision == LagDecision::default());

    lag.sent_snapshot(2, false, cfg.sample_ticks);
    assert_eq!(lag.down_loss.percent(), 33);
    assert!(lag.tick(&cfg, false, 2, 0).decision == LagDecision::default());
}

#[test]
fn startup_input_gate_is_silent_and_resets_at_synchronization() {
    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    let (ship, id, _rx) = seat_rx(&mut a, "starting");
    let sh = a.world.state.ships[ship as usize];
    let flag = &mut a.world.state.flags[0];
    flag.active = 1;
    flag.carried = 0;
    flag.team = sim::TEAM_NONE;
    flag.x = sh.x;
    flag.y = sh.y;
    flag.cooldown = 0;

    a.tick();

    let p = &a.players[&id];
    assert!(p.lag.decision == LagDecision::default());
    assert_eq!(a.world.state.flags[0].carried, 0);

    let now = a.world.state.tick.wrapping_add(1);
    let input_sample_ticks = a.lag_policy.input_sample_ticks;
    let p = a.players.get_mut(&id).unwrap();
    for _ in 0..input_sample_ticks {
        p.lag.observe_input(true, input_sample_ticks);
    }
    for ahead in 0..=INPUT_SYNC_LEAD {
        p.schedule(now.wrapping_add(ahead), 0, now);
    }

    a.tick();

    let p = &a.players[&id];
    assert!(p.lag.input_synchronized);
    assert_eq!(p.lag.input_miss.sampled_ticks(), 1);
    assert_eq!(p.lag.input_miss.percent(), 0);
    assert!(p.lag.decision == LagDecision::default());
}

#[test]
fn downlink_diagnostics_do_not_suppress_weapon_inputs() {
    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    let (_ship, id, _rx) = seat_rx(&mut a, "lossy");
    let p = a.players.get_mut(&id).expect("pilot remains seated");
    p.lag.synchronize_input();
    p.lag.down_loss.value = 1.0;
    p.lag.combat_loss.value = 1.0;
    p.lag.rtt_ticks = 500.0;
    p.lag.jitter_ticks = 500.0;
    p.buttons = sim::BTN_FIRE;

    a.tick();

    assert!(
        a.world.state.weapon_count > 0,
        "path diagnostics must not remove the shot"
    );
}

#[test]
fn lagged_pilots_cannot_take_flags() {
    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    a.lag_policy.spectate_silence_ticks = u32::MAX;
    let (ship, id, _rx) = seat_rx(&mut a, "lossy");
    let stale_at = a.world.state.tick.wrapping_sub(INPUT_RELEASE_TICKS);
    let p = a.players.get_mut(&id).unwrap();
    p.lag.synchronize_input();
    p.last_input_at = stale_at;
    let sh = a.world.state.ships[ship as usize];
    let flag = &mut a.world.state.flags[0];
    flag.active = 1;
    flag.carried = 0;
    flag.team = sim::TEAM_NONE;
    flag.x = sh.x;
    flag.y = sh.y;
    flag.cooldown = 0;
    let before = *flag;

    a.tick();

    let after = a.world.state.flags[0];
    assert_eq!(after.carried, before.carried, "the pickup is rolled back");
    assert_eq!(after.team, before.team, "the flag keeps its prior owner");
    assert!(a.world.events.e[..a.world.events.count as usize]
        .iter()
        .all(|event| event.etype != sim::EV_FLAG_TAKE));
}

#[test]
fn sustained_input_silence_moves_a_pilot_to_the_stands() {
    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    a.lag_policy.spectate_silence_ticks = 1;
    let (ship, id, _rx) = seat_rx(&mut a, "lossy");
    let rid = a.players[&id].rid.clone();
    let p = a.players.get_mut(&id).unwrap();
    p.lag.synchronize_input();
    a.rating
        .damage(a.world.state.tick, &rid, "hunter", 500, false);
    a.world.state.ships[ship as usize].energy = 1;
    let before = a.rating.rating_of(&rid);

    a.tick();

    assert!(!a.players.contains_key(&id));
    assert!(a.watchers.contains_key(&id));
    assert_eq!(a.watchers[&id].lifecycle, 2);
    assert!(
        a.rating.rating_of(&rid) < before,
        "lag spectating keeps the quit-under-fire consequence"
    );
    a.fly(id, 0, 32).expect("the pilot may recover into a hull");
    assert_eq!(
        a.players[&id].lifecycle, 3,
        "the recovered hull cannot accept packets from the life before lag spectating"
    );
}

/// A pilot who did not ask to be in the stands is told which of the two ways
/// they got there.
///
/// The client cannot work this out for itself. Both involuntary benchings
/// arrive as an ordinary welcome on seat 255, identical to the one a pilot
/// gets for pressing the key, and the frame served under it is five seconds
/// old: the first thing on screen is the pilot's own hull, still flying. So
/// the reason rides the message that takes the seat away rather than being
/// paired up at the far end with a lag notice by timing.
#[test]
fn a_bench_says_why_on_the_welcome_that_takes_the_seat() {
    let reason = |rx: &mut mpsc::Receiver<Message>| -> Vec<(u8, u8)> {
        drain(rx)
            .iter()
            .filter(|m| m.first() == Some(&S2C_WELCOME))
            .map(|m| (m[1], *m.last().expect("a welcome carries its reason")))
            .collect()
    };

    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    a.lag_policy.spectate_silence_ticks = 1;
    let (_, id, mut rx) = seat_rx(&mut a, "lossy");
    a.players.get_mut(&id).unwrap().lag.synchronize_input();
    a.tick();
    assert_eq!(
        reason(&mut rx),
        vec![(255, WHY_LAG)],
        "the room took the seat for silence and says so"
    );

    // And the way back carries nothing to say: the pilot asked for this one.
    a.fly(id, 0, 32).expect("the pilot may recover into a hull");
    assert_eq!(
        reason(&mut rx)
            .iter()
            .map(|(_, why)| *why)
            .collect::<Vec<_>>(),
        vec![WHY_NONE],
    );

    // The safe-zone sweep is the other one nobody asked for, and it is a
    // different sentence at the far end.
    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    a.lag_policy.spectate_silence_ticks = u32::MAX;
    let (_, id, mut rx) = seat_rx(&mut a, "loiterer");
    drain(&mut rx);
    assert!(a.sit_out(id, true));
    assert_eq!(reason(&mut rx), vec![(255, WHY_SAFE)]);

    // Pressing the key is not news. It is the same operation and the same
    // message, and the only one of the three the pilot already knows about.
    let mut a = room_with_teams("teams = [\"Keel\"]\n");
    a.lag_policy.spectate_silence_ticks = u32::MAX;
    let (_, id, mut rx) = seat_rx(&mut a, "asker");
    drain(&mut rx);
    assert!(a.sit_out(id, false));
    assert_eq!(reason(&mut rx), vec![(255, WHY_NONE)]);
}

#[test]
fn nearby_hostiles_select_the_combat_snapshot_lane() {
    let mut world = sim::World::new(1);
    let me = world.spawn(0, 0, 500, 500, 0) as u8;
    let hostile = world.spawn(0, 1, 531, 500, 0) as u8;
    assert!(near_combat(&world, me));
    world.state.ships[hostile as usize].x += 2 * sim::TILE_PX * 256;
    assert!(!near_combat(&world, me));
}

#[test]
fn combat_snapshot_delivery_runs_at_fifty_hertz() {
    let mut a = room_with_teams("teams = [\"Keel\", \"Vantage\"]\n");
    let (me, _id, mut rx) = seat_rx(&mut a, "near");
    let hostile = seat_human(&mut a, "hostile");
    assert_ne!(
        a.world.state.ships[me as usize].team,
        a.world.state.ships[hostile as usize].team
    );
    let mine = a.world.state.ships[me as usize];
    let other = &mut a.world.state.ships[hostile as usize];
    other.x = mine.x + 31 * sim::TILE_PX * 256;
    other.y = mine.y;
    drain(&mut rx);

    let mut buf = vec![0u8; sim::PACK_MAX];
    for frame in 1..=10 {
        a.world.state.tick = frame;
        let (ordinary, combat) = snapshot_lanes(frame);
        if combat {
            a.broadcast_player_snapshots(&mut buf, true);
        }
        if ordinary {
            a.broadcast_player_snapshots(&mut buf, false);
        }
    }
    assert_eq!(
        snapshots(&drain(&mut rx)).len(),
        5,
        "nearby combat gets five snapshots in ten ticks"
    );

    a.world.state.ships[hostile as usize].x = mine.x + 33 * sim::TILE_PX * 256;
    for frame in 11..=20 {
        a.world.state.tick = frame;
        let (ordinary, combat) = snapshot_lanes(frame);
        if combat {
            a.broadcast_player_snapshots(&mut buf, true);
        }
        if ordinary {
            a.broadcast_player_snapshots(&mut buf, false);
        }
    }
    assert_eq!(
        snapshots(&drain(&mut rx)).len(),
        5,
        "the combat lane does not flap at the radius boundary"
    );

    for frame in 21..=110 {
        a.world.state.tick = frame;
        let (ordinary, combat) = snapshot_lanes(frame);
        if combat {
            a.broadcast_player_snapshots(&mut buf, true);
        }
        if ordinary {
            a.broadcast_player_snapshots(&mut buf, false);
        }
    }
    drain(&mut rx);
    for frame in 111..=120 {
        a.world.state.tick = frame;
        let (ordinary, combat) = snapshot_lanes(frame);
        if combat {
            a.broadcast_player_snapshots(&mut buf, true);
        }
        if ordinary {
            a.broadcast_player_snapshots(&mut buf, false);
        }
    }
    assert_eq!(
        snapshots(&drain(&mut rx)).len(),
        2,
        "ordinary cadence returns after the one-second combat tail"
    );
}

/// Ticks arrive in order on this transport, but the clamp can lower one, so
/// the queue is keyed by tick rather than by arrival. Out of order in, in
/// order out.
#[test]
fn scheduled_inputs_come_out_in_tick_order() {
    let mut p = a_player();
    p.schedule(112, sim::BTN_FIRE, 100);
    p.schedule(105, sim::BTN_THRUST, 100);
    assert_eq!(p.buttons_at(105), sim::BTN_THRUST);
    assert_eq!(p.buttons_at(111), sim::BTN_THRUST);
    assert_eq!(p.buttons_at(112), sim::BTN_FIRE);
}

/// A repeat for a tick already spoken for is the client correcting itself
/// inside the window, so the newer one is what it meant.
#[test]
fn the_newest_input_for_a_tick_wins() {
    let mut p = a_player();
    p.schedule(105, sim::BTN_FIRE, 100);
    p.schedule(105, sim::BTN_THRUST, 100);
    assert_eq!(p.buttons_at(105), sim::BTN_THRUST);
}

/// A clock that has drifted is a client to correct, not one to disconnect,
/// so an absurd lead is clamped rather than refused. Without this a client
/// could queue a minute of flying and then stop sending.
#[test]
fn a_wild_lead_is_clamped_rather_than_honoured() {
    let mut p = a_player();
    p.schedule(100_000, sim::BTN_FIRE, 100);
    assert_eq!(
        *p.pending.keys().next().unwrap(),
        100 + INPUT_LEAD_MAX,
        "an input a minute ahead should land at the ceiling"
    );
}

/// The echoed tick is what the arena accepted, not what was asked for. A
/// client steers its clock off this number, so a clamped input that
/// reported its unclamped tick would tell the client its inputs were
/// arriving impossibly early and drive the lead to zero.
#[test]
fn the_echoed_tick_is_the_one_that_was_accepted() {
    let mut p = a_player();
    p.schedule(100_000, sim::BTN_FIRE, 100);
    assert_eq!(p.input_ack, 100 + INPUT_LEAD_MAX);
}

/// A room that has been up for 497 days crosses u32::MAX. The lead ceiling
/// remains ahead on the serial clock instead of becoming ancient.
#[test]
fn the_lead_ceiling_crosses_the_end_of_the_clock() {
    let mut p = a_player();
    let now = u32::MAX - 10;
    p.last_input_at = now;
    p.schedule(200, sim::BTN_FIRE, now);
    let accepted = now.wrapping_add(INPUT_LEAD_MAX);
    assert!(p.pending.contains_key(&accepted));
    p.last_input_at = accepted;
    assert_eq!(p.buttons_at(accepted.wrapping_sub(1)), 0);
    assert_eq!(p.buttons_at(accepted), sim::BTN_FIRE);
}

/// And a client that floods cannot grow the arena's memory with it.
#[test]
fn the_input_queue_is_bounded() {
    let mut p = a_player();
    for t in 1..=(INPUT_QUEUE_MAX as u32 * 3) {
        p.schedule(100 + t, sim::BTN_FIRE, 100);
    }
    assert!(
        p.pending.len() <= INPUT_QUEUE_MAX,
        "queue grew to {}",
        p.pending.len()
    );
}
