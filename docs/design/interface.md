# The design language

What every screen of this game is built from: the colors, the two typefaces,
the handful of shapes, the drawn marks, the layout, what moves, and how the
interface talks. It was written by surveying every menu page and the whole of
the flight HUD as they exist in `client/arena/`, and checked against the
running client itself, every tab and the live arena screenshotted against a
local fleet, so each rule here is one the shipped drawing already follows and
says why. [identity.md](identity.md) sets the art
direction this serves; [menu.md](menu.md) describes the menu's structure and
behavior; this is the visual and verbal grammar both are drawn in.

The enforcement is the code. `client/arena/palette.lua` is the one copy of
every color, `client/arena/ui.lua` draws the HUD and every menu page,
`client/arena/marks.lua` holds the drawings two surfaces share, and
`client/arena/menu.lua` decides what the pages say. A rule that exists only in
this file is a rule waiting to be broken, so where one matters it lives in a
shared function and this document points at it.

## One interface, two voices

There are two surfaces and they are read differently. The HUD is glanced at,
mid-fight, out of the corner of an eye. The menu is read, parked, between
matches. Everything else in this document follows from that split.

The HUD speaks in capitals, because capitals are the case an instrument is
labeled in: MENU, PILOTS, STREAK, DESTROYED. The menu speaks in a
sentence's case, one capital at the front of a line and nothing else, because
a page of capitals is a page nobody reads twice. The switch is made in one
place (`cased` in ui.lua), set by whichever surface is drawing, never written
into the strings themselves: case is how a thing is set, not what it says.

Three kinds of string opt out of both voices, and they are quoted rather than
said. A name keeps the case its owner gave it, everywhere: a call sign on a
nameplate, a side's name on the team list, a hull spelled the way the roster
spells it, a zone spelled the way the catalog spells it (Team Battle, never
team battle). And no line is set all lower case: a sentence opens on a
capital wherever it is drawn, per Chris. A reading off a machine is verbatim: a key cap, a build number, a
URL. And the feed sets its lines in lower case with names as the only
capitals, because "OZONE KILLED KESTREL" is an announcement and the feed
reports things that happened to people.

The same split decides what each surface is made of. The HUD is marks and
counts, words an ask away (the hover card, the H table). The menu is words,
with marks confirming them. A corner read in a tenth of a second cannot be a
column of reading, and a settings page read once a week does not need to be
memorized as pictograms.

## Color

The palette is `client/arena/palette.lua` and nothing else declares a color.
The values came from the hand-written web prototype and survived it, so the
game kept the look it had already been seen in.

The ground and the ink:

| name | value | what it is |
|---|---|---|
| BG | `#05070c` | the field. Near black, never pure black |
| INK | `#dfe9f5` | what the interface says |
| DIM | `#6c7a90` | what it says more quietly: labels, captions, the unpressable |
| PANEL_INK | `#9fb6d4` | prose inside a card, and a hull's interior lines |

The two-color read, which is the most important rule in the game:

| name | value | what it is |
|---|---|---|
| FRIEND | `#4fd6ff` | yours |
| ENEMY | `#ffa552` | not yours |

Hulls, plates, radar blips, the match score, the vignette's opposite: a thing
that is glanced at carries one of these two and only these two. They are
separated by hue and by luminance both, so the distinction survives colorblind
vision. Cyan is also the interface's own accent, because "the thing you are
on" and "yours" are the same statement: the cursor's wash, a lit tab, a
pressed key, the caret, your own row on every table.

Which side an enemy belongs to is a slower question, so it is answered in
text. Names and the panels that talk about people wear a color generated from
the team byte: a golden-angle walk around the hue wheel with the cyan arc
fenced off (no side is ever issued a cyan), three saturation steps so near
hues still separate, and a luminance floor so no side is dealt a color that
vanishes on black. Every client derives the same color from the same byte with
nothing sent to agree on it.

Past those, a hue means one thing, one thing per hue, across every screen:

| band | value | means |
|---|---|---|
| pink | `#ff5ea8` | the bomb |
| violet | `#c27bff`, `#a06bff` | a place, not a player: the burst's rounds, a wormhole |
| green | `#35e0a0` | a door (the open state is a darker step of the same band) |
| pale green | `#8dffb0` | what you were paid, and `#5aa874` a step down from it for a kill you only helped with |
| gold | `#ffd166` | a charge you carry and spend |
| deep gold | `#ffe08a` | a pilot on a streak, on the hull and in the feed |
| red | `#ff505a` | you are being hurt, or about to lose something |
| slate | `#3f5878` | structure: rules, panel edges, terrain on the dial |

A round's rung is the one scale nobody has to be taught, green, yellow,
orange, red (`#62cc35 #f7dd0b #ff7000 #f42e3d`), one ramp for every weapon and
every owner. What that ramp gives up is deliberate: a round no longer says
whose it is, and in the 4v4 game that is a real price, since the core never
lands a teammate's bullet and a friendly stream is a flinch the paint asks
for. Decision 55 re-made the call on the live facts and kept the ramp: a
three-pixel round has room for one reading and the rung is the one that says
what a hit costs, bomb blasts hurt everyone in radius whoever threw them, and
the team already lives on the hull and the plate.

Two rules keep this system honest. First, before a new thing gets a color,
check what already owns the nearest hue; the doors are green because pink
belongs to the bomb, orange to a team, and a door wearing either is a door
somebody misreads under fire. Second, a color is never decoration. The logo's
hotter orange and cyan are held apart in the palette under their own names,
so the brand mark cannot drift into the colors pilots identify sides by.

## Type

Two faces, and the split is the two voices again.

**The mono** is DejaVu Sans Mono, the face everything in flight is set in and
the face of every number, count and machine reading in the menu. The HUD's
base size is 13 points on an 18 point line. Its advance is one number,
1233/2048 of the size, and `text_w` uses it.

**The menu face** is proportional, and it is what the menu sets names and prose
in. Its advances are read out of the font file itself and generated into
`client/arena/menu_face.lua` by `client/tools/font_advances.py`, because
measuring it with the mono's number runs about a fifth long and puts carets
past the ends of names. Nothing measures type by guessing, `wrapped` included:
it takes the face it is breaking lines for.

The rule for choosing between them is one question. Would you read it aloud as
a sentence, or look it up in a column? Language takes the menu face, values take
the mono. A row's label is menu face; the count at the end of it is mono. A call
sign in the roster is menu face because it is being read as a name; the same
call sign beside a nameplate in flight is mono because everything in flight is.
A key in the menu is a word you read before you press it and takes the menu face
in a sentence's case; a key in the corner is an instrument label and stays upper
case mono.

That rule is not new and was followed in one place. Every sentence in the menu
was set in mono at 11.5 points until the type pass, which is what a paragraph
without a test is worth. Moving them cost almost nothing in width: weighted by
English letter frequency the menu face sets at 0.511 em against the mono's
0.602, so 14 points of it runs as wide as 11.9 points of mono.

### The ladder

Five sizes, in points, in `TYPE` in ui.lua:

| | pt | what it sets |
| --- | --- | --- |
| `LABEL` | 12 | the upper case register that names a group or a column of figures, and a chip in a dense bar |
| `BODY` | 14 | everything small being read: a sentence, a detail, a price, a word in a button, a tab |
| `ROW` | 17 | a name in a list |
| `LEAD` | 21 | the same name where it heads a sentence or a strip of figures |
| `PAGE` | 26 | what a page calls itself |

There were fifteen, near enough all of them bare numbers at the call site, with
four fifths of a page at 13 points or under. The gap from `LABEL` to `BODY` is
smaller than the rest of the ladder because upper case reads larger than lower
at the same size.

The menu no longer scales itself. It did while it was a drawer that owned the
whole window on a phone and a third of one on a desk: `MENU_SCALE`, 1.25, grew
its rows, gaps, marks and column together on anything not `M.compact`. The
column is the landing's column, laid out at the same width on every window and
sized by the same rules, so there is nothing left to zoom. See
[decision 102](../architecture/decisions.md).

### The inks

Text draws at alpha 1. State says itself with a color: a register brighter under
the cursor, team blue where you already are, a register back where you cannot
press.

| | hex | on the column | what it sets |
| --- | --- | --- | --- |
| `INK` | `#dfe9f5` | 16.59 | names, titles, the thing you came to read |
| `READ` | `#9fb6d4` | 9.81 | sentences, details, values |
| `MUTE` | `#8593a9` | 6.54 | the caps that name a group, and anything unavailable |
| `FRIEND` | `#4fd6ff` | 12.01 | where you are, what is on |
| `CHARGE_COL` | `#ffd166` | 14.12 | a warning, and what you have typed into a field |
| `HURT` | `#ff505a` | 6.35 | an error |

The ground is the column's own: `0x03050a` at 0.86 over the arena. Two other
grounds matter, since a row can be lit, and every one of these clears 4.5:1 on
all three. The worst number in the menu is 4.61.

`pal.DIM` is why the rule is stated as alpha 1 rather than as a habit. It is
worth 4.68:1 on the column at full alpha, so it clears the 4.5 small type wants
with nothing left over and cannot survive being drawn on a lit row at all.
Thirty-three call sites passed it a fraction anyway, and a third of the type in
the menu went under the line: a tab row at 3.33, a games row's own figures at
1.97 before decision 98 took that page, a field's own placeholder at 1.94,
which is the box telling you what to type. Each of those was defensible on its
own line. The number that condemned them is a function of the color, the alpha
and the ground three files apart, which is why `client/tests/type_test.lua`
exists and this paragraph is not enough on its own.

One alpha is left on type: `LIT.breath` on the row you are standing on, which
rides on a name at full ink and floors at 0.74, worth 9.2:1 at the bottom of the
curve.

A control's outline is the other thing with a number to hit, since a boundary is
what says a control is there. `pal.KEY_EDGE` at `#55708f` is 3.97:1 on the
column, against the 3:1 non-text contrast asks. Rules between rows and divisions
inside a panel keep `BORDER` and have nothing to find.

## Shape

The interface owns a small number of shapes and each one means one thing.

**A button is a stroked box**: a rectangle outlined all the way round with a
wash inside it (`key_box`). It is what a card's answers wear, what the help
board draws a key as, and what the corner chips wear, so a hand that has
learned one has learned all of them. The `MENU` key at the foot is the one
exception, and it is the exception because it stands alone: a box down there
joins the column above it or the instruments across the top, depending which
screen you are on. Its three bars do the work the box would. On or off is one rule
everywhere: lit in cyan with a stronger wash when active, dim otherwise.

**The chamfered bracket holds everything that is not a button**: a field, a
card, a panel, a cluster. Four cut corners and nothing between them
(`bracket`). The two shapes together say which kind of rectangle you are
looking at, which is more than either said when buttons came in three shapes.
The one licensed exception is the controls page's reset row, which keeps the
bracket because it sits beside a drawn keyboard, and a stroked box there
reads as a key.

**A border is the shape this game does not contain.** A panel is a
translucent wash of the field color with a lit rule down its left edge, the
light spilling off it (`vrule`), which is a wall face stood on end: the same
construction as everything solid in the arena, dark in the body and lit at
the edge. No frames around pages, no boxes around lists, no chrome around the
feed. Where type must sit on something mid-screen, it gets a wash the width
of the words, never an outline.

**The chamfer is the house diagonal.** Walls cut their corners with it, the
bracket cuts its corners with it, the close mark is four spokes cut away from
a void by it, the pointer's heel is cut by it. One angle, recurring, is what
makes disparate marks read as one set.

**Selection is a wash**: a translucent cyan field across the whole of what is
selected, a shade brighter where it meets its rule, plus a brightened rule
segment (`wash`). Your own row on a table wears it in cyan; a row being read
about wears it in the deep gold. Never a glyph in front of the name, never a
box around the row. A cursor and a hover are the same mark at two weights,
because they are the same fact reported by two hands.

**Rules come in two weights.** Inside the menu, a plain hairline in the
structural slate (`hrule`) sits over a group of rows with a small dim label
on it. The ticked rule (`ticks`), a hairline with short teeth, belongs to the
map border and to the scoreboard's heading; five of them down a page read as
texture, so the menu does not use them between groups.

**Counts are marks, not numerals**, wherever the count is small enough to
read as a shape. Charges are pips: filled discs for what you hold, rings for
the empty places. A range too long to count, like where a hull stands on a
flight row against the rest of the roster, is a bar. A switch you throw is a
chip: a small stroked box with its word inside, on or off, lit when held.

**Everything that points is drawn.** Sort order is a triangle, never a caret
character or a letter v. The wake stepper's arrows, the week stepper, the back
caret on a page a phone has drilled into, the "you are here" wedge in a row's
gutter, the watching play-mark, the board's arrow keys: all triangles from
the mesh layer, weighted like the line work around them. A "<" set in type is
a picture of a mathematical symbol, not of going back. The gui font's glyphs
never stand in for marks, which is also why close is four drawn spokes and
not the letter x.

## Marks

Every mark is a picture of the thing, not a symbol somebody has to learn.
The rail's settings stop is a gauge off the panel in front of you, dark in the
body and lit at the rim with a needle up among its graduations, because that
stop is the one thing on the row about the machine rather than the match; leave
is a doorway with the arrow going out the open side. The ship stop is the hull
you are flying, drawn as itself. Play was a world with a ring around it, for as
long as the menu carried the games.

A drawing that appears in two places is one function. The weapon marks live
in `marks.lua` because the corner stack and the touch pads both draw them,
and two copies once disagreed about which add-ons a hull was wearing. The
pennant is the same pennant on the radar, in the flag strip, and on the team
mark. The helmet and the machine, a person and a bot, are the same pair in
the games list, the scoreboard, and the nameplates: a round crowned shell with a wrapped visor against a squared shell with two lamps and
an antenna. Curved is grown, boxed is built, and that difference survives
being drawn at eleven points.

Stroke weight has one rule with one exception. A mark's pen comes off its own
size with a floor (`marks.pen`: a ratio of the mark, never under about a
pixel), so a mark drawn twice as large is drawn twice as heavy and a small
one never loses its hairlines. The exception is a set: the menu rail's marks
and the hull thumbnails hold one line weight against the screen
(`RAIL_PEN`, `HULL_PEN`), because a column of six marks in six sizes of line
reads as six styles. Anything that draws itself into such a set has to be
told the set's weight. The floor bites hardest on hard edges: a segment's
edges carry falloff and survive under a pixel, a stroked box's do not, so the
layer floors a frame's stroke at one device pixel (`vec.lua`), after the
podium's chips, stroked at 0.9 on a density-1 screen, drew three edges each
and lost their tops.

There was a currency and it had a mark: the rivet, a fastener seen from the
side with two strikes through it, standing in front of every price and under
every nameplate. Nothing is bought now and the mark is gone with the wallet.
It is worth keeping the rule it demonstrated, because the next currency will
need it: a unit is a glyph, never a word, and a glyph struck through twice is
what reads as money.

The wordmark is the drawn logo (an orange lambda and a cyan W sharing a
chevron, black separator derived from one centerline) beside the name in the
menu face, mark at 0.74 em, dropped 0.12 em to sit on the word's optical
middle. Nothing under it: a decorative stroke was tried and removed, because
it was decoration in an interface that has none anywhere else.

## Layout

Everything is measured in points, device pixels divided by density, because a
phone at two pixels per point is a small screen and laying out against pixels
draws the interface at half size on the machine that most needs it readable.

The constants that repeat, from ui.lua:

| name | value | what it measures |
|---|---|---|
| PAD | 14 | the margin instruments keep from the screen edge |
| COL_W | 248 | the left column's panels: scoreboard, run log, pilot box |
| LINE | 18 | one row of a HUD list |
| RADAR | 168 | the dial's side at rest |
| GUTTER | 22 | the inset a menu row's type keeps from both of its edges |
| ROW_PAD | 16 | how far a lit row reaches past its column of type |
| KEY_H | 26 | a button's height |

The HUD has a fixed geography, and it is the prototype's. Top left: the chip
row (TAKE SEAT, ROOM, the on-air or watching chip) and the rooms panel under
it, all of which come and go, so in an ordinary match that corner is the fight.
Bottom middle: the faint `MENU` key, and the column it raises, in a room you
are in and nowhere else. Top left held MENU until decision 102 moved it to the
foot, where the panel it opens stands; the front page carries neither, since
the menu is about a room you have taken a seat in.
Top right: the radar or the map (one corner, one instrument), with the feed
hanging under it. The radar is hard into the corner at the same PAD the button
row keeps from the other one; the map, which is two thirds of the window's
short side and reaches past the middle of an upright phone, starts on the line
under the row instead. Nothing is captioned up there. The instrument draws
where you are, and a pair of tile numbers beside it was the same fact in the
form nobody reads. Bottom left: the corner stack, what your triggers do and
what you carry, growing upward.

The corner and the board belong to a room you are in, the way the key at the
foot does. The front page has neither: no dial, and a band that opens nothing.
A radar answers what is near you and there is no you out there, and a roster is
the list of a room somebody is standing outside of. The whistle is the same
rule, since the ending is that board with a head over it, so on the front page
a finished match is a word under the clock and the fight carrying on behind
the name. What the band keeps either way is the clock and both scores, which
are the fight reading out rather than an instrument about a seat.

The top of that geography is a row with an instrument at each end. The corner
key and the band share one center, a key's height is what that center is taken
from, and the band grows outward from the middle until it reaches the key on
one side or the dial on the other. Anything up there that works its own
vertical out of the padding drifts, because the padding is a horizontal
measurement.

A band with nowhere left to grow gives up the two side names rather than the
line it stands on, and gives up both or neither: the row's ends are a small
key and a square a third of a phone across, so measuring each name against the
end it happens to face drew one and dropped the other. An upright phone is the
window that runs out, and reads as the clock with a figure either side of it.
The names are on the board a press on the band opens.

The match ending is the board again rather than a page of its own: at the
whistle it comes up whether or not anybody asked for it, in a column of its
own up to 720 points wide, with a line saying who took the match, a bar under
that carrying each side's name inside its own share of it, and a foot with the
countdown and one key. The same arrangement at every window size; an upright
phone hugs the foot of the screen with it, so the key lands under a thumb.
The band stands down while it is up, since the head carries the score and the
foot carries the clock.

Top center is the band: the clock, with a side either side of it as a name
over a number, a team over its score, the two lines of a side adding up to the
clock's own height so the whole
thing reads as one line. The clock is one key tall, the same at every window
size, so the band and the way into the menu are the same height and the top
row reads as a row. Under it, the flag pennants and whatever the room
has to say. The band is also the control, in a room you are in: a press opens
the board under it, which is the roster, then the pilot box a row was pressed
on. While that board is up the fight behind it is washed and every other
instrument's type recedes, because the board is the thing being read. Dead
center is reserved for the big statements, DESTROYED and SAFE ZONE, and for
the cards and tables a player asks for. On a touchscreen the bottom of the
screen belongs to the thumbs and everything else lifts out of their way.

Panels in the left column size themselves to their content, count their rows,
and measure their columns against the widest thing actually in them, headed
by that column's label; fixed offsets do not survive four numeric columns in
248 points. A scrollbar appears only when there is something to scroll to,
as a thin slate thumb on the panel's right edge.

The menu is a tab row over a page. The layout asks two questions about the
window, not one. Width decides where the tabs go: under 620 points they are
a bar along the bottom edge where a thumb reaches, above it a row across the
top beside the wordmark, bounded at the far end by the account button. Height decides how much room there is to spend: under 500 points
the type zoom comes off and the margins pull in, which is what a phone held
sideways needs. The HUD's own compact flag trips when the scarce axis drops
under 480 points, and it drops panels rather than shrinking type, because
one column of 248 always fits and smaller type on a phone fits less.

Pages scroll in pixels, whole rows only. Type comes from the gui, which
draws over every mesh, so nothing behind a heading can cover a row that has
slid under it; what a row does at the edge is appear whole or not at all.
The thing a page is spent against stays pinned: the ship panel's head, with
the hull and the credits it has left, and the week's heading. That rule is
what a short window relies on. The panel is the same panel at every shape,
and a landscape phone that cannot hold it scrolls the rows under a head that
stays put, rather than growing a second layout of its own.

## Motion

Almost nothing moves on its own, so the things that do are a complete list:
the hull under the cursor turns (one turning ship is the one you are looking
at, answering; eight revolving is a screensaver), the logo turns at the same
rate, the sweep dial sweeps where something is being looked for, the help
prompt breathes once every three seconds, the on-air dot swells slowly
because a blink held for minutes is a blink a player learns to stop seeing,
an arming bind slot pulses, the ending's score bar arrives over a third of a
second, eased, and it is the one movement on that screen. Feed lines spend
their last second and a half leaving; a payout drifts off the wreck that
paid it, anchored in the world so it falls behind a moving player the way
the wreck does.

The rules under that list: motion marks the thing being read or the thing
being waited for, never decorates, and one surface gets one movement. Fast
blinking does not exist. Where a state must hold attention for a long time it
swells rather than flashes.

## Depth

Nothing pauses, and the layering says so. The menu is a scrim, not a
curtain: 0.6 over the home starfield, 0.78 over a live game (a game is more
to read through than stars), a shade heavier on a phone. The instruments
stay up underneath at a third of their light, because you can be shot while
you read, and a glance at your energy is still worth taking; nameplates
alone come down, because glyphs draw over every mesh and six names shining
through a panel read as a fault. A card dims the world the same way and
drops every hit box published before it, so a question is answered, not
clicked past.

Nameplates come down for every panel that stands over the arena, not just for
the menu's. The landing is the case that says why: it is a live room with the
column laid over it, and the ship stop opens a panel climbing from its own
stop to the top of the window. Every call sign in the fight behind it read
through the build in front of it until the rule was written as "something is
being read over the arena" rather than as "the menu is open".

That gui-over-mesh constraint is load-bearing everywhere: the only way to
quiet a label is to quiet the label (`text_dim`), a wash can never do it. It
is why rows draw whole or not at all, and why the ending takes the
nameplates down with it for the twenty five seconds it is up.

Text is also a budget. The gui draws `TEXT_POOL` strings a frame (declared in
`state.lua`, where the side that writes them can be tested against it) and
drops the rest, so the worst frame the interface composes, the ending with
its roster and the pilot box open, is measured against the budget in
podium_test, and the debug readout shows the count beside the mesh layers'
own. The pool was once a number only the gui knew, at 128, and the podium's
phrase chips queued past it: their boxes drew and their words did not, and
nothing anywhere said so.

## Words

The interface says a thing once, in one place, and mostly in one sentence.

No captions. A row says what it has to say on the row; a sentence that
restates the row it sits under is read once and is furniture forever after.
The one line at the foot of a page is reserved for something that just
happened: why a join failed, where a binding landed. Section labels are the
small dim mono line over a hairline, and they say what a group of rows is
about, which is the one thing a page title cannot.

States are honest and specific. An empty page is the sweep dial plus two
lines: what happened, then what happens next ("nobody has played this week
yet" / "the table resets on Monday"). A request in flight says "asking", not
nothing, and never blames the player for a filter that matched nobody. A
refusal names the rule and the way out: "two charges at a time: take one off
to fit another". Waiting rows keep their place in the list with the dial
beside them, because a player is better off seeing that Chaos exists and is
down than wondering whether they misread the list.

Numbers are shown as the shape of the thing where they can be: a volume is
lit steps, not the word "half"; where a hull stands on a flight row is a bar
against the rest of the roster, not a figure in the core's units. Where a number must be words it comes with its noun ("4 playing, 3 AI",
spelled out rather than "4/3"). Addresses, wire URLs, and the client's own
diagnostics never reach a player's screen; the debug readout exists, deliberately
plain, behind the LINK bars.

## Pressing things

Five inputs drive everything: up, down, left, right, enter. That is a d-pad,
four drawn arrows and a button on glass, and what a keyboard already sends.
Left and right walk the tab row and set a row's value; down enters the page;
a grid is the one place arrows mean rows and columns. A pointer is additive:
resting on a row moves the same cursor the arrows move, and lights it the
same way.

The landing answers the same hands. Its stops and its key are a page of rows
with no panel around them, so up and down walk them in the order they are
said and enter presses what the cursor is on, opening a stop's list and then
walking that. Enter with nothing lit is PLAY NOW, because a keyboard that had
to walk to it would be a front page nobody can start the game from. Left and
right are not read out there: there is no tab row and no row with a value to
set, which is the work those two do inside the panel.

Hit boxes are rectangles resolved by one function, `ui.pick`, which the press
path, the hover pass and the tests all ask. Containment decides by rank:
a backdrop (a panel's ground, the screen-wide box that shuts the menu)
declares itself behind everything with a negative priority, and among equals
publish order breaks the tie, which is how a pip beats its row and a close
mark beats the button it sits in. The field of play publishes no boxes at
all, because the left button is the gun and a box over a hull would eat the
shot at the moment a player is lined up on somebody.

The touch floor is declared, 44 points (`ui.TARGET`), which is what every
platform's own ruler says a fingertip is. Controls keep the shapes the design
gives them, and the resolver makes up the difference: on glass, a press that
missed everything reaches the nearest control within the floor, so a
26-point button answers a 44-point finger without drawing like one, and
between two pips the nearer one wins. A corner target still runs into its
corner, where a thumb cannot overshoot off the screen.

Anything destructive or costly asks first, on a card that states the cost in
its note ("MOVING RESPAWNS YOU"), and the last answer is always the one that
changes nothing, which is what escape gives.

## The HUD's own rules

The corner stack is the model of the whole surface: rows of marks and
counts, no panel, no rules between rows, the color separation doing the
grouping (what a trigger does is drawn in its round's rung color, what you
carry is gold). Two numbers are not in it, and for the same reason: the
corner is what a press changes. Energy is not, because your own hull carries
the same pip every hull carries and a corner bar was the same number twice in
the place you least look. Your rating is not, because it is what other people
see when they look at you rather than anything you can act on, and the podium
says what a match did to it. Damage is the vignette, red creeping in from the
edges, which never hides the ship shooting you. The words for any row are an
ask away: rest the pointer and a card names it, says what it does, and says
which key spends it.

Panels appear because they were asked for. The scoreboard is a toggle, and
the run log comes up with it; the pilot box opens from a scoreboard row and
closes with the scoreboard; the map replaces the radar in its own corner and
the same click puts it back. What was not asked for stays off, and what
cannot be used is not drawn: a scrollbar on a list that fits, a spent
charge's row, empty charge slots.

On a phone, the pads carry the weapon marks themselves, so the stack stands
down to nothing and the feed becomes a short toast in the empty band of the
screen, far from the thumbs: one line at a time, and only lines about you,
except that a streak line shows whoever it names, since who the room goes
after next is news every pilot steers by.

## Where this lives

| file | carries |
|---|---|
| `client/arena/palette.lua` | every color, the team generator, the rung ramp |
| `client/arena/ui.lua` | the HUD, every menu page, the primitives (`key_box`, `bracket`, `wash`, `vrule`, `pips`) |
| `client/arena/marks.lua` | the drawings shared with the touch pads, and `pen` |
| `client/arena/menu.lua` | the pages' contents and words |
| `client/arena/menu_face.lua` | the menu face's measured advances (generated) |
| `client/arena/touch.lua` | the thumb controls, drawing the shared marks |
| `.design/rethink/` | the mocks several of these pages were redrawn to |

The mocks are where the language was last argued about in pictures; when a
page and its mock disagree, one of them is wrong on purpose and the reason
should be findable in a commit or in this file.
