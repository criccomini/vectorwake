# The account stop as a dropdown

Today the landing's ACCOUNT stop is a door: a press opens the drawer on the
pilot page (arena.script's land_act says so in as many words). Zone and ship
open lists in place. These boards draw account opening in place too, as the
same upward panel the other two stops get, holding only the account acts and
none of the career: claim account, sign up and log in for a guest; set
password and log off once the account is claimed.

Four boards, built by `build.py` and seeded with the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-dropdown.html --title "Pilot Dropdown" \
      --artboard Main.dc.html --artboard Claimed.dc.html \
      --artboard Closed.dc.html --artboard Phone.dc.html \
      --canvas canvas.json

What the boards say:

- Acts on the account you are stand above a rule; ways of being somebody
  else stand below it. The guest's list leads with CLAIM ACCOUNT in the
  offer green the invite band uses (decision 80), with KEEP YOUR POINTS as
  its note, then NEW NAME, the reroll the pilot page keeps behind a key of
  that name; under the rule, SIGN UP with START FRESH beside it, and LOG IN.
- The claimed pilot's list is SET PASSWORD and NEW NAME over the rule, and
  LOG OFF under it.
- Rows wear the menu's states from decision 72, and the panel is the nearly
  opaque ground land_list already draws, since two rows over a live fight
  have to be read rather than read through.
- The list opens upward from its own stop like the other two, so it covers
  the lockup, which stands down the way the shipped mark already does when
  a panel climbs into it.

Open before anything is built:

- For a guest, SIGN UP and CLAIM ACCOUNT are nearly one act in the account
  model: claiming is setting a password on the account the client was
  already handed, and the shipped pilot page calls that act SIGN UP. If
  they collapse, one row survives and the rule goes.
- What a row press opens is not drawn. LOG IN and both password acts need
  fields, either in the drawer's existing cards or inline over the glass.
- Whether the pilot page keeps its foot keys once the dropdown carries the
  same acts, or slims to the career alone.

The design system is lifted from `../start-flow/build.py`, which lifted it
from the real client. Two things have moved since that canvas: the stops
grew frost, so the fight blurs behind them here too, and ship building went
(the roster is one row a ship), so the ship stop holds a hull's name.
