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
  var KEYS = {
    ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1,
    Space: 1, Tab: 1
  };
  function grabFocus() {
    var c = document.getElementById("canvas");
    if (c) {
      c.setAttribute("tabindex", "0");
      try { c.focus({ preventScroll: true }); } catch (e) { c.focus(); }
    }
  }
  window.addEventListener("load", grabFocus);
  document.addEventListener("pointerdown", grabFocus, true);
  document.addEventListener("keydown", function (e) {
    if (KEYS[e.code]) e.preventDefault();
  }, { passive: false, capture: true });
  var tries = 0;
  var poll = setInterval(function () {
    grabFocus();
    if (++tries > 40 || document.activeElement === document.getElementById("canvas")) {
      clearInterval(poll);
    }
  }, 250);
})();
"""


# A committed dark page: this is an arcade screen, and the ground is the
# simulation's own clear colour. The frame stays quiet so the arena is the
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
    display: block !important; background: #05070d;
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

# Defold owns the canvas buffer, sized from game.project. Resizing it from
# here fought that: the engine kept its own idea of the drawable, the render
# script projected the interface into it, and the part past the visible edge
# was simply cropped. CSS scales the finished frame to the window instead,
# which cannot crop anything.
FRAME_HEAD = ""


# Defold's loader sizes the canvas by fitting game.project's 1280x800 into
# the window with the aspect preserved, and centres what is left with a
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
