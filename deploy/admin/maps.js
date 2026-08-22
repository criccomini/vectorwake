// The map editor, and what each zone plays.
//
// Loaded after admin.js and using its helpers: `post`, `el`, `tell`, `fill`
// and `ask` are script-scope bindings from that file, which is what a classic
// script gives a later one.
//
// ## One scope, two files
//
// That sharing runs both ways, and the second way is a trap. Two classic
// scripts share one global scope, so every name declared at the top level here
// is declared in the same place admin.js declares its own. A collision between
// two `function`s is silent and the later file wins, which is a function
// quietly replaced. A collision between a `function` here and a `let` there is
// a SyntaxError, and it takes this whole file with it: nothing runs, the
// editor never wires up, and what the page says is that some later call cannot
// see a variable.
//
// Both happened. `repaint` is `repaint` rather than `draw` because admin.js
// draws the fleet table with a `draw` of its own, and `inField` is not
// `typing` because admin.js debounces its pilot search with a `let typing`.
// deploy/admin/tests/scope_test.js runs the two files into one scope the way a
// browser does and fails on any name they both claim, so the next one of these
// is caught before it ships rather than by reading the panel.
//
// ## The core is the judge, not this file
//
// A map has to be a great deal more than well formed. It has to be a room a
// three-tile hull can fly all of, with somewhere for both sides to start and
// no ground a ship can be shoved into and never leave. Those are questions
// with one right answer, and the answer lives in `sim/src/check.c`, which the
// generator takes its own verdict from.
//
// So this file does not check maps. It packs the tiles, posts them, and shows
// what the core said. What it packs has to be byte-exact -- the header, the
// runs and the FNV-1a over both -- because the server unpacks it with the same
// function an arena does, and anything else is refused rather than guessed at.
// That refusal is the design: a browser cannot be trusted to agree with the
// simulation, so it is never asked to.

"use strict";

// Tile classes, from sim/include/sim/sim.h. A tile is class in the low nibble
// and a variant in the high one.
const T_EMPTY = 0, T_SOLID = 1, T_SAFE = 2, T_DOOR = 3, T_GOAL = 4;
const T_WORMHOLE = 5, T_OVER = 6, T_UNDER = 7, T_TURF = 8, T_SPAWN = 9;
const T_SLOPE = 10;

// What kind of solid a solid tile is, which is SIM_SOLID_* in the same header.
// The core never reads these, because every one of them stops a ship the same
// way, so they belong to the renderer. An editor that only ever wrote variant
// zero could draw a room with no rock in it.
const S_WALL = 0, S_BORDER = 1, S_ROCK_A = 2, S_ROCK_B = 3;
const S_ROCK_BIG = 4, S_ROCK_BODY = 5, S_STATION = 6, S_STATION_BODY = 7;

// What you can put down. `v` is the variant, which means a different thing per
// class: what kind of solid, a channel for a door, a side for a start or a
// goal, the filled corner for a slope.
//
// `size` and `body` are the objects bigger than a tile. Only the top-left
// carries the picture and the rest is body, which is how the client draws a
// station once rather than thirty-six times; an editor that wrote the corner
// without the body would be drawing a station one tile wide.
//
// `name` is what the readout calls the tile, where that differs from what the
// chip calls it. A chip sells what pressing it does, so it says "(6x6)" and
// "(eraser)"; a readout names what is already there, and the size of a station
// is not news once one is in front of you. Most paints need only the one word.
//
// `group` is only how the palette is laid out. Twenty-five chips in one row is
// a wall of text, and these fall into four honest piles.
const PAINTS = [
  { key: "wall", cls: T_SOLID, v: S_WALL, label: "wall", group: "ground" },
  { key: "empty", cls: T_EMPTY, v: 0, label: "empty (eraser)", name: "empty",
    group: "ground" },
  { key: "edge", cls: T_SOLID, v: S_BORDER, label: "map edge", group: "ground" },
  { key: "nw", cls: T_SLOPE, v: 0, label: "slope NW", group: "ground" },
  { key: "ne", cls: T_SLOPE, v: 1, label: "slope NE", group: "ground" },
  { key: "se", cls: T_SLOPE, v: 2, label: "slope SE", group: "ground" },
  { key: "sw", cls: T_SLOPE, v: 3, label: "slope SW", group: "ground" },

  { key: "rocka", cls: T_SOLID, v: S_ROCK_A, label: "rock", group: "objects" },
  { key: "rockb", cls: T_SOLID, v: S_ROCK_B, label: "rock, the other one", group: "objects" },
  { key: "rockbig", cls: T_SOLID, v: S_ROCK_BIG, body: S_ROCK_BODY, size: 2,
    label: "big rock (2x2)", name: "big rock", group: "objects" },
  { key: "station", cls: T_SOLID, v: S_STATION, body: S_STATION_BODY, size: 6,
    label: "station (6x6)", name: "station", group: "objects" },
  { key: "over", cls: T_OVER, v: 0, label: "scenery, over", group: "objects" },
  { key: "under", cls: T_UNDER, v: 0, label: "scenery, under", group: "objects" },

  { key: "spawn0", cls: T_SPAWN, v: 0, label: "start, side one", group: "places" },
  { key: "spawn1", cls: T_SPAWN, v: 1, label: "start, side two", group: "places" },
  { key: "goal0", cls: T_GOAL, v: 0, label: "goal, side one", group: "places" },
  { key: "goal1", cls: T_GOAL, v: 1, label: "goal, side two", group: "places" },
  { key: "safe", cls: T_SAFE, v: 0, label: "safe", group: "places" },
  { key: "turf", cls: T_TURF, v: 0, label: "flag stand", group: "places" },
  { key: "worm", cls: T_WORMHOLE, v: 0, label: "wormhole", group: "places" },
];

// Eight door channels, evenly spread over one clock: a door of channel n opens
// n eighths of a period after channel zero, so two sets four apart are open in
// turn. That is the whole vocabulary, and offering two of it was offering a
// quarter of what a map can say.
for (let n = 0; n < 8; n++) {
  PAINTS.push({
    key: `door${n}`, cls: T_DOOR, v: n, group: "doors",
    label: `door ${String.fromCharCode(65 + n)}`,
  });
}

const TOOLS = [
  { key: "pencil", label: "pencil" },
  { key: "line", label: "line" },
  { key: "rect", label: "rect" },
  { key: "box", label: "outline" },
  { key: "fill", label: "fill" },
  { key: "select", label: "select" },
];

// Colors, from the panel's own variables so the editor and the rest of the
// page are one instrument. A slope draws as its triangle rather than as a
// shaded square: the whole point of the class is which half is solid.
const INK = {
  [T_EMPTY]: "#05070c",
  [T_SOLID]: "#8494ab",
  [T_SLOPE]: "#8494ab",
  [T_SAFE]: "#4fd6ff",
  [T_DOOR]: "#c27bff",
  [T_GOAL]: "#ffa552",
  [T_WORMHOLE]: "#c27bff",
  [T_OVER]: "#2b3a4f",
  [T_UNDER]: "#1d2838",
  [T_TURF]: "#ffa552",
  [T_SPAWN]: "#4fd6ff",
};

// Solids by what kind they are. Rock is warmer and grayer than anything built,
// which is the rule the arena's own palette follows so a rock field never
// reads as architecture; the editor keeps to it so a plan looks like the room.
const SOLID_INK = {
  [S_WALL]: "#8494ab",
  [S_BORDER]: "#39465c",
  [S_ROCK_A]: "#8a8794",
  [S_ROCK_B]: "#8a8794",
  [S_ROCK_BIG]: "#8a8794",
  [S_ROCK_BODY]: "#8a8794",
  [S_STATION]: "#7c8fa8",
  [S_STATION_BODY]: "#7c8fa8",
};

// The open map. `tiles` is one byte per tile in row order, which is the order
// the file is written in.
let doc = null;
let paint_at = 0;
let tool = "pencil";
let zoom = 4;
let dragging = null;
let checking = null;
let known = { maps: [], rotations: [], zones: [] };

// Where writes go when a preview is being computed instead of drawn. Null the
// rest of the time, which is every write that is meant to land.
let sink = null;

// The marquee, in tiles, and what was last lifted out of one. `sel` is
// normalized: x and y are the top left, w and h are at least one.
let sel = null;
let clip = null;

// The last tile the pointer was over, which is where a paste goes when there
// is no selection to put it back into. It keeps the last tile it saw after the
// pointer leaves, rather than going to nothing: a paste aimed at where you
// were last looking is right, and one aimed off the map is clipped.
let hover = [0, 0];

// Whether the pointer is on the canvas at all, which only the readout cares
// about. Kept apart from `hover` so that leaving does not move the paste.
let onCanvas = false;

// What can be taken back, and what taking it back would put back.
//
// One entry per gesture rather than per tile: a dragged line is one thing a
// person did, and undoing it a pixel at a time is not undo. `pending` is what
// the gesture in progress has changed so far, keyed by tile so a stroke that
// crosses itself records the tile once with the byte it started with.
let past = [];
let future = [];
let pending = null;
// Where the marquee was when the gesture opened, so the step can put it back.
let held = null;

// Deltas rather than snapshots. A map is up to a megabyte of tiles and a
// stroke touches a handful of them, so a stack of whole maps would cost a
// megabyte a step to record what a person can see is a line. The exception is
// a resize, which changes the shape of the array and is stored whole.
const HISTORY_STEPS = 60;
const HISTORY_BYTES = 32 * 1024 * 1024;

function blank(w, h) {
  return { name: "", w, h, tiles: new Uint8Array(w * h), dirty: false };
}

const at = (x, y) => doc.tiles[y * doc.w + x];

// Half a turn about the middle, which is the symmetry the match maps are
// drawn with: the two sides face identical approach geometry rather than
// handed versions of it. A slope has to turn with the tile, and turning one
// half a turn swaps the corner it fills for the opposite one, which on this
// numbering is exactly a flip of the second bit.
function turned(byte) {
  const cls = byte & 15, v = byte >> 4;
  if (cls === T_SLOPE) return cls | ((v ^ 2) << 4);
  // A start or a goal belongs to a side, and the far half of a symmetric map
  // belongs to the other one. Anything else turns unchanged.
  if (cls === T_SPAWN || cls === T_GOAL) return cls | ((v ^ 1) << 4);
  return byte;
}

// Whether the far half is drawing itself. Asked through a function because
// this module is loaded without a page by its own tests, and a checkbox that
// is not there means the box is not ticked.
function symmetric() {
  if (typeof document === "undefined") return false;
  const box = el("map-sym");
  return !!(box && box.checked);
}

// One tile, no symmetry, no questions. The bounds check lives here so every
// caller can name a tile off the edge and have nothing happen.
function raw(x, y, byte) {
  if (!doc || x < 0 || y < 0 || x >= doc.w || y >= doc.h) return;
  write(y * doc.w + x, byte);
}

// One tile, and the tile opposite it when the far half is drawing itself.
//
// Every write to the map goes through here or through `raw`, which is what
// makes undo possible without every tool having to remember anything: the
// record is taken where the change happens rather than where it was asked for.
function put(x, y, byte) {
  if (!doc || x < 0 || y < 0 || x >= doc.w || y >= doc.h) return;
  raw(x, y, byte);
  if (symmetric()) {
    const mx = doc.w - 1 - x, my = doc.h - 1 - y;
    if (mx !== x || my !== y) raw(mx, my, turned(byte));
  }
}

function write(at, byte) {
  // A preview is the same drawing with the writes caught in a bucket instead
  // of landing. Running the real tool against a sink is what makes what you
  // see while you drag the thing you get when you let go, rather than a second
  // implementation of a line that agrees with the first one until it doesn't.
  if (sink) { sink.set(at, byte); return; }
  if (doc.tiles[at] === byte) return;
  // The byte it held when this gesture started, not the one it held a moment
  // ago: a stroke that crosses itself must undo to before the stroke.
  if (pending && !pending.has(at)) pending.set(at, doc.tiles[at]);
  doc.tiles[at] = byte;
  doc.dirty = true;
}

// Run a tool with its writes caught rather than laid down, and hand back what
// it would have written as tile index to byte.
function ghost(fn) {
  const held = sink;
  sink = new Map();
  try {
    fn();
    return sink;
  } finally {
    sink = held;
  }
}

// --- objects bigger than a tile --------------------------------------------

// One object at an anchor, without symmetry: the corner carries the picture
// and everything else is body.
function block(ax, ay, p) {
  const corner = p.cls | (p.v << 4);
  const body = p.cls | (p.body << 4);
  for (let dy = 0; dy < p.size; dy++) {
    for (let dx = 0; dx < p.size; dx++) {
      raw(ax + dx, ay + dy, dx === 0 && dy === 0 ? corner : body);
    }
  }
}

// An object snapped to its own grid.
//
// Snapping is what keeps two of them from half-overlapping. A station dropped
// one tile off another leaves a corner buried under somebody else's body,
// which draws as nothing at all and is solid anyway: an invisible wall, which
// is the worst thing a map can have in it. On the grid, two stations are
// either the same station or two stations.
function stamp(x, y, p) {
  const ax = Math.floor(x / p.size) * p.size;
  const ay = Math.floor(y / p.size) * p.size;
  block(ax, ay, p);
  if (!symmetric()) return;
  // The half-turn of a block is the block itself, so the anchor is mirrored
  // whole rather than tile by tile. A rock has no handedness to turn.
  const mx = doc.w - ax - p.size, my = doc.h - ay - p.size;
  if (mx !== ax || my !== ay) block(mx, my, p);
}

// What a tool lays at one tile, whatever the paint happens to be.
function layer(p) {
  return p.size > 1 ? (x, y) => stamp(x, y, p) : (x, y) => put(x, y, byteOf(p));
}

// --- taking it back --------------------------------------------------------

/// How much a step costs to hold, so a stack of them can be bounded by
/// something truer than a count. Six bytes a tile: where it was, what it was,
/// what it became.
function weigh(step) {
  return step.kind === "tiles" ? step.at.length * 6 : step.before.tiles.length * 2;
}

function trim() {
  let bytes = past.reduce((n, s) => n + weigh(s), 0);
  while (past.length > HISTORY_STEPS || (bytes > HISTORY_BYTES && past.length > 1)) {
    bytes -= weigh(past.shift());
  }
}

// Start recording. Every gesture that changes the map opens one of these and
// closes it, so that what a person did once is undone once.
function beginStep() {
  pending = new Map();
  held = sel;
}

function endStep() {
  if (!pending || pending.size === 0) {
    pending = null;
    return;
  }
  const at = new Int32Array(pending.size);
  const before = new Uint8Array(pending.size);
  const after = new Uint8Array(pending.size);
  let i = 0;
  for (const [index, was] of pending) {
    at[i] = index;
    before[i] = was;
    after[i] = doc.tiles[index];
    i++;
  }
  pending = null;
  // The marquee rides along, because undoing a move that does not put the
  // marquee back leaves it pointing at ground the tiles have left.
  past.push({ kind: "tiles", at, before, after, was: held, now: sel });
  // A new stroke is a new branch: what was undone is not coming back.
  future = [];
  trim();
  historyChanged();
}

// A resize changes the shape of the array rather than tiles in it, so it is
// the one step held whole. There is one per press of `apply`, and a map is not
// resized in a loop.
function pushDoc(before) {
  past.push({ kind: "doc", before, after: snapshot() });
  future = [];
  trim();
  historyChanged();
}

function snapshot() {
  return { w: doc.w, h: doc.h, tiles: doc.tiles.slice(), name: doc.name };
}

function restore(shot) {
  doc.w = shot.w;
  doc.h = shot.h;
  doc.tiles = shot.tiles.slice();
  doc.dirty = true;
  // A marquee drawn on the larger map does not survive shrinking back to the
  // smaller one, and a rect hanging off the edge is worse than none.
  if (sel && (sel.x + sel.w > doc.w || sel.y + sel.h > doc.h)) sel = null;
  el("map-w").value = doc.w;
  el("map-h").value = doc.h;
}

function apply(step, back) {
  if (step.kind === "doc") {
    restore(back ? step.before : step.after);
    return;
  }
  const to = back ? step.before : step.after;
  for (let i = 0; i < step.at.length; i++) doc.tiles[step.at[i]] = to[i];
  doc.dirty = true;
  sel = back ? step.was : step.now;
}

function undo() {
  if (!doc || !past.length) return;
  const step = past.pop();
  apply(step, true);
  future.push(step);
  historyChanged();
  repaint();
  verdict();
}

function redo() {
  if (!doc || !future.length) return;
  const step = future.pop();
  apply(step, false);
  past.push(step);
  historyChanged();
  repaint();
  verdict();
}

// Opening a map is not something to undo past: what came before it is a
// different drawing.
function forgetHistory() {
  past = [];
  future = [];
  pending = null;
  sink = null;
  sel = null;
  historyChanged();
}

function historyChanged() {
  if (typeof document === "undefined") return;
  const u = el("map-undo");
  const r = el("map-redo");
  if (u) u.disabled = past.length === 0;
  if (r) r.disabled = future.length === 0;
}

// --- what the file looks like ----------------------------------------------
//
// sim/src/pack.c writes it and reads it back. Fourteen bytes of header, then
// three-byte runs of length and tile over the map's own rect. The hash covers
// the size and then every tile, so the same drawing at two sizes is two maps.

function fnv(doc) {
  let h = 2166136261;
  const dim = [doc.w & 255, doc.w >> 8, doc.h & 255, doc.h >> 8];
  for (const b of dim) { h = Math.imul(h ^ b, 16777619) >>> 0; }
  for (let i = 0; i < doc.tiles.length; i++) {
    h = Math.imul(h ^ doc.tiles[i], 16777619) >>> 0;
  }
  return h >>> 0;
}

function pack(doc) {
  const out = [];
  // "PAMV" on the wire: the magic is a little-endian u32 spelling VMAP.
  out.push(0x50, 0x41, 0x4d, 0x56, 2, 0);
  out.push(doc.w & 255, doc.w >> 8, doc.h & 255, doc.h >> 8);
  const h = fnv(doc);
  out.push(h & 255, (h >> 8) & 255, (h >> 16) & 255, (h >>> 24) & 255);
  const total = doc.w * doc.h;
  let i = 0;
  while (i < total) {
    const v = doc.tiles[i];
    let run = 1;
    // 65535 is the longest a run can say, so a long one simply repeats.
    while (i + run < total && doc.tiles[i + run] === v && run < 65535) run++;
    out.push(run & 255, run >> 8, v);
    i += run;
  }
  return new Uint8Array(out);
}

function unpack(bytes) {
  if (bytes.length < 14) throw new Error("too short to be a map");
  const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]);
  if (magic !== "PAMV") throw new Error("not a map file");
  if (bytes[4] !== 2) throw new Error(`map format version ${bytes[4]}, not 2`);
  const w = bytes[6] | (bytes[7] << 8), h = bytes[8] | (bytes[9] << 8);
  const d = blank(w, h);
  let at = 14, i = 0;
  while (at + 2 < bytes.length && i < w * h) {
    const run = bytes[at] | (bytes[at + 1] << 8), v = bytes[at + 2];
    at += 3;
    for (let k = 0; k < run && i < w * h; k++) d.tiles[i++] = v;
  }
  if (i !== w * h) throw new Error("the runs do not cover the map");
  return d;
}

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// --- drawing ---------------------------------------------------------------

// What color a tile draws in. A solid is not one thing: the variant is the
// difference between a wall somebody built and a rock that was already there,
// and an editor that drew them alike would be hiding the thing you just
// placed.
function inkOf(cls, v) {
  if (cls === T_SOLID) return SOLID_INK[v] || SOLID_INK[S_WALL];
  return INK[cls] || "#8494ab";
}

function tile(g, x, y, b) {
  const cls = b & 15, v = b >> 4;
  if (cls === T_EMPTY) return;
  g.fillStyle = inkOf(cls, v);
  const px = x * zoom, py = y * zoom;
  if (cls === T_SLOPE) {
    // The filled corner, and the two beside it. Drawn as the triangle the
    // simulation collides against, so what you see is the wall there is.
    const pts = [
      [[0, 0], [1, 0], [0, 1]],
      [[0, 0], [1, 0], [1, 1]],
      [[1, 0], [1, 1], [0, 1]],
      [[0, 0], [0, 1], [1, 1]],
    ][v & 3];
    g.beginPath();
    g.moveTo(px + pts[0][0] * zoom, py + pts[0][1] * zoom);
    g.lineTo(px + pts[1][0] * zoom, py + pts[1][1] * zoom);
    g.lineTo(px + pts[2][0] * zoom, py + pts[2][1] * zoom);
    g.closePath();
    g.fill();
  } else {
    g.fillRect(px, py, zoom, zoom);
  }
}

// `over` is what a drag would write if it ended now, as tile index to byte.
// Named for what it does rather than the obvious `draw`, which belongs to
// admin.js: see the note at the top of this file about the shared scope.
function repaint(over) {
  // Nothing to draw on when this module is loaded by its own tests, which
  // exercise the tools and the history rather than the canvas.
  if (!doc || typeof document === "undefined") return;
  const c = el("map-canvas");
  c.width = doc.w * zoom;
  c.height = doc.h * zoom;
  const g = c.getContext("2d");
  g.fillStyle = INK[T_EMPTY];
  g.fillRect(0, 0, c.width, c.height);
  for (let y = 0; y < doc.h; y++) {
    for (let x = 0; x < doc.w; x++) tile(g, x, y, at(x, y));
  }

  // An object's footprint, so a station reads as one six-tile thing rather
  // than as a patch of wall. Only the corner knows how big it is.
  if (zoom >= 3) {
    g.strokeStyle = "#05070c";
    g.lineWidth = 1;
    for (let y = 0; y < doc.h; y++) {
      for (let x = 0; x < doc.w; x++) {
        const b = at(x, y);
        if ((b & 15) !== T_SOLID) continue;
        const v = b >> 4;
        const n = v === S_ROCK_BIG ? 2 : v === S_STATION ? 6 : 0;
        if (n) g.strokeRect(x * zoom + 0.5, y * zoom + 0.5, n * zoom - 1, n * zoom - 1);
      }
    }
  }
  // The boundary the core paints on load, drawn dimmer than a wall an author
  // put there. It is not in the file and never was: every map gets four tiles
  // of it whatever the tiles say. Leaving it off drew an open field running to
  // the edge, which is not the room this is.
  g.fillStyle = "#39465c";
  for (let i = 0; i < 4; i++) {
    g.fillRect(0, i * zoom, doc.w * zoom, zoom);
    g.fillRect(0, (doc.h - 1 - i) * zoom, doc.w * zoom, zoom);
    g.fillRect(i * zoom, 0, zoom, doc.h * zoom);
    g.fillRect((doc.w - 1 - i) * zoom, 0, zoom, doc.h * zoom);
  }

  // A grid, once the tiles are big enough for one to mean anything. Every
  // eight, which is a landmark rather than graph paper.
  if (zoom >= 4) {
    g.strokeStyle = "#10161f";
    g.lineWidth = 1;
    g.beginPath();
    for (let x = 0; x <= doc.w; x += 8) {
      g.moveTo(x * zoom + 0.5, 0);
      g.lineTo(x * zoom + 0.5, doc.h * zoom);
    }
    for (let y = 0; y <= doc.h; y += 8) {
      g.moveTo(0, y * zoom + 0.5);
      g.lineTo(doc.w * zoom, y * zoom + 0.5);
    }
    g.stroke();
  }

  // A start is worth seeing from across the room, so it gets a ring rather
  // than a filled tile a wall would hide behind.
  if (zoom >= 3) {
    for (let y = 0; y < doc.h; y++) {
      for (let x = 0; x < doc.w; x++) {
        const b = at(x, y);
        if ((b & 15) !== T_SPAWN) continue;
        g.strokeStyle = (b >> 4) === 1 ? INK[T_GOAL] : INK[T_SAFE];
        g.lineWidth = 1;
        g.strokeRect(x * zoom - 1.5, y * zoom - 1.5, zoom + 3, zoom + 3);
      }
    }
  }

  // What the drag in progress would leave behind, drawn half solid over the
  // map it has not touched. An erasing drag writes empty, which is invisible
  // as a fill, so its tiles are struck through instead: a preview of taking
  // something away has to show where it is being taken from.
  if (over && over.size) {
    g.save();
    g.globalAlpha = 0.55;
    for (const [k, b] of over) {
      const x = k % doc.w, y = Math.floor(k / doc.w);
      if ((b & 15) === T_EMPTY) {
        g.strokeStyle = "#ff6b6b";
        g.lineWidth = 1;
        g.beginPath();
        g.moveTo(x * zoom + 1, y * zoom + 1);
        g.lineTo((x + 1) * zoom - 1, (y + 1) * zoom - 1);
        g.stroke();
      } else {
        tile(g, x, y, b);
      }
    }
    g.restore();
  }

  if (sel) {
    g.save();
    g.strokeStyle = "#e6edf7";
    g.lineWidth = 1;
    g.setLineDash([4, 3]);
    g.strokeRect(sel.x * zoom + 0.5, sel.y * zoom + 0.5,
                 sel.w * zoom - 1, sel.h * zoom - 1);
    g.restore();
  }
}

// --- tools -----------------------------------------------------------------

function byteOf(p) { return p.cls | (p.v << 4); }

// Where a drag ends once shift has had its say.
//
// Held, a line goes to the nearest eighth of a turn and a rectangle goes
// square, which is what every drawing tool has done since before any of us,
// and what makes a 45 degree wall drawable rather than approximable. The
// boundary between flat and diagonal is at 22.5 degrees, whose tangent's
// reciprocal is the 2.4142 below; the diagonal's length is the drag projected
// onto it, so the end stays under the pointer rather than jumping past it.
function lock(x0, y0, x1, y1, square) {
  const dx = x1 - x0, dy = y1 - y0;
  const ax = Math.abs(dx), ay = Math.abs(dy);
  const sx = Math.sign(dx), sy = Math.sign(dy);
  if (square) {
    const n = Math.max(ax, ay);
    return [x0 + sx * n, y0 + sy * n];
  }
  if (ay * 2.4142 < ax) return [x1, y0];
  if (ax * 2.4142 < ay) return [x0, y1];
  const n = Math.round((ax + ay) / 2);
  return [x0 + sx * n, y0 + sy * n];
}

function stroke(x0, y0, x1, y1, lay) {
  // Bresenham, so a dragged line is the line you drew and not a stack of
  // rectangles with gaps between them.
  let dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
  let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy;
  for (;;) {
    lay(x0, y0);
    if (x0 === x1 && y0 === y1) break;
    const e2 = 2 * err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
}

function rect(x0, y0, x1, y1, lay, outline) {
  const [lx, hx] = x0 < x1 ? [x0, x1] : [x1, x0];
  const [ly, hy] = y0 < y1 ? [y0, y1] : [y1, y0];
  for (let y = ly; y <= hy; y++) {
    for (let x = lx; x <= hx; x++) {
      if (outline && x !== lx && x !== hx && y !== ly && y !== hy) continue;
      lay(x, y);
    }
  }
}

// Everything the flood reaches, found before anything is written.
//
// Walking and writing at the same time was wrong on a symmetric map: the
// mirrored write lands on ground the flood has not visited yet and stops it
// early. Finding the region first costs a set and is simply correct.
function region(x, y) {
  const want = at(x, y);
  const seen = new Set();
  const stack = [[x, y]];
  while (stack.length) {
    const [cx, cy] = stack.pop();
    if (cx < 0 || cy < 0 || cx >= doc.w || cy >= doc.h) continue;
    const k = cy * doc.w + cx;
    if (seen.has(k) || doc.tiles[k] !== want) continue;
    seen.add(k);
    stack.push([cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1]);
  }
  return seen;
}

function flood(x, y, p) {
  const seen = region(x, y);
  if (p.size > 1) {
    // A field of objects rather than a wash of them: every anchor on the
    // object's own grid whose whole footprint is inside the region. One that
    // hangs over the edge is left off, because half a station is an invisible
    // wall and the point of the grid is that there are none.
    const tried = new Set();
    for (const k of seen) {
      const ax = Math.floor((k % doc.w) / p.size) * p.size;
      const ay = Math.floor(Math.floor(k / doc.w) / p.size) * p.size;
      const key = ay * doc.w + ax;
      if (tried.has(key)) continue;
      tried.add(key);
      let whole = ax + p.size <= doc.w && ay + p.size <= doc.h;
      // The width check is not decoration. A tile index is row times width
      // plus column, so a column off the right edge is arithmetically the next
      // row's column zero, and asking the region about it gets a cheerful yes.
      for (let dy = 0; whole && dy < p.size; dy++) {
        for (let dx = 0; dx < p.size; dx++) {
          if (!seen.has((ay + dy) * doc.w + ax + dx)) { whole = false; break; }
        }
      }
      if (whole) stamp(ax, ay, p);
    }
    return;
  }
  const byte = byteOf(p);
  for (const k of seen) put(k % doc.w, Math.floor(k / doc.w), byte);
}

function tileAt(ev) {
  const c = el("map-canvas");
  const r = c.getBoundingClientRect();
  return [
    Math.floor((ev.clientX - r.left) / zoom),
    Math.floor((ev.clientY - r.top) / zoom),
  ];
}

// --- a region, and what you can do to one -----------------------------------

function norm(x0, y0, x1, y1) {
  const [lx, hx] = x0 < x1 ? [x0, x1] : [x1, x0];
  const [ly, hy] = y0 < y1 ? [y0, y1] : [y1, y0];
  const x = Math.max(0, lx), y = Math.max(0, ly);
  return {
    x, y,
    w: Math.min(doc.w - 1, hx) - x + 1,
    h: Math.min(doc.h - 1, hy) - y + 1,
  };
}

function inside(r, x, y) {
  return r && x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
}

// A copy of what is in a rect, cut loose from the map it came from.
function lift(r) {
  const tiles = new Uint8Array(r.w * r.h);
  for (let y = 0; y < r.h; y++) {
    for (let x = 0; x < r.w; x++) {
      tiles[y * r.w + x] = doc.tiles[(r.y + y) * doc.w + r.x + x];
    }
  }
  return { w: r.w, h: r.h, tiles };
}

// Put one back down. Through `put`, so a symmetric map mirrors the paste the
// same way it mirrors everything else.
function blit(buf, x, y) {
  for (let dy = 0; dy < buf.h; dy++) {
    for (let dx = 0; dx < buf.w; dx++) {
      put(x + dx, y + dy, buf.tiles[dy * buf.w + dx]);
    }
  }
}

function erase(r) {
  for (let y = 0; y < r.h; y++) {
    for (let x = 0; x < r.w; x++) put(r.x + x, r.y + y, T_EMPTY);
  }
}

// Move what is selected. Read first, then clear, then lay down: source and
// destination overlap on any drag shorter than the selection is wide, and
// clearing as you go would eat the thing you are carrying.
function shift(dx, dy) {
  if (!sel || (dx === 0 && dy === 0)) return;
  const buf = lift(sel);
  beginStep();
  erase(sel);
  blit(buf, sel.x + dx, sel.y + dy);
  // Moved before the step closes, so the step records where the marquee ends
  // up as well as where the tiles do.
  sel = norm(sel.x + dx, sel.y + dy,
             sel.x + dx + sel.w - 1, sel.y + dy + sel.h - 1);
  endStep();
}

function copy(cut) {
  if (!sel) return;
  clip = lift(sel);
  if (!cut) return;
  beginStep();
  erase(sel);
  endStep();
}

function paste() {
  if (!clip) return;
  // Back where a selection is, if there is one, and under the pointer if not.
  const x = sel ? sel.x : hover[0], y = sel ? sel.y : hover[1];
  beginStep();
  blit(clip, x, y);
  sel = norm(x, y, x + clip.w - 1, y + clip.h - 1);
  endStep();
}

// --- the live verdict ------------------------------------------------------
//
// Asked of the server while somebody draws, because "a start is walled in" is
// worth hearing when you wall it in rather than when you press save. Debounced
// hard: this packs the whole map and the far end floods it twice.

function verdict() {
  if (typeof document === "undefined") return;
  if (checking) clearTimeout(checking);
  checking = setTimeout(async () => {
    if (!doc) return;
    try {
      const r = await post("/v1/admin/map/check", {
        secret,
        bytes: b64(pack(doc)),
      });
      const rep = r.report || {};
      const per = rep.spawns_team || [0, 0];
      const bits = [
        `${doc.w} by ${doc.h}`,
        // The split as well as the count. A map whose starts are all on one
        // side is playable and is not a two-sided map, and nothing else here
        // would say so: a side with no start of its own is handed somebody
        // else's, which puts both teams in one pocket.
        `${rep.spawns || 0} start(s), ${per[0] || 0} and ${per[1] || 0} a side`,
        `${Math.round((100 * (rep.solid || 0)) / (doc.w * doc.h))}% wall`,
      ];
      el("map-stats").textContent = bits.join(", ");
      // A map whose shape depends on its doors opening is a map worth serving
      // and worth a word, because a zone that sets `door_period` to zero never
      // opens them and would be playing a different room than this one. Said
      // rather than refused: which zone it lands in is not the map's business.
      const leans = (rep.regions_shut || 0) > (rep.regions || 0);
      if (r.ok) {
        tell("map-verdict", leans
          ? `a hull can fly all of this, through its doors: shut, it is `
            + `${rep.regions_shut} separate rooms`
          : "a hull can fly all of this", "ok");
      } else {
        tell("map-verdict", r.error || "not playable");
      }
    } catch (e) {
      tell("map-verdict", e.message);
    }
  }, 400);
}

// --- the list and the editor -----------------------------------------------

function openDoc(d, name) {
  doc = d;
  doc.name = name || "";
  el("editor").hidden = false;
  el("editor-name").textContent = name || "a new map";
  el("map-w").value = doc.w;
  el("map-h").value = doc.h;
  forgetHistory();
  onCanvas = false;
  readout();
  repaint();
  verdict();
  // The editor sits under the list, which on a full table is most of a screen
  // away. Opening one and being left looking at the row you clicked is the
  // kind of thing that reads as a button that did nothing.
  el("editor").scrollIntoView({ block: "start", behavior: "smooth" });
}

async function drawMaps() {
  const r = await post("/v1/admin/maps", { secret });
  known = { maps: r.maps || [], rotations: r.rotations || [], zones: r.zones || [] };
  const rows = known.maps.map((m) => {
    const acts = document.createElement("div");
    acts.className = "acts";
    const edit = document.createElement("button");
    edit.className = "quiet";
    edit.textContent = "edit";
    edit.onclick = () => openNamed(m.name);
    const del = document.createElement("button");
    del.className = "quiet";
    del.textContent = "delete";
    del.onclick = () => remove(m.name);
    acts.append(edit, del);
    return [
      m.name,
      `${m.w} by ${m.h}`,
      String(m.bytes),
      m.zones && m.zones.length ? m.zones.join(", ") : "nothing",
      m.edited,
      m.author || "(gone)",
      acts,
    ];
  });
  fill("maps", rows);
  el("maps-empty").hidden = rows.length > 0;
  el("map-count").textContent = rows.length
    ? `${rows.length} map${rows.length === 1 ? "" : "s"}`
    : "";
  drawRotations();
}

async function openNamed(name) {
  try {
    const r = await post("/v1/admin/map", { secret, name });
    openDoc(unpack(unb64(r.bytes)), name);
    tell("maps-note", `${name} is open`, "ok");
  } catch (e) {
    tell("maps-note", e.message);
  }
}

async function remove(name) {
  const yes = await ask({
    title: `Delete ${name}?`,
    body: "The drawing goes. A zone playing it has to be pointed somewhere else first.",
    ok: "delete",
  });
  // A plain confirm answers with the empty string, and a cancel with null.
  if (yes === null) return;
  try {
    await post("/v1/admin/map/delete", { secret, name });
    if (doc && doc.name === name) closeEditor();
    tell("maps-note", `${name} is gone`, "ok");
    drawMaps();
  } catch (e) {
    tell("maps-note", e.message);
  }
}

function closeEditor() {
  doc = null;
  el("editor").hidden = true;
}

async function save() {
  if (!doc) return;
  let name = doc.name;
  if (!name) {
    name = await ask({
      title: "Name this map",
      body: "Letters, digits, dash and underscore. A zone names it by this.",
      ok: "save",
      label: "name",
      value: "",
    });
    if (!name) return;

  }
  tell("map-verdict", "saving", "plain");
  try {
    const r = await post("/v1/admin/map/save", {
      secret,
      name,
      bytes: b64(pack(doc)),
    });
    doc.name = name;
    doc.dirty = false;
    el("editor-name").textContent = name;
    const note = r.warning
      ? `saved, but the fleet has not heard: ${r.warning}`
      : `saved and published as catalog change ${r.serial}`;
    tell("map-verdict", note, r.warning ? undefined : "ok");
    drawMaps();
  } catch (e) {
    tell("map-verdict", e.message);
  }
}

// --- rotations -------------------------------------------------------------
//
// One row per zone the fleet knows about, plus any zone a rotation already
// names. A zone with an empty list is handed back to its zone file, which is
// the only way back and the reason an empty list is a real answer rather than
// a refusal.

function zonesKnown() {
  // The catalog names the zones, and the server reads the catalog. A rotation
  // for a zone that has since been retired still shows, because it is still
  // stored and somebody has to be able to take it off.
  const names = new Set(known.zones);
  for (const r of known.rotations) names.add(r.zone);
  return [...names].sort();
}

function drawRotations() {
  const host = el("rotations");
  host.textContent = "";
  const zones = zonesKnown();
  if (!zones.length) {
    const p = document.createElement("p");
    p.className = "dim";
    p.textContent = "No zones yet. The fleet view names them once one is up.";
    host.append(p);
    return;
  }
  for (const zone of zones) {
    const row = known.rotations.find((r) => r.zone === zone);
    const chosen = row ? row.maps.slice() : [];

    const card = document.createElement("div");
    card.className = "card";
    const head = document.createElement("div");
    head.className = "row";
    const title = document.createElement("strong");
    title.textContent = zone;
    const state = document.createElement("span");
    state.className = "dim";
    state.textContent = chosen.length
      ? `${chosen.length} map${chosen.length === 1 ? "" : "s"}`
      : "playing its zone file";
    head.append(title, state);

    const list = document.createElement("div");
    list.className = "chips";
    const redraw = () => {
      list.textContent = "";
      chosen.forEach((name, i) => {
        const chip = document.createElement("button");
        chip.className = "quiet";
        chip.textContent = `${i + 1}. ${name} ×`;
        chip.title = "take this one out";
        chip.onclick = () => { chosen.splice(i, 1); redraw(); };
        list.append(chip);
      });
      const add = document.createElement("select");
      const none = document.createElement("option");
      none.textContent = "add a map";
      none.value = "";
      add.append(none);
      for (const m of known.maps) {
        const o = document.createElement("option");
        o.value = m.name;
        o.textContent = m.name;
        add.append(o);
      }
      add.onchange = () => {
        if (add.value) { chosen.push(add.value); redraw(); }
      };
      list.append(add);
      state.textContent = chosen.length
        ? `${chosen.length} map${chosen.length === 1 ? "" : "s"}`
        : "playing its zone file";
    };
    redraw();

    const acts = document.createElement("div");
    acts.className = "row";
    const go = document.createElement("button");
    go.className = "go";
    go.textContent = "publish";
    go.onclick = async () => {
      try {
        const r = await post("/v1/admin/zone-maps", { secret, zone, maps: chosen });
        tell(
          "rot-note",
          r.warning
            ? `${zone} saved, but the fleet has not heard: ${r.warning}`
            : `${zone} plays ${chosen.length || "its zone file"} from the next match`,
          r.warning ? undefined : "ok",
        );
        drawMaps();
      } catch (e) {
        tell("rot-note", e.message);
      }
    };
    acts.append(go);
    card.append(head, list, acts);
    host.append(card);
  }
}

// --- wiring ----------------------------------------------------------------

// The palette, in piles. Twenty-five buttons in one run is a paragraph, and
// what somebody is looking for is nearly always the pile rather than the
// chip: ground to fly through, objects standing in it, places that mean
// something to a mode, and the doors.
function paintChips() {
  const h = el("map-palette");
  h.textContent = "";
  const seen = [];
  for (const p of PAINTS) if (!seen.includes(p.group)) seen.push(p.group);
  for (const group of seen) {
    const row = document.createElement("div");
    row.className = "paints";
    const name = document.createElement("span");
    name.className = "dim";
    name.textContent = group;
    row.append(name);
    PAINTS.forEach((p, i) => {
      if (p.group !== group) return;
      const b = document.createElement("button");
      b.className = "quiet";
      b.textContent = p.label;
      b.setAttribute("aria-pressed", String(i === paint_at));
      b.onclick = () => { paint_at = i; paintChips(); };
      row.append(b);
    });
    h.append(row);
  }
}

function chips(host, items, current, onPick) {
  const h = el(host);
  h.textContent = "";
  items.forEach((it, i) => {
    const b = document.createElement("button");
    b.className = "quiet";
    b.textContent = it.label;
    b.setAttribute("aria-pressed", String(i === current()));
    b.onclick = () => {
      onPick(i);
      chips(host, items, current, onPick);
    };
    h.append(b);
  });
}

// What a tile is, in words, for the readout under the pointer.
//
// The two body variants have no paint of their own, because you place the
// object rather than its middle. They still have to answer, or hovering the
// far corner of a station would say nothing at all.
function nameAt(x, y) {
  const b = at(x, y);
  const cls = b & 15, v = b >> 4;
  if (cls === T_EMPTY) return "empty";
  if (cls === T_SOLID && v === S_ROCK_BODY) return "big rock";
  if (cls === T_SOLID && v === S_STATION_BODY) return "station";
  const p = PAINTS.find((q) => q.cls === cls && q.v === v);
  if (!p) return `class ${cls}, variant ${v}`;
  return p.name || p.label;
}

// Where the pointer is and what is under it.
//
// Tiles are counted from zero at the top left, which is how the file counts
// them and how `sim_map_check` names one when it refuses a map. A readout that
// counted from one would be a second numbering to translate between.
function readout() {
  if (typeof document === "undefined") return;
  const n = el("map-at");
  if (!n) return;
  const [x, y] = hover;
  if (!doc || !onCanvas || x < 0 || y < 0 || x >= doc.w || y >= doc.h) {
    n.textContent = "";
    return;
  }
  n.textContent = `${x}, ${y}   ${nameAt(x, y)}`;
}

// Whether a key belongs to whatever has focus rather than to the editor. Not
// `typing`, which admin.js holds a debounce timer in; see the note at the top.
function inField(on) {
  return !!on && (on.tagName === "INPUT" || on.tagName === "TEXTAREA"
                  || on.tagName === "SELECT" || on.isContentEditable);
}

// What the clipboard is holding, said out loud. A copy has no visible effect
// whatever, and a cut looks exactly like a delete, so the one line under the
// canvas is the only way either says it worked.
function note() {
  if (!clip) return;
  tell("map-verdict", `${clip.w} by ${clip.h} on the clipboard`, "plain");
}

function wire() {
  paintChips();
  chips("map-tools", TOOLS, () => TOOLS.findIndex((t) => t.key === tool),
        (i) => {
          tool = TOOLS[i].key;
          // A marquee left lying under a pencil is a rectangle nobody can get
          // rid of, because the keys that clear it belong to the other tool.
          if (tool !== "select") sel = null;
          repaint();
        });

  const c = el("map-canvas");
  const frame = c.parentElement;

  // What this gesture is laying down, decided when it starts and held for the
  // whole of it. The right button erases whatever the palette says, so a wall
  // can be tidied without losing the paint you were using; the palette's own
  // empty tile is the same thing for anybody who would rather pick it.
  let laying = null;

  // What kind of drag this is: paint, marquee, move, or pan. Decided once, at
  // the press, because a gesture that changes its mind halfway is a gesture
  // that drops tiles somewhere surprising.
  let kind = null;

  // Where a pan started, in client pixels and in scroll offset.
  let from = null;

  // Held space pans instead of drawing, which is the one gesture every tool in
  // this shape shares. Tracked here rather than read off the event because a
  // key held down before the press is not on the press.
  let spacing = false;

  // The right button is a tool here, so the menu it usually opens is not.
  c.addEventListener("contextmenu", (ev) => ev.preventDefault());

  function cursor() {
    if (!frame) return;
    frame.style.cursor = kind === "pan" ? "grabbing" : spacing ? "grab" : "";
  }

  // The shape a drag would leave, run through the tools themselves.
  function preview(x, y, shifted) {
    const p = laying;
    const lay = p === T_EMPTY ? (ax, ay) => put(ax, ay, T_EMPTY) : layer(p);
    let [ex, ey] = [x, y];
    if (shifted) {
      [ex, ey] = lock(dragging[0], dragging[1], x, y, tool !== "line");
    }
    return ghost(() => {
      if (tool === "line") stroke(dragging[0], dragging[1], ex, ey, lay);
      else if (tool === "rect") rect(dragging[0], dragging[1], ex, ey, lay, false);
      else if (tool === "box") rect(dragging[0], dragging[1], ex, ey, lay, true);
    });
  }

  c.addEventListener("pointerdown", (ev) => {
    if (!doc) return;
    ev.preventDefault();
    c.setPointerCapture(ev.pointerId);
    const [x, y] = tileAt(ev);
    dragging = [x, y];

    // Pan first, because the middle button and the space bar mean pan whatever
    // else is picked.
    if (ev.button === 1 || spacing) {
      kind = "pan";
      from = [ev.clientX, ev.clientY, frame.scrollLeft, frame.scrollTop];
      cursor();
      return;
    }

    if (tool === "select") {
      // Inside the marquee is a move, outside it starts a new one.
      kind = inside(sel, x, y) ? "move" : "marquee";
      if (kind === "marquee") sel = null;
      repaint();
      return;
    }

    kind = "paint";
    const rub = ev.button === 2 || ev.ctrlKey;
    laying = rub ? T_EMPTY : PAINTS[paint_at];
    const lay = rub ? (ax, ay) => put(ax, ay, T_EMPTY) : layer(laying);
    beginStep();
    if (tool === "pencil") lay(x, y);
    else if (tool === "fill") {
      if (rub) flood(x, y, { cls: T_EMPTY, v: 0 });
      else flood(x, y, laying);
    }
    repaint();
  });

  c.addEventListener("pointermove", (ev) => {
    if (!doc) return;
    hover = tileAt(ev);
    onCanvas = true;
    readout();
    if (!dragging) return;
    const [x, y] = hover;

    if (kind === "pan") {
      frame.scrollLeft = from[2] - (ev.clientX - from[0]);
      frame.scrollTop = from[3] - (ev.clientY - from[1]);
      return;
    }
    if (kind === "paint" && tool === "pencil") {
      const lay = laying === T_EMPTY ? (ax, ay) => put(ax, ay, T_EMPTY) : layer(laying);
      stroke(dragging[0], dragging[1], x, y, lay);
      dragging = [x, y];
      repaint();
      return;
    }
    if (kind === "paint") { repaint(preview(x, y, ev.shiftKey)); return; }
    if (kind === "marquee") {
      let [ex, ey] = [x, y];
      if (ev.shiftKey) [ex, ey] = lock(dragging[0], dragging[1], x, y, true);
      sel = norm(dragging[0], dragging[1], ex, ey);
      repaint();
      return;
    }
    if (kind === "move") {
      // The block where it would land, drawn over where it still is.
      const dx = x - dragging[0], dy = y - dragging[1];
      const buf = lift(sel);
      repaint(ghost(() => blit(buf, sel.x + dx, sel.y + dy)));
    }
  });

  // One end for every gesture, however it ends. A pointer that leaves the
  // window or is taken away by the browser still closes the step it opened,
  // or the next stroke would be undone together with it.
  const finish = (ev) => {
    if (!doc || !dragging) return;
    const [x, y] = ev ? tileAt(ev) : dragging;
    const shifted = ev ? ev.shiftKey : false;

    if (kind === "pan") {
      dragging = null; kind = null; from = null;
      cursor();
      return;
    }
    if (kind === "marquee") {
      let [ex, ey] = [x, y];
      if (shifted) [ex, ey] = lock(dragging[0], dragging[1], x, y, true);
      sel = norm(dragging[0], dragging[1], ex, ey);
      // A click rather than a drag is a click: it clears rather than selecting
      // one tile, which is what everybody expects of empty space.
      if (sel.w === 1 && sel.h === 1) sel = null;
      dragging = null; kind = null;
      repaint();
      return;
    }
    if (kind === "move") {
      shift(x - dragging[0], y - dragging[1]);
      dragging = null; kind = null;
      repaint();
      verdict();
      return;
    }

    const p = laying;
    const lay = p === T_EMPTY ? (ax, ay) => put(ax, ay, T_EMPTY) : layer(p);
    let [ex, ey] = [x, y];
    if (shifted) [ex, ey] = lock(dragging[0], dragging[1], x, y, tool !== "line");
    if (tool === "line") stroke(dragging[0], dragging[1], ex, ey, lay);
    if (tool === "rect") rect(dragging[0], dragging[1], ex, ey, lay, false);
    if (tool === "box") rect(dragging[0], dragging[1], ex, ey, lay, true);
    dragging = null;
    kind = null;
    endStep();
    repaint();
    verdict();
  };
  c.addEventListener("pointerleave", () => {
    onCanvas = false;
    readout();
  });
  c.addEventListener("pointerup", finish);
  c.addEventListener("pointercancel", () => finish(null));
  c.addEventListener("lostpointercapture", () => finish(null));

  // Space is held to pan and is the page's scroll key the rest of the time, so
  // it is swallowed only while the editor is open and nothing is being typed
  // into.
  addEventListener("keydown", (ev) => {
    if (ev.code !== "Space" || el("editor").hidden || inField(ev.target)) return;
    ev.preventDefault();
    if (!spacing) { spacing = true; cursor(); }
  });
  addEventListener("keyup", (ev) => {
    if (ev.code !== "Space") return;
    spacing = false;
    cursor();
  });
  // A window that loses focus with the key down would come back still panning.
  addEventListener("blur", () => { spacing = false; cursor(); });

  el("map-zoom").oninput = (ev) => { zoom = Number(ev.target.value); repaint(); };
  el("map-resize").onclick = () => {
    if (!doc) return;
    const w = Math.max(9, Math.min(1024, Number(el("map-w").value) | 0));
    const h = Math.max(9, Math.min(1024, Number(el("map-h").value) | 0));
    if (w === doc.w && h === doc.h) return;
    const before = snapshot();
    // Kept from the top left, which is where the drawing is anchored: a resize
    // that recentered would move every wall against every start.
    const next = blank(w, h);
    for (let y = 0; y < Math.min(h, doc.h); y++) {
      for (let x = 0; x < Math.min(w, doc.w); x++) {
        next.tiles[y * w + x] = doc.tiles[y * doc.w + x];
      }
    }
    next.name = doc.name;
    next.dirty = true;
    doc = next;
    pushDoc(before);
    repaint();
    verdict();
  };
  el("map-undo").onclick = undo;
  el("map-redo").onclick = redo;

  // The shortcuts everybody already has in their hands. Not while a field has
  // focus, where they mean what they mean everywhere else: the name dialog is
  // a text box and undo in it is the browser's.
  addEventListener("keydown", (ev) => {
    if (!doc || el("editor").hidden || inField(ev.target)) return;

    // The two that are not chords.
    if (ev.key === "Escape" && sel) { ev.preventDefault(); sel = null; repaint(); return; }
    if ((ev.key === "Delete" || ev.key === "Backspace") && sel) {
      ev.preventDefault();
      beginStep();
      erase(sel);
      endStep();
      repaint();
      verdict();
      return;
    }

    if (!(ev.ctrlKey || ev.metaKey)) return;
    const key = ev.key.toLowerCase();
    if (key === "z" && !ev.shiftKey) { ev.preventDefault(); undo(); }
    else if ((key === "z" && ev.shiftKey) || key === "y") { ev.preventDefault(); redo(); }
    else if (key === "c") { ev.preventDefault(); copy(false); note(); }
    else if (key === "x") {
      ev.preventDefault();
      copy(true);
      note();
      repaint();
      verdict();
    } else if (key === "v") {
      ev.preventDefault();
      paste();
      repaint();
      verdict();
    } else if (key === "a") {
      ev.preventDefault();
      sel = norm(0, 0, doc.w - 1, doc.h - 1);
      repaint();
    }
  });
  el("map-save").onclick = save;
  el("map-close").onclick = closeEditor;
  el("map-new").onclick = () => {
    // A match room, which is the size everything the fleet plays is drawn at,
    // and small enough that a first map is a room rather than a project.
    openDoc(blank(160, 160), "");
    tell("maps-note", "drawing a new map; it is saved when you name it", "plain");
  };
}

// The page wires itself up when there is a page. Under node there is not, and
// what a test wants from this file is the codec: whether these bytes are the
// bytes `sim_map_pack` writes is a question worth answering without a browser,
// because the answer is what decides whether a drawing can be saved at all.
if (typeof document !== "undefined") wire();
if (typeof module !== "undefined") {
  module.exports = {
    pack, unpack, fnv, blank, turned, PAINTS,
    // The history, which is worth testing without a page: undo is the kind of
    // thing that quietly loses a drawing rather than failing loudly.
    put, beginStep, endStep, undo, redo, forgetHistory, flood, stroke, rect,
    // The geometry and the objects, which are worth testing for the same
    // reason: a station written a tile off its grid is a wall nobody can see.
    lock, stamp, layer, ghost, byteOf,
    // The clipboard, whose failure mode is losing the thing you were carrying.
    lift, blit, erase, copy, paste, shift, norm, inside, nameAt,
    paint: (key) => PAINTS.find((p) => p.key === key),
    select: (r) => { sel = r; },
    selection: () => sel,
    clipboard: () => clip,
    open: (d) => { doc = d; forgetHistory(); },
    tiles: () => doc.tiles,
    depth: () => [past.length, future.length],
  };
}
