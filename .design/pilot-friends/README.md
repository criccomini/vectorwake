# Pilot and friends, one page

Six boards for folding the friends page into the pilot page and shrinking
the account chrome, which today spends a whole page and a reading column on
three rows. Canvas artifact f6bd35e5; boards are built by `build.py` and
seeded with the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-and-friends.html --title "Pilot and Friends" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard DirectionA.dc.html --artboard DirectionB.dc.html \
      --artboard BFriends.dc.html --artboard CCard.dc.html \
      --canvas canvas.json

Three directions, each a grammar the menu already speaks:

- **A, one page sectioned** (`DirectionA`): the settings grammar. A pilot
  section of one row with two keys, then the friends sections inline.
- **B, drill-down** (`DirectionB` + `BFriends`): the slot-reading grammar.
  The pilot page stays an account page and a friends row slides the full
  list in from the right. Honest cost drawn honestly: the top page stays
  mostly empty, and join gains a press.
- **C, band head** (`Main` + `CCard`): the ship-page grammar, and the
  leading candidate. The account is a 64 point band over the page (name,
  status, two small keys; name press rerolls) and the body is the friends
  page from the add field down. `CCard` shows the claim card over it,
  unchanged, which is the argument that login and claim never needed a
  page.

Every direction takes the rail back to four stops (play, ship, pilot,
settings), moves the friends badge onto the pilot stop, and means pilot has
to ride the match row, with the account controls standing down there.
