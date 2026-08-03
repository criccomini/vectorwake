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
stores the secret it gets back. That is the whole flow. There is no form, no
email, and no name to type: the call sign generator names the pilot as it does
today, and the account exists before the first menu is drawn.
[meta-layer.md](../architecture/meta-layer.md) has the machinery.

A pilot made this way is a guest. A guest is not a lesser player. Their rating
is real, accrues from their first death, and follows them between zones and
sessions, because the account is real and the client keeps its secret. What a
guest's identity is tied to is one browser profile or one device, which makes
it exactly as durable as that browser's local storage. Clearing it orphans the
account, and the rating with it.

## Claiming

Claiming turns a guest into a durable identity by attaching a way back in, and
each platform supplies its own: Steam identity when the Steam build lands, and
console identity with the console builds, per
[platforms.md](../architecture/platforms.md). The web forces nothing, so on the
web the way back in is the account key. A claim method is added only when a
platform forces one, which is the rule that keeps this list at three.

The account key is the guest secret made portable: a generated high-entropy
key, shown once in a form a password manager or a paper note can hold, and
stored only as a hash, the same idiom the fleet already uses for pool tokens in
[discovery.md](../architecture/discovery.md). Logging in on a new device is
typing it. There are still no passwords anywhere in this design, because the
three things that make a password table a liability are absent: nobody chose
this key, it exists nowhere else to be reused, and there is no reset flow.
Losing it is the sentence a guest already lives under, said about a much
smaller risk.

Most players should never type the key at all. A logged-in session can display
a short-lived six-digit link code, a new device types the code, and both then
hold the account, so a phone and a desktop each keep the other alive. The same
flow carries the account across platforms, a web session into the Steam build,
and it is the shape console activation screens have taught everyone already.
The key in the password manager is the backstop, not the routine.

Several methods can attach to one account, which is what lets the web build and
the Steam build be the same pilot, as the roadmap has wanted since M6 was
written.

Nothing moves at the moment of claiming. It is the same account with the same
rating and the same history; what changes is that losing the device no longer
loses the pilot. Claiming also reserves the account's call sign across the
fleet, and it changes the label the next section defines.

The client asks once, after a session has gone well, and never blocks play on
the answer. A player who declines stays a guest forever and loses nothing but
the reservation and the label.

## Names

Names come from the generator, always. There is no free-text name field for the
same reason there is no chat, per
[decision 28](../architecture/decisions.md#28-no-chat): an open text channel is
a moderation queue, and consoles certify against exactly that. A claimed
account may keep the call sign it was dealt or roll a new one from the same
word list, and the name it settles on is reserved fleet-wide. Guests keep
today's behavior, a generated name that the room suffixes on collision.

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
tomorrow, wearing a reserved name, which is what a career and a ban both need
before they mean anything. Flying an undeclared bot on a claimed account is
the offense the ban system exists for.

**Unknown** means a guest. The server genuinely does not know what is flying
the seat, and the label says so rather than guessing. Most unknowns are humans
in their first sessions, which is why unknown is not a punishment: an unknown
pilot joins anything a default zone offers and rates normally.

Zones that care can raise the bar. A zone's catalog row may set `admission` to
`any`, the default, or `claimed`, for ladder arenas where knowing the field is
human matters more than a newcomer joining in one second.

## Bots hold accounts

A house bot is a roster individual per [ai-players.md](ai-players.md), and its
account is where the career described there lives: one rating, one history, one
place at a time. The pinned reference personality is a house bot account whose
rating never moves, which is what anchors the whole scale.

A third-party bot account is created under a claimed human account, and that
owner is the accountable party: a misbehaving bot is its owner's ban. The join
declaration and the account kind are the same fact stated twice, and the arena
refuses a join where they disagree, so a bot cannot pass as a person by staying
quiet. Guests cannot own bots, because an owner who can evaporate by clearing
local storage is not accountable for anything. If a key-claimed owner proves
nearly as easy to shed, the bar for bot ownership rises to a platform
identity, since a Steam ban is the one consequence that genuinely sticks.

## Rank over time

Rating already belongs to the event log, per [rating.md](rating.md): every
rated death is stored with its weights and the ratings before and after, and
the current number is a projection of that history. Accounts are what the log
is keyed by, so a profile can draw a career. Rating over time per mode class,
the separate vs-human and vs-AI records rating.md promises as statistics, and
the games behind the number all come from reading the same log along its time
axis. None of it is new storage.

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

Concurrent sessions. Two tabs share one guest secret, so one account can hold
two seats in one room, and two seats under one mind can feed each other kills.
Refusing the second session is simple and punishes households behind one
browser profile; allowing it invites collusion the repeat-kill dampener only
partly prices in.

Sweeping. Every drive-by page load mints a row. An unclaimed account idle for
a year is probably gone forever, and whether to delete it, tombstone it, or
keep it costs almost nothing either way until the table says otherwise.

Recovery for guests. There is none by design, and the claim prompt should say
so plainly. Whether that one sentence is enough warning, or whether losing a
Wake-tier rating to a cleared cache becomes the complaint that forces a second
look, is a question only live players can answer.

Whether typing a key is friction enough to lose claims. Passkeys are the
fallback if it tests badly: the web platform's own credential, still no third
party, at the cost of a WebAuthn ceremony bridged through the browser wrapper.
