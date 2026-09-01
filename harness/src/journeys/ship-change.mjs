// Change ship in the middle of a match, through the menu, and come back in it.
//
// The whole of decision 128 from a player's side: the ship menu the front page
// opens is the ship menu the column opens, editing it mid-match asks the room
// for nothing until the panel closes, and closing it at a full bar puts the
// pilot back at their start in what they built.
//
// It is worth a journey rather than a unit test because every part of it lives
// on a different side of a boundary. The panel is drawn by ui.lua, the draft is
// held in menu.lua, the settling is in arena.script, the gate is in the C core
// compiled into both ends, and the respawn arrives back over the wire in a
// snapshot. The Lua tests can see the first three against a fake engine and the
// core's own tests can see the fourth; nothing but this can see them agree.
//
// What it asserts is about the game, not the screen: not "the carousel drew a
// Wedge" but "the server now says this pilot is flying one, and did not until
// the panel was closed".

import { arrive } from './arrive.mjs'

export const name = 'ship-change'

// How long to wait for the room to answer a ship. It is one reliable message
// and the next snapshot carries the answer, so this is generous rather than
// tuned: what it is really waiting out is a whistle the ask can land beside.
const ANSWER_MS = 20000

// How many times to go back and ask again.
//
// Nothing pauses while this menu is up, which is the bargain the in-match
// column struck: a pilot reading it can be shot for reading it, and a ship
// costs a full bar, so a stray round landing between the last press and the
// close is a refusal. That is the design working rather than a flake, and a
// player answers it by waiting a moment and asking again. So does this.
const TRIES = 3

// Wait for the ship to be whole enough to spend, which is what the panel's own
// head asks a pilot to do.
const whole = (pilot, log) => pilot.until('a full bar to spend on a ship',
  s => s.me && s.me.alive && s.me.energy >= s.me.max_energy,
  { timeout: 90000 })

export async function run (pilot, { log = () => {} } = {}) {
  const seated = await arrive(pilot, { log })
  const was = seated.me.class

  for (let go = 1; go <= TRIES; go++) {
    await whole(pilot, log)
    log(`asking for a ship, try ${go}, flying hull ${was}`)

    const up = await pilot.read()
    if (!up.screen.menu_open) {
      await pilot.tap('open')
      await pilot.until('the column',
        s => s.screen.menu_open && s.boxes.length > 0)
    }
    if (up.screen.page !== 'ship') {
      await pilot.tap('menu_stop', { value: 'ship' })
      await pilot.until('the ship panel', s => s.screen.page === 'ship')
    }

    log('opening the body')
    await pilot.tap('land_sect', { value: 'body' })
    const opened = await pilot.until('the body carousel',
      s => s.screen.section === 'body' && s.screen.hull_shown !== null)

    // Turn it. Two steps rather than one so the hull is unambiguously
    // somebody else's, and because turning past a page is exactly what used
    // to hand the seat back at the end of the roster.
    log(`turning the carousel off hull ${opened.screen.hull_shown}`)
    await pilot.tap('land_page_ship', { value: 1 })
    await pilot.tap('land_page_ship', { value: 1 })
    const turned = await pilot.until('a different hull on the carousel',
      s => s.screen.hull_shown !== undefined && s.screen.hull_shown !== was)
    const want = turned.screen.hull_shown
    log(`carousel is on hull ${want}`)

    // And nothing has been asked of the room. This is the half of the design
    // that cannot be seen from either end alone: the panel is an editor, so
    // walking it costs no respawns, and the pilot is still flying what they
    // were flying a moment ago.
    const held = await pilot.read()
    if (held.me.class !== was) {
      throw new Error(
        `turning the carousel put this pilot in hull ${held.me.class} on the ` +
        'spot. In a match the panel drafts: nothing should reach the room ' +
        'until it closes, or crossing the roster costs a respawn a step.')
    }

    // Out of the body onto the ship menu, then out of the ship stop, which is
    // what settles the draft. Whole again first, because the panel's head has
    // been saying so for as long as it has been open.
    log('closing the panel')
    await pilot.tap('menu_back')
    await pilot.until('the ship menu again', s => !s.screen.section)
    await whole(pilot, log)
    await pilot.tap('menu_back')

    log(`waiting for the room to answer hull ${want}`)
    let flown = null
    try {
      flown = await pilot.until(
        `the room to put this pilot in hull ${want}`,
        s => s.me && s.me.class === want,
        { timeout: ANSWER_MS })
    } catch (why) {
      // Refused, which the client has to have said out loud: the panel that
      // carried the warning has gone, and a ship dropped in silence is a menu
      // that did nothing.
      const after = await pilot.read()
      if (!after.screen.note) {
        throw new Error(
          `hull ${want} never arrived and the client said nothing about it. ` +
          'A refused ship has to name its reason.')
      }
      log(`refused: ${after.screen.note}`)
      if (go === TRIES) throw why
      continue
    }

    // And it cost what a ship costs. A change is a respawn, so the pilot is
    // at their start with a fresh bar of the new hull rather than carrying
    // the old one's damage across.
    if (!flown.me.alive) throw new Error('the new ship arrived dead')
    log(`flying hull ${flown.me.class} at ` +
        `${flown.me.energy}/${flown.me.max_energy}`)
    return { was, now: flown.me.class, tries: go }
  }
}
