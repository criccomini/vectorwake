# Landing, and the menu

You arrive flying.

There is no start screen, no hull picker in front of the game, and nothing to
confirm. The page loads and you are an Apex called something like Zephyr 18,
in the practice arena, with eight AI pilots already fighting over four flags
and your controls live. Everything that used to be a decision made *before*
playing is a decision made *during* it.

## Why there was never anything to replace

The start screen always drew over a running arena -- the simulation was
stepping, the bots were fighting, and the panel was a lid on top. All it did
was cover the screen and make `my_buttons()` return zero. So arriving in the
game was not a feature to build; it was two lines to delete.

What did have to be built is the way back to those choices, because a start
screen answers questions once and a game asks them again: which hull, which
game, how loud, who am I.

## One list, a stack behind it

A single column at a time. A title, the rows, a hint. Down and up move, enter
or right descends or acts, escape or left goes back, and escape at the root
closes.

```
menu
├ ship        eight hulls, silhouette and a line of what it is for
├ play        practice · duel · zones · address
├ pilot       your call sign, and a reroll
├ settings    sound · frames · fullscreen
└ about       what this is, the controls, the build
```

Five inputs, which is exactly what a d-pad has, what a phone can draw as four
arrows and a button, and what a keyboard already sends. The same tree works on
all three without a second layout, which is the whole reason for a stack of
lists rather than a screen: a two-pane menu reads better on a desktop and
falls apart at 390 points wide, and the console work later would have to
undo it.

Adding a level costs a table in `client/arena/menu.lua` and nothing in the
drawing code. `menu.view()` hands the interface a title, rows, and which one
is selected; `ui.menu` knows nothing else.

Closing forgets where you were. The first version kept the stack, and escape,
down, enter -- which had meant "duel" a moment earlier -- silently changed
hull instead, because reopening had landed back in the ship list. A menu
always opens at the top.

## Nothing pauses

You can be shot while reading the menu, and during testing that is exactly
what happened: a screenshot of the ship list has `D E S T R O Y E D` across
the arena behind it.

That is deliberate. In a zone the world does not stop because one player
opened a panel, so offline it must not either -- one code path, one set of
rules, and no mode where the game is running but not really. It also makes
the menu cost something, which is honest: opening it mid-fight is a risk, not
a timeout.

The consequence to accept is that the arrow keys drive the menu while it is
open, so your ship coasts. Frictionless flight makes coasting the natural
thing anyway; a second set of navigation keys would have kept you flying at
the price of another thing to learn.

The interface stays up underneath -- scoreboard, radar, feed, your own status
-- because hiding it would be a lie about what is happening. Only the two big
centred lines step aside, since they sit exactly where the menu does.

## Changing hull is a respawn

`sim_set_ship_class` puts a pilot in a different hull in place: back to your
start, at rest, a full bar of the new ship, upgrades gone, anything you were
carrying dropped on the map. Everyone else keeps flying and the score stands.

Before this, choosing a ship rebuilt the arena, which is why it could only
happen before a match began. A menu that throws the match away to answer a
question about yourself is not a menu you can open while playing -- and in a
zone it is not even possible, because the world belongs to the server.

The cost is the same cost dying has. Swapping hull mid-fight to counter
somebody should not be free, and losing your greens is what makes it a
decision.

**Not yet:** changing hull inside a zone. The class is sent once, at join, and
there is no message for "I am a Wedge now". The menu says so rather than
pretending.

## Loading

Four megabytes of engine have to arrive and compile before the game can draw
anything. What a player saw during that was a grey progress bar on black: a
page that has not started.

Now the page starts without the engine. `client/tools/single_file.py` draws
the same starfield -- same three depths, same colours, same cell hash -- in
plain canvas 2D, with the wordmark over it and one hairline of progress under
that. When the engine's first real frame is on screen it fades out.

The hand-off is triggered by the game, from `arena.script`, not by the loader.
"The runtime initialised" is seconds before "there is an arena on screen", and
fading out at the wrong one of those turns a seamless hand-off into a black
flash.

Half the progress bar is the embedded assets being decoded, which is
measurable. The rest is compilation, which is not, so it creeps toward the
end and only ever grows.

## Settings that had nowhere to live

**Frames.** A browser drives its frame loop from `requestAnimationFrame`, so
on a 120 Hz laptop the game renders twice as often as on a 60 Hz one and costs
twice the battery for it. The simulation is 100 Hz either way, so this is a
picture setting and not a game one -- which is exactly why it belongs to the
player rather than to us. The row hides itself if the engine will not take
`sys.set_update_frequency`.

**Sound.** Off, quiet, half, full, on the master group.

Both are saved with the call sign and the address, and applied on load, so the
menu never holds a value the engine does not have.

## What is deliberately absent

A **difficulty** or **bot count** setting: the practice arena is a fixed
eight, and a knob for it would be a knob for how much of the game you are
playing.

A **directory nudge** -- a line in the feed saying three pilots are in a live
zone -- is written down here rather than built, because it needs a public
directory to point at and the default address is a loopback one.
