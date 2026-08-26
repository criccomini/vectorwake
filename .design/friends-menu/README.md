# The friends page, rethought

Chris said the friends menu looks like garbage and asked for directions to
make it look awesome. What the page owes a player is
[friends.md](../../docs/design/friends.md)'s three things: add somebody, see
which friends are on, join them in one press. The shipped page answers all
three and looks like none of them: five sections in one row grammar, a
button or two on every row with unfriend drawn three times as loudly as the
one join, the fact the page exists for reduced to a six-point dot and a dim
word, and a ledger at the foot repeating names already listed above it.

Four directions beside the page as shipped, plus the empty state, which two
thirds of accounts meet before they meet anything else. The people are the
same eight on every board so the directions compare. Canvas artifact
3bb97182; boards are built by `build.py` and seeded with the design skill's
helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out friends-menu.html --title "Friends Menu" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard Manifest.dc.html --artboard CrewWall.dc.html \
      --artboard Channels.dc.html --artboard FirstFriend.dc.html \
      --canvas canvas.json

- **A, deck watch** (`Main`, and `FirstFriend` for the empty state): the
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
