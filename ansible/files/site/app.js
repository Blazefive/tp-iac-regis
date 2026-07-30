// Same-origin only. No fetch, no third party, no cookie, and nothing here
// reports anything about the host it runs on.
"use strict";

// ---- Footer year ---------------------------------------------------------

document.getElementById("year").textContent = String(new Date().getFullYear());

// ---- Theme -----------------------------------------------------------------

// Three states rather than two: "auto" defers to the operating system, the other
// two override it. Persisted so a reload keeps the choice.
const THEMES = ["auto", "light", "dark"];
const LABELS = { auto: "Thème : auto", light: "Thème : clair", dark: "Thème : sombre" };
const root = document.documentElement;
const toggle = document.getElementById("theme-toggle");

function readStored() {
  try {
    return localStorage.getItem("theme");
  } catch {
    return null; // Private browsing can deny storage; the toggle still works.
  }
}

function applyTheme(name) {
  root.setAttribute("data-theme", name);
  toggle.textContent = LABELS[name];
  try {
    localStorage.setItem("theme", name);
  } catch {
    /* ignored on purpose */
  }
}

applyTheme(THEMES.includes(readStored()) ? readStored() : "auto");

toggle.addEventListener("click", () => {
  const current = root.getAttribute("data-theme");
  applyTheme(THEMES[(THEMES.indexOf(current) + 1) % THEMES.length]);
});

// ---- Reveal on scroll ------------------------------------------------------

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealables = document.querySelectorAll(".reveal");

if (reduceMotion || !("IntersectionObserver" in window)) {
  // No animation wanted, or no support: show everything straight away rather
  // than leaving content permanently invisible.
  revealables.forEach((element) => element.classList.add("is-visible"));
} else {
  const revealer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        revealer.unobserve(entry.target); // once is enough
      });
    },
    { rootMargin: "0px 0px -10% 0px", threshold: 0.05 }
  );

  revealables.forEach((element) => revealer.observe(element));
}

// ---- Current section in the nav -------------------------------------------

const links = [...document.querySelectorAll(".bar nav a")];
const sections = links
  .map((link) => document.querySelector(link.getAttribute("href")))
  .filter(Boolean);

if ("IntersectionObserver" in window && sections.length) {
  const tracker = new IntersectionObserver(
    (entries) => {
      entries
        .filter((entry) => entry.isIntersecting)
        .forEach((entry) => {
          links.forEach((link) => {
            const active = link.getAttribute("href") === `#${entry.target.id}`;
            // aria-current, not a class: the state is announced to assistive
            // technology and styled from the same attribute.
            if (active) link.setAttribute("aria-current", "true");
            else link.removeAttribute("aria-current");
          });
        });
    },
    { rootMargin: "-45% 0px -50% 0px" }
  );

  sections.forEach((section) => tracker.observe(section));
}
