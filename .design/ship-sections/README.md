# The ship menu as five sections

Chris's ask: the ship menu should be a handful of rows, body, guns, bombs,
specials and flair, each one opening a submenu holding the config for that
part, with the build credits on display at the top, above body and below the
back bar, and still there in the submenus.

Shipped as [decision 112](../../docs/architecture/decisions.md). Nine boards,
drawn before the client was, and the client agrees with them.

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

**Body carries the stats, twice.** The hull's five bars stand under the row
that names it on the menu, and every hull in the body list carries its own,
so the roster can be read down a column. The five words are said once, at the
head of that list, over the columns they name.

**Nothing new in the language.** A section row opens, which is the caret every
stop on the landing already wears. The rows inside are decision 104's six ends
unchanged: the walker in body, steppers and switches in guns, bombs and
specials, the range cells in flair.

## Where the five came from

Four are the sections `menu.tune_rows` already builds, under Chris's words:
flight becomes body, gun becomes guns, bomb becomes bombs, rack becomes
specials. Which rows appear inside each is still the core's answer rather than
a list written in the client, so a zone that gives a hull no bomb rack opens a
bombs section with nothing in it rather than one nobody remembered to hide.

Body is the one section that is a choice rather than a set of slots, so it
is a list: seven hulls and sitting out, one to a row, each row carrying that
hull's five bars, and a press flies the one you are on. It was a walker,
because decision 100 called seven hulls with five bars apiece a page in a
list's clothes. That was true of a page that also held every slot the hull
could spend on. A section that holds nothing else is a list, and a list is
where the bars pay: seven read down a column compare, seven read one at a
time have to be remembered.

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

One pilot flies every one of them, on one build: an Apex on spray 1, gun
bounce 1, bomb shrapnel 1, repel 2 and burst 1. Three of those five come with
the hull and two were stepped on top of it, which is a distinction the purse
does not make: a profile is spent from the same seven a step is. Six of them,
one in hand, and the three counts on the menu add to the six.

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
