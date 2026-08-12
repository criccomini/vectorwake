"use strict";

const COLORS = {
  bg: "#05070c",
  grid: "#121a26",
  friend: "#4fd6ff",
  enemy: "#ffa552",
  bomb: "#ff5ea8",
  ink: "#dfe9f5",
  dim: "#6c7a90",
};

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

function drawHull(ctx, hull, x, y, angle, scale, color, alpha = 1) {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(angle);
  ctx.scale(scale, -scale);
  ctx.beginPath();
  ctx.moveTo(hull.poly[0], hull.poly[1]);
  for (let i = 2; i < hull.poly.length; i += 2) {
    ctx.lineTo(hull.poly[i], hull.poly[i + 1]);
  }
  ctx.closePath();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = color === COLORS.friend ? "#0d2632" : "#2b1b12";
  ctx.strokeStyle = color;
  ctx.lineWidth = 0.65 / scale;
  ctx.shadowColor = color;
  ctx.shadowBlur = 7 / scale;
  ctx.fill();
  ctx.stroke();
  ctx.restore();
}

class BattleScene {
  constructor(canvas, quiet = false) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.quiet = quiet;
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.width = 0;
    this.height = 0;
    this.pointer = { x: 0, y: 0 };
    this.stars = Array.from({ length: quiet ? 50 : 130 }, (_, i) => ({
      x: ((i * 67 + 13) % 997) / 997,
      y: ((i * 149 + 71) % 991) / 991,
      z: 0.3 + ((i * 37) % 70) / 100,
    }));
    this.ships = quiet ? [] : [
      { x: 0.66, y: 0.37, vx: -2.5, vy: 1.5, hull: 0, a: -2.08, color: COLORS.friend, scale: 1.7 },
      { x: 0.79, y: 0.61, vx: -1.5, vy: -0.4, hull: 5, a: -1.78, color: COLORS.enemy, scale: 1.45 },
      { x: 0.57, y: 0.72, vx: 1.1, vy: -1.7, hull: 4, a: 0.48, color: COLORS.enemy, scale: 1.12 },
      { x: 0.88, y: 0.22, vx: -1.8, vy: 1.2, hull: 2, a: -2.3, color: COLORS.friend, scale: 0.72 },
    ];
    this.bolts = [];
    this.last = 0;
    this.spawnClock = 0;
    this.resize = this.resize.bind(this);
    this.frame = this.frame.bind(this);
    window.addEventListener("resize", this.resize, { passive: true });
    if (!quiet) {
      canvas.closest(".hero").addEventListener("pointermove", (event) => {
        const rect = canvas.getBoundingClientRect();
        this.pointer.x = event.clientX / rect.width - 0.5;
        this.pointer.y = event.clientY / rect.height - 0.5;
      }, { passive: true });
    }
    this.resize();
    if (reducedMotion) {
      this.render(0);
    } else {
      requestAnimationFrame(this.frame);
    }
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    this.width = Math.max(1, rect.width);
    this.height = Math.max(1, rect.height);
    this.canvas.width = Math.round(this.width * this.dpr);
    this.canvas.height = Math.round(this.height * this.dpr);
    this.ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
  }

  spawnBolt(time) {
    const origin = this.ships[Math.floor(time / 900) % this.ships.length];
    const speed = 280;
    this.bolts.push({
      x: origin.x * this.width,
      y: origin.y * this.height,
      vx: Math.cos(origin.a) * speed,
      vy: Math.sin(origin.a) * speed,
      color: origin.color === COLORS.friend ? COLORS.friend : COLORS.enemy,
      life: 1,
    });
  }

  frame(time) {
    const dt = Math.min((time - this.last) / 1000 || 0, 0.04);
    this.last = time;
    if (!document.hidden) {
      this.update(dt, time);
      this.render(time);
    }
    requestAnimationFrame(this.frame);
  }

  update(dt, time) {
    if (this.quiet) return;
    this.spawnClock += dt;
    if (this.spawnClock > 0.68) {
      this.spawnClock = 0;
      this.spawnBolt(time);
    }
    for (const ship of this.ships) {
      ship.x += ship.vx * dt / this.width;
      ship.y += ship.vy * dt / this.height;
      if (ship.x < 0.52) ship.x = 0.92;
      if (ship.x > 0.95) ship.x = 0.54;
      if (ship.y < 0.14) ship.y = 0.84;
      if (ship.y > 0.88) ship.y = 0.16;
    }
    this.bolts = this.bolts.filter((bolt) => {
      bolt.x += bolt.vx * dt;
      bolt.y += bolt.vy * dt;
      bolt.life -= dt * 0.72;
      return bolt.life > 0 && bolt.x > -80 && bolt.x < this.width + 80 && bolt.y > -80 && bolt.y < this.height + 80;
    });
  }

  render(time) {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.width, this.height);
    ctx.fillStyle = COLORS.bg;
    ctx.fillRect(0, 0, this.width, this.height);

    const gridSize = this.quiet ? 96 : 82;
    const offsetX = this.pointer.x * 8;
    const offsetY = this.pointer.y * 8;
    ctx.strokeStyle = this.quiet ? "#101722" : COLORS.grid;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.52;
    for (let x = (offsetX % gridSize) - gridSize; x < this.width + gridSize; x += gridSize) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, this.height);
      ctx.stroke();
    }
    for (let y = (offsetY % gridSize) - gridSize; y < this.height + gridSize; y += gridSize) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(this.width, y);
      ctx.stroke();
    }

    for (const star of this.stars) {
      const x = ((star.x * this.width) + this.pointer.x * star.z * -20 + this.width) % this.width;
      const y = ((star.y * this.height) + this.pointer.y * star.z * -20 + this.height) % this.height;
      ctx.globalAlpha = 0.2 + star.z * 0.55;
      ctx.fillStyle = star.z > 0.75 ? "#93a9c8" : "#4a6089";
      ctx.fillRect(x, y, star.z > 0.75 ? 1.5 : 1, star.z > 0.75 ? 1.5 : 1);
    }

    if (!this.quiet) {
      ctx.globalAlpha = 1;
      for (const bolt of this.bolts) {
        ctx.save();
        ctx.globalAlpha = Math.max(0, bolt.life);
        ctx.strokeStyle = bolt.color;
        ctx.shadowColor = bolt.color;
        ctx.shadowBlur = 10;
        ctx.lineWidth = 2.2;
        ctx.beginPath();
        ctx.moveTo(bolt.x, bolt.y);
        ctx.lineTo(bolt.x - bolt.vx * 0.08, bolt.y - bolt.vy * 0.08);
        ctx.stroke();
        ctx.restore();
      }
      this.ships.forEach((ship, index) => {
        const bob = Math.sin(time / 1100 + index) * 2;
        drawHull(ctx, HULLS[ship.hull], ship.x * this.width + offsetX * 0.5, ship.y * this.height + offsetY * 0.5 + bob, ship.a - Math.PI / 2, ship.scale, ship.color, index === 2 ? 0.7 : 1);
      });
    } else {
      ctx.save();
      ctx.globalAlpha = 0.7;
      ctx.strokeStyle = COLORS.friend;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(this.width * 0.78, this.height * 0.52, Math.min(this.width, this.height) * 0.2, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }
    ctx.globalAlpha = 1;
  }
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
  const film = document.querySelector("[data-gameplay]");
  if (!film) return;

  const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
  if (reducedMotion || connection?.saveData) return;

  const videos = [...film.querySelectorAll("[data-gameplay-take]")];
  if (videos.length !== 2) return;

  const clipStart = 0.3;
  const clipEnd = 5.2;
  const crossfadeSeconds = 0.85;
  let active = 0;
  let crossing = false;
  let frame;
  let run = 0;
  let loadPromise;
  let objectUrl;

  const load = () => {
    if (loadPromise) return loadPromise;
    loadPromise = fetch(film.dataset.src)
      .then((response) => {
        if (!response.ok) throw new Error(`Gameplay film returned ${response.status}`);
        return response.blob();
      })
      .then((blob) => {
        objectUrl = URL.createObjectURL(blob);
        const ready = videos.map((video) => new Promise((resolve, reject) => {
          video.addEventListener("loadeddata", resolve, { once: true });
          video.addEventListener("error", reject, { once: true });
          video.src = objectUrl;
          video.load();
        }));
        return Promise.all(ready);
      });
    return loadPromise;
  };

  const stop = () => {
    run += 1;
    cancelAnimationFrame(frame);
    videos.forEach((video) => video.pause());
  };

  const start = async () => {
    const token = ++run;
    try {
      await load();
    } catch (_) {
      return;
    }
    if (token !== run) return;

    active = 0;
    crossing = false;
    videos.forEach((video, index) => {
      video.pause();
      video.classList.toggle("is-active", index === active);
    });
    videos[active].currentTime = clipStart;
    try {
      await videos[active].play();
    } catch (_) {
      return;
    }

    const crossfade = async () => {
      if (crossing || token !== run) return;
      crossing = true;
      const next = 1 - active;
      const outgoing = videos[active];
      const incoming = videos[next];
      incoming.currentTime = clipStart;
      try {
        await incoming.play();
      } catch (_) {
        crossing = false;
        return;
      }
      if (token !== run) {
        incoming.pause();
        return;
      }
      incoming.classList.add("is-active");
      outgoing.classList.remove("is-active");
      window.setTimeout(() => {
        if (token !== run) return;
        outgoing.pause();
        outgoing.currentTime = clipStart;
        active = next;
        crossing = false;
      }, crossfadeSeconds * 1000);
    };

    const tick = () => {
      if (token !== run) return;
      if (videos[active].currentTime >= clipEnd - crossfadeSeconds) crossfade();
      frame = requestAnimationFrame(tick);
    };
    tick();
  };

  if (!("IntersectionObserver" in window)) {
    start();
    return;
  }

  const observer = new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) {
      start();
    } else {
      stop();
    }
  }, { threshold: 0.1 });
  observer.observe(film);
  window.addEventListener("pagehide", () => {
    stop();
    if (objectUrl) URL.revokeObjectURL(objectUrl);
  }, { once: true });
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
        localStorage.setItem(cacheKey, JSON.stringify({
          count,
          savedAt: Date.now(),
        }));
      } catch (_) {
        return;
      }
    })
    .catch(() => {})
    .finally(() => window.clearTimeout(timeout));
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-cta-field]").forEach((canvas) => new BattleScene(canvas, true));
  setupGameplayFilm();
  setupGitHubStars();
  setupDiscordCount();
  setupHullSelector();
  setupEnergyDemo();
  setupReveals();
  setupHeader();
});
