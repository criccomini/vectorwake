// Boot the client, find a game, join it, fly.
//
// The walking skeleton. It is the shortest thing that is nonetheless the whole
// harness: the stage runs, a real client loads, the client finds the fleet, a
// press that a human could make joins a room, the ship flies, and every
// watcher is reading the whole time. If this passes, the parts hold together,
// and every other journey is more of the same.
//
// What it asserts is deliberately about the game and not about the screen. Not
// "a button exists" but "a press here joins a room". Not "the ship drew" but
// "the ship moved, and the server agrees somebody is here".

import { tilesApart } from '../units.mjs'

export const name = 'boot-to-match'

export async function run (pilot, { flightMs = 60000, log = () => {} } = {}) {
  // The client boots, reaches the directory and draws its landing. Everything
  // before this is the engine starting up, which is not what is under test but
  // is where a broken build stops.
  log('waiting for the landing')
  await pilot.until('the client to draw its landing',
    s => s.screen.landing && s.boxes.length > 0,
    { timeout: 60000 })

  await pilot.wake()

  // The landing is PLAY NOW over three stops, and PLAY NOW is the whole of
  // joining: one press and you are in a room. Wait for it to actually take a
  // press before making one, because until the client has heard from the
  // directory there is no game behind it.
  log('waiting for PLAY NOW to be live')
  await pilot.until('a live PLAY NOW',
    s => s.boxes.some(b => b.hits === 'play_now'),
    { timeout: 45000 })

  // Each hand on its own path. The desktop's keyboard walk and the phone's
  // thumb are different code, and a journey that only ever tapped would leave
  // the keyboard untested on the profile that is all keyboard.
  if (pilot.profile.input === 'keyboard') {
    const at = await pilot.read()
    if (at.cursor.go !== 'play_now') {
      throw new Error(
        `the landing's cursor fires ${at.cursor.go || 'nothing'}, not play_now`)
    }
    log('pressing enter on PLAY NOW')
    await pilot.press('select')
  } else {
    log('tapping PLAY NOW')
    await pilot.tap('play_now')
  }

  log('waiting to be in a room')
  const joined = await pilot.until('a room with this client in it',
    s => s.screen.joined && s.link.connected && s.ships.length > 0,
    { timeout: 60000 })
  log(`joined ${joined.room.zone || '?'} on ${joined.room.map || '?'} ` +
      `with ${joined.ships.length} ships`)

  // A seat, eventually. A room may bench an arrival until the next whistle,
  // which is ordinary and is why this is its own wait rather than part of the
  // one above.
  log('waiting for a seat')
  const seated = await pilot.until('a seat of our own',
    s => s.screen.flying && s.me,
    { timeout: 90000 })
  log(`flying seat ${seated.me.seat}, hull ${seated.me.class}, ` +
      `team ${seated.me.team}`)

  // Fly. Not well: the point is that the input path carries a held key into
  // the simulation and the ship answers, which is the thing no unit test on
  // either side can see.
  //
  // What is measured is the furthest this ship ever got from where it started,
  // not where it finished. A pilot who flies a circuit finishes near the spawn
  // having crossed the map twice, and the first version of this check called
  // that "the ship did not move".
  let anchor = { x: seated.me.x, y: seated.me.y }
  let reach = 0
  const note = seen => {
    if (!seen?.me) return
    if (!seen.me.alive) {
      // A death resets the question. The next life starts somewhere else, and
      // the distance across that gap is the respawn, not the flying.
      anchor = null
      return
    }
    if (!anchor) { anchor = { x: seen.me.x, y: seen.me.y }; return }
    reach = Math.max(reach, tilesApart(anchor, seen.me))
  }

  log(`flying for ${Math.round(flightMs / 1000)}s`)
  const until = Date.now() + flightMs
  let beat = 0
  while (Date.now() < until) {
    pilot.throwFaults()
    if (pilot.profile.input === 'touch') {
      // Thumb pushed away from the middle is thrust, and where it points is
      // where the nose goes.
      await pilot.stick(beat % 3 === 0 ? 60 : 0, -80, 700)
      if (beat % 2) await pilot.tapPad('guns')
    } else {
      // Mostly ahead, with a turn now and then. Alternating every beat makes
      // a ship that wobbles on the spot.
      await pilot.hold('thrust', 700)
      if (beat % 3 === 0) await pilot.hold(beat % 6 ? 'left' : 'right', 250)
      if (beat % 2) await pilot.hold('guns', 200)
    }
    beat += 1
    note(await pilot.read())
  }

  const ended = await pilot.read()
  note(ended)
  log(`got ${reach.toFixed(1)} tiles from where it started`)

  if (reach < 1) {
    throw new Error(
      `flew for ${Math.round(flightMs / 1000)}s and never got more than ` +
      `${reach.toFixed(2)} tiles from the spawn. Input is not reaching the ` +
      'simulation.')
  }
  return { reach, seat: ended.me?.seat ?? seated.me.seat }
}
