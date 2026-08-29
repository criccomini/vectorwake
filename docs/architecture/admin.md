# The admin surface

## The hazard

"See and control the fleet" pulls straight back toward the central authority that
[zones-and-arenas.md](zones-and-arenas.md) exists to avoid. Commands need
somewhere to land, landing places accumulate state, and a stateful thing in the
middle of a running fleet becomes a thing that has to be up.

Splitting the surface into seeing and controlling keeps that from happening, and
splitting *controlling* again, into edits and actions, is what makes the
authority question answerable.

## Seeing costs nothing

A directory already holds what an operator wants to look at: every registered
arena server, the zone it serves, its verified player count, its region, when it
was last observed, and whether it passed verification. The admin UI is therefore
another client of the browse protocol with an authenticated superset of the same
reply.

Built, and the authenticated half landed somewhere this section did not
predict. A directory holds registrations and no accounts, so it cannot tell an
operator from anybody else; the meta-layer holds accounts and no
registrations. So the panel asks the process that can authorise, and that
process asks the process that knows: `/v1/admin/fleet` checks the flag and
relays `O2D_FLEET` to the directory over loopback. The directory answers that
tag only for a request no proxy touched, which is a real distinction on these
hosts and not the loopback test it looks like, because every service runs on
the host network and Caddy proxies from 127.0.0.1 too. What separates them is
the `X-Forwarded-For` Caddy always writes.

Because each directory relays only its own observations, an admin unioning
across all of a deployment's directories sees a more complete picture than any
single directory holds. That is the same union an arena server performs to choose
a zone, run for a different reason.

Build it as a static HTML page rather than inside the Defold client. It wants
tables, forms, and text entry; our client draws vector art and text on purpose,
and [decision 20](decisions.md) deliberately removed the last DOM text input
from it. A static page needs no new server, opens from disk or any host, and
points at directory addresses the way the game client does. A directory may
serve it as a convenience, but nothing depends on that.

## Control, part one: edits

Bans, a zone's map or settings, fill targets, adding a zone, retiring one, pool
tokens and their instance caps. These are not commands, they are edits, and the
architecture already has a distribution path for edits: a versioned catalog
deployed to every directory, which arenas take by highest version.

So the write surface of the admin UI is *producing a new catalog version*. It is
a configuration authoring tool that happens to have a live view attached.

That does create one central place, and the distinction worth holding onto is
that it is central for authorship rather than for runtime. If the authoring side
is down, every directory keeps serving the catalog version it has and every arena
keeps serving the zone it chose. Nothing stops. An assignment scheduler going
down stops joins; a config author going down stops config changes, which is the
correct blast radius for the feature.

Backing the catalog with git gives version history, diffs, and an audit trail for
no work, and makes "who changed War's bomb damage on Tuesday" a question with an
answer.

## Control, part two: actions

Kicking a player, draining an arena server, pinning one to a zone, unpinning it,
restarting it. These have to reach one specific process now.

Send them down the registration socket that already exists, scoped so a
directory may only command arenas registered with it. The arena already trusts
its directories for the catalog, the socket survives NAT and dynamic addressing,
and no arena has to expose an admin listener of its own. The alternative, an
admin credential on every arena plus a second listener each, adds attack surface
to the process that holds the simulation.

Two directories can still send conflicting pins. Rather than designing that
away, make a pin sticky local state on the arena with last-write-wins, and
surface it: `pinned to Chaos by chris at 14:02 via directory B`. A conflict then
reads as visible operator error, which is what it is, instead of a systemic flaw
that needs a protocol.

Actions get no audit trail from the catalog, so log each at both ends, the
directory that sent it and the arena that ran it, and show the log in the UI.

### What each one does, as built

All five are implemented on the arena in `ArenaServer::run_command`, and the
panel sends four of them.

**kick** takes a call sign, not a seat, and sweeps every room in the process,
because an operator naming a player does not know which room holds them. The
panel extends that across instances: the directory fans a kick out to every
arena it holds a registration for, and the ones that do not have that pilot
answer `nobody here called ...`, which is a refusal worth reading rather than
noise to suppress. It is a disconnect and not a ban. They may rejoin at once,
so it is for breaking up a situation; the durable answer is a ban, which lives
with identity in the meta-layer.

**drain** stops new joins and sends every bot home, publishing `bots_wanted` of
zero so the bot server stops refilling it. Humans already flying stay flying.
This is what empties a box before it is retired, and since nothing in the
selection path drains any more, per
[zones-and-arenas.md](zones-and-arenas.md), it is the only thing that drains at
all.

**pin** holds an instance on one named zone and switches policy off for it:
`decide_loop` skips a pinned instance entirely. It refuses a zone the catalog
does not carry. Pinning a populated instance drains it first and switches when
it empties, answering `pinned; draining before the switch`. **unpin** returns
it to policy.

**restart** exits, and lets the container platform bring the process back. That
is the whole implementation and the honest one, for the reason at the bottom of
this document: an admin surface that spawned processes would need credentials
on the hosting layer. The panel does not draw a button for it. The route
accepts it, because a considered `curl` is a different thing from a stray
click.

A command is fire and forget with an answer that arrives later: the directory
records what it sent, the arena acks with an outcome, and the directory records
that beside it. So the panel shows the audit log rather than a result, and both
halves of a command appear there a moment apart.

## Capabilities

This is what finally calls `has_capability`. It sat in `config.rs` for months
with tests, a `[[staff]]` block in `zone.toml`, and nothing invoking it, because
there was no command channel to gate. The live copy is `catalog.rs`'s, checked by
`admin.rs` against the catalog's staff table; the `zone.toml` half is gone.

Keep ASSS's model, which [the research notes](../research/asss-server.md) argue
for at length: named powers rather than ranks. `ban`, `setmode`, `reload`,
`kick`, `drain`, `pin`, `catalog`. Each maps to a button the UI shows or hides
and to a check on the message the directory will accept. The staff table moves
into the catalog alongside bans, for the same reason: an operator who can ban in
Chaos but not in War is a support ticket waiting to happen.

One correction for whoever wires it up: the table keys on call signs, and it
cannot keep doing so. Call signs are server-dealt from a word list no operator's
name is in, and `/v1/rename` moves one off its holder in a click. When named
powers arrive they hang off account numbers, or off the account flag below,
which has neither problem.

## Metrics

[server.md](server.md) names five numbers as the ones that say whether the
architecture is holding: tick duration, bandwidth per player, snapshot size,
input queue depth, and lag actions taken. They belong in the `STATUS` push an
arena already sends, which gets them to the admin UI through a path that exists
rather than through a metrics stack we would then have to run.

Per-arena rather than per-fleet, because a single arena at 9 ms of tick time is
the interesting case and an average across forty of them hides it.

## The panel that exists

A first surface, a page and two endpoints behind basic auth at `/admin`, was
removed the same day as weight: the browse reply already showed every
registered instance to anyone who asked, and a fleet this size had nothing
left for a page to say. What earned the surface back was accounts. Once the
meta-layer existed, "this account may operate the fleet" became a fact it
could hold and check, and the ban stopped being a curl with a token in it.

So the panel is `deploy/admin/`: static files Caddy serves at
`admin.<domain>` on the central host, with `/v1` proxied to the meta-layer so
the page and its API share an origin and nothing needs CORS. Static for the
reason the top of this document gives: it wants tables, forms and text entry,
which the game client refuses to draw on purpose.

Six main views rather than one scroll: **Fleet**, **Pilots**, **Activity**,
**Errors**, **Debug** and **Access**. Everything used to sit on a single page in the order it was built,
so finding a ban meant scrolling past the fleet, the feed, a pilot card and a
command log, and the page grew a section every time the panel did.

They are routed on the hash rather than served as six documents. Six
documents would each re-check the flag, re-fetch everything and repeat the CSP
for navigation inside one session, and since the panel is a directory of static
files, a path per view would need a rewrite rule in Caddy to survive a reload.
A hash is still somewhere you can bookmark and still what the back button
walks, and costs none of that.

It opens on the fleet, because "is anything wrong right now" is the question
somebody opens a dashboard for. Four tiles carry the numbers that get read from
across a desk, and under them every registered instance with its zone, region,
occupancy, rooms and tick time, and a state that reads `ok` or names the one
thing worth knowing: unverified, silent, a tick near budget, a queue that is
not draining, lag actions taken, a drain announced, capped. The catalog
version, the build and the key check sit in the line above the table, and the
command log sits below it, because the fleet is where commands are sent from
and a verb with its answer a moment later is one thing read in one place.

Pilots holds the filter and the table. Activity is the same log across the
whole fleet, filtered by facets you tick rather than by two dropdowns: the
questions asked of it are usually "these three kinds" or "both populations",
which a dropdown can only answer by growing a combination per pair. None ticked
under **what** means every kind, and none ticked under **who** means nothing at
all, which reads backwards until you notice that nobody expresses "no filter"
by ticking twelve boxes and everybody expresses it by leaving them alone.
Errors holds browser failures grouped by build, stack, and reported account.
The summary says how many groups were active in the last hour and day, while an
expanded row gives the bounded stack and user agent. The account number links
to the pilot page, so a report and the pilot's recent activity are one click
apart. Debug holds sampled local corrections above half a pixel, with filters
for the account, build, zone, wire and time window. Each row keeps the two
positions and velocities, local presentation debt, clock adjustment and repel
state. They stay individual because that sequence is the evidence; grouping
them would keep a count and lose the motion. Access is bans and admins together,
since both answer one question about who may do what and they used to sit at
opposite ends of a long page.

A separate route, `#pilot/<account>`, is one pilot: their card, the controls that
act on them, and their history. It is reached by link rather than from the
rail, because there is no such thing as the pilot page until you have picked
one. It used to be a card at the bottom of the list, under whichever page of
the table you happened to be on, so picking somebody scrolled you past
twenty-five rows and the address bar said nothing about who you were reading
about. Being a page is what lets every call sign anywhere on the panel point at
it, and they all do now: the pilot table, the activity feed, a pilot's own
history, the ban list and the admin list were four different things, two of
them buttons that opened a card and two of them plain text that did nothing.

The pilot table, both event tables, and error table page twenty-five rows at a time. The
pilot table's footer counts, because the accounts it reads are bounded by how
many people have ever played and an index scan over that is cheap. The event
tables do not: `pilot_events` takes most of 300,000 rows a day, so counting a
history to draw a footer is work that grows forever, and they ask for
twenty-six rows instead and report whether the extra one arrived. The footer
reads the same either way. Where a page starts comes from the reply rather than
from a constant on the page, since the server clamps what it was asked for and
a client deriving the answer from its own number lies the moment the two
disagree.

The controls disappear entirely against a meta-layer too old to page, which is
every deploy for about a minute. Such a server ignores `limit` and `offset` and
answers with the whole list, so `next` would move a number nothing acts on and
the footer would count rows off the end of a list that was never sliced. That
is what "pilots 1 to 72" becoming "pilots 26 to 98" over an unchanged table of
seventy-two was. The page tells the two apart by whether `offset` came back at
all, the same way it decides whether a pilot is unrated or the server simply
never said.

Two columns link out, and both lead to the thing you want next after reading
the row. An instance name goes to the provider's console page for the machine
it runs on, which is the click after deciding a host rather than a process is
the problem. The link exists only when the host knows its own provider id:
`provision.sh` reads it from the metadata service every cloud offers on
169.254.169.254, writes it to `.env` as `VW_HOST_ID`, and the arena carries it
on its registration. A laptop and any provider that spells the field
differently get plain text, which costs a link and nothing else.

A build goes to the repository at that commit, which is the question a drifted
row raises: what is this process actually running. CI stamps the short sha and
GitHub resolves a short one the same as a full one, so nothing is padded on the
way. `unknown` is what a binary built outside CI reports and it links nowhere,
because there is nothing on the other end of it. The drift note stays outside
the link, since it is the panel's reading of the row rather than part of the
sha.

Above the pilot table is Recent, the same log read across the whole fleet
rather than one pilot at a time. People and bots are separate views rather than
one feed, because a room runs fifty-one bots against a handful of players and
mixing them is a page of bot arrivals with everything worth reading pushed off
the end of it. A call sign in it opens that pilot's card below, so noticing
something and going to look at it is one click.

Its note line reports when the log last took a row of each kind, whether or not
the current filter matched anything. An empty table otherwise has two meanings
that look identical and want opposite responses: nothing matches what you
asked, which is a filter to widen, or nothing is arriving, which is a fleet to
go and look at.

The pilot table filters as you type, over call signs and account numbers, and
there is no button beside the box: the keystrokes are the whole interaction,
and a button that repeats them invites somebody to wonder what it does
differently. Picking a row opens that pilot's card, and under the card is what
the fleet saw them do.

Each row carries a standing in three readings, because they answer questions
that are not the same one. **rank** is the position on the ladder, **rating**
is the number the matchmaker reads, and **tier** is the band, which is the only
one of the three a player is ever shown per
[rating.md](../design/rating.md). Two things follow from how rating works and
are worth knowing before reading the column. A pilot holds one rating per mode
class, so the row shows the class they have played most and names it when it is
not the default one; the rank is their position on that ladder rather than on
some merged board. And a pilot still inside their provisional games has a
rating but no position, since ranking an unsettled number would push everybody
else down for it, so the cell reads `placing 4/10` and the rank is empty. Bots
hold accounts and are rated like anybody else, which is the point of them, so
the top of a ladder can be one and that is the system working rather than a
bug.

A pilot gets a row in `ratings` when a rated event first credits them and not
when the account is made, so a fleet where nobody has died yet has a full
accounts table and an empty ladder. Every tier cell then says `unrated`, which
is the state saying so rather than three blank columns that read as a broken
panel. Blank is reserved for the one case where the page genuinely does not
know: a meta-layer too old to send these fields at all. It tells the two apart
by whether the reply carried `provisional`, since claiming somebody is unrated
on the strength of a field the server never sent would be a confident lie about
their standing.

That heading is up whether or not anybody is picked, the way Log and Bans are,
and says to pick a pilot when nothing is. It lived inside the block it labels
for one afternoon, which meant the section did not exist until you had already
found it: an operator reading down the page saw Fleet, Pilot, Log, Bans,
Admins, and nothing to suggest the log was there at all.

That last part is the half of acting on a report the panel could not do. An
operator with a complaint in front of them had the reporter's word and a kick,
and no way to check one against anything. Now the card carries the pilot's
recent history out of the log
[meta-layer.md](meta-layer.md#the-pilot-log) describes: arrivals, refusals
with the sentence the pilot was actually sent, hull and side changes,
departures with the reason and whether the fight was being lost. Refusals and
quits are drawn in the color the rest of the page gives to something wrong,
because those are the two an operator is scanning for.

Each row names the stay it belongs to, and opening one narrows the table to
that stay alone. A pilot's history runs across several and a report is usually
about one of them.

It is written out rather than shown as the JSON it arrives as. An operator
reading a complaint should not have to know the wire to use the page, so a
departure reads `left, held 2m 0s, settled as a quit` and a hull change reads
`hull 0 to 3`. An event kind the page has not learned falls through to its raw
detail rather than to nothing, because the arena can ship a new one before
these files do.

Nothing in it edits. The log is a record of what happened, and an operator who
could revise it would be holding a different kind of thing.

Two deployment-wide faults show there and nowhere else. Two directories on
different catalog versions is a publish that half landed, which the fleet
resolves correctly and silently by taking the highest. And a verifying key in
the catalog that is not the public half of the meta-layer's signing key means
every session token fails its check: pilots keep flying, as guests, rating
nothing, with nothing on fire to say so.

The maps page is beside it, and is the first thing in the panel that changes
what the fleet serves rather than what it says about a pilot.

## Maps, and what a zone plays

The page has two halves because the job does: you draw a room, then you say
where it is played. A canvas one square per tile with the tile classes as a
palette, and below it one card per zone naming what it plays, in order, at one
match each.

**What is drawn goes in the database, not the repository.** The catalog on
disk stays the reviewed baseline: it is what a fresh deployment boots with,
what the tests run against, and what serves when nothing has been published. A
map made at a click is operational data, the same kind of thing as a ban or an
admin flag, and it goes where those went. The alternative considered and
rejected was the panel committing to git and CI rebuilding the image, which is
a multi-minute wait per tweak, push credentials on an internet-facing box, and
binary blobs accreting in a repository that has evicted 5 MB of them once
already.

**A publish reaches the fleet through the machinery a catalog edit already
used.** Every publish takes the next serial, and a directory serves the
catalog's own version plus that serial. An arena takes the highest version it
is offered, so a rotation lands the way a new catalog does, and a running room
takes it without dropping anybody: the match in progress finishes on the
ground it started on, because swapping the map under a live fight is a desync
everybody sees. Rolling one back is another publish rather than a smaller
number.

The push goes over the same loopback socket the panel commands the fleet
through, and it is the only direction there is: a directory holds no
credential the meta-layer would accept, so it cannot ask. The meta-layer
therefore insists once a minute as well, since a directory that restarts comes
back serving the maps on disk and nothing else would ever tell it otherwise.

**The browser packs the file and does not judge it.** Whether a map is worth
serving is a question with one right answer, and it is the core's:
`sim_map_check` asks whether the map names a start, whether any start strands a
three-tile hull, and whether its hull-sized regions connect. Mapforge adds the
match recipe's four starts per side, routes, and geometry. The page asks while
somebody is still drawing, so "a start is walled in" arrives when they wall it
in.

What the browser does have to get exactly right is the file. The far end
unpacks it with the same function an arena does and refuses anything whose
bytes disagree with the hash in its own header, which is the design rather
than an inconvenience: a browser cannot be trusted to agree with the
simulation, so it is never asked to. `deploy/admin/tests/pack_test.js` reads
the shipped maps and writes them back byte for byte to prove the codec has not
drifted.

## What an operator may edit about a pilot

Most of an account is deliberately not editable, and the panel is easier to
reason about once that is said plainly rather than discovered a field at a
time.

**The call sign can be typed or dealt.** An operator may set one directly or
take a fresh draw from the pool, and the account number does not move either
way, so the rating and the history ride through it. The typed half is the one
place in this service where a name is chosen rather than generated;
[accounts.md](../design/accounts.md) says what that spends and what it does
not, and the short version is that uniqueness survives because the unique
index was always the arbiter. A typed name is cleaned the way an arena cleans
any name it is handed, printable ASCII and 24 at the outside, and a collision
comes back as a refusal naming the name. A bot is refused outright, because a
house bot's name is how its roster individual is found and renaming one would
leave the scoreboard disagreeing with the roster that seeded its rating.

**Standing is a ban and its reason**, which the panel already sets, and which
takes effect within one token lifetime because this is where tokens are
minted.

A wallet and a table of upgrades stood here, and both are gone with the shop
they belonged to. The wallet was the one number on this page an operator could
set, for refunding a lost purchase or handing out a prize; upgrades were
granted and revoked a rung at a time in a table under the card. Nothing is
bought in this game any more, and a hull is a whole ship, so there is nothing
for either control to move.

Two rules from them are worth keeping for whatever comes next. A number an
operator types gets a confirmation naming both ends and the difference, because
the mistake worth guarding against is a digit and a digit is invisible in one
number and obvious in three. A stepper does not, because a step cannot be typed
wrong. And anything an operator changes lands in the pilot log as its own kind
of event, kept apart from the same change made by a player, so a log cannot
hide an operator's decision inside somebody's play.

Three things stay uneditable on purpose. A rating is maintained by transactional
event settlement, so setting one by hand would leave the number disagreeing
with the fights that moved it; the way to move a rating is to change what
happened or how it is scored. A password is the pilot's, and an
admin who can set one can take an account, which is a larger power than
anything else on this page and buys nothing a ban does not. And an account's
kind is load-bearing in two directions at once: only a house bot may anchor
the ladder, and only an accountable owner may hold a third-party bot, so
kind moves when a bot is registered rather than when an operator decides.

## Still ahead

The verbs need one more thing before kicking is comfortable: `RoomView`
carries counts and not names, so an operator cannot see who is in a room.
Kick works by call sign against every instance, which is enough to act on a
report and not enough to notice one.

The pilot log closed the smaller half of that. Acting on a report is
checkable now, since the card says what the fleet saw, and the Recent section
above it is the fleet-wide read that arrived a day later because an operator
wanted one. What still does not exist is anything that watches on somebody's
behalf: an operator looks, or the log says nothing. No alert, no threshold, no
score. [networking.md](networking.md) rules out the version of this that
watches how people fly, and that is untouched.

The name is its own certificate, which this file's opening comment prices as
the thing a mistake can burn. Taken anyway, and as isolation rather than
risk: the certificate volume outlives reinstalls now, and if the panel's name
ever hits the issuance limit it strands the panel while the game plays on.
The page also sends a strict CSP, `default-src 'self'` with nothing inline,
so the free text it renders (a ban reason is operator-typed) cannot become
script on the one origin where a script holds an operator's credential.

## Authentication

TLS from the start, for the same reason registration requires it: an admin
credential over cleartext is an admin credential given away.

Entry is a flag on the operator's own account. `accounts.admin` is written by
no route at all: granting and revoking are SQL run by the operator on the
central host, per the runbook in `deploy/README.md`, so the authority over
who operates the fleet is the database credential and nothing reachable over
HTTP. Signing in to the panel is `/v1/login` with the operator's call sign
and password, the same credential the game uses, and the device secret it
answers with is what the panel holds.

One rule makes that safe, and every route the panel grows has to keep it: the
`admin` field a session reply carries is decoration for the page. The
authorization is `admin_for` in `meta.rs`, which resolves the presented
secret and checks the flag in the database inside every admin route. Checked
per action rather than per login, so revoking the flag or banning the account
lands on the next click, not the next session. A client can dress its screen
up as an admin's and every action still comes back 403.

An admin appoints other admins from the panel. That is a real reduction in
containment and it is worth writing down rather than discovering: a leaked
session, or a bug in the page, can now mint an operator that outlives the
session it came from, where before the worst it could do was act as one until
the flag was revoked. The trade bought the thing an operator actually wanted,
which is adding a second operator without a database credential and a shell.

What survives the trade is every guard that did not depend on that
containment. Only a claimed human can hold the flag, because the panel signs
in with a password that a guest does not have and a bot's `house` credential
is not. The panel's ban refuses accounts holding the flag, so one compromised
session cannot lock the other operators out. And the last admin cannot be
revoked, because two operators disagreeing is a conversation while a
deployment with nobody who can open the panel is a trip to the database.

The first admin of a deployment is still made in the database, since there is
nobody to grant it yet, and `deploy/README.md` has that one command.

The cost, stated plainly: fleet-wide reach now stands behind a password whose
only floor is six characters. The login throttle holds guessing to ten tries
a quarter hour per name however many addresses join in, which is a brake and
not a proof, so the flag goes to accounts whose passwords deserve it. An
earlier draft of this section wanted a passkey or an SSO front before any
surface returned; the flag traded that bar for a credential the fleet already
had, and a passkey remains the upgrade path if the trade stops feeling right.

## What it does not do

It is not a place players appear. Chat moderation, appeals, and anything that
needs a player-facing view belong with identity, which
[decision 11](decisions.md) puts outside the directory and this document does
not change.

It is not a deployment tool. Raising a replica count is the container platform's
job, and an admin UI that also spawns processes would need credentials on the
hosting layer, which is a much larger thing to protect than a catalog editor.
