# The menu

> **There is one menu.** The landing and the in-match column were the same
> drawing off two models, and this note is where they stop being two. The
> column is `ACCOUNT`, `ZONE`, `PLAYERS`, `SHIP`, `SETTINGS` over one key, in
> that order wherever it stands. Everything below that says "the landing's
> stops" or "the in-match column" is describing one half of a thing that is now
> whole.
>
> `PLAYERS` is the one stop that is not in both places. It opens the room, and
> the front page watches somebody else's game from the stands, where decision
> 108 says the instruments of a room nobody is in do not belong. So the front
> page is four stops and a room is five.
>
> The key reads where this client is sitting. No seat anywhere, on the front
> page or on a bench, and it says `PLAY` and is the way into one; a seat of
> your own and it says `SPECTATE`, hands the hull back and leaves you watching
> the room you were in from its own gallery. It is gated exactly as a ship
> change is, because it is the same act of standing a ship down, and a wounded
> pilot keeps their hull and is told why.
>
> `RESUME` is gone with it. Escape, the menu key, or a press on the glass
> beside the column are what put it away in a match, which is what a press
> beside a panel means everywhere else in this interface. At home it cannot be
> put away at all: out there the column is the screen rather than something
> over one, so it carries the lockup, washes nothing, and escape walks out of
> whatever is open and then stops.
>
> `SIDE` is gone from the column, and it came back inside `PLAYERS`. Crossing
> to another team is a thing you do about the room you are in rather than about
> yourself, so it is done from the card of somebody already on the side you
> want: a press on their row opens it, and its one key is `JOIN <side>`. See
> [decision 143](../architecture/decisions.md) and
> [decision 147](../architecture/decisions.md).

> **`PLAYERS` is the room, and the whistle raises it.** One flat list: every
> player in it, your own side first, then everyone else, then the watchers,
> each of those three by name. A row is a name in its side's color, the seat's
> mark, then the side in a `TEAM` column and what the zone counts. A watcher is
> a row like any other, reading `Watching` where a side would be.
>
> Its answer down the column is where you stand: the side you fly for, or
> `watching`. The band opens the same panel, and at the whistle the arena
> raises it the way a hand would, with one column added for what the match paid
> each pilot. Who took the match is said by the band rather than by the sheet.
> See [decision 147](../architecture/decisions.md).

> **The ship stop is in a room too, and LEAVE SEAT is gone.** The panel the
> landing opens is the panel the in-match column opens: the same five parts
> over the same purse, drawn by the same code off the same rows. A pilot who
> wants a different hull three minutes into a match gets one where they would
> look for it.
>
> What differs is what closing it means. On the front page every turn of the
> carousel and every credit is saved and sent as it happens, because out there
> it costs nothing. In a match the panel edits a draft and nothing leaves the
> client until it closes: a ship is the hull and the build together, changing
> it wants a full bar and pays a respawn, and walking the roster from an Apex
> to a Lattice would otherwise be six ship changes and six respawns. The head
> says what closing it will do while it is open, and a close the bar cannot pay
> for says so in the feed.
>
> The column is `ZONE`, `SHIP`, `SETTINGS`, `SIDE`. `LEAVE` is gone from it:
> its flying answer handed the seat back, which is a state with nothing to do
> in it, and its benched answer left the room for the stands, which is what
> picking a game off the zone stop does. The ship roster's last page was the
> same act again and went with it. Every note below about a leave stop, about
> sitting out being the page past the roster, or about the ship page being
> between matches only describes something that no longer exists. See
> [decision 136](../architecture/decisions.md).

> **The ship stop is five parts of a ship.** Body, guns, bombs, specials and
> flair, each a row that opens the part it names, with the build credits under
> the back bar on the menu and on every section. The tray is chrome the panel
> draws rather than a strip of the content, so it cannot scroll away.
>
> Body turns one ship at a time, about the axis running up the screen: the
> hull drawn the way the arena draws one, an arrow either side of it and level
> with it, the name and a line about how it flies under it, and the five rows
> one to a line below. Turning is the whole of choosing: the ship on the
> carousel is the ship you fly, so the arrows are the only control and the
> drawing under them is a place for a cursor to stand. It was a list for a
> day, which compared the seven and drew none of them. The bars take a floor,
> so the hull at the bottom of a row is a stub rather than a blank.
>
> The hull's line reads the same five bars: where this hull stands in speed,
> thrust, turn, energy and recharge, and nothing else. It was the silhouette
> while every hull flew alike, then the weapons for a day, and both of those
> stopped being the hull's. A sentence about the five drawn under it is one
> the eye can check.
>
> A section reads what it holds in the fight, in the games list's voice: the
> detail at 14 in the mute, hard against the right of the type column. The
> credits are the tray's to report. Flair is back off the settings page, and
> the level row says Level.
>
> The build everybody starts in spends all seven credits: both weapons a rung
> up, a gun off walls, a fuse, four fragments and one of each charge. So the
> purse starts empty and every arrow on the panel is dead until a pilot hands
> something back, which makes their first act deciding what to trade rather
> than finding somewhere to park a credit nobody spent for them. A hull that
> cannot reach a slot is charged nothing for it, so a Cipher arrives with the
> bomb's three in hand.

> **A column's labels are one weight.** The settings stop had its name in ink,
> because it has no answer beside it and a stop with nothing at full strength
> looked unpressable. It looked that way because the whole column was drawn at
> a third; with that fixed the ink left one white word in a column of muted
> ones. The left edge of a stop is the question column, and it is one weight
> all the way down.

> **The column is read at full strength.** It was drawn at a third of it. The
> HUD quiets every word on screen while a menu is up so the instruments behind
> it recede, and the column is drawn after that and took the dim meant for what
> it covers: the same rows as the landing's, through the same function, at 0.34
> against 1.00. A card over the column is the one case that keeps the dim,
> since the card is what is being read then.
>
> The settings page opens each section once. It drew SHIP twice, one row under
> each, because the wake and the charge keys both claimed the band.
>
> On a phone the kill line goes down under a panel, with the nameplates and
> for their reason: the gui draws over every mesh, so a panel cannot cover it,
> and a kill in the middle of a settings row loses the line and the row.

> **The column speaks the menu language too.** The settings stop wears no
> mark. It carried a gauge, drawn by the tab rail's own mark table, and a rail
> is not what this column is: it was an end of its own in a language with a
> fixed set of them, and it said the word already on the row. No stop wears a
> mark saying it opens either. Each carried a caret for two decisions, and
> since every stop opens something the mark was true of all four and told a
> hand nothing. The corner it took is the answer's now. See
> [decision 154](../architecture/decisions.md).
>
> A stop with no answer beside it puts its own name in ink. The others are a
> question at the label's weight with an answer at full strength; settings has
> a page rather than a value to answer with, so its name is the answer. A
> muted word alone on a lit box reads as a control that cannot be pressed.
>
> Every stop insets its name by the measure the panels use, and the sides list
> stands its rows at the height they do. Both were on the numbers decision 104
> replaced everywhere it looked, and it did not look here: the sides are drawn
> from the column rather than from the landing, and the language sheet draws
> panels and rows and no stops at all.

> **The drawer is gone, and settings live in the match.** There is no slide-out
> panel, no rail of tabs, no stage, no topbar and no head row with an x on it.
> What is left of the menu is a column at the foot of the screen, raised by a
> faint `MENU` key standing in the same place, holding three stops: leave,
> settings, and which side you are on, over a breathing RESUME.
>
> It is the landing's own column with different stops on it. Same width, same
> place, and the settings stop opens a panel climbing off its row exactly as
> the ship stop does at home.
>
> The key is drawn in a room you are in and nowhere else: as a pilot, or as a
> spectator who picked the room off the ship stop's last page. The front page
> carries no menu at all, because nothing the menu holds has an answer out
> there. No seat to leave, no side to be on, and the three stops over PLAY NOW
> are the choices that do have one.
>
> Settings cannot be reached anywhere else. The landing goes on saying who,
> where and what, and holds nothing about the machine.
>
> Side is a list rather than a value stepped left and right: a row per side,
> the one you fly for marked, the counts beside them, any other one press away.
>
> The key moved out of the top left corner with the panel it used to pull out
> of the left edge. It is at the bottom middle, where the column stands, so the
> press and what it raises share a spot; the column slides up out of that edge
> and RESUME settles onto the key's own pixels. It carries the word on every
> window, which the corner never had room for on a phone, and it wears no box:
> alone at the foot, a box reads as a fourth stop under the landing's three and
> as an instrument over a match.
>
> Nothing pauses. The wash behind the column is a tint, and the clock band and
> the radar keep their line, because a pilot reading settings is still being
> shot at.
>
> Every note below about a drawer, a rail, a tab row, a stage, a head row, a
> page sliding in from the right, or the menu covering a phone's whole window
> describes something that no longer exists. See
> [decision 102](../architecture/decisions.md) and `.design/game-menu`.

> **The play tab is gone, and the landing's zone stop is the games.** The
> drawer carried a page of them and the landing carried a list of them, which
> at home is the same games twice on one screen, each with its own cursor. What
> that page held besides the games moved onto the tab row: the side you are on
> is a stop, first in a room, and leaving is a stop in the slot before settings,
> going one step from wherever you are standing. Flying, it hands the seat back
> and the panel stays up; benched, it leaves the room for the stands and asks
> first. The row that decision left was ship, pilot, settings at home; the
> pilot stop went with decision 99 and the ship stop with decision 100, so
> what is left is settings at home and side, leave, settings in a room. Every note
> below about a games page, a format strip, a sweep dial on a zone nobody is
> serving, or a button hung off a row describes something that no longer
> exists. See [decision 98](../architecture/decisions.md).

> **There is no ship page.** The drawer's ship tab and every page behind it
> are gone, and so is the row of the tab set that carried them: at home the
> row is settings alone, and in a room it is leave and settings. Every note
> below about a kit, a shelf, a build library, a wallet, a price or a roster
> down a column describes something that no longer exists.
>
> What replaced it is the landing's ship stop, which opens a panel rather
> than a list: one hull at a time, paged left and right, with its flight as
> five bars against the rest of the roster, the build credits its pilot has
> spent, and the rows that spend them. A slot that only goes to one draws as
> a switch and anything you can have more of draws as a stepper, which is the
> core's own ceiling deciding rather than the page. Sitting out is the page
> past the roster. The wake and the charge-key order moved to settings, being
> preferences about a look and a keyboard rather than about how a ship
> fights. See [ships.md](ships.md) and
> [decision 100](../architecture/decisions.md).

> **Friends is gone.** The tab, the page, the add field and the band at its
> foot are out of the menu, and so are the wire and the tables behind them.
> The home row is play, ship, pilot and settings; the row a match gets is
> play and settings. Nothing in the client asks who is on or where they are
> flying. See [decision 95](../architecture/decisions.md).

> **Settings is the last stop on every row.** The home row was play, ship,
> friends, pilot and settings. Settings had been fourth of five, because the
> account stop was appended to a row that already ended with it, so the tab
> sat in one place at home and another in a match. It is the least pressed
> stop there is and the only one that is not part of the game, so it takes the
> end of the row in both, and the stop that varies with where you are standing
> takes the fourth slot: `pilot` at home, `leave` in a room. The tab bars most
> players already know either end with settings or keep it off the row
> altogether, inside the account page. Ours cannot do the second: `pilot` is
> off the row a match gets, and settings is the only route to sound and
> fullscreen on a phone mid-match. See
> [decision 83](../architecture/decisions.md).

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

> **The account is a list the landing opens, and the pilot page is gone.**
> The page carried the career over four short acts, two presses and a panel
> away from the one screen an account is worth editing on. The career is the
> site's, so what is left is the acts, and they are a list the landing's
> account stop drops in place exactly as zone and ship do: for a guest SIGN
> UP in the caution color with "keep your points" beside it, NEW NAME, a
> rule, and LOG IN; signed in, SET PASSWORD, NEW NAME, the rule, and LOG OFF.
> Signing up and claiming this account are one act and one row, because the
> server has one endpoint for it and what it does is put a password on the
> account this client already holds. The tab, the page and the call sign's
> press go with it: the name in the head stays as the label it was always
> also being. A guest with something to lose still gets the gold band in the
> drawer, "You are using a guest account. Press here to set your password.",
> and the same warning rides the account stop as a dot. See
> [decision 99](../architecture/decisions.md).

> **The account page was a stop on the rail.** The home row was play, ship,
> friends, settings and pilot: the account page as the fifth stop, wearing the
> helmet mark the interface already uses for a person, with the call sign pill
> at the far end of the top line as a second door onto it. Both are gone with
> the page (decision 99), and what the drawer carries at home is the ship and
> settings. See [decision 69](../architecture/decisions.md).

> **A game row is one press, and leaving is a button on it.** Pressing a game
> means be in that game, wherever this client happens to be: already there and
> the panel goes, anywhere else and the stands dial it and keep dialing while a
> network or an arena is down, with the panel up until a room answers. The way
> out of the game you are flying is a button at the right hand end of that
> game's own row, reached by the right arrow, and it hands the seat back rather
> than the room. The `leave` stop is off the tab row a pilot in a match gets,
> which is play and settings. See
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

> **The landing is the game now.** Opening the client seats you in the stands
> of a real melee room and draws the watcher's HUD; the front end is that
> screen with the wordmark and a pulsing PLAY NOW key over its foot. The deck
> this file describes below is gone, and so is the zone carousel that lived on
> it. What is left of the menu is a panel you open over the stands, closable
> like the one opened mid-fight. See [decision 61](../architecture/decisions.md)
> and the section
> "Behind it, the sky the game is played under", which is now literally the
> game. The reasoning below is kept where it still holds; where it describes a
> deck, the stands are what exists.

> **The split happened.** [match-game.md](match-game.md) moved the ship page,
> the upgrades and the standings out of this tree and into pages of their own,
> with settings beside them, so the front end is six tabs and help folds
> into settings with the bindings. Upgrades was one of them.
> It was folded into the ship page for a while, with the price
> of each rung written on the row that spends it, on the argument that picking
> a slot and paying for it are one act. What that produced was a panel doing
> two jobs at once: a wallet and a budget on one screen, and the word "spend"
> meaning both. They are two questions asked at different times and they are
> two stops again. It is one full-screen surface met in
> both places, differing only in which tabs it carries: in a match, play and
> settings, because nothing pauses and anything you cannot act on
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

```
vectorwake
├ ship        the roster: one row a ship, with its name and the shape it
│             presents on the first line, its flight as five bars against the
│             rest of the roster on the second, and what it flies with on the
│             third. Pressing a row flies it. Sitting out is the last row.
│             Under them, flair: the wake, and which charge key throws which
│             kind where the ship carries two. See ships.md
├ pilot       who you are and the way to keep it: the name large with a NEW
│             NAME key beside it, the career as bare totals under a ship-page
│             section rule, and the account acts at the foot. A guest gets
│             one lit SIGN UP under "Keep your points and log in on other
│             devices"; signed in, the same foot holds the password and the
│             way out
│
│             your call sign still sits at the far end of the top line and
│             opens the same page. It was the only way in for a long time,
│             on the argument that a stop repeating the name beside it said
│             it twice; what that bought was an account nobody knew they
│             had, because a name in a pill does not look like a button.
│             The stop is the door a stranger finds and the name is the one
│             a returning player knows, and it stays because it is the one
│             thing on screen saying who you are signed in as. It is drawn
│             as a button, and it is the only thing at that end of the line:
│             a Discord door stood beside it until the game stopped carrying
│             one at all, per decision 73
└ settings    sound · music · frames · fullscreen · bindings · about

in a room
├ zone        the games list, which is also the way out: picking one leaves
│             this game for the stands of the one picked, and picking the
│             game you are in is the plain leave. It costs the match either
│             way, so it asks first
├ ship        the same panel the landing's ship stop opens, over a full
│             purse. Editing it in a match is a draft: nothing reaches the
│             room until the panel closes, and closing it wants a full bar
│             and pays a respawn. See
│             [decision 136](../architecture/decisions.md)
├ settings    the same page, because sound and fullscreen are needed there
└ side        which side you are on, and the page that crosses to the other:
              one row a side, in the room's own words and colors, with the
              count of people and machines apart. Only where the room has
              named some. See teams.md
```

The two rows are the same four questions where they both have an answer. There
was no ship stop in a room and no games list either, so a pilot who wanted a
different hull three minutes in had to leave the game to get one, and getting
to another game was leave, leave, and then pick one. Both are one stop now.

`LEAVE SEAT` stood where `ZONE` does and is gone with decision 136: watching a
room you hold a seat in is a state with nothing to do in it, and it was
reachable from the ship menu as well, whose roster carried the same act on its
last page.

Five inputs, which is exactly what a d-pad has, what a phone can draw as four
arrows and a button, and what a keyboard already sends. It is two axes rather
than the stack's one, and it costs nothing on any of the three: the row is
horizontal, the page is vertical, and nothing needs a pointer. A page still
descends where it has somewhere to go, and the ship page does not: a row is
the whole of what there is to say about a ship, so there is nothing behind it
to open.

### A page you cannot stand on is not a page you can enter

The catalog and the games list arrive over the wire. Until they do, those
pages hold one line saying so, and down off the tab used to step into them
anyway: the cursor landed on a list of none, the arrows left the tab row, and
the next press did nothing anybody could see. So the step is refused while
there is nothing to stand on, silently, with the cursor left on the tab. The
stage previews the page from the tab above it either way, so the same words
are on screen; the press starts working the moment the rows arrive. A page
whose first control is a text field counts as standable even with no rows,
because the field is the whole of what that page is for.

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

The home screen's ground is the arena's own sky: three parallax layers of star
with the clouds and the band behind them, all of it drifting slowly and
diagonally because nothing is looking at anything. It is the same routine the
game draws its sky with, so the screen a stranger lands on is made of the thing
they are about to be inside.

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

Three controls used to say otherwise. One page's add key wore the
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

The week's table keeps its heading pinned and slides its rows under it,
because the heading is what every column below it is being read against. A list still follows the cursor as well,
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

## The games, and the one list of them

The drawer had a tab for them, and it was the second list of the same games:
the landing behind it already carried one under its zone stop, per decision 89.
Two lists of one thing is two cursors and two ideas of which game the stands
should show, so the tab went, per decision 98.

`client/arena/directory.lua` asks a directory what is running. Opening the
landing's zone list asks at once, and it re-asks every three seconds for as
long as that list is the thing on screen, so a zone that comes up or goes down
while somebody is reading it changes under them rather than sitting at whatever
the first ask returned.

It polls nowhere else. What is running matters while somebody is deciding which
one to join, and not at all while they are three levels away setting the volume
or ten minutes into a fight. Stopping is also what makes the next look start
with a fresh ask: without that, coming back to the list after a match would
show the fleet as it stood before the match began, and the interval would have
to elapse before that corrected itself.

What a row is called is the zone's label, and what a press on it names is the
zone's own key. They were one string, so the game a player reads and the game a
join and a rating are filed under could not differ: renaming Melee to Team
Battle would have moved all of them. A zone that sets no label reads as its
key, which is what every zone did before labels existed.

A row is a mode, not a machine. The reply lists the instances running each zone
underneath it, already ordered so the head is the fullest one that still has
room, and joining takes that head. The address is never shown. The zone's name
travels with the join, so arriving at an instance that has since changed game is
a refusal rather than a surprise.

A row is the game's name with its format under it, reading as one line: 4 v 4,
3:00. The words ride the directory reply beside the label, derived by the
catalog from what each zone declares (`ZoneDef::format`), so a tuning edit that
moves the clock moves the line and the client never knows a format. A sentence
saying what the game is held that place first and went three ways before it
landed here, and what settled it was dropping the count: how many people and how
many machines are in a room is a fact about the next thirty seconds rather than
about which game to pick. In the drawer the same words were three stacks under
the name in the room band's label-over-value grammar, per decision 82, which is
the layout that went with the page.

The game the stands are showing is marked, so coming back is one press. A zone
nobody is running is still a row, drawn a register back, because a player is
better off seeing that a game exists and is down than wondering whether they
misread the list.

### The landing

There is no landing page. Opening the client dials the game at the head of the
list as a watcher and draws the room, and the front end is that: the watcher's
own HUD, with the corner keys, the clock and the score, the radar and the feed,
and none of a hull's furniture. The front end's chrome sits over the foot of
it, in the order you would say it: the wordmark, three stops (account, zone,
ship), and a PLAY NOW key that takes a seat in the room already on screen. On a
window with the height for it that is a column, the stops at the key's own
width stacked over it; on a short one it is a rail, the stops as three cells
beside the key with the name over them.

The stops are decision 89, and they exist because the drawer went undiscovered:
a first visit met PLAY NOW and a hamburger, deployed into whatever the stands
were showing, and never learned there was another game or another ship to be. A
column row is the question at its left edge and the current answer at its
right; a rail cell sets the question over the answer. All three drop a list.
Account drops the account acts, which is the whole of that interface since
decision 99 took the pilot page: sign up or set a password, roll a new call
sign, log in or log off, with a rule between what you can do to the account
you are and how to be a different one, and a dot on the stop for a guest with
something to lose. Zone drops the
games list in place; picking one re-dials the stands to it, so the fight behind
the glass becomes the one the key would join, and PLAY NOW stays the press that
commits. Ship drops the panel that is the whole of a ship: five parts over the credits
they are bought with, with the body a carousel of the roster. A list opens upward
from the stop it belongs to, and what it covers stands down, the wordmark
included, the same way the clock band stands down under the drawer. Down the
column that is the stops above the open one; along the rail nothing stands
above an open cell, so all three stay and only the name comes off.

The key breathes on the same slow swell the on-air tally uses, with its edge
floored well above dark so the trough never reads as a key that stopped
working. It is the one press this screen exists for. Enter is the same press,
because a keyboard should not have to open a menu to start the game. It does
what the ship stop says: the hull on that stop is the hull this press flies,
since turning the carousel is the whole of choosing one.

**The shape is a question about height,** which is decision 91. A column costs
about 260 points whatever the window is: a third of a monitor, which is what it
was drawn against, and more than half of a phone held sideways. The camera
stands behind the hull the stands are watching, so the middle of the screen is
that hull, and a column that tall on a short window is drawn across it. At 844
by 390 the wordmark landed on the ship and the account stop on its call sign.
Where the column would climb that far the same pieces lie down into the rail,
which is the direction the column beat for the upright case: a cell carries its
question over its answer, so three cells and the key fit one line, and where
that line is wider than the window the cells take a line of their own over the
key, which is what a 320 point screen gets. Nothing about what a stop is or
what pressing it does changes with the shape.

**The name sits directly over the block.** It could have gone under the
clock, in the broadcast bug's slot, or into the corner the missing corner
stack leaves empty; all three were drawn, and the mocks are in
`.design/spectator-landing`. A stranger's eye ends on the pulsing thing at the
foot of the screen, climbs the stops, and the name has to be where that look
ends or the page never says what it is. The stops' own directions, a column
against a rail along the foot and a line of pressable words, are drawn in
`.design/start-flow`; the column won the question and the rail came back for
the windows it does not fit.

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
No key and no stops, because there is nothing to join yet, and none of the
instruments, because the radar, the coordinates, the link bars and the roster
are all about a room this client has not found. They are absent rather than
drawn empty.

**The name does not move.** It sits exactly where it sits once the room is
there, with the stops and the key appearing underneath it, so arriving is the
column fading in rather than the page rearranging itself. A centered lockup
was tried first and it jumped to the foot of the screen the moment a game
answered, which is the one move a hand-off should never make.

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

The band shares the corner key's line at every window size, including a phone's
390 points. It took a line of its own down there for a while, because the top
right carries the dial's two readouts and a centered band with two call signs
on it was drawn straight through them. The line under the row is where the dial
itself is, though, so dropping bought the same collision against a bigger
instrument and cost the row the one alignment it is for. What gives instead is
the names. A band with nowhere left to grow drops both of them and keeps the
two figures, which are the reading; the names are on the board a press opens.

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

## Changing ship is a front-end act

A ship is locked for a match, so the ship page is a place you stand between
them: press a row and arrive in that ship at the next spawn. At home the press
is the whole choice, since a ship there is only what you will arrive in and
pressing another undoes it. In a game it is a request the room answers, and
sitting out despawns you.

There is one thing to remember per hull, and it is not a build: which of the
two charge keys throws which kind. That is a preference about a keyboard rather
than a fact about a ship, so it lives on the device beside the bindings.

`sim_set_ship_class` still puts a pilot in a different hull in place, and the
zone protocol still carries the change, because that is how a seat is dealt
its hull when a match starts and how a watcher takes one. What went is the
row that offered it mid-fight.

The reasoning for the old rule is worth keeping, because it is why a ship is
locked at all. Changing hull in place cost exactly what dying cost: back to
your start, at rest, a full bar of the new ship, everything you had built up
gone. That priced a mid-fight swap honestly while a ship accumulated things
during a life. A ship comes back whole now, so the same swap would cost
nothing at all, and a pilot could answer every matchup by dying into a
counter.

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
stars, same three depths, same density, same four temperatures, same cell hash,
in plain canvas 2D, with the wordmark over it and one hairline of progress under
that. When the engine's first real frame is on screen it fades out, into the
same sky drawn by the engine with the menu over it. What the loader does not
draw is everything behind the stars, the clouds and the band, which arrive with
that first frame.

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
