// The panel's whole brain. Talks to the meta-layer through the /v1 proxy on
// this origin, holds one device secret in localStorage, and treats the
// `admin` field a session reply carries as decoration: every action posts
// the secret and the server re-checks the flag, so nothing this file decides
// is load-bearing. docs/architecture/admin.md is the design.
//
// Server text goes into the page through textContent, never through
// innerHTML. Ban reasons are operator-typed free text, and the CSP upstream
// is the second lock on that door, not the first.

(() => {
"use strict";

const KEY = "vw-admin-secret";

const el = (id) => document.getElementById(id);
const login = el("login"), panel = el("panel");

let secret = localStorage.getItem(KEY) || "";
// The pilot the lookup found, so the ban button knows its target and sense.
let shown = null;
// Which pilot the activity table is drawn for, so looking the same one up
// again after a rename or a ban keeps the stay an operator was reading, and
// which stay that is. Null means their whole history.
let shownWas = null;
let stay = null;

async function post(path, body) {
  let r;
  try {
    r = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error("cannot reach the meta-layer");
  }
  const reply = await r.json().catch(() => ({}));
  if (!r.ok) {
    // The flag is checked per action, so a revoked operator finds out on
    // their next click. Put them back at the door rather than leaving a
    // panel that draws buttons and refuses all of them.
    if (r.status === 403 && path.startsWith("/v1/admin")) eject(reply.error);
    throw new Error(reply.error || `the server said ${r.status}`);
  }
  return reply;
}

// Say something in one of the note lines. `kind` is "ok" for something that
// worked and "plain" for something in progress; a refusal is the default and
// needs no argument.
function tell(id, text, kind) {
  const n = el(id);
  n.textContent = text;
  n.classList.toggle("ok", kind === "ok");
  n.classList.toggle("plain", kind === "plain");
}

function show(section) {
  login.hidden = section !== login;
  panel.hidden = section !== panel;
  // Who you are belongs in the header, which is outside both sections, so it
  // is shown and hidden with them rather than by them. The rail goes the same
  // way: links to places you cannot reach are worse than no links.
  el("who-line").hidden = section !== panel;
  el("rail").hidden = section !== panel;
}

// -------------------------------------------------------------- paging

// How many rows a page of a table is. One number for every paged list, because a
// screen holds about this many of any of them and an operator who has learned
// what `next` costs on one table should not relearn it on the next.
const PAGE = 25;

// Which page each table is on, by the name its pager and note line use. Reset
// to zero whenever what is being paged changes, since page four of a filter
// nobody typed yet is an empty table and a puzzle.
const pages = { pilots: 0, recent: 0, errors: 0, debug: 0, events: 0 };

// Draw one table's footer: which rows these are, out of how many, and whether
// the two controls can go anywhere.
//
// `total` when the server counted, and `more` when it did not. The pilot table
// is bounded by how many people have ever played, so counting it is an index
// scan and worth it; the event log takes most of 300,000 rows a day, so it
// answers "is there another page" with one extra row instead. The footer reads
// the same either way, which is the point of doing it here.
function pager(name, { empty, noun, shown, from, total, more, paged = true }) {
  const box = el(`${name}-pager`);
  const [prev, next] = box.querySelectorAll("button");

  // A meta-layer too old to page ignores `limit` and `offset` and answers with
  // the whole list, so the controls have to go: `next` would move a number
  // nothing acts on and the footer would count rows off the end of a list that
  // was never sliced. That is what "pilots 1 to 72" then "pilots 26 to 98" on
  // an unchanged table of 72 was, and it is a deploy race rather than a bug in
  // either half. The page detects it the same way it detects everything else
  // the server may not send: by whether the field came back at all.
  if (!paged) {
    prev.hidden = true;
    next.hidden = true;
    el(name === "pilots" ? "pilots-note" : `${name}-range`).textContent =
      shown ? `${shown} ${noun}${shown === 1 ? "" : "s"}` : empty;
    return;
  }

  prev.disabled = from === 0;
  next.disabled = !more;
  // The controls go when a list fits on one page, because two dead buttons
  // say nothing. The line between them stays: it is where the count goes and,
  // for the pilot table, where `paint` writes a draw that failed, so hiding
  // the box would take the error report with it.
  const alone = from === 0 && !more;
  prev.hidden = alone;
  next.hidden = alone;

  const line = el(name === "pilots" ? "pilots-note" : `${name}-range`);
  if (!shown) {
    line.textContent = from === 0 ? empty : "nothing on this page";
    return;
  }
  const of = total == null ? "" : ` of ${total}`;
  const s = total === 1 || (total == null && shown === 1) ? "" : "s";
  line.textContent = shown === 1 && !of
    ? `${noun} ${from + 1}`
    : `${noun}${s} ${from + 1} to ${from + shown}${of}`;
}

// Both controls on every pager, wired once. `data-step` says which way, and
// the table redraws from the server rather than from anything held here: a
// page of a list that is still moving should be the page as it is now.
for (const [name, redraw] of [
  ["pilots", () => drawPilots(el("lookup-q").value.trim())],
  ["recent", () => drawRecent()],
  ["errors", () => drawErrors()],
  ["debug", () => drawDebug()],
  ["events", () => drawEvents()],
]) {
  for (const b of document.querySelectorAll(`#${name}-pager button`)) {
    b.addEventListener("click", () => {
      pages[name] = Math.max(0, pages[name] + Number(b.dataset.step));
      paint(name === "events" ? "activity" : name, redraw);
    });
  }
}

// ----------------------------------------------------------------- routing

// Six main views, one at a time, chosen by the hash.
//
// The hash rather than six documents. Each would re-check the flag, re-fetch
// everything and repeat the CSP, for navigation between parts of one session;
// and the panel is served as static files from a directory, so a path per view
// would need a rewrite rule in Caddy to survive a reload. A hash is still
// somewhere you can bookmark, still what the back button walks, and costs
// none of that.
const VIEWS = ["fleet", "pilots", "activity", "errors", "debug", "maps", "access", "pilot"];

// The rail holds the main views; `pilot` is reached by link rather than
// by nav, because there is no such thing as "the pilot page" until you have
// picked one.
const RAILED = VIEWS.filter((view) => view !== "pilot");

// Who the pilot view is currently showing, so a redraw after a rename or a ban
// knows which account to ask for again.
let onPilot = null;

// maps.js loads after this file and installs its redraw through the explicit
// panel interface. Keeping the delegate here lets the admin refresh loop call
// it without putting either script's local names back in global scope.
let mapsDraw = () => Promise.reject(new Error("the map editor did not load"));
function installMaps(draw) {
  if (typeof draw !== "function") throw new TypeError("a map redraw must be a function");
  mapsDraw = draw;
}
function drawMaps() { return mapsDraw(); }

function route() {
  // `#pilot/123` is the only route with an argument, and the account is the
  // whole of it. Anything unrecognised falls to the fleet rather than to a
  // blank page.
  const raw = location.hash.replace(/^#/, "");
  const [head, arg] = raw.split("/");
  const view = VIEWS.includes(head) ? head : VIEWS[0];
  onPilot = view === "pilot" ? Number(arg) || null : null;

  for (const v of VIEWS) el(`view-${v}`).hidden = v !== view;
  for (const v of RAILED) {
    const link = el(`nav-${v}`);
    // `aria-current` rather than a class, because "this is the one you are on"
    // is what it means, and the stylesheet can hang off it just as well. The
    // pilot page marks Pilots, since that is where it came from and an
    // unmarked rail reads as a page outside the panel.
    if (v === view || (view === "pilot" && v === "pilots")) {
      link.setAttribute("aria-current", "page");
    } else {
      link.removeAttribute("aria-current");
    }
  }
  return view;
}

// A hash the page did not put there is a click on a link or the back button,
// and both mean draw that view now rather than at the next refresh.
addEventListener("hashchange", () => {
  const view = route();
  if (panel.hidden) return;
  if (view === "activity") paint("recent", drawRecent);
  if (view === "errors") paint("errors", drawErrors);
  if (view === "debug") paint("debug", drawDebug);
  if (view === "pilots") paint("pilots", () => drawPilots(el("lookup-q").value.trim()));
  if (view === "access") { paint("bans", drawBans); paint("admins", drawAdmins); }
  // maps.js installs this delegate after this file loads. By the time a hash
  // can change, the editor has registered its redraw.
  if (view === "maps") paint("maps", drawMaps);
  if (view === "pilot") paint("pilot", () => lookup(`#${onPilot}`));
});

// A call sign, anywhere on this panel, pointing at that pilot's page.
//
// One function because a person is named in six places: the pilot table, the
// activity feed, a pilot's own history, the ban list, the admin list and client
// errors. Before it, some were buttons that opened a card and others were plain
// text that did nothing. A real link is middle clickable, has an address you
// can send somebody, and needs no handler.
function pilotLink(account, name) {
  const text = name || (account ? `#${account}` : "(none)");
  if (!account) return text;
  const a = document.createElement("a");
  a.href = `#pilot/${account}`;
  a.className = "pick";
  a.textContent = text;
  return a;
}

// ------------------------------------------------------------------ sign in

// How often the fleet redraws while somebody is looking at it. An arena
// pushes status every five seconds, so asking faster would draw the same
// numbers again.
const FLEET_REFRESH_MS = 5000;
let ticking = null;
let pulsing = null;
// Who wrote what is in the fleet note. The refresh clears its own messages
// and leaves a command's alone, because a redraw arriving a second after a
// click used to wipe the only confirmation the click produced.
let noteOwner = null;

// Where each table says what went wrong. One entry per table, so a table
// added later without a note line fails this lookup loudly here rather than
// quietly on screen.
const NOTES = {
  fleet: "fleet-note",
  maps: "maps-note",
  pilot: "lookup-note",
  recent: "recent-note",
  pilots: "pilots-note",
  bans: "bans-note",
  admins: "admins-note",
  activity: "activity-note",
  errors: "errors-note",
  debug: "debug-note",
};

// Draw a table, and say so when it cannot be drawn.
//
// Every draw is started from a timer, a refresh or a keystroke, none of which
// has anywhere to put a rejection, so each call used to end in
// `.catch(() => {})`. That swallowed a failed render whole: the previous rows
// stayed on screen and the count under them still agreed with them, so a
// table that had stopped updating read exactly like a table with nothing new
// to say. Injecting one malformed row reproduced it in a second, and the same
// class of failure had already cost an hour twice, once on the fleet table
// and once on this one.
//
// The likeliest cause is the page being newer than the meta-layer, which
// happens on every deploy: these files ship from the checkout inside a minute
// and the binary ships as an image once CI has built it. So the message says
// that rather than only naming the exception, and it says the rows are old,
// because a half-written table is worse than an empty one and both are worse
// than either with a line under it.
function paint(name, run) {
  return run().catch((e) => {
    tell(NOTES[name], `cannot draw this: ${e.message}. The rows above may be out of date. If a deploy just landed, the page is ahead of the server and it will agree again shortly.`);
    // The fleet note is shared with the command confirmations, so a redraw
    // has to know whose message it is about to clear.
    if (name === "fleet") noteOwner = "fleet";
  });
}

async function arrive(name) {
  el("who").textContent = name;
  show(panel);
  route();
  refresh();
  // The fleet and the feed are the two that move on their own. Bans and
  // admins change when an operator changes them, and this page is where that
  // happens.
  if (!ticking) ticking = setInterval(() => paint("fleet", drawFleet), FLEET_REFRESH_MS);
  if (!pulsing) pulsing = setInterval(() => paint("recent", drawRecent), RECENT_REFRESH_MS);
}

function refresh() {
  paint("fleet", drawFleet);
  paint("recent", drawRecent);
  paint("errors", drawErrors);
  paint("debug", drawDebug);
  paint("pilots", () => drawPilots(el("lookup-q").value.trim()));
  paint("bans", drawBans);
  paint("admins", drawAdmins);
  paint("maps", drawMaps);
}

async function boot() {
  if (!secret) { show(login); return; }
  try {
    const s = await post("/v1/session", { secret });
    if (!s.admin) {
      localStorage.removeItem(KEY);
      secret = "";
      tell("login-note", "that account no longer holds the admin flag");
      show(login);
      return;
    }
    arrive(s.name);
  } catch (e) {
    // A dead secret is forgotten; a dead meta-layer is not the secret's fault.
    if (!String(e.message).includes("reach")) {
      localStorage.removeItem(KEY);
      secret = "";
    }
    tell("login-note", e.message);
    show(login);
  }
}

el("login-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const note = el("login-note");
  tell("login-note", "signing in.", "plain");
  try {
    const got = await post("/v1/login", {
      name: el("login-name").value.trim(),
      password: el("login-password").value,
    });
    const s = await post("/v1/session", { secret: got.secret });
    if (!s.admin) {
      // A real pilot, but not an operator. The secret is not kept: this
      // page has no business holding a game credential it cannot use.
      tell("login-note", "that account does not hold the admin flag");
      return;
    }
    secret = got.secret;
    localStorage.setItem(KEY, secret);
    el("login-password").value = "";
    tell("login-note", "");
    arrive(s.name);
  } catch (e) {
    tell(note.id, e.message);
  }
});

// Back to the door, with the reason if there is one. Signing out and being
// turned away are the same teardown, so they are the same function.
function eject(why) {
  localStorage.removeItem(KEY);
  secret = "";
  shown = null;
  if (ticking) { clearInterval(ticking); ticking = null; }
  if (pulsing) { clearInterval(pulsing); pulsing = null; }
  el("pilot-card").hidden = true;
  el("activity").hidden = true;
  el("activity-none").hidden = false;
  shownWas = null;
  stay = null;
  tell("login-note", why || "");
  show(login);
}

el("logout").addEventListener("click", () => eject(""));

// -------------------------------------------------------------------- fleet

// Fill a tbody from rows of cells. Every value goes in as text, which is the
// rule this page keeps everywhere: server strings are data, never markup. A
// cell may also be a node, which is how the action buttons get in.
//
// Each cell carries its column's name in `data-label`. On a wide screen that
// is unused; below the card breakpoint the stylesheet draws it beside the
// value, which is what lets a phone read the same facts in the same words
// instead of a squeezed table.
function fill(table, rows) {
  const t = el(table);
  const heads = [...t.querySelectorAll("thead th")].map((th) => th.textContent.trim());
  const body = t.querySelector("tbody");
  body.textContent = "";
  for (const cells of rows) {
    const tr = document.createElement("tr");
    cells.forEach((c, i) => {
      const td = document.createElement("td");
      const v = Array.isArray(c) ? c[0] : c;
      if (v instanceof Node) td.append(v);
      else td.textContent = v;
      if (Array.isArray(c) && c[1]) td.className = c[1];
      if (heads[i]) td.dataset.label = heads[i];
      tr.append(td);
    });
    body.append(tr);
  }
  return body;
}

// -------------------------------------------------------------------- asking

// One dialog, used for both questions this page asks. Native `<dialog>`
// rather than confirm() and prompt(): those cannot be drawn to the game's art
// direction, some browsers suppress them outright, and showModal() brings the
// focus trap and the escape key with it for nothing.
//
// Resolves to the typed string, "" for a plain confirm, or null for a refusal,
// so a caller can treat null as "they said no" whichever kind it asked.
function ask({ title, body, ok, label, value }) {
  const dlg = el("ask");
  el("ask-title").textContent = title;
  el("ask-body").textContent = body;
  el("ask-ok").textContent = ok || "confirm";
  const field = el("ask-field");
  const input = el("ask-input");
  field.hidden = !label;
  if (label) {
    el("ask-label").textContent = label;
    input.value = value || "";
  }
  return new Promise((resolve) => {
    dlg.addEventListener("close", () => {
      resolve(dlg.returnValue === "ok" ? (label ? input.value.trim() : "") : null);
    }, { once: true });
    dlg.showModal();
    // The field if there is one, so a keyboard can answer without reaching
    // for the mouse; otherwise the confirming button.
    (label ? input : el("ask-ok")).focus();
  });
}

// ------------------------------------------------------------------ commands

// Send a verb to an instance, or to every instance when `instance` is "*".
// The answer says only that it went: the arena's outcome arrives at the
// directory a moment later and shows up in the log below.
async function command(instance, verb, args) {
  noteOwner = "command";
  try {
    const r = await post("/v1/admin/command", { secret, instance, verb, args });
    tell("fleet-note", `${verb} sent to ${r.sent} instance(s); the log has the outcome`, "ok");
  } catch (e) {
    tell("fleet-note", e.message);
    return;
  }
  // Give the arena a moment to answer before re-reading, so the outcome is
  // usually there by the time the operator looks.
  setTimeout(() => paint("fleet", drawFleet), 700);
}

// The instance, linked to the machine it is on when the host knows its own
// provider id. That is the click after deciding the box rather than the
// process is the problem, and it saves finding the right row in a console
// listing every instance the account owns.
//
// A link and not a fetch, so the site's CSP has nothing to say about it: the
// policy governs what this page loads, not where it navigates. Provider-shaped
// on purpose. If the deployment ever leaves Vultr this is the one line that
// knows, which is a better place for that knowledge than nowhere.
const CONSOLE = "https://console.vultr.com/subs/?id=";

function instance(i) {
  if (!i.host_id) return i.instance;
  const a = document.createElement("a");
  a.href = CONSOLE + encodeURIComponent(i.host_id);
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.textContent = i.instance;
  a.title = "open the console page for the machine this instance runs on";
  return a;
}

// Bytes at a glance. An operator comparing a snapshot against a budget wants
// "3.1 kB", not five digits to count.
function bytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} kB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

// A commit is only ever compared here, so seven characters is the whole of
// what is useful. `unknown` is what a binary built outside CI reports, and
// saying so beats drawing a blank cell that reads like a missing field.
//
// The sha links to the repository at that commit, which is the question after
// noticing a row has drifted: what is this process actually running. CI stamps
// the short sha, and GitHub resolves a short one on /tree the same as a full
// one, so the value travels as it arrives rather than being padded here.
// `unknown` links nowhere, because there is nothing on the other end of it.
//
// The drift note stays outside the link. It is our reading of the row, not
// part of the sha, and a link whose text includes a parenthetical reads as
// though the parenthetical is somewhere you can go.
const REPO = "https://github.com/criccomini/vectorwake/tree/";

function build(b, mine) {
  if (!b) return "";
  const short = b.slice(0, 7);
  const drift = b !== mine && mine ? " (drift)" : "";
  if (b === "unknown") return short + drift;
  const box = document.createDocumentFragment();
  const a = document.createElement("a");
  a.href = REPO + encodeURIComponent(b);
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.textContent = short;
  a.title = "open the repository at this commit";
  box.append(a);
  if (drift) box.append(document.createTextNode(drift));
  return box;
}

// The rooms an instance is holding, as the numbers a player would use. A
// count cannot say whether one room is packed or four are half empty, which
// is the fill ladder working or not working.
function rooms(i) {
  const box = document.createElement("span");
  box.className = "rooms";
  const head = document.createElement("span");
  // A meta-layer that predates rooms travelling whole sends a count here.
  // The page and the server update on different clocks, so for a few minutes
  // after a deploy this reads the old shape, and a panel that draws nothing
  // is a worse answer than one that draws what it was sent.
  const list = Array.isArray(i.rooms) ? i.rooms : [];
  const count = Array.isArray(i.rooms) ? i.rooms.length : i.rooms || 0;
  head.textContent = `${count}/${i.max_rooms}`;
  box.append(head);
  // The breakdown only when there is something to break down. One room holds
  // whatever the players and bots columns already say, so repeating it beside
  // them taught nobody anything and read as a code to be cracked.
  if (list.length > 1) {
    for (const r of list) {
      const cell = document.createElement("span");
      cell.className = r.full ? "room full" : "room";
      cell.textContent = `#${r.number}: ${r.players} playing`;
      if (r.bots) cell.textContent += `, ${r.bots} bots`;
      if (r.full) cell.textContent += ", full";
      box.append(cell);
    }
  }
  return box;
}

function button(label, onClick, cls) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = label;
  if (cls) b.className = cls;
  b.addEventListener("click", onClick);
  return b;
}

// The controls on one instance's row. Restart is deliberately not here: it is
// the container platform's job, and the route accepts it for a considered
// curl rather than a stray click. Drain and pin ask first, because both
// interrupt a running game; unpin only hands an instance back to policy.
function actions(i) {
  const box = document.createElement("span");
  box.className = "acts";

  box.append(button("drain", async () => {
    const yes = await ask({
      title: "Drain this instance?",
      body: `${i.instance} stops taking joins and sends every bot home. ` +
        (i.players
          ? `The ${i.players} player(s) on it now keep flying until they leave.`
          : "Nobody is playing on it."),
      ok: "drain",
    });
    if (yes !== null) command(i.instance, "drain", "");
  }, "warn"));

  if (i.pinned) {
    box.append(button("unpin", () => command(i.instance, "unpin", "")));
  } else {
    box.append(button("pin", async () => {
      const zone = await ask({
        title: "Pin this instance?",
        body: "Automatic zone selection stops for it until it is unpinned" +
          (i.players ? ", and it drains first because somebody is playing." : "."),
        ok: "pin",
        label: "zone",
        value: i.zone || "",
      });
      if (zone) command(i.instance, "pin", zone);
    }, "warn"));
  }
  return box;
}

// What is worth saying out loud about one instance, worst first, or nothing
// when it is simply serving. The panel is read at a glance, so an instance
// that is fine should say "ok" and an instance that is not should say which
// way. Thresholds: the tick budget is 10ms at 100Hz, a queue that is not
// draining is the first sign of a room in trouble, and 30s of silence is when
// the directory reaps a registration.
function trouble(i) {
  if (!i.verified) return ["unverified", "bad"];
  if (i.age_ms > 15000) return [`silent ${Math.round(i.age_ms / 1000)}s`, "bad"];
  if (i.tick_us > 8000) return [`tick ${(i.tick_us / 1000).toFixed(1)}ms`, "bad"];
  if (i.queue_depth > 50) return [`queue ${i.queue_depth}`, "bad"];
  if (i.lag_actions > 0) return [`lag ${i.lag_actions}`, "warn"];
  // A pin outranks the rest of this list because it is the one state policy
  // cannot explain: an instance on a zone the rules would not have chosen
  // reads as a fault until you know somebody put it there. Named with who
  // and when, which is what turns two conflicting pins into visible operator
  // error rather than a mystery.
  if (i.pinned) {
    const when = i.pinned_at_ms
      ? new Date(i.pinned_at_ms).toTimeString().slice(0, 5) : "";
    return [`pinned to ${i.pinned}` +
      (i.pinned_by ? ` by ${i.pinned_by}` : "") + (when ? ` at ${when}` : ""), "warn"];
  }
  if (i.intent) return [`announced ${i.intent}`, "warn"];
  if (i.capped) return ["capped", "warn"];
  return ["ok", ""];
}

async function drawFleet() {
  const note = el("fleet-note");
  let f;
  try {
    f = await post("/v1/admin/fleet", { secret });
  } catch (e) {
    tell(note.id, e.message);
    noteOwner = "fleet";
    return;
  }
  if (noteOwner === "fleet") {
    tell("fleet-note", "");
    noteOwner = null;
  }

  // A render that throws goes to `paint`, which is where every other table's
  // does too. This used to be a try/catch here and nowhere else, which is
  // exactly why it was worth generalising: the lesson had been learned once
  // and applied at one call site out of six.
  draw(f);
}

function draw(f) {
  const rows = f.instances.map((i) => {
    return [
      instance(i),
      i.zone || "(none)",
      i.region,
      trouble(i),
      [i.players, "n"],
      [i.bots, "n"],
      rooms(i),
      // Two decimals because a healthy tick is tens of microseconds and one
      // decimal rounds every one of them to 0.0ms, which reads as no reading
      // at all rather than as the good news it is.
      [i.tick_us ? `${(i.tick_us / 1000).toFixed(2)}ms` : "", "n"],
      // The other four of the five numbers server.md names. They arrive on
      // every status push and were being thrown away here.
      // Zero is a real reading on a fleet with only house bots. Leave the cell
      // blank only when an arena did not send a usable measurement.
      [Number.isFinite(i.bw_per_player) ? `${bytes(i.bw_per_player)}/s` : "", "n"],
      [i.snapshot_bytes ? bytes(i.snapshot_bytes) : "", "n"],
      [i.queue_depth, i.queue_depth > 50 ? "n bad" : "n"],
      [i.lag_actions, i.lag_actions > 0 ? "n warn" : "n"],
      [build(i.build, f.build), i.build && f.build && i.build !== f.build ? "bad" : ""],
      actions(i),
    ];
  });
  fill("fleet", rows);
  drawAudit(f.audit || []);

  // The line above the table is the answer to "is the fleet up", so it says
  // the totals and then anything that is wrong with the deployment itself,
  // which no single row would show.
  const players = f.instances.reduce((n, i) => n + i.players, 0);
  const bots = f.instances.reduce((n, i) => n + i.bots, 0);
  const bad = f.instances.filter((i) => trouble(i)[1] === "bad").length;

  // The same totals as tiles, which is what gets read from across a desk. The
  // room count adds up what each instance is holding rather than counting
  // instances, since one arena with four rooms and four with one are the same
  // number of rooms and very different fleets. An instance too old to send
  // its rooms whole sends a count, and both shapes add up the same.
  // Not `rooms`, which is the name of the function three lines up that draws
  // one instance's. A const shadows it for the whole of this scope, so the
  // row builder above reached the binding before it was initialised and every
  // fleet draw threw. Caught in one page load by the guard added an hour ago,
  // which is the argument for it in one line.
  const roomsHeld = f.instances.reduce(
    (n, i) => n + (Array.isArray(i.rooms) ? i.rooms.length : Number(i.rooms) || 0), 0);
  el("stat-arenas").textContent = f.instances.length;
  el("stat-players").textContent = players;
  el("stat-bots").textContent = bots;
  el("stat-rooms").textContent = roomsHeld;

  const head = el("fleet-head-line");
  head.textContent = "";
  const say = (text, cls) => {
    const s = document.createElement("span");
    if (text instanceof Node) s.append(text);
    else s.textContent = text;
    if (cls) s.className = cls;
    head.append(s, document.createTextNode(" "));
  };
  const n = f.instances.length;
  if (!n) say("no arena is registered", "bad");
  else say(`${n} arena${n === 1 ? "" : "s"}, ${players} playing, ${bots} bots.`);
  if (bad) say(`${bad} needing attention.`, "bad");
  say(`catalog v${f.catalog_version}.`);

  // Every build in the deployment, held against this one. Three processes
  // that agree is a converge that landed; one that does not is a converge
  // that half did, which every other number here would go on reporting as
  // perfectly healthy.
  const all = [f.directory_build, ...f.instances.map((i) => i.build)];
  const others = all.filter(Boolean);
  const drifted = others.filter((b) => b !== f.build).length;
  // A process that reports no build at all used to be dropped here, so the
  // one state this line exists to catch, a converge that half landed, could
  // hide behind a blank field and read as agreement. Silence is not a match.
  const silent = all.length - others.length;
  if (f.build) {
    // The same sha the rows carry, linked the same way, because two spellings
    // of one commit eight lines apart reads as a bug in whichever is plainer.
    const line = document.createDocumentFragment();
    line.append(document.createTextNode("build "), build(f.build, ""),
                document.createTextNode("."));
    say(line);
    if (drifted) {
      say(`${drifted} process(es) on another build; a converge landed on some of the fleet and not the rest.`, "bad");
    }
    if (silent) {
      say(`${silent} process(es) name no build, so whether they match cannot be told from here.`, "bad");
    }
  }

  // A key disagreement is not visible anywhere else in the fleet: tokens fail
  // their check, everyone flies as a guest, and nothing is on fire.
  if (!f.key_agrees) {
    say("The catalog names a different verifying key than this meta-layer signs with, so every session token is failing.", "bad");
  }

}

// ---------------------------------------------------------------------- log

// The directory's own record, newest first. Both halves of a command land
// here: what it sent, then the arena's ack a moment later, which is why an
// `ack:` row has no verb of its own.
function drawAudit(rows) {
  fill("audit", rows.map((r) => {
    const t = new Date(r.at_ms);
    const hhmmss = [t.getHours(), t.getMinutes(), t.getSeconds()]
      .map((n) => String(n).padStart(2, "0")).join(":");
    const bad = /refused|no such|unknown|nobody/i.test(r.outcome);
    // An ack has no actor because no person sent it: it is the arena
    // answering. Saying so beats an empty cell that reads like missing data.
    const ack = r.verb.startsWith("ack:");
    return [
      hhmmss,
      r.actor || (ack ? "arena" : ""),
      ack ? "answered" : r.verb,
      r.target,
      [r.outcome || r.args, bad ? "wrap bad" : "wrap"],
    ];
  }));
  el("audit-empty").hidden = rows.length > 0;
  el("audit").hidden = rows.length === 0;
}

// --------------------------------------------------------------------- bans

async function drawBans() {
  const rows = (await post("/v1/admin/bans", { secret })).bans || [];
  fill("bans", rows.map((b) => [
    `#${b.account}`,
    pilotLink(b.account, b.name),
    [b.reason || "(none recorded)", "wrap"],
    b.last_seen,
  ]));
  el("bans-empty").hidden = rows.length > 0;
  el("bans").hidden = rows.length === 0;
}

// ------------------------------------------------------------------ recent

// How often the feed redraws. Slower than the fleet, because this is a
// database query rather than a number the directory already holds, and
// because what it shows changes on the scale of somebody joining a game.
const RECENT_REFRESH_MS = 15000;

// How long ago a timestamp was, in the words a note line wants. The server
// sends UTC without a zone, so it is read as UTC rather than as local.
function ago(utc) {
  const then = Date.parse(utc.replace(" ", "T") + "Z");
  if (Number.isNaN(then)) return utc;
  const s = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (s < 90) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 90) return `${m}m ago`;
  const h = Math.round(m / 60);
  return h < 48 ? `${h}h ago` : `${Math.round(h / 24)}d ago`;
}

// What is ticked in one facet, as an array.
function ticked(name) {
  return [...document.querySelectorAll(`#view-activity input[name="${name}"]:checked`)]
    .map((b) => b.value);
}

async function drawRecent() {
  const who = ticked("who");
  const body = {
    secret,
    who,
    kinds: ticked("kind"),
    hours: Number(el("recent-hours").value),
    limit: PAGE,
    offset: pages.recent * PAGE,
  };
  let r;
  try {
    r = await post("/v1/admin/recent", body);
  } catch (e) {
    tell("recent-note", /no such route/i.test(e.message)
      ? "this needs a newer meta-layer than the one running; it will fill in once the deploy lands"
      : e.message);
    return;
  }
  const list = r.events || [];
  fill("recent", list.map((v) => {
    // The call sign is a link to that pilot's page, so noticing something
    // here and going to look at it is one click and an address you can send
    // to somebody.
    return [
      v.at,
      pilotLink(v.pilot, v.name),
      [v.kind, NOTABLE(v) ? "bad" : ""],
      [describe(v), "wrap"],
      v.zone ? `${v.zone}${v.room === null ? "" : ` r${v.room}`} ${v.instance}` : "",
    ];
  }));
  el("recent").hidden = list.length === 0;

  // What the note says when the table is empty is the whole value of this
  // section on a quiet fleet. "Nothing matches" and "nothing is arriving"
  // look identical in a blank table and mean completely different things, so
  // the newest row of each kind is reported whether or not it is on screen.
  const newest = r.newest || {};
  const pulse = ["people", "bots"]
    .filter((k) => newest[k])
    .map((k) => `${k} ${ago(newest[k])}`)
    .join(", ");
  const empty = el("recent-empty");
  pager("recent", {
    empty: who.length ? "nothing matching that" : "tick people or bots to see anything",
    noun: "event",
    shown: list.length,
    from: r.offset,
    total: null,
    more: Boolean(r.more),
    paged: r.offset != null,
  });
  if (list.length) {
    tell("recent-note", `last filed: ${pulse}`);
    empty.hidden = true;
  } else {
    tell("recent-note", "");
    empty.hidden = false;
    empty.textContent = pulse
      ? `Nothing from ${who} matching that. The log is being written: last filed ${pulse}.`
      : "The log holds nothing at all yet. Either no arena has filed since it " +
        "was deployed, or reporting is off on the ones that have.";
  }
}

// A changed filter is a different list, and page four of it is an empty table
// and a puzzle.
// Every box and the one menu, on change. A changed filter is a different
// list, and page four of it is an empty table and a puzzle.
el("view-activity").addEventListener("change", () => {
  pages.recent = 0;
  paint("recent", drawRecent);
});

// Thirteen boxes are quick to tick and slow to untick one at a time.
el("kinds-clear").addEventListener("click", () => {
  for (const b of document.querySelectorAll('#view-activity input[name="kind"]')) {
    b.checked = false;
  }
  pages.recent = 0;
  paint("recent", drawRecent);
});

// ----------------------------------------------------------- client errors

function errorDetail(error) {
  const details = document.createElement("details");
  details.className = "error-detail";
  const summary = document.createElement("summary");
  summary.textContent = `${error.kind}: ${error.message}`;
  details.append(summary);

  if (error.stack) {
    const stack = document.createElement("pre");
    stack.className = "error-stack";
    stack.textContent = error.stack;
    details.append(stack);
  }
  const meta = document.createElement("p");
  meta.className = "error-meta";
  meta.textContent = `first seen ${error.first_at} UTC${error.user_agent ? ` · ${error.user_agent}` : ""}`;
  details.append(meta);
  return details;
}

async function drawErrors() {
  const r = await post("/v1/admin/errors", {
    secret,
    limit: PAGE,
    offset: pages.errors * PAGE,
  });
  const list = r.errors || [];
  el("errors-hour").textContent = r.groups_1h || 0;
  el("errors-day").textContent = r.groups_24h || 0;
  el("errors-groups").textContent = r.groups || 0;
  el("errors-hits").textContent = r.occurrences || 0;
  fill("errors", list.map((error) => {
    const last = document.createElement("time");
    last.dateTime = error.last_at.replace(" ", "T") + "Z";
    last.title = `${error.last_at} UTC`;
    last.textContent = ago(error.last_at);
    return [
      last,
      error.account ? pilotLink(error.account, `#${error.account}`) : "(startup)",
      [errorDetail(error), "wrap"],
      error.build || "(unknown)",
      [`${error.origin || ""}${error.page || ""}` || "(unknown)", "wrap error-origin"],
      [error.occurrences, "n"],
    ];
  }));
  el("errors").hidden = list.length === 0;
  el("errors-empty").hidden = list.length > 0;
  tell("errors-note", "");
  pager("errors", {
    empty: "no browser errors",
    noun: "group",
    shown: list.length,
    from: r.offset,
    total: r.groups,
    more: Boolean(r.more),
    paged: r.offset != null,
  });
}

// -------------------------------------------------------- rollback reports

function debugDetail(report) {
  const details = document.createElement("details");
  details.className = "error-detail";
  const summary = document.createElement("summary");
  summary.textContent = `${report.correction_px.toFixed(1)} px at ticks ` +
    `${report.snapshot_tick} server / ${report.client_tick} client`;
  details.append(summary);

  const meta = document.createElement("p");
  meta.className = "error-meta";
  meta.textContent = `predicted ${report.predicted_x.toFixed(1)},${report.predicted_y.toFixed(1)} ` +
    `then reconciled ${report.reconciled_x.toFixed(1)},${report.reconciled_y.toFixed(1)}; ` +
    `snapshot sequence ${report.snapshot_seq}`;
  details.append(meta);

  const motion = document.createElement("p");
  motion.className = "error-meta";
  motion.textContent = `velocity ${report.predicted_vx.toFixed(2)},${report.predicted_vy.toFixed(2)} ` +
    `then ${report.reconciled_vx.toFixed(2)},${report.reconciled_vy.toFixed(2)} px/tick; ` +
    `local debt ${report.local_debt_px.toFixed(2)} px / ` +
    `${report.local_debt_deg.toFixed(2)} deg`;
  details.append(motion);

  const shove = document.createElement("p");
  shove.className = "error-meta";
  shove.textContent = `repel ${report.repel_before_ticks} ticks at ` +
    `${report.repel_before_speed.toFixed(2)} px/tick, then ` +
    `${report.repel_after_ticks} ticks at ` +
    `${report.repel_after_speed.toFixed(2)} px/tick`;
  details.append(shove);
  return details;
}

function debugAccount() {
  const raw = el("debug-account").value.trim().replace(/^#/, "");
  const account = Number(raw);
  return Number.isSafeInteger(account) && account > 0 ? account : null;
}

async function drawDebug() {
  const r = await post("/v1/admin/debug", {
    secret,
    hours: Number(el("debug-hours").value),
    wire: el("debug-wire").value,
    account: debugAccount(),
    zone: el("debug-zone").value.trim(),
    build: el("debug-build").value.trim(),
    limit: PAGE,
    offset: pages.debug * PAGE,
  });
  const list = r.debug || [];
  fill("debug", list.map((report) => {
    const at = document.createElement("time");
    at.dateTime = report.at.replace(" ", "T") + "Z";
    at.title = `${report.at} UTC${report.user_agent ? ` · ${report.user_agent}` : ""}`;
    at.textContent = ago(report.at);
    const where = report.zone || "(unknown)";
    return [
      at,
      report.account ? pilotLink(report.account, `#${report.account}`) : "(unknown)",
      `${where}${report.room == null ? "" : ` r${report.room}`}`,
      report.wire,
      [debugDetail(report), "wrap"],
      [`frame ${report.frame_ms.toFixed(1)} ms; snapshots ${report.snapshot_gap_ms.toFixed(1)} ms; ` +
        `clock ${report.clock_adjust > 0 ? "+" : ""}${report.clock_adjust}`,
        "wrap"],
      [`ack ${report.input_ack}; margin ${report.input_margin}; lead ${report.input_lead}; ` +
        `${report.input_holes} holes`, "wrap"],
      report.build || "(unknown)",
    ];
  }));
  el("debug").hidden = list.length === 0;
  el("debug-empty").hidden = list.length > 0;
  tell("debug-note", "");
  pager("debug", {
    empty: "no rollback reports match these filters",
    noun: "report",
    shown: list.length,
    from: r.offset,
    total: null,
    more: Boolean(r.more),
    paged: r.offset != null,
  });
}

el("debug-filters").addEventListener("change", () => {
  pages.debug = 0;
  paint("debug", drawDebug);
});

let debugTyping = null;
for (const id of ["debug-account", "debug-zone", "debug-build"]) {
  el(id).addEventListener("input", () => {
    pages.debug = 0;
    clearTimeout(debugTyping);
    debugTyping = setTimeout(() => paint("debug", drawDebug), 180);
  });
}

// ---------------------------------------------------------------- activity

// The pilot log, under the card. Either the whole of one pilot's history or
// one stay out of it, which is what `stay` holds.
//
// A room's tick is a hundred a second, so ticks are what the arena counts in
// and seconds are what an operator reads in.
const TICKS_PER_SEC = 100;

function heldFor(ticks) {
  const s = Math.round((ticks || 0) / TICKS_PER_SEC);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m}m ${s % 60}s` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// One event as a sentence. The row is the point of this table, so the detail
// column is written out rather than shown as the JSON it arrives as: an
// operator reading a report should not have to know the wire to use the page.
//
// An unknown kind falls through to its raw detail rather than to nothing. The
// arena can learn a new event before this file does, and a row that says
// something unfamiliar beats a row that says nothing.
// Label-and-value pairs, dropping the ones that are not there. A row can
// always be missing a field: an arena a version ahead or behind writes a
// different shape, and this page meets both during a deploy. Printing the
// word "undefined" at an operator is worse than printing nothing, because it
// reads as something the fleet recorded.
function bits(...pairs) {
  return pairs
    .filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([k, v]) => (k ? `${k} ${v}` : `${v}`))
    .join(", ");
}

function describe(e) {
  const d = e.detail || {};
  switch (e.kind) {
    case "join":
      return bits(["hull", d.class], ["slot", d.ship], ["side", d.team],
                  ["over", d.transport]);
    case "denied": {
      // The sentence the pilot was actually sent, which is the thing they are
      // quoting when they report it. The claimed name rides along only when
      // it disagrees with the account's, since two names on one refusal is
      // worth seeing and one repeated is noise.
      const why = d.why || "refused";
      return d.claimed && d.claimed !== e.name ? `${why} (claimed ${d.claimed})` : why;
    }
    case "watch":
      return bits(["side", d.team], [null, d.any ? "staff sight" : null]);
    case "ship":
      return bits([null, d.from === undefined ? null : `hull ${d.from} to ${d.to}`]);
    case "team":
      return bits([null, d.from === undefined ? null : `side ${d.from} to ${d.to}`],
                  [null, d.public === false ? "private" : null]);
    case "found":
      return bits([null, d.name], ["side", d.team]);
    case "invite":
      return bits(["slot", d.to]);
    case "sit_out":
      return d.why === "safe" ? "moved by the safe-zone sweep" : "asked to sit out";
    case "died":
      return bits(["by", d.by], [null, d.bounty ? `paid ${d.bounty}` : null]);
    case "kill":
      return bits(["of", d.of], [null, d.bounty ? `paid ${d.bounty}` : null],
                  [null, d.quit ? "they quit the fight" : null]);
    case "fly":
      return bits(["hull", d.class], ["slot", d.ship], ["side", d.team]);
    case "on_air":
      return bits([null, d.ship === undefined ? null : `slot ${d.ship} watched`]);
    case "leave":
      return bits([null, d.why],
                  [null, d.held === undefined ? null : `held ${heldFor(d.held)}`],
                  [null, d.quit_loss ? "settled as a quit" : null]);
    case "account":
      return bits(["dealt", d.name]);
    case "claim":
      return "password set";
    case "login":
      return "signed in on a new device";
    case "rename":
      return bits([null, d.from], [d.from ? "to" : null, d.to],
                  ["by", d.by === "self" ? "self" : d.by && `#${d.by}`]);
    case "ban":
      return bits(["by", d.by && `#${d.by}`], [null, d.reason]);
    case "unban":
    case "grant":
    case "revoke":
      return bits(["by", d.by && `#${d.by}`]);
    default:
      return Object.keys(d).length ? JSON.stringify(d) : "";
  }
}

// Refusals and quits are the two an operator is scanning for, so they carry
// the color the rest of the page gives to something wrong.
const NOTABLE = (e) =>
  e.kind === "denied" || e.kind === "ban" || (e.kind === "leave" && e.detail?.quit_loss);

async function drawEvents() {
  const box = el("activity");
  // The prompt and the table are the two halves of one section, so exactly
  // one of them is up at any time.
  el("activity-none").hidden = Boolean(shown);
  if (!shown) { box.hidden = true; return; }
  box.hidden = false;
  const page = { limit: PAGE, offset: pages.events * PAGE };
  const body = stay
    ? { secret, session: stay, ...page }
    : { secret, account: shown.account, ...page };
  let r;
  try {
    r = await post("/v1/admin/events", body);
  } catch (e) {
    // Same deploy race the pilot list handles: these files ship from the
    // checkout in a minute and the binary ships once CI has built it, so a
    // route this page knows can be one the meta-layer has not learned.
    tell("activity-note", /no such route/i.test(e.message)
      ? "this needs a newer meta-layer than the one running; it will fill in once the deploy lands"
      : e.message);
    fill("events", []);
    el("events-empty").hidden = true;
    return;
  }
  const list = r.events || [];
  fill("events", list.map((v) => {
    // The stay opens on its own. A pilot's history runs across several and
    // reading one out of the middle is most of what a report needs.
    const pick = document.createElement("button");
    pick.type = "button";
    pick.className = "link pick";
    pick.textContent = v.session ? v.session.slice(0, 8) : "";
    if (v.session) pick.addEventListener("click", () => { stay = v.session; pages.events = 0; drawEvents(); });
    return [
      v.at,
      [v.kind, NOTABLE(v) ? "bad" : ""],
      [describe(v), "wrap"],
      // An account event happened with no arena involved, and a dash there
      // would read as a room whose name went missing.
      v.zone ? `${v.zone}${v.room === null ? "" : ` r${v.room}`} ${v.instance}` : "",
      v.session ? pick : "",
    ];
  }));
  el("events-empty").hidden = list.length > 0 || Boolean(stay);
  el("events").hidden = list.length === 0;

  pager("events", {
    empty: "nothing recorded",
    noun: "event",
    shown: list.length,
    from: r.offset,
    total: null,
    more: Boolean(r.more),
    paged: r.offset != null,
  });

  const note = el("activity-note");
  note.textContent = "";
  if (stay) {
    note.append("one stay. ");
    const all = document.createElement("button");
    all.type = "button";
    all.className = "link";
    all.textContent = "show the whole history";
    all.addEventListener("click", () => { stay = null; pages.events = 0; drawEvents(); });
    note.append(all);
  } else if (list.length) {
    note.textContent = "newest first; open a stay to read one of them in full";
  }
}

// ------------------------------------------------------------------- pilot

function drawPilot(p) {
  shown = p;
  // The page is about this person, so it is titled with them. "Pilot" over a
  // card that already says the call sign twice is a heading doing no work.
  el("one-head").textContent = p.name || `Account #${p.account}`;
  const dl = el("pilot");
  dl.textContent = "";
  const row = (dt, dd, cls) => {
    const t = document.createElement("dt");
    t.textContent = dt;
    const d = document.createElement("dd");
    d.textContent = dd;
    if (cls) d.className = cls;
    dl.append(t, d);
  };
  row("account", `#${p.account}`);
  row("call sign", p.name || "(none)");
  row("kind", p.kind === "human" ? (p.claimed ? "human, claimed" : "guest") : p.kind);
  row("created", p.created);
  row("last seen", p.last_seen);
  row("standing", p.banned ? `banned: ${p.reason || "no reason recorded"}` : "in good standing",
      p.banned ? "bad" : "good");
  if (p.admin) row("admin", "yes", "good");

  el("pilot-card").hidden = false;
  // A bot's name is how its roster identity is found, so the server refuses
  // to rename one at all. Saying so by not drawing the controls beats saying
  // it in a refusal.
  el("name-text").value = "";
  el("name-form").hidden = p.kind !== "human";

  const form = el("ban-form"), button = el("ban-button");
  form.hidden = false;
  // An admin is not bannable: the server refuses, and a button that is not
  // there is a kinder refusal than one that is.
  button.hidden = p.admin;
  el("kick-button").hidden = p.admin;
  el("ban-reason").parentElement.hidden = p.admin;
  button.textContent = p.banned ? "unban" : "ban";
  button.className = p.banned ? "" : "ban";
  el("ban-reason").value = p.banned ? p.reason || "" : "";

  // The flag. Only a claimed human can hold one, because the panel signs in
  // with a password, so the button is drawn only where it could work.
  const flag = el("admin-button");
  const grantable = p.kind === "human" && (p.admin || p.claimed);
  flag.hidden = !grantable;
  flag.textContent = p.admin ? "revoke admin" : "make admin";
  flag.className = p.admin ? "ban" : "";

  // A different pilot starts on their whole history rather than inheriting
  // whichever stay the last one was opened to.
  if (!shownWas || shownWas !== p.account) stay = null;
  shownWas = p.account;
  paint("activity", drawEvents);
}


// ------------------------------------------------------------------ pilots

// The list under the filter. Searched on the server, because guests are free
// and accumulate for a week, so the set is unbounded and the index is where
// the filtering belongs.
//
// Typing is debounced: a keystroke is not a question worth asking a database,
// and 180ms is under the gap between two keys and over the gap inside one
// word.
let typing = null;

// Where a pilot sits on their ladder. Empty while they are placing, because
// the server hands out no position until a rating has settled and an empty
// cell says that more plainly than a placeholder would.
//
// The size of the board rides in the title rather than the cell: #3 of 5 and
// #3 of 5000 are different facts, and a column narrow enough to scan cannot
// carry both halves of every row.
function rank(p) {
  if (p.rank == null) return "";
  const cell = document.createElement("span");
  cell.textContent = `#${p.rank}`;
  if (p.of) cell.title = `${p.rank} of ${p.of} rated in ${p.class}`;
  return cell;
}

// The band, which is the only one of these three a player is ever shown. The
// server computes it, and sends the two constants behind it, because the
// thresholds and the default class live in rating.rs and meta.rs and a second
// copy here is a second copy to forget when they move.
//
// Four states, and the last two are the reason this is not a one-liner.
//
// A pilot gets a row in `ratings` when a rated event first credits them, not
// when the account is made, so a deployment where nobody has died yet has an
// accounts table and an empty ladder. That is the ordinary state of a new
// fleet and it says `unrated`, because a column of eight blanks reads as a
// panel that is broken rather than as a fleet that has not fought. It cost an
// hour of looking for a bug that was not there to learn that.
//
// Blank is kept for the one case where this page genuinely does not know: a
// meta-layer too old to send any of these fields. `provisional` rides on the
// reply for exactly that, since it is present whenever the feature is and
// absent whenever it is not, and saying `unrated` off the back of a field the
// server never sent would be a confident lie about somebody's standing.
function tier(p, r) {
  if (r.provisional == null) return "";
  if (p.tier) return p.class === r.default_class ? p.tier : `${p.tier} (${p.class})`;
  if (p.games != null) return `placing ${p.games}/${r.provisional}`;
  return "unrated";
}

async function drawPilots(q) {
  let r;
  try {
    r = await post("/v1/admin/pilots",
                   { secret, q: q || "", limit: PAGE, offset: pages.pilots * PAGE });
  } catch (e) {
    // The page and the server update on different clocks: these files ship
    // from the checkout in about a minute, the binary ships as an image once
    // CI has built it. So a route this page knows about can be a route the
    // meta-layer has not learned yet, and "no such route" is a deploy in
    // progress rather than anything an operator can act on.
    tell("pilots-note", /no such route/i.test(e.message)
      ? "this list needs a newer meta-layer than the one running; it will fill in once the deploy lands"
      : e.message);
    return;
  }
  const list = r.pilots || [];
  fill("pilots", list.map((p) => {
    return [
      `#${p.account}`,
      pilotLink(p.account, p.name),
      p.kind === "human" ? (p.claimed ? "human" : "guest") : p.kind,
      [p.banned ? "banned" : p.admin ? "admin" : "", p.banned ? "bad" : "good"],
      [rank(p), "n"],
      [p.rating == null ? "" : Math.round(p.rating), "n"],
      tier(p, r),
      p.last_seen,
    ];
  }));
  // A total the server counted, so the footer can say which slice of what it
  // is showing rather than "the first hundred", which never said how many
  // hundreds there were.
  // Straight from the reply rather than recomputed from PAGE. The server
  // clamps what it was asked for, so the page it actually returned is the only
  // one that can be described honestly, and a client deriving the answer from
  // its own constant is a client that lies the moment the two disagree.
  const paged = r.offset != null;
  pager("pilots", {
    empty: q ? `nobody matches ${q}` : "no pilots yet",
    noun: "pilot",
    shown: list.length,
    from: r.offset,
    total: r.total,
    more: paged && r.offset + list.length < r.total,
    paged,
  });
}

el("lookup-q").addEventListener("input", (ev) => {
  clearTimeout(typing);
  const q = ev.target.value.trim();
  pages.pilots = 0;
  typing = setTimeout(() => paint("pilots", () => drawPilots(q)), 180);
});

async function lookup(q) {
  const note = el("lookup-note");
  tell("lookup-note", "");
  // A different pilot is a different history, so it starts at the first page
  // of it. Same pilot redrawn after a rename keeps the page you were on.
  const m0 = q.match(/^#?(\d+)$/);
  if (!shown || (m0 && Number(m0[1]) !== shown.account)) pages.events = 0;
  const body = { secret };
  const m = q.match(/^#?(\d+)$/);
  if (m) body.account = Number(m[1]);
  else body.name = q;
  try {
    drawPilot(await post("/v1/admin/pilot", body));
  } catch (e) {
    el("pilot-card").hidden = true;
    el("activity").hidden = true;
    el("activity-none").hidden = false;
    shown = null;
    shownWas = null;
    stay = null;
    tell(note.id, e.message);
  }
}

// Kick goes to every instance, because a call sign says who and not where.
// The arenas not holding them answer "nobody here called ...", which is worth
// reading in the log rather than hiding: it says where they are not.
el("kick-button").addEventListener("click", () => {
  if (!shown || !shown.name) return;
  command("*", "kick", shown.name);
});

// The note is the only free text an operator writes about somebody, so it
// saves on its own rather than riding along with a ban.
// Rename: one route, two intentions. A typed name is sent as typed and the
// server decides whether it is allowed; an empty field means deal one, which
// is what the reroll button sends. Either way the account number does not
// move, so the rating and the history ride through it.
async function rename(name, dialog) {
  if (!shown) return;
  const yes = await ask(dialog);
  if (yes === null) return;
  try {
    const r = await post("/v1/admin/rename", { secret, account: shown.account, name });
    await lookup(`#${shown.account}`);
    tell("lookup-note", `now called ${r.name}`, "ok");
  } catch (e) {
    tell("lookup-note", e.message);
  }
}

el("name-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const want = el("name-text").value.trim();
  if (!shown || !want) return;
  rename(want, {
    title: "Rename this pilot?",
    body: `${shown.name} becomes ${want}. Their old call sign goes back into ` +
      "the pool for anybody to be dealt, and this one is theirs until it is " +
      "changed again.",
    ok: "rename",
  });
});

// Granting and revoking the flag. It is the one action on this page that
// changes who else may use the page, so it asks in the plainest words the
// dialog has room for.
async function setAdmin(account, name, admin) {
  const yes = await ask({
    title: admin ? "Make this pilot an admin?" : "Revoke this admin?",
    body: admin
      ? `${name} will be able to sign in here and do everything you can do, ` +
        "including making other admins."
      : `${name} will not be able to sign in here again. Their account, ` +
        "rating and history are untouched.",
    ok: admin ? "make admin" : "revoke",
  });
  if (yes === null) return;
  try {
    await post("/v1/admin/grant", { secret, account, admin });
    // Re-read first and say so second: `lookup` clears this line on its way
    // in, so a message set before it is a message nobody sees.
    if (shown && shown.account === account) await lookup(`#${account}`);
    paint("admins", drawAdmins);
    tell("lookup-note", admin ? `${name} is an admin` : `${name} is no longer an admin`, "ok");
  } catch (e) {
    tell("lookup-note", e.message);
  }
}

el("admin-button").addEventListener("click", () => {
  if (!shown) return;
  setAdmin(shown.account, shown.name, !shown.admin);
});

el("reroll-button").addEventListener("click", () => {
  if (!shown) return;
  rename("", {
    title: "Reroll this call sign?",
    body: `${shown.name} is dealt a new name from the pool, and the old one ` +
      "goes back into it.",
    ok: "reroll",
  });
});

el("ban-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  if (!shown) return;
  const note = el("lookup-note");
  try {
    await post("/v1/admin/ban", {
      secret,
      account: shown.account,
      banned: !shown.banned,
      reason: el("ban-reason").value.trim(),
    });
    // Re-read rather than guess: what the page shows is what the database
    // holds, including anything another operator did in between.
    await lookup(`#${shown.account}`);
    paint("bans", drawBans);
  } catch (e) {
    tell(note.id, e.message);
  }
});

// ------------------------------------------------------------------ admins

async function drawAdmins() {
  const rows = (await post("/v1/admin/admins", { secret })).admins || [];
  fill("admins", rows.map((a) => {
    const box = document.createElement("span");
    box.className = "acts";
    box.append(button("revoke", () => setAdmin(a.account, a.name, false), "warn"));
    return [`#${a.account}`, pilotLink(a.account, a.name), a.last_seen, box];
  }));
}

window.vectorwakeAdmin = Object.freeze({
  post, el, tell, fill, ask, installMaps, drawMaps,
  get secret() { return secret; },
});
boot();
})();
