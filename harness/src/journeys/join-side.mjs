// Read the room from the players sheet, and cross to the other side from it.
//
// The whole of decision 147 from a player's side: the scoreboard, the roster,
// the pilot box and the side picker are one panel, that panel is a stop of the
// menu, and joining a side is done from the card of somebody already on it.
//
// It is worth a journey rather than a unit test because the pieces are on
// different sides of every boundary in the client. The stop is declared in
// menu.lua, the sheet is drawn by ui.lua off a roster that arrives over the
// wire, the card's key sends `C2S_TEAM` from arena.script, and what answers is
// the zone deciding whether it will take you: a full bar, a seat spare on the
// side you asked for, and a respawn. The Lua tests can see the drawing against
// a fake room and the server's own tests can see the gate; nothing but this can
// see them agree.
//
// What it asserts is about the game rather than the screen: not "a JOIN key was
// drawn" but "the room now says this pilot flies for the other side, and did
// not until the key was pressed".

import { arrive } from './arrive.mjs'

export const name = 'join-side'

// How long to wait for the room to answer a side. One reliable message and the
// next roster carries the answer, so this is generous rather than tuned: what
// it is really waiting out is a whistle the ask can land beside.
const ANSWER_MS = 20000

// How many times to go back and ask again.
//
// Nothing pauses while this panel is up, which is the bargain the in-match
// column struck. A side costs a full bar, so a stray round landing between
// opening the card and pressing its key is a refusal. That is the design
// working rather than a flake, and a player answers it by waiting a moment and
// asking again. So does this.
const TRIES = 3

const whole = pilot => pilot.until('a full bar to spend on a side',
  s => s.me && s.me.alive && s.me.energy >= s.me.max_energy,
  { timeout: 90000 })

// Open the column at the players stop, however the profile's hand reaches it,
// and on the sheet rather than on a card left open by a try that was refused.
async function openSheet (pilot) {
  let up = await pilot.read()
  if (!up.screen.menu_open) {
    await pilot.tap('open')
    up = await pilot.until('the column',
      s => s.screen.menu_open && s.boxes.length > 0)
  }
  if (up.screen.panel !== 'players') {
    await pilot.tap('menu_stop', { value: 'players' })
  } else if (up.screen.pilot_card !== null
             && up.screen.pilot_card !== undefined) {
    // A card is a level of this panel, so the way off it is the way off any
    // level: back, once.
    await pilot.tap('menu_back')
  }
  return pilot.until('the players sheet',
    s => s.screen.panel === 'players'
      && (s.screen.pilot_card === null || s.screen.pilot_card === undefined))
}

export async function run (pilot, { log = () => {} } = {}) {
  const seated = await arrive(pilot, { log })
  const mine = seated.me.team

  for (let go = 1; go <= TRIES; go++) {
    await whole(pilot)
    log(`asking for a side, try ${go}, flying for side ${mine}`)
    const sheet = await openSheet(pilot)

    // Every row of the sheet is a seat, so the room is readable from here. A
    // room with nobody else in it has nothing to cross to, which is a fact
    // about the room rather than a fault: the bot server fills these, so it
    // means the fill has not landed yet.
    const rows = sheet.boxes.filter(b => b.action === 'board_row')
    log(`the sheet lists ${rows.length} in the room`)
    if (rows.length < 2) {
      throw new Error(
        'the players sheet listed nobody but this pilot. The room fills with ' +
        'bots, so an empty sheet is either a roster that never arrived or a ' +
        'list that is not being drawn from it.')
    }

    // Somebody on another side. Their row is where the card comes from, and
    // the card is the only thing in the client that offers a side.
    let opened = null
    for (const row of rows) {
      await pilot.tap('board_row', { value: row.value })
      const card = await pilot.until('a pilot card',
        s => s.screen.pilot_card !== null
          && s.screen.pilot_card !== undefined)
      const key = card.boxes.find(b => b.action === 'board_join')
      if (key && key.value !== mine) { opened = key; break }
      // Somebody on our own side, or a side the zone will not take us into.
      // Their card offers nothing, which is the design: back out and try the
      // next row rather than pressing at a key that is not there.
      await pilot.tap('menu_back')
      await pilot.until('the sheet again',
        s => s.screen.pilot_card === null
          || s.screen.pilot_card === undefined)
    }
    if (!opened) {
      throw new Error(
        'no row on the sheet opened a card offering another side. Either the ' +
        'whole room is on one side, or the card is not drawing the key that ' +
        'is the only way to cross.')
    }
    const want = opened.value
    log(`the card offers side ${want}`)

    // And nothing has been asked of the room yet. Reading about somebody is
    // not joining them: the card is a panel, and the key on it is the act.
    const held = await pilot.read()
    if (held.me.team !== mine) {
      throw new Error(
        `opening a card moved this pilot to side ${held.me.team} on the spot. ` +
        'The card reads; its key is what asks.')
    }

    log(`pressing the key for side ${want}`)
    await whole(pilot)
    await pilot.tap('board_join', { value: want })

    let crossed = null
    try {
      crossed = await pilot.until(
        `the room to put this pilot on side ${want}`,
        s => s.me && s.me.team === want,
        { timeout: ANSWER_MS })
    } catch (why) {
      // Refused, which the client has to have said out loud: a side dropped in
      // silence is a key that did nothing.
      const after = await pilot.read()
      if (!after.screen.note) {
        throw new Error(
          `side ${want} never arrived and the client said nothing about it. ` +
          'A refused side has to name its reason.')
      }
      log(`refused: ${after.screen.note}`)
      if (go === TRIES) throw why
      continue
    }

    // And it cost what a side costs. A weapon in flight carries the side that
    // fired it, so a change that took effect in place would turn incoming fire
    // friendly mid-air; crossing is a respawn, which is a full bar at a start.
    if (crossed.me.alive && crossed.me.energy < crossed.me.max_energy * 0.9) {
      throw new Error(
        `crossed to side ${want} on ${crossed.me.energy} of ` +
        `${crossed.me.max_energy}. A side change is a respawn, so the pilot ` +
        'should arrive whole rather than carrying the damage across.')
    }

    // And the panel went back to the sheet by itself, which is where the
    // answer to the key is: your own row crosses into the first group and
    // their side becomes yours. A card left standing would be the one place
    // in the client that cannot show what was just asked for.
    const back = await pilot.until('the sheet again',
      s => s.screen.panel === 'players'
        && (s.screen.pilot_card === null
            || s.screen.pilot_card === undefined))
    const still = back.boxes.filter(b => b.action === 'board_row')
    if (still.length < 2) {
      throw new Error(
        'the sheet came back with nobody on it. Crossing sides is a respawn, ' +
        'and the room is the same room.')
    }
    log(`the sheet still lists ${still.length}, this pilot now on side ${want}`)
    return crossed
  }
  throw new Error(`no side after ${TRIES} tries`)
}
