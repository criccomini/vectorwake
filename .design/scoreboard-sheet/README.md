# The players sheet

Rounds two and three of [one board](../one-board/README.md). Chris picked the
sheet, the menu's own panel, and asked for four things: name it for what it
is, have the column say which side you are on, make it hold in every zone,
and look at other shapes and places for the band it hangs off. Then, on the
second look, flatten it: one list with a Team column rather than sections,
join a side from a player's card, drop the side line the column made
redundant, put your own side first, and call it Players. Twenty three
boards. Drawings of a proposal, not a plan of record. Nothing here is
built.

## What the sheet is

- **A stop in the column.** `PLAYERS` sits between `ZONE` and `SHIP`, and
  its answer is where you stand: your side, `Pylon`, or `Watching`. The
  band's press and the board key open the same panel. That is a fifth stop, which decision 143 named as the number to watch on a short
  window's rail; the phone board carries the cost.
- **One list.** The head names the panel and reads the clock. Under it,
  every player: the name in the side's color, the seat's mark, the side's
  name in the Team column, then kills, deaths and assists. Your own side
  comes first and then everyone else, each run alphabetical by name; a
  watcher has no side and reads one alphabetical list. The band above
  carries the score, and the Team column names every side, so the sheet
  says neither again. Your own row keeps its wash. Watchers close the list
  under a band. Nothing in the menu language is new here: rows, a head, a
  band, a stacked panel.
- **A press on a pilot opens their card**, by enter, click or tap. The card
  is a panel that stacked, with the pilot as its head, rows reading their
  side, ship, rating and this match, and one breathing key at the foot:
  `JOIN CAISSON`, gated as a hull change is. On a full side the key stands
  down and the foot says `Caisson is full`. On your own side's pilot, and on
  yourself, there is no key. That is how an invitation was sent from the
  info box in `docs/design/teams.md`, and joining is the same shape.
- **At the whistle** it rises on its own with the result as its head, the
  share bar under it, a rating column, and the MVP mark on the winner's best.
  The band keeps the clock.

What round two had instead, and why it went: a section per side that was
itself the press that joined it, a new thing for the menu language. Flat
with a Team column needs no new row shape, and the card was always going to
exist. What the flat list costs is a side with nobody on it, which has no
row to press: in Free Roam, founding a side needs a door of its own.

## By zone

- **Team Battle** counts kills. Drawn on a monitor, both phones, and between
  rounds.
- **Turf** counts turf, and the band carries each side's stands as pennants
  in its color, the ones nobody holds dim.
- **War** counts rounds and shows the four flags the same way.
- **The duel** counts rounds. Its two pilots are the two rows, with no Team
  column, and a `Rounds` band under them lists who took each and how long it
  ran, the round in play reading its clock.
- **Free Roam** has no clock and no score. Thirty one pilots in one list,
  your pact first, where the Team column does what eight colors cannot,
  scrolling under the pinned head.

## The name

`Players`, which Chris settled after `Teams` and `Scoreboard` were each
drawn. The stop's answer is your side in every zone; in a duel a side is
named by its pilot, so the answer there is your own call sign, and in Free
Roam it is the pact you are in.

## The band

Three shapes, each drawn for every zone on one sheet and then in a Turf room
on a monitor and a War room on a phone:

- **Middle**, the shipped band: the clock one key tall at top center, a side
  either side of it as a name over a number, pennants under. Keeps the first
  glance.
- **Thin**: one line at 16 points in the same place, the clock smaller, names
  and scores at one weight, pennants inline. Spends less of the top edge and
  makes the clock small.
- **Corner**: a stack in the top left, the clock then a line per side with
  its pennants. Clears the top edge for the fight and sits where the room's
  chips come and go. Drawn once with the sheet up, since the sheet no longer
  hangs under the thing that opens it.

Free Roam is the same open question in all three: with no clock and no
score, the band is the room's count and nothing else.

## What is here

`build.py` is the source, in the manner of `../one-board/build.py`, whose
chrome it carries forward: hues from `client/arena/palette.lua`, the band,
key, stop and row measures from `client/arena/ui.lua`, the seat marks and the
pennant, and the two faces the client carries.

Rebuild with `python3 build.py`; the twenty three `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
