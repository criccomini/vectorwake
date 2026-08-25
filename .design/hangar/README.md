# The hangar: ship and upgrades, rethought

Chris asked for a rethink of the ship and upgrade menus: the ship page is
busy, a bit buggy, and hard to learn, and the upgrades tab feels like it
belongs inside it. His test is worth quoting, because it is the whole brief
in one sentence: if I cannot turn something on, I should be able to buy it,
or at least see how much it costs, in the ship menu.

Five boards. One shows the two pages as they ship, at the drawer's own 390
point measure, and three directions follow, each mocked against the same
account so they compare line for line. Nothing here has landed; these are
drawings of a proposal.

## What the two pages are today

The ship page holds five different activities in one column: choosing a
build, managing builds (new, rename, delete), spending the thirty points,
assigning the charge keys, and dressing the ship. It speaks three control
grammars to do it: stats and levels are ladders, add-ons are chips, spray is
a count. And it teaches nothing. The sentences that explain what proximity
or freeze actually buy in a fight live on the upgrades tab, and the reading
pane that showed them beside the shelf died with the drawer (decision 63),
so the one place the game explains an add-on is the shelf's drill-in card.

A slot the account owns none of is simply absent from the ship page. That
was a deliberate rule, "this page is what you fly," and it is the exact
thing the brief runs into: the page cannot say there is more of this and
here is its price.

The two pages were one panel once, with the price of each rung written on
the row that spends it, and they were split because that put a wallet and a
budget on one screen with the word spend meaning both
([match-game.md](../../docs/design/match-game.md)). The split fixed that
confusion and created this one. Any merge has to answer the old objection,
not just undo the split.

One more fact reframes the whole question. The shelf is much smaller than
its page suggests. Stats are never sold: every account owns all eight steps
of all five from the first flight. The gun's ladder and most add-on rungs
are dealt whole too. What melee actually sells a new account is eight
purchases: one bomb rung, three spray rungs, two shrapnel rungs, and a
third repel and burst. Two full stops for eight prices, on two pages that
draw the same twenty-three slots in the same order.

On the bugginess: it is structural more than incidental. Three row grammars
each carry their own hit and cursor logic, the chips reflow and walk their
own widths even when scrolled out of sight, the profile list, the pane keys
and the kit rows share one cursor index space, and the page's two-column
layout is retrofitted into a one-column drawer through a `stacked` branch.
Whichever direction wins, converging on one row grammar deletes most of
that surface.

## The cleanup every direction bakes in

All three boards share one pass over the ship page, argued once here:

- **One row grammar.** Everything is a ladder. The chips become rows with
  pips like everything else; a one-rung add-on is a one-pip ladder. One
  control to learn, one code path to hit.
- **The library folds into a selector.** One row at the head, arrows either
  side of the build's name, the edited mark beside it. Pressing it opens
  the builds list, which is where new, rename and delete live. The head
  stops carrying two keys and a four-row list stops paying rent on every
  visit.
- **A teach band, pinned over the stops.** Whatever row the cursor is on
  prints its one-sentence lesson there. The reading pane reborn at drawer
  width, on the page where the deciding happens.
- **Levels move into their trigger's group.** Gun level sits with spray and
  bounce, bomb level with shrapnel and proximity, so a group is the whole
  story of one trigger.

## One hangar (the leading direction: Main, BuyCard)

The tabs merge and the drawer drops to five stops. Every slot the arena has
is on the ship page, and a ladder draws three kinds of step: a filled pip is
a point slotted, a hollow pip is a step owned and not slotted, and a dim
square is a rung the arena has that the account does not. Where a next rung
is for sale, it wears the gold diamond and the row ends in the price behind
the rivet mark. Pressing into the dim region opens a buy card in the
drawer: the lesson, the ladder at reading size, the price, the wallet, and
BUY.

The answer to the old wallet-and-budget objection is separation by shape
and place rather than by page. Kit points are pips in the slot's own color
and their figure lives in the band; prices always wear the rivet mark and
gold; and the wallet never sits on the page at all, only on the card, the
way the refusal card already works. Spend on the page always means points.
Buying is a card, slotting is a press.

The tradeoff: gold is on the page while you fit, and the page is the
game's longest. The teach band carries some of that weight, and the shelf
being eight prices keeps the gold sparse in practice.

## Fit and buy (Lenses)

One geography, two lenses. The same page under a FIT | BUY toggle in the
band: FIT is the kit page with the cleanup and no prices anywhere, dim
rungs saying only that more exists; BUY relights the same rows in the
shelf's terms, dealt bar, owned pips, the next rung priced, with the wallet
in the band where the budget was. The upgrades stop dies here too.

This keeps the argument that split the pages fully intact: the two
questions stay two moments, and the band never shows two figures at once.
What you learn once is where a slot lives, and the answer to why a row
stops is one press away on the same row rather than another stop.

The tradeoff: the price is a toggle away, not on the refusal itself, which
is half a step short of the brief; and a mode is a state a player has to
notice they are in, even with the band recolored.

## Two stops, linked (Linked)

The smallest change. Both stops stay and the ship page stops hiding the
shelf: rungs past what the account owns are drawn dim, and a row with
something for sale ends in the bare rivet mark. Pressing into the dim
region jumps to the upgrades stop with that slot's card open, price, lesson
and BUY; buying lands the rung on the ship page at once, and the way back
is one press.

This is the least code and honors the split completely. The tradeoffs are
the ones the brief started from: the jump is a context switch in the middle
of building, the price itself still is not visible where the refusal
happens, and the drawer keeps six stops with two of them drawing mostly the
same list.

## A recommendation

One hangar. The brief asks for the price at the point of refusal, and only
the merge puts it there. The shelf's real size settles the rest: eight
prices do not need a stop of their own, and the stop they occupy costs a
duplicate drawing of the whole slot space plus the tab row's widest layout.
The old confusion has a concrete answer now that it did not have when the
pages were split, because the split's own shelf work built it: the dealt
bar, the rivet mark, the gold diamond and the refusal card are a vocabulary
for commerce that did not exist in the first merge, and the card is where
the wallet lives. Fit and buy is the fallback if the gold on the fitting
page proves noisy in practice; it shares almost all of its drawing with
one hangar, so trying the leading direction risks little.

## What is here

`build.py` is the source. It writes the five `.dc.html` artboards from the
same design system the earlier mocks lift from the client: hues from
`client/arena/palette.lua`, panel grammar from `client/arena/ui.lua`, the
lockup from `docs/banner.svg`. The account shown is real to the melee
shelf as `sim/src/sim.c` deals it and `server/src/meta/upgrades.rs` prices
it: base entitlements plus one bought spray rung, 130 rivets in the wallet.

## Rebuilding

```sh
python3 build.py
```

That rewrites the artboards. To rebuild the canvas they are published in,
re-seed it with the `design` skill's helper and publish the result to the
same URL. The seeded file is git-ignored: it is editor payload, and nothing
in it is authored here.
