// The map editor, and what each zone plays.
//
// Loaded after admin.js and using its helpers: `post`, `el`, `tell`, `fill`
// and `ask` are script-scope bindings from that file, which is what a classic
// script gives a later one.
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

// What you can put down, in the order the palette shows it. `v` is the
// variant, which means a different thing per class: a channel for a door, a
// team for a start or a goal, and the filled corner for a slope.
//
// The slopes are named for the corner that stays solid, which is what the
// simulation calls them, and drawn as the triangle they are.
const PAINTS = [
  { key: "wall", cls: T_SOLID, v: 0, label: "wall" },
  { key: "empty", cls: T_EMPTY, v: 0, label: "empty" },
  { key: "nw", cls: T_SLOPE, v: 0, label: "slope NW" },
  { key: "ne", cls: T_SLOPE, v: 1, label: "slope NE" },
  { key: "se", cls: T_SLOPE, v: 2, label: "slope SE" },
  { key: "sw", cls: T_SLOPE, v: 3, label: "slope SW" },
  { key: "spawn0", cls: T_SPAWN, v: 0, label: "start, side one" },
  { key: "spawn1", cls: T_SPAWN, v: 1, label: "start, side two" },
  { key: "safe", cls: T_SAFE, v: 0, label: "safe" },
  { key: "door0", cls: T_DOOR, v: 0, label: "door A" },
  { key: "door1", cls: T_DOOR, v: 1, label: "door B" },
  { key: "worm", cls: T_WORMHOLE, v: 0, label: "wormhole" },
  { key: "turf", cls: T_TURF, v: 0, label: "flag stand" },
  { key: "goal0", cls: T_GOAL, v: 0, label: "goal, side one" },
  { key: "goal1", cls: T_GOAL, v: 1, label: "goal, side two" },
];

const TOOLS = [
  { key: "pencil", label: "pencil" },
  { key: "line", label: "line" },
  { key: "rect", label: "rect" },
  { key: "box", label: "outline" },
  { key: "fill", label: "fill" },
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
  [T_OVER]: "#1d2838",
  [T_UNDER]: "#1d2838",
  [T_TURF]: "#ffa552",
  [T_SPAWN]: "#4fd6ff",
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

function put(x, y, byte) {
  if (!doc || x < 0 || y < 0 || x >= doc.w || y >= doc.h) return;
  doc.tiles[y * doc.w + x] = byte;
  doc.dirty = true;
  if (el("map-sym").checked) {
    const mx = doc.w - 1 - x, my = doc.h - 1 - y;
    if (mx !== x || my !== y) doc.tiles[my * doc.w + mx] = turned(byte);
  }
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

function draw() {
  if (!doc) return;
  const c = el("map-canvas");
  c.width = doc.w * zoom;
  c.height = doc.h * zoom;
  const g = c.getContext("2d");
  g.fillStyle = INK[T_EMPTY];
  g.fillRect(0, 0, c.width, c.height);
  for (let y = 0; y < doc.h; y++) {
    for (let x = 0; x < doc.w; x++) {
      const b = at(x, y);
      const cls = b & 15, v = b >> 4;
      if (cls === T_EMPTY) continue;
      g.fillStyle = INK[cls] || "#8494ab";
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
}

// --- tools -----------------------------------------------------------------

function byteOf(p) { return p.cls | (p.v << 4); }

function stroke(x0, y0, x1, y1, byte) {
  // Bresenham, so a dragged line is the line you drew and not a stack of
  // rectangles with gaps between them.
  let dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
  let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy;
  for (;;) {
    put(x0, y0, byte);
    if (x0 === x1 && y0 === y1) break;
    const e2 = 2 * err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
}

function rect(x0, y0, x1, y1, byte, outline) {
  const [lx, hx] = x0 < x1 ? [x0, x1] : [x1, x0];
  const [ly, hy] = y0 < y1 ? [y0, y1] : [y1, y0];
  for (let y = ly; y <= hy; y++) {
    for (let x = lx; x <= hx; x++) {
      if (outline && x !== lx && x !== hx && y !== ly && y !== hy) continue;
      put(x, y, byte);
    }
  }
}

function flood(x, y, byte) {
  const want = at(x, y);
  if (want === byte) return;
  const stack = [[x, y]];
  while (stack.length) {
    const [cx, cy] = stack.pop();
    if (cx < 0 || cy < 0 || cx >= doc.w || cy >= doc.h) continue;
    if (at(cx, cy) !== want) continue;
    put(cx, cy, byte);
    stack.push([cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1]);
  }
}

function tileAt(ev) {
  const c = el("map-canvas");
  const r = c.getBoundingClientRect();
  return [
    Math.floor((ev.clientX - r.left) / zoom),
    Math.floor((ev.clientY - r.top) / zoom),
  ];
}

// --- the live verdict ------------------------------------------------------
//
// Asked of the server while somebody draws, because "a start is walled in" is
// worth hearing when you wall it in rather than when you press save. Debounced
// hard: this packs the whole map and the far end floods it twice.

function verdict() {
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
      if (r.ok) {
        tell("map-verdict", "a hull can fly all of this", "ok");
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
  draw();
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

function wire() {
  chips("map-palette", PAINTS, () => paint_at, (i) => { paint_at = i; });
  chips("map-tools", TOOLS, () => TOOLS.findIndex((t) => t.key === tool),
        (i) => { tool = TOOLS[i].key; });

  const c = el("map-canvas");
  c.addEventListener("pointerdown", (ev) => {
    if (!doc) return;
    ev.preventDefault();
    c.setPointerCapture(ev.pointerId);
    const [x, y] = tileAt(ev);
    const byte = byteOf(PAINTS[paint_at]);
    if (tool === "pencil") { put(x, y, byte); dragging = [x, y]; }
    else if (tool === "fill") flood(x, y, byte);
    else dragging = [x, y];
    draw();
  });
  c.addEventListener("pointermove", (ev) => {
    if (!doc || !dragging) return;
    const [x, y] = tileAt(ev);
    if (tool === "pencil") {
      stroke(dragging[0], dragging[1], x, y, byteOf(PAINTS[paint_at]));
      dragging = [x, y];
      draw();
    }
  });
  c.addEventListener("pointerup", (ev) => {
    if (!doc || !dragging) return;
    const [x, y] = tileAt(ev);
    const byte = byteOf(PAINTS[paint_at]);
    if (tool === "line") stroke(dragging[0], dragging[1], x, y, byte);
    if (tool === "rect") rect(dragging[0], dragging[1], x, y, byte, false);
    if (tool === "box") rect(dragging[0], dragging[1], x, y, byte, true);
    dragging = null;
    draw();
    verdict();
  });

  el("map-zoom").oninput = (ev) => { zoom = Number(ev.target.value); draw(); };
  el("map-resize").onclick = () => {
    if (!doc) return;
    const w = Math.max(9, Math.min(1024, Number(el("map-w").value) | 0));
    const h = Math.max(9, Math.min(1024, Number(el("map-h").value) | 0));
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
    draw();
    verdict();
  };
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
if (typeof module !== "undefined") module.exports = { pack, unpack, fnv, blank, turned };
