# One row grammar

**Built.** See [decision 72](../../docs/architecture/decisions.md), and
`client/tests/row_field_test.lua`, which holds every page to the rule. The
standing row also breathes, which these boards do not show: the ink on it
runs 0.74 to full on the clock the landing key breathes on.


Six boards proposing a single way to draw a hovered or standing row in the
menu, against the eight ways `client/arena/ui.lua` draws one today: the
stage's full-bleed wash at 0.18, the kit rows' left-bleed at 0.2 (0.1
unfocused, two points shaved off the top), the friends rows' floating band at
0.16, the builds rows' overhang past the panel edge at 0.2, the ship grid's
inset cell at 0.14, the rail stop's inset slot at 0.16, and the call sign
dropdown's flat row at 0.16. Text starts at 0, 11, 14 or 36 from the drawer's
edge depending on the page. The `Current` board draws all eight to their own
geometry so the zoo is visible rather than described.

The rule, on the `Main` board:

- The lit field is `wash(FRIEND)` across the full drawer span, at the row's
  full height, and the hit box is exactly the field. `wash()` is already the
  right drawing: a flat fill at 0.8a with a skirt adding 0.6a against the
  left rule, gone by 130 points.
- Two weights only. **0.18 is the cursor**, whether it arrived by pointer or
  by arrows; the kit page's focused/unfocused split collapses into it.
  **0.07 is the row you are already standing in**: the game you are flying,
  the hull you fly, the loaded build. It replaces the wedge, and the cursor
  outranks it on the same row.
- One text column: row content starts 36 from the drawer's left edge (the
  existing 14 margin plus the 22 gutter) and right-aligned data ends 36 from
  the right edge. Section labels and rules share the column.
- Ink steps 0.85 to 1.0 with the cursor; unpressable rows sit at 0.55 and
  never light; the standing row's label is set in FRIEND.
- The two shapes that are not rows, ship grid cells and rail stops, take the
  same two weights on their own hit shapes; the skirt belongs only to rows
  against the panel's left rule. The lit rail stop keeps its tab gradient,
  which answers where you are, not where the pointer is.

`Play`, `Settings`, `Ship` and `Elsewhere` redraw the shipped pages under the
rule. The kit page is the big migration (14 inset onto the 36 column, field
to the full span); settings is nearly the baseline already; friends and
builds drop their bands and overhangs.

`build.py` is the source, in the manner of `../play-menu/build.py`, whose
chrome it borrows: hues from `client/arena/palette.lua`, geometry from
`client/arena/ui.lua`. Rebuild with `python3 build.py`; the six `.dc.html`
files and `canvas.json` beside it are what the design canvas is seeded from.

The seeded canvas itself is git-ignored. It is the whole canvas editor with
these boards baked into it, some two and a half megabytes against the hundred
kilobytes of source that generates it, and the same argument that keeps
`client/dist/` out of the history keeps it out too. Seed a fresh one from
these files when it is wanted.
