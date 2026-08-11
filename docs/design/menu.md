# Landing, and the menu

The page opens on a menu over a starfield. It asks three things, none of them
required: which hull you want, whether the call sign you were dealt suits you,
and which game to join. Press enter on a game and you are flying.

Escape brings the same menu back over the live arena. Every row means there
what it meant on the way in, so there is one menu in this game and you learn it
once.

## The only difference between the two

Whether there is a game behind the panel. That is one flag, `menu.home`, and
everything else follows from it: with nothing behind it the menu cannot be
closed, the corner stops offering a way out, and a `leave` row appears in the
root only once there is something to leave.

Closing a menu with nothing behind it would leave a player on an empty
starfield with no way back, which is a button that breaks the game.

## One list, a stack behind it

A single column at a time. A title, the rows, a line at the bottom. Down and up
move, enter or right descends or acts, escape or left goes back, and escape at
the root closes.

```
vectorwake
├ play        the games a directory is running, and how busy each one is
├ ship        eight hulls, silhouette and a line of what it is for
├ pilot       your call sign, and a reroll
├ settings    sound · music · frames · fullscreen
├ help        the controls, on a keyboard and under a thumb
├ about       what this is, and the build
└ leave       back to the menu (only while you are in a game)
```

Five inputs, which is exactly what a d-pad has, what a phone can draw as four
arrows and a button, and what a keyboard already sends. The same tree works on
all three without a second layout, which is the whole reason for a stack of
lists rather than a screen: a two-pane menu reads better on a desktop and falls
apart at 390 points wide, and the console work later would have to undo it.

Adding a level costs a table in `client/arena/menu.lua` and nothing in the
drawing code. `menu.view()` hands the interface a title, rows, and which one is
selected; `ui.menu` knows nothing else. A node's rows may be a function rather
than a table, which is how the games list and the conditional `leave` row are
built from the moment rather than declared.

Closing forgets where you were. The first version kept the stack, and escape,
down, enter, which had meant a play row a moment earlier, silently changed hull
instead, because reopening had landed back in the ship list. A menu always
opens at the top.

## The games list

`client/arena/directory.lua` asks a directory what is running. Opening the list
asks at once, and it re-asks every three seconds for as long as the list is the
thing on screen, so the counts move under a player reading them rather than
sitting at whatever they were when the page loaded.

It polls nowhere else. How busy a game is matters while somebody is deciding
which one to join, and not at all while they are three levels away setting the
volume or ten minutes into a fight. Stopping is also what makes the next look
start with a fresh ask: without that, coming back to the list after a match
would show the fleet as it stood before the match began, and the interval would
have to elapse before that corrected itself.

A row is a game, not a machine. The reply lists the instances running each zone
underneath it, already ordered so the head is the fullest one that still has
room, and joining takes that head. The address is never shown. The zone's name
travels with the join, so arriving at an instance that has since changed game is
a refusal rather than a surprise.

Two columns: the name, and how busy it is. What the game actually is goes under
the list, as a line about whichever row is selected. Both on the row was tried
and does not fit: "everybody against everybody" beside "5 playing, 3 AI" is 45
characters against the 40 a phone has room for, and of the two the count is what
decides while the description is what explains.

The game you played last is marked and the cursor opens on it, so coming back is
one press. A zone nobody is running is still a row, because a player is better
off seeing that Chaos exists and is down than wondering whether they misread the
list.

## Nothing pauses

You can be shot while reading the menu, and during testing that is exactly what
happened: a screenshot of the ship list has `D E S T R O Y E D` across the arena
behind it.

That is deliberate. The world does not stop because one player opened a panel,
and a menu that suspended it would be a lie the server cannot tell. It also
makes the menu cost something, which is honest: opening it mid-fight is a risk,
not a timeout.

The consequence to accept is that the arrow keys drive the menu while it is
open, so your ship coasts. Frictionless flight makes coasting the natural thing
anyway; a second set of navigation keys would have kept you flying at the price
of another thing to learn.

The interface stays up underneath, scoreboard and radar and feed and your own
status, because hiding it would be a lie about what is happening. Only the two
big centred lines step aside, since they sit exactly where the menu does.

## Changing hull is a respawn

`sim_set_ship_class` puts a pilot in a different hull in place: back to your
start, at rest, a full bar of the new ship, upgrades gone, anything you were
carrying dropped on the map. Everyone else keeps flying and the score stands.

Before this, choosing a ship rebuilt the arena, which is why it could only
happen before a match began. A menu that throws the match away to answer a
question about yourself is not a menu you can open while playing, and in a zone
it is not even possible, because the world belongs to the server.

The cost is the same cost dying has. Swapping hull mid-fight to counter somebody
should not be free, and losing your greens is what makes it a decision.

On the home screen the same row is just the hull you will arrive in, saved
beside your call sign and sent with the join.

### In a zone, and only from a full bar

The zone protocol carries a hull change (`C2S_SHIP`), the server applies it
through the same core function, and the next snapshot brings back a different
ship. Nothing is predicted: a hull that flickered back would be worse than one
that arrives a frame late.

You keep your team and your seat. You lose your upgrades, your position and
anything you were carrying, exactly as dying takes them. Your kills and deaths
stand, because those are the match's record rather than yours to spend.

**Only at full energy, and only alive.** A fresh hull is a fresh bar, so ungated
this is a way out of a fight you are losing: take a beating, switch, come back
whole. Full energy means you are not in one, or you have flown clear long enough
to recover, which is the same thing. Dead is refused too, because the change
sets `alive`, and allowing it would hand an early respawn to anybody who opened
the menu on the way down.

The rule lives in the core, so the client and the server enforce one copy of it.
The client checks first only so a refusal comes with a reason rather than
silence.

## Loading

Four megabytes of engine have to arrive and compile before the game can draw
anything. What a player saw during that was a grey progress bar on black: a page
that has not started.

Now the page starts without the engine. `client/tools/single_file.py` draws the
same starfield, same three depths, same colours, same cell hash, in plain canvas
2D, with the wordmark over it and one hairline of progress under that. When the
engine's first real frame is on screen it fades out, into the same starfield
drawn by the engine with the menu over it.

The hand-off is triggered by the game, from `arena.script`, not by the loader.
"The runtime initialised" is seconds before "there is something on screen", and
fading out at the wrong one of those turns a seamless hand-off into a black
flash.

Half the progress bar is the embedded assets being decoded, which is measurable.
The rest is compilation, which is not, so it creeps toward the end and only ever
grows.

## Settings that had nowhere to live

**Frames.** A browser drives its frame loop from `requestAnimationFrame`, so on
a 120 Hz laptop the game renders twice as often as on a 60 Hz one and costs
twice the battery for it. The simulation is 100 Hz either way, so this is a
picture setting and not a game one, which is exactly why it belongs to the
player rather than to us. The row hides itself if the engine will not take
`sys.set_update_frequency`.

**Sound**, and **music** separately. Off, quiet, half, full, on their own mixer
groups. Wanting the game loud and the soundtrack off is the commonest thing
anybody wants out of a game's audio and one number cannot say it.

All of them are saved beside the call sign and the last game, and applied on
load, so the menu never holds a value the engine does not have.

## What is deliberately absent

**An offline mode.** The client used to land in a practice arena it flew
itself, against a roster of eight bots written in Lua. That is gone. It was
three hundred lines shadowing `server/src/ai.rs` that drifted from it every time
either was fixed, and the fleet already runs the game it was standing in for.
The cost is real and accepted: with no connection there is no game. See decision
20.

**A difficulty or bot count setting.** How many AI pilots are in a room is the
zone's business, declared in its `zone.toml`, and a knob for it in the client
would be a knob for how much of somebody else's game you are playing.

**An address field.** There is no way to type a websocket URL into this game:
the games list asks the configured directory what is running and you pick from
the answer. That deleted the last text input, and with it the invisible DOM
input laid over the canvas, the focus handed back and forth between the two, and
the keystroke that went to whichever of them held the caret, which was the
single largest source of bugs in this client. An operator who runs their own
directory points a build at it with `--config=vectorwake.directory=ws://...`,
and a build that should skip the menu entirely takes
`--config=vectorwake.server=wss://...`; a player never sees an address.

The consequence, which is the point: if the directory is unreachable there is no
way into a game. A single front door is a front door that has to be up.
