//! Where a pilot can get to, and roughly which way.
//!
//! docs/architecture/ai-runtime.md has described this for as long as there have
//! been bots, under "Route", and it was never built. What stood in for it was a
//! give-up timer: head straight at the destination, notice after two seconds
//! that nothing is getting closer, and leave that kind of destination alone for
//! five. That fixed a pilot pressing its nose against a green behind a wall,
//! and it fixes nothing else, because the replacement destination is rolled from
//! the same box in the middle of the map and lies through the same wall. A drill
//! on Chaos caught one holding thrust into a wall for a minute and a half,
//! travelling one pixel every ten ticks.
//!
//! ## The grid is two tiles, not eight
//!
//! The document says eight tiles to a cell with cost from wall density, and that
//! is written for a map made of thick blocks. Ours are not. A wall on these maps
//! is two tiles through, so an eight-tile cell holding a wall right across it is
//! a quarter solid, and any threshold loose enough to keep the corridors open is
//! loose enough to let a route go straight through the wall beside them. Built
//! that way it changed nothing at all: every cell on Chaos came out passable and
//! every straight line came out clear.
//!
//! Two tiles is thirty-two pixels and a hull is twenty-eight across, so a cell
//! holding any wall at all is a cell that hull cannot count on getting through.
//! That makes the rule "any solid tile shuts the cell", which needs no threshold
//! and no tuning, and it makes the grid an occupancy map rather than an estimate.
//! It costs 512 by 512 cells, which is a quarter of a megabyte held once per map
//! and shared by every pilot flying it.
//!
//! Cells against a wall cost more than open ones. Nothing forbids them; it puts
//! a route down the middle of a corridor rather than along the edge, and an edge
//! is where a hull carrying its own momentum ends up scraping.

use crate::sim;

/// Tiles to a cell, and the grid that falls out of it.
pub const CELL: usize = 2;
pub const W: usize = sim::MAP_TILES / CELL;
const CELL_PX: f32 = (CELL * 16) as f32;

const BLOCKED: u8 = 0;
/// What a cell next to a wall costs against an open one.
const HUG: u8 = 3;

pub struct Nav {
    cost: Box<[u8]>,
}

fn cell_of(px: f32) -> usize {
    (px / CELL_PX).clamp(0.0, (W - 1) as f32) as usize
}

fn centre(c: usize) -> f32 {
    c as f32 * CELL_PX + CELL_PX / 2.0
}

impl Nav {
    /// Read the map once. Every pilot sent the same map shares the result, so
    /// this is paid per map rather than per pilot: fifty-one bots in a room is
    /// one of these, not fifty-one.
    pub fn build(map: &sim::sim_map) -> Nav {
        let mut cost = vec![1u8; W * W].into_boxed_slice();
        for cy in 0..W {
            for cx in 0..W {
                let mut shut = false;
                for ty in cy * CELL..(cy + 1) * CELL {
                    let row = ty * sim::MAP_TILES;
                    for tx in cx * CELL..(cx + 1) * CELL {
                        let cls = map.tile[row + tx] & 0x0f;
                        // A door is a wall whenever it is shut, and a route
                        // that depends on catching one open strands a pilot for
                        // four seconds at a time.
                        if cls == 1 || cls == 3 {
                            shut = true;
                        }
                    }
                }
                if shut {
                    cost[cy * W + cx] = BLOCKED;
                }
            }
        }
        // A second pass, because the first has to finish before anything can
        // ask what its neighbours came out as.
        let mut out = cost.clone();
        for cy in 1..W - 1 {
            for cx in 1..W - 1 {
                if cost[cy * W + cx] == BLOCKED {
                    continue;
                }
                let touching = (-1i32..=1).any(|dy| {
                    (-1i32..=1).any(|dx| {
                        cost[(cy as i32 + dy) as usize * W + (cx as i32 + dx) as usize]
                            == BLOCKED
                    })
                });
                if touching {
                    out[cy * W + cx] = HUG;
                }
            }
        }
        Nav { cost: out }
    }

    fn open(&self, cx: usize, cy: usize) -> bool {
        self.cost[cy * W + cx] != BLOCKED
    }

    /// Whether the straight line between two points stays on open cells.
    ///
    /// Coarser than a pilot's own line of sight, which ai.rs walks at half a
    /// tile and is the right test for "can I shoot that". This is "can I fly at
    /// that", and it is asked of the same grid the route is solved on so the two
    /// cannot disagree about where the walls are.
    pub fn clear(&self, from: (f32, f32), to: (f32, f32)) -> bool {
        let (dx, dy) = (to.0 - from.0, to.1 - from.1);
        let steps = ((dx * dx + dy * dy).sqrt() / (CELL_PX / 2.0)).ceil() as i32;
        for i in 1..=steps.max(1) {
            let t = i as f32 / steps.max(1) as f32;
            let x = from.0 + dx * t;
            let y = from.1 + dy * t;
            if !self.open(cell_of(x), cell_of(y)) {
                return false;
            }
        }
        true
    }

    /// A route from one point to another, as world positions, nearest first.
    /// Empty when there is no way through, which a caller should read as "head
    /// at it anyway and let the give-up timer decide", not as "stop".
    ///
    /// Both ends are snapped to the nearest open cell, because both legitimately
    /// sit inside one that is not: a pilot scraping a wall is in a blocked cell
    /// by this grid's reckoning, and refusing to route from there would strand
    /// exactly the pilot that needs a route.
    pub fn route(&self, from: (f32, f32), to: (f32, f32)) -> Vec<(f32, f32)> {
        let start = self.nearest_open(cell_of(from.0), cell_of(from.1));
        let goal = self.nearest_open(cell_of(to.0), cell_of(to.1));
        let (Some(start), Some(goal)) = (start, goal) else {
            return Vec::new();
        };
        if start == goal {
            return vec![to];
        }
        SCRATCH.with(|s| s.borrow_mut().solve(self, start, goal, to))
    }

    /// The nearest open cell to one that may not be, searched outwards. Four
    /// rings is 128 px, further than a hull can be wedged into anything.
    fn nearest_open(&self, cx: usize, cy: usize) -> Option<usize> {
        if self.open(cx, cy) {
            return Some(cy * W + cx);
        }
        for r in 1..=4i32 {
            for dy in -r..=r {
                for dx in -r..=r {
                    if dx.abs() != r && dy.abs() != r {
                        continue;
                    }
                    let (nx, ny) = (cx as i32 + dx, cy as i32 + dy);
                    if nx < 0 || ny < 0 || nx >= W as i32 || ny >= W as i32 {
                        continue;
                    }
                    if self.open(nx as usize, ny as usize) {
                        return Some(ny as usize * W + nx as usize);
                    }
                }
            }
        }
        None
    }
}

/// A* working memory, one set per thread rather than one per pilot.
///
/// Fifty-one pilots would be a hundred megabytes of scratch only one of them
/// touches at a time, and a fresh allocation per route would be megabytes of
/// churn on a search that usually expands a few thousand cells. `came` holds the
/// direction a cell was reached from rather than which cell it was, which is one
/// byte instead of four over a quarter of a million of them.
///
/// A generation stamp means nothing is ever cleared: a cell whose stamp is stale
/// was never visited on this search.
struct Scratch {
    gen: u32,
    stamp: Vec<u32>,
    g: Vec<u32>,
    came: Vec<u8>,
    heap: std::collections::BinaryHeap<std::cmp::Reverse<(u32, u32)>>,
}

/// The eight ways into a cell, and the index each is stored as.
const STEPS: [(i32, i32); 8] = [
    (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1),
];

thread_local! {
    static SCRATCH: std::cell::RefCell<Scratch> = std::cell::RefCell::new(Scratch {
        gen: 0,
        stamp: vec![0; W * W],
        g: vec![0; W * W],
        came: vec![0; W * W],
        heap: std::collections::BinaryHeap::new(),
    });
}

/// A cap on one search, so a route asked for across a map with no way through
/// costs a bounded amount rather than a quarter of a million cells. Measured on
/// the three shipped maps, a route right across one expands a few thousand.
const MAX_EXPAND: u32 = 40_000;

impl Scratch {
    fn solve(&mut self, nav: &Nav, start: usize, goal: usize, to: (f32, f32)) -> Vec<(f32, f32)> {
        self.gen = self.gen.wrapping_add(1);
        let gen = self.gen;
        self.heap.clear();
        self.stamp[start] = gen;
        self.g[start] = 0;
        self.heap.push(std::cmp::Reverse((0, start as u32)));

        let (gx, gy) = ((goal % W) as i32, (goal / W) as i32);
        let mut expanded = 0u32;
        let mut found = false;
        while let Some(std::cmp::Reverse((_, cur))) = self.heap.pop() {
            let cur = cur as usize;
            if cur == goal {
                found = true;
                break;
            }
            expanded += 1;
            if expanded > MAX_EXPAND {
                break;
            }
            let (cx, cy) = ((cur % W) as i32, (cur / W) as i32);
            for (k, &(dx, dy)) in STEPS.iter().enumerate() {
                let (nx, ny) = (cx + dx, cy + dy);
                if nx < 1 || ny < 1 || nx >= W as i32 - 1 || ny >= W as i32 - 1 {
                    continue;
                }
                let n = ny as usize * W + nx as usize;
                if nav.cost[n] == BLOCKED {
                    continue;
                }
                // No cutting a corner a hull cannot cut: a diagonal between two
                // walls is a gap of no width whatever the grid says.
                if dx != 0
                    && dy != 0
                    && (!nav.open((cx + dx) as usize, cy as usize)
                        || !nav.open(cx as usize, (cy + dy) as usize))
                {
                    continue;
                }
                let step = if dx != 0 && dy != 0 { 14 } else { 10 };
                let ng = self.g[cur] + step * nav.cost[n] as u32;
                if self.stamp[n] == gen && self.g[n] <= ng {
                    continue;
                }
                self.stamp[n] = gen;
                self.g[n] = ng;
                self.came[n] = k as u8;
                // Octile, admissible on an eight-neighbour grid and tight
                // enough that the search does not fan out over the map.
                let (ax, ay) = ((nx - gx).abs(), (ny - gy).abs());
                let h = 10 * (ax + ay) - 6 * ax.min(ay);
                self.heap.push(std::cmp::Reverse((ng + h as u32, n as u32)));
            }
        }
        if !found {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut c = goal;
        while c != start {
            out.push((centre(c % W), centre(c / W)));
            let (dx, dy) = STEPS[self.came[c] as usize];
            let (px, py) = ((c % W) as i32 - dx, (c / W) as i32 - dy);
            c = py as usize * W + px as usize;
        }
        out.reverse();
        // The last cell is a cell; what the caller asked for is a point in it.
        if let Some(last) = out.last_mut() {
            *last = to;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A wall across the middle with one gap in it. A route has to find the gap;
    /// a straight line has to say it cannot.
    fn walled() -> Box<sim::sim_map> {
        let mut m: Box<sim::sim_map> = crate::sim::zeroed_box();
        for tx in 100..400 {
            if (240..248).contains(&tx) {
                continue; // the doorway
            }
            for ty in 250..252 {
                m.tile[ty * sim::MAP_TILES + tx] = 1;
            }
        }
        m
    }

    #[test]
    fn a_thin_wall_is_a_wall() {
        // The whole reason this grid is two tiles. At eight tiles to a cell
        // with a density threshold, a two-tile wall is a quarter of a cell and
        // every line through it reads as clear.
        let n = Nav::build(&walled());
        let above = (200.0 * 16.0, 240.0 * 16.0);
        let below = (200.0 * 16.0, 262.0 * 16.0);
        assert!(!n.clear(above, below), "a line through the wall is not clear");
        assert!(n.clear(above, (210.0 * 16.0, 240.0 * 16.0)), "and open ground is");
    }

    #[test]
    fn a_route_finds_the_one_way_through() {
        let n = Nav::build(&walled());
        let above = (200.0 * 16.0, 240.0 * 16.0);
        let below = (200.0 * 16.0, 262.0 * 16.0);
        let path = n.route(above, below);
        assert!(!path.is_empty(), "there is a way round");
        // Every leg of it stays out of the wall, which is the property that
        // matters: a path that clips a corner is a pilot pressed against one.
        let mut at = above;
        for step in &path {
            assert!(n.clear(at, *step), "leg from {at:?} to {step:?} crosses a wall");
            at = *step;
        }
        // And it goes through the doorway rather than round the map, which the
        // x range of the path is enough to show.
        let far = path.iter().any(|p| p.0 / 16.0 > 236.0 && p.0 / 16.0 < 252.0);
        assert!(far, "the route did not use the gap");
    }

    #[test]
    fn nowhere_to_go_is_an_empty_route_rather_than_a_hang() {
        let mut m: Box<sim::sim_map> = crate::sim::zeroed_box();
        // Seal a pilot in.
        for ty in 300..311 {
            for tx in 300..311 {
                let edge = ty == 300 || ty == 310 || tx == 300 || tx == 310;
                if edge {
                    m.tile[ty * sim::MAP_TILES + tx] = 1;
                }
            }
        }
        let n = Nav::build(&m);
        let inside = (305.0 * 16.0, 305.0 * 16.0);
        let outside = (500.0 * 16.0, 500.0 * 16.0);
        assert!(n.route(inside, outside).is_empty(), "no way out is no route");
    }
}
