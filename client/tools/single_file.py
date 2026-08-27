#!/usr/bin/env python3
"""Fold a Defold HTML5 bundle into one self-contained page.

Defold ships a directory: an index, a loader, an engine .js, a .wasm, and a
split game archive, all fetched over HTTP at startup. That is the right shape
for a web server and the wrong shape for handing somebody a build to try.

This inlines the lot into a single .html with no network requests at all --
not to a CDN, not to its own origin. It works from a static host, from a
strict content-security-policy, and from a file:// URL.

    ./client/tools/single_file.py client/bundle/wasm-web/vectorwake out.html

The interception point is FileLoader.request, which is the one funnel every
asset load goes through, so this does not have to fake XMLHttpRequest. The
exception is the engine .js: the loader injects that by URL into a <script>
tag, which would bypass any funnel, so loadAndRunScriptAsync is replaced with
one that injects the source it already has.
"""

import base64
import json
import os
import re
import sys

# Everything the loader asks for, by basename. The pthread pair is deliberately
# absent: it is a second copy of the engine for browsers with SharedArrayBuffer,
# and embedding both would double a payload for no gain.
def collect(bundle, exe):
    want = [
        f"{exe}_wasm.js",
        f"{exe}.wasm",
        os.path.join("archive", "archive_files.json"),
    ]
    desc = os.path.join(bundle, "archive", "archive_files.json")
    with open(desc) as f:
        for entry in json.load(f)["content"]:
            for piece in entry["pieces"]:
                want.append(os.path.join("archive", piece["name"]))

    assets = {}
    for rel in want:
        path = os.path.join(bundle, rel)
        with open(path, "rb") as f:
            assets[os.path.basename(rel)] = base64.b64encode(f.read()).decode()
    return assets


SHIM = """
// --- self-contained loader -------------------------------------------------
// Every asset is embedded below. FileLoader.request is the single funnel the
// engine loads through, so replacing it removes the network entirely.
(function () {
  var B64 = __ASSETS__;
  var CACHE = {};
  var SERVED = 0, TOTAL = 0;
  for (var _k in B64) TOTAL++;

  function bytes(name) {
    if (!CACHE[name]) {
      var bin = atob(B64[name]);
      var out = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      CACHE[name] = out;
    }
    return CACHE[name];
  }

  function text(name) {
    return new TextDecoder("utf-8").decode(bytes(name));
  }

  // The loader builds paths like "split/archive_files.json"; the basename is
  // what identifies an asset here.
  function pick(url) {
    var n = String(url).split("?")[0].split("/").pop();
    return Object.prototype.hasOwnProperty.call(B64, n) ? n : null;
  }

  // One engine is embedded, not two, so do not let the loader ask for the
  // pthread build. Streaming would go through fetch() and miss this shim.
  Module["isWASMPthreadSupported"] = false;
  EngineLoader.stream_wasm = false;

  FileLoader.request = function (url, method, responseType) {
    var name = pick(url);
    return {
      send: function () {
        var self = this;
        setTimeout(function () {
          if (!name) {
            if (self.onerror) self.onerror({ status: 404 }, "not embedded: " + url);
            return;
          }
          var raw = bytes(name);
          var xhr = {
            readyState: 4,
            status: 200,
            getResponseHeader: function (h) {
              return /content-length/i.test(h) ? String(raw.length) : null;
            }
          };
          if (method === "HEAD") {
            xhr.response = null;
          } else if (responseType === "arraybuffer") {
            // A copy: the engine keeps this buffer past the call.
            xhr.response = raw.buffer.slice(
              raw.byteOffset, raw.byteOffset + raw.byteLength);
          } else {
            var s = text(name);
            xhr.response = responseType === "json" ? JSON.parse(s) : s;
          }
          if (self.onprogress) {
            self.onprogress(xhr, { loaded: raw.length, total: raw.length }, 0);
          }
          // Half the bar is decoding what is embedded here; the rest is the
          // engine compiling, which nothing can measure.
          if (window.vwProgress) window.vwProgress(++SERVED / TOTAL * 0.55);
          if (self.onload) self.onload(xhr, {});
        }, 0);
      }
    };
  };

  // The stock version injects <script src=...>, which would fetch over the
  // network and bypass everything above. Inject the source instead.
  EngineLoader.loadAndRunScriptAsync = function (src) {
    var name = pick(src);
    var script = document.createElement("script");
    script.type = "text/javascript";
    script.textContent = text(name);
    document.body.appendChild(script);
  };

  // Keyboard. The engine listens on the canvas, and a canvas that never gets
  // focus never sees a key. Served straight from a file that is automatic
  // enough; embedded in a frame it is not, and the game looks broken while
  // running perfectly. So: take focus as soon as there is a canvas, take it
  // back on any pointer down, and stop the arrow keys and space from
  // scrolling whatever page we happen to be sitting in.
  //
  // None of it while a card is asking for type. The lines a player fills in
  // are real input elements over the canvas, which is the only way a browser
  // will raise a phone's keyboard, and all three guards here are hostile to
  // one: focus taken back on the very tap that was meant to open the
  // keyboard, and space swallowed before it reaches the field. A call sign
  // has a space in it, so that last one is not a detail: "Vesper 412" was
  // typed and "Vesper412" arrived.
  var KEYS = {
    ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1,
    Space: 1, Tab: 1
  };
  function typing(e) {
    var f = document.getElementById("vw-ask");
    if (!f) return false;
    // On the way down, focus has not moved yet and the target is what will
    // take it; at rest, the active element is the answer.
    if (e && e.target && e.target.nodeType && f.contains(e.target)) return true;
    return f.contains(document.activeElement);
  }
  function grabFocus(e) {
    if (typing(e)) return;
    var c = document.getElementById("canvas");
    if (c) {
      c.setAttribute("tabindex", "0");
      try { c.focus({ preventScroll: true }); } catch (e2) { c.focus(); }
    }
  }
  window.addEventListener("load", grabFocus);
  document.addEventListener("pointerdown", grabFocus, true);
  document.addEventListener("keydown", function (e) {
    if (!typing(e) && KEYS[e.code]) e.preventDefault();
  }, { passive: false, capture: true });
  var tries = 0;
  var poll = setInterval(function () {
    grabFocus();
    if (++tries > 40 || document.activeElement === document.getElementById("canvas")) {
      clearInterval(poll);
    }
  }, 250);

  // Loading.
  //
  // Four megabytes of engine have to arrive and compile before the game can
  // draw anything, and what a player saw meanwhile was a gray bar on black --
  // a page that has not started yet. So the page starts without it: the same
  // starfield, at the same three depths and the same colors, drawn in plain
  // canvas 2D while the wasm compiles behind it. The wordmark sits in the
  // middle and the engine's own progress drives one hairline under it.
  //
  // The game says when it is up, from arena.script, rather than the loader
  // guessing: "the runtime initialized" is several seconds before "there is
  // an arena on screen", and fading out at the wrong one of those is how a
  // seamless hand-off becomes a black flash.
  //
  // The name is the lockup ui.lua draws on the menu, down to the numbers, so
  // the hand-off changes nothing about it either. It was the letters of
  // "vectorwake" spaced out in whatever monospace the browser had, which is a
  // placeholder that outlived the mark being drawn.
  (function () {
    var cv = document.createElement("canvas");
    cv.id = "vw-preboot";
    cv.style.cssText =
      "position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:5;" +
      "background:#05070d;transition:opacity .45s ease-out";
    document.body.appendChild(cv);
    var g = cv.getContext("2d");
    var w = 0, h = 0, t0 = Date.now(), done = false, progress = 0;

    // The menu's own face. Defold bakes it into a distance-field atlas that
    // only the engine can read, so the page carries the file itself and drops
    // back to a monospace until it has decoded. The loader redraws every
    // frame, so there is nothing to wait for: the name simply arrives.
    //
    // Copyright 2018 The Chakra Petch Project Authors
    // (https://github.com/m4rc1e/Chakra-Petch.git), licensed under the SIL
    // Open Font License 1.1, whose second condition is that this notice
    // travels with the font. client/ui/menu-LICENSE.txt is the full text.
    var FACE = '"vwmenu",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace';
    try {
      var ff = new FontFace("vwmenu",
                            "url(data:font/ttf;base64,__MENU_FONT__)");
      ff.load().then(function (f) { document.fonts.add(f); },
                     function () {});
    } catch (e) {}

    // The loading mark uses the canonical 84 by 104 geometry from
    // client/web/logo.svg. The orange Lambda and cyan W share one chevron;
    // drawing that centerline once keeps its black gap even at every corner.
    var MK_W = 84, MK_H = 104;
    var LOGO_EM = 0.74, LOGO_GAP = 0.30, LOGO_DROP = 0.12;
    var MK_SPAN = MK_W / MK_H;
    var INK = "#dfe9f5", FRIEND = "#4fd6ff";
    var LOGO_ORANGE = "#ff9d22", LOGO_CYAN = "#27c5ed";

    // `ox` is the mark's left edge and `oy` is its bottom edge.
    function mark(ox, oy, mh) {
      var k = mh / MK_H;
      g.save();
      g.translate(ox, oy - mh);
      g.scale(k, k);

      g.fillStyle = LOGO_ORANGE;
      g.beginPath();
      g.moveTo(42, 0); g.lineTo(84, 67); g.lineTo(66, 78);
      g.lineTo(42, 53); g.lineTo(18, 78); g.lineTo(0, 67);
      g.closePath();
      g.fill();

      g.fillStyle = LOGO_CYAN;
      g.beginPath();
      g.moveTo(0, 67); g.lineTo(18, 78); g.lineTo(42, 53);
      g.lineTo(66, 78); g.lineTo(84, 67); g.lineTo(60, 103);
      g.lineTo(42, 74); g.lineTo(24, 103);
      g.closePath();
      g.fill();

      g.strokeStyle = "#000";
      g.lineWidth = 3;
      g.lineCap = "square";
      g.lineJoin = "miter";
      g.miterLimit = 20;
      g.beginPath();
      g.moveTo(0, 67); g.lineTo(18, 78); g.lineTo(42, 53);
      g.lineTo(66, 78); g.lineTo(84, 67);
      g.stroke();
      g.restore();
    }

    // The same three depths of star world.lua uses, at the same density and
    // in the same colors, so the moment the engine takes over the sky carries
    // on looking like itself. The engine draws more than this behind them,
    // clouds and a band and whatever set pieces the map hangs out at its rim,
    // and those arrive with the first real frame.
    var LAYERS = [
      {k: 0.18, cell: 54, size: 1.1, col: "#2a3a58", fill: 13},
      {k: 0.36, cell: 92, size: 1.6, col: "#4a6089", fill: 11},
      {k: 0.60, cell: 168, size: 2.3, col: "#93a9c8", fill: 9}
    ];
    // Star temperature, and it is worked out here the way world.lua works it
    // out: each color scaled to the luminance its layer already had, so what
    // changes between one star and the next is hue and not brightness.
    var TEMPS = ["#9fbcff", "#f2f5ff", "#ffd08a", "#ff9a52"];
    var PICK = [0, 1, 0, 1, 1, 2, 0, 1, 0, 0, 1, 2, 0, 1, 3, 1];
    var FAT = [0, 0, 0.4, 0.6];
    function bits(hex) {
      var n = parseInt(hex.slice(1), 16);
      return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
    function lum(c) { return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]; }
    for (var li = 0; li < LAYERS.length; li++) {
      var base = bits(LAYERS[li].col);
      LAYERS[li].cols = TEMPS.map(function (t) {
        var c = bits(t), k = lum(base) / lum(c);
        return "rgb(" + Math.round(c[0] * k) + "," + Math.round(c[1] * k) +
               "," + Math.round(c[2] * k) + ")";
      });
    }
    function lcg(s) { return (s * 48271) % 2147483647; }

    function frame() {
      if (cv.width !== innerWidth * 1 || cv.height !== innerHeight * 1) {
        w = cv.width = innerWidth;
        h = cv.height = innerHeight;
      }
      g.fillStyle = "#05070d";
      g.fillRect(0, 0, w, h);
      // Drifting, because a still starfield reads as a picture of a game and
      // a moving one reads as the game.
      var t = (Date.now() - t0) / 1000;
      for (var li = 0; li < LAYERS.length; li++) {
        var L = LAYERS[li], c = L.cell;
        var ox = -t * 14 * L.k, oy = -t * 5 * L.k;
        var i0 = Math.floor(-ox / c) - 1, i1 = Math.floor((w - ox) / c) + 1;
        var j0 = Math.floor(-oy / c) - 1, j1 = Math.floor((h - oy) / c) + 1;
        for (var j = j0; j <= j1; j++) {
          for (var i = i0; i <= i1; i++) {
            var s = lcg(((i * 1973 + j * 9277 + li * 26699) % 2147483646 + 2147483646) % 2147483646 + 1);
            if (s % 16 >= L.fill) continue;
            s = lcg(s);
            var px = (i + s / 2147483647) * c + ox;
            s = lcg(s);
            var py = (j + s / 2147483647) * c + oy;
            // A draw of its own for the color and the shade, which is what
            // world.lua spends here too.
            s = lcg(s);
            var tmp = PICK[s % 16];
            g.fillStyle = L.cols[tmp];
            g.globalAlpha = 0.45 + (s % 8) / 8 * 0.55;
            var size = L.size + FAT[tmp];
            g.fillRect(px, py, size, size);
          }
        }
      }
      g.globalAlpha = 1;

      // The lockup. `cy` is the middle of the name's line box, which is what
      // wordmark() is handed, and everything else hangs off it.
      var cx = w / 2, cy = h / 2;
      var size = Math.min(w / 11, 44);
      g.textAlign = "left";
      g.textBaseline = "alphabetic";
      g.font = "300 " + size + "px " + FACE;
      var m = g.measureText("vectorwake");
      // Width scales with the size, so one measurement is enough to know what
      // size fits a phone held upright.
      var span = size * (LOGO_EM * MK_SPAN + LOGO_GAP) + m.width;
      if (span > w * 0.8) {
        size = size * w * 0.8 / span;
        g.font = "300 " + size + "px " + FACE;
        m = g.measureText("vectorwake");
        span = size * (LOGO_EM * MK_SPAN + LOGO_GAP) + m.width;
      }
      var mh = size * LOGO_EM;
      var x0 = cx - span / 2;

      // Defold centers a string in its line box and canvas draws from a
      // baseline, so the box is measured and centered by hand. Old browsers do
      // not report it; the ratios below are what this face measures.
      var asc = m.fontBoundingBoxAscent || size * 0.99;
      var desc = m.fontBoundingBoxDescent || size * 0.31;
      g.fillStyle = INK;
      g.fillText("vectorwake", x0 + size * (LOGO_EM * MK_SPAN + LOGO_GAP),
                 cy + (asc - desc) / 2);
      mark(x0, cy + size * LOGO_DROP + mh / 2, mh);

      // One hairline, as wide as the lockup, that only ever grows.
      var by = cy + size * 0.95;
      g.fillStyle = "#1d2838";
      g.fillRect(x0, by, span, 2);
      g.fillStyle = FRIEND;
      g.fillRect(x0, by, span * progress, 2);

      if (!done) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);

    // Progress is what the loader knows; the last stretch is compilation,
    // which nothing can measure, so it creeps rather than sitting still.
    window.vwProgress = function (p) {
      if (p > progress) progress = p;
    };
    setInterval(function () {
      if (progress < 0.97) progress += (0.97 - progress) * 0.06;
    }, 100);

    // Called from the game's own first frame.
    window.vwReady = function () {
      if (done) return "";
      done = true;
      cv.style.opacity = "0";
      setTimeout(function () { cv.remove(); }, 500);
      return "";
    };
  })();

  // Sound. A browser starts every page muted: the audio context is created
  // suspended and only a user gesture may resume it. The engine takes that
  // gesture from exactly one place -- a mouse or touch event whose target is
  // the canvas -- and has no keyboard path at all. So a pilot who never
  // clicks the canvas plays the whole match in silence, which looks precisely
  // like broken sound rather than a page that was never unlocked. Measured on
  // the shipped build: a click reaches "running" and queues audio within a
  // frame; Enter, space and the arrows leave it "suspended" indefinitely.
  //
  // Unlock on anything, from anywhere, and keep trying afterwards, because
  // the first gesture can easily land before the engine has opened its audio
  // device at all.
  try {
    // iOS mutes Web Audio outright when the ring/silent switch is on, unless
    // the page declares itself playback rather than interface noise.
    if (navigator.audioSession) navigator.audioSession.type = "playback";
  } catch (e) {}

  var gestured = false, pump = null, pumped = 0;
  function audioRunning() {
    var shared = window._dmJSDeviceShared;
    var ctx = shared && shared.audioCtx;
    if (!ctx) return false;
    if (ctx.state !== "running") { try { ctx.resume(); } catch (e) {} }
    return ctx.state === "running";
  }
  function gesture() {
    gestured = true;
    if (audioRunning() || pump) return;
    // resume() is asynchronous even when it works, so one call proves
    // nothing. Watch until it takes, then stop watching.
    pumped = 0;
    pump = setInterval(function () {
      if (audioRunning() || ++pumped > 40) { clearInterval(pump); pump = null; }
    }, 250);
  }
  ["pointerdown", "mousedown", "touchstart", "touchend", "keydown", "click"]
    .forEach(function (t) {
      window.addEventListener(t, gesture, {capture: true, passive: true});
    });
  // A backgrounded tab suspends its own context. Coming back is not a
  // gesture, but the page has had one by then, which is what the browser
  // actually requires.
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden && gestured) gesture();
  });
})();
"""


# A committed dark page: this is an arcade screen, and the ground is the
# simulation's own clear color. The frame stays quiet so the arena is the
# only thing with any brightness in it.
FRAME_CSS = """
<style>
  /* The game is the page. No title, no help bar, no Defold chrome: a canvas
     the size of the window and nothing else in front of it. */
  html, body {
    margin: 0; padding: 0; height: 100%; width: 100%;
    background: #05070d; overflow: hidden;
  }
  /* Defold lays the body out as a flex row, and the canvas ends up an item
     in it -- offset to the right by whatever sits before it, with that much
     of its right edge hanging off the viewport. Nothing scaled it wrong; it
     was simply pushed. Pinning it to the corner is the whole fix. */
  .canvas-app-container, #canvas-container, .canvas-app-canvas-container,
  #canvas, .canvas-app-canvas {
    position: fixed !important;
    left: 0 !important; top: 0 !important;
    width: 100vw !important; height: 100vh !important;
    margin: 0 !important; padding: 0 !important; border: 0 !important;
    display: block !important;
  }
  /* On a high-density screen the buffer is upscaled to fit the window, and
     the browser's default filter is bilinear -- which is what made clean
     one-pixel vector lines look soft. Nearest keeps an edge an edge.
     Drawing at device resolution instead would be sharper still, but the
     interface is drawn with the engine's debug font, whose glyphs are a
     fixed pixel size and would then be half as large on screen. */
  #canvas, .canvas-app-canvas {
    outline: none;
    image-rendering: pixelated;
    image-rendering: crisp-edges;
  }
  /* Defold's own footer: a fullscreen button and a credit link. */
  .buttons-background, #canvas-app-buttons, .canvas-app-buttons {
    display: none !important;
  }
</style>
"""

# Tab is the browser's own focus-traversal key, so pressing it on a page whose
# only content is a canvas moves focus off the canvas and every keystroke
# after it goes nowhere. The start screen uses tab to reach its fields, so the
# page has to keep it.
FRAME_HEAD = """
<script>
// A fragment has no head of its own -- the host supplies it -- so Defold's
// <meta name="viewport"> goes out with the rest of the document shell. A phone
// with no viewport meta lays the page out at 980 css pixels and scales the
// result down to the screen, which means the interface is sized for a display
// nobody is holding: the scoreboard and the desktop key hints appear, at about
// a third of the size they are meant to be read at, and the compact layout
// never triggers because the game is told it has 980 points of width.
//
// Embedded in an iframe none of this happens -- the parent's element sets the
// width, a phone reports 390, and everything is correct -- which is exactly
// why it went unnoticed: the page is normally played inside a frame and the
// standalone file is what gets handed to somebody to try.
(function () {
  if (document.querySelector('meta[name="viewport"]')) return;
  var m = document.createElement("meta");
  m.name = "viewport";
  m.content = "width=device-width, initial-scale=1.0, maximum-scale=1.0, " +
              "user-scalable=0, viewport-fit=cover";
  (document.head || document.documentElement).appendChild(m);
})();
</script>
"""


# Defold owns the canvas buffer, sized from game.project. Resizing it from
# here fought that: the engine kept its own idea of the drawable, the render
# script projected the interface into it, and the part past the visible edge
# was simply cropped. CSS scales the finished frame to the window instead,
# which cannot crop anything.


# Defold's loader sizes the canvas by fitting game.project's 1280x800 into
# the window with the aspect preserved, and centers what is left with a
# margin -- which is where the interface-cropping offset came from. With a
# fixed zoom that fit is exactly wrong: the buffer should be the window, so
# a reshaped window shows more or less of the arena instead of the same
# arena letterboxed or squashed. Two numbers do it.
def fill_window(html):
    out = html.replace("var width = 1280;\n        var height = 800;",
                       "var width = innerWidth;\n        var height = innerHeight;")
    if out == html:
        sys.exit("loader canvas size not found; Defold's template changed")
    # The footer is hidden, so it must not reserve height either.
    out = out.replace("buttonHeight = 42;", "buttonHeight = 0;")
    return out


# Defold's own loading screen is CSS rather than script, so it cannot be waited
# out: bob injects a sheet that puts a pale gradient on the container and the
# Defold wordmark on the canvas, and both paint the instant the document has a
# canvas to lay out. On a five megabyte single file that is a second or more
# before the loader at the bottom of the page runs and the starfield covers it.
# engine_template.html grounds both to the arena's clear color after the
# injection point. This checks it is still there, because the rule lived here
# for a while, only ran for --fragment, and prod serves the whole document: the
# page opened on somebody else's brand for a year of pushes and nothing said so.
# The face the loading screen sets the name in, which is the face the menu is
# set in. Found beside this script rather than in the bundle: what the bundle
# holds is a distance-field atlas of the glyphs, which is the engine's business
# and unreadable to a browser.
def menu_font():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "ui", "menu.ttf"), "rb") as f:
        return base64.b64encode(f.read()).decode()


def check_ground(html):
    if "defold-logo-html5-splash" not in html:
        return
    if "#canvas {\n\t\tbackground: #05070d;" in html:
        return
    sys.exit("Defold's splash is in the sheet and engine_template.html no "
             "longer overrides it; the page would open on the Defold logo")


def to_fragment(html, title):
    """Strip the document wrapper, leaving styles and body content.

    Artifact hosts supply their own <!doctype>, <head> and <body>, so a full
    document nested inside one is invalid. Everything the page needs -- the
    styles, the canvas, the loader -- survives; only the shell goes.
    """
    styles = re.findall(r"<style[^>]*>.*?</style>", html, re.S)
    body = re.search(r"<body[^>]*>(.*)</body>", html, re.S)
    if not body:
        sys.exit("no <body> to extract")
    # Ours last: Defold's stylesheet paints the page white, and whoever comes
    # second wins.
    return "\n".join(styles) + FRAME_CSS + FRAME_HEAD + body.group(1)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    fragment = "--fragment" in sys.argv
    bundle, out = args[0], args[1]
    exe = args[2] if len(args) > 2 else "vectorwake"

    with open(os.path.join(bundle, "index.html")) as f:
        html = f.read()
    with open(os.path.join(bundle, "dmloader.js")) as f:
        loader = f.read()

    assets = collect(bundle, exe)

    # Inline the loader in place of its script tag.
    html = re.sub(
        r'<script id=.engine-loader.[^>]*></script>',
        lambda _: "<script id='engine-loader'>\n" + loader + "\n</script>",
        html,
        count=1,
    )
    if "engine-loader" not in html:
        sys.exit("could not find the engine-loader script tag")

    shim = SHIM.replace("__ASSETS__", json.dumps(assets))
    shim = shim.replace("__MENU_FONT__", menu_font())
    html = html.replace(
        "<script id='engine-start'",
        "<script id='engine-inline'>\n" + shim + "\n</script>\n\t<script id='engine-start'",
        1,
    )

    # There is nothing left to fetch, so the file:// guard is now wrong: this
    # page is meant to work when opened straight off a disk.
    guard = re.compile(
        r'if \(window\.location\.href\.startsWith\("file://"\)\)\s*\{.*?\}'
        r'\s*else\s*\{.*?\n\s*\}',
        re.S,
    )
    check_ground(html)
    html = fill_window(html)
    html, n = guard.subn('EngineLoader.load("canvas", "%s");' % exe, html)
    if n != 1:
        sys.exit("could not rewrite the file:// guard (matched %d times)" % n)

    if fragment:
        html = to_fragment(html, "vectorwake")

    with open(out, "w") as f:
        f.write(html)
    print("%s  %.1f MB" % (out, os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    main()
