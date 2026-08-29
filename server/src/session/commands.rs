//! Commands whose effects live entirely inside one room.
//!
//! Join, ship, and watch stay in the connection dispatcher because they also
//! change credentials or rated leases. These commands need only membership
//! and the room lock, so they do not share that state machine.

use std::sync::Arc;

use tokio::sync::Mutex;

use crate::arena::ArenaServer;
use crate::presence::PresenceHandle;
use crate::protocol::input_packet;

pub(super) async fn say(zone: &Arc<Mutex<ArenaServer>>, presence: &PresenceHandle, data: &[u8]) {
    let Some(&phrase) = data.get(1) else { return };
    let Some((room, member)) = presence.current().flying() else {
        return;
    };
    let mut zone = zone.lock().await;
    let Some(arena) = zone.rooms.iter_mut().find(|arena| arena.number == room) else {
        return;
    };
    if let Some(ship) = arena.players.get(&member).map(|player| player.ship) {
        arena.say(ship, phrase);
    }
}

pub(super) async fn team(zone: &Arc<Mutex<ArenaServer>>, presence: &PresenceHandle, data: &[u8]) {
    let Some(&want) = data.get(1) else { return };
    if presence.current().flying().is_none() {
        return;
    }
    let mut zone = zone.lock().await;
    let Some((room, member)) = presence.current().flying() else {
        return;
    };
    let Some(arena) = zone.rooms.iter_mut().find(|arena| arena.number == room) else {
        return;
    };
    if let Some(ship) = arena.players.get(&member).map(|player| player.ship) {
        arena.join_team(ship, want);
    }
}

pub(super) async fn found(zone: &Arc<Mutex<ArenaServer>>, presence: &PresenceHandle) {
    if presence.current().flying().is_none() {
        return;
    }
    let mut zone = zone.lock().await;
    let Some((room, member)) = presence.current().flying() else {
        return;
    };
    let Some(arena) = zone.rooms.iter_mut().find(|arena| arena.number == room) else {
        return;
    };
    if let Some(ship) = arena.players.get(&member).map(|player| player.ship) {
        arena.found_and_move(ship);
    }
}

pub(super) async fn invite(zone: &Arc<Mutex<ArenaServer>>, presence: &PresenceHandle, data: &[u8]) {
    let Some(&guest) = data.get(1) else { return };
    if presence.current().flying().is_none() {
        return;
    }
    let mut zone = zone.lock().await;
    let Some((room, member)) = presence.current().flying() else {
        return;
    };
    let Some(arena) = zone.rooms.iter_mut().find(|arena| arena.number == room) else {
        return;
    };
    if let Some(ship) = arena.players.get(&member).map(|player| player.ship) {
        arena.invite(ship, guest);
    }
}

pub(super) async fn input(zone: &Arc<Mutex<ArenaServer>>, presence: &PresenceHandle, data: &[u8]) {
    let Some(packet) = input_packet(data) else {
        return;
    };
    if presence.current().flying().is_none() {
        return;
    }
    let mut zone = zone.lock().await;
    let Some((room, member)) = presence.current().flying() else {
        return;
    };
    let Some(arena) = zone.rooms.iter_mut().find(|arena| arena.number == room) else {
        return;
    };
    let now = arena.world.state.tick.wrapping_add(1);
    let sample_ticks = arena.lag_policy.sample_ticks;
    let Some(player) = arena.players.get_mut(&member) else {
        return;
    };
    if packet.lifecycle != player.lifecycle {
        return;
    }
    // Input and snapshot receipts share one packet so each direction is
    // measured on the arena's clock.
    player.last_input_at = now;
    player
        .lag
        .acknowledge_snapshots(packet.snapshot_ack, packet.snapshot_mask, now, sample_ticks);
    for (tick, buttons) in packet.records {
        player.schedule(tick, buttons, now);
    }
}
