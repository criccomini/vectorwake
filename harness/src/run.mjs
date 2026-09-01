// One run: a stage, a page, a pilot per profile, and a journey each.
//
// The watchers run beside the journey rather than after it. A journey that
// waits thirty seconds for a screen that will never come should fail on the
// reason it will never come, not on the timeout, and the reason is usually
// something a watcher saw twenty-nine seconds earlier.

import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { Stage, ROOT } from './stage.mjs'
import { buildPage } from './build.mjs'
import { Pilot } from './pilot.mjs'
import { PROFILES } from './profiles.mjs'
import { check, standard } from './oracles.mjs'
import { advisorySummary } from './pilot.mjs'

export const RUNS = path.join(ROOT, 'client', 'dist', 'harness-runs')

/**
 * Run one journey on one profile, with the watchers reading throughout.
 *
 * The journey and the watching are two loops that have to share one browser,
 * so the watching rides on the journey's own reads: `Pilot.read` records what
 * it saw, and this polls that record. A watcher therefore sees every reading
 * the journey sees, and cannot itself slow the journey down.
 */
async function watched (pilot, stage, journey, opts) {
  const watchers = standard(stage)
  let watching = true
  let fault = null

  // Neither of these two promises may reject. `Promise.race` settles on the
  // first, and a rejection arriving at the loser afterwards has nobody left to
  // catch it: Node calls that an unhandled rejection and, depending on how it
  // was started, kills the process. So both resolve, with a marker, and the
  // throwing happens out here where there is exactly one path.
  const watcher = (async () => {
    while (watching) {
      try {
        const seen = await pilot.read()
        if (seen) await check(watchers, seen, pilot)
      } catch (e) {
        fault = fault || e
        return
      }
      await new Promise(r => setTimeout(r, 250))
    }
  })()

  const walked = journey.run(pilot, opts)
    .then(out => ({ out }), error => ({ error }))

  const stopped = (async () => {
    while (watching && !fault) await new Promise(r => setTimeout(r, 100))
    return { faulted: true }
  })()

  try {
    const first = await Promise.race([walked, stopped])
    // A watcher's fault outranks the journey's own error: the journey usually
    // fails by timing out on a screen that never came, and the reason it never
    // came is what the watcher saw.
    if (fault) throw fault
    if (first.error) throw first.error
    return first.out
  } finally {
    watching = false
    await watcher
    // The journey may still be mid-press when a watcher fails. Let it settle
    // rather than leaving a promise running against a browser being closed.
    await walked
  }
}

export async function runOne (journey, profileName, opts = {}) {
  const stage = opts.stage
  const started = Date.now()
  const dir = path.join(RUNS, `${journey.name}-${profileName}`)
  await mkdir(dir, { recursive: true })

  const log = []
  const say = line => {
    log.push(`${((Date.now() - started) / 1000).toFixed(1)}s ${line}`)
    if (opts.verbose) process.stdout.write(`  [${profileName}] ${line}\n`)
  }

  let pilot
  try {
    pilot = await Pilot.open({
      url: stage.pageUrl,
      profile: profileName,
      hz: opts.hz,
      headed: opts.headed,
      video: opts.video ? dir : undefined
    })
    const out = await watched(pilot, stage, journey, { ...opts, log: say })
    await pilot.shot(path.join(dir, 'end.png'))
    return {
      ok: true,
      profile: profileName,
      journey: journey.name,
      out,
      advisories: advisorySummary(pilot.advisories),
      ms: Date.now() - started
    }
  } catch (e) {
    // Everything a person would want in order to understand this failure,
    // written down before anything is torn down: the client's last account of
    // itself, the servers' account of the same seconds, a picture, and the
    // console.
    const evidence = {
      journey: journey.name,
      profile: profileName,
      failed_after_ms: Date.now() - started,
      fault: { kind: e.kind || 'error', message: e.message, detail: e.detail },
      journey_log: log,
      last_reading: pilot?.last || null,
      advisories: advisorySummary(pilot?.advisories || []),
      client_errors: stage.clientErrors || [],
      console: pilot?.console?.slice(-60) || [],
      servers: stage.logsSince(Date.now() - started + 5000)
    }
    await writeFile(path.join(dir, 'failure.json'),
      JSON.stringify(evidence, null, 2))
    if (pilot) await pilot.shot(path.join(dir, 'failure.png')).catch(() => {})
    return {
      ok: false,
      profile: profileName,
      journey: journey.name,
      error: e,
      evidence: dir,
      ms: Date.now() - started
    }
  } finally {
    if (pilot) await pilot.close().catch(() => {})
  }
}

/** Every journey on every profile, on one stage. */
export async function runAll (journeys, opts = {}) {
  const names = opts.profiles || PROFILES.map(p => p.name)
  const stage = new Stage({
    page: await buildPage(`ws://127.0.0.1:9700`, opts),
    bots: opts.bots
  })
  await stage.up()
  const results = []
  try {
    for (const journey of journeys) {
      for (const name of names) {
        process.stdout.write(`== ${journey.name} on ${name}\n`)
        const r = await runOne(journey, name, { ...opts, stage })
        results.push(r)
        if (r.ok) {
          process.stdout.write(`   ok in ${(r.ms / 1000).toFixed(1)}s\n`)
          // Not failures, but not nothing either: the browser complained
          // about something while this was passing, and a run that never
          // shows them is a run that lets them accumulate unseen.
          for (const a of r.advisories) {
            process.stdout.write(`   note x${a.n}: ${a.text}\n`)
          }
        } else {
          process.stdout.write(
            `   FAILED after ${(r.ms / 1000).toFixed(1)}s: ` +
            `${r.error.kind || 'error'}: ${r.error.message}\n` +
            (r.error.detail ? `   ${r.error.detail.split('\n').join('\n   ')}\n` : '') +
            `   evidence in ${r.evidence}\n`)
        }
      }
    }
  } finally {
    await stage.down()
  }
  return results
}
