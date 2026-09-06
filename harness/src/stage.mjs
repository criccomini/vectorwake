// The fleet on loopback: a directory, an arena, the bots, and the page.
//
// Everything the harness plays against runs here, in this process's children,
// on 127.0.0.1, in cleartext. That is not a shortcut around TLS. The directory
// refuses a bearer token from a remote peer over cleartext and accepts one
// from loopback, which is exactly the arrangement `docker-compose.local.yml`
// describes for a laptop, minus Caddy, because the harness has no hostname to
// route and no certificate to present.
//
// Two things are deliberately absent.
//
// There is no meta-layer, so no database and no accounts: the catalog is
// copied with its `[meta]` block removed, and everyone who joins is a guest.
// What that costs is the account path, which a journey cannot walk here. What
// it buys is a stage that starts in two seconds from nothing.
//
// And there is no rated filing. `VW_REPORT=0` because a harness session's
// kills are real enough to move a ladder that belongs to other people.

import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { mkdtemp, rm, readFile, writeFile, mkdir, cp } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'

export const ROOT = path.resolve(import.meta.dirname, '..', '..')

// Ports nobody else on the box is using, and far from the fleet's own, so a
// harness run and a hand-started server cannot quietly join each other.
export const PORTS = {
  directory: 9700, arena: 9701, page: 9702, arenaMetrics: 9703
}

const START_TIMEOUT_MS = 30000

function serverBinary () {
  for (const variant of ['release', 'debug']) {
    const p = path.join(ROOT, 'server', 'target', variant, 'vectorwake-server')
    if (existsSync(p)) return p
  }
  throw new Error(
    'no server binary; run: cargo build --manifest-path server/Cargo.toml')
}

// A pool token this process invents and throws away. The catalog names the
// digest of a token rather than the token, so the pair has to be made together
// and there is nothing to keep.
function poolCredentials () {
  const token = createHash('sha256')
    .update(`vwplay ${process.pid} ${Date.now()} ${Math.random()}`)
    .digest('hex')
  const digest = 'sha256:' + createHash('sha256').update(token).digest('hex')
  return { token, digest }
}

// Everything a child writes, kept per role so a failure report can quote the
// server's own account of the same second the client complained about.
class Log {
  constructor (name) { this.name = name; this.lines = [] }

  absorb (stream) {
    let held = ''
    stream.setEncoding('utf8')
    stream.on('data', chunk => {
      held += chunk
      const parts = held.split('\n')
      held = parts.pop()
      for (const line of parts) {
        this.lines.push({ at: Date.now(), line })
        if (this.lines.length > 5000) this.lines.shift()
      }
    })
  }

  // Lines from the last `ms` milliseconds: what the server was saying while
  // the thing the harness noticed was happening.
  since (ms) {
    const cut = Date.now() - ms
    return this.lines.filter(l => l.at >= cut).map(l => l.line)
  }

  saw (needle) {
    return this.lines.some(l => l.line.includes(needle))
  }

  async waitFor (needle, timeout = START_TIMEOUT_MS) {
    const until = Date.now() + timeout
    while (Date.now() < until) {
      if (this.saw(needle)) return true
      await new Promise(r => setTimeout(r, 100))
    }
    throw new Error(
      `${this.name}: waited ${timeout}ms for ${JSON.stringify(needle)}\n` +
      this.lines.slice(-25).map(l => `  ${this.name}| ${l.line}`).join('\n'))
  }
}

export class Stage {
  constructor (opts = {}) {
    this.opts = opts
    this.children = []
    this.logs = {}
    this.dir = null
    this.page = null
  }

  get directoryUrl () { return `ws://127.0.0.1:${PORTS.directory}` }
  get arenaUrl () { return `ws://127.0.0.1:${PORTS.arena}` }
  get pageUrl () { return `http://127.0.0.1:${PORTS.page}/` }

  spawnRole (name, args, env) {
    const child = spawn(serverBinary(), args, {
      cwd: ROOT,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe']
    })
    const log = new Log(name)
    log.absorb(child.stdout)
    log.absorb(child.stderr)
    this.logs[name] = log
    this.children.push(child)
    child.on('exit', (code, signal) => {
      if (!this.stopping && code !== 0) {
        log.lines.push({ at: Date.now(), line: `*** exited ${code}/${signal}` })
      }
    })
    return log
  }

  // The catalog, minus its accounts. Copied rather than edited in place: the
  // real one is a committed artifact and a harness has no business touching
  // it.
  async catalogFor (digest) {
    const dir = path.join(this.dir, 'catalog')
    await cp(path.join(ROOT, 'catalog'), dir, { recursive: true })
    const file = path.join(dir, 'catalog.toml')
    let toml = await readFile(file, 'utf8')
    const without = toml.replace(/^\[meta\]\nurl = .*\nkey = .*\n/m, '')
    if (without === toml) {
      throw new Error('catalog: no [meta] block to remove; the shape changed')
    }
    toml = without.replace(/token = "env:VW_POOL_DIGEST"/, `token = "${digest}"`)
    await writeFile(file, toml)
    return dir
  }

  async up () {
    this.dir = await mkdtemp(path.join(tmpdir(), 'vwplay-'))
    await mkdir(path.join(this.dir, 'data'), { recursive: true })
    const { token, digest } = poolCredentials()
    const catalog = await this.catalogFor(digest)

    const shared = { VW_ACCOUNTS: '0', VW_REPORT: '0' }

    const directory = this.spawnRole('directory',
      ['directory', `127.0.0.1:${PORTS.directory}`, catalog], shared)
    await directory.waitFor(`listening on ws://127.0.0.1:${PORTS.directory}`)

    const arena = this.spawnRole('arena',
      [`127.0.0.1:${PORTS.arena}`, path.join(this.dir, 'data')], {
        ...shared,
        VW_DIRECTORY: this.directoryUrl,
        VW_TOKEN: token,
        VW_ADDRESS: this.arenaUrl,
        VW_REGION: 'harness',
        // The arena's own account of itself, which is the harness's only
        // second opinion. It is coarse (a count of humans, not a ship's
        // position) and it is still the only thing on the stage that can
        // contradict the client.
        VW_METRICS: `127.0.0.1:${PORTS.arenaMetrics}`
      })
    // Registered is not enough. Until the directory has reached back and
    // proved the address, the arena is not offered to anybody browsing, and a
    // client would find an empty games list and be right to.
    await directory.waitFor(`at ${this.arenaUrl}: verified`)
    await arena.waitFor('serving zone')

    if (this.opts.bots !== false) {
      const bots = this.spawnRole('bots', ['bots'], {
        ...shared, VW_DIRECTORY: this.directoryUrl, VW_TOKEN: token
      })
      await bots.waitFor('bots, wants')
    }

    await this.servePage()
    return this
  }

  async servePage () {
    const file = this.opts.page
    if (!file || !existsSync(file)) {
      throw new Error(`no page to serve at ${file}; build one first`)
    }
    const html = await readFile(file)
    const assets = new Map()
    for (const [name, type] of [
      ['manifest.webmanifest', 'application/manifest+json'],
      ['icon-192.png', 'image/png'],
      ['icon-512.png', 'image/png']
    ]) {
      assets.set('/' + name, { body: await readFile(path.join(path.dirname(file), name)), type })
    }
    this.clientErrors = []
    this.page = createServer((req, res) => {
      // The client's own diagnostics post here. It is the same endpoint the
      // fleet's meta-layer serves, and standing it up is what turns "some
      // console output looked bad" into a structural signal: the page decides
      // what counts as a fault in the game, dedupes it, and hands over a
      // stack. A browser's own console noise never comes through here, because
      // the reporter wraps `console.error` and only sees what page script
      // calls.
      if (req.method === 'POST' && req.url === '/meta/v1/client-error') {
        let body = ''
        req.on('data', d => { body += d })
        req.on('end', () => {
          try {
            this.clientErrors.push({ at: Date.now(), ...JSON.parse(body) })
          } catch {
            this.clientErrors.push({ at: Date.now(), kind: 'unparsed', message: body.slice(0, 500) })
          }
          res.writeHead(204).end()
        })
        return
      }
      const asset = assets.get(new URL(req.url, this.pageUrl).pathname)
      if (asset) {
        res.writeHead(200, { 'content-type': asset.type, 'cache-control': 'no-store' })
        res.end(asset.body)
        return
      }
      // Runtime assets are embedded; the install metadata is served above.
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store'
      })
      res.end(html)
    })
    this.page.listen(PORTS.page, '127.0.0.1')
    await once(this.page, 'listening')
  }

  /**
   * The arena's own numbers, as a map.
   *
   * Prometheus text, parsed to the extent the harness needs: a name and a
   * value per line, comments dropped. Returns null when the arena is not
   * answering, which a caller should treat as "no second opinion" rather than
   * as a fault, because the harness's job is to test the client.
   */
  async metrics () {
    try {
      const res = await fetch(
        `http://127.0.0.1:${PORTS.arenaMetrics}/metrics`,
        { signal: AbortSignal.timeout(2000) })
      if (!res.ok) return null
      const out = {}
      for (const line of (await res.text()).split('\n')) {
        if (!line || line.startsWith('#')) continue
        const at = line.lastIndexOf(' ')
        if (at < 0) continue
        const value = Number(line.slice(at + 1))
        if (!Number.isNaN(value)) out[line.slice(0, at)] = value
      }
      return out
    } catch {
      return null
    }
  }

  // Every server's account of the last `ms`, for a failure report.
  logsSince (ms) {
    const out = {}
    for (const [name, log] of Object.entries(this.logs)) out[name] = log.since(ms)
    return out
  }

  async down () {
    this.stopping = true
    if (this.page) this.page.close()
    for (const child of this.children) {
      if (child.exitCode === null) child.kill('SIGTERM')
    }
    // A room closes on a quiet timeout or a SIGTERM, so give it the moment it
    // needs to do that before insisting.
    await new Promise(r => setTimeout(r, 400))
    for (const child of this.children) {
      if (child.exitCode === null) child.kill('SIGKILL')
    }
    if (this.dir) await rm(this.dir, { recursive: true, force: true })
  }
}
