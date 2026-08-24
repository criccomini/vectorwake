# Podium redesign

Three artboards for the match ending. The podium was one card capped at 620pt,
sized so a phone could hold it, and a desktop was shown that same small card
floating in scrim. These boards are the ending that owns whatever window it is
given, carrying less than the card did: watch replay and the banked readout are
gone, leaving the result, the score, both rosters, comms, the next-match clock,
and one share key.

This landed. `podium()` in `client/arena/ui.lua` draws what these boards draw,
and `client/tests/podium_test.lua` holds the geometry to it. The boards stay as
the drawing the layout was settled against.

## The proposal

- One measure spans the window, capped near 1040pt, and type scales with it.
- The result, the score band and both rosters stand at the head with no
  header over them: a scoreline needs no label. Under them come two
  sections, SAY for the comms and NEXT MATCH for the clock beside a drain
  bar in the score bar's own language, with the share key under it. Each of
  those headers sits over a rule, padded equally off the head and the
  content.
- Sharing has no section of its own. A header over a single key names the
  key twice, so the key sits inside NEXT MATCH, wearing the tray-and-arrow
  mark every phone puts on the control that sends a thing somewhere else.
- Wide windows set the rosters abreast; upright phones stack them at full
  width rather than halving the measure between them. A phone held sideways
  keeps the rosters in two columns, since a roster is a column wherever it
  is drawn, and spans the measure with SAY and NEXT MATCH like every other
  board, a size or two down to earn the room back.

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
