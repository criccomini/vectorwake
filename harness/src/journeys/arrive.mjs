// Boot the client, find a game, and take a seat in it.
//
// The prologue every journey past the first one shares. It was the first two
// thirds of boot-to-match, which is where it belongs while there is one
// journey and is a copy the moment there are two: a second journey that
// repeated it would be a second place for "how does a player get into a room"
// to drift.
//
// What it asserts is the same as ever: not that a button exists, but that a
// press a person could make joins a room and hands over a seat.

export async function arrive (pilot, { log = () => {} } = {}) {
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
  return seated
}
