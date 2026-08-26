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
labeled in: LINK, POS, MENU, PILOTS, DESTROYED. The menu speaks in a
sentence's case, one capital at the front of a line and nothing else, because
a page of capitals is a page nobody reads twice. The switch is made in one
place (`cased` in ui.lua), set by whichever surface is drawing, never written
into the strings themselves: case is how a thing is set, not what it says.

Three kinds of string opt out of both voices, and they are quoted rather than
said. A name keeps the case its owner gave it, everywhere: a call sign on a
nameplate, a side's name on the team list, a hull spelled the way the shop
spells it. A reading off a machine is verbatim: a key cap, a build number, a
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
| gold | `#ffd166` | a charge you carry and spend, and a price you can afford |
| deep gold | `#ffe08a` | bounty: what a pilot is worth |
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
the face of every number, key cap, count, and machine reading in the menu.
The HUD's base size is 13 points on an 18 point line; small labels step down
from there (the group label is 9 points, upper case, dim). Its advance is one
number, 1233/2048 of the size, and `text_w` uses it.

**The menu face** is proportional, and it is what the menu sets names and
prose in: tab words, page rows at 15 to 21 points, the podium's headline, the
wordmark. Its advances are read out of the font file itself and generated
into `client/arena/menu_face.lua` by `client/tools/font_advances.py`, because
measuring it with the mono's number runs about a fifth long and puts carets
past the ends of names. Nothing measures type by guessing.

The rule for choosing between them: data is mono, things being read are the
menu face. A row's label is menu face; the count at the end of it is mono. A
call sign in the roster is menu face because it is being read as a name; the
same call sign beside a nameplate in flight is mono because everything in
flight is.

Ten points is the floor for authored type, the small label register included
(`LBL_PX` in ui.lua), and dim labels at that size draw at DIM's full alpha:
nine-point dim mono at nine tenths of itself measured about 3.9:1 against the
field, under the 4.5:1 small type wants, on the labels that name every group.
The only type below the floor is squeezed there by a window too small for the
authored size, where the alternative is overlap.

The menu sets its type 1.18 larger than the HUD on a desktop window
(`MENU_ZOOM`), and not on a phone or a short window, which are already showing
as much as they can. The zoom is applied to the whole scale, not the type
alone, so rows, gaps, and marks grow together and nothing drifts out of
alignment.

## Shape

The interface owns a small number of shapes and each one means one thing.

**A button is a stroked box**: a rectangle outlined all the way round with a
wash inside it (`key_box`). It is what MENU wears in the corner, what a
card's answers wear, what the help board draws a key as, so a hand
that has learned one has learned all of them. On or off is one rule
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
about wears it in bounty gold. Never a glyph in front of the name, never a
box around the row. A cursor and a hover are the same mark at two weights,
because they are the same fact reported by two hands.

**Rules come in two weights.** Inside the menu, a plain hairline in the
structural slate (`hrule`) sits over a group of rows with a small dim label
on it. The ticked rule (`ticks`), a hairline with short teeth, belongs to the
map border and to the scoreboard's heading; five of them down a page read as
texture, so the menu does not use them between groups.

**Counts are marks, not numerals**, wherever the count is small enough to
read as a shape. Charges are pips: filled discs for what you hold, rings for
the empty places. Kit ladders are diamonds, filled where spent, outlined
where a step remains, because a row of squares is a progress bar and a kit is
not progress, it is choices out of a budget. A range too long to count (the
thirty-point budget) is a bar. A switch you throw is a chip: a small stroked
box with its word inside, on or off, lit when held.

**Everything that points is drawn.** Sort order is a triangle, never a caret
character or a letter v. The carousel's arrows, the week stepper, the back
caret on a page a phone has drilled into, the "you are here" wedge in a row's
gutter, the watching play-mark, the board's arrow keys: all triangles from
the mesh layer, weighted like the line work around them. A "<" set in type is
a picture of a mathematical symbol, not of going back. The gui font's glyphs
never stand in for marks, which is also why close is four drawn spokes and
not the letter x.

## Marks

Every mark is a picture of the thing, not a symbol somebody has to learn.
The rail's play stop is a world with a ring around it; settings is three
sliders at three different positions, because a row of identical sliders is a
picture of nothing being adjustable; leave is a doorway with the arrow going
out the open side; friends is two helmets, one behind the other. The ship stop
is the hull you are flying, drawn as itself. When a mark cannot be a picture of
its object it is
the object's own instrument: upgrades is the rivet, the mark that stands in
front of every price.

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

The rivet deserves its own note because it is the currency. It is the
fastener seen from the side, cap, shank, two strikes through, following the
convention that a glyph struck through reads as money. Two strikes rather
than one because one bar through a shape is a "no entry" sign, and seen from
the side because face-on the bars closed up at price sizes and became exactly
that sign. A price is always the mark plus the figure, sized to the figure;
"40 rivets" in words was a word doing a glyph's job. The arena is not an
exception. The bounty under a nameplate is what killing that hull pays, so it
is set as a price like any other, and the mark is what tells it apart from the
kills, deaths and points that are drawn as bare figures elsewhere.

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

The HUD has a fixed geography, and it is the prototype's. Top left: the button
row (MENU, ROOM, the on-air or watching chip) and the rooms panel under it.
Top right: the LINK bars, then the radar or the map (one corner, one
instrument), with POS on the dial's other shoulder and the feed hanging under
it. Bottom left: the corner stack, what your triggers do and what you carry,
growing upward.

The top of that geography is a row, and everything standing in it shares one
center: the corner key at the left, the band in the middle where there is room
for it, and the LINK and POS readouts at the right. A key's height is what the
row takes from, and the dial starts where the row ends. Anything up there that
works its own vertical out of the padding drifts, because the padding is a
horizontal measurement.

The match ending is the board again rather than a page of its own: at the
whistle it comes up whether or not anybody asked for it, in a column of its
own up to 720 points wide, with a line saying who took the match, a bar under
that carrying each side's name inside its own share of it, and a foot with the
countdown and one key. The same arrangement at every window size; an upright
phone hugs the foot of the screen with it, so the key lands under a thumb.
The band stands down while it is up, since the head carries the score and the
foot carries the clock.

Top center is the band: the clock, with a side either side of it as a name
over a number (a team over its score, a duel's pilot over their rating),
the two lines of a side adding up to the clock's own height so the whole
thing reads as one line. The clock is one key tall, the same at every window
size, so the band and the way into the menu are the same height and the top
row reads as a row. Under it, the flag pennants and whatever the room
has to say. The band is also the control: a press opens the board under it,
which is the roster, then whatever else the zone keeps (a run of fights, in
the mode that is a run), then the pilot box a row was pressed on. While that
board is up the fight behind it is washed and every other instrument's type
recedes, because the board is the thing being read. Dead center is reserved for the two big
statements, DESTROYED and SAFE ZONE, and for the cards and tables a player asks
for. On a touchscreen the bottom of the screen belongs to the thumbs and
everything else lifts out of their way.

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
The thing a page is spent against stays pinned: the ship page's band with
its budget, the week's heading, the friends page's add field.

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

That gui-over-mesh constraint is load-bearing everywhere: the only way to
quiet a label is to quiet the label (`text_dim`), a wash can never do it. It
is why rows draw whole or not at all, and why the ending takes the
nameplates down while it is up.

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
lit steps, not the word "half"; a kit level is a position on a ladder read as
L2. Where a number must be words it comes with its noun ("4 playing, 3 AI",
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
the place you least look. Your bounty is not, because it is what other people
see when they look at you rather than anything you can spend, and it is
already said over every nameplate and in the scoreboard column that sorts by
it. Damage is the vignette, red
creeping in from the edges, which never hides the ship shooting you. The
words for any row are an ask away: rest the pointer and a card names it,
lists what the greens taught it, and says which key spends it.

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
| `.design/rethink/`, `.design/friends/` | the mocks several of these pages were redrawn to |

The mocks are where the language was last argued about in pictures; when a
page and its mock disagree, one of them is wrong on purpose and the reason
should be findable in a commit or in this file.
