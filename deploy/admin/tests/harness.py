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
<!-- The two nodes wire() reaches for that live in the list section rather
     than the editor. The button is how a drive opens a blank map. -->
<button id="map-new">new map</button>
<p id="maps-note"></p>
%s
</main>
<script>
const secret = "drive";
function el(id) { return document.getElementById(id); }
function tell(id, msg, kind) {
  const n = el(id);
  if (n) { n.textContent = msg; n.dataset.kind = kind || ""; }
}
function fill() {}
function ask() { return Promise.resolve("drive-map"); }
// Nothing here talks to a server. The live verdict is the one call maps.js
// makes on its own, and a drive of the drawing tools does not need its answer.
function post() { return Promise.resolve({ ok: true, report: {} }); }
</script>
<script src="maps.js"></script>
</body>
""" % editor
out.write_text(page)
print(f"wrote {out}")
