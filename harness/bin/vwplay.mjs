#!/usr/bin/env node
// Play the game.
//
//   node harness/bin/vwplay.mjs journeys                  every journey, every profile
//   node harness/bin/vwplay.mjs journeys --profile desktop
//   node harness/bin/vwplay.mjs journeys --headed --verbose
//   node harness/bin/vwplay.mjs journeys --flight 10      a shorter flight, while iterating
//
// Exits non-zero when anything failed, and leaves what it knows about each
// failure in client/dist/harness-runs/.

import { runAll, RUNS } from '../src/run.mjs'
import * as bootToMatch from '../src/journeys/boot-to-match.mjs'

const JOURNEYS = { 'boot-to-match': bootToMatch }

function parse (argv) {
  const opts = { profiles: null, verbose: false, headed: false }
  const rest = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--profile') opts.profiles = (opts.profiles || []).concat(argv[++i])
    else if (a === '--journey') rest.push(argv[++i])
    else if (a === '--flight') opts.flightMs = Number(argv[++i]) * 1000
    else if (a === '--hz') opts.hz = Number(argv[++i])
    else if (a === '--verbose') opts.verbose = true
    else if (a === '--headed') opts.headed = true
    else if (a === '--video') opts.video = true
    else if (a === '--rebuild') opts.force = true
    else if (a === '--no-bots') opts.bots = false
    else if (!a.startsWith('-')) rest.push(a)
    else {
      process.stderr.write(`vwplay: unknown option ${a}\n`)
      process.exit(2)
    }
  }
  return { opts, rest }
}

const { opts, rest } = parse(process.argv.slice(2))
const command = rest[0] || 'journeys'

if (command !== 'journeys') {
  process.stderr.write(
    `vwplay: ${command} is not built yet.\n` +
    'The monkey and the player come after the journeys; ' +
    'see docs/architecture/playtest-harness.md.\n')
  process.exit(2)
}

const wanted = rest.slice(1)
const journeys = wanted.length
  ? wanted.map(n => {
      const j = JOURNEYS[n]
      if (!j) {
        process.stderr.write(
          `vwplay: no journey ${n}; have ${Object.keys(JOURNEYS).join(', ')}\n`)
        process.exit(2)
      }
      return j
    })
  : Object.values(JOURNEYS)

const results = await runAll(journeys, opts)
const failed = results.filter(r => !r.ok)

process.stdout.write(
  `\n${results.length - failed.length}/${results.length} passed\n`)
if (failed.length) {
  process.stdout.write(`evidence under ${RUNS}\n`)
  process.exit(1)
}
