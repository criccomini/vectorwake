// The panel's whole brain. Talks to the meta-layer through the /v1 proxy on
// this origin, holds one device secret in localStorage, and treats the
// `admin` field a session reply carries as decoration: every action posts
// the secret and the server re-checks the flag, so nothing this file decides
// is load-bearing. docs/architecture/admin.md is the design.
//
// Server text goes into the page through textContent, never through
// innerHTML. Ban reasons are operator-typed free text, and the CSP upstream
// is the second lock on that door, not the first.

"use strict";

const KEY = "vw-admin-secret";

const el = (id) => document.getElementById(id);
const login = el("login"), panel = el("panel");

let secret = localStorage.getItem(KEY) || "";
// The pilot the lookup found, so the ban button knows its target and sense.
let shown = null;

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

function show(section) {
  login.hidden = section !== login;
  panel.hidden = section !== panel;
}

// ------------------------------------------------------------------ sign in

// How often the fleet redraws while somebody is looking at it. An arena
// pushes status every five seconds, so asking faster would draw the same
// numbers again.
const FLEET_REFRESH_MS = 5000;
let ticking = null;
// Who wrote what is in the fleet note. The refresh clears its own messages
// and leaves a command's alone, because a redraw arriving a second after a
// click used to wipe the only confirmation the click produced.
let noteOwner = null;

async function arrive(name) {
  el("who").textContent = name;
  show(panel);
  el("lookup-q").focus();
  refresh();
  // Only the fleet is on a timer. Bans and admins change when an operator
  // changes them, and this page is where that happens.
  if (!ticking) ticking = setInterval(() => drawFleet().catch(() => {}), FLEET_REFRESH_MS);
}

function refresh() {
  drawFleet().catch(() => {});
  drawBans().catch(() => {});
  drawAdmins().catch(() => {});
}

async function boot() {
  if (!secret) { show(login); return; }
  try {
    const s = await post("/v1/session", { secret });
    if (!s.admin) {
      localStorage.removeItem(KEY);
      secret = "";
      el("login-note").textContent = "that account no longer holds the admin flag";
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
    el("login-note").textContent = e.message;
    show(login);
  }
}

el("login-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const note = el("login-note");
  note.textContent = "signing in.";
  try {
    const got = await post("/v1/login", {
      name: el("login-name").value.trim(),
      password: el("login-password").value,
    });
    const s = await post("/v1/session", { secret: got.secret });
    if (!s.admin) {
      // A real pilot, but not an operator. The secret is not kept: this
      // page has no business holding a game credential it cannot use.
      note.textContent = "that account does not hold the admin flag";
      return;
    }
    secret = got.secret;
    localStorage.setItem(KEY, secret);
    el("login-password").value = "";
    note.textContent = "";
    arrive(s.name);
  } catch (e) {
    note.textContent = e.message;
  }
});

// Back to the door, with the reason if there is one. Signing out and being
// turned away are the same teardown, so they are the same function.
function eject(why) {
  localStorage.removeItem(KEY);
  secret = "";
  shown = null;
  if (ticking) { clearInterval(ticking); ticking = null; }
  el("pilot").hidden = true;
  el("ban-form").hidden = true;
  el("login-note").textContent = why || "";
  show(login);
}

el("logout").addEventListener("click", () => eject(""));

// -------------------------------------------------------------------- fleet

// Fill a tbody from rows of cells. Every value goes in as text, which is the
// rule this page keeps everywhere: server strings are data, never markup. A
// cell may also be a node, which is how the action buttons get in.
function fill(table, rows) {
  const body = el(table).querySelector("tbody");
  body.textContent = "";
  for (const cells of rows) {
    const tr = document.createElement("tr");
    for (const c of cells) {
      const td = document.createElement("td");
      const v = Array.isArray(c) ? c[0] : c;
      if (v instanceof Node) td.append(v);
      else td.textContent = v;
      if (Array.isArray(c) && c[1]) td.className = c[1];
      tr.append(td);
    }
    body.append(tr);
  }
  return body;
}

// ------------------------------------------------------------------ commands

// Send a verb to an instance, or to every instance when `instance` is "*".
// The answer says only that it went: the arena's outcome arrives at the
// directory a moment later and shows up in the log below.
async function command(instance, verb, args, confirming) {
  if (confirming && !window.confirm(confirming)) return;
  const note = el("fleet-note");
  noteOwner = "command";
  try {
    const r = await post("/v1/admin/command", { secret, instance, verb, args });
    note.textContent = `${verb} sent to ${r.sent} instance(s); the log has the outcome`;
  } catch (e) {
    note.textContent = e.message;
    return;
  }
  // Give the arena a moment to answer before re-reading, so the outcome is
  // usually there by the time the operator looks.
  setTimeout(() => drawFleet().catch(() => {}), 700);
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
  box.append(button("drain", () => command(i.instance, "drain", "",
    `Drain ${i.instance}? New joins stop and every bot goes home. ` +
    `${i.players} player(s) are on it now and will not be disconnected.`), "warn"));
  if (i.pinned) {
    box.append(button("unpin", () => command(i.instance, "unpin", "")));
  } else {
    box.append(button("pin", () => {
      const zone = window.prompt("Pin to which zone?", i.zone || "");
      if (!zone) return;
      command(i.instance, "pin", zone,
        `Pin ${i.instance} to ${zone}? Automatic zone selection stops for it` +
        (i.players ? ", and it drains first because somebody is playing." : "."));
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
    note.textContent = e.message;
    noteOwner = "fleet";
    return;
  }
  if (noteOwner === "fleet") {
    note.textContent = "";
    noteOwner = null;
  }

  const rows = f.instances.map((i) => [
    i.instance,
    i.zone || "(none)",
    i.region,
    [i.players, "n"],
    [i.bots, "n"],
    [`${i.rooms}/${i.max_rooms}`, "n"],
    // Two decimals because a healthy tick is tens of microseconds and one
    // decimal rounds every one of them to 0.0ms, which reads as no reading
    // at all rather than as the good news it is.
    [i.tick_us ? `${(i.tick_us / 1000).toFixed(2)}ms` : "", "n"],
    trouble(i),
    actions(i),
  ]);
  fill("fleet", rows);
  drawAudit(f.audit || []);

  // The line above the table is the answer to "is the fleet up", so it says
  // the totals and then anything that is wrong with the deployment itself,
  // which no single row would show.
  const players = f.instances.reduce((n, i) => n + i.players, 0);
  const bots = f.instances.reduce((n, i) => n + i.bots, 0);
  const bad = f.instances.filter((i) => trouble(i)[1] === "bad").length;
  const head = el("fleet-head");
  head.textContent = "";
  const say = (text, cls) => {
    const s = document.createElement("span");
    s.textContent = text;
    if (cls) s.className = cls;
    head.append(s, document.createTextNode(" "));
  };
  const n = f.instances.length;
  if (!n) say("no arena is registered", "bad");
  else say(`${n} arena${n === 1 ? "" : "s"}, ${players} playing, ${bots} bots.`);
  if (bad) say(`${bad} needing attention.`, "bad");
  say(`catalog v${f.catalog_version}.`);
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
      [r.outcome || r.args, bad ? "bad" : ""],
    ];
  }));
  el("audit-empty").hidden = rows.length > 0;
  el("audit").hidden = rows.length === 0;
}

// --------------------------------------------------------------------- bans

async function drawBans() {
  const rows = (await post("/v1/admin/bans", { secret })).bans || [];
  fill("bans", rows.map((b) => [
    `#${b.account}`, b.name || "(none)", b.reason || "(none recorded)", b.last_seen,
  ]));
  el("bans-empty").hidden = rows.length > 0;
  el("bans").hidden = rows.length === 0;
}

// ------------------------------------------------------------------- pilot

function drawPilot(p) {
  shown = p;
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
  if (p.admin) row("admin", "holds the flag", "good");
  dl.hidden = false;

  // Admins are not bannable from here; the server refuses and the button
  // saying so first is kinder than the refusal.
  const form = el("ban-form"), button = el("ban-button");
  form.hidden = p.admin;
  button.textContent = p.banned ? "unban" : "ban";
  button.className = p.banned ? "" : "ban";
  el("ban-reason").value = "";
}

async function lookup(q) {
  const note = el("lookup-note");
  note.textContent = "";
  const body = { secret };
  const m = q.match(/^#?(\d+)$/);
  if (m) body.account = Number(m[1]);
  else body.name = q;
  try {
    drawPilot(await post("/v1/admin/pilot", body));
  } catch (e) {
    el("pilot").hidden = true;
    el("ban-form").hidden = true;
    shown = null;
    note.textContent = e.message;
  }
}

el("lookup-form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  lookup(el("lookup-q").value.trim());
});

// Kick goes to every instance, because a call sign says who and not where.
// The arenas not holding them answer "nobody here called ...", which is worth
// reading in the log rather than hiding: it says where they are not.
el("kick-button").addEventListener("click", () => {
  if (!shown || !shown.name) return;
  command("*", "kick", shown.name);
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
    drawBans().catch(() => {});
  } catch (e) {
    note.textContent = e.message;
  }
});

// ------------------------------------------------------------------ admins

async function drawAdmins() {
  const rows = (await post("/v1/admin/admins", { secret })).admins || [];
  fill("admins", rows.map((a) => [`#${a.account}`, a.name || "(none)", a.last_seen]));
}

boot();
