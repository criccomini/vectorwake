// Does the harness notice anything?
//
//     node harness/test/oracles_test.mjs
//
// A harness whose watchers have quietly stopped watching is worse than no
// harness, because it reports green. Every oracle here is fed a sequence of
// readings and asked to fail on the bad one. The readings are hand-built
// rather than recorded, so each case says in its own shape what it is about.
//
// One of these caught a real hole. `staysConnected` was written as "connected,
// then not", which passed the actual case: losing its server is something this
// client handles well, so a quarter of a second later it is sitting on the
// landing looking healthy, and an oracle hunting for a disconnected client in
// a room finds nothing. Killing an arena under a live match went green.

import {
  framesAdvance, tickAdvances, staysConnected, selfConsistent,
  clientReportsNoFaults, serverSeesYou, check
} from '../src/oracles.mjs'

let fails = 0
function ok (name, condition, detail) {
  if (condition) {
    console.log('ok   ' + name)
  } else {
    fails += 1
    console.log('FAIL ' + name + (detail ? '  -- ' + detail : ''))
  }
}

// A reading with everything healthy, which each case then spoils in one way.
let seq = 0
function reading (over = {}) {
  seq += 1
  return {
    seq,
    frames: seq * 6,
    tick: seq * 6,
    screen: { landing: false, joined: true, flying: true, watching: false },
    me: { seat: 3, alive: true, x: 100, y: 100, energy: 900, max_energy: 1000 },
    ships: [{ seat: 3, alive: true }],
    link: { connected: true, bars: 4 },
    room: { zone: 'melee', room: 1 },
    ...over
  }
}

// Feed a watcher readings until one produces a fault. Time has to pass for the
// watchers that measure a stall, so the clock is moved rather than waited out.
async function feed (watch, readings, { clockJumpMs = 0 } = {}) {
  const realNow = Date.now
  let offset = 0
  Date.now = () => realNow() + offset
  try {
    for (const r of readings) {
      const fault = await watch(r, r.pilot || {})
      if (fault) return fault
      offset += clockJumpMs
    }
    return null
  } finally {
    Date.now = realNow
  }
}

// --- frames ----------------------------------------------------------------

ok('a drawing client passes',
  !await feed(framesAdvance(), [reading(), reading(), reading()]))

const stuck = reading({ frames: 500 })
ok('a client that stops drawing is caught',
  (await feed(framesAdvance(),
    [reading({ frames: 500 }), { ...stuck }, { ...stuck }, { ...stuck }],
    { clockJumpMs: 2000 }))?.kind === 'stalled-frames')

// --- ticks -----------------------------------------------------------------

ok('a running simulation passes',
  !await feed(tickAdvances(), [reading(), reading(), reading()]))

const frozen = reading({ tick: 900 })
ok('a simulation that stands still while joined is caught',
  (await feed(tickAdvances(),
    [reading({ tick: 900 }), { ...frozen }, { ...frozen }, { ...frozen }],
    { clockJumpMs: 3000 }))?.kind === 'stalled-tick')

ok('and a still tick on the landing is not a fault',
  !await feed(tickAdvances(), [
    reading({ tick: 900, screen: { landing: true, joined: false } }),
    reading({ tick: 900, screen: { landing: true, joined: false } }),
    reading({ tick: 900, screen: { landing: true, joined: false } })
  ], { clockJumpMs: 9000 }))

// --- the wire --------------------------------------------------------------

ok('an ordinary session passes',
  !await feed(staysConnected(), [reading(), reading()]))

// The case the first version of this oracle missed: the client is already home
// and looking healthy by the time anybody reads it. What lasts is the reason.
ok('a room that goes away under a seated client is caught',
  (await feed(staysConnected(), [
    reading(),
    reading({
      screen: { landing: true, joined: false, flying: false },
      me: null,
      link: { connected: false, lost: 'the zone closed the connection' }
    })
  ]))?.kind === 'disconnected')

ok('and a journey that means to leave is not a fault',
  !await feed(staysConnected(), [
    reading(),
    {
      ...reading({
        screen: { landing: true, joined: false, flying: false },
        me: null,
        link: { connected: false, lost: 'left' }
      }),
      pilot: { leaving: true }
    }
  ]))

ok('a client that never got seated is not held to it',
  !await feed(staysConnected(), [
    reading({ screen: { landing: true, joined: false }, link: { connected: false } })
  ]))

// --- what the client says about itself -------------------------------------

ok('a consistent client passes', !await feed(selfConsistent(), [reading()]))

ok('in a room and knowing of no ships is caught',
  (await feed(selfConsistent(), [reading({ ships: [] })]))?.kind === 'empty-room')

ok('flying with no ship of its own is caught',
  (await feed(selfConsistent(), [reading({ me: null })]))?.kind === 'no-ship')

ok('energy past the hull ceiling is caught',
  (await feed(selfConsistent(), [
    reading({ me: { alive: true, energy: 5000, max_energy: 1000 } })
  ]))?.kind === 'energy')

// --- the client's own reports ----------------------------------------------

const stage = { clientErrors: [] }
const reports = clientReportsNoFaults(stage)
ok('a quiet client passes', !await reports(reading()))
stage.clientErrors.push({ kind: 'console', message: 'bang', stack: 'at x' })
const told = await reports(reading())
ok('a fault the client reported is raised', told?.kind === 'client-error', told?.message)
ok('and it is raised once, not on every reading afterwards',
  !await reports(reading()))

// --- the server's second opinion -------------------------------------------

const empty = { metrics: async () => ({ vw_players: 0 }) }
ok('an arena that counts nobody while this client flies is caught',
  (await feed(serverSeesYou(empty, { forMs: 0 }), [reading()]))
    ?.kind === 'server-sees-nobody')

ok('and an arena that counts somebody passes',
  !await feed(serverSeesYou({ metrics: async () => ({ vw_players: 1 }) }), [reading()]))

ok('an arena with nothing to say is not evidence either way',
  !await feed(serverSeesYou({ metrics: async () => null }), [reading()]))

// --- the runner's own contract ---------------------------------------------

let raised = null
try {
  await check([() => null, () => ({ kind: 'made-up' })], reading(), {})
} catch (e) { raised = e }
ok('check raises the first fault it is given', raised?.kind === 'made-up')

console.log(fails === 0 ? 'all good' : fails + ' failed')
process.exit(fails === 0 ? 0 : 1)
