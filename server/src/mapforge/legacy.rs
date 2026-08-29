//! The archetype-and-scatter generator, frozen.
//!
//! The shipped melee rotation's recipes pin hashes produced by this exact
//! code, so it changes only if those maps are regenerated and their recipes
//! re-pinned. New maps come from `themes`, where a theme owns its geometry
//! instead of scattering material over a topology.

use super::*;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Archetype {
    ThreeLanes,
    RingSpokes,
    TwinHubs,
    Archipelago,
}

impl Archetype {
    pub fn name(self) -> &'static str {
        match self {
            Self::ThreeLanes => "three-lanes",
            Self::RingSpokes => "ring-spokes",
            Self::TwinHubs => "twin-hubs",
            Self::Archipelago => "archipelago",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    Dockyard,
    AsteroidReef,
    DerelictConvoy,
    RelayRing,
}

impl Theme {
    pub fn name(self) -> &'static str {
        match self {
            Self::Dockyard => "dockyard",
            Self::AsteroidReef => "asteroid-reef",
            Self::DerelictConvoy => "derelict-convoy",
            Self::RelayRing => "relay-ring",
        }
    }

    pub fn fidelity(self, m: &MaterialCounts) -> f64 {
        match self {
            Self::Dockyard => {
                0.6 * (m.stations as f64 / 144.0).min(1.0)
                    + 0.4 * (m.scenery as f64 / 24.0).min(1.0)
            }
            Self::AsteroidReef => (m.rocks as f64 / 180.0).min(1.0),
            Self::DerelictConvoy => {
                0.7 * (m.stations as f64 / 288.0).min(1.0)
                    + 0.3 * (m.scenery as f64 / 36.0).min(1.0)
            }
            Self::RelayRing => {
                0.5 * (m.slopes as f64 / 40.0).min(1.0)
                    + 0.3 * (m.stations as f64 / 144.0).min(1.0)
                    + 0.2 * (m.scenery as f64 / 24.0).min(1.0)
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
    pub archetype: Archetype,
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
    fn check(&self) -> Result<(), String> {
        if self.version != 1 {
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
        Gauge {
            name: self.name.clone(),
            seed: self.seed,
            mode: self.mode,
            routes: self.routes,
            min_opening_tiles: self.min_opening_tiles,
            contact_seconds: (self.contact_seconds_min, self.contact_seconds_max),
            allow_doors: self.allow_doors,
            allow_wormholes: self.allow_wormholes,
            wall_band: (1.5, 8.0),
            wall_target: 4.0,
        }
    }

    pub fn build(&self) -> Result<(Box<sim::sim_map>, LayoutGraph), String> {
        self.check()?;
        let graph = layout(self);
        let mut canvas = Canvas::new(self.envelope.width, self.envelope.height);
        canvas.reserve_graph(&graph);
        add_spawns(&mut canvas, &graph);
        arena_shape(&mut canvas, self.envelope.shape);
        skeleton(&mut canvas, self);
        theme(&mut canvas, self, &mut Rng::new(self.seed));
        sim::index_map(&mut canvas.map);
        Ok((canvas.map, graph))
    }
}

fn layout(brief: &Brief) -> LayoutGraph {
    let w = brief.envelope.width as i32;
    let h = brief.envelope.height as i32;
    let wide = w >= h;
    let (home0, home1) = if wide {
        ((18, h / 2), (w - 19, h / 2))
    } else {
        ((w / 2, 18), (w / 2, h - 19))
    };
    let mut g = LayoutGraph::new();
    let a = g.node(NodeKind::Home0, home0.0, home0.1, 13);
    let b = g.node(NodeKind::Home1, home1.0, home1.1, 13);
    let width = brief.min_opening_tiles as i32 + 4;
    match brief.archetype {
        Archetype::ThreeLanes => {
            if wide {
                for y in [h / 4, h / 2, h * 3 / 4] {
                    let l = g.node(NodeKind::Junction, w / 3, y, 9);
                    let r = g.node(NodeKind::Junction, w * 2 / 3, y, 9);
                    g.edge(a, l, width);
                    g.edge(l, r, width);
                    g.edge(r, b, width);
                }
            } else {
                for x in [w / 4, w / 2, w * 3 / 4] {
                    let t = g.node(NodeKind::Junction, x, h / 3, 9);
                    let d = g.node(NodeKind::Junction, x, h * 2 / 3, 9);
                    g.edge(a, t, width);
                    g.edge(t, d, width);
                    g.edge(d, b, width);
                }
            }
        }
        Archetype::RingSpokes => {
            let ring = [
                (w / 2, h / 2 - h / 5),
                (w / 2 + w / 5, h / 2),
                (w / 2, h / 2 + h / 5),
                (w / 2 - w / 5, h / 2),
            ]
            .map(|(x, y)| g.node(NodeKind::Junction, x, y, 10));
            for n in 0..4 {
                g.edge(ring[n], ring[(n + 1) % 4], width);
            }
            if wide {
                g.edge(a, ring[3], width);
                g.edge(ring[1], b, width);
                g.edge(ring[3], ring[1], width);
            } else {
                g.edge(a, ring[0], width);
                g.edge(ring[2], b, width);
                g.edge(ring[0], ring[2], width);
            }
        }
        Archetype::TwinHubs => {
            if wide {
                for y in [h / 2 - h / 6, h / 2 + h / 6] {
                    let hub = g.node(NodeKind::Landmark, w / 2, y, 13);
                    g.edge(a, hub, width);
                    g.edge(hub, b, width);
                }
                let center = g.node(NodeKind::Junction, w / 2, h / 2, 9);
                g.edge(a, center, width);
                g.edge(center, b, width);
            } else {
                for x in [w / 2 - w / 6, w / 2 + w / 6] {
                    let hub = g.node(NodeKind::Landmark, x, h / 2, 13);
                    g.edge(a, hub, width);
                    g.edge(hub, b, width);
                }
                let center = g.node(NodeKind::Junction, w / 2, h / 2, 9);
                g.edge(a, center, width);
                g.edge(center, b, width);
            }
        }
        Archetype::Archipelago => {
            if wide {
                for y in [h / 4, h / 2, h * 3 / 4] {
                    let l = g.node(NodeKind::Junction, w * 2 / 5, y, 10);
                    let r = g.node(NodeKind::Junction, w * 3 / 5, h - 1 - y, 10);
                    g.edge(a, l, width + 2);
                    g.edge(l, r, width + 2);
                    g.edge(r, b, width + 2);
                }
            } else {
                for x in [w / 4, w / 2, w * 3 / 4] {
                    let t = g.node(NodeKind::Junction, x, h * 2 / 5, 10);
                    let d = g.node(NodeKind::Junction, w - 1 - x, h * 3 / 5, 10);
                    g.edge(a, t, width + 2);
                    g.edge(t, d, width + 2);
                    g.edge(d, b, width + 2);
                }
            }
        }
    }
    g
}

fn skeleton(c: &mut Canvas, brief: &Brief) {
    let (w, h) = (c.w, c.h);
    match brief.archetype {
        Archetype::ThreeLanes => {
            if w >= h {
                for y in [h / 3, h * 2 / 3] {
                    c.line(w / 4, y, w / 2 - 9, y, tile(SOLID, WALL));
                }
                c.line(
                    w / 2 - 4,
                    h / 2 - 12,
                    w / 2 - 4,
                    h / 2 - 4,
                    tile(SOLID, WALL),
                );
            } else {
                for x in [w / 3, w * 2 / 3] {
                    c.line(x, h / 4, x, h / 2 - 9, tile(SOLID, WALL));
                }
                c.line(
                    w / 2 - 12,
                    h / 2 - 4,
                    w / 2 - 4,
                    h / 2 - 4,
                    tile(SOLID, WALL),
                );
            }
        }
        Archetype::RingSpokes => {
            let (cx, cy) = (w / 2, h / 2);
            let (rx, ry) = (w / 5, h / 5);
            c.line(cx - rx, cy - ry, cx - 8, cy - ry, tile(SOLID, WALL));
            c.line(cx + 8, cy - ry, cx + rx, cy - ry, tile(SOLID, WALL));
            c.line(cx + rx, cy - ry, cx + rx, cy - 8, tile(SOLID, WALL));
            c.line(cx + rx, cy + 8, cx + rx, cy + ry, tile(SOLID, WALL));
            if w >= h {
                c.line(cx - rx - 15, cy - 9, cx - rx - 4, cy - 9, tile(SOLID, WALL));
            } else {
                c.line(cx - 9, cy - ry - 15, cx - 9, cy - ry - 4, tile(SOLID, WALL));
            }
        }
        Archetype::TwinHubs => {
            if w >= h {
                let y = h / 2 - h / 6;
                c.line(w / 2 - 17, y - 8, w / 2 - 7, y - 8, tile(SOLID, WALL));
                c.line(w / 2 + 7, y + 8, w / 2 + 17, y + 8, tile(SOLID, WALL));
                c.line(w / 2, h / 2 - 8, w / 2, h / 2 - 4, tile(SOLID, WALL));
            } else {
                let x = w / 2 - w / 6;
                c.line(x - 8, h / 2 - 17, x - 8, h / 2 - 7, tile(SOLID, WALL));
                c.line(x + 8, h / 2 + 7, x + 8, h / 2 + 17, tile(SOLID, WALL));
                c.line(w / 2 - 8, h / 2, w / 2 - 4, h / 2, tile(SOLID, WALL));
            }
        }
        Archetype::Archipelago => {
            let points = [
                (w / 3, h / 3),
                (w / 2 - 8, h * 2 / 3),
                (w / 2 + 11, h / 2 - 5),
            ];
            for &(x, y) in &points {
                c.line(x - 4, y, x + 4, y, tile(SOLID, ROCK_A));
                c.line(x, y - 3, x, y + 3, tile(SOLID, ROCK_B));
            }
        }
    }
}

fn theme(c: &mut Canvas, brief: &Brief, rng: &mut Rng) {
    if brief.theme == Theme::RelayRing {
        // A relay field gets one unmistakable diagonal signal arm. Try a few
        // authored sites because the topology may reserve any one of them.
        for &(x, y, down) in &[(26, 26, true), (c.w / 3, 22, false), (24, c.h - 30, false)] {
            if c.slope_run(x, y, 5, down) {
                break;
            }
        }
    }
    let attempts = match brief.theme {
        Theme::Dockyard => 90,
        Theme::AsteroidReef => 110,
        Theme::DerelictConvoy => 90,
        Theme::RelayRing => 80,
    };
    for n in 0..attempts {
        let x = rng.range(10, c.w / 2 - 5);
        let y = rng.range(10, c.h - 10);
        match brief.theme {
            Theme::Dockyard => {
                if n < 8 {
                    c.object(x, y, 6, STATION, STATION_BODY);
                } else if n % 4 == 0 {
                    c.scenery_pair(x, y, UNDER, (n % 4) as u8);
                } else {
                    c.bar(x, y, rng.range(4, 10), n % 2 == 0, WALL);
                }
            }
            Theme::AsteroidReef => {
                let reefs = [
                    (c.w / 5, c.h / 4),
                    (c.w / 3, c.h / 5),
                    (c.w / 4, c.h / 2),
                    (c.w / 3, c.h * 3 / 4),
                    (c.w / 6, c.h * 4 / 5),
                ];
                let reef = reefs[n as usize % reefs.len()];
                let x = reef.0 + rng.range(-12, 13);
                let y = reef.1 + rng.range(-12, 13);
                if n % 5 == 0 {
                    c.object(x, y, 2, ROCK_BIG, ROCK_BODY);
                } else {
                    c.small_rock(x, y, if n % 2 == 0 { ROCK_A } else { ROCK_B });
                    c.small_rock(
                        x + 5,
                        y + if n % 3 == 0 { 3 } else { -3 },
                        if n % 2 == 0 { ROCK_B } else { ROCK_A },
                    );
                }
            }
            Theme::DerelictConvoy => {
                if n < 12 {
                    c.object(x, y, 6, STATION, STATION_BODY);
                } else if n % 3 == 0 {
                    c.scenery_pair(x, y, OVER, (n % 4) as u8);
                } else {
                    c.bar(x, y, rng.range(3, 9), n % 4 == 0, WALL);
                }
            }
            Theme::RelayRing => {
                if n < 8 {
                    c.object(x, y, 6, STATION, STATION_BODY);
                } else if n < 16 {
                    c.slope_run(x, y, 4, n % 2 == 0);
                } else if n % 3 == 0 {
                    c.scenery_pair(x, y, UNDER, (n % 8) as u8);
                } else {
                    c.bar(x, y, rng.range(3, 7), n % 2 == 0, WALL);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curated_maps_match_their_recipes() {
        for name in [
            "drydock",
            "relay",
            "convoy",
            "shoal",
            "breakwater",
            "switchyard",
        ] {
            let base = PathBuf::from("../catalog/zones/melee");
            let text = std::fs::read_to_string(base.join(format!("{name}.recipe.toml")))
                .expect("a recipe");
            let brief: Brief = toml::from_str(&text).expect("a version 1 brief");
            let (map, graph) = brief.build().expect("a generated map");
            let wrapped = super::super::Brief::V1(brief.clone());
            let metrics = assess_brief(&wrapped, &map, graph, false).expect("metrics");
            println!("MEASURE {name}: contact {:.2}", metrics.contact_seconds);
            assert!(metrics.accepted, "{name}: {:?}", metrics.gates);
            assert_eq!(brief.expected_hash.as_deref(), Some(metrics.hash.as_str()));
            assert_eq!(
                std::fs::read(base.join(format!("{name}.vwmap"))).expect("a shipped map"),
                sim::pack_map(&map).expect("packed output"),
                "{name} differs from its recipe"
            );
        }
    }
}
