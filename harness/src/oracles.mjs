// What makes a run a failure.
//
// A watcher here is a function handed each reading in turn. It returns a fault
// or nothing. They are deliberately dull: every one of them is a statement a
// player could make about their own session, and none of them needs to know
// what the journey was trying to do.
//
// The interesting one is `agreesWithServer`. Every other check has one side of
// the wire in view, and the bug that hurt most had both sides individually
// healthy: the deployed client's compiled core read a wire the server had
// stopped writing, so a joining player was shown DESTROYED on a fleet that was
// fine. No single-sided test catches that. This one asks the client what it
// thinks it is looking at, asks the server the same question, and fails when
// they disagree by more than the snapshot delay can explain.

import { Fault } from './pilot.mjs'
import { tilesApart } from './units.mjs'

/** The frame loop stopped. */
export function framesAdvance ({ stallMs = 4000 } = {}) {
  let lastFrames = null
  let lastMove = Date.now()
  return seen => {
    if (lastFrames === null || seen.frames > lastFrames) {
      lastFrames = seen.frames
      lastMove = Date.now()
      return null
    }
    if (Date.now() - lastMove > stallMs) {
      return new Fault('stalled-frames',
        `the client drew no frame for ${stallMs}ms`,
        `stuck at frame ${seen.frames}, tick ${seen.tick}`)
    }
    return null
  }
}

/** The simulation stopped while the client was in a room. */
export function tickAdvances ({ stallMs = 6000 } = {}) {
  let lastTick = null
  let lastMove = Date.now()
  return seen => {
    if (!seen.screen?.joined || !seen.link?.connected) {
      lastTick = null
      lastMove = Date.now()
      return null
    }
    if (lastTick === null || seen.tick > lastTick) {
      lastTick = seen.tick
      lastMove = Date.now()
      return null
    }
    if (Date.now() - lastMove > stallMs) {
      return new Fault('stalled-tick',
        `the simulation stood still for ${stallMs}ms while joined`,
        `stuck at tick ${seen.tick}`)
    }
    return null
  }
}

/**
 * The client reported a fault in itself.
 *
 * The page's own diagnostics catch uncaught errors, rejected promises, failed
 * resources and everything script logs through `console.error`, which is where
 * Defold surfaces a Lua error. They post it to the stage with a stack. This is
 * the authority on whether the game faulted, rather than the harness reading
 * console output and guessing.
 */
export function clientReportsNoFaults (stage) {
  let told = 0
  return () => {
    const errors = stage.clientErrors || []
    if (errors.length <= told) return null
    const fresh = errors[told]
    told = errors.length
    return new Fault('client-error',
      `the client reported a ${fresh.kind} fault: ${fresh.message}`,
      fresh.stack || undefined)
  }
}

/**
 * The wire dropped under a match, without the journey asking it to.
 *
 * Written first as "connected, then not", which let the real case through.
 * Losing its server is one of the few things this client handles gracefully:
 * it says why and dials the next room. So the reading a quarter of a second
 * later is a client happily looking for a game, and an oracle looking for a
 * disconnected client in a room sees nothing wrong. Killing the arena under a
 * live match passed.
 *
 * What is durable is `net.lost`, the reason the wire gave. So the question is
 * not where the client is now but whether it was ever seated in a room that
 * then went away underneath it. A journey that means to leave says so first.
 */
export function staysConnected () {
  let wasSeated = false
  return (seen, pilot) => {
    if (seen.screen?.joined && seen.link?.connected) wasSeated = true
    if (!wasSeated) return null
    if (seen.link?.connected) return null
    if (pilot?.leaving) { wasSeated = false; return null }
    if (!seen.link?.lost) return null
    wasSeated = false
    return new Fault('disconnected',
      `the room went away underneath this client: ${seen.link.lost}`,
      seen.link?.denied ? `the zone said: ${seen.link.denied}` : undefined)
  }
}

/**
 * Things the client says about itself that cannot both be true.
 *
 * Each of these is a shape a real bug took. Being in a room with nobody in it,
 * including yourself, is what a client shows when it has lost track of the
 * roster; and being alive with no energy at all, or over the hull's own
 * ceiling, is what a wire disagreement looks like from the client's side.
 */
export function selfConsistent () {
  return seen => {
    const s = seen.screen || {}
    if (s.joined && !s.adrift && (seen.ships || []).length === 0) {
      return new Fault('empty-room',
        'the client says it is in a room and knows of no ships')
    }
    if (s.flying && !seen.me) {
      return new Fault('no-ship',
        'the client says it is flying and has no ship of its own')
    }
    const me = seen.me
    if (me && me.alive && me.max_energy > 0) {
      if (me.energy < 0 || me.energy > me.max_energy) {
        return new Fault('energy',
          `own energy is ${me.energy} of ${me.max_energy}`)
      }
    }
    return null
  }
}

/**
 * The client's account of its own ship against the server's.
 *
 * `ask` is a channel to the server's own view of this ship, which the stage
 * cannot yet supply: nothing the arena publishes carries a position, so this
 * wants a spectating connection that decodes snapshots the way tools/pilot
 * does. Written now because the oracle is the reason the harness exists and
 * the shape of it settles what that channel has to return.
 *
 * A client predicting correctly agrees with the server almost exactly: the
 * pilot harness measures 0.04 px at worst on a local link. The tolerance here
 * is two tiles, far looser, because it is watching for a wire that means
 * different things on the two sides rather than for prediction drift.
 */
export function agreesWithServer (ask, { tiles = 2, forMs = 3000 } = {}) {
  let disagreeingSince = null
  return async seen => {
    const me = seen.me
    if (!me || !seen.screen?.flying) { disagreeingSince = null; return null }

    const truth = await ask(seen)
    if (!truth) { disagreeingSince = null; return null }

    if (truth.alive !== me.alive) {
      return new Fault('client-server-disagree',
        `the client says its ship is ${me.alive ? 'alive' : 'destroyed'} ` +
        `and the server says ${truth.alive ? 'alive' : 'destroyed'}`,
        'This is the shape of the bug that showed DESTROYED on a healthy ' +
        'fleet: each side was healthy on its own.')
    }

    const off = tilesApart(truth, me)
    if (off <= tiles) { disagreeingSince = null; return null }

    // One reading apart is a snapshot in flight. Held apart is a wire that
    // means two different things.
    disagreeingSince = disagreeingSince || Date.now()
    if (Date.now() - disagreeingSince < forMs) return null
    return new Fault('client-server-disagree',
      `the client and the server have put this ship ${off.toFixed(1)} tiles ` +
      `apart for ${forMs}ms`,
      `client ${me.x},${me.y}  server ${truth.x},${truth.y}`)
  }
}

/**
 * The server agrees that somebody is here.
 *
 * The coarsest possible version of the check above, and the one the stage can
 * actually answer today: the arena publishes how many humans it holds, so a
 * client that believes it is flying while the arena counts nobody is a client
 * and a server that disagree about whether this session exists. It would not
 * have caught the DESTROYED-on-a-healthy-fleet bug, which needs a ship's
 * state and not a count. It does catch a client that thinks it joined.
 *
 * `forMs` covers the join and leave, where one side is legitimately ahead.
 */
export function serverSeesYou (stage, { forMs = 8000 } = {}) {
  let aloneSince = null
  return async seen => {
    if (!seen.screen?.joined || !seen.link?.connected) {
      aloneSince = null
      return null
    }
    const m = await stage.metrics()
    if (!m || m.vw_players === undefined) return null
    if (m.vw_players >= 1) { aloneSince = null; return null }

    aloneSince = aloneSince || Date.now()
    if (Date.now() - aloneSince < forMs) return null
    return new Fault('server-sees-nobody',
      `the client says it is in a room and the arena counts ${m.vw_players} humans`,
      `for ${forMs}ms; zone=${seen.room?.zone || '-'} room=${seen.room?.room}`)
  }
}

/**
 * Memory and frame time over a long run.
 *
 * Growth alone is not a leak: a browser allocates in steps and collects in
 * steps. What is reported is growth that survives the whole run, measured
 * between the first and last quarter, so a soak has to actually soak before
 * this says anything.
 */
export function soakCurves ({ minSamples = 60, growth = 1.6 } = {}) {
  const heap = []
  const frames = []
  return async (seen, pilot) => {
    const mem = await pilot.page.evaluate(
      () => performance.memory ? performance.memory.usedJSHeapSize : null)
    if (mem) heap.push(mem)
    if (seen.frame_ms) frames.push(seen.frame_ms)
    if (heap.length < minSamples) return null

    const quarter = Math.floor(heap.length / 4)
    const first = mean(heap.slice(0, quarter))
    const last = mean(heap.slice(-quarter))
    if (last > first * growth) {
      return new Fault('heap-growth',
        `the JS heap grew ${(last / first).toFixed(2)}x over the run`,
        `${(first / 1e6).toFixed(1)}MB to ${(last / 1e6).toFixed(1)}MB`)
    }
    return null
  }
}

function mean (xs) { return xs.reduce((a, b) => a + b, 0) / xs.length }

/** Run every watcher against one reading, and raise the first fault. */
export async function check (watchers, seen, pilot) {
  for (const watch of watchers) {
    const fault = await watch(seen, pilot)
    if (fault) throw fault
  }
}

export function standard (stage) {
  return [
    clientReportsNoFaults(stage),
    framesAdvance(),
    tickAdvances(),
    staysConnected(),
    selfConsistent(),
    serverSeesYou(stage)
  ]
}
