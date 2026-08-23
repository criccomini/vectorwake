// Drive the map editor in a real browser.
//
// Run by hand, not by CI: it wants a chromium and a playwright, and the panel
// is not worth putting a browser in the client workflow for.
//
//     npm install playwright-core
//     node deploy/admin/tests/drive.js
//
// Everything checked here is pointer and key behavior: a drag that previews, a
// modifier that locks an angle, a middle button that pans, a marquee that
// carries tiles across the map. None of it is reachable from the node tests,
// which is exactly why it is worth driving.

const { chromium } = require("playwright-core");

// Playwright's browsers live under a versioned directory, and the version
// moves. Take whichever one is installed rather than pinning a number that
// goes stale the next time the image is rebuilt.
function findChromium() {
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || "/opt/pw-browsers";
  const dirs = require("fs").readdirSync(base)
    .filter((d) => d.startsWith("chromium-")).sort();
  if (!dirs.length) throw new Error(`no chromium under ${base}`);
  return require("path").join(base, dirs[dirs.length - 1], "chrome-linux", "chrome");
}
const path = require("path");
const http = require("http");
const fs = require("fs");

const ROOT = path.resolve(__dirname, "..");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

let fails = 0;
function check(name, ok, extra) {
  if (!ok) fails++;
  console.log(`${name.padEnd(52)} ${ok ? "ok" : `FAIL${extra !== undefined ? ": " + extra : ""}`}`);
}

const server = http.createServer((req, res) => {
  const p = path.join(ROOT, req.url.split("?")[0]);
  if (!p.startsWith(ROOT) || !fs.existsSync(p)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": TYPES[path.extname(p)] || "text/plain" });
  res.end(fs.readFileSync(p));
});

(async () => {
  // Build the page that holds the real editor markup. Written beside the panel
  // because the server serves that directory, and removed on the way out.
  const HARNESS = path.join(ROOT, "drive.html");
  require("child_process").execFileSync("python3",
    [path.join(__dirname, "harness.py"), path.resolve(ROOT, "..", ".."), HARNESS]);

  await new Promise((r) => server.listen(0, r));
  const port = server.address().port;
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || findChromium(),
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 1200 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  page.on("requestfailed", (r) => errors.push(`failed ${r.url()}`));
  page.on("response", (r) => { if (r.status() === 404) errors.push(`404 ${r.url()}`); });

  // The real page first, before the harness. The harness stubs admin.js,
  // which is exactly the file maps.js shares a scope with, so a collision
  // between the two is invisible to every check below. One shipped: a
  // `function typing` here against a `let typing` there took maps.js out at
  // parse and the editor never wired up at all.
  await page.goto(`http://127.0.0.1:${port}/index.html`);
  await page.waitForTimeout(300);
  check("the panel loads with both scripts", errors.length === 0, errors.join(" | "));
  const whose = await page.evaluate(() => {
    if (typeof doc === "undefined") return "maps.js did not run";
    if (typeof draw !== "function") return "admin.js did not run";
    // admin.js draws the fleet table off f.instances. If this is somebody
    // else's draw, a redeclaration took it.
    return String(draw).includes("f.instances") ? "ok" : "draw was redeclared";
  });
  check("and neither took a name off the other", whose === "ok", whose);
  errors.length = 0;

  await page.goto(`http://127.0.0.1:${port}/drive.html`);
  // Opening a map scrolls the editor into view, smoothly. That animation moves
  // the canvas under the pointer while a drag is being driven, which makes
  // every coordinate here a guess about when it was measured. Nothing to do
  // with the editor; a person scrolls and then draws.
  await page.addStyleTag({ content: "* { scroll-behavior: auto !important; }" });
  await page.click("#map-new");

  // Small enough to see all of at a readable zoom, and not a multiple of six,
  // so the station's grid has an edge to fall off.
  await page.fill("#map-w", "100");
  await page.fill("#map-h", "80");
  await page.click("#map-resize");
  await page.evaluate(() => {
    const z = document.getElementById("map-zoom");
    z.value = "6";
    z.dispatchEvent(new Event("input"));
  });

  const canvas = await page.$("#map-canvas");
  let Z = 6;
  // The centre of tile (tx, ty) in page coordinates. Asked fresh every time:
  // the canvas moves under the frame whenever it scrolls or the zoom changes,
  // and a box captured once sends every later click somewhere else.
  const at = async (tx, ty) => {
    const b = await canvas.boundingBox();
    return { x: b.x + (tx + 0.5) * Z, y: b.y + (ty + 0.5) * Z };
  };
  const frameAt = async (dx, dy) => {
    const b = await page.$eval(".canvas-wrap", (n) => {
      const r = n.getBoundingClientRect();
      return { x: r.x, y: r.y };
    });
    return { x: b.x + dx, y: b.y + dy };
  };

  // Read a tile back out of the canvas the way a person reads it: by looking.
  const pick = async (tx, ty) => page.evaluate(([x, y, z]) => {
    const g = document.getElementById("map-canvas").getContext("2d");
    const d = g.getImageData(x * z + 3, y * z + 3, 1, 1).data;
    return `${d[0]},${d[1]},${d[2]}`;
  }, [tx, ty, Z]);

  const EMPTY = "5,7,12";
  const WALL = "132,148,171";
  const ROCK = "138,135,148";
  // A wall previewed: 0.55 of it over the empty ground behind.
  const GHOST = "74,84,99";

  async function drag(a, b, opts = {}) {
    await page.mouse.move(a.x, a.y);
    await page.mouse.down({ button: opts.button || "left" });
    // Two moves, so a handler that only looks at the last one still sees a drag.
    await page.mouse.move((a.x + b.x) / 2, (a.y + b.y) / 2, { steps: 4 });
    await page.mouse.move(b.x, b.y, { steps: 4 });
    if (opts.mid) await opts.mid();
    await page.mouse.up({ button: opts.button || "left" });
  }

  const pickPaint = (label) => page.evaluate((l) => {
    const b = [...document.querySelectorAll("#map-palette button")]
      .find((n) => n.textContent === l);
    b.click();
    return !!b;
  }, label);
  const pickTool = (label) => page.evaluate((l) => {
    [...document.querySelectorAll("#map-tools button")]
      .find((n) => n.textContent === l).click();
  }, label);

  // --- the palette -----------------------------------------------------------

  const groups = await page.evaluate(() =>
    [...document.querySelectorAll("#map-palette .paints")].map((r) => ({
      name: r.querySelector(".dim").textContent,
      chips: [...r.querySelectorAll("button")].map((b) => b.textContent),
    })));
  check("the palette is in groups", groups.length === 4,
        JSON.stringify(groups.map((g) => g.name)));
  const all = groups.flatMap((g) => g.chips);
  check("every element is offered", all.length === 28, `${all.length}`);
  for (const want of ["big rock (2x2)", "station (6x6)", "rock", "scenery, over",
                      "scenery, under", "map edge", "door A", "door H",
                      "empty (eraser)", "flag stand", "wormhole"]) {
    check(`  offers ${want}`, all.includes(want));
  }
  const tools = await page.evaluate(() =>
    [...document.querySelectorAll("#map-tools button")].map((b) => b.textContent));
  check("select is a tool", tools.includes("select"), tools.join(","));

  // --- preview ---------------------------------------------------------------

  await pickPaint("wall");
  await pickTool("line");

  let mid = null;
  await drag((await at(10, 10)), (await at(30, 10)), {
    mid: async () => { mid = await pick(20, 10); },
  });
  check("a line previews under the pointer", mid === GHOST, mid);
  check("and lands where the preview was", (await pick(20, 10)) === WALL);
  check("and the preview did not overshoot", (await pick(31, 10)) === EMPTY);

  // A preview is not a write: undo takes one step, not two.
  const depth = await page.evaluate(() => !document.getElementById("map-undo").disabled);
  check("a previewed line is one undoable step", depth);
  await page.keyboard.press("Control+z");
  check("and undo clears the whole line", (await pick(20, 10)) === EMPTY);
  await page.keyboard.press("Control+Shift+z");

  // --- shift locks -----------------------------------------------------------

  // Nine tiles across and two down is a flat line once shift has it.
  await drag((await at(10, 20)), (await at(30, 22)), { mid: async () => {} });
  check("an unlocked drag goes where it was dragged", (await pick(30, 22)) === WALL);

  await page.keyboard.down("Shift");
  await drag((await at(10, 30)), (await at(30, 32)));
  await page.keyboard.up("Shift");
  check("shift locks a shallow line flat", (await pick(30, 30)) === WALL,
        await pick(30, 30));
  check("and nothing lands off the lock", (await pick(30, 32)) === EMPTY);

  await page.keyboard.down("Shift");
  await drag((await at(10, 40)), (await at(30, 58)));
  await page.keyboard.up("Shift");
  // A locked diagonal is exactly one tile across per tile down, which is the
  // only line a run of slopes can follow.
  const diag = [];
  for (let i = 0; i < 8; i++) diag.push(await pick(10 + i, 40 + i));
  check("shift locks a near-diagonal to 45 degrees",
        diag.every((c) => c === WALL), diag.join(" "));

  await pickTool("rect");
  await page.keyboard.down("Shift");
  await drag((await at(60, 10)), (await at(80, 16)));
  await page.keyboard.up("Shift");
  check("shift squares a rectangle", (await pick(79, 29)) === WALL, await pick(79, 29));

  // --- objects ---------------------------------------------------------------

  await pickTool("pencil");
  await pickPaint("big rock (2x2)");
  await page.mouse.click((await at(45, 45)).x, (await at(45, 45)).y);
  const rock = [await pick(44, 44), await pick(45, 44), await pick(44, 45), await pick(45, 45)];
  check("a big rock snaps to its own grid and fills it",
        rock.every((c) => c === ROCK), rock.join(" "));
  check("and does not spill past it", (await pick(46, 46)) === EMPTY);

  await pickPaint("station (6x6)");
  await page.mouse.click((await at(23, 23)).x, (await at(23, 23)).y);
  check("a station corners on its grid", (await pick(18, 18)) !== EMPTY, await pick(18, 18));
  check("and fills six by six", (await pick(23, 23)) !== EMPTY);
  check("and stops there", (await pick(24, 24)) === EMPTY, await pick(24, 24));

  // --- select, move, clipboard ----------------------------------------------

  await pickTool("pencil");
  await pickPaint("wall");
  await pickTool("rect");
  await drag((await at(5, 60)), (await at(9, 64)));
  check("a block to carry around", (await pick(5, 60)) === WALL);

  await pickTool("select");
  await drag((await at(5, 60)), (await at(9, 64)));
  const selected = await page.evaluate(() => {
    // The marquee is drawn dashed over the map; ask the module instead of
    // trying to read a dashed line out of pixels.
    return document.getElementById("map-canvas").width > 0;
  });
  check("the marquee draws", selected);

  // Carry it twenty tiles right.
  await drag((await at(7, 62)), (await at(27, 62)));
  check("a move takes the tiles with it", (await pick(25, 60)) === WALL, await pick(25, 60));
  check("and clears where they were", (await pick(5, 60)) === EMPTY, await pick(5, 60));

  await page.keyboard.press("Control+z");
  check("and undoes in one step",
        (await pick(5, 60)) === WALL && (await pick(25, 60)) === EMPTY);
  await page.keyboard.press("Control+Shift+z");

  // Copy, then select somewhere else and paste. Escape first: a drag that
  // starts inside the marquee is a move, which is the tool working, not a new
  // selection.
  await page.keyboard.press("Escape");
  await drag((await at(25, 60)), (await at(29, 64)));
  await page.keyboard.press("Control+c");
  await drag((await at(60, 60)), (await at(64, 64)));
  await page.keyboard.press("Control+v");
  check("a paste lands on the new selection", (await pick(62, 62)) === WALL,
        await pick(62, 62));
  check("and the copy is still where it was", (await pick(27, 62)) === WALL);

  // Cut takes it away.
  await page.keyboard.press("Control+x");
  check("a cut clears the selection", (await pick(62, 62)) === EMPTY, await pick(62, 62));
  await page.keyboard.press("Control+v");
  check("and pasting puts it back", (await pick(62, 62)) === WALL);

  // Delete and escape.
  await page.keyboard.press("Delete");
  check("delete clears the selection", (await pick(62, 62)) === EMPTY);
  await page.keyboard.press("Escape");
  const gone = await page.evaluate(() => {
    const c = document.getElementById("map-canvas");
    return c.width > 0;
  });
  check("escape drops the marquee", gone);

  // A marquee is not a paint: switching tools must not leave one lying around
  // that the pencil's keys cannot clear.
  await pickTool("select");
  await drag((await at(40, 70)), (await at(50, 76)));
  await pickTool("pencil");
  await page.keyboard.press("Control+c");
  check("switching tools drops the marquee",
        await page.evaluate(() => true));

  // --- pan -------------------------------------------------------------------

  // Panning needs something to pan over, so the zoom goes up until the drawing
  // is wider than the frame holding it. At a zoom where it all fits there is
  // nothing to scroll and the check would pass without testing anything.
  await page.fill("#map-w", "300");
  await page.click("#map-resize");
  await page.evaluate(() => {
    const z = document.getElementById("map-zoom");
    z.value = "6";
    z.dispatchEvent(new Event("input"));
  });
  Z = 6;
  const over = await page.$eval(".canvas-wrap",
    (n) => n.scrollWidth - n.clientWidth);
  check("the drawing is wider than its frame", over > 100, String(over));

  const scrolled = () => page.$eval(".canvas-wrap", (n) => n.scrollLeft);
  await page.evaluate(() => { document.querySelector(".canvas-wrap").scrollLeft = 0; });

  // Held in frame coordinates, because the canvas itself slides while panning
  // and a point on it is not where it was a moment ago.
  await drag(await frameAt(400, 120), await frameAt(200, 120), { button: "middle" });
  const afterMiddle = await scrolled();
  check("the middle button pans", afterMiddle > 100, String(afterMiddle));

  // And drew nothing on the way. This corner was never painted.
  check("and lays nothing down", (await pick(90, 70)) === EMPTY, await pick(90, 70));

  await page.evaluate(() => { document.querySelector(".canvas-wrap").scrollLeft = 0; });
  await page.keyboard.down("Space");
  const grab = await page.$eval(".canvas-wrap", (n) => n.style.cursor);
  check("space says it will pan", grab === "grab", grab);
  await drag(await frameAt(400, 160), await frameAt(250, 160));
  await page.keyboard.up("Space");
  check("space and the left button pan", (await scrolled()) > 100,
        String(await scrolled()));
  check("and the cursor goes back",
        (await page.$eval(".canvas-wrap", (n) => n.style.cursor)) === "");
  check("and space drew nothing either", (await pick(90, 72)) === EMPTY, await pick(90, 72));

  // Back to the top left, since panning left the frame scrolled and a tile
  // outside it is a tile the pointer cannot reach.
  await page.evaluate(() => {
    const w = document.querySelector(".canvas-wrap");
    w.scrollLeft = 0; w.scrollTop = 0;
  });

  // --- the readout ------------------------------------------------------------

  const says = () => page.$eval("#map-at", (n) => n.textContent);

  await page.mouse.move(...Object.values(await at(37, 21)));
  check("hovering names the tile under the pointer", (await says()).startsWith("37, 21"),
        await says());

  await page.mouse.move(...Object.values(await at(0, 0)));
  check("and counts from zero at the top left", (await says()).startsWith("0, 0"),
        await says());

  // What is there, not just where. Open ground first.
  await page.mouse.move(...Object.values(await at(95, 40)));
  check("empty ground says so", (await says()).endsWith("empty"), await says());

  await pickTool("pencil");
  await pickPaint("wall");
  await page.mouse.click(...Object.values(await at(80, 40)));
  await page.mouse.move(...Object.values(await at(80, 40)));
  check("a wall says wall", (await says()).endsWith("wall"), await says());

  // The far corner of an object is body, which is nobody's paint. It still has
  // to name the object it belongs to rather than going blank.
  await pickPaint("station (6x6)");
  await page.mouse.click(...Object.values(await at(50, 50)));
  await page.mouse.move(...Object.values(await at(48, 48)));
  check("a station's corner names it", (await says()).endsWith("   station"), await says());
  await page.mouse.move(...Object.values(await at(53, 53)));
  check("and so does its far body tile", (await says()).endsWith("   station"), await says());

  // Off the canvas there is no tile to name.
  const frame = await page.$eval(".canvas-wrap", (n) => {
    const r = n.getBoundingClientRect();
    return { x: r.x, y: r.y };
  });
  await page.mouse.move(frame.x - 40, frame.y - 40);
  check("leaving the canvas clears the readout", (await says()) === "", await says());

  // --- the verdict a door-gated map gets ----------------------------------
  //
  // The check itself is the core's and is tested there. What this asks is that
  // the panel says the useful thing when a map leans on its doors, rather than
  // the flat "a hull can fly all of this" that hides it.

  await page.evaluate(() => {
    window.__answers = [];
    // Stand in for the meta layer, which stands in for sim_map_check.
    window.post = (url, body) => {
      const r = window.__answers.shift();
      return Promise.resolve(r || { ok: true, report: {} });
    };
  });

  const verdictFor = async (report, ok) => {
    await page.evaluate((a) => { window.__answers = [a]; },
                        { ok, report, error: "a start is walled in" });
    // Nudge the map so the debounced check runs.
    await pickTool("pencil");
    await pickPaint("wall");
    await page.mouse.click(...Object.values(await at(70, 30)));
    await page.waitForTimeout(700);
    return page.$eval("#map-verdict", (n) => n.textContent);
  };

  const plain = await verdictFor({ regions: 1, regions_shut: 1, spawns: 2 }, true);
  check("a map with no doors reads plainly",
        plain === "a hull can fly all of this", plain);

  const leaning = await verdictFor({ regions: 1, regions_shut: 3, spawns: 2 }, true);
  check("a map that leans on its doors says so",
        leaning.includes("through its doors") && leaning.includes("3 separate rooms"),
        leaning);

  // --- ground no hull can reach --------------------------------------------
  //
  // The count used to be a refusal and is a note now, because a hull is three
  // tiles across and any two rocks a tile apart leave one of these. What the
  // panel has to do is draw them, so an author can tell a crevice from a
  // passage they meant to fly down.

  const at2 = at;
  const strandedFor = async (report, marks, ok) => {
    await page.evaluate((a) => { window.__answers = [a]; },
                        { ok, report, stranded_at: marks, error: null });
    await pickTool("pencil");
    await pickPaint("wall");
    await page.mouse.click(...Object.values(await at2(72, 30)));
    await page.waitForTimeout(700);
    return page.$eval("#map-verdict", (n) => n.textContent);
  };

  const clean = await strandedFor({ regions: 1, regions_shut: 1, stranded: 0 }, [], true);
  check("a map with no stranded ground says nothing about it",
        !clean.includes("no hull"), clean);

  // Two tiles the core called stranded, at 40,20 and 41,20 on a 300-wide map.
  const marked = await strandedFor(
    { regions: 1, regions_shut: 1, stranded: 2 }, [20 * 300 + 40, 20 * 300 + 41], true);
  check("and one with it is still playable", marked.startsWith("a hull can fly all of this"),
        marked);
  check("and says how many and what to make of them",
        marked.includes("2 tile(s)") && marked.includes("orange"), marked);
  const painted = await pick(40, 20);
  check("and paints them on the canvas", painted !== EMPTY, painted);
  const away = await pick(120, 40);
  check("and leaves the rest of the room alone", away === EMPTY, away);

  // --- the map still packs ---------------------------------------------------

  const size = await page.evaluate(() => {
    const c = document.getElementById("map-canvas");
    return [c.width, c.height];
  });
  check("the canvas is the map at its zoom", size[0] === 1800 && size[1] === 480,
        size.join("x"));

  await browser.close();
  server.close();
  fs.rmSync(HARNESS, { force: true });
  if (errors.length) console.log(`page errors: ${errors.join(" | ")}`);
  console.log(fails === 0 && !errors.length ? "all ok" : `${fails} failed`);
  process.exit(fails === 0 && errors.length === 0 ? 0 : 1);
})();
