// The page the harness plays: the real client, built from the working tree,
// pointed at the stage.
//
// `vectorwake.directory` is compiled into game.projectc, so a build is how a
// client gets told where its fleet is. It could have been a query parameter
// instead, and it deliberately is not: a client that took its catalog address
// from the page would follow any link that named one, and a catalog names the
// meta-layer this client sends an account secret to. A build-time override
// cannot be aimed by a stranger.
//
// Building from the working tree rather than downloading a release is the
// point. The change under test is in the tree.

import { spawn, spawnSync } from 'node:child_process'
import { existsSync, statSync, readdirSync } from 'node:fs'
import { writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'
import { ROOT } from './stage.mjs'

const OUT_DIR = path.join(ROOT, 'client', 'dist')

function run (cmd, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd: ROOT, env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe']
    })
    let tail = ''
    const keep = chunk => { tail = (tail + chunk).slice(-4000) }
    child.stdout.on('data', keep)
    child.stderr.on('data', keep)
    child.on('exit', code => code === 0
      ? resolve()
      : reject(new Error(`${cmd} ${args.join(' ')} exited ${code}\n${tail}`)))
  })
}

// bob 1.13.0 is compiled to class file 69, which means JDK 25 or newer. An
// older one fails with an UnsupportedClassVersionError that talks about class
// file versions and never says "Java 25", so checking the version here rather
// than checking that some java exists saves the puzzle. A machine with
// JAVA_HOME set to an older JDK is the common case, not a broken one.
const NEEDS_JDK = 25

function javaVersion (home) {
  const java = path.join(home, 'bin', 'java')
  if (!existsSync(java)) return null
  const out = spawnSync(java, ['-version'], { encoding: 'utf8' })
  const said = `${out.stdout || ''}${out.stderr || ''}`
  const m = said.match(/version "(\d+)/)
  return m ? Number(m[1]) : null
}

function javaHome () {
  const tried = []
  const candidates = [
    process.env.JAVA_HOME,
    '/opt/jdk25',
    '/usr/lib/jvm/java-25-openjdk-amd64'
  ].filter(Boolean)
  for (const home of candidates) {
    const v = javaVersion(home)
    if (v && v >= NEEDS_JDK) return home
    tried.push(`${home} (${v ? `java ${v}` : 'no java'})`)
  }
  throw new Error(
    `bob needs JDK ${NEEDS_JDK} or newer; tried ${tried.join(', ')}. ` +
    'Set JAVA_HOME to one.')
}

/**
 * Build the client and pack it to one file the stage can serve.
 *
 * Returns the path to the page. Skips the build when the page is newer than
 * everything it is built from, because a driver being iterated on should not
 * pay two minutes a run for a client nobody has touched.
 */
export async function buildPage (directoryUrl, opts = {}) {
  await mkdir(OUT_DIR, { recursive: true })
  const page = path.join(OUT_DIR, 'harness.html')

  if (!opts.force && existsSync(page) && fresh(page)) return page

  const settings = path.join(OUT_DIR, 'harness.settings')
  await writeFile(settings,
    `[vectorwake]\ndirectory = ${directoryUrl}\n`)

  await run(path.join(ROOT, 'client', 'build.sh'),
    ['wasm-web', opts.variant || 'release', 'bundle'],
    { JAVA_HOME: javaHome(), VW_SETTINGS: settings })

  // Packed exactly the way CI packs what it publishes, which means no
  // `--fragment`. That flag strips the document down to its styles and its
  // body for an artifact host to wrap, and the shell's `window.vw*` helpers
  // live in the head, so a fragment loses the install prompt, the link
  // anchors, the ask forms and the viewport reconciler. The harness testing a
  // page the fleet does not serve would be worse than not testing at all.
  await run('python3', [
    path.join(ROOT, 'client', 'tools', 'single_file.py'),
    path.join(ROOT, 'client', 'bundle', 'wasm-web', 'vectorwake'),
    page
  ])
  return page
}

// Newer than every source the bundle is made of. Cheap and slightly
// conservative: it looks at the trees rather than at the dependency graph, so
// it rebuilds a little more often than it strictly must.
function fresh (page) {
  for (const name of ['manifest.webmanifest', 'icon-192.png', 'icon-512.png']) {
    if (!existsSync(path.join(path.dirname(page), name))) return false
  }
  const built = statSync(page).mtimeMs
  // `client/ext` is the native extension, and it was missing from this list.
  // It is the one source here that is not Lua: it wraps the simulation core
  // for the client and compiles a boot's worth of sound, so a run against a
  // stale bundle would be a run against a different game than the tree says.
  const watched = ['client/arena', 'client/ext', 'client/render', 'client/ui',
    'client/main', 'client/web', 'client/tools/single_file.py', 'client/game.project', 'client/build.sh',
    'sim/src', 'sim/include']
  for (const rel of watched) {
    const full = path.join(ROOT, rel)
    if (!existsSync(full)) continue
    if (newestUnder(full) > built) return false
  }
  return true
}

function newestUnder (dir) {
  const s = statSync(dir)
  if (!s.isDirectory()) return s.mtimeMs
  let newest = s.mtimeMs
  for (const entry of readdirSync(dir)) {
    const t = newestUnder(path.join(dir, entry))
    if (t > newest) newest = t
  }
  return newest
}
