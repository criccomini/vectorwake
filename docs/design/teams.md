# Teams

A team has a name, a door, and a size. Public teams belong to the zone: the
operator names them, they outlive every round, and the mode keeps score over
them. Private teams belong to the players who form them: born from a menu
action, named by a generator, entered by invitation, and gone when the last
member leaves. Everyone may join any public team with room in it, and any
private team they hold an invitation to. That is the whole system, and every
refusal a player ever sees is the same sentence: that team is full.

The original called these freqs, and we inherit the structure while dropping
the addressing. A freq was a number because 1997's interface was a chat box
and `=245` was how you named a team from a keyboard. This client has no text
input anywhere, a rule [menu.md](menu.md) records along with the bugs that
earned it, so the number was never going to be the interface. Teams live in a
menu and menus carry names. The simulation is untouched by any of this: a team
is still one byte in the state and on the wire, and the name rides the roster
the way a pilot's call sign does. Names
are presentation. Numbers are simulation. That split already runs through the
whole client.

## Three numbers

A zone shapes its teams with three settings, and everything else in this
document is behavior those settings imply.

| Setting | What it bounds |
|---|---|
| `max_teams` | How many teams the room may hold, the zone's public ones included |
| `max_humans_per_team` | People on one side |
| `max_bots_per_team` | Bots on one side, which is the ballast dial |

There is no balance rule beyond the caps. An earlier draft of this design had
one, a relative invariant that refused any move widening the human gap past
one, and it grew a table of cases, a frozen-swap problem, and a deadlock where
two players who both wanted to cross could each block the other. A join rule
that needs a table is answering a question players will not ask. Caps answer
the question they will ask, which is "why can't I join?", with a reason that
needs no explanation.

What caps do not prevent is stacking inside them: six humans against two is
legal if the cap says six. That is a trade made on purpose, because this
game's failure mode is softer than most. The short side backfills with bots
that genuinely fight, the stack's ratings pay for farming weaker opposition
per [rating.md](rating.md), and a zone that cares sets its cap low. The knob
belongs to the operator, which is where this game puts every number.

## Public teams have names that last

A zone declares its public teams by name in its settings file, next to
everything else the operator tunes. The names are stable on purpose: if War's
sides are always Keel and Vantage, then "Vantage always rushes the north
flags" becomes a sentence regulars say, and the kill feed reads like news
from a place rather than output from a lobby. A mode scores over the public
teams and only them.

Default seating goes to the public team with the fewest humans. It is a
default, not a rule: the team row in the menu shows every team and its count,
and moving is always one selection away.

## Private teams are invitations

Anyone may found a team while the room is under `max_teams`. A founded team
is private, wears a generated name, and admits only pilots who have been
invited. Any member may extend an invitation, because that is how groups
actually form, and an invitation is a roster selection rather than anything
typed. There are no passwords, which is not a sacrifice: a password is a
secret that leaks, an invitation is a decision that does not, and the client
could not have offered a text field anyway.

The selection happens in the info box rather than in a menu of its own. Open
the scoreboard, click whoever it is, and the panel that says who they are
carries the invitation under their bounty. A separate invite menu was the
first version and it was a second roster to keep in step with the first, sorted
its own way, listing the same people; a player deciding to invite somebody is
usually already reading about them when they decide. The control appears only
when it would do something, which means you are on a private side and this is
somebody else who is not already on it. Once sent it says so and stops taking
clicks, because the zone answers an invitation with a team list that does not
name the invitee, so the sender's own record of it is the only receipt there
is.

There is no kick. A team that wants someone gone walks away: everyone else
changes teams, founds a fresh one under a fresh generated name, and re-invites
in a few taps, leaving the unwanted member holding a team of one. This works
because teams are ephemeral and names are free, so nobody defends an asset.
It also makes invitations socially cheap, since a mistake is not a commitment
that needs a moderation tool to undo. A team with no members left in it stops
existing and its byte returns to the pool.

The walk-away only reads as a walk-away if the new team looks new, so the
generator carries on through its word list instead of restarting at the top of
it. Restarting was the first version and it handed a lone player the word the
reaper had just freed, which made founding a second team look like a button
that did nothing. The list still wraps once it is exhausted, because a
free-for-all founds a side for every arrival and a counter that only climbed
would have a room of bots flying for Anvil Watch 30 by the afternoon.

What a private team means depends on the mode. In a free-form zone it is its
own side: you and yours, mutually friendly inside the brawl. In a fixed-side
mode there is no third side to be, and none is needed, because playing
together there is just everyone joining the same public team while it has
room. A zone that wants no extra sides at all sets `max_teams` to the count
of its public teams and the found-a-team row simply is not offered.

## Free-for-all is not a special case

Chaos today is `teams = 1` with the ship index standing in for a side, a
special case that once broke every weapon in the zone. Under this design a
free-for-all is nothing but settings: every pilot spawns as a team of one,
and `max_humans_per_team` says how large a pact may grow. Chaos setting it to
three means a trio may hunt together in a room of soloists while a six-strong
pact that nobody can hurt stays impossible. The dial the original spread
across its freq-size settings is the same dial, held by the same operator.

## Changing teams

Changing teams is gated exactly like changing hulls, for exactly the same
reasons: only alive, only at a full bar, and it is a respawn. A weapon in
flight carries the team that fired it, so a change that took effect in place
would turn incoming fire friendly mid-air; respawning ends the question. The
change drops any flag the pilot carries and clears their earned bounty, which
closes the laundering the original also had to close, where two friends swap
sides to farm each other. Ratings need no protection at all, because rating
is pairwise between accounts per [rating.md](rating.md) and never mentions a
team.

## Bots are the balance

The bot server already fills rooms toward a target and yields seats to
humans, per [ai-players.md](ai-players.md). Teams give it one more
instruction: prefer the side that needs you. Bots flow toward whichever team
is short, inside `max_bots_per_team`, so human choices never strand a side.
Five friends taking one team of War against a bot-held other side is not an
abuse case, it is a co-op mode this design gets for free, and it is why the
caps can afford to be generous where the original had to be strict: its short
side stayed short, ours refills.

## Later, not now

A private team answers "I want to play with my friends tonight." The durable
version of that sentence is a party: the same group, persisted on the account
layer, seated together whenever they enter any zone. Accounts exist and hold
durable ids, so the step is small, but it is a second storey and this
document is the ground floor. A spectator team, the original's parking place
for the dead and the curious, is likewise cheap under this model and waits
for a mode that wants an audience.
