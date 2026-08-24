# Podium redesign

Three artboards for the match ending. The shipped podium in
`client/arena/ui.lua` is one card capped at 620pt, sized so a phone can hold
it, and a desktop shows that same small card floating in scrim. These boards
propose an ending that owns whatever window it is given, with the same content
the card carries today: the result, the score, both rosters, comms, share and
replay, what the match banked, and the next-match clock.

They are drawings of a proposal, not a plan of record.

## The proposal

- One measure spans the window, capped near 1040pt, and type scales with it.
- The page is sectioned in the play page's aside grammar: SCORE holds the
  band and both rosters, SAY the comms, SHARE the two keys, each header hung
  off its own vrule. Wide windows set the rosters abreast; upright phones
  stack them at full width rather than halving the measure between them.
- The foot runs the next-match clock on the left, over a drain bar in the
  score bar's own language, and the banked rivets on the right, in the
  wallet's yellow.
- A phone held sideways keeps both rosters up, moves the countdown, the
  payout and the actions to a right rail, and leaves comms one row under
  the thumbs.

## What is here

`build.py` is the source. It writes the three `.dc.html` artboards from the
same design system the rethink mocks lift from the client: hues from
`client/arena/palette.lua`, the panel grammar from `client/arena/ui.lua`, and
the two faces the client carries. The match shown is a real one, taken from a
screenshot of the shipped card so the two layouts compare line for line.

## Rebuilding

```sh
python3 build.py
```

That rewrites the artboards. To rebuild the canvas they are published in,
re-seed it with the `design` skill's helper and publish the result to the same
URL. The seeded file is git-ignored: it is editor payload, and nothing in it
is authored here.
