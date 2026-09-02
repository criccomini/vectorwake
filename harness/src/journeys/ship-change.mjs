// Change ship in the middle of a match, through the menu, and come back in it.
//
// The whole of decision 136 from a player's side: the ship menu the front page
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
  const first = (await arrive(pilot, { log })).me.class
  let was = first

  for (let go = 1; go <= TRIES; go++) {
    await whole(pilot, log)
    // The hull this try starts on, read now rather than carried down from
    // arrive. What the check below is about is the turn, so its "before" has
    // to be from just before the turn: a room seats a pilot and can move them
    // afterwards, at a whistle or when the build they owe names another hull,
    // and a figure taken two seconds earlier is then a reading of a ship
    // nobody is in.
    was = (await pilot.read()).me.class
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

    // Wait for it to come to rest, rather than reading it on the way through.
    // A tap returns when its press is sent and not when the client has read
    // it, so a wait for "any hull but the one we were flying" can answer with
    // the first of those two steps while the second is still on its way. Rest
    // is two readings that agree, which is the test a press already makes on a
    // box before it lands.
    let before = null
    await pilot.until(`the carousel at rest off hull ${was}`, s => {
      const on = s.screen.hull_shown
      const rest = on !== null && on !== undefined && on !== was && on === before
      before = on
      return rest
    })

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

    // The hull the carousel is showing when the panel is left is the hull the
    // key will ask for, so this is read as late as it can be rather than out
    // of the wait above. A journey that takes it any earlier is guessing at a
    // draft still being edited, and one that guesses wrong waits out its whole
    // answer and then reports a refusal that never happened.
    const want = held.screen.hull_shown
    log(`carousel is on hull ${want}`)

    // Out of the body onto the ship menu, then out of the ship stop onto the
    // bare column. None of that spends the draft: a dismissal is not a
    // decision, and the draft stands on the column with the ship stop naming
    // it. See decision 159.
    log('backing out to the column')
    await pilot.tap('menu_back')
    await pilot.until('the ship menu again', s => !s.screen.section)
    await whole(pilot, log)
    await pilot.tap('menu_back')
    await pilot.until('the bare column',
      s => s.screen.menu_open && !s.screen.panel)

    // Still flying what they were flying, which is the half of the design
    // that walking the panel is for: the draft has crossed no wire yet.
    const pending = await pilot.read()
    if (pending.me && pending.me.class !== was) {
      throw new Error(
        `leaving the ship panel put this pilot in hull ${pending.me.class}. ` +
        'Closing a panel is a dismissal and must not spend a draft.')
    }

    // The key is what spends it, and it says so: with a ship drafted over a
    // seat the column's one key is the refit.
    log('pressing the key')
    await whole(pilot, log)
    await pilot.tap('menu_go')

    log(`waiting for the room to answer hull ${want}`)
    let flown = null
    try {
      flown = await pilot.until(
        `the room to put this pilot in hull ${want}`,
        s => s.me && s.me.class === want,
        { timeout: ANSWER_MS })
    } catch (why) {
      // Refused. The client says so where it can: its own gate mirrors the
      // core's, so a bar it can see is short names a reason in the menu's
      // note, and a ship dropped in silence is a menu that did nothing.
      //
      // The room's gate cannot say it yet. The client will not send on a part
      // bar and the core will not move a hurt pilot's hull, so the two checks
      // bracket a flight time: press whole, take a round while the ask is in
      // the air, and the room keeps you where you are without a word. That is
      // the hole decision 150 closed for crossing sides and has not closed for
      // ships. So one silence is retried on the budget this loop already
      // carries, and only a run of them is a fault worth stopping on.
      const after = await pilot.read()
      log(after.screen.note
        ? `refused: ${after.screen.note}`
        : 'refused, and nothing was said: a round landed during the ask')
      if (go === TRIES) {
        if (!after.screen.note) {
          throw new Error(
            `hull ${want} never arrived and the client said nothing about it, ` +
            `${TRIES} tries running. A refused ship has to name its reason.`)
        }
        throw why
      }
      continue
    }

    // And it cost what a ship costs. A change is a respawn, so the pilot is
    // at their start with a fresh bar of the new hull rather than carrying
    // the old one's damage across.
    if (!flown.me.alive) throw new Error('the new ship arrived dead')
    log(`flying hull ${flown.me.class} at ` +
        `${flown.me.energy}/${flown.me.max_energy}`)
    return { was: first, now: flown.me.class, tries: go }
  }
}
