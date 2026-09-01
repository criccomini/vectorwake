# Zones

Team Battle is the whole catalog today. Four more games are planned beside it:

- **Duel**, one against one, rated.
- **War**, four a side capturing flags, named for the original's War Zone.
- **Turf**, four a side holding fixed flags scattered over the map.
- **Free roam**, a giant map in the tradition of Alpha and Chaos, up to
  sixty-four pilots in one room, up to eight a side, greens on the field.

This document says what each of those is as a game, what it asks of the
engine, and in what order to build them. The short answer on the engine is
that we already have the one these games need, and the temptation to build "a
flexible mode framework" first should be resisted, because the flexibility is
already where it belongs and a framework would be a fifth project in front of
four games.

## Where a zone's rules live

Subspace ran hundreds of distinct games for thirty years without zone owners
modifying the engine, and it is worth being precise about how, because the
folklore version ("it was all SERVER.CFG and bots") hides the actual split.
Three layers carried it:

1. **SERVER.CFG** held the numbers: physics, weapons, prizes, flag timers.
2. **The engine** held mechanisms with no opinions: flags could be carried,
   prizes could be picked up, and nothing in the physics knew what winning
   meant.
3. **The bots** held the meaning. A league zone's rules were thousands of
   lines of zone-specific bot code, and "no engine modifications" really
   meant that the per-zone game logic lived outside the engine, not that it
   did not exist.

vectorwake has rebuilt the same split on purpose:

1. The **catalog** is our SERVER.CFG. A zone declares its mode, maps, sides
   and caps, and overrides any `sim_settings` field, which is how one zone
   flies Alpha's weapon tables while another halves the wormhole reach. See
   [architecture/catalog.md](../architecture/catalog.md).
2. The **simulation core** is the mechanism layer. It moves flags, reports
   who holds them, and refuses to know what an arrangement of them means.
3. **Modes** in `server/src/modes.rs` are where the meaning went. A mode is
   a small compiled Rust type behind the `Mode` trait: it watches the state a
   tick produced, writes the banner, keeps the score, and says when a match
   opens and closes. This is the layer Subspace kept in bots, moved inside
   the server where it can be tested. The original decision here proposed
   sandboxed WebAssembly modules and is superseded
   ([decision 6](../architecture/decisions.md#6-zone-modules-are-sandboxed));
   compiled Rust won, and nothing below reopens that.

Every zone in this document decomposes along this split: a mechanism or two
in the sim, a mode or a mode parameter in Rust, and numbers in the catalog.
None of them needs a new layer.

## Duel

Two pilots, one small map, rated. The whole of it was built once:
[decision 92](../architecture/decisions.md#92-duel-is-two-pilots-and-the-door-decides-which-two)
made the duel a rated 1v1 with pairing at the door, and
[decision 96](../architecture/decisions.md#96-duels-are-gone) removed it, as
a product call about focus rather than a technical retreat. `rating.rs` is
still in the tree and the pit maps still draw.

Bringing it back is a catalog row (`melee`, two sides, one human each), the
pairing flow, and the client's duel board, which was built and removed with
the rest. The engineering is days, so the only real question is the product
one: decision 96 was made deliberately, and reversing it should be too.

## War

The classic flag game. Flags start neutral in bases, only opponents can pick
one up, a carried flag drops after a set time or when the carrier dies, and a
team wins the round by claiming the whole set. Heavily team-oriented, built
around defensible bases.

Most of this exists. The `Warzone` mode is implemented and tested: hold every
flag for the timer to take the round, flags go neutral and return home on the
reset. The sim already enforces opponents-only pickup (`update_flags` skips a
flag your side owns) and drops a dying carrier's flags where they died, still
owned, behind a cooldown. Maps carry per-team spawn points
(`sim_map_spawn`), so spawning each side near its own base is a map's job,
not a sim change.

What is missing:

- **A carry timer.** A carried flag today stays carried until the carrier
  dies. The original drops it after a set time, which is what keeps one fast
  ship from vanishing with the game. One `sim_settings` field and a per-flag
  clock; it touches sim state, so it is a `CFG_VERSION` bump and a golden
  regeneration.
- **Base maps.** A flag game is its base geometry: chokepoints, a flag room,
  approaches worth fighting over. Mapforge builds melee rooms; whether it can
  build a defensible base is open, and hand-building the first War map is the
  honest fallback.
- **Bots that play the objective.** The current brains fight. None of them
  flies to a flag, defends a room, or escorts a carrier. This is the largest
  line item, here and in Turf, and there is no configuring around it: it is
  exactly the code Subspace zones put in their bots.

The zone definition writes itself: two named sides, `max_humans_per_team = 4`,
`max_rooms = 1`, the last because a long flag game deserves its own blast
radius, which is the argument
[architecture/zones-and-arenas.md](../architecture/zones-and-arenas.md)
already makes about War by name.

## Turf

Territorial flags. Each flag is fixed at its spot on the map, flying over it
claims it for your side, and holding stands pays: either points on a period,
or a win for holding the set. Which of the two is a mode parameter, not two
modes.

This is the cheapest flag game, because the client comes free. Flags are
already on the wire and drawn as pennants, and `SIM_TILE_TURF` already exists
as a tile class the map surfaces as a feature ("a flag stand a mode can
find"). Nothing acts on it yet. Two pieces close the gap:

- **A fixed bit on `sim_flag`.** A turf flag transfers to the side that
  touches it and never sets `carried`. The room places one on each turf
  stand when it builds the map. Small sim change, same `CFG_VERSION` and
  golden cost as the carry timer.
- **A `Turf` mode.** Awards points per held stand on a period, scores
  through the per-side score `MatchState` already carries, and runs either
  on Melee's clock-and-intermission skeleton or continuously in Warzone's
  manner.

`SIM_MAX_FLAGS` is 16, which bounds the stands a map can offer. Enough for a
first Turf map, and a dial rather than a wall if a later one wants more.

## Free roam

The original public zone: a huge map, no clock, no matches, fly out and fight
whoever you find. Up to sixty-four pilots in a room, sides of up to eight,
and greens on the field so a ship grows over a life and loses it on death.

More of this is ready than it looks. Sixty-four seats sit far under
`SIM_MAX_SHIPS`; snapshots are interest-culled, so a crowded room does not
cost every client the whole room's traffic; eight sides of eight is already
expressible in the catalog (`teams`, `max_humans_per_team`); map format v2
carries per-map dimensions, so "giant" is a mapforge scale to reach for; and
a continuous room with no clock is what the `arena` mode already is. One
small map note: the sim's spawn lists split two ways (`SIM_SIDES`), and a
free roam map wants scattered neutral spawns anyway, so nothing forces that
constant up.

Greens are the real work, and the only genuinely new engine system in this
document. They existed once, were replaced by kits in the match-game rethink,
and survive in the sim only as a comment. The landing zone survived with
them: the kit slot space is per-ship, and its own header says it "used to be
the space a green indexed, one byte per prize, rolled by the server against a
table of weights." A green is a field entity whose pickup bumps one slot on
the ship that took it. Building them back means:

- the entity in sim state, with spawn rules that keep them out of walls,
  which we solved the first time;
- a prize weight table in `sim_settings`, so what greens grant is zone data
  like everything else, and Team Battle sets the spawn rate to zero and
  changes nothing;
- the wire, the client's drawing of them, and a pickup sound;
- a death policy: the original takes a share of your greens back when you
  die, and that share is another settings number.

Greens also have to coexist with
[decision 117](../architecture/decisions.md#117-the-build-is-the-pilots-not-the-hulls)'s
one build per pilot and
[decision 121](../architecture/decisions.md#121-the-loadout-is-nobodys-ship)'s
room-owned weapon ladders. The clean reading: a green climbs the same
ladders, above the pilot's build, within the zone's ceilings. A build is what
you start a life with; greens are what that life earned; death settles the
difference.

## What we will not build

**A module runtime.** Decision 6's sandboxed modules stay superseded. The
four zones above need two new modes and a parameter between them, which is no
argument for an ABI, an authoring system, and a sandbox. Generalize when the
fifth zone does not fit, not before.

**A mode-aware client.** The client reads the catalog's format strip, draws
pennants off the wire, and gets the match clock from `match_state`. Turf and
War ride that as it stands. The duel board and the drawing of greens are each
one bespoke piece, and that is the ceiling: a client that switches behavior
on the mode name is a client that needs shipping every time the catalog
grows.

## What every zone costs

A zone is not only its mode. Each row in the catalog brings:

- **A bot population that plays the objective.** At our population a zone
  without one is a dead room, and objective-playing brains are the single
  largest item on both flag games.
- **A balance surface.** Every mode is a new answer to "which hull wins
  here," and the calibrate infrastructure (skill strata, paired bouts, the
  4v4 and 1v1 arms) exists to keep asking it.
- **An ops row.** Fleet capacity, fill targets, and one more game whose
  health somebody reads on the admin panel.

This is the honest brake on the list growing. Team Battle got good by being
the only game; each zone added divides the population and the tuning
attention, which is why the order below is an order and not a sprint.

## Order of work

1. **Turf.** The smallest sim delta, the client comes free, and turf bots
   are the easy end of objective play: fly to a point and fight near it.
   It proves the whole path a new zone takes through the engine.
2. **War.** The carry timer, a base map, and the first real objective bots:
   navigation to flags, defense, escort.
3. **Duel**, whenever the product appetite returns. The engineering is small
   and known; the decision is the work.
4. **Free roam** last, because greens are the one new system in it and
   everything else is configuration and scale.
