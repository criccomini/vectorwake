"use strict";

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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

  const clips = [
    { start: 0.15, end: 4.45 },
    { start: 4.75, end: 9 },
    { start: 9.35, end: 13.65 },
  ];
  const crossfadeSeconds = 0.85;
  let active = 0;
  let clip = 0;
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
    clip = 0;
    crossing = false;
    videos.forEach((video, index) => {
      video.pause();
      video.classList.toggle("is-active", index === active);
    });
    videos[active].currentTime = clips[clip].start;
    try {
      await videos[active].play();
    } catch (_) {
      return;
    }

    const crossfade = async () => {
      if (crossing || token !== run) return;
      crossing = true;
      const next = 1 - active;
      const nextClip = (clip + 1) % clips.length;
      const outgoing = videos[active];
      const incoming = videos[next];
      incoming.currentTime = clips[nextClip].start;
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
        outgoing.currentTime = clips[clip].start;
        active = next;
        clip = nextClip;
        crossing = false;
      }, crossfadeSeconds * 1000);
    };

    const tick = () => {
      if (token !== run) return;
      if (videos[active].currentTime >= clips[clip].end - crossfadeSeconds) crossfade();
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
  setupGameplayFilm();
  setupGitHubStars();
  setupDiscordCount();
  setupReveals();
  setupHeader();
});
