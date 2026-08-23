// Exercise the page-height function from the shipping Defold template. Keeping
// the function in the template means this test runs the same code as Safari.

const fs = require("fs");

const source = fs.readFileSync("client/web/engine_template.html", "utf8");
const appleStart = source.indexOf("// apple-test:start");
const appleEnd = source.indexOf("// apple-test:end");
if (appleStart < 0 || appleEnd < appleStart) {
  throw new Error("Apple device test boundary is missing from engine_template.html");
}
const appleBody = source.slice(
  appleStart + "// apple-test:start".length, appleEnd);
const apple = Function(appleBody + "\nreturn apple;")();

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

check("an iPhone is an Apple touch device",
  apple("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", 5), true);
check("a desktop-class iPad is an Apple touch device",
  apple("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 5), true);
check("a Mac with the same user agent is not an iPad",
  apple("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 0), false);
check("another touch desktop is not mistaken for an iPad",
  apple("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", 5), false);

if (failures > 0) process.exit(1);
