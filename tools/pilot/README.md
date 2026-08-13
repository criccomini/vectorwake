# pilot

Flies real clients at an arena and reports what actually happened.

Not a connectivity check. Each pilot joins, takes the map and settings the zone
sends, flies with held inputs, and decodes every snapshot through the simulation
core itself. So what it verifies is that ships move, energy drains and
recharges, weapons appear, kills land, and that a locally predicted tick agrees
with the server's next snapshot.

    make
    python3 pilot.py wss://play.vectorwake.net/dir war 4 30   # directory zone pilots seconds
    python3 pilot.py --direct ws://127.0.0.1:9001 "" 2 20     # one arena, no browse
    python3 pilot.py --direct --adapt ws://127.0.0.1:9001 "" 3 15   # steer the clock

It browses first, like a client does. Which instance serves which zone is
decided by the instances themselves and differs between deploys, so an address
baked into a test joins whichever zone happens to be there and earns a wrong-zone
refusal -- the server being right and the test being wrong. That is how this
harness first learned that refusal works in production.

Needs `pip install websockets`.

## Reading the output

`predict_err(worst/mean px)` is the one to watch. A client that predicts
correctly agrees with the server almost exactly: on a local link with the clock
adapted, 0.04 px at worst and 0.00 px on average over 497 snapshots. Against
the live fleet the mean holds at 0.01 px and the worst case is a few pixels,
which is one jittery sample rather than drift. A settings or wire mismatch shows
up here as a growing divergence and nowhere else: a zone that raised a hull's
top speed without the settings traveling measured 11 px of peak error while
every other check on the connection stayed green.

Two bugs used to sit in that number and hide each other. It stepped the core one
tick and compared the result against the next snapshot, which is five ticks
later, so four ticks of ordinary flight were charged to the client as error. Then
it divided by 4096 and called the answer pixels, but positions are Q8 and 4096
units is a tile, so the inflated number was shrunk by sixteen on the way out.
What came out looked like sub-pixel agreement and was read that way. Anything
quoting a `predict_err` figure from before this was fixed is reading tiles of a
four-tick drift.

`reach(ship/round tiles)` is how far the furthest ship and the furthest round
any snapshot carried were from the pilot's own hull. The server chooses one
fixed fairness radius, and this checks that claim from the far end rather than
believing it. A number past the radius means the server handed a client
something it could not lawfully see. The client cannot ask for a wider view.

`corrections` counts samples thrown out because the ship died or respawned
between the prediction and the snapshot. Those measure a teleport rather than a
prediction, and the client's contract is to accept the server's correction, so
they are reported separately rather than folded into the error. They appear if
and only if a death did.

## What it has found

The signed overflow in the recharge clamp, fixed in `b1abbe5`: four pilots
against the live server reported an energy bar of -2147482013, which is
INT32_MIN plus a tick of recharge. Nothing else in the deployment noticed,
because the arena was serving, registered and verified throughout.
