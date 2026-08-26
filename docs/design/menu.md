# Landing, and the menu

> **The x and the call sign are a row of their own.** The two controls on the
> drawer's top line are the head, and the arrows reach them by pressing up off
> the first row of a page: left and right walk between them and loop, down goes
> back into the page at the top of it, enter presses what it is on, and up does
> nothing because nothing is over that line. They were stops on the end of the
> rail, so right off the last tab crossed the height of the panel to a button
> at the top of it. An arrow off the rail is a step in a direction now: up
> walks into the page from underneath and lands on its last row, down comes in
> over the top and lands on its first, and neither opens a page's text field.
> Enter is the press that is not a direction, so it is the one that still lands
> where the page was left. The ship page carries the head every other page
> carries, and the settings page carries no "what this changes" section under
> its rows. See [decision 75](../architecture/decisions.md).

> **The pilot page is the career and the way to keep it.** The name leads
> with the reroll behind a NEW NAME key, because a press on your own call
> sign used to reroll it on the spot. Under a ship-page section rule, the
> career as bare totals: the most-flown class's rating and tier, the record,
> rated games, rivets, all served by the meta-layer's `/v1/career`. At the
> foot, the one act each state has: a guest's lit SIGN UP under "Keep your
> points and log in on other devices" and "Already have a pilot? log in", or
> the password and log out as a pair. "Keep this pilot" and the reading
> column that said everything twice are gone; sign up and log in are the
> words everywhere, and the sign-up card carries the one explaining line. A
> guest with something to lose gets a gold banner on every tab but this one:
> "You are using a guest account. Press here to set your password." See
> [decision 70](../architecture/decisions.md).

> **The account page is a stop on the rail.** The home row is play, ship,
> friends, settings and pilot: the account page as the fifth stop, wearing the
> helmet mark the interface already uses for a person. The call sign pill at
> the far end of the top line stays and opens the same page, because it is the
> one thing on screen saying who you are signed in as; it used to be the only
> way in, and a name in a pill does not look like a button. The stop stays
> home, so the short row a match gets is unchanged. The name is a label with a
> press on it rather than a stop the arrows walk, so it never lights for the
> page: the rail stop is the one mark saying where you are. See
> [decision 69](../architecture/decisions.md).

> **A game row is one press, and leaving is a button on it.** Pressing a game
> means be in that game, wherever this client happens to be: already there and
> the panel goes, anywhere else and the stands dial it and keep dialing while a
> network or an arena is down, with the panel up until a room answers. The way
> out of the game you are flying is a button at the right hand end of that
> game's own row, reached by the right arrow, and it hands the seat back rather
> than the room. The `leave` stop is off the tab row a pilot in a match gets,
> which is play, friends and settings. See
> [decision 66](../architecture/decisions.md).

> **The standings are gone.** The week's table came out of the client: the
> tab, the page, the column heads it sorted by, the box you typed into to
> narrow it, the arrows that stepped a week back, and the `/v1/week` call that
> filled all of it. Four stops, not five. The site still publishes the ladder
> at `/pilots`, which is where a pilot reads where they stand. See
> [decision 65](../architecture/decisions.md).

> **The ship page is the shelf.** The upgrades tab is gone: every slot the arena
> has is a row of the ship page, drawn as circles (solid equipped, a ring owned,
> a dim grey ring not yours) with the price of the next rung on the rows that
> still have one to sell. Pressing a row's name, or the part of its ladder
> nobody owns, slides a reading in from the right, which is the one place in
> this menu anything is bought. The build library sits behind the band's name
> key with a key that makes one and a key that drops one, nothing renames a
> build any more, and the save key stands at the foot of the ship page only
> while the kit differs from the build it came from. Five stops, not six. See
> [decision 64](../architecture/decisions.md) and the mocks in `.design/hangar`.
> That page went without a head for a while, the band standing on the head's
> own line; decision 75 put the head back on every page.

> **One column, docked to the left edge.** The menu is drawn once at 390 points
> wide and stood against the left edge of whatever window it is in: a head with
> the wordmark and the call sign, the page under it, the six stops at its foot.
> A phone held upright gives it the whole screen, which is what that phone
> already got; anything wider keeps the fight beside it, so a ship or a zone can
> be changed without leaving the stands. The two layouts this file describes
> below, a tab bar under a thumb and a row of words across the top, are one
> layout now. See [decision 63](../architecture/decisions.md) and the mocks in
> `.design/menu-unify`. Three things went with the width: the picture of a
> keyboard on the controls page, the reading pane beside the upgrades shelf, and
> the second column that carried the room's roster beside a list. The first two
> are pages you read a row at a time now. The roster went altogether: it was a
> second scoreboard on the page that is about leaving for somewhere else, and
> the room it described is on screen the moment the panel goes.

> **It opens as a drawer.** The key that opens it is a hamburger, three bars in
> a square box with the word MENU beside them on a desktop and the bars alone on
> a phone in either orientation. The column slides in from the left over 160ms
> and back out the same way, and a thumb can drag it off: a third of its width
> is far enough to count as gone, anything less springs back rather than sitting
> ajar. What the column comes to cover stands down while it is over them and
> comes back when it leaves. That is the match clock band and the dial's corner,
> asked as a real overlap rather than as "is a menu open", so a phone held
> sideways loses the band and keeps the dial. The way out is an x in the square
> the key occupies, at the same inset on the same line, with the wordmark moved
> right to make the room: pressing the key and pressing the x are one control
> seen from either side.

> **The play page is the games and nothing else.** No heading over the only list
> on it, no player and robot counts beside each name, no roster under the rows,
> and no DEPLOY key at the foot. A row is the way in, by a tap or by enter, and
> its lit field and its press run edge to edge of the panel rather than stopping
> at the row's own measure.
>
> **A row states its format.** Under the sentence, three small stacks in the
> room band's label-over-value grammar: TEAMS, TIME and SCORING, with a thin
> rule between them, so Team Battle reads 4 v 4, 3:00, kills and Duel reads
> 1 v 1, one life, rungs. The words ride the directory reply beside the label
> and the description, derived by the catalog from what each zone declares
> (`ZoneDef::format`), so a tuning edit that moves the clock moves the strip
> and the client never knows a format. With the numbers in the strip, the
> description stops restating them and carries the hook the strip cannot:
> Duel's stakes, Team Battle's bounty rule. A directory from before the strip
> sends none and the row is the name and the sentence, as it was. Mocked and
> chosen in `.design/play-menu` (version I of three rounds).

> **The landing is the game now.** Opening the client seats you in the stands
> of a real melee room and draws the watcher's HUD; the front end is that
> screen with the wordmark and a pulsing PLAY NOW key over its foot. The deck
> this file describes below is gone, and so is the zone carousel that lived on
> it. What is left of the menu is a panel you open over the stands, closable
> like the one opened mid-fight, with the play tab back to being the list of
> games. See [decision 61](../architecture/decisions.md) and the section
> "Behind it, the sky the game is played under", which is now literally the
> game. The reasoning below is kept where it still holds; where it describes a
> deck, the stands are what exists.

> **The split happened.** [match-game.md](match-game.md) moved the ship page,
> the upgrades and the standings out of this tree and into pages of their own,
> with settings beside them, so the front end is six tabs and help folds
> into settings with the bindings. Friends is one of them and upgrades is
> another. Upgrades was folded into the ship page for a while, with the price
> of each rung written on the row that spends it, on the argument that picking
> a slot and paying for it are one act. What that produced was a panel doing
> two jobs at once: a wallet and a budget on one screen, and the word "spend"
> meaning both. They are two questions asked at different times and they are
> two stops again. It is one full-screen surface met in
> both places, differing only in which tabs it carries: in a match, play,
> friends and settings, because nothing pauses and anything you cannot act on
> now costs match time to read. It is still driven by the five inputs below, with left
> and right moving along the tab row and up and down moving through the page.
> The sections about a single column and about changing hull mid-fight are
> kept for the reasoning; where they describe a tree, the tab row is what
> exists.

The page opens on a menu over a starfield. It asks three things, none of them
required: which hull you want, whether the call sign you were dealt suits you,
and which game to join. Press enter on a game and you are flying.

Escape brings the same menu back over the live arena. Every row means there
what it meant on the way in, so there is one menu in this game and you learn it
once.

## The only difference between the two

Whether you are in a hull. That is `menu.home`, and the tab row follows it:
five stops with no hull, the short row with one. A pilot the room benched is in
the stands too, same empty cockpit and same time to read, so they get the row
back with `leave` added, which is the one stop that needs a zone to mean
anything, and `pilot` withheld, which is the one that needs there not to be
one: an account is not a thing to edit from inside a room.

The short row keeps the games. It did not, and leaving was a stop of its own
called `leave`, which filed the way out of a game beside the way to the sound
settings and a page away from the game it was about. It is a button at the
right hand end of that game's own row now, and it hands the seat back rather
than the room: what a pilot leaving a match wants is to stop flying, not to
lose the arena they were flying in. So the row that carries it is the room's
own, the panel stays standing over the result, and the corner offers TAKE SEAT
for going back in. Right is the arrow that reaches the button, which is where
it is drawn and the one thing right had no other use for on a list of games.

That leaves one press on this list with one meaning: be in this game. Three
states answer it three ways, and all three are `M.want_zone`.

| where you are | a press on a game row |
| --- | --- |
| flying it | puts the panel away, because you are already there |
| flying another | asks first, then joins: it costs the match you are in |
| watching, or adrift | dials that zone and keeps dialing; the panel stays up until a room answers |

The third is the one worth stating. A press is a thing this client is now
trying to do rather than a thing it has done, so `M.await` holds which game and
the panel is where it says so. On a fleet that is down, that panel is the whole
of the feedback there is: the stands go on dialing, the row wears the dial
that is looking for a room, and `M.arrived` takes the panel away the moment one
answers.

Whether the menu can be *closed* is a different question, and it used to be the
same one. Closing a menu with nothing behind it would leave a player on an
empty starfield with no way back, which is a button that breaks the game. What
is behind it now is either the stands or the waiting screen, and both of those
carry MENU, so it always closes and nothing ever opens it but a player. Escape
means the same thing from every level: put the panel away. Left and the chevron
are what walk back through the tree.

## A tab row, and a page under it

Five tabs at the front end and three in a match, with one page under whichever
is lit. Left and right walk the row; down or up enters the page, and up from
its first row or down off its last comes back to the row, which makes the
column a ring a thumb can walk either way. Left and right on a row set that
row's value.
The exception is a row drawn as a chip rather than as a ladder: the ship
page's add-ons are a line of boxes across the page, so left and right go to
the box beside this one and enter throws the one you are on. An arrow points
at what is next to a thing; on a chip that is another chip.

```
vectorwake
├ play        the zones a directory is running, each with a sentence saying
│             what its game is
├ ship        every slot the arena has, as circles, and the thirty points you
│             spend on them. A rung you do not own is dim with its price on
│             the end of the row; pressing the row reads it and buys it.
│             Slots, never strength: see match-game.md
├ friends     a field you type a call sign into, the adds waiting on an
│             answer, and your friends: a green dot and the game they are
│             in, or a hollow one. A key at the foot invites somebody who
│             has never played. See friends.md
├ settings    sound · music · frames · fullscreen · bindings · about
└ pilot       who you are and the way to keep it: the name large with a NEW
              NAME key beside it, the career as bare totals under a ship-page
              section rule, and the account acts at the foot. A guest gets
              one lit SIGN UP under "Keep your points and log in on other
              devices"; signed in, the same foot holds the password and the
              way out

              your call sign still sits at the far end of the top line and
              opens the same page. It was the only way in for a long time,
              on the argument that a stop repeating the name beside it said
              it twice; what that bought was an account nobody knew they
              had, because a name in a pill does not look like a button.
              The stop is the door a stranger finds and the name is the one
              a returning player knows, and it stays because it is the one
              thing on screen saying who you are signed in as. It is drawn
              as a button, and it is the only thing at that end of the line:
              a Discord door stood beside it until the game stopped carrying
              one at all, per decision 73

in a match
├ play        the same list, because the way out of the game you are in is a
│             button on that game's own row
├ friends     the same page: who is on, and who is waiting on an answer
└ settings    the same page, because sound and fullscreen are needed there
```

Five inputs, which is exactly what a d-pad has, what a phone can draw as four
arrows and a button, and what a keyboard already sends. It is two axes rather
than the stack's one, and it costs nothing on any of the three: the row is
horizontal, the page is vertical, and nothing needs a pointer. A page still
descends where it has somewhere to go, though the ship page no longer does:
picking a hull and spending its thirty points are the same act seen twice, so
the carousel and the ladders are one page rather than two levels.

### A page you cannot stand on is not a page you can enter

The catalog and the games list arrive over the wire. Until they do, those
pages hold one line saying so, and down off the tab used to step into them
anyway: the cursor landed on a list of none, the arrows left the tab row, and
the next press did nothing anybody could see. So the step is refused while
there is nothing to stand on, silently, with the cursor left on the tab. The
stage previews the page from the tab above it either way, so the same words
are on screen; the press starts working the moment the rows arrive. A page
whose first control is a text field counts as standable even with no rows,
because a friends page with nobody on it is the whole reason somebody opens
it.

### Lit and hovered are two marks

The lit stop is where you are. The hovered one is what a press would open,
and it never moves the cursor. That was one mark for a while, on the reading
that a hover is the cursor wherever the cursor lives, and the cursor lives in
the rail at the root and in the stage below it. What came out was a tab row
that changed the page under the mouse on the home screen and did nothing from
inside a page, told apart only by how you had got there. Inside the stage a
hover is still the cursor, because there is one cursor and it is the list you
are reading; on the rail, crossing the row on the way to somewhere else can
no longer take a page off the screen.

The call sign lights for the arrows standing on it, wherever the panel is,
because that is a cursor and a cursor you cannot see is a cursor nobody can
use. It does not light for a pointer crossing it while its own page is up: the
rail carries that page and the rail's stop is what says you are on it, and a
name lighting under a mouse there would put "where you are" in two places.

## What the window decides

Two questions, not one, and for a while it was only the first.

**Width** decides where the tabs go. Under 620 points they are a bar along the
bottom edge, where a thumb reaches them; over it they are a row across the top
beside the wordmark. That is a question about width because what it settles is
whether five words fit up there.

**Height** decides how much room there is to spend. Under 500 points the type
zoom comes off and the margins pull in. This is the question that was missing:
a phone held sideways is 844 points wide and 390 tall, which is how anybody
plays a game like this, and measuring width alone gave it the desktop layout
at desktop size in 390 points of screen. Every page lost its bottom half.

Landscape therefore takes the top row, which is the right answer for it: 56
points of height against the bottom bar's 84, at the size a phone reads.

The far end of the top line carries the call sign on both layouts, with the
wordmark giving up size to make room. The tab row is bounded by it and gives
up its gaps before its type. Laid out from opposite ends and never told about
each other, the two ran into the middle of a landscape phone and the last tab
was drawn under a button that took its taps.

There were two buttons there until decision 73, the call sign and a way out
to Discord, the second wearing its mark alone where the word would not fit.
The community door is the site's now and the game carries none, so what is
left is the call sign at one end of that line and the x at the other.

Those two are their own row, walked with left and right, reached by pressing
up off the first row of a page. They were the far end of the tab row for a
while, on the argument that a button no key can focus is broken for whoever is
not holding a mouse, which is true and was answered in the wrong place: the
tabs are along the foot of the column and these are drawn at the top of it, so
right off the last tab took the cursor the height of the panel sideways into a
control nobody watched it arrive at. Up off a page is where a hand looks for
the thing above the page.

Away from home the call sign is not a stop. An account is not a thing to edit
from inside a room, so there the name is a label saying who you are signed in
as and the x is the whole of that row.

## Behind it, the sky the game is played under

The home screen's ground is the arena's own starfield: three parallax layers
and the nebula behind them, drifting slowly and diagonally because nothing is
looking at anything. It is the same routine the game draws its sky with, so
the screen a stranger lands on is made of the thing they are about to be
inside.

A hull used to cross it on a closed loop, trailing a wake, on the argument
that a text column in the middle of an empty field carried nothing. What it
actually did was put a ship nobody was flying in front of a menu about flying
one, moving against a field that was already moving. The field alone is the
picture.

## A button is a stroked box

One shape for a thing to press: a rectangle outlined all the way round with a
wash inside it. That is what MENU wears in the corner of a game and what the
help page draws a key as, so a hand that has learned one has learned
all of them.

Three controls used to say otherwise. Add on the friends page wore the
chamfered bracket that holds a cluster together, and the account and community
buttons at the end of the top line were rounded pills, on the argument that a
pill is the shape the web puts a link in. Each was a fair reading of its own
shape and the wrong answer about the object: they do what MENU does, on pages
where MENU itself is one press away.

The bracket keeps everything that is not a button, which is a field, a card or
a panel. So the two shapes now say which of those a rectangle is, and that is
more than either of them was saying before.

## The interface measures its own type

Two faces: the mono everything in flight is set in, and the menu's own. A
caret goes after the last letter of a name, a field behind a tab is as wide as
the tab's word, and a word is centered in the room it was given, so all three
need a width before anything is drawn.

The mono answers with one number, because every glyph in it advances the same.
The menu's face does not, and measuring it with the mono's number ran about a
fifth long on lower case: the caret sat two letters past the end of a call
sign, and every tab word sat left of the middle of its own field with the
padding visibly bigger on one side than the other.

So the advances are read out of the file the face draws with and written down
as a table beside it. `client/tools/font_advances.py` generates it and says
why; nothing runs at build time, because the font is vendored and a generated
file in the tree beats a step somebody has to remember.

## Scrolling

Pages scroll, in pixels, dragged by a finger and pushed by a wheel notch. The
offset is reset when the page changes and clamped against what the page came
to on the last frame, since only the page knows how tall it is and it does not
know until it has drawn.

Every page draws whole rows only. There is no scissor to clip a half row
against, and there could not be one that helped: type comes from the gui,
which draws over every mesh the interface lays down, so nothing behind a
heading can cover a row that has slid under it. What a row does at the edge is
appear whole or not at all.

The ship page keeps its band pinned and slides the kit under it, because the
band carries the budget every row below it is spent against. The week's table
keeps its heading for the same reason. A list still follows the cursor as well,
so the arrows and a d-pad drag the page rather than walking off the edge of it.

Adding a level costs a table in `client/arena/menu.lua` and nothing in the
drawing code. `menu.view()` hands the interface a title, rows, and which one is
selected; `ui.menu` knows nothing else. A node's rows may be a function rather
than a table, which is how the games list and the conditional `leave` row are
built from the moment rather than declared.

Closing forgets where you were. The first version kept the stack, and escape,
down, enter, which had meant a play row a moment earlier, silently changed hull
instead, because reopening had landed back in the ship list. The menu always
opens on the tab row.

## The play tab

The zones, and nothing else. They were three sections at one point, zones and
friends and community, because run together in one column they read as one list
where a chat server is a game you could join and friends is a room with nobody
in it. Friends is a tab of its own now, and the community section left the game
with the rest of the Discord door, per decision 73. The heading that survived
those two went as well: with one list left, a label reading "zones" over it was
the interface naming what the reader could already see.

Nothing on this page is a place outside the game any more, which is the rule
the list wanted all along: a row is how the menu writes a place inside the
game, and everything on the play page is one.

`client/arena/directory.lua` asks a directory what is running. Opening the list
asks at once, and it re-asks every three seconds for as long as the list is the
thing on screen, so a zone that comes up or goes down while somebody is reading
the page changes under them rather than sitting at whatever it was when the
page loaded.

It polls nowhere else. What is running matters while somebody is deciding
which one to join, and not at all while they are three levels away setting the
volume or ten minutes into a fight. Stopping is also what makes the next look
start with a fresh ask: without that, coming back to the list after a match
would show the fleet as it stood before the match began, and the interval would
have to elapse before that corrected itself.

What a row is called is the zone's label, and what a press on it names is the
zone's own key. They were one string, so the game a player reads and the game a
join, a rating and a kit ceiling are filed under could not differ: renaming
Melee to Team Battle would have moved all of them. A zone that sets no label
reads as its key, which is what every zone did before labels existed.

A row is a mode, not a machine. The reply lists the instances running each zone
underneath it, already ordered so the head is the fullest one that still has
room, and joining takes that head. The address is never shown. The zone's name
travels with the join, so arriving at an instance that has since changed game is
a refusal rather than a surprise.

One column: the name, with the sentence saying what the game is set under it on
the same row. It went three ways before that. Both on one line does not fit,
because "everybody against everybody" beside "5 playing, 3 AI" is 45 characters
against the 40 a phone has room for. The description then moved under the list,
as a line about whichever row was selected, which is not reading three
sentences: it is reading one at a time, a long way from the name it belongs to.
What settled it was dropping the count. How many people and how many machines
are in a room is a fact about the next thirty seconds rather than about which
game to pick, and taking it out left the row wide enough for the sentence that
explains.

The game you played last is marked and the cursor opens on it, so coming back is
one press. A zone nobody is running is still a row, because a player is better
off seeing that Chaos exists and is down than wondering whether they misread the
list.

### The landing

There is no landing page. Opening the client dials the game at the head of the
list as a watcher and draws the room, and the front end is that: the watcher's
own HUD, with the corner keys, the clock and the score, the radar and the feed,
and none of a hull's furniture. Two things are laid over the foot of it, and
they are the whole of the front end's chrome: the wordmark, and a PLAY NOW key
that takes a seat in the room already on screen.

The key breathes on the same slow swell the on-air tally uses, with its edge
floored well above dark so the trough never reads as a key that stopped
working. It is the one press this screen exists for. Enter is the same press,
because a keyboard should not have to open a menu to start the game.

**The name sits directly over the key.** It could have gone under the clock, in
the broadcast bug's slot, or into the corner the missing corner stack leaves
empty; all three were drawn, and the mocks are in `.design/spectator-landing`.
A stranger's eye ends on the pulsing thing at the foot of the screen, and the
name has to be where that look lands or the page never says what it is. Read as
one block the two are a title and its button; read apart they are a mark in a
corner nobody looks at.

Nothing else is added. Every reading a panel would carry is one the HUD
already draws, to the people in the room, in code that has to be right anyway.

The corner keeps MENU and drops TAKE SEAT. That key means the same act as PLAY NOW, and two controls for one act,
one of them pulsing at the foot of the screen and one a chip in the corner, is
the offer made twice. A pilot the room benched mid-match keeps TAKE SEAT: they
are not on the landing, and the seat being held is theirs already.

### Before a room answers

A directory lookup and a handshake stand between the engine's first frame and
the first snapshot. What is on screen for them is this same page with
everything that needs a room taken off it: the starfield, the name, and MENU.
No key, because there is nothing to join yet, and none of the instruments,
because the radar, the coordinates, the link bars and the roster are all about
a room this client has not found. They are absent rather than drawn empty.

**The name does not move.** It sits exactly where it sits once the room is
there, with the key appearing underneath it, so arriving is two things fading
in rather than the page rearranging itself. A centered lockup was tried first
and it jumped to the foot of the screen the moment a game answered, which is
the one move a hand-off should never make.

Nothing is said while it is only waiting. A couple of seconds of network is not
worth a caption, and a wordmark on a starfield is what this game looks like. A
line appears where the key will be when something has actually gone wrong: a
join that failed, or a directory that has answered and named no games. Silence
there would be a client that looks like it is still trying when it has finished
looking and found nothing.

What used to fill that gap was the menu, opened by the client rather than by
anybody, which is the one thing this whole design is against. It also meant the
first screen of a game about flying was a list.

MENU is on it because a directory that never answers must not leave a wordmark
and no way out. That is also what lets the menu always close: there is always
something behind it that has a way back in.

Which game you land in is the head of the directory's list, which is the
deployment's own first zone and is Melee. Moving the cursor down the games list
re-dials the stands to whatever it lands on, so what is on screen is always
what the key would join, and the choice outlives the menu closing.

On a phone the band takes a line of its own under the corner key rather than
sharing it. At 390 points the top right already carries the link bars and the
tile readout, and a centered band with two names on it was drawn straight
through them. It keeps the side names down there, which the old band gave up
to fit beside PLAYERS; that key is gone, so the only thing left to clear is
the dial's own corner.

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
big centered lines step aside, since they sit exactly where the menu does.

## Changing hull is a front-end act

The hull is locked for a match, so the ship page is a place you stand between
them: turn the carousel to a hull, spend your thirty points, and arrive in that
ship at the next spawn. At home the turn is the choice, since a hull there is
only what you will arrive in and turning again undoes it. In a game the turn is
a browse and the press is the choice, because there a hull is a request the
room answers and sitting out despawns you.

What the ship page saves is a kit per hull, and that is a convenience now rather
than a requirement. It used to be neither: a kit was checked against the hull's
own row, so the same thirty points bought a different ship on a Chord than on
an Anvil and the two questions could not be asked apart. The rows are gone
(see [ships.md](ships.md#the-tech-tree)), so any kit is legal on any hull, and
saving one per hull is just a place to keep the build you like flying that
shape with.

`sim_set_ship_class` still puts a pilot in a different hull in place, and the
zone protocol still carries the change, because that is how a seat is dealt
its hull when a match starts and how a watcher takes one. What went is the
row that offered it mid-fight.

The reasoning for the old rule is worth keeping, because it is why the hull
is locked at all. Changing hull in place cost exactly what dying cost: back
to your start, at rest, a full bar of the new ship, everything you had built
up gone. That priced a mid-fight swap honestly while a ship accumulated
things during a life. A kit is owned rather than accumulated, so the same
swap would now cost nothing at all, and a pilot could answer every matchup by
dying into a counter.

### The core still guards it

The zone protocol carries a hull change (`C2S_SHIP`), the server applies it
through the same core function, and the next snapshot brings back a different
ship. Nothing is predicted: a hull that flickered back would be worse than one
that arrives a frame late.

**Only at full energy, and only alive**, which the core enforces so the client
and the server hold one copy of the rule. That gate was written against
mid-fight swapping and outlives it: it is also what makes a seat dealt its
hull at a spawn well defined, since a spawn is exactly a live ship at a full
bar.

## Loading

Four megabytes of engine have to arrive and compile before the game can draw
anything. What a player saw during that was a gray progress bar on black: a page
that has not started.

Now the page starts without the engine. `client/tools/single_file.py` draws the
same starfield, same three depths, same colors, same cell hash, in plain canvas
2D, with the wordmark over it and one hairline of progress under that. When the
engine's first real frame is on screen it fades out, into the same starfield
drawn by the engine with the menu over it.

The hand-off is triggered by the game, from `arena.script`, not by the loader.
"The runtime initialized" is seconds before "there is something on screen", and
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
