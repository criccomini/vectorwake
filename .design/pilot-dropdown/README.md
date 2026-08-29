# The account stop as a dropdown

Shipped as [decision 99](../../docs/architecture/decisions.md). The landing's
ACCOUNT stop used to be a door: a press opened the drawer on the pilot page,
where zone and ship opened lists in place. It opens the same kind of list now,
holding only the account acts and none of the career, and the pilot page, its
tab and the call sign's press are gone.

These boards were the proposal and have been brought back to what shipped.
Four of them, built by `build.py` and seeded with the design skill's helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out pilot-dropdown.html --title "Pilot Dropdown" \
      --artboard Main.dc.html --artboard Claimed.dc.html \
      --artboard Closed.dc.html --artboard Phone.dc.html \
      --canvas canvas.json

What the boards say:

- Acts on the account you are stand above a rule; ways of being somebody else
  stand below it. A guest reads SIGN UP with "keep your points" beside it and
  NEW NAME, then LOG IN under the rule. A claimed pilot reads SET PASSWORD and
  NEW NAME over the rule, LOG OFF under it.
- The stop wears a dot for a guest with something a lost account would cost
  them, which is the warning the drawer spells out in words on its band.
- Rows wear the menu's states from decision 72, and the panel is the nearly
  opaque ground `land_list` already draws, since two rows over a live fight
  have to be read rather than read through.
- The list opens upward from its own stop like the other two, so it covers the
  lockup, which stands down the way the shipped mark already does when a panel
  climbs into it.

Two things changed between the proposal and what shipped:

- The proposal drew CLAIM ACCOUNT and SIGN UP as two rows, an offer above the
  rule and a fresh start below it. They are one act: the server has one
  endpoint, `/v1/claim`, and what it does is put a password on the account
  this client was handed on its first run. There is no second act that makes a
  fresh account and signs it up, because a fresh account is what a guest
  already has. One row, in the player's word for it.
- The offer wears the caution color rather than a green. The green belonged to
  an invite band that went with friends (decision 95); the color the warning
  is written in everywhere else is the guest band's, and the dot on the stop
  is the same hue.

Still open: what a row press opens is drawn nowhere here. LOG IN and both
password acts raise the account cards, which stand over the landing with no
panel behind them.

The design system is lifted from `../start-flow/build.py`, which lifted it
from the real client. Two things had moved since that canvas: the stops grew
frost, so the fight blurs behind them here too, and ship building went (the
roster is one row a ship), so the ship stop holds a hull's name.
