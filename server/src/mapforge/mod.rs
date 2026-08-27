//! Deterministic, brief-driven map generation.
//!
//! Two generations live here. `themes` is the current one: each theme owns a
//! geometric pattern, placed aligned on a module grid, and decides which map
//! elements it uses. `legacy` is the archetype-and-scatter generator frozen so
//! the shipped rotation's recipes keep reproducing their exact bytes, the same
//! arrangement `sim/tools/mapgen.c` has with the maps that preceded it. New
//! maps start in `themes`.
//!
//! Either way a map starts as an authored brief, passes through an explicit
//! layout graph, receives geometry, then faces the simulation validator and a
//! second set of play-oriented gates.

mod legacy;
mod themes;

use crate::{drill, sim};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub(crate) const EMPTY: u8 = 0;
pub(crate) const SOLID: u8 = 1;
pub(crate) const SAFE: u8 = 2;
pub(crate) const DOOR: u8 = 3;
pub(crate) const GOAL: u8 = 4;
pub(crate) const WORMHOLE: u8 = 5;
pub(crate) const OVER: u8 = 6;
pub(crate) const UNDER: u8 = 7;
pub(crate) const TURF: u8 = 8;
pub(crate) const SPAWN: u8 = 9;
pub(crate) const SLOPE: u8 = 10;

pub(crate) const WALL: u8 = 0;
pub(crate) const ROCK_A: u8 = 2;
pub(crate) const ROCK_B: u8 = 3;
pub(crate) const ROCK_BIG: u8 = 4;
pub(crate) const ROCK_BODY: u8 = 5;
pub(crate) const STATION: u8 = 6;
pub(crate) const STATION_BODY: u8 = 7;

pub(crate) fn tile(class: u8, variant: u8) -> u8 {
    class | variant << 4
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Melee,
    Goal,
    Turf,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ArenaShape {
    Rectangle,
    CutCorners,
    OffsetBays,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Symmetry {
    HalfTurn,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub width: u16,
    pub height: u16,
    pub shape: ArenaShape,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NodeKind {
    Home0,
    Home1,
    Junction,
    Landmark,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct LayoutNode {
    pub id: usize,
    pub kind: NodeKind,
    pub x: i32,
    pub y: i32,
    pub radius: i32,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct LayoutEdge {
    pub from: usize,
    pub to: usize,
    pub width: i32,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct LayoutGraph {
    pub nodes: Vec<LayoutNode>,
    pub edges: Vec<LayoutEdge>,
}

impl LayoutGraph {
    pub fn new() -> Self {
        Self {
            nodes: Vec::new(),
            edges: Vec::new(),
        }
    }

    pub fn node(&mut self, kind: NodeKind, x: i32, y: i32, radius: i32) -> usize {
        let id = self.nodes.len();
        self.nodes.push(LayoutNode {
            id,
            kind,
            x,
            y,
            radius,
        });
        id
    }

    pub fn edge(&mut self, from: usize, to: usize, width: i32) {
        self.edges.push(LayoutEdge { from, to, width });
    }
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct CoreReport {
    regions: i32,
    regions_shut: i32,
    reachable: i32,
    stranded: i32,
    spawns: i32,
    spawns_team: [i32; 2],
    spawns_stranded: i32,
    solid: i32,
    open: i32,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct MaterialCounts {
    pub wall: usize,
    pub rocks: usize,
    pub stations: usize,
    pub scenery: usize,
    pub slopes: usize,
    pub doors: usize,
    pub wormholes: usize,
    pub safe: usize,
    pub goals: usize,
    pub turf: usize,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct DrillMetrics {
    seeds: Vec<u32>,
    kills: u32,
    shots: u32,
    hits: u32,
    bounces: u32,
    crawling_percent: f64,
    travel_percent: f64,
    fight_percent: f64,
    cells_visited: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct MapMetrics {
    name: String,
    hash: String,
    width: u16,
    height: u16,
    pub(crate) accepted: bool,
    pub(crate) gates: Vec<String>,
    quality: f64,
    core: CoreReport,
    route_target: u8,
    routes_found: usize,
    route_lengths_tiles: Vec<f64>,
    route_balance: f64,
    contact_seconds: f64,
    min_opening_tiles: u8,
    spawn_exit_directions: [usize; 2],
    line_of_sight: [usize; 3],
    dead_ends: usize,
    wall_percent: f64,
    thick_generic_wall_tiles: usize,
    landmark_count: usize,
    cover_quadrants_percent: [f64; 4],
    pub(crate) symmetry_mismatches: usize,
    theme_fidelity: f64,
    pub(crate) materials: MaterialCounts,
    layout: LayoutGraph,
    route_overlay: Vec<Vec<[u16; 2]>>,
    drill: Option<DrillMetrics>,
}

pub(crate) struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed ^ 0x9e37_79b9_7f4a_7c15)
    }

    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    pub fn range(&mut self, lo: i32, hi: i32) -> i32 {
        lo + (self.next() % (hi - lo).max(1) as u64) as i32
    }
}

pub(crate) struct Canvas {
    pub map: Box<sim::sim_map>,
    pub reserved: Vec<bool>,
    pub w: i32,
    pub h: i32,
}

impl Canvas {
    pub fn new(width: u16, height: u16) -> Self {
        let mut map = sim::blank_map();
        unsafe { sim::sim_map_size(&mut *map, width as i32, height as i32) };
        Self {
            map,
            reserved: vec![false; width as usize * height as usize],
            w: width as i32,
            h: height as i32,
        }
    }

    fn index(&self, x: i32, y: i32) -> Option<usize> {
        (x >= 0 && y >= 0 && x < self.w && y < self.h)
            .then_some(y as usize * sim::MAP_TILES + x as usize)
    }

    fn local_index(&self, x: i32, y: i32) -> Option<usize> {
        (x >= 0 && y >= 0 && x < self.w && y < self.h)
            .then_some(y as usize * self.w as usize + x as usize)
    }

    pub fn at(&self, x: i32, y: i32) -> u8 {
        self.index(x, y)
            .map_or(tile(SOLID, 1), |i| self.map.tile[i])
    }

    pub fn put(&mut self, x: i32, y: i32, value: u8) {
        if let Some(i) = self.index(x, y) {
            self.map.tile[i] = value;
        }
    }

    pub fn turned(value: u8) -> u8 {
        let class = value & 15;
        let variant = value >> 4;
        match class {
            SPAWN | GOAL => tile(class, variant ^ 1),
            SLOPE => tile(class, variant ^ 2),
            _ => value,
        }
    }

    pub fn pair(&mut self, x: i32, y: i32, value: u8) {
        self.put(x, y, value);
        self.put(self.w - 1 - x, self.h - 1 - y, Self::turned(value));
    }

    pub fn line(&mut self, mut x0: i32, mut y0: i32, x1: i32, y1: i32, value: u8) {
        let dx = (x1 - x0).abs();
        let dy = -(y1 - y0).abs();
        let sx = if x0 < x1 { 1 } else { -1 };
        let sy = if y0 < y1 { 1 } else { -1 };
        let mut err = dx + dy;
        loop {
            self.pair(x0, y0, value);
            if x0 == x1 && y0 == y1 {
                break;
            }
            let twice = err * 2;
            if twice >= dy {
                err += dy;
                x0 += sx;
            }
            if twice <= dx {
                err += dx;
                y0 += sy;
            }
        }
    }

    pub fn reserve_disk(&mut self, x: i32, y: i32, radius: i32) {
        for yy in y - radius..=y + radius {
            for xx in x - radius..=x + radius {
                if (xx - x) * (xx - x) + (yy - y) * (yy - y) <= radius * radius {
                    if let Some(i) = self.local_index(xx, yy) {
                        self.reserved[i] = true;
                    }
                }
            }
        }
    }

    fn reserve_line(&mut self, a: &LayoutNode, b: &LayoutNode, width: i32) {
        let steps = (b.x - a.x).abs().max((b.y - a.y).abs()).max(1);
        for n in 0..=steps {
            let x = a.x + (b.x - a.x) * n / steps;
            let y = a.y + (b.y - a.y) * n / steps;
            self.reserve_disk(x, y, width / 2 + 2);
        }
    }

    pub fn reserve_graph(&mut self, graph: &LayoutGraph) {
        for node in &graph.nodes {
            self.reserve_disk(node.x, node.y, node.radius);
        }
        for edge in &graph.edges {
            self.reserve_line(&graph.nodes[edge.from], &graph.nodes[edge.to], edge.width);
        }
    }

    pub fn reserved_at(&self, x: i32, y: i32) -> bool {
        self.local_index(x, y).is_none_or(|i| self.reserved[i])
    }

    pub fn free_box(&self, x: i32, y: i32, size: i32, padding: i32) -> bool {
        self.free_rect(x, y, size, size, padding)
    }

    pub fn free_rect(&self, x: i32, y: i32, width: i32, height: i32, padding: i32) -> bool {
        for yy in y - padding..y + height + padding {
            for xx in x - padding..x + width + padding {
                if xx < 6 || yy < 6 || xx >= self.w - 6 || yy >= self.h - 6 {
                    return false;
                }
                let Some(i) = self.local_index(xx, yy) else {
                    return false;
                };
                if self.reserved[i] || self.at(xx, yy) != EMPTY {
                    return false;
                }
            }
        }
        true
    }

    pub fn object(&mut self, x: i32, y: i32, size: i32, corner: u8, body: u8) -> bool {
        let mx = self.w - size - x;
        let my = self.h - size - y;
        if !self.free_box(x, y, size, 2) || !self.free_box(mx, my, size, 2) {
            return false;
        }
        for (ox, oy) in [(x, y), (mx, my)] {
            for yy in 0..size {
                for xx in 0..size {
                    self.put(
                        ox + xx,
                        oy + yy,
                        tile(SOLID, if xx == 0 && yy == 0 { corner } else { body }),
                    );
                }
            }
        }
        true
    }

    pub fn small_rock(&mut self, x: i32, y: i32, variant: u8) -> bool {
        let mx = self.w - 1 - x;
        let my = self.h - 1 - y;
        if !self.free_box(x, y, 1, 2) || !self.free_box(mx, my, 1, 2) {
            return false;
        }
        self.pair(x, y, tile(SOLID, variant));
        true
    }

    pub fn bar(&mut self, x: i32, y: i32, length: i32, vertical: bool, variant: u8) -> bool {
        let (width, height) = if vertical { (1, length) } else { (length, 1) };
        let mx = self.w - width - x;
        let my = self.h - height - y;
        if !self.free_box(x, y, length, 2) || !self.free_box(mx, my, length, 2) {
            return false;
        }
        for n in 0..length {
            let (sx, sy) = if vertical { (x, y + n) } else { (x + n, y) };
            self.pair(sx, sy, tile(SOLID, variant));
        }
        true
    }

    pub fn scenery_pair(&mut self, x: i32, y: i32, class: u8, variant: u8) {
        if self.at(x, y) == EMPTY && self.at(self.w - 1 - x, self.h - 1 - y) == EMPTY {
            self.pair(x, y, tile(class, variant));
        }
    }

    pub fn slope_run(&mut self, x: i32, y: i32, length: i32, down: bool) -> bool {
        for n in 0..length {
            let (sx, sy) = if down { (x + n, y + n) } else { (x + n, y - n) };
            if !self.free_box(sx, sy, 2, 2) {
                return false;
            }
        }
        let variants = if down { [1, 3] } else { [2, 0] };
        for n in 0..length {
            let (sx, sy) = if down { (x + n, y + n) } else { (x + n, y - n) };
            self.pair(sx, sy, tile(SLOPE, variants[0]));
            self.pair(sx + 1, sy, tile(SLOPE, variants[1]));
        }
        true
    }

    /// A run of door tiles on one channel, anchored: the tile just past the
    /// start must already be solid, because a free-standing fence across a
    /// lane is something to fly around rather than through, measured at a
    /// third of the drill's kills. Refuses reserved ground so a door can
    /// never plug one of the brief's required routes.
    pub fn door_run(&mut self, x: i32, y: i32, length: i32, vertical: bool, channel: u8) -> bool {
        let (ax, ay) = if vertical { (x, y - 1) } else { (x - 1, y) };
        if self.at(ax, ay) & 15 != SOLID {
            return false;
        }
        for n in 0..length {
            let (sx, sy) = if vertical { (x, y + n) } else { (x + n, y) };
            if self.at(sx, sy) != EMPTY || self.reserved_at(sx, sy) {
                return false;
            }
        }
        for n in 0..length {
            let (sx, sy) = if vertical { (x, y + n) } else { (x + n, y) };
            self.pair(sx, sy, tile(DOOR, channel & 7));
        }
        true
    }

    /// A wormhole mouth and its half-turn twin. The pull reaches fourteen
    /// tiles, so the caller keeps spawns well outside that; the reservation
    /// here only keeps later stamps from crowding the mouth.
    pub fn wormhole(&mut self, x: i32, y: i32) {
        self.pair(x, y, tile(WORMHOLE, 0));
        self.reserve_disk(x, y, 5);
        self.reserve_disk(self.w - 1 - x, self.h - 1 - y, 5);
    }

    pub fn spawn_pair(&mut self, x: i32, y: i32) {
        self.pair(x, y, tile(SPAWN, 0));
        self.reserve_disk(x, y, 6);
        self.reserve_disk(self.w - 1 - x, self.h - 1 - y, 6);
    }
}

pub(crate) fn add_spawns(c: &mut Canvas, graph: &LayoutGraph) {
    let home = &graph.nodes[0];
    if c.w >= c.h {
        for (dx, dy) in [(-2, -7), (2, -3), (-2, 3), (2, 7)] {
            c.spawn_pair(home.x + dx, home.y + dy);
        }
    } else {
        for (dx, dy) in [(-7, -2), (-3, 2), (3, -2), (7, 2)] {
            c.spawn_pair(home.x + dx, home.y + dy);
        }
    }
}

pub(crate) fn arena_shape(c: &mut Canvas, shape: ArenaShape) {
    match shape {
        ArenaShape::Rectangle => {}
        ArenaShape::CutCorners => {
            let n = 14;
            for y in 4..4 + n {
                for x in 4..4 + n - (y - 4) {
                    c.pair(x, y, tile(SOLID, WALL));
                }
            }
        }
        ArenaShape::OffsetBays => {
            let mid = c.h / 2;
            for y in 4..mid - 22 {
                for x in 4..10 {
                    c.pair(x, y, tile(SOLID, WALL));
                }
            }
        }
    }
}

/// Homes at opposite ends of the long axis, the shape every theme shares.
pub(crate) fn homes_graph(width: u16, height: u16) -> (LayoutGraph, usize, usize) {
    let w = width as i32;
    let h = height as i32;
    let mut g = LayoutGraph::new();
    let (a, b) = if w >= h {
        (
            g.node(NodeKind::Home0, 18, h / 2, 13),
            g.node(NodeKind::Home1, w - 19, h / 2, 13),
        )
    } else {
        (
            g.node(NodeKind::Home0, w / 2, 18, 13),
            g.node(NodeKind::Home1, w / 2, h - 19, 13),
        )
    };
    (g, a, b)
}

fn blocked(map: &sim::sim_map, x: i32, y: i32) -> bool {
    x < 0
        || y < 0
        || x >= map.w as i32
        || y >= map.h as i32
        || matches!(map.class_at(x as usize, y as usize), SOLID | DOOR | SLOPE)
}

fn center_clear(map: &sim::sim_map, x: i32, y: i32, radius: i32) -> bool {
    for yy in y - radius..=y + radius {
        for xx in x - radius..=x + radius {
            if blocked(map, xx, yy) {
                return false;
            }
        }
    }
    true
}

fn shortest_path(
    map: &sim::sim_map,
    start: (i32, i32),
    goal: (i32, i32),
    radius: i32,
    banned: &[bool],
) -> Vec<(i32, i32)> {
    let w = map.w as usize;
    let h = map.h as usize;
    let mut previous = vec![-1i32; w * h];
    let mut queue = VecDeque::new();
    let s = start.1 as usize * w + start.0 as usize;
    let g = goal.1 as usize * w + goal.0 as usize;
    previous[s] = s as i32;
    queue.push_back(s);
    while let Some(at) = queue.pop_front() {
        if at == g {
            break;
        }
        let (x, y) = ((at % w) as i32, (at / w) as i32);
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let (nx, ny) = (x + dx, y + dy);
            if nx < 0 || ny < 0 || nx >= w as i32 || ny >= h as i32 {
                continue;
            }
            let ni = ny as usize * w + nx as usize;
            if previous[ni] >= 0 || banned[ni] || !center_clear(map, nx, ny, radius) {
                continue;
            }
            previous[ni] = at as i32;
            queue.push_back(ni);
        }
    }
    if previous[g] < 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut at = g;
    loop {
        out.push(((at % w) as i32, (at / w) as i32));
        if at == s {
            break;
        }
        at = previous[at] as usize;
    }
    out.reverse();
    out
}

fn homes(map: &sim::sim_map) -> [Vec<(i32, i32)>; 2] {
    let mut out = [Vec::new(), Vec::new()];
    for feature in map.features.iter().take(map.feature_count as usize) {
        if feature.kind == SPAWN && feature.variant < 2 {
            out[feature.variant as usize].push((feature.tx as i32, feature.ty as i32));
        }
    }
    out
}

fn distinct_routes(map: &sim::sim_map, opening: u8, wanted: usize) -> Vec<Vec<(i32, i32)>> {
    let home = homes(map);
    if home[0].is_empty() || home[1].is_empty() {
        return Vec::new();
    }
    let centroid = |points: &[(i32, i32)]| {
        (
            points.iter().map(|p| p.0).sum::<i32>() / points.len() as i32,
            points.iter().map(|p| p.1).sum::<i32>() / points.len() as i32,
        )
    };
    let start = centroid(&home[0]);
    let goal = centroid(&home[1]);
    let w = map.w as usize;
    let h = map.h as usize;
    let mut banned = vec![false; w * h];
    let mut routes = Vec::new();
    let radius = opening as i32 / 2;
    for _ in 0..wanted {
        let path = shortest_path(map, start, goal, radius, &banned);
        if path.is_empty() {
            break;
        }
        for &(x, y) in &path {
            let near_end = (x - start.0).abs() + (y - start.1).abs() < 14
                || (x - goal.0).abs() + (y - goal.1).abs() < 14;
            if near_end {
                continue;
            }
            for yy in y - radius - 2..=y + radius + 2 {
                for xx in x - radius - 2..=x + radius + 2 {
                    if xx >= 0 && yy >= 0 && xx < w as i32 && yy < h as i32 {
                        banned[yy as usize * w + xx as usize] = true;
                    }
                }
            }
        }
        routes.push(path);
    }
    routes
}

fn object_normalized(value: u8) -> u8 {
    let class = value & 15;
    let variant = value >> 4;
    if class == SOLID {
        return tile(
            SOLID,
            match variant {
                ROCK_BODY => ROCK_BIG,
                STATION_BODY => STATION,
                _ => variant,
            },
        );
    }
    value
}

fn symmetry_mismatches(map: &sim::sim_map) -> usize {
    let (w, h) = (map.w as i32, map.h as i32);
    let mut mismatches = 0;
    for y in 0..h {
        for x in 0..w {
            let a = map.tile[y as usize * sim::MAP_TILES + x as usize];
            let b = map.tile[(h - 1 - y) as usize * sim::MAP_TILES + (w - 1 - x) as usize];
            if Canvas::turned(object_normalized(a)) != object_normalized(b) {
                mismatches += 1;
            }
        }
    }
    mismatches / 2
}

fn materials(map: &sim::sim_map) -> MaterialCounts {
    let mut out = MaterialCounts {
        wall: 0,
        rocks: 0,
        stations: 0,
        scenery: 0,
        slopes: 0,
        doors: 0,
        wormholes: 0,
        safe: 0,
        goals: 0,
        turf: 0,
    };
    for y in 4..map.h as usize - 4 {
        for x in 4..map.w as usize - 4 {
            let value = map.tile[y * sim::MAP_TILES + x];
            let (class, variant) = (value & 15, value >> 4);
            match class {
                SOLID if variant == WALL => out.wall += 1,
                SOLID if matches!(variant, ROCK_A | ROCK_B | ROCK_BIG | ROCK_BODY) => {
                    out.rocks += 1
                }
                SOLID if matches!(variant, STATION | STATION_BODY) => out.stations += 1,
                OVER | UNDER => out.scenery += 1,
                SLOPE => out.slopes += 1,
                DOOR => out.doors += 1,
                WORMHOLE => out.wormholes += 1,
                SAFE => out.safe += 1,
                GOAL => out.goals += 1,
                TURF => out.turf += 1,
                _ => {}
            }
        }
    }
    out
}

fn line_of_sight(map: &sim::sim_map) -> [usize; 3] {
    let mut out = [0usize; 3];
    for y in (8..map.h as i32 - 8).step_by(8) {
        for x in (8..map.w as i32 - 8).step_by(8) {
            if blocked(map, x, y) {
                continue;
            }
            for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                let mut d = 0;
                while d < 64 && !blocked(map, x + dx * d, y + dy * d) {
                    d += 1;
                }
                out[if d < 16 {
                    0
                } else if d < 36 {
                    1
                } else {
                    2
                }] += 1;
            }
        }
    }
    out
}

fn dead_ends(map: &sim::sim_map) -> usize {
    let stride = 6i32;
    let gw = map.w as i32 / stride;
    let gh = map.h as i32 / stride;
    let open = |x: i32, y: i32| center_clear(map, x * stride + 3, y * stride + 3, 2);
    let mut count = 0;
    for y in 1..gh - 1 {
        for x in 1..gw - 1 {
            if !open(x, y) {
                continue;
            }
            let degree = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                .iter()
                .filter(|(dx, dy)| open(x + dx, y + dy))
                .count();
            if degree == 1 {
                count += 1;
            }
        }
    }
    count
}

fn spawn_exits(map: &sim::sim_map, points: &[(i32, i32)]) -> usize {
    let Some(&(x, y)) = points.first() else {
        return 0;
    };
    [(1, 0), (-1, 0), (0, 1), (0, -1)]
        .iter()
        .filter(|(dx, dy)| (1..=12).all(|n| center_clear(map, x + dx * n, y + dy * n, 1)))
        .count()
}

fn cover_quadrants(map: &sim::sim_map) -> [f64; 4] {
    let mut solid = [0usize; 4];
    let mut total = [0usize; 4];
    for y in 4..map.h as usize - 4 {
        for x in 4..map.w as usize - 4 {
            let q = usize::from(x >= map.w as usize / 2) + 2 * usize::from(y >= map.h as usize / 2);
            total[q] += 1;
            if map.blocks(x, y) {
                solid[q] += 1;
            }
        }
    }
    std::array::from_fn(|q| 100.0 * solid[q] as f64 / total[q].max(1) as f64)
}

fn run_drills(map: Arc<sim::sim_map>, base: u64) -> DrillMetrics {
    let seeds = [base as u32, (base >> 32) as u32 ^ 0xa511_e9b3];
    let mut out = DrillMetrics {
        seeds: seeds.to_vec(),
        kills: 0,
        shots: 0,
        hits: 0,
        bounces: 0,
        crawling_percent: 0.0,
        travel_percent: 0.0,
        fight_percent: 0.0,
        cells_visited: 0,
    };
    let mut flying = 0u64;
    let mut crawling = 0u64;
    let mut travel = 0u64;
    let mut fight = 0u64;
    for seed in seeds {
        let d = drill::run_on(Arc::clone(&map), 8, 1_200, seed);
        out.kills += d.kills;
        out.shots += d.shots;
        out.hits += d.hits;
        out.bounces += d.bounces;
        out.cells_visited += d.cells;
        flying += d.flying;
        crawling += d.crawling;
        travel += d.doing[1];
        fight += d.doing[2];
    }
    let total = flying.max(1) as f64;
    out.crawling_percent = 100.0 * crawling as f64 / total;
    out.travel_percent = 100.0 * travel as f64 / total;
    out.fight_percent = 100.0 * fight as f64 / total;
    out
}

/// The play-facing thresholds a brief holds its map to, whichever generation
/// the brief came from.
pub(crate) struct Gauge {
    pub name: String,
    pub seed: u64,
    pub mode: Mode,
    pub routes: u8,
    pub min_opening_tiles: u8,
    pub contact_seconds: (f64, f64),
    pub allow_doors: bool,
    pub allow_wormholes: bool,
    pub wall_band: (f64, f64),
    pub wall_target: f64,
}

pub(crate) fn assess(
    map: &sim::sim_map,
    graph: LayoutGraph,
    gauge: &Gauge,
    fidelity: f64,
    simulate: bool,
) -> Result<MapMetrics, String> {
    let (report, core_error) = sim::check_map(map);
    let home = homes(map);
    let routes = distinct_routes(map, gauge.min_opening_tiles, gauge.routes as usize);
    let lengths: Vec<f64> = routes.iter().map(|p| p.len() as f64).collect();
    let shortest = lengths.iter().copied().reduce(f64::min).unwrap_or(0.0);
    let longest = lengths.iter().copied().reduce(f64::max).unwrap_or(0.0);
    let balance = if longest > 0.0 {
        shortest / longest
    } else {
        0.0
    };
    let bytes = sim::pack_map(map)?;
    let shared = sim::unpack_map(&bytes)?;
    let mut probe = sim::World::on_shared_map(gauge.seed as u32, Arc::clone(&shared));
    let ship = probe.spawn_on_map(0, 0, 0, 0);
    let top = if ship >= 0 {
        (unsafe { sim::sim_eff_speed(&probe.cfg.classes[0], &probe.state.ships[ship as usize]) })
            as f64
            / 65536.0
    } else {
        1.0
    };
    let contact = shortest * sim::TILE_PX as f64 / (top * 100.0);
    let material = materials(map);
    let mismatch = symmetry_mismatches(map);
    // Perimeter masses shape the arena and are allowed to have depth. This
    // gate is about a wall in playable space becoming a shapeless block.
    let thick = (20..map.h as usize - 20)
        .flat_map(|y| (20..map.w as usize - 20).map(move |x| (x, y)))
        .filter(|&(x, y)| {
            let generic =
                |xx: usize, yy: usize| map.tile[yy * sim::MAP_TILES + xx] == tile(SOLID, WALL);
            generic(x, y)
                && generic(x - 1, y)
                && generic(x + 1, y)
                && generic(x, y - 1)
                && generic(x, y + 1)
        })
        .count();
    let interior = ((map.w as usize - 8) * (map.h as usize - 8)).max(1);
    // A slope is half a tile of wall and counts as half, as everywhere else.
    let wall_percent = 100.0
        * (material.wall as f64
            + material.rocks as f64
            + material.stations as f64
            + material.slopes as f64 / 2.0)
        / interior as f64;
    let landmark_count = map
        .features
        .iter()
        .take(map.feature_count as usize)
        .filter(|f| matches!(f.kind, GOAL | WORMHOLE | TURF))
        .count()
        + material.stations / 36
        + material.rocks / 4;
    let mut gates = Vec::new();
    if let Some(reason) = core_error {
        gates.push(format!("core validator: {reason}"));
    }
    if report.spawns_team != [4, 4] {
        gates.push(format!(
            "expected four starts per side, found {} and {}",
            report.spawns_team[0], report.spawns_team[1]
        ));
    }
    if routes.len() < gauge.routes as usize {
        gates.push(format!(
            "expected {} separated routes at {} tiles wide, found {}",
            gauge.routes,
            gauge.min_opening_tiles,
            routes.len()
        ));
    }
    if !(gauge.contact_seconds.0..=gauge.contact_seconds.1).contains(&contact) {
        gates.push(format!(
            "home route is {contact:.1} seconds, outside {:.1} to {:.1}",
            gauge.contact_seconds.0, gauge.contact_seconds.1
        ));
    }
    if mismatch != 0 {
        gates.push(format!("{mismatch} half-turn symmetry mismatch(es)"));
    }
    if thick != 0 {
        gates.push(format!(
            "{thick} generic interior wall tile(s) are needlessly thick"
        ));
    }
    if gauge.mode == Mode::Melee && (material.safe + material.goals + material.turf != 0) {
        gates.push("melee maps cannot contain safe, goal, or turf tiles".into());
    }
    if !gauge.allow_doors && material.doors != 0 {
        gates.push("the brief does not call for doors".into());
    }
    if !gauge.allow_wormholes && material.wormholes != 0 {
        gates.push("the brief does not call for wormholes".into());
    }
    if !(gauge.wall_band.0..=gauge.wall_band.1).contains(&wall_percent) {
        gates.push(format!(
            "playable cover is {wall_percent:.1}%, outside {:.1}% to {:.1}%",
            gauge.wall_band.0, gauge.wall_band.1
        ));
    }
    let exits = [spawn_exits(map, &home[0]), spawn_exits(map, &home[1])];
    if exits.iter().any(|n| *n < 2) {
        gates.push(format!(
            "spawn exits are {} and {} directions",
            exits[0], exits[1]
        ));
    }
    let quadrants = cover_quadrants(map);
    let los = line_of_sight(map);
    let ends = dead_ends(map);
    let los_total = los.iter().sum::<usize>().max(1) as f64;
    let los_largest = los.iter().copied().max().unwrap_or(0) as f64;
    let wall_span = (gauge.wall_band.1 - gauge.wall_band.0).max(0.1) / 2.0;
    let quality = (35.0 * balance
        + 20.0 * fidelity
        + 2.5 * exits.iter().sum::<usize>() as f64
        + 5.0 * (1.0 - (quadrants[0] - quadrants[3]).abs() / 100.0)
        + 5.0 * (1.0 - (quadrants[1] - quadrants[2]).abs() / 100.0)
        + 20.0 * (1.0 - los_largest / los_total)
        + 10.0 * (1.0 - (wall_percent - gauge.wall_target).abs() / wall_span).max(0.0)
        - ends as f64 * 1.5
        - gates.len() as f64 * 25.0)
        .clamp(0.0, 100.0);
    Ok(MapMetrics {
        name: gauge.name.clone(),
        hash: format!("{:08x}", unsafe { sim::sim_map_hash(map) }),
        width: map.w,
        height: map.h,
        accepted: gates.is_empty(),
        gates,
        quality,
        core: CoreReport {
            regions: report.regions,
            regions_shut: report.regions_shut,
            reachable: report.reachable,
            stranded: report.stranded,
            spawns: report.spawns,
            spawns_team: report.spawns_team,
            spawns_stranded: report.spawns_stranded,
            solid: report.solid,
            open: report.open,
        },
        route_target: gauge.routes,
        routes_found: routes.len(),
        route_lengths_tiles: lengths,
        route_balance: balance,
        contact_seconds: contact,
        min_opening_tiles: gauge.min_opening_tiles,
        spawn_exit_directions: exits,
        line_of_sight: los,
        dead_ends: ends,
        wall_percent,
        thick_generic_wall_tiles: thick,
        landmark_count,
        cover_quadrants_percent: quadrants,
        symmetry_mismatches: mismatch,
        theme_fidelity: fidelity,
        materials: material,
        layout: graph,
        route_overlay: routes
            .iter()
            .map(|path| {
                path.iter()
                    .step_by(3)
                    .map(|&(x, y)| [x as u16, y as u16])
                    .collect()
            })
            .collect(),
        drill: simulate.then(|| run_drills(shared, gauge.seed)),
    })
}

fn svg(map: &sim::sim_map, metrics: &MapMetrics) -> String {
    let mut out = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {} {}\" role=\"img\" aria-label=\"{} map preview\"><rect width=\"100%\" height=\"100%\" fill=\"#05070c\"/>",
        map.w, map.h, metrics.name
    );
    for y in 0..map.h as usize {
        for x in 0..map.w as usize {
            let value = map.tile[y * sim::MAP_TILES + x];
            let (class, variant) = (value & 15, value >> 4);
            let color = match (class, variant) {
                (SOLID, ROCK_A | ROCK_B | ROCK_BIG | ROCK_BODY) => "#8a8794",
                (SOLID, STATION | STATION_BODY) => "#7c8fa8",
                (SOLID, 1) => "#39465c",
                (SOLID, _) | (SLOPE, _) => "#8494ab",
                (DOOR, _) => "#ffd166",
                (WORMHOLE, _) => "#b66bff",
                (SAFE, _) => "#3ddc97",
                (OVER, _) => "#2b3a4f",
                (UNDER, _) => "#1d2838",
                (SPAWN, 0) => "#4fd6ff",
                (SPAWN, _) => "#ffa552",
                _ => continue,
            };
            out.push_str(&format!(
                "<rect x=\"{x}\" y=\"{y}\" width=\"1\" height=\"1\" fill=\"{color}\"/>"
            ));
        }
    }
    let colors = ["#50fa7b", "#ff79c6", "#f1fa8c"];
    for (n, route) in metrics.route_overlay.iter().enumerate() {
        let points = route
            .iter()
            .map(|p| format!("{},{}", p[0], p[1]))
            .collect::<Vec<_>>()
            .join(" ");
        out.push_str(&format!(
            "<polyline points=\"{points}\" fill=\"none\" stroke=\"{}\" stroke-width=\"0.7\" opacity=\"0.65\"/>",
            colors[n % colors.len()]
        ));
    }
    out.push_str("</svg>");
    out
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("map");
    path.with_file_name(format!("{stem}.{suffix}"))
}

fn write_candidate(
    brief_toml: &str,
    map: &sim::sim_map,
    metrics: &MapMetrics,
    path: &Path,
) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(path, sim::pack_map(map)?).map_err(|e| e.to_string())?;
    std::fs::write(sidecar(path, "recipe.toml"), brief_toml).map_err(|e| e.to_string())?;
    std::fs::write(
        sidecar(path, "metrics.json"),
        serde_json::to_string_pretty(metrics).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    std::fs::write(sidecar(path, "svg"), svg(map, metrics)).map_err(|e| e.to_string())?;
    Ok(())
}

/// A brief from either generation, told apart by its version field.
pub(crate) enum Brief {
    V1(legacy::Brief),
    V2(themes::Brief),
}

impl Brief {
    fn parse(text: &str) -> Result<Self, String> {
        let value: toml::Value = toml::from_str(text).map_err(|e| e.to_string())?;
        match value.get("version").and_then(|v| v.as_integer()) {
            Some(1) => Ok(Self::V1(
                toml::from_str::<legacy::Brief>(text).map_err(|e| e.to_string())?,
            )),
            Some(2) => Ok(Self::V2(
                toml::from_str::<themes::Brief>(text).map_err(|e| e.to_string())?,
            )),
            Some(n) => Err(format!("brief version {n} is not supported")),
            None => Err("the brief names no version".into()),
        }
    }

    fn name(&self) -> &str {
        match self {
            Self::V1(b) => &b.name,
            Self::V2(b) => &b.name,
        }
    }

    fn expected_hash(&self) -> Option<&str> {
        match self {
            Self::V1(b) => b.expected_hash.as_deref(),
            Self::V2(b) => b.expected_hash.as_deref(),
        }
    }

    fn summary(&self) -> String {
        match self {
            Self::V1(b) => format!("{} · {}", b.archetype.name(), b.theme.name()),
            Self::V2(b) => b.theme.name().to_string(),
        }
    }

    fn toml(&self) -> Result<String, String> {
        match self {
            Self::V1(b) => toml::to_string_pretty(b).map_err(|e| e.to_string()),
            Self::V2(b) => toml::to_string_pretty(b).map_err(|e| e.to_string()),
        }
    }

    fn build(&self) -> Result<(Box<sim::sim_map>, LayoutGraph), String> {
        match self {
            Self::V1(b) => b.build(),
            Self::V2(b) => b.build(),
        }
    }

    fn gauge(&self) -> Gauge {
        match self {
            Self::V1(b) => b.gauge(),
            Self::V2(b) => b.gauge(),
        }
    }

    fn fidelity(&self, m: &MaterialCounts) -> f64 {
        match self {
            Self::V1(b) => b.theme.fidelity(m),
            Self::V2(b) => b.theme.fidelity(m),
        }
    }
}

fn read_brief(path: &Path) -> Result<Brief, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Brief::parse(&text).map_err(|e| format!("{}: {e}", path.display()))
}

pub(crate) fn assess_brief(
    brief: &Brief,
    map: &sim::sim_map,
    graph: LayoutGraph,
    simulate: bool,
) -> Result<MapMetrics, String> {
    let fidelity = brief.fidelity(&materials(map));
    assess(map, graph, &brief.gauge(), fidelity, simulate)
}

fn generate(recipe: &Path, output: &Path, simulate: bool) -> Result<MapMetrics, String> {
    let brief = read_brief(recipe)?;
    let (map, graph) = brief.build()?;
    let metrics = assess_brief(&brief, &map, graph, simulate)?;
    if !metrics.accepted {
        return Err(format!(
            "{} failed: {}",
            brief.name(),
            metrics.gates.join("; ")
        ));
    }
    if let Some(expected) = brief.expected_hash() {
        if expected != metrics.hash {
            return Err(format!(
                "{} generated {}, recipe expects {}",
                brief.name(),
                metrics.hash,
                expected
            ));
        }
    }
    write_candidate(&brief.toml()?, &map, &metrics, output)?;
    Ok(metrics)
}

fn gallery(path: &Path, cards: &[(String, String, MapMetrics)]) -> Result<(), String> {
    let mut body = String::from(
        "<!doctype html><meta charset=\"utf-8\"><title>Mapforge gallery</title><style>body{background:#05070c;color:#e6edf7;font:14px system-ui;margin:24px}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:18px}article{border:1px solid #39465c;padding:12px}img{width:100%;background:#05070c;image-rendering:pixelated}b{color:#4fd6ff}.bad{color:#ff6b6b}</style><h1>Mapforge gallery</h1><p>Each route overlay is a separately flyable seven-tile corridor. Open the metrics JSON beside a candidate for the full report.</p><main>",
    );
    for (name, summary, metrics) in cards {
        let class = if metrics.accepted {
            ""
        } else {
            " class=\"bad\""
        };
        body.push_str(&format!(
            "<article><img src=\"{}.svg\" alt=\"\"><h2>{}</h2><p><b>{}</b> · {} by {}</p><p{}>{:.0} quality · {} routes · {:.1}s home flight · {:.1}% wall</p></article>",
            name,
            name,
            summary,
            metrics.width,
            metrics.height,
            class,
            metrics.quality,
            metrics.routes_found,
            metrics.contact_seconds,
            metrics.wall_percent
        ));
    }
    body.push_str("</main>");
    std::fs::write(path.join("index.html"), body).map_err(|e| e.to_string())
}

fn batch(output: &Path, seed: u64, simulate: bool) -> Result<(), String> {
    std::fs::create_dir_all(output).map_err(|e| e.to_string())?;
    let mut cards = Vec::new();
    let mut n = 0u64;
    for theme in themes::Theme::all() {
        for _ in 0..2 {
            let brief =
                themes::Brief::candidate(seed.wrapping_add(n.wrapping_mul(0x9e37_79b9)), theme);
            n += 1;
            let wrapped = Brief::V2(brief.clone());
            let (map, graph) = wrapped.build()?;
            let metrics = assess_brief(&wrapped, &map, graph, simulate)?;
            let path = output.join(format!("{}.vwmap", brief.name));
            write_candidate(&wrapped.toml()?, &map, &metrics, &path)?;
            println!(
                "{:<40} {:>5.1}  {}",
                brief.name,
                metrics.quality,
                if metrics.accepted {
                    "accepted".to_string()
                } else {
                    metrics.gates.join("; ")
                }
            );
            cards.push((brief.name.clone(), wrapped.summary(), metrics));
        }
    }
    gallery(output, &cards)?;
    println!("wrote {} candidates to {}", cards.len(), output.display());
    Ok(())
}

fn verify(recipe: &Path, map_path: &Path) -> Result<(), String> {
    let brief = read_brief(recipe)?;
    let (map, graph) = brief.build()?;
    let metrics = assess_brief(&brief, &map, graph, false)?;
    if !metrics.accepted {
        return Err(metrics.gates.join("; "));
    }
    if brief.expected_hash() != Some(metrics.hash.as_str()) {
        return Err(format!(
            "recipe hash is {:?}, generated hash is {}",
            brief.expected_hash(),
            metrics.hash
        ));
    }
    let found = std::fs::read(map_path).map_err(|e| e.to_string())?;
    let expected = sim::pack_map(&map)?;
    if found != expected {
        return Err(format!("{} does not match its recipe", map_path.display()));
    }
    println!(
        "{} matches {} ({}, {:.1} quality)",
        map_path.display(),
        recipe.display(),
        metrics.hash,
        metrics.quality
    );
    Ok(())
}

fn usage() -> String {
    "usage:\n  vectorwake-server mapforge generate <recipe.toml> <map.vwmap> [--simulate]\n  vectorwake-server mapforge batch <output-dir> [seed] [--no-simulate]\n  vectorwake-server mapforge verify <recipe.toml> <map.vwmap>".into()
}

pub fn run() {
    let args: Vec<String> = std::env::args().skip(2).collect();
    let result = match args.first().map(String::as_str) {
        Some("generate") if args.len() >= 3 => generate(
            Path::new(&args[1]),
            Path::new(&args[2]),
            args.iter().any(|a| a == "--simulate"),
        )
        .map(|m| {
            println!(
                "wrote {} ({}, {:.1} quality, {} routes)",
                args[2], m.hash, m.quality, m.routes_found
            )
        }),
        Some("batch") if args.len() >= 2 => {
            let seed = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1);
            batch(
                Path::new(&args[1]),
                seed,
                !args.iter().any(|a| a == "--no-simulate"),
            )
        }
        Some("verify") if args.len() == 3 => verify(Path::new(&args[1]), Path::new(&args[2])),
        _ => Err(usage()),
    };
    if let Err(error) = result {
        eprintln!("mapforge: {error}");
        std::process::exit(2);
    }
}
