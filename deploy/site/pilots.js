"use strict";

(() => {
  const page = document.body.dataset.pilotsPage;
  if (!page) return;

  const number = new Intl.NumberFormat("en-US");

  const request = async (path, body) => {
    const response = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    let payload = {};
    try {
      payload = await response.json();
    } catch (_) {
      payload = {};
    }
    if (!response.ok) throw new Error(payload.error || `Request returned ${response.status}`);
    return payload;
  };

  const textCell = (value, className = "") => {
    const cell = document.createElement("td");
    cell.textContent = value;
    if (className) cell.className = className;
    return cell;
  };

  const kindLabel = (kind) => kind
    .split(/[- ]/)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");

  const tierLabel = (rating, tier) => {
    if (rating == null) return "Unrated";
    return tier || "Placing";
  };

  const rankLabel = (rank) => rank == null ? "Not ranked" : `#${number.format(rank)}`;

  const kdLabel = (kills, deaths) => {
    if (deaths === 0) return kills === 0 ? "0.00" : "∞";
    return (kills / deaths).toFixed(2);
  };

  const classLabel = (ratingClass, defaultClass) => {
    if (!ratingClass || ratingClass === defaultClass) return "Overall";
    return ratingClass.charAt(0).toUpperCase() + ratingClass.slice(1);
  };

  const showTableMessage = (tbody, message, columns) => {
    const row = document.createElement("tr");
    const cell = textCell(message, "table-message");
    cell.colSpan = columns;
    row.append(cell);
    tbody.replaceChildren(row);
  };

  const setupDirectory = () => {
    const form = document.querySelector("#pilot-filter");
    const input = document.querySelector("#pilot-search");
    const clear = document.querySelector("#pilot-clear");
    const tbody = document.querySelector("#pilot-rows");
    const range = document.querySelector("#pilot-range");
    const previous = document.querySelector("#pilot-previous");
    const next = document.querySelector("#pilot-next");
    if (!form || !input || !tbody || !range || !previous || !next) return;

    const params = new URLSearchParams(window.location.search);
    const state = {
      q: (params.get("q") || "").slice(0, 40),
      offset: 0,
      limit: 50,
      total: 0,
      request: 0,
    };
    input.value = state.q;
    clear.hidden = !state.q;

    const draw = (payload) => {
      const pilots = payload.pilots || [];
      const rows = pilots.map((pilot) => {
        const row = document.createElement("tr");
        row.append(textCell(rankLabel(pilot.rank), "rank-cell"));

        const identity = document.createElement("td");
        identity.className = "pilot-identity";
        const link = document.createElement("a");
        link.href = `/pilots/${encodeURIComponent(pilot.account)}`;
        link.textContent = pilot.name;
        const kind = document.createElement("span");
        kind.className = pilot.kind === "human" ? "pilot-kind" : "pilot-kind is-bot";
        kind.textContent = kindLabel(pilot.kind);
        identity.append(link, kind);
        row.append(identity);

        const tier = textCell(tierLabel(pilot.rating, pilot.tier), "tier-cell");
        if (pilot.class) {
          const ratingClass = document.createElement("span");
          ratingClass.textContent = classLabel(pilot.class, payload.default_class);
          tier.append(ratingClass);
        }
        row.append(tier);
        row.append(textCell(pilot.rating == null ? "Unrated" : number.format(Math.round(pilot.rating)), "number"));
        row.append(textCell(number.format(pilot.kills), "number"));
        row.append(textCell(number.format(pilot.deaths), "number"));
        row.append(textCell(number.format(pilot.assists), "number"));
        row.append(textCell(kdLabel(pilot.kills, pilot.deaths), "number"));
        row.append(textCell(number.format(pilot.games || 0), "number"));
        return row;
      });

      if (rows.length) {
        tbody.replaceChildren(...rows);
      } else {
        showTableMessage(tbody, state.q ? `No pilots match “${state.q}”.` : "No pilots have flown yet.", 9);
      }

      state.total = payload.total || 0;
      const first = state.total === 0 ? 0 : state.offset + 1;
      const last = Math.min(state.offset + pilots.length, state.total);
      range.textContent = state.total === 0
        ? "No pilots found."
        : `Showing ${number.format(first)} to ${number.format(last)} of ${number.format(state.total)} pilots.`;
      previous.disabled = state.offset === 0;
      next.disabled = state.offset + pilots.length >= state.total;
    };

    const load = async () => {
      const requestId = ++state.request;
      showTableMessage(tbody, "Loading pilots…", 9);
      range.textContent = "Loading pilots…";
      previous.disabled = true;
      next.disabled = true;
      try {
        const payload = await request("/v1/pilots", {
          q: state.q,
          offset: state.offset,
          limit: state.limit,
        });
        if (requestId !== state.request) return;
        draw(payload);
      } catch (error) {
        if (requestId !== state.request) return;
        showTableMessage(tbody, `Pilots could not be loaded. ${error.message}`, 9);
        range.textContent = "Pilot data is unavailable right now.";
      }
    };

    form.addEventListener("submit", (event) => {
      event.preventDefault();
      state.q = input.value.trim();
      state.offset = 0;
      clear.hidden = !state.q;
      const url = state.q ? `/pilots?q=${encodeURIComponent(state.q)}` : "/pilots";
      window.history.replaceState({}, "", url);
      load();
    });

    clear.addEventListener("click", () => {
      input.value = "";
      state.q = "";
      state.offset = 0;
      clear.hidden = true;
      window.history.replaceState({}, "", "/pilots");
      load();
      input.focus();
    });

    previous.addEventListener("click", () => {
      state.offset = Math.max(0, state.offset - state.limit);
      load();
    });

    next.addEventListener("click", () => {
      state.offset += state.limit;
      load();
    });

    load();
  };

  const setupProfile = () => {
    const parts = window.location.pathname.split("/").filter(Boolean);
    const fromPath = Number.parseInt(parts[parts.length - 1], 10);
    const fromQuery = Number.parseInt(new URLSearchParams(window.location.search).get("id"), 10);
    const account = Number.isSafeInteger(fromPath) ? fromPath : fromQuery;
    const name = document.querySelector("#profile-name");
    const status = document.querySelector("#profile-status");
    const scoreboard = document.querySelector("#profile-scoreboard");
    const ratingsSection = document.querySelector("#profile-ratings");
    const ratingsBody = document.querySelector("#profile-rating-rows");
    const cta = document.querySelector("#profile-cta");
    if (!name || !status || !scoreboard || !ratingsSection || !ratingsBody || !cta) return;

    if (!Number.isSafeInteger(account) || account < 1) {
      name.textContent = "Pilot not found";
      status.textContent = "This profile address does not name a pilot.";
      return;
    }

    request("/v1/pilot", { account })
      .then((payload) => {
        const pilot = payload.pilot;
        const ratings = pilot.ratings || [];
        const best = ratings[0] || null;
        name.textContent = pilot.name;
        document.title = `${pilot.name} / vectorwake`;
        const kind = document.querySelector("#profile-kind");
        kind.textContent = kindLabel(pilot.kind);
        kind.classList.toggle("is-bot", pilot.kind !== "human");
        status.hidden = true;

        document.querySelector("#profile-rank").textContent = rankLabel(best?.rank);
        document.querySelector("#profile-tier").textContent = tierLabel(best?.rating, best?.tier);
        document.querySelector("#profile-rating").textContent = best
          ? number.format(Math.round(best.rating))
          : "Unrated";
        document.querySelector("#profile-kills").textContent = number.format(pilot.kills);
        document.querySelector("#profile-deaths").textContent = number.format(pilot.deaths);
        document.querySelector("#profile-assists").textContent = number.format(pilot.assists);
        document.querySelector("#profile-kd").textContent = kdLabel(pilot.kills, pilot.deaths);
        document.querySelector("#profile-games").textContent = number.format(best?.games || 0);
        scoreboard.hidden = false;

        if (ratings.length) {
          const rows = ratings.map((rating) => {
            const row = document.createElement("tr");
            row.append(textCell(classLabel(rating.class, payload.default_class)));
            row.append(textCell(tierLabel(rating.rating, rating.tier), "tier-cell"));
            row.append(textCell(number.format(Math.round(rating.rating)), "number"));
            row.append(textCell(rankLabel(rating.rank), "number"));
            row.append(textCell(number.format(rating.games), "number"));
            return row;
          });
          ratingsBody.replaceChildren(...rows);
          ratingsSection.hidden = false;
        }
        cta.hidden = false;
      })
      .catch((error) => {
        name.textContent = "Pilot not found";
        status.textContent = error.message;
      });
  };

  if (page === "directory") setupDirectory();
  if (page === "profile") setupProfile();
})();
