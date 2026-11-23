// Kiri's website. Two small things, both optional: the page works without them.

// 1. The download buttons point at the latest release's disk image. Without
//    this (or if GitHub's API is unreachable) they open the latest release's
//    page, which has the same file on it.
(async () => {
  try {
    const res = await fetch("https://api.github.com/repos/ErikHellman/kiri/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return;
    const release = await res.json();
    const dmg = (release.assets || []).find((a) => a.name.endsWith(".dmg"));
    if (dmg) {
      for (const a of document.querySelectorAll(".js-download")) a.href = dmg.browser_download_url;
    }
    const version = (release.tag_name || "").replace(/^v/, "");
    if (version) {
      for (const el of document.querySelectorAll(".js-version")) el.textContent = `Version ${version}, free`;
    }
  } catch {
    // Keep the links to the release page.
  }
})();

// 2. The theme picker shows Kiri in the theme chosen, when there is a picture
//    of it (assets/themes/<id>-light.webp, or -dark in dark mode); otherwise
//    the picture of all six stays.
const blurbs = {
  honey: "Warm cream and amber. Kiri's own.",
  matcha: "Green tea and rice paper.",
  sakura: "Cherry blossom on soft blush.",
  tide: "Sea glass and deep water.",
  lavender: "Dusky violet and lilac.",
  graphite: "Quiet greys, one blue accent.",
};
const picture = document.querySelector(".js-theme-shot");
const blurb = document.querySelector(".js-theme-blurb");
const buttons = [...document.querySelectorAll(".theme")];
const dark = matchMedia("(prefers-color-scheme: dark)");
const reduce = matchMedia("(prefers-reduced-motion: reduce)");
let chosen = null;

function show(id) {
  chosen = id;
  for (const b of buttons) b.setAttribute("aria-checked", String(b.dataset.theme === id));
  blurb.textContent = blurbs[id];
  const src = `assets/themes/${id}-${dark.matches ? "dark" : "light"}.webp`;
  const next = new Image();
  next.onload = () => {
    if (chosen !== id) return;
    const swap = () => {
      picture.src = src;
      picture.alt = `Kiri in the ${id[0].toUpperCase() + id.slice(1)} theme`;
      picture.classList.remove("fading");
    };
    if (reduce.matches) return swap();
    picture.classList.add("fading");
    setTimeout(swap, 200);
  };
  next.src = src;
}

for (const b of buttons) b.addEventListener("click", () => show(b.dataset.theme));
// Arrow keys move between the radios, as in a native radio group.
document.querySelector(".themes").addEventListener("keydown", (e) => {
  const i = buttons.indexOf(document.activeElement);
  if (i < 0) return;
  const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
  if (!step) return;
  e.preventDefault();
  const b = buttons[(i + step + buttons.length) % buttons.length];
  b.focus();
  show(b.dataset.theme);
});
dark.addEventListener("change", () => chosen && show(chosen));
// Start on Honey, if its picture is there.
show("honey");
