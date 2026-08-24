# Podium redesign

Three artboards for the match ending. The shipped podium in
`client/arena/ui.lua` is one card capped at 620pt, sized so a phone can hold
it, and a desktop shows that same small card floating in scrim. These boards
propose an ending that owns whatever window it is given, with the same content
the card carries today: the result, the score, both rosters, comms, share and
replay, what the match banked, and the next-match clock.

They are drawings of a proposal, not a plan of record.

## The proposal

- One measure spans the window, capped near 1200pt, and type scales with it.
- Wide windows stand the payout, the countdown and the actions in a spine
  between the two rosters. Narrow windows fold the spine back into the stack
  and the foot, which is the order the shipped card already keeps.
- Upright phones stack the sides at full width rather than halving the
  measure between them.
- A phone held sideways keeps both rosters up, moves the spine to a right
  rail, and leaves comms one row under the thumbs.
- The next-match clock wears a drain bar in the score bar's own language.

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
