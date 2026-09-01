// One browser playing the game.
//
// Everything here goes in as a real browser event and comes back as the
// client's own account of its screen. Nothing calls into Lua, and nothing
// looks at a pixel. Input that skipped the input path would leave the input
// path untested, which is most of what there is to test on this side; and a
// pixel answers no question a test can ask, because the frame is composited on
// a GPU and every part of it is moving.
//
// The one rule worth restating, because it is the bug this harness was built
// after: a press goes to the box that takes it, not to the box that drew it.
// `tap` will not aim at a control whose own testimony says something else
// would swallow the press. It throws instead, naming the thief.

import { chromium } from 'playwright'
import { profile as findProfile } from './profiles.mjs'

// Software rendering: this runs headless on machines with no GPU, and the
// client is a WebGL app that will not start without one.
const LAUNCH_ARGS = [
  '--use-gl=swiftshader',
  '--enable-unsafe-swiftshader',
  '--no-sandbox',
  '--mute-audio'
]

// The keyboard the client ships with, from client/arena/controls.lua. Named
// by what a pilot is doing rather than by the key, so a journey reads as
// flying and a rebind is one line here.
export const KEYS = {
  left: 'ArrowLeft',
  right: 'ArrowRight',
  thrust: 'ArrowUp',
  reverse: 'ArrowDown',
  guns: 'd',
  bombs: 'a',
  charge1: 'w',
  charge2: 's',
  multi: '`',
  map: 'm',
  players: 'p',
  help: 'h',
  menu: 'Escape',
  select: 'Enter',
  up: 'ArrowUp',
  down: 'ArrowDown'
}

export class Fault extends Error {
  constructor (kind, message, detail) {
    super(message)
    this.kind = kind
    this.detail = detail
  }
}

export class Pilot {
  constructor (opts) {
    this.opts = opts
    this.profileName = opts.profile
    this.profile = findProfile(opts.profile)
    this.faults = []
    this.console = []
    this.last = null
  }

  static async open (opts) {
    const pilot = new Pilot(opts)
    await pilot.boot()
    return pilot
  }

  async boot () {
    const p = this.profile
    this.browser = await chromium.launch({
      headless: this.opts.headed !== true,
      args: LAUNCH_ARGS
    })
    this.context = await this.browser.newContext({
      viewport: p.viewport,
      deviceScaleFactor: p.deviceScaleFactor,
      hasTouch: p.hasTouch,
      isMobile: p.isMobile || false,
      recordVideo: this.opts.video ? { dir: this.opts.video, size: p.viewport } : undefined
    })

    // Arming, before anything on the page runs. Deliberately not a query
    // parameter: nothing in a URL can turn this on, so a link cannot make
    // somebody else's client start describing their screen.
    const hz = this.opts.hz || 10
    await this.context.addInitScript(`window.vwProbeHz = ${hz}`)

    this.page = await this.context.newPage()

    // What fails a run, and what only gets written down.
    //
    // An uncaught exception is the page's own failure and fails the run. A
    // console error might be either: Defold surfaces a Lua error through
    // `console.error`, and so does the browser when it wants to complain
    // about, say, a preventDefault it declined to honor. The two are not the
    // same thing and this used to treat them as one, which meant a Chrome
    // advisory about touch dispatch ended a run that was flying perfectly.
    //
    // The client already tells the difference. Its diagnostics wrap
    // `console.error`, so anything page script logs is reported to the stage's
    // endpoint and counted as a fault there, while a message the browser
    // itself printed never reaches that wrapper. So console errors are
    // recorded here as advisories: reported at the end of a run, never fatal
    // on their own.
    this.advisories = []
    this.page.on('console', m => {
      const text = m.text()
      this.console.push({ at: Date.now(), type: m.type(), text })
      if (this.console.length > 2000) this.console.shift()
      if (m.type() === 'error') this.advisories.push({ at: Date.now(), text })
    })
    this.page.on('pageerror', e => {
      this.faults.push(new Fault('pageerror', e.message))
    })
    this.page.on('crash', () => {
      this.faults.push(new Fault('crash', 'the page crashed'))
    })

    await this.page.goto(this.opts.url, { waitUntil: 'domcontentloaded' })
  }

  // --- reading -------------------------------------------------------------

  /** The client's account of its own screen, or null before the first one. */
  async read () {
    const seen = await this.page.evaluate(() => window.vwProbe || null)
    if (seen) {
      if (seen.error) throw new Fault('probe', `the probe failed: ${seen.error}`)
      this.last = seen
      this.lastAt = Date.now()
    }
    return seen
  }

  /**
   * Wait until the client says `want` of itself.
   *
   * Every wait in this harness is a wait for a state, never a sleep for a
   * duration: a sleep long enough to be reliable on a slow machine is a sleep
   * wasted on a fast one, and a sleep short enough to be quick is a flake.
   */
  async until (what, want, opts = {}) {
    const timeout = opts.timeout || 30000
    const until = Date.now() + timeout
    let last = null
    while (Date.now() < until) {
      this.throwFaults()
      const seen = await this.read()
      if (seen) {
        last = seen
        if (want(seen)) return seen
      }
      await this.page.waitForTimeout(opts.every || 100)
    }
    throw new Fault('timeout',
      `waited ${timeout}ms for ${what}`,
      last ? describe(last) : 'the probe never published; is the client booting?')
  }

  /** Every fault seen so far, raised as one. */
  throwFaults () {
    if (!this.faults.length) return
    const first = this.faults[0]
    first.detail = this.faults.map(f => `${f.kind}: ${f.message}`).join('\n')
    throw first
  }

  // --- pressing ------------------------------------------------------------

  async press (name, ms = 40) {
    const key = KEYS[name] || name
    await this.page.keyboard.down(key)
    await this.page.waitForTimeout(ms)
    await this.page.keyboard.up(key)
  }

  async hold (names, ms) {
    const keys = (Array.isArray(names) ? names : [names]).map(n => KEYS[n] || n)
    for (const k of keys) await this.page.keyboard.down(k)
    await this.page.waitForTimeout(ms)
    for (const k of keys) await this.page.keyboard.up(k)
  }

  async down (name) { await this.page.keyboard.down(KEYS[name] || name) }
  async up (name) { await this.page.keyboard.up(KEYS[name] || name) }

  /**
   * Press the control that fires `action`, whichever hand this profile has.
   *
   * The box is chosen by what a press on it actually resolves to, not by what
   * published it. A control that something else covers is a failure here and
   * not a silent no-op, because a silent no-op is precisely how the roster's
   * fly-this-ship press stayed dead for weeks.
   */
  async tap (action, opts = {}) {
    const seen = await this.until(`a control that fires ${action}`,
      s => pickBox(s, action, opts.value) || covered(s, action, opts.value),
      { timeout: opts.timeout || 10000 })

    let box = pickBox(seen, action, opts.value)
    if (!box) {
      const thief = covered(seen, action, opts.value)
      throw new Fault('covered',
        `${action} is on screen but a press there fires ${thief.hits}`,
        'The control is published under something that takes the press. ' +
        'Reach it with the cursor instead, or fix the priority.')
    }

    // And where it will still be when the press lands.
    //
    // Panels in this client arrive by sliding: a column rises out of the key
    // it was raised from and a page climbs up through the bottom edge, over
    // about a fifth of a second. A press aimed at a box read mid-slide lands
    // where that box used to be, which is a different control by then. That is
    // not a flake to retry, it is a press on the wrong row: it opened the
    // fourth stop of the menu column instead of the second, and did it every
    // time.
    box = await this.stillness(action, opts) || box

    if (this.profile.input === 'touch') {
      await this.touch(box.x, box.y)
    } else {
      // Split, because a synthetic click that arrives as one event does not
      // always register: the client reads a press and a release.
      await this.page.mouse.move(box.x, box.y)
      await this.page.waitForTimeout(30)
      await this.page.mouse.down()
      await this.page.waitForTimeout(30)
      await this.page.mouse.up()
    }
    return box
  }

  /**
   * The box `action` publishes, once it has stopped moving, or null if it
   * never does.
   *
   * Two readings that agree is the whole test. Nothing on this screen moves
   * except while something is opening or closing, so a box in the same place
   * across a beat is a box at rest, and one still travelling is one this
   * press has no business landing on yet.
   */
  async stillness (action, opts = {}, beat = 90, tries = 25) {
    let last = null
    for (let i = 0; i < tries; i++) {
      const seen = await this.read()
      const box = pickBox(seen, action, opts.value)
      if (box && last &&
          Math.abs(box.x - last.x) < 1 && Math.abs(box.y - last.y) < 1) {
        return box
      }
      last = box
      await this.page.waitForTimeout(beat)
    }
    return last
  }

  /** Touch a flight pad by name: guns, bombs, or a charge slot. */
  async tapPad (name, ms = 60) {
    const seen = await this.until(`the ${name} pad`, s => s.pads && s.pads[name])
    const pad = seen.pads[name]
    if (!pad || pad.absent) throw new Fault('pad', `no ${name} pad on this hull`)
    await this.touch(pad.x, pad.y, ms)
  }

  /**
   * One finger down and up.
   *
   * Every touch this harness sends goes through here and through the one CDP
   * session below, deliberately. Playwright's own `touchscreen.tap` drives the
   * same pipeline by a different route, and a session that used both left
   * Chrome's touch-point bookkeeping disagreeing with itself: the next
   * touchstart arrived non-cancelable, the client's preventDefault was
   * refused, and the console error read exactly like a page that was
   * scrolling. It was the harness holding the glass wrong, not the game.
   */
  async touch (x, y, ms = 40) {
    await this.finger('touchStart', x, y)
    await this.page.waitForTimeout(ms)
    await this.finger('touchEnd', x, y)
  }

  /**
   * The stick, which is anywhere on the left of the screen: press, drag to say
   * where the nose should point, hold, lift.
   *
   * Playwright's touchscreen offers a tap and nothing else, so a held drag
   * goes through CDP, which is the same event stream a finger produces.
   */
  async stick (dx, dy, ms = 300) {
    const seen = this.last || await this.read()
    const w = seen?.view?.css_w || this.profile.viewport.width
    const h = seen?.view?.css_h || this.profile.viewport.height
    // A spot on the left half that no pad owns; the stick is relative, so
    // where it starts only has to be its own.
    const ox = w * 0.22
    const oy = h * 0.6
    await this.finger('touchStart', ox, oy)
    await this.finger('touchMove', ox + dx, oy + dy)
    await this.page.waitForTimeout(ms)
    await this.finger('touchEnd', ox + dx, oy + dy)
  }

  async finger (type, x, y) {
    this.cdp = this.cdp || await this.context.newCDPSession(this.page)
    await this.cdp.send('Input.dispatchTouchEvent', {
      type,
      touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }]
    })
  }

  /**
   * Say that the next disconnect is wanted.
   *
   * A journey that presses leave is about to drop the wire on purpose, and
   * `staysConnected` cannot tell that from a room disappearing. Clears itself
   * once the client is home.
   */
  async leave (press) {
    this.leaving = true
    try {
      await press()
      await this.until('the landing', s => s.screen.landing && !s.screen.joined)
    } finally {
      this.leaving = false
    }
  }

  /** Whatever this profile uses to wake its input path. */
  async wake () {
    if (this.profile.input === 'touch') {
      // Pads are not drawn until the client has seen a finger, so a mobile
      // session's first press has to be a plain touch on the canvas.
      const p = this.profile.viewport
      await this.touch(p.width / 2, p.height / 2)
    } else {
      await this.page.mouse.move(4, 4)
    }
  }

  async shot (file) {
    await this.page.screenshot({ path: file })
  }

  async close () {
    if (this.context) await this.context.close()
    if (this.browser) await this.browser.close()
  }
}

// A box whose press really does fire `action`.
function pickBox (seen, action, value) {
  if (!seen || !seen.boxes) return null
  return seen.boxes.find(b =>
    b.hits === action &&
    (value === undefined || b.hits_value === value)) || null
}

// The box that drew `action` but does not get the press, so a failure can name
// what is on top of it instead of saying the control is missing.
function covered (seen, action, value) {
  if (!seen || !seen.boxes) return null
  return seen.boxes.find(b =>
    b.action === action &&
    (value === undefined || b.value === value)) || null
}

function describe (s) {
  const screen = s.screen || {}
  const where = screen.landing
    ? `landing${screen.panel ? ` panel=${screen.panel}` : ''}`
    : `in a room${screen.menu_open ? ' menu=open' : ''}`
  return [
    `last reading #${s.seq}: ${where}`,
    `joined=${screen.joined} watching=${screen.watching} flying=${screen.flying}`,
    `tick=${s.tick} connected=${s.link?.connected} zone=${s.room?.zone || '-'}`,
    `cursor=${s.cursor?.action || '-'} go=${s.cursor?.go || '-'}`,
    `controls: ${[...new Set((s.boxes || []).map(b => b.hits).filter(Boolean))].join(' ')}`
  ].join('\n  ')
}

/** Advisories grouped by message, for a run summary that is one line each. */
export function advisorySummary (advisories) {
  const counts = new Map()
  for (const a of advisories) {
    const key = a.text.split('\n')[0].slice(0, 120)
    counts.set(key, (counts.get(key) || 0) + 1)
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([text, n]) => ({ text, n }))
}
