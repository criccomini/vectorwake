# The friends page, rethought

Chris said the friends menu looks like garbage and asked for directions to
make it look awesome. What the page owes a player is
[friends.md](../../docs/design/friends.md)'s three things: add somebody, see
which friends are on, join them in one press. The shipped page answers all
three and looks like none of them: five sections in one row grammar, a
button or two on every row with unfriend drawn three times as loudly as the
one join, the fact the page exists for reduced to a six-point dot and a dim
word, and a ledger at the foot repeating names already listed above it.

Round one put four directions beside the page as shipped, and Chris's answer
was a simpler line than any of them, now on `Main` and the canvas's first
page: the add box keeps its shipped style under an ADD FRIEND label, the in
this game and sent sections are gone along with the friends count and the
ledger row, incoming adds sit under RECEIVED, and friends are one head with
a solid green dot and their zone when they are in a game, a hollow grey dot
and nothing else when they are off. The row press still raises the card, so
join and unfriend live there for every input. Two rules came with the pick
and are recorded in [interface.md](../../docs/design/interface.md): a zone's
name is spelled the way the catalog spells it (Team Battle, never team
battle), and no line is set all lower case.

An open question for the build: with the ledger gone, an ignored add has no
page it can be accepted from later, so either ignore becomes final or the
ledger returns somewhere quieter. The mock leaves that to the
implementation round.

The round-one boards stay on the canvas's second page. The people are the
same eight on every board so the directions compare. Canvas artifact
3bb97182; boards are built by `build.py` and seeded with the design skill's
helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out friends-menu.html --title "Friends Menu" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard DeckWatch.dc.html --artboard Manifest.dc.html \
      --artboard CrewWall.dc.html --artboard Channels.dc.html \
      --artboard FirstFriend.dc.html --canvas canvas.json

- **A, deck watch** (`DeckWatch`, and `FirstFriend` for the empty state): the
  page reorders around now. A friend in a game gets the play page's
  live-row grammar, name large with the game, clock and ground as stacks,
  and the whole row is the join. Off friends are a plain roll with no
  keys, an add waiting on you is a hail band answered in place, the field
  folds behind the ADD key, and the ledger is one drill-in row at the
  foot. Costs a press each to reach the field and the ledger.
- **B, the manifest** (`Manifest`): one aligned roster, every person one
  line: a mark carries the state, the WHERE column carries the game, at
  most one key rides a line. Scales to the hundred-edge cap on one
  screen; costs a legend nobody has been taught, and the ago words.
- **C, the crew wall** (`CrewWall`): a plaque per friend with the helmet
  mark, lit when flying with the join on the plaque. Looks like the game
  rather than a table; thin at two friends, crowded at forty.
- **D, by game** (`Channels`): each zone holding a friend is a band with
  its clock and its names and the join on the band. Strongest when
  somebody is on; with nobody on, most opens, it is rolls under no band.

The rejected fold of friends into the pilot page is in
`.design/pilot-friends`; friends stays a tab of its own. The card that a
row press raises for five-input devices is unchanged in every direction
here, which is what lets A, C and D take the buttons off the quiet rows.
