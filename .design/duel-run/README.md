# The duel's run, without the rung

Boards for the panel under the duel's roster: the list of fights a run is made
of. Chris's reading of the shipped one, off a screenshot of the ending:

> The duel scoreboard is weird. This rung/floor nomenclature is weird. Just
> track streaks and show previous pilot names and who won. Show the list up to
> some limit like last 5 or something.

Drawings of a proposal, not a plan of record. Nothing here is built.

## What the shipped panel does

Its head is `RUNG 6  FLOOR 6` and every row under it is a rung number, so at
the moment in the screenshot the panel is four bookkeeping numbers and a
verdict. A floor is the checkpoint a loss cannot push you below, named on
screen and explained nowhere; a rung is a roster slot. Three more faults, all
on the `As shipped` board:

- The rung is said a third time in the line over the bar, "back to rung 6".
- The rival is nowhere in the run, even though a run is a list of fights
  against people. The roster above names whoever you just fought and forgets
  them at the next whistle.
- The middle column is `1-0` or `0-1` on every row, because a duel is first
  to one and catalog validation refuses any other value, so all it ever says
  is that somebody died.

The MVP mark goes with them, at Chris's call. In a first-to-one duel the
winner is the only pilot with a kill, so the best gun in the room is always
whoever just won and the mark is the bar above it said again. The rule that
keeps it honest in a bigger room: no mark unless three or more pilots scored.

## Settled

The board is three sections down one column, with the countdown and the invite
key under them.

**The pilots** are unchanged.

**The fights** lose their head entirely: no rung, no floor, no scoreline, no
count. Each row names the rival, says won or lost in that word's own color,
and keeps how long the fight took. Five rows. The name is set in the menu face
because it is a name being read; the word and the clock beside it are mono
because they are data, which is the rule in `docs/design/interface.md` and one
the shipped panel breaks by putting the rival's slot number where the rival's
name should be.

**The readings** are label over value with a thin rule between the stacks, the
grammar the play page sets a zone's format in and the band sets TIME and
PLAYERS in. They sit under the fights. Above them they sat where the roster's
column headings sit, heading columns they had nothing to do with; below, they
land where a total lands and nothing can read them as headings. The fights
count is one of them now, so the list needs no footnote either.

`BEST` is a number the run does not keep yet: the wire carries a best rung, and
a best streak is a max over the streak. It is also my addition rather than
Chris's, and the easiest of the three to drop.

One question the ask leaves open, and the two boards that answer it: `Main`
gives the readings their own section, wearing the same wash and left rule the
two above them wear; `Joined` puts them inside the fights panel under a ticked
rule, the way a table carries its own totals.

## The boards

Every board is one evening at two moments a fight apart: eleven fights in the
run is three deep and climbing, and the twelfth is the screenshot, where
Tessellate takes the life and the three ends. `Broken` is the settled shape at
that second moment, which is worth drawing because the shipped head does not
survive it: the streak hides at zero, so the one number this is about goes
missing exactly on the screen you read after losing. The names are the ones a
real evening deals, since the rival order is `pilots::CALIBRATED` sorted by its
ordering prior.

The mid-fight board is the fight between the two moments, at the 340 point
measure the board takes when it is asked for rather than raised at the whistle.
The phone draws the same three sections anchored to the foot.

The second page keeps what was passed over, drawn as proposed: the readings
above the list, the streak lighting the panel's own left rule over the rows it
counted, and the first round's two answers to what should lead the panel at
all.

## What it costs to build

The leg the room files carries a rung, a result, a scoreline and a duration,
and no name (`modes::LadderLeg`), so the rival's call sign has to be captured
when the leg is filed: by the time the panel draws it the rival may have left.
That is one field on the leg, the name reaching the mode through `ModeCtx`,
and eleven bytes a leg on `S2C_MATCH` becoming eleven plus the name. Sending
five legs rather than twelve nearly pays for it. The scoreline drops off the
wire with the column. The streak is already there; a best streak would be a
max over it.

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
these boards would have sent that run back to Kestrel. The board draws the
same either way.

## What is here

`build.py` is the source, in the manner of `../podium-rethink/build.py`, whose
design system it borrows: hues from `client/arena/palette.lua`, panel, key and
ending geometry from `client/arena/ui.lua`, the two faces from `client/ui/`.
Desktop boards are drawn at the ending's own zoom, so every authored size is
its `ui.lua` number times 1.45, bar and countdown excepted the way `END.band`
and `END.foot` except them.

Rebuild with `python3 build.py`; the `.dc.html` files and `canvas.json` beside
it are what a design canvas is seeded from. The seeded canvas itself is
git-ignored, for the reason `../menu-rows/README.md` gives.
