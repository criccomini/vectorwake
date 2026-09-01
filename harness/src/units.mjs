// The one place that knows how far a tile is.
//
// The core holds a position in Q8: 256 to the pixel. `sim.ship_x_raw` divides
// that out, so what reaches the probe is pixels, and a tile is sixteen of
// them. Both numbers are easy to have a wrong idea about, and a harness with a
// wrong idea reports a ship that flew the length of the map as one that never
// moved, which is what the first run of this thing did.

export const PX_PER_TILE = 16

/** How far apart two things the probe reported are, in tiles. */
export function tilesApart (a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y) / PX_PER_TILE
}
