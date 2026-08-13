# Accounts

A pilot is flying within a second of loading the page, and the rating they earn
tonight still means something in a year. Accounts exist to make both of those
true at once, which is why nothing in this document ever asks a new player to
stop and sign up.

Four rules shape the design. Bots hold accounts exactly as humans do, whether
we run them or somebody else does. Every seat in a room says whether a human, a
bot, or something unknown is flying it. Nobody signs up to play. And identity
is long lived, so a rating is the record of a career rather than of an evening.

## Nobody signs up to fly

The first time the client runs, it asks the meta-layer for an account and
stores the secret it gets back. That is the whole flow. There is no form and no
email; the server deals the pilot a call sign with the account, and the account
exists before the first menu is drawn.
[meta-layer.md](../architecture/meta-layer.md) has the machinery.

A pilot made this way is a guest. A guest is not a lesser player. Their rating
is real, accrues from their first death, and follows them between zones and
sessions, because the account is real and the client keeps its secret. What a
guest's identity is tied to is one browser profile or one device, which makes
it exactly as durable as that browser's local storage, and no more than a week
more durable than their interest: a guest that has not begun a session in
seven days is deleted, and its call sign returns to the pool. The client
treats the resulting refusal as what it is and quietly becomes a new guest.

## Names

Names come from the server's generator, and are unique across the fleet from
the moment they are dealt, guests included. No player-facing route accepts a
proposed name, for the same reason there is no chat, per
[decision 28](../architecture/decisions.md#28-no-chat): an open text channel
is a moderation queue, and a name a player types is that channel with a
scoreboard attached.

One route does take a typed name, and it is an operator's:
`/v1/admin/rename`, behind the admin flag, one pilot at a time, with the
actor and both names on the log line. It is worth being exact about what that
spends, because this section used to claim it could never happen. Fleet-wide
uniqueness is untouched, since the arbiter was never the generator: it is the
unique index on `lower(call_sign)`, and a typed name that collides is refused
by the same index that makes a dealt one redraw. What it spends is the
curated register, because some names are now chosen words rather than drawn
ones. That is a deliberate trade, bounded by who can make it, and the thing
it buys is an operator who can fix a name rather than only replace it.

Any pilot may reroll, guest or claimed. The account number never moves, so the
rating and the history ride through the rename; only the label changes. The
word list is sized so that a week's guests plus every claimed pilot occupy a
few percent of the pool, and generation retries on collision against the
database's own unique index, which is the only arbiter.

Uniqueness is also what makes a name loadbearing enough to log in with, which
is the next section.

## Claiming

Claiming turns a guest into a durable identity by attaching a way back in: a
password on the call sign they already hold. Name and password are the whole
of it. Nothing moves at the moment of claiming; it is the same account with
the same name, the same rating and the same history. What changes is that
losing the device no longer loses the pilot, and the account is never swept.
A password is a person saying they mean to come back.

Logging in on another device is typing the name and the password. The answer
is a device secret of that device's own, so each device holds its own way in
and one can be forgotten without taking the others with it. Sessions,
short-lived signed tokens, and the arena's verification of them are unchanged
from the layer below; the password's only job is to obtain a device secret,
once per device.

Passwords are stored argon2-hashed, sized between six and sixty four
characters, and constrained in no other way: composition rules push people
toward the same dressed-up word, and what this account guards is a call sign
and a ladder rating. There is no reset flow, because there is no email to
reset against; a forgotten password is a lost pilot, said plainly at the
moment of claiming. The login route is throttled per address and per name,
and guest creation per address, which is what stands between a guessable
credential and a guessing script.

Platform identities remain the plan where a platform forces one: Steam
identity when the Steam build lands, console identity with the console
builds, per [platforms.md](../architecture/platforms.md). Several credentials
can attach to one account, which is what lets the web build and the Steam
build be the same pilot.

The client offers the claim on the pilot page and never blocks play on it. A
player who declines stays a guest and loses nothing but durability.

A seat is bound to one identity for the life of its connection. The zone
reads the name and the token once, at the join, and what it binds there is
what the roster shows everyone and what every kill is filed against until
the connection ends; there is no message that rebinds a live seat, because a
seat carrying two accounts' halves of one life is a ledger nobody can settle.
So when the client's identity moves under a live game -- a login, a reroll, a
logout whose fresh guest has landed -- the client rejoins the same game as
whoever it now is. The rejoin costs the ship, which is the honest price: the
old pilot's bounty, kit and score were never the new one's to keep. Claiming
is the one identity event that costs nothing, because it changes no name and
no account: the pilot you claimed is the pilot you were.

## Human, bot, unknown

Every seat carries one of three labels, and the scoreboard and the roster the
server repeats carry it to every client.

**Bot** means the account is a bot account and the join declared it, per
[decision 29](../architecture/decisions.md#29-a-bot-is-a-client). The label
subdivides once. A house bot is ours, flown by the bot server under a fleet
credential, and a third-party bot is anyone else's. Both are first-class
citizens: the same account shape, the same rating math, the same seat rules.
The difference is trust. A house bot is code we ship, so it may anchor the
rating ladder and seed from the calibration tournament. A third-party bot is
declared honestly but runs code we have never seen, so it anchors nothing.

**Human** means the account is claimed. A claim does not prove a heartbeat and
does not try to. What it proves is that the pilot chose to be the same person
tomorrow, wearing a name that is theirs, which is what a career and a ban both
need before they mean anything. Flying an undeclared bot on a claimed account
is the offense the ban system exists for.

**Unknown** means a guest. The server genuinely does not know what is flying
the seat, and the label says so rather than guessing. Most unknowns are humans
in their first sessions, which is why unknown is not a punishment: an unknown
pilot joins anything a default zone offers and rates normally.

Zones that care can raise the bar. A zone sets `admission` in its `zone.toml`
to `any`, the default, or `claimed`, for ladder arenas where knowing the field
is vouched for matters more than a newcomer joining in one second. The bar is
on the label, so it is a statement about the account rather than about anything
a client said.

## Bots hold accounts

A house bot is a roster individual per [ai-players.md](ai-players.md), and its
account is where the career described there lives: one rating, one history, one
place at a time. The pinned reference personality is a house bot account whose
rating never moves, which is what anchors the whole scale. Bot names live in
the same unique namespace as everyone else's, drawn from word lists that are
disjoint by test, so a scoreboard never wonders which kind of pilot a word
belongs to.

A third-party bot account is created under a claimed human account, and that
owner is the accountable party: a misbehaving bot is its owner's ban. The join
declaration and the account kind are the same fact stated twice, and the arena
refuses a join where they disagree, so a bot cannot pass as a person by staying
quiet. Guests cannot own bots, because an owner who can evaporate by clearing
local storage is not accountable for anything. If a password-claimed owner
proves nearly as easy to shed, the bar for bot ownership rises to a platform
identity, since a Steam ban is the one consequence that genuinely sticks.

## Rank over time

Rating already belongs to the event log, per [rating.md](rating.md): every
rated death is stored with its weights and the ratings before and after, and
the current number is a projection of that history. Accounts are what the log
is keyed by, so a profile can draw a career. The log carries no foreign key to
the account on purpose, so a swept guest's deaths stay in the record as
numbers: what happened stays happened.

## Bans

A fleet ban is a mark on the account, enforced where identity is issued rather
than where the game is played: the meta-layer refuses to mint a session token
for a banned account, so an arena never checks a fleet ban list and a ban takes
effect within one token lifetime. Per-zone bans stay in the catalog on the
zone's row, as [zones-and-arenas.md](../architecture/zones-and-arenas.md) has
them.

## Open questions

Smurfing. Guest accounts are free, so a strong player can always start over at
the bottom. Placement K converges a fresh account in an evening and the
per-event cap bounds each death, so the disguise is short, but a short disguise
in a low room is still somebody's bad night. If it becomes a pattern, the lever
is the `admission` bar rather than making guests slower to create.

Concurrent rated sessions. One account may hold one active rated session across
the fleet. Arenas claim a renewable meta-layer lease before seating an
authenticated account and release it when the connection leaves its hull.
Watching does not claim a lease; taking a hull again claims one before the
spawn. A reconnect waits briefly for the old connection to settle and release
before it is refused.

Recovery. A guest has none by design, and now a claimed pilot's recovery is
only as good as wherever they kept the password. Whether "there is no reset"
survives contact with the first player who loses a Wake-tier rating to a
forgotten password, or whether that complaint forces a platform identity or a
passkey as the second way in, is a question only live players can answer.

Name squatting. Names are server-dealt, so nobody can choose one to sit on,
but a claimed account holds its call sign forever while costing nothing to
keep. If the pool ever thins, the levers are more words and longer numbers
before they are expiry for the claimed.
