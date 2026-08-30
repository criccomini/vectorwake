# The ship menu as five sections

Chris's ask: the ship menu should be a handful of rows, body, guns, bombs,
specials and flair, each one opening a submenu holding the config for that
part, with the build credits on display at the top, above body and below the
back bar, and still there in the submenus.

Shipped as [decision 112](../../docs/architecture/decisions.md), with body
corrected to a carousel by [decision
113](../../docs/architecture/decisions.md), to the ship's own drawing by
[decision 114](../../docs/architecture/decisions.md), and to turning as the
whole of choosing by [decision
118](../../docs/architecture/decisions.md). Nine boards, drawn before the
client was, and kept in step with it.

Artifact: [Ship Menu Sections](https://claude.ai/code/artifact/165ecbef-f9b9-4392-bcf9-27bf0938653a)

## What was there

One panel with everything on it. The hull is walked on the top row, five
flight bars read under it, the credit tray sits under those, and then every
slot the hull can spend on runs down the rest of the glass under three band
labels: gun, bomb, rack.

On an Apex that is eleven rows to spend on under three band labels, with the
walker, the bars, the tray and a reset around them: 762 points of panel. An
810-point window has 782 to give it, so it fits by twenty and a shorter
browser window scrolls; a 390 by 844 phone has 735 once its safe areas are
out, and scrolls by twenty-seven. What goes off the top first is the tray, so
a pilot stepping a slot near the foot is spending a purse they cannot see.
`land_panel` has a scroll, a thumb and a cursor-follow to make that bearable,
all of which exist because the page is longer than the glass.

Five rows and a reset fit a window a scroll of that could not, and the tray
stops being the third strip of the content and becomes part of the panel.

## The rules the boards follow

**The tray is chrome.** The panel draws it, under the back bar, above
everything the page is about, and it is the same seven diamonds on the menu
and on all five sections. That is what "stays visible in the submenus" turns
into once a submenu is a panel of its own rather than a scroll position: there
is no scroll position left that could take it away.

It does not hold still, and the Stack board is where that shows. A panel is as
tall as what it holds and stands on the bottom margin it slid out of, so a
section of four rows sits lower than a menu of six and its tray rides down
with its own head. What is fixed is the tray's place in a panel, not its place
on the screen.

**A section reads what it holds, in the games list's voice.** `menu_row`
draws a detail at TYPE.BODY in `pal.MUTE`, hard against the right of the type
column, in the face the numbers in flight are set in: that is what "4v4 3:00"
wears on the zone stop, and it is what "2 rounds, bouncing" wears here. It is
quieter than the name it answers and can never be mistaken for a control.

**The stats belong to body.** The section turns one ship at a time with its
five rows read out one to a line underneath it. They stood on the menu too for
four decisions, under the row that names the hull; the row already answers
with the hull's name, and a page of five plain rows does not want an
instrument wedged under the first (decision 116). The bars take a floor, so
the hull at the bottom of a row draws a stub rather than nothing.

**Almost nothing new in the language.** A section row opens, which is the
caret every stop on the landing already wears, and the rows inside are
decision 104's six ends unchanged: steppers and switches in guns, bombs and
specials, the range cells in flair. Body is the one thing here that is not a
row. It is a drawing with the walker's two arrows either side of it, level
with the ship rather than with a line of type, and a reading block under it.

**And the two arrows are the whole control.** A pilot is flying whatever they
turn to, so there is nothing under the drawing to press and no mark on it to
say which of seven it is: one is ever shown, and it is theirs. That is why the
boards draw the ship in the pilot's own color with no wash behind it. See
decision 118.

## Where the five came from

Four are the sections `menu.tune_rows` already builds, under Chris's words:
flight becomes body, gun becomes guns, bomb becomes bombs, rack becomes
specials. Which rows appear inside each is still the core's answer rather than
a list written in the client, so a zone that gives a hull no bomb rack opens a
bombs section with nothing in it rather than one nobody remembered to hide.

Body is the one section that is a choice rather than a set of slots, and it
took three shapes to settle. It was a walker with no drawing on it, then a
list of seven with five bars apiece, and it is a carousel: one hull drawn the
way the arena draws one, turning about the axis up the screen, an arrow either
side of it, the name and the hull's own line under it, the five rows beneath.
What the list bought was reading two hulls against each other; what it cost
was seeing either of them, and what a hull looks like is most of what a pilot
is choosing between. See decisions 113 and 114.

It kept the list's press for a while after it stopped being a list, which is
how a control outlives the shape that needed one. A list is walked and then
answered; a carousel has already narrowed to the ship on the glass, so the
turn was the answer and the press was the same question asked twice.

Nothing in body costs a credit on the shipped roster: every hull's flight step
is zero, which is why the shipped panel has no flight rows either.

Flair is the pair the settings page is holding for the ship, the wake and
which key throws which charge. They went there because a panel a player opens
to spend credits was the wrong home for two things that cost nothing. A
section that costs nothing sits fine beside four that do, so on these boards
they come back here and settings loses them: one control, one home.

## The choice that was open

What a section reads. Chris took the contents, and AltReading is the record of
the other one: a section reading the credits standing in it, which is the same
currency the tray above is denominated in. That version reads as one
instrument with the tray and tells a pilot hunting a credit to free which row
to open without opening any. What it cannot do is say anything about the ship,
and the pilot is here about a gun.

Two small ones, drawn one way and worth saying: reset stays on the menu,
because what it puts back is all five sections at once, rather than one per
section; and the tray is drawn the same on body and flair, where nothing is
spendable, because it is a label and seven chips and never a control.

The level row is called Level. It was Rung, which is the client's word rather
than the core's: `SIM_SLOT_LEVEL` and `SLOT_NOTES` both say level. A ladder
can go on being a ladder in prose without the row a pilot presses saying so.

## The boards

Nine, built by `build.py` and seeded with the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out ship-menu-sections.html --title "Ship Menu Sections" \
      --artboard Main.dc.html --artboard Stack.dc.html \
      --artboard Body.dc.html --artboard Guns.dc.html \
      --artboard Bombs.dc.html --artboard Specials.dc.html \
      --artboard Flair.dc.html --artboard Phone.dc.html \
      --artboard AltReading.dc.html --canvas canvas.json

Main is the menu. Stack is a section coming up over it. The five sections are
their own boards, Phone is the menu at 390, and AltReading is the reading that
was not taken.

One pilot flies every one of them, on the build everybody starts in: the
second rung of both weapons, a gun that comes off walls, a fuse on the bomb
and one of each charge. Six credits of the seven, one in hand. Since decision
117 the build is the pilot's rather than the hull's, so that is the same menu
on every body, and a hull that cannot reach a slot is charged nothing for it.

Every number is lifted from the client rather than invented:
`client/arena/palette.lua` for hues, `ui.lua` for the type ladder
{12, 14, 17, 21}, LIT {0.18, 0.07}, the 44-point row, `PANEL_MAX` 560, the
14-point inset and margin, the 34x18 switch, and the 30-point tray with its
nine-point diamonds. The rows in each section are what `sim_slot_cap` answers
off the shipped baseline, in the order `tune_rows` builds them: the trigger's
own level first, then gun caps {spray 5, bounce 1, freeze 1} and bomb caps
{bounce 1, prox 1, shrapnel 3, freeze 1}, with prox, shrapnel and push off the
gun and spray off the bomb, and the rack at repel 3, burst 2. Shrapnel reads
fragments rather than levels, so one level reads 4. The bars are the `flight`
table off `sim/src/baseline.c`, shared against the roster's own range the way
`flight_bars` does it, so Apex is three quarters of the way up speed and a
seventh of the way up energy. The fight behind the glass is
`../dropdown-stack`'s.

## What it cost the client

Close to what these boards guessed. `menu.tune_rows` became `M.sect_rows`,
which answers one section at a time off the same slot descriptors, and
`M.ship_panel` takes the open section rather than a page of the roster. Body
is `M.landing_ships` with `flight_bars` on every row, both of which the client
already had and one of which it had stopped drawing when the roster became a
pager. The tray moved into `panel_frame`, beside the head.

Two guesses were wrong. The scroll does not go: a landscape phone has 362
points of room and the roster wants 460, so a section still scrolls where the
window is short. What the sections actually fixed is that the tray is chrome
now and cannot scroll away, which is what was asked for and is the better half
of the claim these boards made.

The other was in the client rather than in these boards. `menu_row` had two
colors for a reading, `pal.READ` on a row wearing a caret and `pal.MUTE` on
one that only reads, and nothing had ever worn a caret and carried a reading,
so the two had never been on a screen together. The boards were drawn in the
mute off the games list, which is the one that was right; the caret's own
color was the one that had to move.

The pager, the walker, the band and the old panel's second head are all out of
`ui.lua` with the page that held them.
