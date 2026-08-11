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
  if (!r.ok) throw new Error(reply.error || `the server said ${r.status}`);
  return reply;
}

function show(section) {
  login.hidden = section !== login;
  panel.hidden = section !== panel;
}

// ------------------------------------------------------------------ sign in

async function arrive(name) {
  el("who").textContent = name;
  show(panel);
  el("lookup-q").focus();
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

el("logout").addEventListener("click", () => {
  localStorage.removeItem(KEY);
  secret = "";
  shown = null;
  show(login);
  el("login-note").textContent = "";
});

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
  } catch (e) {
    note.textContent = e.message;
  }
});

// ------------------------------------------------------------------ admins

async function drawAdmins() {
  const rows = (await post("/v1/admin/admins", { secret })).admins || [];
  const body = el("admins").querySelector("tbody");
  body.textContent = "";
  for (const a of rows) {
    const tr = document.createElement("tr");
    for (const v of [`#${a.account}`, a.name || "(none)", a.last_seen]) {
      const td = document.createElement("td");
      td.textContent = v;
      tr.append(td);
    }
    body.append(tr);
  }
}

boot();
