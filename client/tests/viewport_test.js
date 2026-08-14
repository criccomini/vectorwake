// Exercise the page-height function from the shipping Defold template. Keeping
// the function in the template means this test runs the same code as Safari.

const fs = require("fs");

const source = fs.readFileSync("client/web/engine_template.html", "utf8");
const start = source.indexOf("// viewport-test:start");
const end = source.indexOf("// viewport-test:end");
if (start < 0 || end < start) {
  throw new Error("viewport test boundary is missing from engine_template.html");
}
const body = source.slice(start + "// viewport-test:start".length, end);
const pageHeight = Function(body + "\nreturn vwPageHeight;")();

let failures = 0;
function check(name, got, want) {
  if (got === want) {
    console.log("ok   " + name);
  } else {
    failures += 1;
    console.log("FAIL " + name + ": got " + got + ", wanted " + want);
  }
}

// extended, standalone, width, visible, layout, inner, outer, large,
// screen width, screen height
check("an installed portrait app reaches the physical bottom",
  pageHeight(true, true, 402, 812, 812, 812, 812, 874, 402, 874), 874);
check("landscape rejects measurements left over from portrait",
  pageHeight(true, true, 874, 390, 812, 390, 874, 812, 402, 874), 402);
check("a landscape Safari tab still reaches behind its toolbar",
  pageHeight(true, false, 874, 330, 330, 330, 812, 390, 402, 874), 390);
check("a focused input stays inside the visual viewport",
  pageHeight(false, true, 874, 330, 812, 812, 874, 812, 402, 874), 330);

if (failures > 0) process.exit(1);
