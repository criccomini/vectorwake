use crate::{config, protocol::S2C_LAG, sim};

pub(crate) const SNAPSHOT_EVERY: u32 = 5; // 20 Hz
pub(crate) const COMBAT_SNAPSHOT_EVERY: u32 = 2; // 50 Hz
pub(crate) const COMBAT_INTEREST: i32 = 32 * 16 * 256;
pub(crate) const COMBAT_TAIL_TICKS: u32 = 100;
pub(crate) const SERIAL_HALF: u32 = 1 << 31;

pub(crate) fn serial_after(a: u32, b: u32) -> bool {
    a != b && a.wrapping_sub(b) < SERIAL_HALF
}

pub(crate) fn serial_before(a: u32, b: u32) -> bool {
    serial_after(b, a)
}

pub(crate) fn serial_at_or_before(a: u32, b: u32) -> bool {
    a == b || serial_before(a, b)
}

pub(crate) fn serial_elapsed(now: u32, before: u32) -> u32 {
    now.wrapping_sub(before)
}

pub(crate) fn next_nonzero(value: u32) -> u32 {
    value.wrapping_add(1).max(1)
}

// Snapshot sequence zero means "no receipt yet" on the wire. The generator
// skips it, so crossing the numeric boundary advances by one sequence rather
// than by the two values returned by wrapping subtraction.
pub(crate) fn snapshot_distance(newer: u32, older: u32) -> u32 {
    let distance = newer.wrapping_sub(older);
    if newer < older {
        distance.saturating_sub(1)
    } else {
        distance
    }
}

pub(crate) fn snapshot_after(a: u32, b: u32) -> bool {
    a != b && snapshot_distance(a, b) < SERIAL_HALF
}

pub(crate) fn snapshot_rewind(seq: u32, distance: u32) -> u32 {
    if distance == 0 {
        return seq;
    }
    let raw = seq.wrapping_sub(distance);
    if raw == 0 || seq <= distance {
        raw.wrapping_sub(1)
    } else {
        raw
    }
}

pub(crate) fn snapshot_lanes(frame: u32) -> (bool, bool) {
    (
        frame % SNAPSHOT_EVERY == 0,
        frame % COMBAT_SNAPSHOT_EVERY == 0,
    )
}

/// One sight boundary chosen by the server for every human view. It covers
/// the sixty-tile radar plus twenty-four tiles of arrival margin, so a client
/// cannot widen disclosure by claiming a larger window.
pub(crate) const FAIR_INTEREST: i32 = 84 * 16 * 256;

pub(crate) fn fair_contains_xy(cx: i32, cy: i32, x: i32, y: i32) -> bool {
    let dx = x as i64 - cx as i64;
    let dy = y as i64 - cy as i64;
    dx * dx + dy * dy <= (FAIR_INTEREST as i64) * (FAIR_INTEREST as i64)
}

pub(crate) fn fair_contains(world: &sim::World, center: u8, subject: u8) -> bool {
    let Some(center) = world.state.ships.get(center as usize) else {
        return false;
    };
    let Some(subject) = world.state.ships.get(subject as usize) else {
        return false;
    };
    center.active != 0
        && subject.active != 0
        && fair_contains_xy(center.x, center.y, subject.x, subject.y)
}

pub(crate) fn near_combat(world: &sim::World, ship: u8) -> bool {
    let Some(me) = world.state.ships.get(ship as usize) else {
        return false;
    };
    if me.active == 0 || me.alive == 0 {
        return false;
    }
    let close = |x: i32, y: i32| {
        let dx = x as i64 - me.x as i64;
        let dy = y as i64 - me.y as i64;
        dx * dx + dy * dy <= (COMBAT_INTEREST as i64) * (COMBAT_INTEREST as i64)
    };
    if world.state.ships[..world.state.ship_count as usize]
        .iter()
        .enumerate()
        .any(|(i, other)| {
            i != ship as usize
                && other.active != 0
                && other.alive != 0
                && other.team != me.team
                && close(other.x, other.y)
        })
    {
        return true;
    }
    world.state.weapons[..world.state.weapon_count as usize]
        .iter()
        .any(|weapon| (weapon.owner == ship || weapon.team != me.team) && close(weapon.x, weapon.y))
}
#[derive(Clone, Copy, Default)]
pub(crate) struct LossRate {
    pub(crate) value: f64,
    pub(crate) sampled_ticks: u32,
}

pub(crate) fn observe_weighted(
    value: &mut f64,
    sampled_ticks: &mut u32,
    observation: f64,
    window_ticks: u32,
    elapsed_ticks: u32,
) {
    let window = window_ticks.max(1);
    let weight = elapsed_ticks.max(1).min(window);
    let before = (*sampled_ticks).min(window);
    let warm_weight = weight.min(window.saturating_sub(before));
    let after = before.saturating_add(warm_weight);
    if before < window {
        *value = (*value * before as f64 + observation * warm_weight as f64) / after as f64;
    }
    let rolling_weight = weight - warm_weight;
    if rolling_weight > 0 {
        *value += (observation - *value) * rolling_weight as f64 / window as f64;
    }
    *sampled_ticks = after;
}

impl LossRate {
    pub(crate) fn observe(&mut self, lost: bool, window_ticks: u32, elapsed_ticks: u32) {
        observe_weighted(
            &mut self.value,
            &mut self.sampled_ticks,
            lost as u8 as f64,
            window_ticks,
            elapsed_ticks,
        );
    }

    pub(crate) fn percent(self) -> u8 {
        (self.value * 100.0).round().clamp(0.0, 100.0) as u8
    }
}

pub(crate) struct SentSnapshot {
    pub(crate) seq: u32,
    pub(crate) tick: u32,
    pub(crate) combat: bool,
    pub(crate) combat_epoch: u32,
    pub(crate) received: bool,
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct LagDecision {
    pub(crate) no_flags: bool,
    pub(crate) weapon_percent: u8,
    pub(crate) spectate: bool,
}

pub(crate) struct LagUpdate {
    pub(crate) decision: LagDecision,
    pub(crate) notify: bool,
}

pub(crate) struct LagTracker {
    pub(crate) age: u32,
    pub(crate) snapshot_seq: u32,
    pub(crate) snapshots: std::collections::VecDeque<SentSnapshot>,
    pub(crate) last_snapshot_ack: u32,
    pub(crate) rtt_ticks: f64,
    pub(crate) jitter_ticks: f64,
    pub(crate) last_rtt_ticks: Option<f64>,
    pub(crate) last_rtt_snapshot_tick: Option<u32>,
    pub(crate) rtt_sampled_ticks: u32,
    pub(crate) jitter_sampled_ticks: u32,
    pub(crate) down_loss: LossRate,
    pub(crate) combat_loss: LossRate,
    pub(crate) combat_active: bool,
    pub(crate) combat_idle_ticks: u32,
    pub(crate) combat_epoch: u32,
    pub(crate) up_loss: LossRate,
    pub(crate) decision: LagDecision,
    pub(crate) healthy_ticks: u32,
    pub(crate) severe_ticks: u32,
    pub(crate) last_notice: u32,
}

impl Default for LagTracker {
    fn default() -> Self {
        LagTracker {
            age: 0,
            snapshot_seq: 0,
            snapshots: Default::default(),
            last_snapshot_ack: 0,
            rtt_ticks: 0.0,
            jitter_ticks: 0.0,
            last_rtt_ticks: None,
            last_rtt_snapshot_tick: None,
            rtt_sampled_ticks: 0,
            jitter_sampled_ticks: 0,
            down_loss: Default::default(),
            combat_loss: Default::default(),
            combat_active: false,
            combat_idle_ticks: 0,
            combat_epoch: 1,
            up_loss: Default::default(),
            decision: Default::default(),
            healthy_ticks: 0,
            severe_ticks: 0,
            last_notice: 0,
        }
    }
}

impl LagTracker {
    pub(crate) fn sent_snapshot(&mut self, tick: u32, combat: bool, window: u32) -> u32 {
        if combat {
            self.combat_active = true;
            self.combat_idle_ticks = 0;
        } else if self.combat_active {
            self.combat_active = false;
            self.combat_idle_ticks = 0;
        }
        self.snapshot_seq = next_nonzero(self.snapshot_seq);
        self.snapshots.push_back(SentSnapshot {
            seq: self.snapshot_seq,
            tick,
            combat,
            combat_epoch: if combat { self.combat_epoch } else { 0 },
            received: false,
        });
        while self.snapshots.len() > 96 {
            if let Some(old) = self.snapshots.pop_front() {
                // WebTransport can deliver snapshots before the reliable
                // welcome and map stream. Until the first receipt arrives, the
                // client has no usable snapshot baseline and neither do we.
                if self.last_snapshot_ack != 0 {
                    if old.combat && old.combat_epoch == self.combat_epoch {
                        self.combat_loss
                            .observe(!old.received, window, COMBAT_SNAPSHOT_EVERY);
                    } else if !old.combat {
                        self.down_loss
                            .observe(!old.received, window, SNAPSHOT_EVERY);
                    }
                }
            }
        }
        self.snapshot_seq
    }

    pub(crate) fn acknowledge_snapshots(&mut self, ack: u32, mask: u32, now: u32, window: u32) {
        if ack == 0 || snapshot_after(ack, self.snapshot_seq) {
            return;
        }
        if self.last_snapshot_ack == 0 {
            // The oldest set bit is the first snapshot the client can prove it
            // saw. Anything earlier may have arrived before the welcome, so it
            // sits outside the loss sample rather than becoming a failed send.
            let baseline = (0..32)
                .rev()
                .find(|behind| mask & (1u32 << *behind) != 0)
                .map_or(ack, |behind| snapshot_rewind(ack, behind));
            while self
                .snapshots
                .front()
                .is_some_and(|s| snapshot_after(baseline, s.seq))
            {
                self.snapshots.pop_front();
            }
        }
        for sent in &mut self.snapshots {
            let behind = snapshot_distance(ack, sent.seq);
            if (sent.seq == ack || snapshot_after(ack, sent.seq))
                && behind < 32
                && mask & (1u32 << behind) != 0
            {
                sent.received = true;
            }
        }
        if self.last_snapshot_ack == 0 || snapshot_after(ack, self.last_snapshot_ack) {
            if let Some(sent) = self.snapshots.iter().find(|s| s.seq == ack) {
                let sample = serial_elapsed(now, sent.tick) as f64;
                let elapsed = self.last_rtt_snapshot_tick.map_or_else(
                    || {
                        if sent.combat {
                            COMBAT_SNAPSHOT_EVERY
                        } else {
                            SNAPSHOT_EVERY
                        }
                    },
                    |before| serial_elapsed(sent.tick, before),
                );
                observe_weighted(
                    &mut self.rtt_ticks,
                    &mut self.rtt_sampled_ticks,
                    sample,
                    window,
                    elapsed,
                );
                if let Some(last) = self.last_rtt_ticks {
                    observe_weighted(
                        &mut self.jitter_ticks,
                        &mut self.jitter_sampled_ticks,
                        (sample - last).abs(),
                        window,
                        elapsed,
                    );
                }
                self.last_rtt_ticks = Some(sample);
                self.last_rtt_snapshot_tick = Some(sent.tick);
            }
            self.last_snapshot_ack = ack;
        }
        while self
            .snapshots
            .front()
            .is_some_and(|s| snapshot_distance(ack, s.seq) > 31)
        {
            let old = self.snapshots.pop_front().expect("front exists");
            if old.combat && old.combat_epoch == self.combat_epoch {
                self.combat_loss
                    .observe(!old.received, window, COMBAT_SNAPSHOT_EVERY);
            } else if !old.combat {
                self.down_loss
                    .observe(!old.received, window, SNAPSHOT_EVERY);
            }
        }
    }

    pub(crate) fn observe_input(&mut self, missing: bool, window: u32) {
        self.up_loss.observe(missing, window, 1);
    }

    pub(crate) fn suppression(value: f64, start: u32, full: u32) -> u8 {
        if start == 0 || value < start as f64 {
            return 0;
        }
        if full <= start || value >= full as f64 {
            return 100;
        }
        (((value - start as f64) * 100.0) / (full - start) as f64)
            .round()
            .clamp(1.0, 100.0) as u8
    }

    pub(crate) fn tick(&mut self, cfg: &config::LagConfig, bot: bool, now: u32) -> LagUpdate {
        self.age = self.age.saturating_add(1);
        if !self.combat_active {
            let expire = cfg.recover_ticks.max(1);
            if self.combat_idle_ticks < expire {
                self.combat_idle_ticks = self.combat_idle_ticks.saturating_add(1);
                if self.combat_idle_ticks >= expire {
                    self.combat_loss = Default::default();
                    self.combat_epoch = next_nonzero(self.combat_epoch);
                }
            }
        }
        if bot || self.age < cfg.sample_ticks {
            return LagUpdate {
                decision: self.decision,
                notify: false,
            };
        }

        let before = self.decision;
        let ping_ms = self.rtt_ticks * 10.0;
        let jitter_ms = self.jitter_ticks * 10.0;
        let down = if self.combat_active {
            0.0
        } else {
            self.down_loss.value * 100.0
        };
        let combat = if self.combat_active {
            self.combat_loss.value * 100.0
        } else {
            0.0
        };
        let up = self.up_loss.value * 100.0;
        let raw_no_flags = ping_ms >= cfg.no_flags_ping_ms as f64
            || jitter_ms >= cfg.no_flags_jitter_ms as f64
            || down >= cfg.no_flags_down_loss_pct as f64
            || combat >= cfg.no_flags_combat_loss_pct as f64
            || up >= cfg.no_flags_up_loss_pct as f64;
        let raw_weapon =
            Self::suppression(ping_ms, cfg.weapon_start_ping_ms, cfg.weapon_full_ping_ms)
                .max(Self::suppression(
                    jitter_ms,
                    cfg.weapon_start_jitter_ms,
                    cfg.weapon_full_jitter_ms,
                ))
                .max(Self::suppression(
                    down,
                    cfg.weapon_start_down_loss_pct,
                    cfg.weapon_full_down_loss_pct,
                ))
                .max(Self::suppression(
                    combat,
                    cfg.weapon_start_combat_loss_pct,
                    cfg.weapon_full_combat_loss_pct,
                ));
        let severe = ping_ms >= cfg.spectate_ping_ms as f64
            || jitter_ms >= cfg.spectate_jitter_ms as f64
            || down >= cfg.spectate_down_loss_pct as f64
            || combat >= cfg.spectate_combat_loss_pct as f64
            || up >= cfg.spectate_up_loss_pct as f64;

        if raw_no_flags || raw_weapon > 0 {
            self.healthy_ticks = 0;
            self.decision.no_flags = raw_no_flags;
            self.decision.weapon_percent = raw_weapon;
        } else {
            self.healthy_ticks = self.healthy_ticks.saturating_add(1);
            if self.healthy_ticks >= cfg.recover_ticks {
                self.decision.no_flags = false;
                self.decision.weapon_percent = 0;
            }
        }
        self.severe_ticks = if severe {
            self.severe_ticks.saturating_add(1)
        } else {
            0
        };
        self.decision.spectate = severe && self.severe_ticks >= cfg.spectate_ticks.max(1);

        let notify = self.decision != before
            || (self.decision != LagDecision::default()
                && (self.last_notice == 0 || serial_elapsed(now, self.last_notice) >= 500));
        if notify {
            self.last_notice = now;
        }
        LagUpdate {
            decision: self.decision,
            notify,
        }
    }

    pub(crate) fn notice(&self) -> Vec<u8> {
        let state = self.policy_state();
        let ping = (self.rtt_ticks * 10.0).round().clamp(0.0, u16::MAX as f64) as u16;
        let jitter = (self.jitter_ticks * 10.0)
            .round()
            .clamp(0.0, u16::MAX as f64) as u16;
        let mut msg = vec![S2C_LAG, state, self.decision.weapon_percent];
        msg.extend_from_slice(&ping.to_le_bytes());
        msg.extend_from_slice(&jitter.to_le_bytes());
        msg.push(self.down_loss.percent());
        msg.push(self.combat_percent());
        msg.push(self.up_loss.percent());
        msg
    }

    pub(crate) fn policy_state(&self) -> u8 {
        u8::from(self.decision.no_flags)
            | (u8::from(self.decision.weapon_percent > 0) << 1)
            | (u8::from(self.decision.spectate) << 2)
    }

    pub(crate) fn append_telemetry(&self, msg: &mut Vec<u8>) {
        let ping = (self.rtt_ticks * 10.0).round().clamp(0.0, u16::MAX as f64) as u16;
        let jitter = (self.jitter_ticks * 10.0)
            .round()
            .clamp(0.0, u16::MAX as f64) as u16;
        msg.extend_from_slice(&ping.to_le_bytes());
        msg.extend_from_slice(&jitter.to_le_bytes());
        msg.push(self.down_loss.percent());
        msg.push(self.combat_percent());
        msg.push(self.up_loss.percent());
        msg.push(self.policy_state());
        msg.push(self.decision.weapon_percent);
    }

    pub(crate) fn combat_percent(&self) -> u8 {
        if self.combat_active {
            self.combat_loss.percent()
        } else {
            0
        }
    }
}
