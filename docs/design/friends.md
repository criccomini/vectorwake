# Friends

People stay for people. [match-game.md](match-game.md) opens on a retention
number and names this as the system most likely to move it, and
[decision 30](../architecture/decisions.md#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list)
deferred it "until somebody wants them". Somebody does.

Version one is three things:

1. Add somebody, mutually.
2. See which friends are on and what they are in.
3. Join them with one press.

Everything below is in service of those three and nothing else. The parts
deliberately left out are at the end.

## No chat, and no typing at all

[decision 28](../architecture/decisions.md#28-no-chat) is the constraint this
design is shaped around, and it is a gift rather than an obstacle. A friends
system with no messaging has almost no moderation surface: there is no content
to report, nothing to mute, and nobody can reach you with words at all. What
one stranger can do to another is appear on a list.

It also settles the interface question before it is asked. You cannot type a
call sign because there is no text field and there never will be one, so a
friend is a **selection off a roster you are already reading**, which is
exactly how private teams work: "an invitation is a roster selection rather
than anything typed", per [teams.md](teams.md#private-teams-are-invitations).

## Mutual, by both sides adding

One row per direction, and the friendship is the pair.

| you did | they did | what it is |
|---|---|---|
| added them | nothing | you are waiting |
| nothing | added you | they are waiting, and you see it |
| added them | added you | friends |

There is no accept and no decline, because both are the same press seen from
different sides: adding somebody who has already added you *is* accepting.
That removes an entire screen, and with it the thing that screen would have
been used for, which is an inbox strangers can fill.

Removing takes both rows. Leaving the other direction standing would mean a
pilot who removed somebody stays on that person's list forever, visible and
joinable, which is the opposite of what removing means.

The page has to say this, because the rows cannot. A name with "add" beside it
is a press whose consequence is invisible: the name moves to another list and
sits there until somebody else does something, which reads as an invitation
sent off to an approval screen. There is no approval screen. So one line
stands over the list, "add anybody you fly with, and you are friends as soon
as they add you back", and the press says which of the two things it just did:
"added" when you are the first, "friends" when they had already added you.

## Presence comes from the seat, not from a heartbeat

The meta-layer already knows who is flying. An arena claims a row in
`active_rated_sessions` when it seats a token-backed pilot and releases it when
they go, because a rated seat is exclusive: the same account cannot be flying in
two rooms at once. That row is a presence table that already exists, already
has an owner, and is already kept honest by the thing that most wants it to be
right.

So presence is a join, not a subscription. It costs one column: the claim now
carries the zone the arena is serving, because an instance id alone would tell
a player their friend is somewhere without saying where.

One consequence for the client: an answer is about the room the asker was in
when they asked. Arriving in a room or leaving one makes the last one wrong,
and a client that keeps drawing it says "nobody yet" to a pilot sitting in a
room full of people. So the client forgets the answer at both edges and the
page says it is asking until the next one lands.

Watchers are absent from it, and that is correct. A rated seat means flying,
and "in a game" should mean the same thing.

## Where the three things live

**Adding** happens where you have just flown with somebody. The friends page
lists the pilots in your room while you are in one, which is the same roster
the scoreboard and the podium show, and it is reachable from the in-match tab
row so it is one press from the card at the end of a match. That is the moment
a friend is made: you played, it was good, and their name is in front of you.

**Seeing and joining** happen on the friends page too, at the top. A friend in
a game reads as their name, the game, and a press that puts you in it.

**The page** is a tab of its own. It was a row on the play page first, for the
reason [menu.md](menu.md) gives about Discord: "this is where somebody is
already thinking about who to play with", and a tab would have put "who is on"
beside "how loud is the music" in a row of equals.

That argument had it backwards. The play page is somewhere you go in order to
join a game, so a row on it answers "who is on" only for a player who was
already on their way somewhere; the question is asked from wherever you happen
to be standing. And a tab carries its own line under its name, so "two in a
game" is legible from every page in the menu rather than from the one page you
had to open to find out. The row was a good answer to where the *adding*
happens, which is the roster in a match, and that half has not moved.

In a match the same page hangs off the in-match tab row, beside the hangar,
because that is where the roster is.

## What it costs a client

One request. `/v1/friends` returns the whole page: your friends with their
presence, whoever has added you and is waiting, and whoever is in your room and
is not on either list. Asked when the page is opened and while it is on screen,
the way the shop and the week's table already work, and not otherwise: this is
a page somebody is looking at rather than a fact a session needs.

Joining resolves an instance id to an address through the games list the client
already holds, which is why the directory publishes the id alongside the
address. A friend in an instance the directory is not currently listing reads
as on but not joinable, which is the honest answer for an arena that has just
gone.

## Limits, and what they are for

**A hundred outgoing edges.** Not a social judgment: it is what bounds the
query, the page and the JSON. Anybody who reaches it is doing something other
than playing with friends.

**A throttle on adds**, on the same shape as the one that bounds guest
minting. A pilot who adds two hundred people in a minute is farming a list of
who is online, and the rate limit is what makes that cost something.

**The roster of your room is only offered while you are in it.** The list of
who to add is not a directory of the fleet, and there is no way to ask for one:
the only people whose names this system will ever show you are people you are
playing with and people who chose to add you.

## What is deliberately out

**Parties, and seating a party together.** [match-game.md](match-game.md) names
this as the real work, and it is: filling a match while holding two or three
seats adjacent is matchmaking logic that does not exist. What is here gets two
friends into the same room, which is most of the value, and it does it without
touching the code that decides who plays whom.

**Room-level follow.** Presence is the zone and the instance, so joining a
friend puts you in their instance and the ordinary seating rules place you.
Every shipped zone runs one room per instance, so today that is the same thing.
It stops being the same thing the first time an instance holds two, and the fix
is a room number on the seat row rather than a new idea.

**Blocking.** Removing somebody drops both rows; they may add you again, and
you would see them waiting again. With no chat that is a name on a list and
nothing else, so a block would be a moderation feature for a threat model this
game does not have. Worth revisiting the first time somebody reports being
followed around, and cheap to add: it is a third state on an edge that already
exists.

**Notifications.** Nothing pushes. You find out a friend is on by looking, and
the page is one press from the front screen.

**Friends across zones as a social graph.** There is no friends-of-friends, no
suggestions, and no way to see anybody's list but your own.
