"use strict";

const HULLS = [
  {
    name: "Apex",
    role: "Interceptor",
    copy: "Fast enough to catch anything. Thin enough to regret it.",
    stats: ["SPD 4900", "ROT 420"],
    poly: [0,21, 1.6,12, 2.6,5, 6.5,-1, 11,-9, 8.5,-11.5, 3.5,-6.5, 3,-10.5, 0,-11.5, -3,-10.5, -3.5,-6.5, -8.5,-11.5, -11,-9, -6.5,-1, -2.6,5, -1.6,12],
  },
  {
    name: "Wedge",
    role: "Bomber",
    copy: "Put a bomb down the corridor before anyone can leave.",
    stats: ["BMB L2", "NRG 1450"],
    poly: [0,14, 2.6,13, 4.6,7.5, 7.2,1.5, 15.5,-5.5, 16,-9, 9,-7.5, 8,-11, 3.2,-12.5, 0,-12.5, -3.2,-12.5, -8,-11, -9,-7.5, -16,-9, -15.5,-5.5, -7.2,1.5, -4.6,7.5, -2.6,13],
  },
  {
    name: "Chord",
    role: "Skirmisher",
    copy: "See them first, then keep firing after they stop.",
    stats: ["RCH 700", "GUN MULTI"],
    poly: [0,13.5, 5.5,12, 11.5,7.5, 16.5,0.5, 18,-4, 14.5,-6, 11,-2.5, 6.5,1.5, 2.5,3.5, 0,3.8, -2.5,3.5, -6.5,1.5, -11,-2.5, -14.5,-6, -18,-4, -16.5,0.5, -11.5,7.5, -5.5,12],
  },
  {
    name: "Anvil",
    role: "Heavy",
    copy: "A fortress with a bad turning circle.",
    stats: ["NRG 2600", "BMB L3"],
    poly: [0,15, 6.5,14.2, 11,10, 13.5,3, 13.5,-4, 11,-9.5, 6.5,-12, 0,-12, -6.5,-12, -11,-9.5, -13.5,-4, -13.5,3, -11,10, -6.5,14.2],
  },
  {
    name: "Cipher",
    role: "Stealth",
    copy: "Pick one target and plan the exit before you fire.",
    stats: ["GUN L3", "SIDE 6"],
    poly: [0,23, 1.7,7, 3.4,-2, 3,-9, 6.5,-12.5, 2.2,-11.5, 1.6,-13, 0,-13, -1.6,-13, -2.2,-11.5, -6.5,-12.5, -3,-9, -3.4,-2, -1.7,7],
  },
  {
    name: "Facet",
    role: "Brawler",
    copy: "Get inside two tiles and stay there.",
    stats: ["GUN L2×2", "THR 27"],
    poly: [0,15, 4.2,10.5, 8.5,6, 11.5,-2, 9.5,-10, 4.5,-13, 0,-13, -4.5,-13, -9.5,-10, -11.5,-2, -8.5,6, -4.2,10.5],
  },
  {
    name: "Lattice",
    role: "Denial",
    copy: "Turn the map into the weapon.",
    stats: ["MINE L2", "NRG 1900"],
    poly: [0,17, 2.8,12.5, 2.8,5.5, 11.5,4.5, 15,1.5, 11.5,-1.5, 2.8,-2.5, 2.8,-11, 2,-14, 0,-14, -2,-14, -2.8,-11, -2.8,-2.5, -11.5,-1.5, -15,1.5, -11.5,4.5, -2.8,5.5, -2.8,12.5],
  },
];

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function polygonPoints(poly) {
  const points = [];
  for (let i = 0; i < poly.length; i += 2) {
    points.push(`${poly[i]},${-poly[i + 1]}`);
  }
  return points.join(" ");
}

function setupHullSelector() {
  const stage = document.querySelector("[data-hull-stage]");
  const selector = document.querySelector("[data-hull-selector]");
  if (!stage || !selector) return;

  const name = document.querySelector("[data-hull-name]");
  const role = document.querySelector("[data-hull-role]");
  const copy = document.querySelector("[data-hull-copy]");
  const number = document.querySelector("[data-hull-number]");
  const statOne = document.querySelector("[data-hull-stat-one]");
  const statTwo = document.querySelector("[data-hull-stat-two]");

  const select = (index) => {
    const hull = HULLS[index];
    const points = polygonPoints(hull.poly);
    stage.innerHTML = `
      <svg viewBox="-30 -30 60 60" role="img" aria-label="${hull.name}, ${hull.role} hull">
        <defs>
          <linearGradient id="hull-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#183848"/>
            <stop offset="1" stop-color="#070b12"/>
          </linearGradient>
        </defs>
        <line class="hull-axis" x1="0" y1="-29" x2="0" y2="29"/>
        <line class="hull-axis" x1="-29" y1="0" x2="29" y2="0"/>
        <polygon class="hull-ghost" points="${points}" transform="scale(1.18)"/>
        <polygon class="hull-body" points="${points}"/>
      </svg>`;
    name.textContent = hull.name;
    role.textContent = hull.role;
    copy.textContent = hull.copy;
    number.textContent = `${String(index + 1).padStart(2, "0")} / ${String(HULLS.length).padStart(2, "0")}`;
    statOne.textContent = hull.stats[0];
    statTwo.textContent = hull.stats[1];
    selector.querySelectorAll("button").forEach((button, buttonIndex) => {
      button.setAttribute("aria-pressed", String(buttonIndex === index));
    });
  };

  HULLS.forEach((hull, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = `${String(index + 1).padStart(2, "0")} ${hull.name}`;
    button.setAttribute("aria-pressed", String(index === 0));
    button.addEventListener("click", () => select(index));
    selector.appendChild(button);
  });
  select(0);
}

function setupEnergyDemo() {
  const instrument = document.querySelector("[data-energy-demo]");
  const trigger = document.querySelector("[data-fire]");
  const reset = document.querySelector("[data-energy-reset]");
  const value = document.querySelector("[data-energy-value]");
  const bar = document.querySelector("[data-energy-bar]");
  const state = document.querySelector("[data-energy-state]");
  const field = document.querySelector("[data-shot-field]");
  if (!instrument || !trigger || !reset || !value || !bar || !state || !field) return;

  const maximum = 1350;
  let energy = maximum;
  let rechargeTimer;

  const paint = () => {
    const ratio = energy / maximum;
    value.textContent = String(energy);
    bar.style.width = `${Math.max(0, ratio * 100)}%`;
    instrument.classList.toggle("is-low", ratio <= 0.42 && ratio > 0.16);
    instrument.classList.toggle("is-empty", ratio <= 0.16);
    state.textContent = ratio <= 0.16 ? "Exposed" : ratio <= 0.42 ? "Low" : "Armed";
  };

  const recharge = () => {
    window.clearInterval(rechargeTimer);
    rechargeTimer = window.setInterval(() => {
      if (energy >= maximum) {
        window.clearInterval(rechargeTimer);
        return;
      }
      energy = Math.min(maximum, energy + 15);
      paint();
    }, 90);
  };

  trigger.addEventListener("click", () => {
    if (energy < 360) {
      state.textContent = "Dry";
      instrument.animate([
        { transform: "translateX(0)" },
        { transform: "translateX(-4px)" },
        { transform: "translateX(4px)" },
        { transform: "translateX(0)" },
      ], { duration: 180 });
      return;
    }
    energy -= 360;
    paint();
    if (!reducedMotion) {
      const shot = document.createElement("span");
      shot.className = "demo-shot";
      field.appendChild(shot);
      shot.addEventListener("animationend", () => shot.remove(), { once: true });
    }
    recharge();
  });

  reset.addEventListener("click", () => {
    window.clearInterval(rechargeTimer);
    energy = maximum;
    paint();
  });
}

function setupReveals() {
  const reveals = document.querySelectorAll(".reveal");
  if (reducedMotion) {
    reveals.forEach((element) => element.classList.add("is-visible"));
    return;
  }
  const waiting = new Set(reveals);
  let scheduled = false;
  const check = () => {
    waiting.forEach((element) => {
      const box = element.getBoundingClientRect();
      if (box.top < window.innerHeight * 0.92 && box.bottom > 0) {
        element.classList.add("is-visible");
        waiting.delete(element);
      }
    });
    scheduled = false;
  };
  const schedule = () => {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(check);
    }
  };
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule, { passive: true });
  schedule();
}

function setupHeader() {
  const header = document.querySelector("[data-header]");
  if (!header) return;
  let scheduled = false;
  const update = () => {
    header.classList.toggle("is-scrolled", window.scrollY > 40);
    scheduled = false;
  };
  window.addEventListener("scroll", () => {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(update);
    }
  }, { passive: true });
  update();
}

function setupGameplayFilm() {
  const video = document.querySelector("[data-gameplay]");
  if (!video) return;

  const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
  if (reducedMotion || connection?.saveData) return;

  video.src = video.dataset.src;
  const play = () => video.play().catch(() => {});
  if (!("IntersectionObserver" in window)) {
    play();
    return;
  }

  const observer = new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) {
      play();
    } else {
      video.pause();
    }
  }, { threshold: 0.1 });
  observer.observe(video);
}

function setupGitHubStars() {
  const counts = document.querySelectorAll("[data-github-count]");
  const links = document.querySelectorAll("[data-github-link]");
  if (!counts.length) return;

  const cacheKey = "vectorwake-github-stars";
  const cacheAge = 6 * 60 * 60 * 1000;
  const formatter = new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 1,
  });

  const paint = (count) => {
    counts.forEach((element) => {
      element.textContent = formatter.format(count);
      element.closest(".github-stars").hidden = count < 10;
    });
    links.forEach((link) => {
      const countLabel = count >= 10 ? `, ${count.toLocaleString("en-US")} stars` : "";
      link.setAttribute("aria-label", `Vectorwake on GitHub${countLabel}`);
    });
  };

  let cached;
  try {
    cached = JSON.parse(localStorage.getItem(cacheKey));
  } catch (_) {
    cached = null;
  }

  if (Number.isInteger(cached?.count)) {
    paint(cached.count);
    if (Date.now() - cached.savedAt < cacheAge) return;
  }

  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 4000);
  fetch("https://api.github.com/repos/criccomini/vectorwake", { signal: controller.signal })
    .then((response) => {
      if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
      return response.json();
    })
    .then((repository) => {
      if (!Number.isInteger(repository.stargazers_count)) return;
      paint(repository.stargazers_count);
      try {
        localStorage.setItem(cacheKey, JSON.stringify({
          count: repository.stargazers_count,
          savedAt: Date.now(),
        }));
      } catch (_) {
        return;
      }
    })
    .catch(() => {})
    .finally(() => window.clearTimeout(timeout));
}

function setupDiscordCount() {
  const counts = document.querySelectorAll("[data-discord-count]");
  const links = document.querySelectorAll("[data-discord-link]");
  if (!counts.length) return;

  const cacheKey = "vectorwake-discord-members";
  const cacheAge = 6 * 60 * 60 * 1000;
  const paint = (count) => {
    counts.forEach((element) => {
      element.textContent = count.toLocaleString("en-US");
      element.closest(".discord-members").hidden = count < 10;
    });
    links.forEach((link) => {
      const countLabel = count >= 10 ? `, ${count.toLocaleString("en-US")} members` : "";
      link.setAttribute("aria-label", `Join Vectorwake on Discord${countLabel}`);
    });
  };

  let cached;
  try {
    cached = JSON.parse(localStorage.getItem(cacheKey));
  } catch (_) {
    cached = null;
  }

  if (Number.isInteger(cached?.count)) {
    paint(cached.count);
    if (Date.now() - cached.savedAt < cacheAge) return;
  }

  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 4000);
  fetch("https://discord.com/api/v10/invites/jyb4YBcY5Z?with_counts=true", { signal: controller.signal })
    .then((response) => {
      if (!response.ok) throw new Error(`Discord returned ${response.status}`);
      return response.json();
    })
    .then((invite) => {
      const count = invite.approximate_member_count ?? invite.profile?.member_count;
      if (!Number.isInteger(count)) return;
      paint(count);
      try {
        localStorage.setItem(cacheKey, JSON.stringify({ count, savedAt: Date.now() }));
      } catch (_) {
        return;
      }
    })
    .catch(() => {})
    .finally(() => window.clearTimeout(timeout));
}

document.addEventListener("DOMContentLoaded", () => {
  setupGameplayFilm();
  setupGitHubStars();
  setupDiscordCount();
  setupHullSelector();
  setupEnergyDemo();
  setupReveals();
  setupHeader();
});
