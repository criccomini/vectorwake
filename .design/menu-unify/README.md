# One menu, three windows

Nine boards for a menu that is designed once and stood in three places. The
column is the same drawing on every board: the name and the call sign at its
head, the page in the middle, DEPLOY and the six stops at its foot, all at the
phone's own measure of 390 points. What the directions disagree about is where
that column stands, and that is the question the boards ask:

- **Dock** stands it on the left edge at full height. A phone held upright
  gives it the whole window, which is the shipped narrow layout; everywhere
  else the fight keeps the rest of the glass.
- **Card** floats it in the middle, clamped to 390 by 560, with the glass
  dimmed a step around it. The most modal of the three.
- **Console** keeps the six stops and PLAY NOW on a bar that never leaves the
  glass, and a tab raises a sheet rather than a screen. Nothing to open first.

Every board shows the play page open over a live melee, because the stands are
the front end now (decision 61) and changing a ship or a zone should not mean
leaving them.

**Dock was chosen and is built.** See
[decision 63](../../docs/architecture/decisions.md). Card loses the fight it is
drawn over, which is the one thing docking exists to keep. Console is the
stronger answer in the stands and the wrong one over a match, where a permanent
strip of chrome forks the same behavior into two; it stays open as a later step,
since that bar is the dock's own foot row promoted onto the glass.

Two things the boards drew that the built column does not. The DEPLOY key is
there only from the stands, because a key offering to join the fight you are
already in means nothing. And the "watching" card is the room's real roster,
which is what the menu already had beside a list on a wide window and now draws
under the rows.

`build.py` is the source, in the manner of `../spectator-landing/build.py`,
whose design system it borrows: hues from `client/arena/palette.lua`, panel
geometry from `client/arena/ui.lua`, hull outlines to the extents in
`docs/design/ships.md`, the lockup verbatim from `docs/banner.svg`, and the
zones with their own sentences from `catalog/zones/*/zone.toml`.

Rebuild with `python3 build.py`; the nine `.dc.html` files and `canvas.json`
beside it are what a design canvas is seeded from.
