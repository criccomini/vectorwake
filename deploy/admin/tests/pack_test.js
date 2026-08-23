// The panel's map codec, against the maps the fleet actually serves.
//
//     node deploy/admin/tests/pack_test.js
//
// The editor packs a `.vwmap` in the browser and the meta-layer unpacks it
// with the core, which refuses anything that does not hash to what its header
// claims. So the codec here has to agree with `sim/src/pack.c` byte for byte,
// and the cheapest proof is the shipped maps: read one, write it back, and
// compare. A header field in the wrong place or an FNV that has drifted shows
// up as a file that does not match.
//
// Run from the repository root, so the maps are the ones in the catalog rather
// than copies written down beside this file.

const fs = require("fs");
const path = require("path");

const { pack, unpack } = require(path.join(__dirname, "..", "maps.js"));

let fails = 0;
function check(what, ok, why) {
  if (!ok) fails++;
  console.log(`${what.padEnd(52)} ${ok ? "ok" : "FAIL: " + why}`);
}

for (const name of [
  "melee/drydock",
  "melee/relay",
  "melee/convoy",
  "melee/shoal",
  "melee/breakwater",
  "melee/switchyard",
  // The frozen legacy file remains useful as a second codec fixture.
  "melee/slipway",
]) {
  const file = path.join("catalog", "zones", `${name}.vwmap`);
  const raw = new Uint8Array(fs.readFileSync(file));
  let map;
  try {
    map = unpack(raw);
  } catch (e) {
    check(`${name}: reads`, false, e.message);
    continue;
  }
  check(`${name}: reads`, true);

  const again = pack(map);
  check(
    `${name}: writes the same bytes back`,
    again.length === raw.length && again.every((b, i) => b === raw[i]),
    `${again.length} bytes against ${raw.length}`,
  );

  // The size in the header is the map's own, which is the thing the format
  // grew in order to say.
  check(
    `${name}: carries its own size`,
    map.w > 0 && map.h > 0 && map.w * map.h === map.tiles.length,
    `${map.w} by ${map.h} against ${map.tiles.length} tiles`,
  );
}

// A map the editor draws from nothing has to survive the same trip, including
// the tile classes only an editor puts down.
{
  const { blank, turned } = require(path.join(__dirname, "..", "maps.js"));
  const d = blank(37, 21);
  for (let i = 0; i < d.tiles.length; i++) d.tiles[i] = (i * 7) % 11;
  d.tiles[0] = 1 | (3 << 4); // a slope filled from the south west
  d.tiles[5] = 9 | (1 << 4); // a start for side two
  const back = unpack(pack(d));
  check(
    "a drawn map survives its own round trip",
    back.w === d.w && back.h === d.h && back.tiles.every((b, i) => b === d.tiles[i]),
    "the tiles came back different",
  );

  // Half a turn puts the opposite corner of a slope down, and hands a start to
  // the other side. Anything else turns unchanged.
  check("a slope turns to its opposite corner", turned(10 | (0 << 4)) === (10 | (2 << 4)));
  check("and back again", turned(turned(10 | (1 << 4))) === (10 | (1 << 4)));
  check("a start changes sides", turned(9 | (0 << 4)) === (9 | (1 << 4)));
  check("a wall is a wall either way up", turned(1) === 1);
}

// Undo, which is the part of an editor that loses a drawing quietly rather
// than failing loudly. Driven through the same functions the canvas calls.
{
  const M = require(path.join(__dirname, "..", "maps.js"));
  const d = M.blank(40, 30);
  M.open(d);
  const at = (x, y) => M.tiles()[y * 40 + x];
  // What a tool lays at one tile. The canvas gets this from the palette; a
  // test says the byte it wants.
  const lay = (byte) => (x, y) => M.put(x, y, byte);

  // One gesture is one step, however many tiles it touched.
  M.beginStep();
  M.stroke(2, 2, 12, 2, lay(1));
  M.endStep();
  check("a stroke lays its tiles", at(2, 2) === 1 && at(12, 2) === 1);
  check("and is one step", M.depth()[0] === 1, M.depth().join("/"));

  M.undo();
  check("undo takes the whole stroke back", at(2, 2) === 0 && at(12, 2) === 0);
  check("and offers it back", M.depth().join("/") === "0/1", M.depth().join("/"));

  M.redo();
  check("redo puts it where it was", at(2, 2) === 1 && at(12, 2) === 1);
  check("and the stack is where it started", M.depth().join("/") === "1/0");

  // A stroke that crosses itself undoes to before the stroke, not to what the
  // tile held a moment ago.
  M.beginStep();
  M.put(5, 5, 1);
  M.put(5, 5, 2);
  M.put(5, 5, 3);
  M.endStep();
  check("a tile written three times is still one change", at(5, 5) === 3);
  M.undo();
  check("and undoes to what it held before the gesture", at(5, 5) === 0, String(at(5, 5)));
  M.redo();

  // Drawing after an undo is a new branch: what was undone is not coming back.
  M.undo();
  M.beginStep();
  M.put(9, 9, 1);
  M.endStep();
  check("a new stroke drops what was undone", M.depth()[1] === 0, M.depth().join("/"));

  // The eraser is a paint like any other, so it undoes like one.
  M.beginStep();
  M.rect(2, 2, 12, 2, lay(0), false);
  M.endStep();
  check("erasing clears", at(2, 2) === 0 && at(12, 2) === 0);
  M.undo();
  check("and undo brings the wall back", at(2, 2) === 1 && at(12, 2) === 1, String(at(2, 2)));

  // A gesture that changed nothing is not a step, or undo would do nothing
  // once for every time somebody clicked open ground with the eraser.
  const [before] = M.depth();
  M.beginStep();
  M.put(20, 20, 0);
  M.endStep();
  check("a gesture that changed nothing records nothing", M.depth()[0] === before,
        `${before} then ${M.depth()[0]}`);

  // A fill is one step too, however much of the map it covered.
  M.forgetHistory();
  M.beginStep();
  M.flood(25, 25, { cls: 2, v: 0 });
  M.endStep();
  check("a fill is one step", M.depth()[0] === 1);
  const filled = M.tiles().filter((t) => t === 2).length;
  check("that covered the open ground", filled > 100, String(filled));
  M.undo();
  check("and comes back off in one", M.tiles().filter((t) => t === 2).length === 0);

  // Nothing to undo is not an error.
  M.forgetHistory();
  M.undo();
  M.redo();
  check("undo on an empty stack is quiet", M.depth().join("/") === "0/0");
}

// The objects bigger than a tile. What makes these worth a test is the failure
// mode: a corner written without its body, or two of them half-overlapping,
// is a solid tile the client draws nothing for, and an invisible wall is the
// worst thing a map can have in it.
{
  const M = require(path.join(__dirname, "..", "maps.js"));
  const d = M.blank(40, 30);
  M.open(d);
  const at = (x, y) => M.tiles()[y * 40 + x];

  const big = M.paint("rockbig");
  const station = M.paint("station");
  check("the palette has a big rock and a station", !!big && !!station);
  check("and they know how big they are", big.size === 2 && station.size === 6);

  // 1 is SIM_TILE_SOLID; 4 and 5 are ROCK_BIG and ROCK_BODY.
  M.beginStep();
  M.stamp(4, 6, big);
  M.endStep();
  check("a big rock corners at its anchor", at(4, 6) === (1 | (4 << 4)), String(at(4, 6)));
  check("and the other three are body",
        at(5, 6) === (1 | (5 << 4)) && at(4, 7) === (1 | (5 << 4))
          && at(5, 7) === (1 | (5 << 4)));
  check("a whole object is one step", M.depth()[0] === 1);
  M.undo();
  check("and comes off in one", at(4, 6) === 0 && at(5, 7) === 0);
  M.redo();

  // Snapping is the point: anywhere inside a cell lands on the cell.
  M.beginStep();
  M.stamp(5, 7, big);
  M.endStep();
  check("a stamp inside a placed one does not move it", at(4, 6) === (1 | (4 << 4)));
  check("and writes no second corner", at(5, 7) === (1 | (5 << 4)));

  M.beginStep();
  M.stamp(9, 9, station);
  M.endStep();
  check("a station snaps to its own grid", at(6, 6) === (1 | (6 << 4)), String(at(6, 6)));
  check("and fills six by six", at(11, 11) === (1 | (7 << 4)) && at(12, 12) === 0);

  // Every tile of an object is solid, whichever tile of it you land on. That
  // is what the core reads, and the only thing it reads.
  let solid = 0;
  for (let y = 6; y < 12; y++) for (let x = 6; x < 12; x++) {
    if ((at(x, y) & 15) === 1) solid++;
  }
  check("every tile of a station is a wall to fly into", solid === 36, String(solid));

  // A stamp through the general path, which is what the pencil uses.
  M.forgetHistory();
  const e = M.blank(40, 30);
  M.open(e);
  M.beginStep();
  M.layer(big)(21, 15);
  M.endStep();
  check("the pencil's own path stamps too", at(20, 14) === (1 | (4 << 4)), String(at(20, 14)));

  // A fill lays a field of them, and leaves out any that would hang over.
  M.forgetHistory();
  const f = M.blank(13, 13);
  M.open(f);
  const atf = (x, y) => M.tiles()[y * 13 + x];
  M.beginStep();
  M.flood(6, 6, big);
  M.endStep();
  let corners = 0;
  for (let i = 0; i < M.tiles().length; i++) if (M.tiles()[i] === (1 | (4 << 4))) corners++;
  check("a fill of objects lays them on the grid", corners === 36, String(corners));
  check("and leaves the row that would hang over", atf(12, 12) === 0);
}

// Shift, which is the difference between drawing a 45 degree wall and drawing
// something near one. A slope run only works if it is exactly diagonal.
{
  const M = require(path.join(__dirname, "..", "maps.js"));
  const near = (got, want) => got[0] === want[0] && got[1] === want[1];

  check("a flat drag locks flat", near(M.lock(10, 10, 30, 12, false), [30, 10]),
        String(M.lock(10, 10, 30, 12, false)));
  check("an upright drag locks upright", near(M.lock(10, 10, 12, 30, false), [10, 30]));
  check("a drag near the diagonal locks to it",
        near(M.lock(10, 10, 30, 24, false), [27, 27]), String(M.lock(10, 10, 30, 24, false)));
  check("and backwards down the other diagonal too",
        near(M.lock(10, 10, -4, 26, false), [-5, 25]), String(M.lock(10, 10, -4, 26, false)));
  check("an exact diagonal is left where it is",
        near(M.lock(10, 10, 20, 20, false), [20, 20]));
  // Square for a rectangle, which takes the longer side rather than the
  // projection: a box snaps out to what you dragged, not back from it.
  check("shift squares a rectangle", near(M.lock(10, 10, 30, 18, true), [30, 30]),
        String(M.lock(10, 10, 30, 18, true)));
  check("keeping the direction it was dragged",
        near(M.lock(10, 10, 2, 4, true), [2, 2]), String(M.lock(10, 10, 2, 4, true)));
}

// The clipboard, whose failure mode is losing the thing you were carrying.
{
  const M = require(path.join(__dirname, "..", "maps.js"));
  const d = M.blank(40, 30);
  M.open(d);
  const at = (x, y) => M.tiles()[y * 40 + x];

  M.beginStep();
  M.rect(2, 2, 5, 4, (x, y) => M.put(x, y, 1), false);
  M.endStep();

  M.select(M.norm(2, 2, 5, 4));
  M.copy(false);
  check("a copy takes the rect's own size", M.clipboard().w === 4 && M.clipboard().h === 3,
        `${M.clipboard().w} by ${M.clipboard().h}`);
  check("and leaves the map alone", at(2, 2) === 1);

  M.paste();
  check("a paste with a selection lands back on it", at(2, 2) === 1);
  check("and the pasted block is what is selected now",
        M.selection().x === 2 && M.selection().w === 4);

  // Somewhere else, by moving the selection first.
  M.select(M.norm(20, 20, 23, 22));
  M.paste();
  check("a paste at another selection lands there", at(20, 20) === 1 && at(23, 22) === 1);

  // A cut clears what it took.
  M.select(M.norm(2, 2, 5, 4));
  M.copy(true);
  check("a cut takes the tiles", at(2, 2) === 0 && at(5, 4) === 0);
  check("and still has them", M.clipboard().tiles.every((t) => t === 1));
  M.undo();
  check("and undoes in one step", at(2, 2) === 1 && at(5, 4) === 1);

  // A move overlapping its own source: the classic way to eat a drawing.
  M.select(M.norm(2, 2, 5, 4));
  M.shift(1, 0);
  check("a move that overlaps its source keeps every tile",
        at(3, 2) === 1 && at(6, 4) === 1, `${at(3, 2)} ${at(6, 4)}`);
  check("and clears the column it left", at(2, 2) === 0, String(at(2, 2)));
  check("and takes the selection with it", M.selection().x === 3);
  M.undo();
  check("a move undoes in one step", at(2, 2) === 1 && at(6, 4) === 0,
        `${at(2, 2)} ${at(6, 4)}`);
}

// A preview has to be the same drawing the drag will land, or it is a second
// implementation of a line that agrees with the first one until it doesn't.
{
  const M = require(path.join(__dirname, "..", "maps.js"));
  const d = M.blank(40, 30);
  M.open(d);

  const lay = (x, y) => M.put(x, y, 1);
  const seen = M.ghost(() => M.stroke(3, 3, 14, 9, lay));
  check("a preview writes nothing to the map", M.tiles().every((t) => t === 0));
  check("and knows every tile the line would take", seen.size === 12, String(seen.size));

  M.beginStep();
  M.stroke(3, 3, 14, 9, lay);
  M.endStep();
  let same = true;
  for (const [k, b] of seen) if (M.tiles()[k] !== b) same = false;
  check("and the line lands exactly where the preview said", same);

  // An object preview covers its whole footprint, not just the tile under the
  // pointer, or a station would look like a single tile until you let go.
  const big = M.paint("rockbig");
  const shape = M.ghost(() => M.stamp(4, 6, big));
  check("an object previews its whole footprint", shape.size === 4, String(shape.size));
}

console.log(fails === 0 ? "all ok" : `${fails} failed`);
process.exit(fails === 0 ? 0 : 1);
