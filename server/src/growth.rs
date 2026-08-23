//! Public match records and the short deterministic replay attached to them.

use std::collections::VecDeque;

use base64::Engine;
use rand::Rng;
use serde::{Deserialize, Serialize};

use crate::sim;

const SEGMENT_TICKS: usize = 100;
const REPLAY_SEGMENTS: usize = 9;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Artifact {
    pub id: i64,
    pub room: u32,
    pub match_no: u32,
    pub map: String,
    pub teams: Vec<String>,
    pub score: Vec<u16>,
    pub pilots: Vec<Pilot>,
    pub replay: Replay,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Pilot {
    pub ship: u8,
    pub account: Option<u64>,
    pub name: String,
    pub bot: bool,
    pub team: u8,
    pub class: u8,
    pub kills: i16,
    pub deaths: u16,
    pub assists: u16,
    pub points: u32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Replay {
    pub map: String,
    pub settings: String,
    pub segments: Vec<Segment>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Segment {
    pub snapshot: String,
    pub frames: String,
    pub ticks: u16,
}

#[derive(Default)]
pub struct Recorder {
    segments: VecDeque<RawSegment>,
    signature: Vec<(u8, u8)>,
}

#[derive(Default)]
struct RawSegment {
    snapshot: Vec<u8>,
    frames: Vec<u8>,
    ticks: u16,
}

impl Recorder {
    pub fn reset(&mut self) {
        self.segments.clear();
        self.signature.clear();
    }

    pub fn record(&mut self, world: &sim::World, inputs: &[sim::sim_input]) {
        let count = world.state.ship_count as usize;
        let signature = world.state.ships[..count]
            .iter()
            // Death and respawn are simulation events, so replaying the same
            // inputs reproduces `active` without a corrective checkpoint.
            // Class and team changes come from the room and do need one.
            .map(|ship| (ship.cls, ship.team))
            .collect::<Vec<_>>();
        let checkpoint = self.segments.back().is_none_or(|segment| {
            segment.ticks as usize >= SEGMENT_TICKS || signature != self.signature
        });
        if checkpoint {
            let mut snapshot = vec![0; sim::PACK_MAX];
            let n = world.pack(&mut snapshot);
            if n <= 0 {
                return;
            }
            snapshot.truncate(n as usize);
            self.segments.push_back(RawSegment {
                snapshot,
                ..Default::default()
            });
            while self.segments.len() > REPLAY_SEGMENTS {
                self.segments.pop_front();
            }
            self.signature = signature;
        }
        let Some(segment) = self.segments.back_mut() else {
            return;
        };
        segment.frames.push(inputs.len().min(255) as u8);
        for input in inputs.iter().take(255) {
            segment.frames.push(input.ship);
            segment
                .frames
                .extend_from_slice(&input.buttons.to_le_bytes());
        }
        segment.ticks = segment.ticks.saturating_add(1);
    }

    pub fn finish(&self, world: &sim::World) -> Replay {
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        Replay {
            map: b64.encode(world.packed_map()),
            settings: b64.encode(world.packed_settings()),
            segments: self
                .segments
                .iter()
                .map(|segment| Segment {
                    snapshot: b64.encode(&segment.snapshot),
                    frames: b64.encode(&segment.frames),
                    ticks: segment.ticks,
                })
                .collect(),
        }
    }
}

pub fn artifact_id() -> i64 {
    rand::thread_rng().gen_range(1..(1_i64 << 52))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recorder_keeps_the_last_eight_seconds_in_bounded_checkpoints() {
        let world = sim::World::new(7);
        let mut recorder = Recorder::default();
        for _ in 0..801 {
            recorder.record(&world, &[]);
        }
        let replay = recorder.finish(&world);
        assert_eq!(replay.segments.len(), 9);
        assert_eq!(
            replay
                .segments
                .iter()
                .map(|segment| segment.ticks)
                .collect::<Vec<_>>(),
            [100, 100, 100, 100, 100, 100, 100, 100, 1]
        );
        assert!(!replay.map.is_empty());
        assert!(!replay.settings.is_empty());
        assert!(replay
            .segments
            .iter()
            .all(|segment| !segment.snapshot.is_empty()));
    }

    #[test]
    fn recorder_names_each_ship_and_its_little_endian_buttons() {
        let world = sim::World::new(11);
        let mut recorder = Recorder::default();
        recorder.record(
            &world,
            &[sim::sim_input {
                ship: 3,
                buttons: 0x1234,
            }],
        );
        let replay = recorder.finish(&world);
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(&replay.segments[0].frames)
            .unwrap();
        assert_eq!(bytes, [1, 3, 0x34, 0x12]);
    }

    #[test]
    fn artifact_ids_are_exact_in_a_browser_number() {
        for _ in 0..100 {
            let id = artifact_id();
            assert!(id > 0);
            assert!(id < (1_i64 << 52));
        }
    }
}
