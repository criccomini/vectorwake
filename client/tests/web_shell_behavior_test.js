// Execute the shipping browser diagnostics and public result pages. The DOM
// stand-ins are built from the real HTML, so removing an element the scripts
// need fails at the same boundary as renaming or removing its behavior.

const fs = require("fs");
const vm = require("vm");

let failures = 0;
function check(name, ok, detail) {
  if (ok) {
    console.log("ok   " + name);
  } else {
    failures += 1;
    console.log("FAIL " + name + (detail ? ": " + detail : ""));
  }
}

function section(source, startMark, endMark) {
  const start = source.indexOf(startMark);
  const end = source.indexOf(endMark);
  if (start < 0 || end < start) {
    throw new Error("Missing test boundary " + startMark);
  }
  return source.slice(start + startMark.length, end);
}

async function settle(done) {
  for (let i = 0; i < 20; i += 1) {
    if (done && done()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
}

async function diagnosticsTest() {
  const source = fs.readFileSync("client/web/engine_template.html", "utf8");
  const body = section(source, "// diagnostics-test:start",
    "// diagnostics-test:end");
  const listeners = {};
  const posts = [];
  const quietConsole = {error() {}};
  const context = vm.createContext({
    window: {vwAccount: 27},
    location: {
      href: "https://play.vectorwake.net/join/melee",
      origin: "https://play.vectorwake.net",
      pathname: "/join/melee",
    },
    navigator: {userAgent: "Vectorwake test browser"},
    console: quietConsole,
    URL,
    fetch(url, options) {
      posts.push({url, options});
      return Promise.resolve({ok: true});
    },
    addEventListener(name, callback) {
      listeners[name] = listeners[name] || [];
      listeners[name].push(callback);
    },
  });
  vm.runInContext(body, context, {filename: "engine_template diagnostics"});

  const onError = listeners.error && listeners.error[0];
  check("the page installs its browser error listener", !!onError);
  if (!onError) return;

  const secret = "a".repeat(64);
  onError({message: "failed " + secret});
  onError({message: "failed " + secret});
  for (let i = 0; i < 10; i += 1) onError({message: "failure " + i});
  await settle(() => posts.length === 8);

  check("browser failures are deduplicated and capped at eight",
    posts.length === 8, String(posts.length));
  const first = posts[0] || {options: {}};
  const payload = first.options.body ? JSON.parse(first.options.body) : {};
  check("the browser reporter posts its public context",
    first.url === "/meta/v1/client-error"
      && first.options.method === "POST"
      && first.options.keepalive === true
      && payload.account === 27
      && payload.origin === "https://play.vectorwake.net"
      && payload.page === "/join/melee",
    JSON.stringify(payload));
  check("the browser reporter redacts long tokens",
    payload.message === "failed [redacted]", payload.message);
}

class PageNode {
  constructor(tag, attrs) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.dataset = {};
    this.hidden = Object.prototype.hasOwnProperty.call(attrs, "hidden");
    this.textContent = "";
    this.innerHTML = "";
    this.href = attrs.href || "";
    // A control's own value, which for the zone picker is the whole of what
    // the page reads back off it. Assigning `innerHTML` is how the options
    // are drawn, and a browser drops a value its list no longer offers; this
    // keeps whatever was set, which is enough to press the wrong zone and see
    // it refuse.
    this.value = "";
    this.listeners = {};
    // Nodes the page built and hung under this one. The profile draws its
    // per-zone table by appending cells to rows and rows to a tbody, so a
    // test that cannot see through that cannot see the table at all.
    this.children = [];
    this.own = "";
    this.className = attrs.class || "";
    this.classList = {
      toggle: (name, on) => {
        const held = this.className.split(/\s+/).filter(Boolean);
        const without = held.filter((held) => held !== name);
        if (on) without.push(name);
        this.className = without.join(" ");
      },
    };
    for (const [name, value] of Object.entries(attrs)) {
      if (!name.startsWith("data-")) continue;
      const key = name.slice(5).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
      this.dataset[key] = value === true ? "" : value;
    }
  }

  // Setting it replaces whatever was under the node, as the DOM does.
  set textContent(value) {
    this.own = String(value ?? "");
    this.children = [];
  }

  get textContent() {
    const below = this.children.map((child) => child.textContent).join(" ");
    return below ? (this.own ? this.own + " " + below : below) : this.own;
  }

  append(...nodes) {
    this.children.push(...nodes);
  }

  replaceChildren(...nodes) {
    this.children = nodes;
  }

  addEventListener(name, callback) {
    this.listeners[name] = callback;
  }

  emit(name) {
    if (!this.listeners[name]) throw new Error("No " + name + " listener");
    return this.listeners[name]({preventDefault() {}});
  }
}

function parseAttrs(text) {
  const out = {};
  const pattern = /([:\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
  let match;
  while ((match = pattern.exec(text))) {
    out[match[1]] = match[2] ?? match[3] ?? match[4] ?? true;
  }
  return out;
}

function pageDocument(path) {
  const html = fs.readFileSync(path, "utf8");
  const nodes = [];
  const tags = /<([a-z][\w-]*)([^>]*)>/gi;
  let match;
  while ((match = tags.exec(html))) {
    nodes.push(new PageNode(match[1], parseAttrs(match[2])));
  }
  const body = nodes.find((node) => node.tagName === "BODY");
  return {
    body,
    createElement(tag) {
      return new PageNode(tag, {});
    },
    querySelector(selector) {
      const attribute = /^\[([^\]]+)\]$/.exec(selector);
      if (attribute) {
        return nodes.find((node) =>
          Object.prototype.hasOwnProperty.call(node.attrs, attribute[1])) || null;
      }
      // An id, which is how the pilot pages reach their own elements. Only
      // the shipping HTML's ids resolve: a page that loses one gets null
      // here, which is the early return the script takes in a browser.
      const id = /^#([\w-]+)$/.exec(selector);
      if (id) return nodes.find((node) => node.attrs.id === id[1]) || null;
      throw new Error("Unsupported selector " + selector);
    },
  };
}

function response(ok, status, body) {
  return {ok, status, json: async () => body};
}

async function runGrowth(document, location, fetch, navigator) {
  const source = fs.readFileSync("deploy/site/growth.js", "utf8");
  const addresses = [];
  const context = vm.createContext({
    document,
    location,
    fetch,
    navigator,
    console,
    URLSearchParams,
    // The week's zone rides the address so a filtered board can be sent to
    // somebody. Recorded rather than applied: what matters is that the page
    // writes the zone it is showing, not that this stand-in navigates.
    history: {replaceState(_state, _title, url) { addresses.push(url); }},
    setTimeout(callback) { callback(); },
  });
  vm.runInContext(source, context, {filename: "deploy/site/growth.js"});
  await settle();
  return addresses;
}

async function matchPageTest() {
  const document = pageDocument("deploy/site/match.html");
  const calls = [];
  const payload = {
    zone: "melee",
    match: {
      map: "relay",
      room: 3,
      score: [5, 3],
      teams: ["Cyan", "Orange"],
      pilots: [
        {team: 0, name: "Aster 1", kills: 4, deaths: 1, assists: 2},
        {team: 1, name: "Rook 2", kills: 2, deaths: 3, assists: 0, bot: true},
      ],
    },
  };
  let attempt = 0;
  const fetch = async (path, options) => {
    calls.push({path, body: JSON.parse(options.body)});
    attempt += 1;
    if (attempt === 1) return response(false, 404, {error: "not ready"});
    return response(true, 200, payload);
  };
  const shares = [];
  const navigator = {
    share(value) {
      shares.push(value);
      return Promise.resolve();
    },
    clipboard: {writeText() { throw new Error("native share should win"); }},
  };
  const location = {
    pathname: "/match/42",
    href: "https://vectorwake.net/match/42",
  };
  await runGrowth(document, location, fetch, navigator);
  await settle(() => document.querySelector("[data-replay]").href !== "");

  check("the match page retries a result that has not landed",
    calls.length === 2 && calls.every((call) =>
      call.path === "/v1/match" && call.body.id === 42),
    JSON.stringify(calls));
  check("the match page renders the returned score and roster",
    document.querySelector("[data-title]").textContent === "Cyan took it."
      && document.querySelector("[data-score]").hidden === false
      && document.querySelector("[data-score]").innerHTML.includes("5")
      && document.querySelector("[data-grid]").innerHTML.includes("Aster 1")
      && document.querySelector("[data-actions]").hidden === false);
  check("the match page links its deterministic film",
    document.querySelector("[data-replay]").href ===
      "https://play.vectorwake.net/#replay/42",
    document.querySelector("[data-replay]").href);

  const share = document.querySelector("[data-share]");
  await share.emit("click");
  check("the match page uses the native share sheet",
    shares.length === 1
      && shares[0].title === "Vectorwake match result"
      && shares[0].url === location.href
      && share.textContent === "Shared",
    JSON.stringify(shares));
}

async function weekPageTest() {
  const document = pageDocument("deploy/site/week.html");
  const calls = [];
  // Every zone the fleet runs, which is what the picker is built from. The
  // two whose key is not their name are the ones a page that printed keys
  // would get wrong.
  const zones = [
    {zone: "melee", label: "Team Battle"},
    {zone: "turf", label: "Turf"},
    {zone: "roam", label: "Free Roam"},
  ];
  const fetch = async (path, options) => {
    const body = JSON.parse(options.body);
    calls.push({path, body});
    return response(true, 200, {
      since: "2026-08-17",
      zone: body.zone || "",
      label: (zones.find((z) => z.zone === body.zone) || {}).label || "",
      zones,
      week: body.zone === "turf" ? [
        {name: "Rook 2", kills: 4, deaths: 5, rating: 1480,
         swing: -6, wins: 3, seconds: 180},
      ] : [
        {name: "Aster 1", kills: 9, deaths: 2, rating: 1510,
         swing: 14, wins: 1, seconds: 720},
        {name: "Rook 2", kills: 4, deaths: 5, rating: 1480,
         swing: -6, wins: 3, seconds: 180},
      ],
    });
  };
  const copied = [];
  const navigator = {
    clipboard: {
      writeText(value) {
        copied.push(value);
        return Promise.resolve();
      },
    },
  };
  const location = {
    pathname: "/week",
    search: "",
    href: "https://vectorwake.net/week",
  };
  const addresses = await runGrowth(document, location, fetch, navigator);
  await settle(() => document.querySelector("[data-rows]").innerHTML !== "");

  check("the weekly page requests the current recap",
    calls.length === 1 && calls[0].path === "/v1/week"
      && calls[0].body.back === 0 && calls[0].body.zone === "",
    JSON.stringify(calls));
  check("the weekly page renders stories and standings",
    document.querySelector("[data-stories]").hidden === false
      && document.querySelector("[data-stories]").innerHTML.includes("top gun")
      && document.querySelector("[data-stories]").innerHTML.includes("Rook 2")
      && document.querySelector("[data-ladder]").hidden === false
      && document.querySelector("[data-rows]").innerHTML.includes("Aster 1"));

  // A rating is kept per zone, so the board offers one game at a time. The
  // picker is drawn from the reply, which is what lets a zone added to the
  // catalog reach this page without an edit here.
  const picker = document.querySelector("[data-zone]");
  check("the weekly page offers every zone by the name players read",
    document.querySelector("[data-zone-filter]").hidden === false
      && picker.innerHTML.includes("Every zone")
      && picker.innerHTML.includes(">Team Battle<")
      && picker.innerHTML.includes(">Free Roam<")
      && picker.innerHTML.includes("value=\"melee\""),
    picker.innerHTML);

  picker.value = "turf";
  await picker.emit("change");
  await settle(() =>
    document.querySelector("[data-status]").textContent.includes("Turf"));
  check("choosing a zone reads the board again for that zone alone",
    calls.length === 2 && calls[1].body.zone === "turf",
    JSON.stringify(calls));
  check("and the board redraws as that zone's",
    document.querySelector("[data-rows]").innerHTML.includes("Rook 2")
      && !document.querySelector("[data-rows]").innerHTML.includes("Aster 1")
      && document.querySelector("[data-status]").textContent.includes("Turf"),
    document.querySelector("[data-status]").textContent);
  check("and the zone rides the address so the board can be linked",
    addresses.length === 1 && addresses[0] === "/week?zone=turf",
    JSON.stringify(addresses));

  const share = document.querySelector("[data-share]");
  await share.emit("click");
  check("the weekly page falls back to copying its link",
    copied.length === 1 && copied[0] === location.href
      && share.textContent === "Link copied",
    JSON.stringify(copied));
}

// A pilot's profile, which is the one page that shows what a rating actually
// is: one per zone, and no total over them.
async function profilePageTest() {
  const document = pageDocument("deploy/site/pilot.html");
  const payload = {
    pilot: {
      account: 12, name: "Aster 1", kind: "human",
      kills: 240, deaths: 180, assists: 96,
      ratings: [
        {zone: "Team Battle", class: "melee", rating: 1612.4,
         games: 140, tier: "Ace", rank: 3, of: 90},
        {zone: "Free Roam", class: "roam", rating: 1488.7,
         games: 20, tier: "Wing", rank: 41, of: 90},
        // Placing: enough games to be listed, not enough to be told a tier.
        {zone: "Duel", class: "duel", rating: 1502.0,
         games: 2, tier: null, rank: null, of: null},
      ],
    },
  };
  const calls = [];
  const fetch = async (path, options) => {
    calls.push({path, body: JSON.parse(options.body)});
    return response(true, 200, payload);
  };
  const location = {
    pathname: "/pilots/12",
    search: "",
    href: "https://vectorwake.net/pilots/12",
  };
  const source = fs.readFileSync("deploy/site/pilots.js", "utf8");
  const context = vm.createContext({
    document, fetch, console, Intl, URLSearchParams,
    window: {location, history: {replaceState() {}}},
  });
  vm.runInContext(source, context, {filename: "deploy/site/pilots.js"});
  await settle(() =>
    document.querySelector("#profile-rating-rows").children.length > 0);

  check("the profile asks for the pilot named by its address",
    calls.length === 1 && calls[0].path === "/v1/pilot"
      && calls[0].body.account === 12,
    JSON.stringify(calls));

  // The whole point of the table: a row per zone, named as players name it.
  // "melee" and "roam" are keys, and a page that printed them would be
  // naming two games that go by other names on every other screen.
  const rows = document.querySelector("#profile-rating-rows").children;
  check("the profile lists a rating for every zone the pilot has flown",
    rows.length === 3
      && rows[0].textContent.includes("Team Battle")
      && rows[1].textContent.includes("Free Roam")
      && rows[2].textContent.includes("Duel")
      && !rows[0].textContent.includes("Overall"),
    rows.map((row) => row.textContent).join(" | "));
  check("and each row carries that zone's own tier and rank",
    rows[0].textContent.includes("Ace")
      && rows[0].textContent.includes("#3")
      && rows[1].textContent.includes("Wing")
      && rows[2].textContent.includes("Placing")
      && rows[2].textContent.includes("Not ranked"),
    rows.map((row) => row.textContent).join(" | "));
  check("and the table is shown rather than left hidden",
    document.querySelector("#profile-ratings").hidden === false
      && document.querySelector("#profile-scoreboard").hidden === false);

  // The headline is the most-flown zone, not a career: there is no number
  // over every zone and the page must not read as if there were.
  check("the profile's headline figures come from the most-flown zone",
    document.querySelector("#profile-tier").textContent === "Ace"
      && document.querySelector("#profile-rank").textContent === "#3"
      && document.querySelector("#profile-games").textContent === "140",
    document.querySelector("#profile-tier").textContent);
  check("and it says which zone they are from",
    document.querySelector("#profile-zone-note").hidden === false
      && document.querySelector("#profile-zone-note").textContent
        .includes("Team Battle"),
    document.querySelector("#profile-zone-note").textContent);
}

// The canvas has to own every gesture that lands on it.
//
// Without `touch-action: none` the browser treats a thumb drag as a candidate
// scroll or pinch, and the touch events it passes on while it is making up its
// mind are non-cancelable: the client's preventDefault is refused. Nothing
// visibly scrolls, because the body is fixed, so the only symptom is a console
// error and touch handling that is subtly not the client's own. It shipped
// that way until a harness flew the game with a thumb.
function canvasGesturesTest() {
  const source = fs.readFileSync("client/web/engine_template.html", "utf8");
  const rule = source.slice(source.indexOf("#canvas {"));
  const body = rule.slice(0, rule.indexOf("}"));
  check("the canvas takes every gesture itself",
    /touch-action:\s*none/.test(body), body);
  check("and refuses the overscroll the browser would add",
    /overscroll-behavior:\s*none/.test(body), body);
}

(async () => {
  canvasGesturesTest();
  await diagnosticsTest();
  await matchPageTest();
  await weekPageTest();
  await profilePageTest();
  if (failures > 0) process.exit(1);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
