# The hangar: ship and upgrades, rethought

Chris asked for a rethink of the ship and upgrade menus: the ship page is
busy, a bit buggy, and hard to learn, and the upgrades tab feels like it
belongs inside it. His test is the whole brief in one sentence: if I cannot
turn something on, I should be able to buy it, or at least see how much it
costs, in the ship menu.

Three directions were mocked against the pages as shipped, and **one hangar
won**: the tabs merge, the drawer drops to five stops, and every slot the
arena has lives on the ship page. The canvas's first page is that direction
as revised with Chris; the second page keeps the first pass, the shipped
pages beside the two directions that lost, as the record of how it was
chosen. Nothing here has landed; these are drawings of a proposal.

## The diagnosis, kept short

The shipped ship page holds five activities in one column, in three control
grammars (ladders, chips, a count), and teaches nothing: the sentences
explaining what an add-on buys in a fight live on the upgrades tab, whose
reading pane died with the drawer (decision 63). A slot the account owns
none of is simply absent, which is the exact thing the brief runs into.

The pages were one panel once and were split because that put a wallet and
a budget on one screen with the word spend meaning both
([match-game.md](../../docs/design/match-game.md)). The split fixed that
confusion and created this one, so the merge has to answer the old
objection, not just undo the split.

And the shelf is much smaller than its page suggests. Stats are never
sold: every account owns all eight steps of all five from the first
flight, and most rungs are dealt whole. What melee sells a new account is
eight purchases: one bomb rung, three spray rungs, two shrapnel rungs, and
a third repel and burst. Two full stops for eight prices.

The bugginess is structural: three row grammars each with their own hit
and cursor logic, chips that reflow offscreen, the profile list and pane
keys and kit rows sharing one cursor index space, a two-column layout
retrofitted into a one-column drawer. One row grammar deletes most of it.

## The hangar, as revised

**A wash, never a curtain.** The drawer keeps the client's semi-opaque
ground on every board, so the room behind it reads through: a ship
crossing under the panel is faintly there, which is the shipped rule that
nothing hides the fight you are still in.

**No head.** The ship screen spends nothing on the logo and the account:
its top row is the drawer's x, the build's name, and the points meter, and
the ladders start directly under it. The screens that slide in open with
their back row at the same height.

**Circles all the way down.** One mark with three states: a solid circle
is a point equipped, a ring in the slot's color is a step owned and not
equipped, a dim grey ring is a rung the arena has that the account does
not. No chips, no squares, no diamonds. A row with something for sale ends
in its price behind the rivet mark, in the shop's gold; that is the only
commerce on the page.

**The reading slides in.** There is no info band. Pressing a row's word,
or anywhere in its dim region, slides the page off to the left and brings
the reading in from the right: the kind, the name, the lesson, the ladder
at reading size, and, only where a next rung is for sale, the price, the
wallet, and BUY. An owned slot gets the same panel with the commerce
absent. The chevron or a swipe right puts the page back. Pips the account
owns still answer a press directly: tapping one sets the slot to that
step, so building never costs a navigation.

The wallet appearing only on the reading is what answers the objection
that split the pages: spend on the main page always means points, and gold
is always a price wearing the rivet mark.

**Builds live behind the name.** The name is a button, the one stroked box
this interface presses, with the edited tag beside it when the kit has
drifted. Its press slides in the builds list, which holds two keys and
nothing else: NEW slides on to a naming screen, a field and CREATE, and
DELETE takes the build the list stands on, dim on the three starters.
Picking a row loads it and slides back. Saving is not in the list: SAVE is
a key at the foot of the ship screen, standing over the stops only while
the kit differs from its name.

**Two shapes, one drawing.** The main boards are the portrait phone, 390
by 844, where the drawer is the whole screen: the merged page fits it with
no scroll on melee's slot set, save key included. Two more boards show the
phone on its side, 844 by 390, where the drawer keeps its 390 and the
fight keeps the rest, radar and all; height is the scarce edge there, so
that is the one shape where the page scrolls, the save key drops a size,
and the reading tightens its margins to fit whole. A desktop is the
landscape layout with more room.

**Points are a meter and a remainder.** The top row's other end shows a
thin bar and the number that matters mid-edit: how many points are left.
The word kit is gone. Pressing the meter slides in a points page that says
what the thirty are and teaches the circle grammar, so the one gesture the
page has, press a thing to read about it, also covers the budget.

## The first pass, on the record page

As shipped, beside the two directions that lost. Fit and buy put the same
rows under a FIT | BUY toggle and kept the two questions in two moments;
it lost because the price sat a toggle away from the refusal. Two stops,
linked kept both tabs and jumped from the ship page to the shelf's card;
it lost because the jump is a context switch mid-build and the stops keep
drawing mostly the same list.

## What is here

`build.py` is the source. It writes the eleven `.dc.html` artboards from
the same design system the earlier mocks lift from the client: hues from
`client/arena/palette.lua`, panel grammar from `client/arena/ui.lua`, the
lockup from `docs/banner.svg`. The account shown is real to the melee
shelf as `sim/src/sim.c` deals it and `server/src/meta/upgrades.rs` prices
it: base entitlements plus one bought spray rung, 130 rivets in the
wallet, and one point held back from speed so the meter has something to
say.

## Rebuilding

```sh
python3 build.py
```

That rewrites the artboards. To rebuild the canvas they are published in,
re-seed it with the `design` skill's helper and publish the result to the
same URL. The seeded file is git-ignored: it is editor payload, and nothing
in it is authored here.
