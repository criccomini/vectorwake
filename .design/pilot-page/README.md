# The pilot page, rethought

Six boards for the account page alone; friends stays a tab of its own.
Chris's reading of the shipped page: "keep this pilot" is weird, so is the
info box at the bottom, and the whole menu needs a rethink. Canvas artifact
1ef83153; boards are built by `build.py` and seeded with the design skill's
helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-page.html --title "Pilot Page" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard DirectionA.dc.html --artboard BClaimed.dc.html \
      --artboard DirectionC.dc.html --artboard CClaimed.dc.html \
      --canvas canvas.json

What every direction fixes:

- "Keep this pilot" becomes "Set a password": the act rather than the
  consequence, and it pairs with "change password" once claimed.
- The info box goes. It said the call sign a third time, the password
  sentence a second time, and a paragraph of lore over 170 points of
  nothing. One status line under the name and one note under the password
  key carry what it knew; the rest was already written in the claim card.
- The reroll moves behind a NEW NAME key. Today a press on your own call
  sign rerolls it on the spot, which is a landmine on the row a curious
  player presses first.

The directions:

- **A, plain words** (`DirectionA`): the same list, honest labels, the box
  deleted. Shippable in an afternoon; the page stays a nearly empty room.
- **B, the pilot card** (`Main` + `BClaimed`, leading): identity leads and
  the career sits under it: duel rating, tier, record, games, rivets. All
  of it already exists per pilot at /pilots and rivets is on the client;
  showing it is one meta call. A guest's record standing above SET
  PASSWORD is the best claim pitch on the page.
- **C, the form is the page** (`DirectionC` + `CClaimed`): a guest's page
  is the claim form inline, log in below it. The emptiness becomes the
  form's room, but a form pointed at every guest reads as a demand, and
  the house rule is that a password is offered.
