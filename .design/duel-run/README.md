# The duel's run, without the rung

Six boards for the panel under the duel's roster: the list of fights a run is
made of. Chris's reading of the shipped one, off a screenshot of the ending:

> The duel scoreboard is weird. This rung/floor nomenclature is weird. Just
> track streaks and show previous pilot names and who won. Show the list up to
> some limit like last 5 or something.

Drawings of a proposal, not a plan of record. Nothing here is built.

## What the shipped panel does

Its head is `RUNG 6  FLOOR 6` and every row under it is a rung number, so the
five things on screen at the moment in the screenshot are four bookkeeping
numbers and a verdict. A floor is the checkpoint a loss cannot push you below,
named on screen and explained nowhere; a rung is a roster slot. Three more
faults, all visible on the `As shipped` board:

- The rung is said a third time in the line over the bar, "back to rung 6".
- The rival is nowhere in the run, even though a run is a list of fights
  against people. The roster above names whoever you just fought and forgets
  them at the next whistle.
- The middle column is `1-0` on every row, because a duel is first to one and
  catalog validation refuses any other value.

And the streak, the one number this rethink is about, is already in that head
under a rule that hides it at zero, so it is absent exactly on the screen a
player reads after losing.

## Three directions

All three drop the rung, the floor and the scoreline, name the rival, keep
won or lost in that word's own color, and show the last five with a count of
how much longer the evening was. They differ in what leads the panel.

- **A · the list leads.** A plain streak reading at the head, the run's best
  beside it, five named fights under it with how long each took. The smallest
  change that does what was asked. Cost: nothing says the rivals get harder.
- **B · the shape leads.** The head is the whole run drawn, one mark per
  fight, filled for a win and hollow for a loss, so the shape of an evening
  is one glance. Cost: the marks and the rows overlap, and it wants the whole
  twelve-leg window rather than five.
- **C · the number leads.** No head at all: the streak stands as a figure in
  a column beside the rows, and the rows drop to a mark, a name and the word.
  Shortest of the three by a whole head. Cost: how long a fight took is gone,
  and it puts a 0 in 60 point type on the screen you read after losing.

A leads, and the phone and mid-fight boards draw A. The names in every run are
the ones a real evening deals: the rival order is `pilots::CALIBRATED` sorted
by its ordering prior, so rung six really is Tessellate.

## What it costs to build

The leg the room files carries a rung, a result, a scoreline and a duration,
and no name (`modes::LadderLeg`), so the rival's call sign has to be captured
when the leg is filed: by the time the panel draws it the rival may have left.
That is one field on the leg, the name reaching the mode through `ModeCtx`,
and eleven bytes a leg on `S2C_MATCH` becoming eleven plus the name. Sending
five legs rather than twelve nearly pays for it. The scoreline drops off the
wire with the column, and a best streak is a max over the streak.

The word is not only in this panel. `END.result` says "rung 6 cleared" and
"back to rung 6" over the bar; the play page's format strip says
`scoring: rungs`; the zone's hook line is "every rung is a harder rival; a loss
drops you two"; and two `Ladder::banner` lines name a rung and a checkpoint.
The boards put the melee's own grammar over the bar instead, the rival's name
and a verb, and the annotations carry the rest.

## The question the boards do not answer

The floor is real whether or not it is named: a loss drops two rungs and stops
at the last checkpoint. Take the word off the screen and the kindness is still
there, unread. Either keep the mechanic and stop narrating it, which changes
nothing on the server, or make the streak the mechanic, which is what "just
track streaks" says most plainly and is a harsher game: the twelfth fight on
these boards would have sent that run back to Kestrel. The panel draws the
same either way, which is why it is a question rather than a fourth direction.

## What is here

`build.py` is the source, in the manner of `../podium-rethink/build.py`, whose
design system it borrows: hues from `client/arena/palette.lua`, panel, key and
ending geometry from `client/arena/ui.lua`, the two faces from `client/ui/`.
Desktop boards are drawn at the ending's own zoom, so every authored size is
its `ui.lua` number times 1.45, bar and countdown excepted the way `END.band`
and `END.foot` except them.

Rebuild with `python3 build.py`; the six `.dc.html` files and `canvas.json`
beside it are what a design canvas is seeded from. The seeded canvas itself is
git-ignored, for the reason `../menu-rows/README.md` gives.
