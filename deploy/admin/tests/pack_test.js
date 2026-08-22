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

console.log(fails === 0 ? "all ok" : `${fails} failed`);
process.exit(fails === 0 ? 0 : 1);
