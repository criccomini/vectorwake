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

## No chat, and one text field

[decision 28](../architecture/decisions.md#28-no-chat) is the constraint this
design is shaped around, and it is a gift rather than an obstacle. A friends
system with no messaging has almost no moderation surface: there is no content
to report, nothing to mute, and nobody can reach you with words at all. What
one stranger can do to another is appear on a list.

One thing has moved since that was written, and it is not on this page. The
podium between matches carries six fixed phrases anybody in the room can press
([decision
51](../architecture/decisions.md#51-six-phrases-and-no-way-to-add-a-seventh)),
so a stranger can now say "gg" to you. Nothing about the friends system
changes: the phrases go to a room rather than to a person, they are a closed
list nobody can add to, and no friend edge is what carries them.

This document used to go further and say there was no text field anywhere, so
a friend was only ever a **selection off a roster you are already reading**,
the way a private team invitation is one per
[teams.md](teams.md#private-teams-are-invitations). That kept a real property:
the only names the system would ever show you were people you had played with
and people who had chosen to add you.

There is a field now, on the friends page, and it takes a call sign. It
answers as you type: from the first letter, the meta-layer sends back up to
eight call signs beginning with what is there, and pressing one adds that
pilot by account number, so two names that open the same way cannot be
confused for each other. A call sign is a word and three digits and it has to be exact,
which is a small task nobody should have to be careful about.

The arrows reach it. Down off the tab row lands in the box, down again walks
the names it turned up, and enter on one of those is the press a pointer
makes. That matters most on the page a new player sees, which has nothing on
it but this field: a control you can only use by guessing that typing works is
not a control a keyboard has.

That is a real change to what this system will tell you, and worth naming.
Before it, the only pilots the meta-layer would ever put in front of you were
people you had played with and people who had chosen to add you. Now it will
complete a name you have most of. What bounds it is that it only ever
completes: eight names, matched from the start of the name rather than
anywhere inside it, and nothing comes back but the call sign and the number
needed to add them. It was two characters before it answered at all, which
made a field that looks broken until the second letter and bounded nothing
the eight does not: eight names from the front of the alphabet is the same
eight however many pilots there are. There is no browsing, no listing, and no
way to ask it for everybody: `%` is escaped, so a pilot typing one gets
nothing. It is throttled per account, because a client asking on every
keystroke is the honest use and a script walking the alphabet is not.

The other thing a field opens is an add landing in a stranger's list, which is
why the section below grew an ignore.

The field is the whole of the typing. Nothing anybody types reaches another
player.

## Mutual, by both sides adding

One row per direction, and the friendship is the pair.

| you did | they did | what it is |
|---|---|---|
| added them | nothing | you are waiting |
| nothing | added you | they are waiting, and you see it |
| added them | added you | friends |

Accepting is still adding. The button says accept because that is what it does
from your side of the table, but the press is the same insert as any other
add: adding somebody who has already added you closes the pair, and there was
never a second verb to write. What the accept button buys is that the press is
labeled, on the row of the person who made the first move.

Removing takes both rows. Leaving the other direction standing would mean a
pilot who removed somebody stays on that person's list forever, visible and
joinable, which is the opposite of what removing means.

### Ignore

An earlier version of this page had no decline, on the argument that an accept
screen is an inbox a stranger can fill. That is true, and the field above hands
strangers the way to fill it, so ignore is what pays for the field.

Ignoring takes an add off the list that asks you for a decision. It is not a
delete and it is not a block:

- **Nothing is sent.** The pilot who added you goes on seeing "you added
  them", which is true. There is no notification in this game for anything,
  and this is not the place to introduce the first one.
- **It is the end of that ask.** The add stays in the table and stops being
  drawn anywhere. It used to move to a second list headed *everybody who added
  you*, where accepting it later was one press;
  [decision 77](../architecture/decisions.md) took that list off the page and
  out of the reply, so an ignore is now final from the client's side.
- **It outlives the edge.** The ignore is its own row keyed on the pilot who
  pressed it, not a flag on the row it answers. A flag would have been
  cheaper and wrong: the row belongs to whoever pressed add, and they can
  delete it, so add, get ignored, remove, add again, and the ignore would be
  gone with the row that carried it. Cycling an add buys nothing.
- **Removing a friend clears both ignores.** An unfriend puts the pair back
  where it started. Leaving an old ignore standing would swallow their next
  add without either of you knowing why.

The one press whose consequence is still invisible is the add itself, so it
says what it did on the line under the field: "added, you are friends once
they add you back" when you are the first, "friends, they had already added
you" when they were. That is the one thing the client cannot work out for
itself, because once the row is in, the press that closed the pair and the
press that did not look identical. It rides back with the page.

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

The answer used to be about the room the asker was in when they asked, since
it carried that room's roster, and the client had to forget it on every join
and leave or say "nobody yet" to a pilot sitting in a room full of people.
Nothing in the reply is about the room any more, so an answer stands until the
next one lands.

Watchers are absent from it, and that is correct. A rated seat means flying,
and "in a game" should mean the same thing.

## What the page is

Four things down the screen, and nothing else
([decision 77](../architecture/decisions.md)):

1. A field that takes a call sign, under ADD FRIEND.
2. RECEIVED: the adds waiting on an answer, each with accept and ignore.
3. FRIENDS: one line each. A dot, a name, and the game they are in.
4. A key at the foot that invites somebody who has never played.

The dot is the page. Solid green while they are flying, a hollow grey ring
while they are not, so it says the same thing twice and survives a screen that
renders both as one grey. A friend in a game carries the game's name as the
games list spells it, Team Battle rather than melee, and a friend who is off
carries nothing: the ring already said it.

Nothing is drawn on a friend's row but those three things. Join and unfriend
are on the card the row raises, which is the list every input has always been
offered; a key on the row would be the fourth thing competing with the dot for
the eye.

## Where the three things live

**Adding** is the field, and since decision 77 it is the only way to make an
edge from nothing. The page listed the pilots in your room as a section of its
own, with an add on each row; that was the moment a friend is made, and it is
gone. What is left is reading a call sign off the scoreboard and typing it,
which the completions make short: a letter is enough to start, and pressing a
name adds that pilot by number. The cost is written down in decision 77.

**Seeing and joining** happen on the friends page, in the FRIENDS list. A
friend in a game reads as a green dot, their name and the game; the press
raises the card, and the card's first key joins them.

**Inviting somebody who is not here at all** is the key at the foot. It hands
the site's address to the phone's share sheet, or copies it on a desktop, and
the word is the same word: a friend on this page is somebody you fly with, and
a friend at the foot of it is somebody you know. Nothing about the invite
knows who sent it, so the person who opens it arrives as any other new pilot
does.

**The page** is a tab of its own. It was a row on the play page first, for the
reason [menu.md](menu.md) gave about the community section that used to sit
beside it: "this is where somebody is already thinking about who to play
with", and a tab would have put "who is on" beside "how loud is the music" in
a row of equals.

That argument had it backwards. The play page is somewhere you go in order to
join a game, so a row on it answers "who is on" only for a player who was
already on their way somewhere; the question is asked from wherever you happen
to be standing. And a tab carries its own line under its name, so "two in a
game" is legible from every page in the menu rather than from the one page you
had to open to find out.

In a match the same page hangs off the in-match tab row, beside the hangar.

## What it costs a client

One request. `/v1/friends` returns the whole page: your friends with their
presence, and whoever has added you and is waiting on an answer. Asked when the
page is opened and while it is on screen, the way the shop already works, and
not otherwise: this is a page somebody is looking at rather than a fact a
session needs.

It answered with three more lists until decision 77, and they went from the
reply as well as from the page, because a list nobody draws is still four
queries every five seconds of somebody else's database time.

Three routes change it or feed it. `/v1/friend` makes or drops an edge and
takes either an account number off one of those lists or a call sign somebody
typed; `/v1/friend/ignore` sets and clears an ignore; `/v1/friend/find`
answers a prefix with call signs, which is what the add field draws under
itself as you type. The first two answer with the page, because a press has to
redraw and the client should not be working out what an edge did to lists it
does not compute.

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

**The field completes rather than searches.** It is not a directory of the
fleet and there is no way to ask for one: eight names back, matched only from
the start, and the pattern characters escaped so nobody can ask for
everything. A pilot who has most of a call sign gets the rest of it; a pilot
who has none of one gets nothing.

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

**Blocking.** Ignore is not one. An ignored pilot can still see you in a room,
still join a game you are in, and still sits on a list you can accept them
from. What ignore does is stop them asking. With no chat, the rest of what a
block would prevent is a name on a list, which is a moderation feature for a
threat model this game does not have. Worth revisiting the first time somebody
reports being followed around, and cheaper now than it was: `friend_ignores`
is the table a block would live beside.

**Notifications.** Nothing pushes. You find out a friend is on by looking, and
the page is one press from the front screen.

**Friends across zones as a social graph.** There is no friends-of-friends, no
suggestions, and no way to see anybody's list but your own.
