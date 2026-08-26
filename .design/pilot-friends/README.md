# Pilot and friends, one page

Seven boards for moving the friends page inside the pilot page, the two
ways Chris named, with the account chrome reconsidered in both. Canvas
artifact f6bd35e5; boards are built by `build.py` and seeded with the
design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-and-friends.html --title "Pilot and Friends" \
      --artboard Main.dc.html --artboard CurrentPilot.dc.html \
      --artboard CurrentFriends.dc.html --artboard Option1.dc.html \
      --artboard Option1Friends.dc.html --artboard Option2Rows.dc.html \
      --artboard ClaimCard.dc.html --canvas canvas.json

The account today spends a whole page and a reading column on three rows,
so in both options it shrinks to a head band: the call sign large with the
reroll mark on it, what the name is under it, KEEP and LOG IN as keys
(PASSWORD and LOG OUT once claimed). The claim and login flows were always
cards over the page (`ClaimCard`), so no page is lost.

- **Option 1, drill-down** (`Option1` + `Option1Friends`): the ship page's
  grammar. A friends row on the pilot page slides the full list in from
  the right, back chevron and swipe right to return. Each surface does one
  job and the pilot page has room to grow, but join gains a press and the
  top page is one band and one row.
- **Option 2, one page** (`Main` + `Option2Rows`): the friends sections
  are the body of the pilot page, straight under the head. Two treatments
  of the account: the band head (leading) and a row section in the
  settings grammar. Everything is one rail tap away; the page does two
  jobs.

Both options empty the friends tab: the rail goes back to four stops, the
friends badge moves onto the pilot stop, and pilot has to ride the match
row, with the account keys standing down there.
