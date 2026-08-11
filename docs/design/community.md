# Community

vectorwake carries no text between players, permanently, per
[decision 28](../architecture/decisions.md#28-no-chat). The record that removed
chat also priced it: any league or clan scene will organise on Discord, so the
community's real home is somewhere we do not control. This document is about
paying that price on purpose instead of being surprised by it. We create the
server, we hold the keys, and the game points at it.
[Decision 39](../architecture/decisions.md#39-the-community-lives-on-discord-and-the-game-only-points-at-it)
records the choice; this is what it looks like in practice.

## Why Discord

The argument that removed chat was never that talk is worthless. It was that
text between strangers is a permanent moderation commitment, and the one this
project is least equipped to keep. Discord's whole pitch to us is that it keeps
that commitment for a living. AutoMod, per-user reports, timeouts, bans, audit
logs, and an escalation path that ends at Discord's own trust and safety staff
rather than at whoever happens to be awake. We could not build that, which is
exactly why we refused to carry text, and we do not have to build it to run a
server.

The audience seals it. [Decision
33](../architecture/decisions.md#33-the-originals-keys-where-the-browser-permits-them)
already described this game's ancestral players as the alt-tab-to-Discord
crowd, because the original was a chat program with a dogfight attached. The
people this game courts have a Discord client open while they fly. Meeting them
there costs nothing; asking them to register on a forum of ours would cost most
of them.

And nothing of ours is involved. No new service, no schema change, no account
linkage. A Discord server touches no part of the fleet.

## The server

A Discord server is owned in a way an IRC channel never was, so the boring
questions come first and in writing:

- criccomini's account creates and owns it. At least one other person holds
  admin from day one, because a sole owner losing an account or a 2FA device is
  losing the server.
- The rules are written before the first stranger arrives, short enough to
  read. Discord's own terms do the heavy lifting; ours add what is local, on
  the order of "no call-sign impersonation" and where to report a pilot.
- Few channels. An empty channel reads dead the same way an empty room does,
  and we already spend real engineering keeping rooms from reading dead. Start
  with a couple and split only when traffic forces it. A small server that
  looks alive beats a taxonomy of ghost rooms.
- Discord's terms set a floor of 13 years, higher in some countries. The game
  itself gates nothing today, so the server is age-gated where the game is
  not. That asymmetry is fine, and worth knowing about before somebody asks.

The shape is not clicked into a settings screen, it is a script.
`deploy/discord/setup.py`, run with the bot's token, creates what is missing
by name, asserts the guild settings, and deletes nothing, so repairing a
drifted server or rebuilding one after a disaster is a rerun, and the
server's configuration gets reviewed in git like everything else here.

The icon is the client's own mark, cut for a round tile by
`deploy/discord/icon.py` out of `client/web/icon.svg` rather than redrawn.
Two things change on the way, and both are the reasons the tab and the home
screen already differ from each other: full bleed, because Discord masks an
icon to a circle and would read the file's chamfer as a bite out of the rim,
and stood on its middle vertical, because three wedges are nearly twice as
wide as they are tall and centring the box they fill leaves the standing
strokes visibly right of centre. It keeps the mark's own hairline, since
nothing here asks for it at sixteen pixels.

## The door

One address reaches it: `vectorwake.net/discord`, a redirect in
`deploy/caddy/conf.d/central.caddy` pointing at the current invite. The raw
`discord.gg` code never appears in a client build, the README, or anything
else compiled or cached. CI bakes the client into an image and browsers cache
the page, so an invite embedded there would outlive every attempt to revoke
it. Behind the redirect, rotating a leaked or raided invite is editing one
Caddy line, and every place that ever named the address stays correct.

In the client, the about page can name the address in words for free, the way
it already names the transport. Making it tappable is a real question rather
than a given: browsers allow `window.open` only inside a user gesture, and
Defold polls input once a frame, so by the time Lua acts the gesture may
already be spent and the popup blocker eats the call. The login card solved
this class of problem with real DOM elements laid over the canvas, per
[decision 37](../architecture/decisions.md#37-the-phones-own-keyboard-through-an-element-the-canvas-cannot-be),
and a link that must open on tap would ride the same pattern. An address a
player can read and retype is the floor, and it ships first.

## The wire

Everything the fleet says into Discord is one-way: the fleet publishes,
Discord displays, and nothing ever flows back. Within that rule there is more
worth building than a status line, so the rest of this section is what the bot
could be, roughly in the order the work should happen.

### First, a door the bot can point at

The client reads nothing from its own URL. No hash, no query string, so today
the most a message can do is link the front page and hope. Teaching it to read
`play.vectorwake.net/#chaos`, and eventually a room and a spectator flag with
it, is a small change in `net.lua` and the page template that turns every line
the bot writes into something clickable. Almost everything below is worth less
without it, and several ideas are impossible: an invitation to a particular
fight is only an invitation if the link lands in that fight.

Watching matters as much as joining here. Spectating already exists, and a
lurker who clicks a watch link risks nothing, which is a much easier ask than
"install nothing, but do commit to a dogfight right now".

### Being there when nobody is

A small game dies of the same thing every time. You look, the place is empty,
you leave, and the person who looked ten minutes later would have filled the
room you just left. Everything else the bot does is decoration next to
attacking that.

Presence has to be honest about bots or it is worthless. The fleet runs 51 of
them in Chaos and Warzone, so a single number is true and useless: what a
person wants to know is how many humans are up. Show that, and let the bot
count sit beside it as a smaller, quieter figure that says the room is warm
rather than empty. The gap in the way is that the directory aggregates
per-zone player counts for the games list but publishes them nowhere a machine
can read. `/metrics/dir` renders the same page every role gets, so its
`vw_players` gauge answers for the directory process itself and is always
zero. Per-zone gauges there, `vw_zone_players{zone="chaos"}`, close it, and
then the bot is a fetch and a parse against a page that is already public,
learning nothing the games list does not already hand out.

The presence line is the setup. The feature is the ping: an opt-in role,
joined by reacting to a message, that the bot mentions when the human count
crosses a threshold and then stays quiet for an hour. That is what converts
"nobody is ever on" into "I get told when it is worth showing up", and it is
the one thing on this page that changes whether anybody is playing. It is also
about forty lines.

Discord's own scheduled events are the same idea by appointment. A recurring
flight night, created by the bot, that pings and posts the link when it opens.
Concurrency is the scarce resource for a game this size, and an appointment
manufactures it out of nothing.

### The game narrating itself

An arena knows when something notable happened, and the notable ones have a
story: a large bounty falling, a streak ending, a pilot taking the top human
place. Not every kill, which would be noise at nearly two a second, but a
threshold worth of them, posted as they land. A trickle like that makes the
server feel inhabited on an afternoon when the fight is mostly bots.

Release notes are one webhook step at the end of `client.yml` and one secret
in the repository settings, and the message writes itself from what the build
already knows: the commit that produced it, the same stamp the client shows on
screen. It could carry a picture of itself too. `client/tools/shot.sh` drives
the native client under a virtual display and grabs the window, so a build can
show what it changed rather than quoting a subject line.

Fleet trouble belongs in `#staff`. An arena delisting is a fact the directory
already holds, and a line saying warzone went dark at 14:02 and came back at
14:05 is worth more than a dashboard nobody has open.

### Rendered like the game

`deploy/discord/icon.py` proved the pipeline: a drawing in the game's own
palette, rasterised headlessly, uploaded. The same path answers `/rank` and
`/whois` with a card drawn in the game's colours rather than a grey embed, and
the difference between a bot that belongs to this project and one bolted onto
it is mostly that. A weekly standings post and a sparkline of the last seven
days' traffic are the same trick again.

Two framings the ladder gives us that most games cannot. Humans and bots share
it, per [decision 31](../architecture/decisions.md#31-every-pilot-is-an-account-and-bots-hold-them-too),
so "first human above the anchor" is a real and checkable claim, and a good
thing to chase. And movement reads better than standing: who climbed most this
week says more than a top ten that barely moves.

The catch is that answering "what is my rating" needs a public read route, and
the meta-layer deliberately has none, since every route but health is a
credentialed POST. Opening a read surface on the service that holds accounts
is an API design decision rather than a bot feature, and it waits for a ladder
people actually ask after.

### The ambitious one

The simulation is deterministic and driven entirely by inputs, per
[decision 2](../architecture/decisions.md#2-one-deterministic-simulation-shared-by-client-and-server).
If an arena spooled a room's inputs the way it already spools rated events, a
fight could be replayed exactly, and the bot could hand out a replay the
client plays back with a free camera. "Here is the kill, fly it yourself" is a
feature almost nothing else can offer, and this project can only because of a
decision made for other reasons. It needs input capture that does not exist,
so it is a project rather than a weekend, and it is the one on this page most
likely to make somebody talk about the game.

### What it runs as

Not a `vectorwake-discord` image. A second image is a second CI build, a
second tag, a second thing the updater has to pull and a second place a
version can be wrong, and none of that is bought by anything here.

The one-way rule is what makes this cheap. A publisher needs no gateway
socket, no Discord library and no inbound port: it is periodic HTTPS POSTs to
a webhook, which is a few lines against a URL. So presence belongs inside the
directory process, as a task beside the metrics one. The directory already
aggregates the per-zone counts, so posting them is a side effect of state it
computes anyway, with no scrape of its own metrics page and no second copy of
the games list to drift. `metrics::spawn` is the pattern to copy exactly: an
unset address is the off switch, and every failure is reported once and then
ignored, because a process that refuses to run without its noticeboard has
made the noticeboard into an outage.

The pieces that are not presence, release notes from CI and notable events
from an arena, are each a POST from where the fact already lives, so they add
no process either.

Interaction is where that stops being true. A button that grants the ping
role, or a slash command, means Discord POSTs to us, which needs a public
endpoint, a route in `central.caddy`, and Ed25519 request verification, which
is at least a signature check the fleet already knows how to do. That earns a
face of the binary, `vectorwake-server discord`, alongside arena, directory,
bots and meta. Still the same image, still one `command:` in
`docker-compose.central.yml`, still deployed by the updater's git reset and
compose up.

Two operational notes. The bot token and any webhook URL join the secrets
bucket beside the pool token and the meta key, rendered into `.env` by
`fleet.sh`. And a host's `.env` is the one file a deploy cannot rewrite, so
adding either means re-rendering existing hosts rather than assuming the next
deploy carries it.

`setup.py` stays outside all of this. It is an admin script run by hand, like
`fleet.sh`, and nothing in the fleet imports or schedules it.

### Video, if we post clips

Discord plays video attachments inline, so a highlight can be a clip rather
than a link. Mp4 carrying h264 and aac is the safest across every client, and
the constraint is size rather than format: 10 MB for an unboosted server,
50 at boost level two, 100 at three, and Discord takes the higher of the
server's cap and the poster's rather than the sum.

Ten megabytes is a great deal more than this game needs. Flat colour on black
with hard edges is close to the ideal case for a codec, so seconds of arena
footage land well under a megabyte. Anything long enough to strain that wants
a link to our own hosting with `og:video` on the page, which Discord embeds a
player against and which has no cap at all.

One thing that is not on the machines: a real ffmpeg. The only build in the
client's toolchain is the one Playwright ships for its own recorder, which
encodes VP8 into WebM and nothing else, so a clip pipeline installs ffmpeg
rather than borrowing that one.

### Tempting and refused

Account linking keeps returning in cheaper disguises. The current one is a
single-use code a player types in the game, held by the bot rather than by the
meta-layer, which does keep the database clean. It is still the thing we
refused, moved somewhere with less scrutiny. The meta-layer's best property is
that it holds no personal data and depends on no external service, and a
Discord user id is both at once. If linking ever earns its way in it arrives
as its own decision record, not as a rider on a bot.

Giving the house bots voices in a channel is a trap worth naming, because it
sounds delightful. The roster's personalities are real in the arena, where
they come out of how each one flies. Writing dialogue for them is fan fiction
about our own game, it ages badly, and it teaches players to expect a
character the arena cannot deliver.

## What this is not

It is not chat coming back. Decision 28 stands untouched: in the game,
coordination happens through play, and if that ever loosens it will be the
bounded signals that record's reconsider clause describes, not text.

It is not identity. Nobody's Discord name means anything in an arena, no role
in the server grants anything in the game, and a pilot who never opens Discord
is a complete player who missed some conversation.

It is not a dependency. Nothing in the fleet reads from Discord, waits on it,
or fails when it is down. The integration losing its platform would cost us a
noticeboard, and the day Discord's terms or prices turn hostile, moving is
rotating one redirect.

One idea stays parked rather than planned: Discord Activities embed a web page
in a voice channel, and this client is already a single file. But an Activity
routes all traffic through Discord's proxy, which would fight the WebSocket
path and almost certainly kill WebTransport outright, per
[decision 34](../architecture/decisions.md#34-webtransport-beside-the-websocket-never-instead-of-it).
Worth a spike the week somebody is curious, and nothing before that.

## The order of the work

Deep links first, because they are cheap and everything compounds off them.
The ping role next, since it is the only item here that changes whether
anybody is playing. Then honest presence and the notable-event trickle, which
together make a quiet server look inhabited. Release notes ride along whenever
somebody is in `client.yml` anyway. The ladder work waits for a ladder worth
reading, and replays wait until somebody wants them enough to log inputs.
