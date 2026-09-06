# Canned phrases during a match

Chris's ask: a way for a pilot to say a canned phrase, drawn near their
ship for a short time; the house bots saying them too, and acting on
"follow me", "help!" and "retreat!". This is the brainstorm and the
mocks. Nothing here is built.

Two records already stand on this ground. [Decision
51](../../docs/architecture/decisions.md#51-six-phrases-and-no-way-to-add-a-seventh)
put six phrases on the podium between matches, on a wire that carries one
byte and no text, and named a phrase during a match as the thing it would
not do. [Decision 28](../../docs/architecture/decisions.md#28-no-chat)'s
reconsider clause left one door open: fixed phrases, a ping wheel, or
team-only signals during play, "a different feature from chat". And
[ai-players.md](../../docs/design/ai-players.md) says bots do not chat.
Shipping this amends all three, and the sheet's last section says how the
argument goes: a phrase to your own side during play is the signal decision
28 left open, and a bot saying what its brain is doing is a state readout
in words, never a line a human on the list could not say and never to the
other side.

The wire is decision 51's, and that is what keeps the moderation surface
at zero: `C2S_SAY` is an index into a list the client build holds, the room
checks it against a count, one every two seconds a seat. What changes is
that a match phrase goes to the sender's side only while a match runs, the
list grows by the nine below, and the bot server decodes `S2C_SAID`.

Also worth knowing: nothing on the client sends the six today. The chips
went with the ending's card (decision 94) and `arena.script` says the key
that was to replace them "is not here yet". The picker here is that key.

## The phrases

During a match, nine, to your side, a digit each:

| # | phrase | kind | what a bot does with it |
|---|---|---|---|
| 1 | follow me | call | escorts the caller: within four tiles, fights what fights them, for thirty seconds or until the caller dies or says anything else |
| 2 | help! | call | takes the foe nearest the caller, routing to where the radar puts them |
| 3 | retreat! | call | breaks off and recovers toward the nearest safe zone for ten seconds |
| 4 | attack! | call | drops a recovery unless energy is under the reserve, takes the nearest foe or the objective for fifteen seconds |
| 5 | hold here | call | stations at the caller's position for thirty seconds and fights what comes into range |
| 6 | on it | answer | |
| 7 | can't | answer | |
| 8 | falling back | report | |
| 9 | sorry | courtesy | shared with the podium list, keeps its index there |

Between matches, decision 51's six, to the room, unchanged: gg, nice shot,
close one, good luck, thanks, sorry. The picker lists whichever the moment
allows.

Considered and cut, with the reason on the sheet: cover me, regroup, spread
out, take the flag, guard the flag, go go go, coming, with you, no, low
energy, enemy here, got the flag. Each is the same ask in other words, a
report the HUD already makes, or a courtesy the podium already carries.

## What a bot says

A bot answers a call with "on it", or "can't" while it is recovering. Every
bot on the side acts; only the one nearest the caller answers aloud, so
five bots do not say "on it" at once. Unprompted, at most one line a bot
every twenty seconds:

- "falling back" when it begins a retreat with a foe on it, so the human
  it was fighting beside is told before the hull turns;
- "help!" when it is recovering with a foe closer than its retreat range
  and a teammate on the radar, at most once a life;
- "sorry" on a teamkill;
- "gg" on the podium, and nothing else there.

A bot's obedience is not a skill knob, and its archetype does not change
its lines. A phrase is one more input to the goal its brain already picks
between, which keeps the runtime's rule that a bot produces inputs and
nothing else.

## What is drawn

- **The picker.** Decision 67's board, the one the band opened before
  the players sheet took the roster into the menu: a column hanging
  centered under the row, a wash of the field color with a lit rule down
  its left edge and no border, a head in dim capitals with a tick rule
  under it, and rows one HUD line tall in the mono. Chris asked for the
  picker in that grammar, under the scoreboard. One key opens it (`c`, a
  new row in `controls.lua`) and the same key, a pick, escape or four idle
  seconds close it. It appears in a frame rather than sliding, the flight
  keys keep working under it, and the fight is not washed behind it. A
  digit picks its row, and so do the arrows and enter, and so does a
  pointer.
- **The phrase.** One line under the nameplate in ink, eleven points, lower
  case, three seconds with the last eight tenths spent leaving. Your own
  hull wears no plate, so your own line stands where the plate would.
- **A caller off the glass.** The feed carries `Gantry: help!` in the
  side's color, and the caller's radar dot wears a ring while the line
  lives. That ring is the ping decision 51's reconsider clause asked for.
- **The phone.** A CALL key under the rating corner drops the same board
  under the row.
- **Earlier shapes**, on the canvas's second page for the record: the menu
  language's rows on the glass standing on the left edge, and a strip of
  chips along the bottom. Both put a second voice on the HUD; the board is
  the HUD's own.

`build.py` is the source. The chrome is `../rating-corner/build.py`'s
(hues from `client/arena/palette.lua`, measures from `client/arena/ui.lua`)
and the rows are `../menu-language/build.py`'s. `Main.dc.html` is the
sheet; the boards beside it are the picker open on a monitor with a
teammate calling, the second after with your answer and the bot's, a
retreat called, and the phone with the key and with a phrase. The two
earlier pickers are on the second page.

Rebuild with `python3 build.py`; the eight `.dc.html` files and
`canvas.json` beside them are what the design canvas is seeded from.
