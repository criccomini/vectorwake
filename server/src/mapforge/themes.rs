//! The pattern generator: a theme owns its geometry.
//!
//! Where the legacy generator scattered a theme's materials over an
//! archetype's topology, a theme here is the topology. Every stamp sits on a
//! module grid, placement runs along lattices, bands, and rings rather than
//! rejection sampling, and the seed varies texture inside the pattern rather
//! than the pattern itself. Each theme also declares which map elements it
//! uses, which is how doors and wormholes finally reach generated maps.

use super::*;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    WideOpen,
    Nebula,
    GravityWells,
    AsteroidBelt,
    BoulderOrchard,
    StationYard,
    Maze,
    TwinFortresses,
    Canyon,
    Derelict,
    Rings,
    CrystalLattice,
    Pinwheel,
}

impl Theme {
    pub fn all() -> [Self; 13] {
        [
            Self::WideOpen,
            Self::Nebula,
            Self::GravityWells,
            Self::AsteroidBelt,
            Self::BoulderOrchard,
            Self::StationYard,
            Self::Maze,
            Self::TwinFortresses,
            Self::Canyon,
            Self::Derelict,
            Self::Rings,
            Self::CrystalLattice,
            Self::Pinwheel,
        ]
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::WideOpen => "wide-open",
            Self::Nebula => "nebula",
            Self::GravityWells => "gravity-wells",
            Self::AsteroidBelt => "asteroid-belt",
            Self::BoulderOrchard => "boulder-orchard",
            Self::StationYard => "station-yard",
            Self::Maze => "maze",
            Self::TwinFortresses => "twin-fortresses",
            Self::Canyon => "canyon",
            Self::Derelict => "derelict",
            Self::Rings => "rings",
            Self::CrystalLattice => "crystal-lattice",
            Self::Pinwheel => "pinwheel",
        }
    }

    fn envelope(self) -> (u16, u16) {
        match self {
            Self::GravityWells
            | Self::AsteroidBelt
            | Self::StationYard
            | Self::TwinFortresses
            | Self::Canyon => (192, 144),
            Self::Derelict => (144, 192),
            _ => (160, 160),
        }
    }

    fn contact_window(self) -> (f64, f64) {
        match self {
            Self::Maze => (9.0, 26.0),
            Self::TwinFortresses | Self::Rings => (9.0, 22.0),
            _ => (9.0, 17.6),
        }
    }

    fn allows(self) -> (bool, bool) {
        match self {
            Self::StationYard | Self::Maze | Self::TwinFortresses => (true, false),
            Self::Nebula | Self::GravityWells => (false, true),
            Self::Rings => (true, true),
            _ => (false, false),
        }
    }

    fn wall_band(self) -> (f64, f64, f64) {
        match self {
            Self::WideOpen => (0.4, 3.0, 1.2),
            Self::Nebula => (0.3, 3.0, 1.0),
            Self::GravityWells => (0.6, 4.0, 1.8),
            Self::AsteroidBelt => (1.2, 6.0, 3.0),
            Self::BoulderOrchard => (1.0, 5.0, 2.5),
            Self::StationYard => (1.5, 7.0, 3.0),
            Self::Maze => (2.5, 12.0, 5.0),
            Self::TwinFortresses => (1.0, 5.0, 2.5),
            Self::Canyon => (1.2, 6.0, 2.5),
            Self::Derelict => (1.0, 6.0, 2.5),
            Self::Rings => (2.0, 7.0, 4.0),
            Self::CrystalLattice => (0.8, 5.0, 2.0),
            Self::Pinwheel => (0.5, 4.0, 1.5),
        }
    }

    pub fn fidelity(self, m: &MaterialCounts) -> f64 {
        let part = |count: usize, full: f64| (count as f64 / full).min(1.0);
        match self {
            Self::WideOpen => {
                0.5 * part(m.stations, 72.0) + 0.5 * (1.0 - part(m.wall + m.rocks, 300.0))
            }
            Self::Nebula => {
                0.6 * part(m.scenery, 250.0)
                    + 0.2 * part(m.wormholes, 2.0)
                    + 0.2 * part(m.rocks, 60.0)
            }
            Self::GravityWells => 0.6 * part(m.wormholes, 4.0) + 0.4 * part(m.rocks, 40.0),
            Self::AsteroidBelt => part(m.rocks, 300.0),
            Self::BoulderOrchard => part(m.rocks, 280.0),
            Self::StationYard => {
                0.5 * part(m.stations, 400.0)
                    + 0.3 * part(m.doors, 16.0)
                    + 0.2 * part(m.scenery, 40.0)
            }
            Self::Maze => 0.7 * part(m.wall, 700.0) + 0.3 * part(m.doors, 20.0),
            Self::TwinFortresses => 0.6 * part(m.wall, 250.0) + 0.4 * part(m.doors, 10.0),
            Self::Canyon => 0.7 * part(m.wall, 350.0) + 0.3 * part(m.slopes, 16.0),
            Self::Derelict => {
                0.6 * part(m.stations, 250.0)
                    + 0.2 * part(m.slopes, 12.0)
                    + 0.2 * part(m.rocks, 60.0)
            }
            Self::Rings => {
                0.5 * part(m.wall, 600.0) + 0.3 * part(m.doors, 14.0) + 0.2 * part(m.wormholes, 4.0)
            }
            Self::CrystalLattice => 0.7 * part(m.slopes, 70.0) + 0.3 * part(m.rocks, 10.0),
            Self::Pinwheel => 0.5 * part(m.slopes, 32.0) + 0.5 * part(m.wall, 120.0),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Brief {
    pub version: u8,
    pub name: String,
    pub seed: u64,
    pub mode: Mode,
    pub theme: Theme,
    pub symmetry: Symmetry,
    pub envelope: Envelope,
    pub routes: u8,
    pub min_opening_tiles: u8,
    pub contact_seconds_min: f64,
    pub contact_seconds_max: f64,
    #[serde(default)]
    pub allow_doors: bool,
    #[serde(default)]
    pub allow_wormholes: bool,
    #[serde(default)]
    pub expected_hash: Option<String>,
}

impl Brief {
    pub fn candidate(seed: u64, theme: Theme) -> Self {
        let (width, height) = theme.envelope();
        let contact = theme.contact_window();
        let (allow_doors, allow_wormholes) = theme.allows();
        Self {
            version: 2,
            name: format!("{}-{:04x}", theme.name(), seed & 0xffff),
            seed,
            mode: Mode::Melee,
            theme,
            symmetry: Symmetry::HalfTurn,
            envelope: Envelope {
                width,
                height,
                shape: ArenaShape::Rectangle,
            },
            routes: 3,
            min_opening_tiles: 7,
            contact_seconds_min: contact.0,
            contact_seconds_max: contact.1,
            allow_doors,
            allow_wormholes,
            expected_hash: None,
        }
    }

    fn check(&self) -> Result<(), String> {
        if self.version != 2 {
            return Err(format!("brief version {} is not supported", self.version));
        }
        if !(96..=256).contains(&self.envelope.width) || !(96..=256).contains(&self.envelope.height)
        {
            return Err("an arena side must be between 96 and 256 tiles".into());
        }
        if !(2..=3).contains(&self.routes) {
            return Err("routes must be two or three".into());
        }
        if self.min_opening_tiles < 7 {
            return Err("openings must leave at least seven tiles for a three-tile hull".into());
        }
        if self.contact_seconds_min <= 0.0 || self.contact_seconds_max <= self.contact_seconds_min {
            return Err("the contact-time window is not ordered".into());
        }
        Ok(())
    }

    pub fn gauge(&self) -> Gauge {
        let (lo, hi, target) = self.theme.wall_band();
        Gauge {
            name: self.name.clone(),
            seed: self.seed,
            mode: self.mode,
            routes: self.routes,
            min_opening_tiles: self.min_opening_tiles,
            contact_seconds: (self.contact_seconds_min, self.contact_seconds_max),
            allow_doors: self.allow_doors,
            allow_wormholes: self.allow_wormholes,
            wall_band: (lo, hi),
            wall_target: target,
        }
    }

    fn layout(&self) -> LayoutGraph {
        let w = self.envelope.width as i32;
        let h = self.envelope.height as i32;
        let (mut g, a, b) = homes_graph(self.envelope.width, self.envelope.height);
        let width = self.min_opening_tiles as i32 + 4;
        if self.theme == Theme::Rings {
            // One straight reserved corridor through the bullseye; the outer
            // margins around the largest ring carry the other two routes on
            // their own.
            g.edge(a, b, width);
            return g;
        }
        // The junctions hug the home ends, so the fan from a home to its
        // three lanes stays in the margin and each lane crosses the pattern
        // as one straight, clean channel. Junctions a third of the way in
        // swept diagonal reservations through the field and shredded every
        // pattern they crossed.
        if w >= h {
            for y in [h / 4, h / 2, h * 3 / 4] {
                let l = g.node(NodeKind::Junction, 34, y, 7);
                let r = g.node(NodeKind::Junction, w - 35, y, 7);
                g.edge(a, l, width);
                g.edge(l, r, width);
                g.edge(r, b, width);
            }
        } else {
            for x in [w / 4, w / 2, w * 3 / 4] {
                let t = g.node(NodeKind::Junction, x, 34, 7);
                let d = g.node(NodeKind::Junction, x, h - 35, 7);
                g.edge(a, t, width);
                g.edge(t, d, width);
                g.edge(d, b, width);
            }
        }
        g
    }

    pub fn build(&self) -> Result<(Box<sim::sim_map>, LayoutGraph), String> {
        self.check()?;
        let graph = self.layout();
        let mut canvas = Canvas::new(self.envelope.width, self.envelope.height);
        canvas.reserve_graph(&graph);
        add_spawns(&mut canvas, &graph);
        arena_shape(&mut canvas, self.envelope.shape);
        stamp(&mut canvas, self.theme, &mut Rng::new(self.seed));
        sim::index_map(&mut canvas.map);
        Ok((canvas.map, graph))
    }
}

/// One wall tile and its half-turn twin, placed only where both sides are
/// open and unreserved, so a pattern drawn over the whole map parts around
/// the brief's routes instead of plugging them.
fn wall_tile(c: &mut Canvas, x: i32, y: i32, value: u8) {
    let (mx, my) = (c.w - 1 - x, c.h - 1 - y);
    if x < 6 || y < 6 || x >= c.w - 6 || y >= c.h - 6 {
        return;
    }
    if c.reserved_at(x, y) || c.reserved_at(mx, my) {
        return;
    }
    if c.at(x, y) != EMPTY || c.at(mx, my) != EMPTY {
        return;
    }
    c.pair(x, y, value);
}

fn hseg(c: &mut Canvas, y: i32, x0: i32, x1: i32, variant: u8) {
    for x in x0..=x1 {
        wall_tile(c, x, y, tile(SOLID, variant));
    }
}

fn vseg(c: &mut Canvas, x: i32, y0: i32, y1: i32, variant: u8) {
    for y in y0..=y1 {
        wall_tile(c, x, y, tile(SOLID, variant));
    }
}

fn stamp(c: &mut Canvas, theme: Theme, rng: &mut Rng) {
    match theme {
        Theme::WideOpen => wide_open(c),
        Theme::Nebula => nebula(c, rng),
        Theme::GravityWells => gravity_wells(c),
        Theme::AsteroidBelt => asteroid_belt(c, rng),
        Theme::BoulderOrchard => boulder_orchard(c, rng),
        Theme::StationYard => station_yard(c),
        Theme::Maze => maze(c, rng),
        Theme::TwinFortresses => twin_fortresses(c),
        Theme::Canyon => canyon(c),
        Theme::Derelict => derelict(c, rng),
        Theme::Rings => rings(c),
        Theme::CrystalLattice => crystal_lattice(c),
        Theme::Pinwheel => pinwheel(c),
    }
}

/// A near-empty field: one central monument to orbit, a little cover by each
/// home, and an aligned row of rocks along each long edge.
fn wide_open(c: &mut Canvas) {
    c.object(c.w / 2 - 10, c.h / 2 - 18, 6, STATION, STATION_BODY);
    c.small_rock(c.w / 2 - 15, c.h / 2 - 1, ROCK_A);
    c.small_rock(c.w / 2 - 1, c.h / 2 - 15, ROCK_B);
    for y in [c.h / 2 - 18, c.h / 2 + 9] {
        vseg(c, c.w / 3 - 12, y, y + 9, WALL);
    }
    for x in [c.w / 2 - 24, c.w / 2 - 4, c.w / 2 + 16] {
        c.small_rock(x, 28, if x % 2 == 0 { ROCK_A } else { ROCK_B });
        c.small_rock(x + 8, 20, if x % 2 == 0 { ROCK_B } else { ROCK_A });
    }
}

/// Broad diagonal cloud drifts drawn in scenery, sparse rock inside the
/// thick bands, and a two-tile wormhole eye at the center of the storm.
fn nebula(c: &mut Canvas, rng: &mut Rng) {
    // Rock before cloud: a bar refuses ground already carrying scenery, so
    // the drawing order decides whether the bands hold any rock at all.
    for (band, offset) in [-44i32, 0, 44].into_iter().enumerate() {
        let mut t = 16;
        while t <= c.w - 20 {
            let y = t + offset;
            if y >= 10 && y < c.h - 11 && t % 8 == 0 {
                let variant = if rng.next().is_multiple_of(2) {
                    ROCK_A
                } else {
                    ROCK_B
                };
                c.bar(t + 4, y - 4, 2 + (t / 8 % 2), band % 2 == 0, variant);
            }
            t += 8;
        }
    }
    c.wormhole(c.w / 2 - 1, c.h / 2 - 1);
    for offset in [-44i32, 0, 44] {
        let mut t = 16;
        while t <= c.w - 20 {
            let (x, y) = (t, t + offset);
            if y >= 8 && y < c.h - 9 {
                let class = if t % 24 == 0 { OVER } else { UNDER };
                for (dx, dy) in [
                    (0, 0),
                    (1, 0),
                    (2, 0),
                    (0, 1),
                    (1, 1),
                    (2, 1),
                    (1, -1),
                    (2, -1),
                ] {
                    c.scenery_pair(x + dx, y + dy, class, ((t / 8 + dx + dy) % 4) as u8);
                }
            }
            t += 8;
        }
    }
}

/// Four wormholes on the quarter points, each fenced by an aligned square of
/// guard rocks, with a staggered pair of center bars between them.
fn gravity_wells(c: &mut Canvas) {
    // Wells and their brackets sit between the reserved lanes; a bracket
    // corner one tile inside a lane band is silently skipped, which is how
    // this pattern loses half its mass without a word.
    for (x, y) in [(c.w / 3, c.h * 3 / 8), (c.w / 3, c.h * 5 / 8 - 1)] {
        c.wormhole(x, y);
        for (dx, dy) in [(-9, -9), (9, -9), (-9, 9), (9, 9)] {
            let (px, py) = (x + dx, y + dy);
            if dx < 0 {
                hseg(c, py, px - 3, px, WALL);
            } else {
                hseg(c, py, px, px + 3, WALL);
            }
            if dy < 0 {
                vseg(c, px, py - 3, py, WALL);
            } else {
                vseg(c, px, py, py + 3, WALL);
            }
        }
    }
    vseg(c, c.w / 2 - 1, c.h / 2 - 20, c.h / 2 - 4, WALL);
    hseg(c, 20, c.w / 4, c.w / 4 + 11, WALL);
    vseg(c, c.w / 4, 21, 32, WALL);
    hseg(c, 20, c.w * 3 / 4 - 11, c.w * 3 / 4, WALL);
    vseg(c, c.w * 3 / 4, 21, 32, WALL);
    for y in [24, c.h * 3 / 8 + 2] {
        let mut x = c.w / 4 + 12;
        while x <= c.w * 3 / 4 {
            c.small_rock(x, y, if (x / 12) % 2 == 0 { ROCK_A } else { ROCK_B });
            x += 12;
        }
    }
}

/// One dense band of rock sweeping the map on a shallow diagonal, built from
/// aligned rows of rock bars, with big anchor rocks down the middle and a
/// scatter of aligned outliers either side.
fn asteroid_belt(c: &mut Canvas, rng: &mut Rng) {
    let (w, h) = (c.w, c.h);
    let center = move |y: i32| w / 2 + (h / 2 - y) / 3;
    // Anchor rocks first: the weave parts around whatever already stands.
    let mut y = 8;
    while y < c.h / 2 {
        if y % 16 == 0 {
            c.object(center(y) - 1, y, 2, ROCK_BIG, ROCK_BODY);
        }
        y += 4;
    }
    // A brick weave on one global grid: runs of four, gaps of four, the grid
    // offset half a period every row, three open rows between. The gaps stay
    // vertically aligned because the grid is absolute; only the band's
    // envelope follows the diagonal. That is what keeps the belt porous to a
    // three-tile hull everywhere, where runs packed against the drifting
    // centerline sealed hull-sized pockets and the validator refused the map.
    let mut y = 8;
    while y < c.h / 2 {
        let bx = center(y);
        let phase = ((y / 4) % 2) * 4;
        let mut x = (bx - 22).div_euclid(8) * 8 + phase;
        while x + 3 < bx + 22 {
            if !rng.next().is_multiple_of(6) {
                let variant = if ((x / 8) + (y / 4)) % 2 == 0 {
                    ROCK_A
                } else {
                    ROCK_B
                };
                for n in 0..4 {
                    wall_tile(c, x + n, y, tile(SOLID, variant));
                }
            }
            x += 8;
        }
        if y % 12 == 0 {
            c.small_rock(bx - 26, y, ROCK_A);
            c.small_rock(bx + 25, y + 2, ROCK_B);
        }
        y += 4;
    }
}

/// Two-tile boulders planted on an even lattice, with the brief's three
/// reserved lanes reading as the orchard's own avenues, and a small rock at
/// every fourth cell center.
fn boulder_orchard(c: &mut Canvas, rng: &mut Rng) {
    // Rows picked to clear the reserved lanes plus the boulders' own
    // padding: a row on the step-twelve grid that grazes a lane loses every
    // boulder in it silently, which read as the orchard rotting in bands.
    for (row, y) in [12, 24, 50, 62].into_iter().enumerate() {
        let mut col = 0;
        let mut x = 20;
        while x < c.w - 20 {
            c.object(x, y, 2, ROCK_BIG, ROCK_BODY);
            if (row + col) % 4 == 0 {
                let variant = if rng.next().is_multiple_of(2) {
                    ROCK_A
                } else {
                    ROCK_B
                };
                c.small_rock(x + 6, y + 6, variant);
            }
            col += 1;
            x += 12;
        }
    }
}

/// Six-tile stations on a strict grid joined by gantry stubs, service marks
/// running under the lanes between the rows, and a timed door hanging off
/// each station's bay mouth.
fn station_yard(c: &mut Canvas) {
    let columns = [21, 45, 69, 93];
    let rows = [18, 48];
    for (r, &y) in rows.iter().enumerate() {
        for (k, &x) in columns.iter().enumerate() {
            if !c.object(x, y, 6, STATION, STATION_BODY) {
                continue;
            }
            // Both gantry stubs anchor to this station's own hull. A stub
            // reaching for a neighbor that failed to place is a bar floating
            // in open space.
            hseg(c, y + 2, x - 4, x - 1, WALL);
            hseg(c, y + 2, x + 6, x + 9, WALL);
            c.door_run(x + 2, y + 6, 4, true, ((r * 3 + k) % 8) as u8);
        }
    }
    for y in [c.h / 4, c.h / 2] {
        let mut x = 36;
        while x < c.w - 40 {
            c.scenery_pair(x, y, UNDER, ((x / 6) % 4) as u8);
            x += 6;
        }
    }
}

/// Brick-bond corridors: offset wall segments in aligned rows and columns,
/// every third gap closed by a door on its own channel, and the reserved
/// lanes cutting the three wide ways through.
fn maze(c: &mut Canvas, rng: &mut Rng) {
    // Rows land every twelve tiles; the ones inside a reserved lane are
    // skipped tile by tile, which is what turns the brief's three routes
    // into the maze's three wide avenues.
    let mut rows = Vec::new();
    let mut y = 16;
    while y < c.h / 2 + 6 {
        rows.push(y);
        y += 12;
    }
    for (r, &y) in rows.iter().enumerate() {
        let mut x = 14 + (r as i32 % 2) * 8;
        let mut n = 0;
        while x + 10 < c.w - 8 {
            hseg(c, y, x, x + 10, WALL);
            if n % 3 == 2 {
                c.door_run(x + 11, y, 5, false, ((r + n) % 8) as u8);
            }
            x += 16;
            n += 1;
        }
    }
    // A column crossing a row makes a plus, and a plus's center is a wall
    // tile walled on all four sides: exactly the shapeless block the gate
    // refuses. Columns therefore part a tile short of every row.
    let all_rows: Vec<i32> = rows.iter().flat_map(|&y| [y, c.h - 1 - y]).collect();
    for (k, &x) in [28, 52, 76, 100, 124, 148].iter().enumerate() {
        let mut y = 10 + (k as i32 % 2) * 6;
        while y + 8 < c.h / 2 + 8 {
            if !rng.next().is_multiple_of(4) {
                for yy in y..=y + 8 {
                    if all_rows.iter().any(|&r| (yy - r).abs() <= 1) {
                        continue;
                    }
                    wall_tile(c, x, yy, tile(SOLID, WALL));
                }
            }
            y += 12;
        }
    }
}

/// Each home inside a walled keep: open gates north and south, an open bay
/// east toward the field, a doored postern in the back wall, and a little
/// aligned cover in the middle ground.
fn twin_fortresses(c: &mut Canvas) {
    let (x0, x1) = (8, 40);
    let (y0, y1) = (c.h / 2 - 26, c.h / 2 + 26);
    let gate = |v: i32| (v - 4, v + 4);
    let (gx0, gx1) = gate((x0 + x1) / 2);
    let (gy0, gy1) = gate(c.h / 2);
    // The keep overlaps the home's reserved disk on purpose, so its walls
    // are placed directly; wall_tile would part around the reservation and
    // leave the keep in pieces.
    let put = |c: &mut Canvas, x: i32, y: i32| {
        if c.at(x, y) == EMPTY {
            c.pair(x, y, tile(SOLID, WALL));
        }
    };
    for x in x0..=x1 {
        if !(gx0..=gx1).contains(&x) {
            put(c, x, y0);
            put(c, x, y1);
        }
    }
    for y in y0..=y1 {
        if !(gy0..=gy1).contains(&y) {
            put(c, x1, y);
        }
        if !(c.h / 2 - 22..=c.h / 2 - 18).contains(&y) {
            put(c, x0, y);
        }
    }
    // The postern sits high in the back wall, outside the home's reserved
    // disk; door_run refuses reserved ground, so a postern at mid-wall
    // silently becomes an open gap instead of a door.
    c.door_run(x0, c.h / 2 - 22, 5, true, 2);
    for y in [c.h / 2 - 22, c.h / 2 + 6] {
        vseg(c, c.w / 2 - 8, y, y + 15, WALL);
    }
    for (x, y) in [(c.w / 2 - 1, 28), (c.w / 3, 24)] {
        c.small_rock(x, y, ROCK_A);
    }
}

/// Two parallel trenches across the middle with aligned crossings cut
/// through both walls, slope-cut mouths at the outer ends, and rock rows on
/// the open mesas above and below.
fn canyon(c: &mut Canvas) {
    // Slope mouths first: a slope run clears a padded box, so drawn second
    // it refuses to sit against the wall it is meant to cut into.
    c.slope_run(30, c.h / 2 - 26, 6, true);
    let gaps = [(c.w / 2 - 40, c.w / 2 - 32), (c.w / 2 + 32, c.w / 2 + 40)];
    for y in [c.h / 2 - 20, c.h / 2 - 10] {
        for x in 36..=c.w - 37 {
            if gaps.iter().any(|&(g0, g1)| (g0..=g1).contains(&x)) {
                continue;
            }
            wall_tile(c, x, y, tile(SOLID, WALL));
        }
    }
    for y in [20, 28] {
        let mut x = 48;
        while x <= c.w - 48 {
            c.small_rock(x, y, if (x / 12) % 2 == 0 { ROCK_A } else { ROCK_B });
            x += 12;
        }
    }
}

/// One broken capital ship laid across the middle: staggered six-tile hull
/// slabs with the reserved lanes flying through the breaks, slope-cut
/// fracture edges, debris rows fore and aft, and scenery trailing off the
/// wreck.
fn derelict(c: &mut Canvas, rng: &mut Rng) {
    // The wreck is one broken capital ship lying across the travel axis:
    // two contiguous hull slabs per side, filling the strips between the
    // reserved lanes, so the three breaks in the hull are the three ways
    // through. The slabs are painted directly, station corner tiles on
    // their own six-grid, because the object helper's padding refuses the
    // very contiguity a capital hull is made of. Each slab and its mirror
    // are painted separately so both carry corners at their own top-left; a
    // corner buried under another slab's body draws as nothing and collides
    // as everything.
    c.slope_run(22, c.h / 2 - 14, 3, true);
    c.slope_run(46, c.h / 2 - 12, 3, false);
    let slabs = [(7, c.h / 2 - 10), (45, c.h / 2 - 4)];
    for (x0, y0) in slabs {
        for (sx, sy) in [(x0, y0), (c.w - 18 - x0, c.h - 12 - y0)] {
            for dy in 0..12 {
                for dx in 0..18 {
                    let corner = dx % 6 == 0 && dy % 6 == 0;
                    let variant = if corner { STATION } else { STATION_BODY };
                    c.put(sx + dx, sy + dy, tile(SOLID, variant));
                }
            }
        }
    }
    for y in [c.h / 3 - 8, c.h / 3] {
        let mut x = 20;
        while x < c.w - 20 {
            if !rng.next().is_multiple_of(3) {
                let variant = if (x / 12) % 2 == 0 { ROCK_A } else { ROCK_B };
                c.bar(x, y, 2, false, variant);
            }
            x += 12;
        }
    }
    let mut y = c.h / 2 - 24;
    while y < c.h / 2 - 6 {
        c.scenery_pair(c.w / 4 - 6, y, OVER, ((y / 3) % 4) as u8);
        c.scenery_pair(c.w * 3 / 4, y + 1, OVER, ((y / 3) % 4) as u8);
        y += 3;
    }
}

/// Concentric square rings with the gaps rotated ring to ring: doors on the
/// bullseye's own gaps, a straight reserved corridor through the middle, the
/// outer margins carrying the flanking routes, and paired wormholes standing
/// in the inner gap ring, off the corridor.
fn rings(c: &mut Canvas) {
    let (cx, cy) = (c.w / 2, c.h / 2);
    let ring = |c: &mut Canvas, r: i32, top_gaps: &[(i32, i32)]| {
        let (lo_x, hi_x) = (cx - r, cx + r - 1);
        let (lo_y, hi_y) = (cy - r, cy + r - 1);
        for x in lo_x..=hi_x {
            if top_gaps.iter().any(|&(g0, g1)| (g0..=g1).contains(&x)) {
                continue;
            }
            wall_tile(c, x, lo_y, tile(SOLID, WALL));
        }
        for y in lo_y..=hi_y {
            wall_tile(c, lo_x, y, tile(SOLID, WALL));
        }
        (lo_x, lo_y)
    };
    let inner = ring(c, 20, &[(cx - 4, cx + 4)]);
    ring(c, 38, &[(cx - 24, cx - 16), (cx + 16, cx + 24)]);
    ring(c, 56, &[(cx - 4, cx + 4)]);
    c.door_run(cx - 4, inner.1, 9, false, 0);
    c.wormhole(cx, cy - 28);
    for (x, y) in [(cx - 47, cy - 47), (cx + 46, cy - 47)] {
        c.small_rock(x, y, ROCK_B);
    }
}

/// Diamonds cut from slope faces on an offset lattice, all faces at the 45
/// degrees the simulation reflects exactly, each grown around a rock core.
fn crystal_lattice(c: &mut Canvas) {
    for (row, y) in [20, 60].into_iter().enumerate() {
        let mut x = 36 + row as i32 * 12;
        while x < c.w - 24 {
            c.diamond(x, y, 3);
            x += 24;
        }
    }
    for x in [48, 96, 144] {
        c.small_rock(x, 40, ROCK_A);
        c.small_rock(x - 24, 40, ROCK_B);
    }
}

/// Four diagonal slope arms turning around an open hub, hooked caps at the
/// arm tips, corner brackets carrying the spin outward, and a pair of small
/// diamonds flanking the middle.
fn pinwheel(c: &mut Canvas) {
    let (cx, cy) = (c.w / 2, c.h / 2);
    c.slope_run(cx + 8, cy - 16, 14, false);
    c.slope_run(cx + 8, cy + 16, 14, true);
    hseg(c, cy - 31, cx + 24, cx + 43, WALL);
    vseg(c, cx + 23, cy + 31, cy + 50, WALL);
    hseg(c, 28, 28, 47, WALL);
    vseg(c, 28, 29, 47, WALL);
    hseg(c, 28, cx + 32, cx + 51, WALL);
    vseg(c, cx + 51, 29, 47, WALL);
    c.diamond(cx - 16, cy - 16, 2);
    for (x, y) in [(cx - 10, cy - 10), (cx - 10, cy + 10)] {
        c.small_rock(x, y, ROCK_B);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn built(theme: Theme, seed: u64) -> (Box<sim::sim_map>, MapMetrics) {
        let brief = Brief::candidate(seed, theme);
        let (map, graph) = brief.build().expect("a map");
        let wrapped = super::super::Brief::V2(brief);
        let metrics = assess_brief(&wrapped, &map, graph, false).expect("metrics");
        (map, metrics)
    }

    #[test]
    fn every_theme_is_accepted_across_seeds() {
        for theme in Theme::all() {
            for seed in [11, 12] {
                let (_, metrics) = built(theme, seed);
                assert!(
                    metrics.accepted,
                    "{} seed {seed}: {:?}",
                    theme.name(),
                    metrics.gates
                );
            }
        }
    }

    #[test]
    fn themes_place_their_signature_elements() {
        for theme in Theme::all() {
            let (map, _) = built(theme, 11);
            let m = materials(&map);
            let (doors, wormholes) = theme.allows();
            assert_eq!(m.safe + m.goals + m.turf, 0, "{}", theme.name());
            if doors {
                assert!(m.doors > 0, "{} places no doors", theme.name());
            } else {
                assert_eq!(m.doors, 0, "{}", theme.name());
            }
            if wormholes {
                assert!(m.wormholes > 0, "{} places no wormholes", theme.name());
            } else {
                assert_eq!(m.wormholes, 0, "{}", theme.name());
            }
            match theme {
                Theme::AsteroidBelt | Theme::BoulderOrchard => assert!(m.rocks > 60),
                Theme::StationYard | Theme::Derelict => assert!(m.stations >= 72),
                Theme::CrystalLattice | Theme::Pinwheel => assert!(m.slopes >= 16),
                Theme::Nebula => assert!(m.scenery > 100),
                Theme::Maze => assert!(m.wall > 300),
                _ => {}
            }
        }
    }
}
