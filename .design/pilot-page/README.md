# The pilot page, rethought

Seven boards for the account page alone; friends stays a tab of its own.
Canvas artifact 1ef83153; boards are built by `build.py` and seeded with
the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-page.html --title "Pilot Page" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard FootKey.dc.html --artboard Claimed.dc.html \
      --artboard PlayBanner.dc.html --artboard PlayQuiet.dc.html \
      --artboard SignUpCard.dc.html --canvas canvas.json

The settled proposal, after Chris's read of the first round ("keep this
pilot" is weird, so is the info box, what is a season):

- Words are sign up / log in, guest / signed in. The mechanics stay the
  transition: sign up attaches a password to the account the guest already
  is, and the card says what it keeps. No claim vocabulary anywhere.
- The info box is gone; one status line under the name and one note by the
  sign-up act carry what it knew.
- The career is totals and wears no time label: there is no season, and
  the week belongs to the site ladder. Rating, tier, record and games are
  one meta call; rivets is already on the client.
- The reroll lives behind a NEW NAME key; a press on the name no longer
  rolls it.
- A guest with something to lose (an upgrade bought, a friend made, a
  rating banked) gets a banner in the drawer on every tab but pilot,
  pressing through to the page, plus a gold dot on the pilot stop.

Two shapes drawn two ways each: the sign-up act as keys in the head
(`Main`, leading) or a foot key (`FootKey`), and the banner as a band
(`PlayBanner`, leading) or one line (`PlayQuiet`). `Claimed` is the same
page signed in; `SignUpCard` is the card with the new words.
