// Exercise the link bridge from the shipping Defold page. The small DOM below
// records the same element operations a browser performs without copying the
// bridge into the test.

const fs = require("fs");

const source = fs.readFileSync("client/web/engine_template.html", "utf8");
const startMark = "// link-bridge-test:start";
const endMark = "// link-bridge-test:end";
const start = source.indexOf(startMark);
const end = source.indexOf(endMark);
if (start < 0 || end < start) {
  throw new Error("Link bridge test boundary is missing from engine_template.html");
}
const body = source.slice(start + startMark.length, end);

class Element {
  constructor(tag) {
    this.tag = tag;
    this.attributes = {};
    this.children = [];
    this.className = "";
    this.listeners = {};
    this.style = {};
    this._innerHTML = "";
  }

  addEventListener(name, callback) {
    this.listeners[name] = callback;
  }

  appendChild(child) {
    this.children.push(child);
  }

  querySelector(selector) {
    if (selector !== "a") return null;
    return this.children.find((child) => child.tag === "a") || null;
  }

  getBoundingClientRect() {
    return {left: 100, top: 50};
  }

  setAttribute(name, value) {
    this.attributes[name] = value;
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name)
      ? this.attributes[name] : null;
  }

  removeAttribute(name) {
    delete this.attributes[name];
  }

  set innerHTML(value) {
    this._innerHTML = value;
    if (value === "") this.children = [];
  }

  get innerHTML() {
    return this._innerHTML;
  }

  emit(name, event) {
    if (!this.listeners[name]) throw new Error("No " + name + " listener");
    return this.listeners[name](event || {});
  }
}

const linkBox = new Element("div");
const windowStub = {location: {hash: ""}, vwPointerOut: true};
const documentStub = {
  getElementById(id) {
    if (id !== "vw-link") throw new Error("Unexpected element " + id);
    return linkBox;
  },
  createElement(tag) {
    return new Element(tag);
  },
};
const navigatorStub = {};

Function("window", "document", "navigator", body)(
  windowStub, documentStub, navigatorStub);

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log("ok   " + name);
  } else {
    failures += 1;
    console.log("FAIL " + name + (detail ? ": " + detail : ""));
  }
}

async function main() {
  for (const route of ["join/melee", "watch/melee/zone-a/3", "replay/42"]) {
    windowStub.location.hash = "#/" + route;
    check("the game page accepts " + route.split("/")[0] + " routes",
      windowStub.vwRouteRead() === route, windowStub.vwRouteRead());
  }
  windowStub.location.hash = "#/settings";
  check("the game page rejects non-session routes",
    windowStub.vwRouteRead() === "", windowStub.vwRouteRead());

  const published = windowStub.vwLink(
    "10,20,30,40,https://example.test/room,one");
  const anchor = linkBox.querySelector("a");
  check("publishing creates the live anchor", published === "1" && anchor,
    published);
  check("the anchor carries its destination and safe target",
    anchor.href === "https://example.test/room,one"
      && anchor.target === "_blank"
      && anchor.rel === "noopener noreferrer",
    anchor && anchor.href);
  check("the published rectangle reaches the anchor",
    anchor.style.left === "10px" && anchor.style.top === "20px"
      && anchor.style.width === "30px" && anchor.style.height === "40px"
      && linkBox.className === "vw-up");

  windowStub.vwPointerOut = true;
  anchor.emit("mousemove", {clientX: 125, clientY: 82});
  check("moving over the anchor reports link-local coordinates",
    windowStub.vwLinkAt() === "25,32", windowStub.vwLinkAt());
  check("moving over the anchor keeps the game pointer live",
    windowStub.vwPointerOut === false);

  anchor.emit("mouseleave");
  check("leaving the anchor clears its reported position",
    windowStub.vwLinkAt() === "", windowStub.vwLinkAt());
  check("leaving the anchor retires the game pointer",
    windowStub.vwPointerOut === true);

  let shared = null;
  navigatorStub.share = (value) => {
    shared = value;
    return Promise.resolve();
  };
  windowStub.vwLink("11,21,31,41,vwshare:https://example.test/match/9");
  let prevented = false;
  anchor.emit("click", {preventDefault() { prevented = true; }});
  await new Promise((resolve) => setImmediate(resolve));
  check("a share link uses the native share sheet",
    prevented && shared && shared.title === "Vectorwake"
      && shared.url === "https://example.test/match/9"
      && windowStub.vwShareRead() === "shared",
    JSON.stringify(shared));
  check("reading the share result drains it", windowStub.vwShareRead() === "");

  const copied = [];
  navigatorStub.share = undefined;
  navigatorStub.clipboard = {
    writeText(value) {
      copied.push(value);
      return Promise.resolve();
    },
  };
  windowStub.vwLink("12,22,32,42,vwshare:https://example.test/match/10");
  anchor.emit("click", {preventDefault() {}});
  await new Promise((resolve) => setImmediate(resolve));
  check("sharing falls back to the clipboard",
    copied.length === 1 && copied[0] === "https://example.test/match/10"
      && windowStub.vwShareRead() === "copied",
    JSON.stringify(copied));

  windowStub.vwLink("");
  check("withdrawing the publication removes the anchor",
    linkBox.querySelector("a") === null && linkBox.className === "");

  if (failures > 0) process.exit(1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
