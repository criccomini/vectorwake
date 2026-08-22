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

for (const name of ["melee/drydock", "melee/slipway"]) {
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

  // One gesture is one step, however many tiles it touched.
  M.beginStep();
  M.stroke(2, 2, 12, 2, 1);
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
  M.rect(2, 2, 12, 2, 0, false);
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
  M.flood(25, 25, 2);
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

console.log(fails === 0 ? "all ok" : `${fails} failed`);
process.exit(fails === 0 ? 0 : 1);
