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
//
// Four of them, because there are two ways to lose the round rather than one.
// The client's gate refuses an ask made on a part-full bar and says so. The
// room's refuses one that arrives about a pilot a round has hurt in transit,
// and says nothing at all. Neither is a fault, and both clear on their own.
const TRIES = 4

// How long to give a press before deciding the row went out from under it,
// and how long to keep working through the sheet before giving up on the room.
//
// A row is numbered by where it sits this frame and the sheet re-sorts every
// frame it is drawn, so a row number ages: a pilot leaving takes theirs with
// them, and a press carrying it arrives about nobody. The client answers that
// with nothing, which is the only honest answer available, so what a reader
// has to do is notice and take the next row rather than wait out a card that
// is never coming.
//
// Twelve seconds rather than the four this first carried. Four was measured
// off a desktop and a landscape phone reads slower than that: every row timed
// out before its card could arrive, so a search that had found nothing looked
// exactly like a room with nobody to cross to. The bound is on a press that
// resolved to nobody, not on how fast the client draws, so it wants to sit
// well clear of a slow profile's honest answer.
//
// And the search is bounded by a clock rather than a count of rows, since
// what runs out on a slow profile is time.
const CARD_MS = 12000
const SEARCH_MS = 60000

const whole = pilot => pilot.until('a full bar to spend on a side',
  s => s.me && s.me.alive && s.me.energy >= s.me.max_energy,
  { timeout: 90000 })

// And somebody to cross to.
//
// A side is joined through one of its pilots, so a room with everybody on one
// side offers no door at all: no row, no card, no key. That is decision 147's
// stated cost rather than a fault, and it is a state this room reaches -- a
// match ends, the ground changes, and for a moment the only two active ships
// are the pilot and one bot that stayed put, both on side 0. Asking the sheet
// for a crossing then is asking for something that does not exist, and a
// reader that goes looking anyway reports a missing key rather than an empty
// side.
//
// So it is waited for by name. The bot server holds every empty seat and
// seats an arrival on the emptiest side, so a one-sided room is a moment
// rather than a condition; what this waits out is the moment.
const opposed = (pilot, mine) => pilot.until(
  `somebody in the room flying for a side other than ${mine}`,
  s => (s.ships || []).some(sh => sh.active && sh.team !== mine),
  { timeout: 90000 })

// Open the column at the players stop, however the profile's hand reaches it,
// and on the sheet rather than on a card left open by a try that was refused.
//
// Written as a loop that reads, takes one step toward the sheet, and reads
// again, rather than as a press followed by a long wait on the result. A
// press is aimed at a box that was there when it was aimed, and nothing
// pauses behind this panel: a match can end and raise the sheet from under a
// card between the aim and the press, and a press meant for the head can land
// on a row and open another card instead. That is not a fault to assert
// against, it is what pressing at a live screen is, and the answer to it is
// to look again and take the next step rather than to wait thirty seconds on
// a step that did not take.
const SHEET_MS = 30000

// Every one of these steps is a toggle or a move that takes a moment, so each
// waits for its own result before the loop looks again. Pressing one twice
// because the first had not landed yet is how a key that opens the column
// closes it.
const settle = async (pilot, what, want) => {
  try {
    await pilot.until(what, want, { timeout: 5000 })
  } catch { /* it did not take; the next turn of the loop presses again */ }
}

async function openSheet (pilot) {
  const deadline = Date.now() + SHEET_MS
  while (Date.now() < deadline) {
    const up = await pilot.read()
    if (!up || !up.screen.menu_open) {
      await pilot.tap('open')
      await settle(pilot, 'the column', s => s.screen.menu_open)
      continue
    }
    if (up.screen.panel !== 'players') {
      await pilot.tap('menu_stop', { value: 'players' })
      await settle(pilot, 'the players stop',
        s => s.screen.panel === 'players')
      continue
    }
    if (up.screen.pilot_card !== null && up.screen.pilot_card !== undefined) {
      // A card is a level of this panel, so the way off it is the way off any
      // level: back.
      await pilot.tap('menu_back')
      await settle(pilot, 'the way off the card',
        s => s.screen.pilot_card === null || s.screen.pilot_card === undefined)
      continue
    }
    if (up.boxes.length > 0) return up
  }
  throw new Error(
    'the players sheet never came up. The column opens at its stop and a ' +
    'card steps back onto it, so neither the stop nor the way off a card is ' +
    'answering.')
}

export async function run (pilot, { log = () => {} } = {}) {
  const seated = await arrive(pilot, { log })
  const mine = seated.me.team
  // Why the last try came to nothing, so the failure at the end names what
  // was actually seen rather than only that it gave up.
  let why = 'the room was never read'

  for (let go = 1; go <= TRIES; go++) {
    await whole(pilot)
    await opposed(pilot, mine)
    log(`asking for a side, try ${go}, flying for side ${mine}`)
    const sheet = await openSheet(pilot)

    // Every pressable row of the sheet is a seat, so the room is readable from
    // here. A room with nobody else in it has nothing to cross to, which is a
    // fact about the room rather than a fault: the bot server fills these, so
    // it means the fill has not landed yet.
    let seen = sheet.boxes.filter(b => b.action === 'board_row')
    log(`the sheet lists ${seen.length} in the room`)
    if (seen.length < 2) {
      throw new Error(
        'the players sheet listed nobody but this pilot. The room fills with ' +
        'bots, so an empty sheet is either a roster that never arrived or a ' +
        'list that is not being drawn from it.')
    }

    // Somebody on another side. Their row is where the card comes from, and
    // the card is the only thing in the client that offers a side.
    //
    // Worked one row at a time off a fresh reading, because the list under it
    // moves. What is remembered between rows is the seat each card was about,
    // which is what the client answers a press with and the one identifier
    // here that outlives a sort.
    let opened = null
    const asked = new Set()
    let quiet = 0
    const deadline = Date.now() + SEARCH_MS
    for (let row = 0; !opened && Date.now() < deadline; row++) {
      const now = await openSheet(pilot)
      const rows = now.boxes.filter(b => b.action === 'board_row')
      if (rows.length === 0) break
      // From the far end of the list. The sheet puts your own side first and
      // everyone else after it, and a card only offers a key for somebody on
      // another side, so the rows nearest the top are the ones that cannot
      // answer. Walking down from the bottom reaches a crossing on the first
      // press instead of after a screenful of your own team mates, which on a
      // phone is the difference between one try and four.
      const next = rows[rows.length - 1 - (row % rows.length)]

      await pilot.tap('board_row', { value: next.value })
      let card = null
      try {
        card = await pilot.until('a pilot card',
          s => s.screen.pilot_card !== null
            && s.screen.pilot_card !== undefined,
          { timeout: CARD_MS })
      } catch {
        // The row went stale under the press: whoever held that number left
        // between the reading and the tap. Take another reading and go again.
        quiet++
        continue
      }
      if (asked.has(card.screen.pilot_card)) continue
      asked.add(card.screen.pilot_card)

      const key = card.boxes.find(b => b.action === 'board_join')
      if (key && key.value !== mine) { opened = key; break }
      // Somebody on our own side, or a side the zone will not take us into.
      // Their card offers nothing, which is the design: the next reading
      // steps back off it rather than pressing at a key that is not there.
    }
    if (!opened) {
      // Said rather than thrown, because this is a fact about the room and
      // the room changes: a side with every seat spoken for has none to
      // offer until somebody leaves it, and the next try is after a full bar
      // has built. What separates that from a client that has stopped
      // drawing the key is the count -- cards read, and rows that answered a
      // press with nothing at all.
      why = `read ${asked.size} card${asked.size === 1 ? '' : 's'}, none ` +
        `offering a side to cross to; ${quiet} row(s) answered nothing`
      log(`no side on offer: ${why}`)
      if (go === TRIES) break
      continue
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
    } catch (waited) {
      // Refused, and there are two ways that reads.
      //
      // The client's own gate speaks: it wants a full bar to spend, and says
      // so. The room's does not. `Room::join_team` puts the ask past two
      // gates -- whether the side has a door, and whether the core will let
      // this pilot leave where they are, which it refuses for anyone dead or
      // hurt -- and both are silent by design, on the grounds that the team
      // list that follows still says where you are.
      //
      // So the race this loses is real and is the room's to lose: the bar is
      // full when the key is pressed and a round lands during the trip, so
      // the ask arrives about a hurt pilot and is dropped without a word.
      // Nothing to assert against there; what a player does is press again
      // once they are whole, and so does this.
      const after = await pilot.read()
      why = after.screen.note
        ? `the client refused the side: ${after.screen.note}`
        : `side ${want} was asked for on a full bar and never arrived, with ` +
          'nothing said. That is the room\'s silent refusal, which is what a ' +
          'round landing during the trip looks like from here.'
      log(`refused: ${after.screen.note || 'in silence'}`)
      if (go === TRIES) throw waited
      continue
    }

    // The pilot is flying, on the far side, and still in the room. A crossing
    // that killed them or left them a spectator would be a different act than
    // the one the key names.
    //
    // What is deliberately not asserted here is the bar. A side change is a
    // respawn, so the pilot arrives whole, and it is tempting to check for a
    // full one. But this journey presses the key on a full bar because the
    // client's gate demands one, so "arrived whole" and "carried the damage
    // across" produce the same reading and the check cannot tell them apart.
    // What it can tell is that a round landed in the second after arrival,
    // which is a fight happening rather than a fault: it failed a run at 64%
    // on a pilot who had crossed perfectly well. So the bar is read out and
    // not judged.
    log(`crossed to side ${want} at ${crossed.me.energy}/` +
        `${crossed.me.max_energy}, ${crossed.me.alive ? 'alive' : 'down'}`)
    if (!crossed.me.seat && crossed.me.seat !== 0) {
      throw new Error(
        `crossed to side ${want} and lost the seat with it. A side change is ` +
        'a respawn into the same room, not a way out of it.')
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
  throw new Error(`no side after ${TRIES} tries: ${why}`)
}
