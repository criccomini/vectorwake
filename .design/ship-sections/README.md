# The ship menu as five sections

Chris's ask: the ship menu should be a handful of rows, body, guns, bombs,
specials and flair, each one opening a submenu holding the config for that
part, with the build credits on display at the top, above body and below the
back bar, and still there in the submenus.

Not implemented. Nine boards, and one choice left open.

Artifact: [Ship Menu Sections](https://claude.ai/code/artifact/165ecbef-f9b9-4392-bcf9-27bf0938653a)

## What is there today

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

Five rows and a reset fit any window without scrolling, and the tray stops
being the third strip of the content and becomes part of the panel.

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

**A section reads what it holds, in credits, in the color a credit is spent
in.** The pilot on these boards has six of seven spent, split two into guns,
one into bombs and three into specials, and those are the six the tray has
hollowed out. Body and flair cost nothing, so they read what they are instead:
a hull's name, and a wake.

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
keeps the walker, the flight bars and the press that flies the hull. Nothing
in it costs a credit on the shipped roster: every hull's flight step is zero,
which is why the shipped panel has no flight rows either.

Flair is the pair the settings page is holding for the ship, the wake and
which key throws which charge. They went there because a panel a player opens
to spend credits was the wrong home for two things that cost nothing. A
section that costs nothing sits fine beside four that do, so on these boards
they come back here and settings loses them: one control, one home.

## The one open choice

What a section reads. The count is the same currency the tray above is
denominated in, so the two read as one instrument and a pilot hunting a credit
to free knows which row to open. The contents say something the tray cannot,
and cost that: with six credits over three sections, nothing on the page says
where the sixth went. Both are drawn, Main and AltReading.

Two small ones, drawn one way and worth saying: reset stays on the menu,
because what it puts back is all five sections at once, rather than one per
section; and the tray is drawn the same on body and flair, where nothing is
spendable, because it is a label and seven chips and never a control.

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
their own boards, Phone is the menu at 390, and AltReading is the open choice.

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
own rung first, then gun caps {spray 5, bounce 1, freeze 1} and bomb caps
{bounce 1, prox 1, shrapnel 3, freeze 1}, with prox, shrapnel and push off the
gun and spray off the bomb, and the rack at repel 3, burst 2. Shrapnel reads
fragments rather than rungs, so one rung reads 4. The fight behind the glass is `../dropdown-stack`'s.

## What it would cost the client

`menu.tune_rows` already returns the rows grouped and banded, so the sections
are a split of what it builds rather than new data: it would answer a section
at a time, and `M.ship_panel` would answer the five rows with a count apiece.
`land_panel` loses its scroll, its thumb and its cursor-follow, since no page
in the set is longer than the glass, and gains the tray as part of the frame
alongside the head. Panels already stack (decision 103), so a section is the
container that exists rather than a new one.
