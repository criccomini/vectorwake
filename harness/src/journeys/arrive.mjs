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
  // A thumb first, while there is still nothing on screen for it to press.
  //
  // On glass the wake is a plain touch in the middle of the canvas, because
  // the pads are not drawn until the client has seen a finger. Made here it
  // lands on the loading screen, which publishes no boxes, so it means
  // nothing. Made after the room arrives it lands on the column's own
  // backdrop, which means dismiss, and the journey would be racing a gesture
  // it made itself: a touch is dispatched before the client has acted on it,
  // so a read taken straight afterwards answers about the frame before the one
  // that matters. A person's first touch is a press on something.
  await pilot.until('the client to be running', s => s.frames > 0,
    { timeout: 60000 })
  await pilot.wake()

  // The client reaches the directory and puts itself in the stands of the game
  // it was in last. Everything before this is the engine starting up, which is
  // not what is under test but is where a broken build stops.
  log('waiting for a room')
  await pilot.until('the client to reach a room',
    s => !s.screen.adrift && s.boxes.length > 0,
    { timeout: 60000 })

  // The column stands over it, five stops over one key, and that key is the
  // whole of taking a seat: one press and the room owes you a hull. Wait for
  // it to actually take a press before making one, because until the client
  // has heard from the directory there is no game behind it.
  //
  // And raise the column if it is not there, for the one case the wake above
  // cannot rule out: a stage that answers before the first reading lands puts
  // a room on the glass while the touch is still in flight. MENU at the foot
  // is how anybody raises it again.
  log('waiting for the column key to be live')
  const live = s => s.boxes.some(b => b.hits === 'menu_go')
  try {
    await pilot.until('a live key', live, { timeout: 20000 })
  } catch (why) {
    const at = await pilot.read()
    if (at && at.screen.menu_open) throw why
    log('raising the column the wake touch dismissed')
    if (pilot.profile.input === 'keyboard') await pilot.press('menu')
    else await pilot.tap('open')
    await pilot.until('a live key', live, { timeout: 30000 })
  }

  // Each hand on its own path. The desktop's keyboard walk and the phone's
  // thumb are different code, and a journey that only ever tapped would leave
  // the keyboard untested on the profile that is all keyboard.
  if (pilot.profile.input === 'keyboard') {
    const at = await pilot.read()
    if (at.cursor.go !== 'menu_go') {
      throw new Error(
        `the column's cursor fires ${at.cursor.go || 'nothing'}, not menu_go`)
    }
    log('pressing enter on the key')
    await pilot.press('select')
  } else {
    log('tapping the key')
    await pilot.tap('menu_go')
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
