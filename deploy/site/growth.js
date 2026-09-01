"use strict";

const page = document.body.dataset.growthPage;
const request = (path, body) => fetch(path, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body || {}),
}).then((response) => response.json().then((json) => {
  if (!response.ok) {
    const error = new Error(json.error || `Request returned ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return json;
}));

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function matchRecord(id) {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    try {
      return await request("/v1/match", { id });
    } catch (error) {
      if (error.status !== 404 || attempt === 9) throw error;
      await wait(1000);
    }
  }
  throw new Error("That match has not landed yet.");
}

const text = (selector, value) => {
  const node = document.querySelector(selector);
  if (node) node.textContent = value;
};

const html = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
})[character]);

function sharePage(label) {
  const share = document.querySelector("[data-share]");
  if (!share) return;
  share.addEventListener("click", async () => {
    try {
      if (navigator.share) await navigator.share({ title: label, url: location.href });
      else await navigator.clipboard.writeText(location.href);
      share.textContent = navigator.share ? "Shared" : "Link copied";
    } catch (_) {
      share.textContent = "Share canceled";
    }
  });
}

const scoreColor = (index) => index === 0 ? "friend" : "enemy";

async function matchPage() {
  const id = Number(location.pathname.split("/").filter(Boolean).pop());
  if (!Number.isSafeInteger(id) || id <= 0) throw new Error("That match link is incomplete.");
  const payload = await matchRecord(id);
  const match = payload.match;
  const score = match.score || [];
  const teams = match.teams || [];
  const winner = score.length && Math.max(...score);
  const won = score.indexOf(winner);
  const draw = score.filter((value) => value === winner).length > 1;
  text("[data-title]", draw ? "Nobody gave an inch." : `${teams[won] || "A side"} took it.`);
  text("[data-status]", `${payload.zone} / ${match.map || "unnamed ground"} / room ${match.room}`);

  const scoreNode = document.querySelector("[data-score]");
  scoreNode.hidden = false;
  scoreNode.innerHTML = score.map((value, index) =>
    `<div class="score-side ${scoreColor(index)}"><span>${html(teams[index] || `side ${index + 1}`)}</span><strong>${Number(value) || 0}</strong></div>`
  ).join("");

  const byTeam = new Map();
  (match.pilots || []).forEach((pilot) => {
    if (!byTeam.has(pilot.team)) byTeam.set(pilot.team, []);
    byTeam.get(pilot.team).push(pilot);
  });
  const grid = document.querySelector("[data-grid]");
  grid.hidden = false;
  grid.innerHTML = [...byTeam.entries()].map(([team, pilots]) => {
    pilots.sort((a, b) => b.kills - a.kills || a.deaths - b.deaths);
    return `<article class="roster"><h2 class="${scoreColor(team)}">${html(teams[team] || `side ${team + 1}`)}</h2>${pilots.map((pilot, index) =>
      `<div class="roster-row"><span>${html(pilot.name)}${pilot.bot ? " / AI" : ""}${index === 0 && pilot.kills > 0 ? " / MVP" : ""}</span><span>${Number(pilot.kills) || 0} / ${Number(pilot.deaths) || 0} / ${Number(pilot.assists) || 0}</span></div>`
    ).join("")}</article>`;
  }).join("");
  const actions = document.querySelector("[data-actions]");
  actions.hidden = false;
  document.querySelector("[data-replay]").href = `https://play.vectorwake.net/#replay/${id}`;
  sharePage("Vectorwake match result");
}

function story(label, pilot, figure, detail) {
  if (!pilot) return "";
  return `<article class="story"><p>${html(label)}</p><strong>${html(pilot.name)}</strong><span>${html(figure)}</span><small>${html(detail)}</small></article>`;
}

// The board reads one game at a time, or all of them.
//
// A rating is kept per zone, so an unfiltered board cannot put a rating
// column beside a name and mean one thing by it: every row is read in
// whichever zone that pilot flew most, and two rows beside each other can be
// ratings in different games. Naming a zone makes the whole row that zone's,
// the kills and the swing along with the rating.
//
// The picker is drawn from the reply rather than written out here, so a zone
// added to the catalog appears on this page without an edit.
function drawZones(payload, chosen) {
  const filter = document.querySelector("[data-zone-filter]");
  const select = document.querySelector("[data-zone]");
  if (!filter || !select) return;
  const zones = payload.zones || [];
  filter.hidden = !zones.length;
  select.innerHTML = [`<option value="">Every zone</option>`].concat(
    zones.map((zone) =>
      `<option value="${html(zone.zone)}"${zone.zone === chosen ? " selected" : ""}>${html(zone.label || zone.zone)}</option>`)
  ).join("");
  select.value = chosen;
}

async function weekBoard(zone) {
  const payload = await request("/v1/week", { back: 0, zone });
  const rows = payload.week || [];
  const where = payload.label ? ` in ${payload.label}` : "";
  text("[data-status]", rows.length
    ? `Week of ${payload.since}${where}. ${rows.length} pilots on the board.`
    : `No flights have landed${where} this week yet.`);
  drawZones(payload, zone);
  const best = (field) => rows.reduce((held, row) => !held || (row[field] || 0) > (held[field] || 0) ? row : held, null);
  const stories = document.querySelector("[data-stories]");
  stories.hidden = !rows.length;
  stories.innerHTML = [
    story("top gun", best("kills"), `${best("kills")?.kills || 0} kills`, "The week’s largest total"),
    story("biggest climb", best("swing"), `+${best("swing")?.swing || 0}`, "Rating gained this week"),
    story("most wins", best("wins"), `${best("wins")?.wins || 0}`, "Matches taken this week"),
    story("most time in the black", best("seconds"), `${Math.round((best("seconds")?.seconds || 0) / 60)} min`, "Time in live rooms"),
  ].join("");
  const ladder = document.querySelector("[data-ladder]");
  ladder.hidden = !rows.length;
  document.querySelector("[data-rows]").innerHTML = rows.slice(0, 100).map((row) =>
    `<div class="ladder-row"><span>${html(row.name)}</span><span>${Number(row.kills) || 0}</span><span>${Number(row.deaths) || 0}</span><span>${Number(row.rating) || "unrated"}</span><span class="${row.swing >= 0 ? "friend" : "enemy"}">${row.swing > 0 ? "+" : ""}${Number(row.swing) || 0}</span></div>`
  ).join("");
}

async function weekPage() {
  // The zone rides the address, so a filtered board is a link somebody can
  // send. Anything the catalog does not run is refused by the server, and
  // the page says so rather than showing an empty week as if it were true.
  const wanted = new URLSearchParams(location.search || "").get("zone") || "";
  await weekBoard(wanted);
  const select = document.querySelector("[data-zone]");
  if (select) {
    select.addEventListener("change", () => {
      const zone = select.value || "";
      history.replaceState({}, "", zone ? `/week?zone=${encodeURIComponent(zone)}` : "/week");
      weekBoard(zone).catch((error) => text("[data-status]", error.message));
    });
  }
  sharePage("This week in Vectorwake");
}

const run = page === "match" ? matchPage : weekPage;
run().catch((error) => text("[data-status]", error.message));
