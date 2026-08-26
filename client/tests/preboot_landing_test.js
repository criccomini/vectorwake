// The page's own loader draws the lockup and the loading rail before the
// engine exists, and it has to draw them where the engine will: the hand-off
// is a cross fade, so anything that moves across it moves in full view. That
// means the landing geometry is written twice, once as `landing_geom` in
// client/arena/ui.lua and once as `landing()` in client/tools/single_file.py,
// with no way to share it -- one is Lua inside the engine and the other runs
// before the engine is there to ask.
//
// So it is pinned from both ends instead. The table below is what the game
// draws at each window shape, and client/tests/landing_test.lua checks the
// same numbers against the Lua. Either copy drifting fails one of the two.

const fs = require("fs");

const source = fs.readFileSync("client/tools/single_file.py", "utf8");
const startMark = "// preboot-landing-test:start";
const endMark = "// preboot-landing-test:end";
const start = source.indexOf(startMark);
const end = source.indexOf(endMark);
if (start < 0 || end < start) {
  throw new Error("Preboot landing boundary is missing from single_file.py");
}
const body = source.slice(start + startMark.length, end);

// The shapes the interface has classes for: a monitor, an upright phone, a
// phone on its side, a window narrow enough to take the edge-to-edge key, and
// the two sides of the 480 point line that decides compact.
const SHAPES = [
  {w: 1440, h: 810, kx: 560, ky: 734, kw: 320, kh: 54, size: 26, wy: 701},
  {w: 1280, h: 800, kx: 480, ky: 724, kw: 320, kh: 54, size: 26, wy: 691},
  {w: 1920, h: 1080, kx: 800, ky: 1004, kw: 320, kh: 54, size: 26, wy: 971},
  {w: 620, h: 800, kx: 150, ky: 724, kw: 320, kh: 54, size: 26, wy: 691},
  {w: 600, h: 900, kx: 14, ky: 828, kw: 572, kh: 50, size: 26, wy: 795},
  {w: 390, h: 844, kx: 14, ky: 776, kw: 362, kh: 50, size: 20, wy: 750},
  {w: 844, h: 390, kx: 302, ky: 328, kw: 240, kh: 44, size: 20, wy: 302},
  {w: 479, h: 479, kx: 14, ky: 411, kw: 451, kh: 50, size: 20, wy: 385},
];

let failures = 0;
function check(label, ok, detail) {
  if (ok) {
    console.log("ok   " + label);
    return;
  }
  failures += 1;
  console.log("FAIL " + label + (detail ? "  " + detail : ""));
}

// `landing` reads `w`, `h` and `window.vwInsets` off the loader's own scope,
// so the extracted source is closed over those three and asked for the
// function it declares.
const geometry = (win, w, h) =>
  new Function("window", "w", "h", body + "\nreturn landing();")(win, w, h);

for (const s of SHAPES) {
  const got = geometry({}, s.w, s.h);
  for (const key of ["kx", "ky", "kw", "kh", "size", "wy"]) {
    check(s.w + "x" + s.h + " " + key,
          Math.abs(got[key] - s[key]) < 0.001,
          got[key] + " against " + s[key]);
  }
}

// A phone with a home bar under the key. The reconciler publishes the four
// numbers the engine reads, so the loader reads the same ones rather than
// drawing a lockup the engine will lift 34 points the moment it takes over.
const inset = geometry({vwInsets: "0 0 47 34 1 844 844 844 844 844 0"},
                       390, 844);
check("a safe area lifts the key off the home bar",
      inset.ky === 844 - 34 - 18 - 50, String(inset.ky));
check("and takes the lockup with it",
      inset.wy === inset.ky - 16 - 10, String(inset.wy));

// Nothing published yet: the reconciler runs on its own clock and the loader
// draws from the first frame. Zero is right on every desktop and one frame
// stale on a phone, which a canvas redrawn every frame corrects itself.
const bare = geometry({}, 390, 844);
check("no insets yet is the same as no insets", bare.ky === 776,
      String(bare.ky));

if (failures > 0) {
  console.log(failures + " preboot landing checks failed");
  process.exit(1);
}
console.log("all preboot landing checks passed");
