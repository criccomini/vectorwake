#!/usr/bin/env python3
"""Build a page that holds the real editor markup and the real maps.js.

The markup is cut out of deploy/admin/index.html rather than copied, so a
harness cannot quietly drift from the panel it claims to be driving. What is
stubbed is only the part maps.js gets from admin.js: the four DOM helpers and
the fetch, which a UI drive has no use for.
"""
import re
import sys
import pathlib

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

html = (root / "deploy/admin/index.html").read_text()
m = re.search(r'<section id="editor".*?</section>', html, re.S)
assert m, "no editor section in index.html"
editor = m.group(0).replace(" hidden>", ">", 1)

page = """<!doctype html>
<meta charset="utf-8">
<title>editor drive</title>
<link rel="icon" href="favicon.svg">
<link rel="stylesheet" href="admin.css">
<body class="panel">
<main>
<!-- The nodes wire() reaches for that live in the list section rather than
     the editor. The button is how a drive opens a blank map. -->
<button id="map-new">new map</button>
<input id="map-import" type="file" hidden>
<p id="maps-note"></p>
%s
</main>
<script>
function el(id) { return document.getElementById(id); }
function tell(id, msg, kind) {
  const n = el(id);
  if (n) { n.textContent = msg; n.dataset.kind = kind || ""; }
}
function fill() {}
function ask() { return Promise.resolve("drive-map"); }
// Nothing here talks to a server. Most drawing tests use the default answer;
// verdict tests replace the delegate without changing the interface maps.js
// captured when it loaded.
let postDelegate = () => Promise.resolve({ ok: true, report: {} });
let mapsDraw = () => Promise.resolve();
function post(url, body) { return postDelegate(url, body); }
function setPost(fn) { postDelegate = fn; }
function installMaps(fn) { mapsDraw = fn; }
function drawMaps() { return mapsDraw(); }
window.vectorwakeAdmin = Object.freeze({
  post, el, tell, fill, ask, setPost, installMaps, drawMaps, secret: "drive"
});
</script>
<script src="maps.js"></script>
</body>
""" % editor
out.write_text(page)
print(f"wrote {out}")
