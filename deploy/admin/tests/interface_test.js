// Run the shipping admin scripts together and prove that maps.js installs its
// redraw through admin.js's public interface. The DOM only supplies the small
// surface reached while the logged-out panel boots and an empty map list draws.

const fs = require("fs");
const vm = require("vm");

class Element {
  constructor(id = "") {
    this.id = id;
    this.children = [];
    this.classList = {add() {}, remove() {}, toggle() {}};
    this.dataset = {};
    this.hidden = false;
    this.style = {};
    this.textContent = "";
  }

  addEventListener() {}
  append(...children) { this.children.push(...children); }
  appendChild(child) { this.children.push(child); return child; }
  focus() {}
  querySelector() { return new Element(); }
  querySelectorAll() { return []; }
  remove() {}
  replaceChildren(...children) { this.children = children; }
  scrollIntoView() {}
}

const elements = new Map();
const documentStub = {
  addEventListener() {},
  createElement(tag) { return new Element(tag); },
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  },
  querySelectorAll() { return []; },
};

const calls = [];
const windowStub = {
  addEventListener() {},
  location: {hash: ""},
};
const context = vm.createContext({
  Node: Element,
  addEventListener() {},
  clearInterval() {},
  console,
  document: documentStub,
  fetch: async (path) => {
    calls.push(path);
    return {
      ok: true,
      status: 200,
      json: async () => ({maps: [], rotations: [], zones: []}),
    };
  },
  localStorage: {
    getItem() { return null; },
    removeItem() {},
    setItem() {},
  },
  location: windowStub.location,
  setInterval() { return 1; },
  window: windowStub,
});

function run(path) {
  vm.runInContext(fs.readFileSync(path, "utf8"), context, {filename: path});
}

run("deploy/admin/admin.js");
const api = windowStub.vectorwakeAdmin;
if (!api || !Object.isFrozen(api)) {
  throw new Error("admin.js did not publish its frozen helper interface");
}
for (const name of ["post", "el", "tell", "fill", "ask", "installMaps", "drawMaps"]) {
  if (typeof api[name] !== "function") {
    throw new Error(`the admin interface is missing ${name}`);
  }
}

let placeholderCalls = 0;
api.installMaps(async () => { placeholderCalls += 1; });

(async () => {
  await api.drawMaps();
  if (placeholderCalls !== 1) throw new Error("the redraw delegate does not call its install");

  // maps.js skips DOM wiring under Node, but its browser registration still
  // consumes the real interface produced above.
  delete context.document;
  run("deploy/admin/maps.js");
  context.document = documentStub;

  calls.length = 0;
  await api.drawMaps();
  if (placeholderCalls !== 1) {
    throw new Error("maps.js did not replace the placeholder redraw");
  }
  if (calls.length !== 1 || calls[0] !== "/v1/admin/maps") {
    throw new Error(`the installed redraw made the wrong request: ${calls.join(", ")}`);
  }
  console.log("admin script interface test passes");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
