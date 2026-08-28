# Mobile pad mocks

Seven boards for a rethink of the touch controls, from Chris's reading of
them on a phone in a duel: the pads look boxy and pixelated, the gun's fan
is smashed until it stops reading as multifire, the charges are silly gold
squares, the stick is a bare wireframe circle, and nobody discovers that a
double tap toggles reverse.

One board reproduces what ships, to `touch.lua`'s geometry. Three
directions answer it, each drawn resting and with the stick held in the
reversed stance:

- **A · Instrument** the pads become cockpit gauges: arc rims, radial
  glow, the volley at full size, a rim tab for the fan, hexagonal charge
  cells, and a rose for the stick with a tappable stance tab at its foot
- **B · Cluster** one big key for the gun and an even orbit of
  satellites at charge size for bomb, repel and burst, named by their
  marks alone; a charge key bounded by nothing but its own count ring;
  no multifire toggle on a phone, the gun's mark simply drawing the
  volley the trigger will throw; the double tap gesture etched around
  the stick, always naming what the next tap does, REVERSE at rest and
  FORWARD while reversed; a trigger's ring as its recovery, dropping
  dim at the shot and growing back to full as the weapon's delay runs;
  a states board shows a charge key at three, two and one in hand and
  spent, since a spent key stays on screen dimmed rather than
  vanishing, beside a trigger fired, recovering and ready
- **C · Glass** no chrome at all: the controls are the glowing marks
  themselves, the volley is the multifire state, the stick a faint
  reticle with a ghost hint that fades once learned

Two proposals hold across all three: multifire gets a drawn state of its
own rather than a compressed loadout mark, and reverse gets a visible
control a thumb can also tap, so the gesture becomes the shortcut rather
than the secret.

`build.py` is the source, in the manner of `../start-flow/build.py`: hues
from `client/arena/palette.lua`, the shipped geometry from
`client/arena/touch.lua`, the round, bomb, repel and burst drawings from
`client/arena/marks.lua`, hull outlines to the extents in
`docs/design/ships.md`.

Rebuild with `python3 build.py`; the seven `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.

Drawings of a proposal, not a plan of record.
