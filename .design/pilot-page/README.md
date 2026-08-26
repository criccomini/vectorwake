# The pilot page, rethought

Five boards for the account page alone; friends stays a tab of its own.
Canvas artifact 1ef83153; boards are built by `build.py` and seeded with
the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-page.html --title "Pilot Page" \
      --artboard Main.dc.html --artboard Current.dc.html \
      --artboard Claimed.dc.html --artboard PlayBanner.dc.html \
      --artboard SignUpCard.dc.html --canvas canvas.json

The settled page, per Chris across three rounds:

- The guest page is the name with a NEW NAME key, the career, and a
  full-width SIGN UP foot key over "Keep your points and log in on other
  devices", with "already have a pilot? log in" under it. No status line
  under the name; the banner and the foot key say what state the account
  is in.
- The career wears the ship page's section grammar (a rule edge to edge,
  the label under it) and shows bare totals: duel rating and tier, record,
  games, rivets. No season and no week. Rating, tier, record and games are
  one meta call; rivets is already on the client.
- A guest with something to lose gets a gold banner in the drawer on every
  tab but pilot: "You are using a guest account. Press here to set your
  password." Pressing it opens the pilot page; a gold dot rides the pilot
  rail stop regardless.
- Signed in, the foot key goes; the page carries change password and log
  out, with one small "signed in" line under the name.
- Sign up keeps the transition: the card says "keep your points and log in
  on other devices" over one password field. "Claim" vocabulary is gone
  everywhere. The reroll lives behind NEW NAME; a press on the name no
  longer rolls it.

Open before build: whether the banner also stands over the arena HUD or
only in the drawer, and whether sign up asks for the password once or
twice.
