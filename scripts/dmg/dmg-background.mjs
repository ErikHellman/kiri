// The picture behind Kiri's disk image window: warm Honey paper, two frosted
// glass cushions for the icons, and a little bee flying a dotted trail from
// Kiri to Applications. Colors are Honey tokens (KiriKit Honey.swift, light).
//
// Usage: node scripts/dmg/dmg-background.mjs [--preview]
// Writes scripts/dmg/background.svg (the source of truth), background.png
// (660 x 420) and background@2x.png with Playwright (npm i -D playwright, or
// any global install). --preview also writes build/dmg-preview.png: the
// background in a mock Finder window with the real icons, for a quick look.
//
// The geometry here must match scripts/dmg/settings.py (window size, icon
// positions, icon size and label size).
import { writeFileSync, readFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");

export const W = 660, H = 392;
export const ICON = 128;                 // icon_size in settings.py
export const kiri = { x: 170, y: 204 };  // icon centers, in points
export const apps = { x: 490, y: 204 };

const C = {
  canvas: "#F5EEE1", surface: "#FFFCF6", surface2: "#F2E8D6", line: "#E8DAC3",
  fg: "#3B2A2F", muted: "#76615A", accent: "#E09A2D", accentHi: "#F6C25E",
  ink: "#995A05", soft: "#FBE7C2", focus: "#B8700E", glow: "#FFF7E6",
  // Name tags: a caramel that both Finder label colors read on (black text in
  // light mode about 5:1, white text in dark mode about 4:1).
  tag: "#AE6F22", tagHi: "#C3842F",
};

const font = (w) => {
  const b64 = readFileSync(join(repo, `KiriKit/Sources/KiriKit/Fonts/Nunito-${w}.ttf`)).toString("base64");
  return `@font-face{font-family:NunitoK;font-weight:${w};src:url(data:font/ttf;base64,${b64})}`;
};

function hex(cx, cy, r, rot = -90) {
  const p = [];
  for (let i = 0; i < 6; i++) {
    const t = ((rot + i * 60) * Math.PI) / 180;
    p.push(`${(cx + r * Math.cos(t)).toFixed(2)},${(cy + r * Math.sin(t)).toFixed(2)}`);
  }
  return "M" + p.join("L") + "Z";
}

// A patch of honeycomb, faded out by a radial mask, for two corners.
function comb(cx, cy, cols, rows, r) {
  let d = "";
  const dx = r * Math.sqrt(3), dy = r * 1.5;
  for (let row = 0; row < rows; row++)
    for (let col = 0; col < cols; col++)
      d += hex(cx + col * dx + (row % 2 ? dx / 2 : 0), cy + row * dy, r - 2.2);
  return d;
}

// Points along a cubic Bézier, evenly spaced by arc length (for the dots).
function cubicDots(p0, p1, p2, p3, gap) {
  const at = (t) => {
    const u = 1 - t;
    return [
      u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
      u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    ];
  };
  const samples = [];
  let len = 0, prev = at(0);
  for (let i = 0; i <= 2000; i++) {
    const p = at(i / 2000);
    len += Math.hypot(p[0] - prev[0], p[1] - prev[1]);
    samples.push({ p, len });
    prev = p;
  }
  const dots = [];
  for (let s = 0, j = 0; s <= len; s += gap) {
    while (j < samples.length - 1 && samples[j].len < s) j++;
    dots.push({ p: samples[j].p, f: s / len });
  }
  return dots;
}

// The bee, facing right, about 44 pt long, drawn around (0, 0).
const bee = `
<g>
  <path d="M-15,1 Q-25,1 -27,4 Q-22,6 -15,6Z" fill="${C.fg}" opacity="0.9"/>
  <g opacity="0.92">
    <ellipse cx="-3" cy="-14" rx="9" ry="13" transform="rotate(-28 -3 -14)" fill="#FFFFFF" fill-opacity="0.78" stroke="#FFFFFF" stroke-width="1.2"/>
    <ellipse cx="6" cy="-13" rx="7" ry="11" transform="rotate(18 6 -13)" fill="#FFFFFF" fill-opacity="0.7" stroke="#FFFFFF" stroke-width="1.2"/>
    <path d="M-3,-4 Q-5,-15 -8,-22 M6,-4 Q7,-13 9,-19" stroke="${C.line}" stroke-width="0.8" fill="none"/>
  </g>
  <clipPath id="beeBody"><ellipse cx="0" cy="3" rx="16" ry="11.5"/></clipPath>
  <ellipse cx="0" cy="3" rx="16" ry="11.5" fill="url(#beeG)"/>
  <g clip-path="url(#beeBody)" fill="${C.fg}">
    <rect x="-9" y="-10" width="5" height="26" rx="2"/>
    <rect x="1" y="-10" width="5" height="26" rx="2"/>
  </g>
  <ellipse cx="-2" cy="-3" rx="8" ry="3" fill="#FFFFFF" opacity="0.45"/>
  <circle cx="17" cy="1" r="8.5" fill="${C.fg}"/>
  <circle cx="20" cy="-1.5" r="2.4" fill="#FFFFFF"/>
  <circle cx="20.6" cy="-1.8" r="1.2" fill="${C.fg}"/>
  <path d="M17.5,4.5 Q20.5,7.2 23.5,4.2" stroke="#FFFFFF" stroke-width="1.3" stroke-linecap="round" fill="none"/>
  <circle cx="23.2" cy="2.4" r="1.6" fill="#F08BC0" opacity="0.7"/>
  <path d="M15,-7 Q15,-14 11,-17 M19,-6.5 Q22,-13 26,-14.5" stroke="${C.fg}" stroke-width="1.5" stroke-linecap="round" fill="none"/>
  <circle cx="11" cy="-17" r="1.7" fill="${C.fg}"/><circle cx="26" cy="-14.5" r="1.7" fill="${C.fg}"/>
</g>`;

export function backgroundSVG() {
  const cushion = (c) => {
    const s = 168, r = 44;
    return `
    <g filter="url(#cushionShadow)">
      <rect x="${c.x - s / 2}" y="${c.y - s / 2 - 6}" width="${s}" height="${s}" rx="${r}" fill="url(#glassG)"/>
    </g>
    <rect x="${c.x - s / 2 + 0.75}" y="${c.y - s / 2 - 5.25}" width="${s - 1.5}" height="${s - 1.5}" rx="${r - 0.75}" fill="none" stroke="url(#glassEdge)" stroke-width="1.5"/>
    <ellipse cx="${c.x}" cy="${c.y + 58}" rx="50" ry="7" fill="${C.focus}" opacity="0.12" filter="url(#blur6)"/>`;
  };
  // Finder draws the name centered under the icon; the tag sits behind it.
  const tag = (c, w) => `
    <rect x="${c.x - w / 2}" y="${c.y + ICON / 2 + 8}" width="${w}" height="22" rx="11" fill="url(#tagG)"/>
    <rect x="${c.x - w / 2 + 0.5}" y="${c.y + ICON / 2 + 8.5}" width="${w - 1}" height="21" rx="10.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.28"/>`;

  // The trail: from Kiri's cushion, up in an arc, down into Applications.
  const p0 = [kiri.x + 92, kiri.y - 16], p1 = [kiri.x + 140, kiri.y - 92];
  const p2 = [apps.x - 168, apps.y - 100], p3 = [apps.x - 138, apps.y - 30];
  const dots = cubicDots(p0, p1, p2, p3, 9.5).slice(0, -1);
  const trail = dots.map(({ p, f }) =>
    `<circle cx="${p[0].toFixed(2)}" cy="${p[1].toFixed(2)}" r="${(1.6 + f * 1.3).toFixed(2)}" fill="${C.accent}" opacity="${(0.35 + f * 0.6).toFixed(2)}"/>`).join("");
  const beeAt = { x: p3[0] + 14, y: p3[1] + 18 };

  // Little honey hexes floating about, like confetti.
  const sprinkles = [
    [96, 64, 6, C.accent, 0.35, 12], [574, 58, 5, C.accent, 0.4, -8], [610, 104, 3.5, C.ink, 0.25, 20],
    [58, 128, 3.5, C.ink, 0.22, 0], [330, 312, 4, C.accent, 0.3, 10], [612, 312, 6, C.accentHi, 0.45, -14],
    [44, 330, 5, C.accentHi, 0.45, 6], [200, 40, 3, C.accent, 0.3, 0], [470, 30, 3.5, C.accentHi, 0.5, 15],
  ].map(([x, y, r, c, o, rot]) => `<path d="${hex(x, y, r, -90 + rot)}" fill="${c}" opacity="${o}"/>`).join("");

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">
<defs>
  <style>${font(600)}${font(800)}</style>
  <linearGradient id="paper" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FBF5EA"/><stop offset="1" stop-color="${C.canvas}"/>
  </linearGradient>
  <radialGradient id="sun" cx="0.18" cy="0.05" r="0.75">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="warm" cx="0.92" cy="1.05" r="0.7">
    <stop offset="0" stop-color="${C.soft}" stop-opacity="0.95"/><stop offset="1" stop-color="${C.soft}" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="combFadeTR" cx="1" cy="0" r="0.32">
    <stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="combFadeBL" cx="0" cy="1" r="0.3">
    <stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>
  <mask id="combTR"><rect width="${W}" height="${H}" fill="url(#combFadeTR)"/></mask>
  <mask id="combBL"><rect width="${W}" height="${H}" fill="url(#combFadeBL)"/></mask>
  <linearGradient id="glassG" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.78"/><stop offset="1" stop-color="${C.surface}" stop-opacity="0.5"/>
  </linearGradient>
  <linearGradient id="glassEdge" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.2"/>
    <stop offset="1" stop-color="${C.line}" stop-opacity="0.9"/>
  </linearGradient>
  <linearGradient id="tagG" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${C.tagHi}"/><stop offset="1" stop-color="${C.tag}"/>
  </linearGradient>
  <linearGradient id="beeG" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${C.accentHi}"/><stop offset="1" stop-color="${C.accent}"/>
  </linearGradient>
  <filter id="cushionShadow" x="-30%" y="-30%" width="160%" height="170%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="8" result="o"/>
    <feFlood flood-color="#7A4A10" flood-opacity="0.14"/><feComposite in2="o" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="beeShadow" x="-50%" y="-50%" width="200%" height="200%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="2.5"/><feOffset dy="3" result="o"/>
    <feFlood flood-color="#7A4A10" flood-opacity="0.25"/><feComposite in2="o" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="blur6"><feGaussianBlur stdDeviation="6"/></filter>
</defs>

<rect width="${W}" height="${H}" fill="url(#paper)"/>
<rect width="${W}" height="${H}" fill="url(#warm)"/>
<rect width="${W}" height="${H}" fill="url(#sun)"/>
<path d="${comb(470, -8, 9, 7, 17)}" fill="none" stroke="${C.accent}" stroke-opacity="0.22" stroke-width="1.4" mask="url(#combTR)"/>
<path d="${comb(-20, 300, 7, 6, 17)}" fill="none" stroke="${C.accent}" stroke-opacity="0.2" stroke-width="1.4" mask="url(#combBL)"/>
${sprinkles}

<text x="${W / 2}" y="58" text-anchor="middle" font-family="NunitoK" font-weight="800" font-size="25" fill="${C.fg}" letter-spacing="-0.2">Kiri is almost home</text>
<text x="${W / 2}" y="84" text-anchor="middle" font-family="NunitoK" font-weight="600" font-size="14" fill="${C.muted}">Drag it into Applications and you’re all set.</text>

${cushion(kiri)}${cushion(apps)}
${tag(kiri, 46)}${tag(apps, 94)}

${trail}
<g transform="translate(${beeAt.x} ${beeAt.y}) rotate(30) scale(1.08)" filter="url(#beeShadow)">${bee}</g>

<text x="${W / 2}" y="${H - 24}" text-anchor="middle" font-family="NunitoK" font-weight="600" font-size="12" fill="${C.muted}">Then open Kiri and press <tspan font-weight="800" fill="${C.ink}">⌘K</tspan> to find anything</text>
</svg>
`;
}

async function launch() {
  try { return (await import("playwright")).chromium; } catch {
    return (await import("node:module")).createRequire(import.meta.url)("playwright").chromium;
  }
}

const svg = backgroundSVG();
writeFileSync(join(here, "background.svg"), svg);
console.log("wrote scripts/dmg/background.svg");

const chromium = await launch();
const browser = await chromium.launch();
const html = (body, w, h) => `<html><body style="margin:0;width:${w}px;height:${h}px;overflow:hidden">${body}</body></html>`;
for (const scale of [1, 2]) {
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: scale });
  await page.setContent(html(svg, W, H));
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(here, scale === 1 ? "background.png" : "background@2x.png") });
  await page.close();
}
console.log("wrote scripts/dmg/background.png and background@2x.png");

if (process.argv.includes("--preview")) {
  // A mock Finder window: title bar, the background, and the two icons with
  // labels where Finder puts them. For a look without a Mac; the real window
  // is what scripts/dmg.sh builds.
  const b64 = (p) => readFileSync(p).toString("base64");
  const appIcon = b64(join(repo, "App/Kiri/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png"));
  const folder = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128"><defs>
    <linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#7cc4f8"/><stop offset="1" stop-color="#3d9ae8"/></linearGradient>
    <linearGradient id="b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5aaef0"/><stop offset="1" stop-color="#2f84d6"/></linearGradient></defs>
    <path d="M10,28 q0,-8 8,-8 h30 q5,0 8,4 l5,6 h49 q8,0 8,8 v66 q0,8 -8,8 H18 q-8,0 -8,-8Z" fill="url(#b)"/>
    <path d="M10,42 q0,-6 6,-6 h96 q6,0 6,6 v60 q0,8 -8,8 H18 q-8,0 -8,-8Z" fill="url(#f)"/>
    <g fill="none" stroke="#2c6fb5" stroke-opacity="0.55" stroke-width="5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M52,92 L64,58 L76,92 M56,82 h16"/></g></svg>`;
  const label = (c, text) => `<div style="position:absolute;left:${c.x - 60}px;top:${c.y + ICON / 2 + 15}px;width:120px;text-align:center;
    font:13px -apple-system,'Helvetica Neue',Arial,sans-serif;color:#1d1d1f">${text}</div>`;
  const icon = (c, src) => `<img src="${src}" style="position:absolute;left:${c.x - ICON / 2}px;top:${c.y - ICON / 2}px;width:${ICON}px;height:${ICON}px">`;
  const bar = 28, pad = 40;
  const body = `<div style="padding:${pad}px;background:#d9d2c6">
    <div style="width:${W}px;border-radius:12px;overflow:hidden;box-shadow:0 22px 60px rgba(60,40,20,.35),0 0 0 .5px rgba(0,0,0,.25)">
      <div style="height:${bar}px;background:#f3eee6;display:flex;align-items:center;gap:8px;padding-left:12px;border-bottom:.5px solid #d8cfc0;position:relative">
        <span style="width:12px;height:12px;border-radius:50%;background:#ff5f57"></span><span style="width:12px;height:12px;border-radius:50%;background:#febc2e"></span><span style="width:12px;height:12px;border-radius:50%;background:#28c840"></span>
        <span style="position:absolute;left:0;right:0;text-align:center;font:600 13px -apple-system,Arial,sans-serif;color:#4a4a4a">Kiri</span></div>
      <div style="position:relative;width:${W}px;height:${H}px">
        <img src="data:image/png;base64,${b64(join(here, "background@2x.png"))}" style="width:${W}px;height:${H}px;display:block">
        ${icon(kiri, `data:image/png;base64,${appIcon}`)}${icon(apps, `data:image/svg+xml;base64,${Buffer.from(folder).toString("base64")}`)}
        ${label(kiri, "Kiri")}${label(apps, "Applications")}
      </div></div></div>`;
  const pw = W + pad * 2, ph = H + bar + pad * 2;
  const page = await browser.newPage({ viewport: { width: pw, height: ph }, deviceScaleFactor: 2 });
  await page.setContent(html(body, pw, ph));
  await page.waitForFunction(() => [...document.images].every((i) => i.complete));
  mkdirSync(join(repo, "build"), { recursive: true });
  await page.screenshot({ path: join(repo, "build/dmg-preview.png") });
  console.log("wrote build/dmg-preview.png");
}
await browser.close();
