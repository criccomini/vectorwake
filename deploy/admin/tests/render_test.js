// Run the shipping admin script against a small authenticated panel and prove
// that the fleet, browser error, and rollback rows render their live reply
// shapes. These contracts used to be guarded by source-string checks.

const fs = require("fs");
const vm = require("vm");

class Element {
  constructor(id = "", tag = "div") {
    this.id = id;
    this.tag = tag;
    this.children = [];
    this._text = "";
    this.classList = {add() {}, remove() {}, toggle() {}};
    this.dataset = {};
    this.hidden = false;
    this.style = {};
    this.value = "";
    this.checked = false;
    this.disabled = false;
  }

  get textContent() {
    return this._text + this.children.map((child) =>
      child instanceof Element ? child.textContent : String(child)).join("");
  }

  set textContent(value) {
    this._text = String(value);
    this.children = [];
  }

  addEventListener() {}
  append(...children) {
    for (const child of children) {
      if (child instanceof Element) child.parentElement = this;
      this.children.push(child);
    }
  }
  appendChild(child) { this.append(child); return child; }
  focus() {}
  querySelector(selector) {
    if (selector === "tbody") {
      if (!this.body) this.body = new Element(`${this.id}-body`, "tbody");
      return this.body;
    }
    return new Element();
  }
  querySelectorAll(selector) {
    if (selector === "button") {
      if (!this.buttons) this.buttons = [new Element("", "button"), new Element("", "button")];
      return this.buttons;
    }
    return [];
  }
  removeAttribute() {}
  replaceChildren(...children) { this.children = []; this.append(...children); }
  setAttribute() {}
  showModal() {}
}

const elements = new Map();
const documentStub = {
  createDocumentFragment() { return new Element("", "fragment"); },
  createElement(tag) { return new Element("", tag); },
  createTextNode(value) { const node = new Element("", "text"); node.textContent = value; return node; },
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  },
  querySelectorAll() { return []; },
};

const replies = {
  "/v1/session": {admin: true, name: "operator"},
  "/v1/admin/fleet": {
    instances: [{
      instance: "arena-1", zone: "melee", region: "sea", verified: true,
      age_ms: 0, tick_us: 100, queue_depth: 0, lag_actions: 0,
      players: 0, bots: 1, rooms: [], max_rooms: 4,
      bw_per_player: 0, snapshot_bytes: 0, build: "abcdef1",
    }],
    audit: [], build: "abcdef1", directory_build: "abcdef1",
    catalog_version: 7, key_agrees: true,
  },
  "/v1/admin/recent": {events: [], newest: {}, offset: 0, more: false},
  "/v1/admin/errors": {
    errors: [{
      account: 7, kind: "TypeError", message: "broken", stack: "",
      first_at: "2026-08-23 12:00:00", last_at: "2026-08-23 12:00:01",
      user_agent: "test", origin: "https://play.vectorwake.net", page: "/",
      build: "abcdef1", occurrences: 3,
    }],
    groups_1h: 1, groups_24h: 1, groups: 1, occurrences: 3,
    offset: 0, more: false,
  },
  "/v1/admin/debug": {
    debug: [{
      account: 7, at: "2026-08-23 12:00:00", user_agent: "test",
      zone: "melee", room: 2, wire: "ws", build: "abcdef1",
      correction_px: 1.25, snapshot_tick: 50, client_tick: 49,
      predicted_x: 10, predicted_y: 20, reconciled_x: 11, reconciled_y: 21,
      snapshot_seq: 8, predicted_vx: 1, predicted_vy: 2,
      reconciled_vx: 0.5, reconciled_vy: 1.5,
      local_debt_px: 0.25, local_debt_deg: 0.5,
      repel_before_ticks: 4, repel_before_speed: 2,
      repel_after_ticks: 2, repel_after_speed: 1,
      frame_ms: 8.3, snapshot_gap_ms: 16.7, clock_adjust: 2,
      input_ack: 40, input_margin: 3, input_lead: 2, input_holes: 0,
    }],
    offset: 0, more: false,
  },
  "/v1/admin/pilots": {
    pilots: [], total: 0, offset: 0, more: false,
    provisional: 10, default_class: "skirmisher",
  },
  "/v1/admin/bans": {bans: []},
  "/v1/admin/admins": {admins: []},
};

const calls = [];
const windowStub = {location: {hash: ""}};
const context = vm.createContext({
  Node: Element,
  addEventListener() {},
  clearInterval() {},
  clearTimeout() {},
  console,
  document: documentStub,
  fetch: async (path) => {
    calls.push(path);
    const reply = replies[path];
    if (!reply) throw new Error(`unexpected request ${path}`);
    return {ok: true, status: 200, json: async () => reply};
  },
  localStorage: {
    getItem() { return "secret"; },
    removeItem() {},
    setItem() {},
  },
  location: windowStub.location,
  setInterval() { return 1; },
  setTimeout(fn) { return fn(); },
  window: windowStub,
});

vm.runInContext(fs.readFileSync("deploy/admin/admin.js", "utf8"), context,
                {filename: "deploy/admin/admin.js"});

setImmediate(() => {
  const fleet = elements.get("fleet").querySelector("tbody").textContent;
  const errors = elements.get("errors").querySelector("tbody").textContent;
  const debug = elements.get("debug").querySelector("tbody").textContent;

  if (!fleet.includes("0 B/s")) {
    throw new Error(`zero bandwidth disappeared from the fleet row: ${fleet}`);
  }
  if (!errors.includes("#7") || !errors.includes("TypeError: broken")) {
    throw new Error(`the browser error row lost its account or detail: ${errors}`);
  }
  for (const text of [
    "1.3 px at ticks 50 server / 49 client",
    "local debt 0.25 px / 0.50 deg",
    "repel 4 ticks at 2.00 px/tick, then 2 ticks at 1.00 px/tick",
    "snapshots 16.7 ms; clock +2",
  ]) {
    if (!debug.includes(text)) throw new Error(`the rollback row lost: ${text}`);
  }
  for (const path of ["/v1/admin/fleet", "/v1/admin/errors", "/v1/admin/debug"]) {
    if (!calls.includes(path)) throw new Error(`authenticated refresh skipped ${path}`);
  }
  console.log("admin rendering test passes");
});
