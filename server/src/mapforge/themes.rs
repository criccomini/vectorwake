//! The pattern generator: a theme owns its geometry.
//!
//! A theme here is the topology, not a coat of paint over one. Every stamp
//! sits on a module grid, placement runs along lattices, rows, rings and
//! spiral arms rather than rejection sampling, and the seed varies texture
//! inside the pattern rather than the pattern itself. Each theme also declares
//! which map elements it uses and the cover band it is held to, which is how
//! doors and wormholes reach generated maps and how a maze is allowed five
//! times the wall of a nebula.

use super::*;

/// Cosine and sine of 32 evenly spaced headings, scaled by 1024.
///
/// Integer, and a table rather than a call, because a recipe pins the hash of
/// the map it draws. A libm that rounds one heading a bit differently would
/// move a rock one tile and fail verification on a machine that was not the
/// one that pinned it, which is the same reason the simulation core has no
/// floats in it.
const RING32: [(i32, i32); 32] = [
    (1024, 0),
    (1004, 200),
    (946, 392),
    (851, 569),
    (724, 724),
    (569, 851),
    (392, 946),
    (200, 1004),
    (0, 1024),
    (-200, 1004),
    (-392, 946),
    (-569, 851),
    (-724, 724),
    (-851, 569),
    (-946, 392),
    (-1004, 200),
    (-1024, 0),
    (-1004, -200),
    (-946, -392),
    (-851, -569),
    (-724, -724),
    (-569, -851),
    (-392, -946),
    (-200, -1004),
    (0, -1024),
    (200, -1004),
    (392, -946),
    (569, -851),
    (724, -724),
    (851, -569),
    (946, -392),
    (1004, -200),
];

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    SpiralNebula,
    StationYard,
    Maze,
    TwinFortresses,
    Rings,
}

impl Theme {
    pub fn all() -> [Self; 5] {
        [
            Self::SpiralNebula,
            Self::StationYard,
            Self::Maze,
            Self::TwinFortresses,
            Self::Rings,
        ]
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::SpiralNebula => "spiral-nebula",
            Self::StationYard => "station-yard",
            Self::Maze => "maze",
            Self::TwinFortresses => "twin-fortresses",
            Self::Rings => "rings",
        }
    }

    fn envelope(self) -> (u16, u16) {
        match self {
            Self::StationYard | Self::TwinFortresses => (192, 144),
            _ => (160, 160),
        }
    }

    fn contact_window(self) -> (f64, f64) {
        match self {
            Self::Maze => (6.0, 17.2),
            Self::TwinFortresses | Self::Rings => (6.0, 14.5),
            _ => (6.0, 11.6),
        }
    }

    /// The doors and wormholes a candidate brief for this theme asks for.
    /// What a brief does with either is on the fields themselves.
    fn allows(self) -> (bool, bool) {
        match self {
            Self::StationYard | Self::Maze | Self::TwinFortresses => (true, false),
            Self::SpiralNebula => (false, true),
            Self::Rings => (true, true),
        }
    }

    fn wall_band(self) -> (f64, f64, f64) {
        match self {
            Self::SpiralNebula => (1.0, 6.0, 2.5),
            Self::StationYard => (1.5, 7.0, 3.0),
            Self::Maze => (2.5, 12.0, 5.0),
            Self::TwinFortresses => (1.0, 5.0, 2.5),
            Self::Rings => (2.0, 7.0, 4.0),
        }
    }

    pub fn fidelity(self, m: &MaterialCounts) -> f64 {
        let part = |count: usize, full: f64| (count as f64 / full).min(1.0);
        match self {
            Self::SpiralNebula => {
                0.6 * part(m.rocks, 260.0)
                    + 0.2 * part(m.wormholes, 2.0)
                    + 0.2 * part(m.scenery, 120.0)
            }
            Self::StationYard => {
                0.5 * part(m.stations, 400.0)
                    + 0.3 * part(m.doors, 16.0)
                    + 0.2 * part(m.scenery, 40.0)
            }
            Self::Maze => 0.7 * part(m.wall, 700.0) + 0.3 * part(m.doors, 20.0),
            Self::TwinFortresses => 0.6 * part(m.wall, 250.0) + 0.4 * part(m.doors, 10.0),
            Self::Rings => {
                0.5 * part(m.wall, 600.0) + 0.3 * part(m.doors, 14.0) + 0.2 * part(m.wormholes, 4.0)
            }
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
    /// Doors, checked against what the theme drew. A theme draws its doors
    /// or it does not, so a brief refusing them on a theme that draws them
    /// is refused rather than redrawn.
    #[serde(default)]
    pub allow_doors: bool,
    /// Wormholes, which a brief can turn off: `Canvas::wormhole` then lays
    /// the clearing and no mouth, leaving the rest of the pattern where it
    /// was. The duel's maps are drawn that way, because a warp on ground
    /// that small is a way out of the only fight in the room.
    #[serde(default)]
    pub allow_wormholes: bool,
    #[serde(default)]
    pub expected_hash: Option<String>,
    /// Flag stands to lay, absent meaning whatever the mode wants. Melee
    /// wants none; a flag game wants the number its zone plays for.
    #[serde(default)]
    pub stands: Option<u8>,
}

impl Brief {
    /// How many stands this map draws. A melee map draws none and is refused
    /// if it somehow does; a flag game's default is the count its rules read
    /// best at, and a recipe overrides either.
    ///
    /// Four for War, because a round is won by holding the set and a set of
    /// four is small enough for a side of four to cover and large enough that
    /// covering it costs them the map. Six for Turf, where nothing is won by
    /// holding all of them: two more stands than either side has pilots is
    /// what stops the game being one scrum that moves around the map.
    ///
    /// Both are even, and so is any count a recipe may name. See `add_stands`.
    pub fn stands(&self) -> u8 {
        self.stands.unwrap_or(match self.mode {
            Mode::Melee => 0,
            Mode::Goal => 4,
            Mode::Turf => 6,
        })
    }
    pub fn candidate(seed: u64, theme: Theme) -> Self {
        Self::named(
            format!("{}-{:04x}", theme.name(), seed & 0xffff),
            seed,
            theme,
        )
    }

    pub fn named(name: String, seed: u64, theme: Theme) -> Self {
        let (width, height) = theme.envelope();
        let contact = theme.contact_window();
        let (allow_doors, allow_wormholes) = theme.allows();
        Self {
            version: 2,
            name,
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
            stands: None,
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
        // The core holds sixteen flags and a room stands one on each stand,
        // so a map that draws more is drawing objectives no game can see.
        if self.stands() as usize > sim::MAX_FLAGS {
            return Err(format!(
                "a map may draw at most {} flag stands",
                sim::MAX_FLAGS
            ));
        }
        if self.mode == Mode::Melee && self.stands() != 0 {
            return Err("a melee map has no flag stands".into());
        }
        if self.mode != Mode::Melee && self.stands() == 0 {
            return Err("a flag game needs stands to fight over".into());
        }
        // Every stand is drawn with its half-turn twin, and an even-sided map
        // has no middle tile that is its own twin, so there is no arrangement
        // an odd count could take that both sides would face alike.
        if !self.stands().is_multiple_of(2) {
            return Err("flag stands are drawn in pairs, so the count is even".into());
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
            stands: self.stands(),
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
        //
        // The nebula bows its middle lane clear of the core. A lane straight
        // through the middle would both erase the ring the arms wind around
        // and make the shortest home-to-home route a dive into the wormhole,
        // which the route gate cannot see: a wormhole is open ground to a
        // path search and an ejector seat to a pilot.
        // The nebula's outer lanes ride wider than the usual quarters. A lane
        // reserves a band about eleven tiles deep and its half turn reserves
        // another, so three lanes bunched around the middle erase most of an
        // arm; pushed out to the sixths they cross it instead.
        let lanes = if self.theme == Theme::SpiralNebula {
            [h / 6, h / 2 - 24, h * 5 / 6]
        } else {
            [h / 4, h / 2, h * 3 / 4]
        };
        if w >= h {
            for y in lanes {
                let l = g.node(NodeKind::Junction, 34, y, 7);
                let r = g.node(NodeKind::Junction, w - 35, y, 7);
                g.edge(a, l, width);
                g.edge(l, r, width);
                g.edge(r, b, width);
            }
        } else {
            for x in lanes {
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
        canvas.allow_wormholes = self.allow_wormholes;
        canvas.reserve_graph(&graph);
        add_spawns(&mut canvas, &graph);
        add_stands(&mut canvas, &graph, self.stands());
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
        Theme::SpiralNebula => spiral_nebula(c, rng),
        Theme::StationYard => station_yard(c),
        Theme::Maze => maze(c, rng),
        Theme::TwinFortresses => twin_fortresses(c),
        Theme::Rings => rings(c),
    }
}

/// A two-armed spiral of asteroids winding out of a wormhole core.
///
/// One arm is drawn and the map's own half turn provides the other, which is
/// what a two-armed galaxy is. Clumps step out along the arm at an even arc,
/// so the pattern reads as one curve rather than as rings of rubble, and the
/// core wears a rock collar with four diagonal mouths: the collar stops the
/// straight run through the middle from being the shortest way across, and
/// the mouths keep the wormhole somewhere a pilot chooses to go.
fn spiral_nebula(c: &mut Canvas, rng: &mut Rng) {
    let (cx, cy) = (c.w / 2, c.h / 2);
    // Two wormhole tiles in the middle, which is one call: `wormhole` lays a
    // tile and its half-turn twin, so a single call at the center leaves a
    // diagonal domino. A second at cx - 1 squares that off into a 2x2 and is
    // the shape this wanted, but coincident tiles sum and four of them pull
    // four times as hard. That put the point of no return at 33 to 38 tiles
    // of a 38-tile field, so on this map alone, reaching the field was the
    // whole decision and three of the seven hulls could not thrust out of it
    // from anywhere inside. Two tiles is a core the spiral can be drawn
    // around at a strength the field can still be flown through.
    c.wormhole(cx, cy);
    // The collar: an annulus scanned by squared radius rather than sampled
    // around a circle, because a ring of sampled headings at this radius
    // lands its tiles two apart and reads as a dotted line a ship flies
    // straight through. Its four mouths sit on the diagonals, cut where the
    // two axes are within four of each other, which leaves each about five
    // tiles across: a way in for a three-tile hull, and no way to carry
    // speed straight through the middle of the map.
    for dy in -16i32..=16 {
        for dx in -16i32..=16 {
            let d2 = dx * dx + dy * dy;
            if !(169..=256).contains(&d2) || (dx.abs() - dy.abs()).abs() <= 4 {
                continue;
            }
            let variant = if (dx + dy).rem_euclid(2) == 0 {
                ROCK_A
            } else {
                ROCK_B
            };
            wall_tile(c, cx + dx, cy + dy, tile(SOLID, variant));
        }
    }
    // The arm. Radius grows two tiles per clump and the heading advances by
    // an arc rather than a fixed angle, so clumps stay about seven tiles
    // apart the whole way out instead of bunching at the core and stretching
    // at the rim. 2048 units is a full turn, so an arc of seven tiles is
    // 2048 * 7 / (2 pi r), or 2281 / r.
    //
    // Those two rates together are what makes this an arm rather than a set
    // of rings: from the collar to the rim it sweeps about four fifths of a
    // turn. Growing the radius one tile a clump instead of two draws the same
    // rocks around one and a half turns, and a spiral that laps itself reads
    // as concentric circles however it was generated.
    let mut r = 20i32;
    let mut turn = 0i32;
    let mut clump = 0i32;
    while r < c.w.min(c.h) / 2 - 8 {
        let i = ((turn / 64).rem_euclid(32)) as usize;
        let (dx, dy) = RING32[i];
        let (x, y) = (cx + dx * r / 1024, cy + dy * r / 1024);
        // Runs lie along whichever axis the arm is travelling, so a clump
        // reads as a piece of the curve rather than as a brick dropped on it.
        // The second run, set a few tiles further out on alternate clumps,
        // is what gives the arm width; a single file of rocks at this
        // spacing reads as a dotted line.
        let along_x = dy.abs() > dx.abs();
        let length = 4 + (rng.next() % 4) as i32;
        let variant = if clump % 2 == 0 { ROCK_A } else { ROCK_B };
        for lane in 0..if clump % 2 == 0 { 2 } else { 1 } {
            let out = lane * 3;
            let (bx, by) = if along_x {
                (x, y + if dy > 0 { out } else { -out })
            } else {
                (x + if dx > 0 { out } else { -out }, y)
            };
            for n in 0..length - lane {
                let (sx, sy) = if along_x { (bx + n, by) } else { (bx, by + n) };
                wall_tile(c, sx, sy, tile(SOLID, variant));
            }
        }
        if clump % 3 == 1 {
            c.object(x + 4, y + 4, 2, ROCK_BIG, ROCK_BODY);
        }
        // The gas the rocks are riding in. Non-solid, so it costs the fight
        // nothing and gives the arm an edge the eye can follow between the
        // clumps.
        for n in -3..=3 {
            let (sx, sy) = if along_x {
                (x + n, y - 2)
            } else {
                (x - 2, y + n)
            };
            c.scenery_pair(sx, sy, UNDER, ((clump + n) % 4).unsigned_abs() as u8);
        }
        turn += 2281 / r;
        r += 2;
        clump += 1;
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
    // The cross walls are short and sparse on purpose. Run them the full
    // twelve tiles between rows and every pocket in the weave closes to
    // three sides: measured over twenty matches that maze answered skill
    // with a +0.69 correlation against the rotation's +0.87, and threw a
    // third fewer rounds, because pilots spent the match walking corridors
    // instead of meeting in them. A pilot should be able to leave a pocket
    // the way they did not come in.
    let all_rows: Vec<i32> = rows.iter().flat_map(|&y| [y, c.h - 1 - y]).collect();
    for (k, &x) in [28, 52, 76, 100, 124, 148].iter().enumerate() {
        let mut y = 10 + (k as i32 % 2) * 6;
        while y + 5 < c.h / 2 + 8 {
            if rng.next().is_multiple_of(2) {
                for yy in y..=y + 5 {
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
                Theme::SpiralNebula => assert!(m.rocks > 120 && m.scenery > 40),
                Theme::StationYard => assert!(m.stations >= 72),
                Theme::Maze => assert!(m.wall > 300),
                Theme::TwinFortresses => assert!(m.wall > 150),
                Theme::Rings => assert!(m.wall > 300),
            }
        }
    }

    /// Every shipped version 2 map is the exact output of the recipe beside
    /// it, so a change in here that moves a tile fails the build rather than
    /// the match. Regenerating a map on purpose means re-pinning its recipe.
    ///
    /// Version 1 drew the rest of the melee rotation and `legacy` pins those
    /// itself; the roam map comes from `sim/tools/mapgen.c` and has no brief
    /// to pin it against.
    #[test]
    fn the_rotation_matches_its_recipes() {
        for (zone, name) in [
            ("melee", "maelstrom"),
            ("melee", "gantry"),
            ("melee", "warren"),
            ("melee", "redoubt"),
            ("melee", "ringworks"),
            ("turf", "gyre"),
            ("turf", "holdfast"),
            ("turf", "stanchion"),
            ("war", "bulwark"),
            ("war", "lattice"),
            ("war", "rampart"),
            ("duel", "eddy"),
            ("duel", "gimbal"),
            ("duel", "sconce"),
        ] {
            let base = PathBuf::from(format!("../catalog/zones/{zone}"));
            let text = std::fs::read_to_string(base.join(format!("{name}.recipe.toml")))
                .expect("a recipe");
            let brief: Brief = toml::from_str(&text).expect("a version 2 brief");
            let (map, graph) = brief.build().expect("a generated map");
            let expected_hash = brief.expected_hash.clone();
            let wrapped = super::super::Brief::V2(brief);
            let metrics = assess_brief(&wrapped, &map, graph, false).expect("metrics");
            assert!(metrics.accepted, "{name}: {:?}", metrics.gates);
            assert_eq!(expected_hash.as_deref(), Some(metrics.hash.as_str()));
            assert_eq!(
                std::fs::read(base.join(format!("{name}.vwmap"))).expect("a shipped map"),
                sim::pack_map(&map).expect("packed output"),
                "{name} differs from its recipe"
            );
        }
    }

    /// `allow_wormholes` is an instruction and not only a check. A theme that
    /// draws a warp draws none for a brief that refuses one, and the rest of
    /// the pattern does not move: the map is the nebula or the rings without
    /// its well rather than some other map that happens to have neither.
    #[test]
    fn a_brief_can_refuse_the_wormholes_its_theme_draws() {
        for theme in [Theme::SpiralNebula, Theme::Rings] {
            let with = Brief::candidate(11, theme).build().expect("a map").0;
            let mut brief = Brief::candidate(11, theme);
            brief.allow_wormholes = false;
            let (without, graph) = brief.build().expect("a map");
            assert_eq!(materials(&without).wormholes, 0, "{}", theme.name());
            for y in 0..with.h as usize {
                for x in 0..with.w as usize {
                    let i = y * sim::MAP_TILES + x;
                    if with.tile[i] & 15 == WORMHOLE {
                        assert_eq!(without.tile[i], EMPTY, "{} at {x},{y}", theme.name());
                    } else {
                        assert_eq!(
                            with.tile[i],
                            without.tile[i],
                            "{} moved a tile at {x},{y}",
                            theme.name()
                        );
                    }
                }
            }
            let wrapped = super::super::Brief::V2(brief);
            let metrics = assess_brief(&wrapped, &without, graph, false).expect("metrics");
            assert!(metrics.accepted, "{}: {:?}", theme.name(), metrics.gates);
        }
    }

    /// A wormhole sends a ship to its own side's start, so a route that runs
    /// through one is not a route across the map: it is a way home. The route
    /// search sees open ground there, which means nothing but this test keeps
    /// the shortest home-to-home path clear of a warp.
    #[test]
    fn no_shortest_route_runs_through_a_wormhole() {
        for theme in [Theme::SpiralNebula, Theme::Rings] {
            let (map, metrics) = built(theme, 11);
            for route in &metrics.route_overlay {
                for point in route {
                    let value = map.tile[point[1] as usize * sim::MAP_TILES + point[0] as usize];
                    assert_ne!(
                        value & 15,
                        WORMHOLE,
                        "{}: a scored route crosses a wormhole at {point:?}",
                        theme.name()
                    );
                }
            }
        }
    }
}
