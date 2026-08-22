// The panel's scripts share one scope. This proves they can both live in it.
//
// admin.js and maps.js are classic <script> tags on one page, so every name
// either declares at its top level lands in the same global scope. There are
// two ways that goes wrong and neither is loud:
//
//   - `function f` in both files is legal. The later script silently wins and
//     the earlier file's `f` is gone, so a function that still has a caller
//     and a definition is nonetheless a different function by the time it
//     runs. That is how admin.js lost `draw` to the map editor, which left the
//     fleet table calling the editor's canvas repaint and drawing no rows.
//   - `function f` in one and `let f` in the other is a SyntaxError, raised
//     when the second script is instantiated rather than when the name is
//     used. That file does not run at all: its functions never exist, so what
//     the page reports is some later call complaining it cannot see a
//     variable, which points nowhere near the collision. That is how the map
//     editor shipped dead, `function typing` against admin.js's `let typing`,
//     reported on the fleet as "Cannot access 'doc' before initialization".
//
// Sharing a scope is, for the purpose of declaring names, the same thing as
// being one file. So the first check compiles them as one file and lets the
// engine apply its own rule, which is stricter and more current than anything
// written here would be. Compiled, not run: a redeclaration is refused at
// parse, and neither file can execute without a DOM anyway.
//
// The second class the engine has no opinion about, so it is read off the
// sources. That reading is only sound because both files are written by hand
// with every top-level declaration in the first column, which is also what
// makes them worth reading.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

let fails = 0;
function check(name, ok, extra) {
  if (!ok) fails++;
  console.log(`${name.padEnd(56)} ${ok ? "ok" : `FAIL${extra ? ": " + extra : ""}`}`);
}

const dir = path.join(__dirname, "..");
// The order the page loads them in, which is the order the rule applies in.
const scripts = ["admin.js", "maps.js"];
const sources = scripts.map((n) => fs.readFileSync(path.join(dir, n), "utf8"));

let clash = null;
try {
  new vm.Script(sources.join("\n;\n"), { filename: "the panel" });
} catch (e) {
  clash = e.message;
}
check("the panel's scripts can share one scope", clash === null, clash);

// The silent kind. A function declared in both files leaves the first one's
// definition unreachable, with no complaint from anybody.
const owner = new Map();
for (let i = 0; i < scripts.length; i++) {
  for (const [, fn] of sources[i].matchAll(/^function\s+([A-Za-z_$][\w$]*)/gm)) {
    const had = owner.get(fn);
    if (had !== undefined && had !== scripts[i]) {
      check(`${scripts[i]} does not redeclare ${had}'s ${fn}`, false,
            `${scripts[i]} wins and ${had}'s is lost`);
    }
    owner.set(fn, scripts[i]);
  }
}
check("no function is declared by two of the panel's scripts", true);

console.log(fails === 0 ? "all ok" : `${fails} failed`);
process.exit(fails === 0 ? 0 : 1);
