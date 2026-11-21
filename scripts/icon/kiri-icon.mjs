// Kiri's app icon. "Kiri" is Estonian for "letter", so the icon is a letter:
// a cream page rising out of a frosted-glass envelope on a honey tile, sealed
// with an amber wax seal. Colors are Honey tokens (KiriKit Honey.swift).
//
// Usage: node scripts/icon/kiri-icon.mjs [App/Kiri/Assets.xcassets/AppIcon.appiconset]
// Writes scripts/icon/kiri-icon.svg (the source of truth) and, with Playwright
// available (npm i -D playwright, or any global install), every macOS PNG size.
import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");

// Honey tokens (light).
const H = {
  canvas: "#F5EEE1", surface: "#FFFCF6", surface2: "#F2E8D6", surface3: "#EADCC4", line: "#E8DAC3",
  fg: "#3B2A2F", accent: "#E09A2D", accentHi: "#F5B656", accentInk: "#995A05", focus: "#B8700E",
  accentSoft: "#FBE7C2", keyword: "#9B2C6E", string: "#4E7A1F", type: "#1F6F8B",
};

// macOS tile: an 824 pt continuous-corner squircle centered in 1024.
function squircle(x, y, w, h, n = 4.2, steps = 256) {
  const cx = x + w / 2, cy = y + h / 2, a = w / 2, b = h / 2;
  const pts = [];
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2, c = Math.cos(t), s = Math.sin(t);
    pts.push([cx + a * Math.sign(c) * Math.abs(c) ** (2 / n), cy + b * Math.sign(s) * Math.abs(s) ** (2 / n)]);
  }
  return "M" + pts.map(([px, py]) => `${px.toFixed(2)},${py.toFixed(2)}`).join("L") + "Z";
}
const tile = squircle(100, 100, 824, 824);

// Hexagon (pointy top), for the honeycomb texture and the seal.
function hex(cx, cy, r, rot = -90) {
  const p = [];
  for (let i = 0; i < 6; i++) {
    const t = ((rot + i * 60) * Math.PI) / 180;
    p.push(`${(cx + r * Math.cos(t)).toFixed(2)},${(cy + r * Math.sin(t)).toFixed(2)}`);
  }
  return "M" + p.join("L") + "Z";
}
// A rounded hexagon for the wax seal.
function roundHex(cx, cy, r, k = 0.22) {
  const v = [];
  for (let i = 0; i < 6; i++) {
    const t = ((-90 + i * 60) * Math.PI) / 180;
    v.push([cx + r * Math.cos(t), cy + r * Math.sin(t)]);
  }
  let d = "";
  for (let i = 0; i < 6; i++) {
    const p = v[i], prev = v[(i + 5) % 6], next = v[(i + 1) % 6];
    const a = [p[0] + (prev[0] - p[0]) * k, p[1] + (prev[1] - p[1]) * k];
    const b = [p[0] + (next[0] - p[0]) * k, p[1] + (next[1] - p[1]) * k];
    d += `${i ? "L" : "M"}${a[0].toFixed(2)},${a[1].toFixed(2)}Q${p[0].toFixed(2)},${p[1].toFixed(2)} ${b[0].toFixed(2)},${b[1].toFixed(2)}`;
  }
  return d + "Z";
}

// Faint honeycomb in the tile's upper part.
let comb = "";
const R = 46, dx = R * Math.sqrt(3), dy = R * 1.5;
for (let row = 0; row < 14; row++) {
  for (let col = 0; col < 14; col++) {
    const cx = 60 + col * dx + (row % 2 ? dx / 2 : 0), cy = 60 + row * dy;
    comb += hex(cx, cy, R - 5);
  }
}

// Geometry (1024 grid, y down).
const env = { x: 214, y: 470, w: 596, h: 340, r: 56 };       // envelope body
const sheet = { x: 290, y: 236, w: 444, h: 480, r: 34 };      // the letter
const vTip = { x: 512, y: 648 };                              // where the front folds meet
const pocket = `M${env.x},${env.y + 18} L${vTip.x - 70},${vTip.y - 34} Q${vTip.x},${vTip.y + 4} ${vTip.x + 70},${vTip.y - 34} L${env.x + env.w},${env.y + 18}
  L${env.x + env.w},${env.y + env.h - env.r} Q${env.x + env.w},${env.y + env.h} ${env.x + env.w - env.r},${env.y + env.h}
  L${env.x + env.r},${env.y + env.h} Q${env.x},${env.y + env.h} ${env.x},${env.y + env.h - env.r} Z`;

// Lines of writing on the letter, in Honey syntax colors, plus the honey caret.
const lines = [
  { x: 346, w: 150, c: H.keyword }, { x: 512, w: 166, c: H.fg, o: 0.78 },
  { x: 346, w: 300, c: H.fg, o: 0.78 },
  { x: 390, w: 200, c: H.string },
  { x: 390, w: 120, c: H.type }, { x: 526, w: 100, c: H.fg, o: 0.5 },
];
const rows = [306, 306, 370, 434, 498, 498];
const writing = lines.map((l, i) =>
  `<rect x="${l.x}" y="${rows[i]}" width="${l.w}" height="30" rx="15" fill="${l.c}" fill-opacity="${l.o ?? 0.92}"/>`).join("");
const caret = `<rect x="601" y="424" width="13" height="50" rx="6.5" fill="${H.focus}"/>`;

const font = (w) => {
  try {
    const b64 = readFileSync(join(repo, `KiriKit/Sources/KiriKit/Fonts/Nunito-${w}.ttf`)).toString("base64");
    return `@font-face{font-family:NunitoK;font-weight:${w};src:url(data:font/ttf;base64,${b64})}`;
  } catch { return ""; }
};

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
  <style>${font(800)}</style>
  <linearGradient id="tileG" x1="0.2" y1="0" x2="0.8" y2="1">
    <stop offset="0" stop-color="#FFCB73"/><stop offset="0.5" stop-color="${H.accent}"/><stop offset="1" stop-color="#C47A12"/>
  </linearGradient>
  <radialGradient id="tileGlow" cx="0.3" cy="0.12" r="0.75">
    <stop offset="0" stop-color="#FFF3D6" stop-opacity="0.75"/><stop offset="1" stop-color="#FFF3D6" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.85"/><stop offset="0.35" stop-color="#FFFFFF" stop-opacity="0.12"/>
    <stop offset="0.75" stop-color="#FFFFFF" stop-opacity="0.05"/><stop offset="1" stop-color="#FFE2A8" stop-opacity="0.5"/>
  </linearGradient>
  <linearGradient id="combFade" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="0.55" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
  <mask id="combMask"><rect width="1024" height="1024" fill="url(#combFade)"/></mask>
  <linearGradient id="backG" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${H.surface3}"/><stop offset="1" stop-color="#D9C3A0"/>
  </linearGradient>
  <linearGradient id="sheetG" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="${H.surface}"/>
  </linearGradient>
  <linearGradient id="glassG" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFDF8" stop-opacity="0.62"/><stop offset="1" stop-color="${H.surface2}" stop-opacity="0.9"/>
  </linearGradient>
  <linearGradient id="glassEdge" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.25"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.7"/>
  </linearGradient>
  <radialGradient id="sealG" cx="0.38" cy="0.3" r="0.8">
    <stop offset="0" stop-color="${H.accentHi}"/><stop offset="0.55" stop-color="${H.focus}"/><stop offset="1" stop-color="#7A4404"/>
  </radialGradient>
  <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="16"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.32"/></feComponentTransfer>
    <feFlood flood-color="#5A3A1A"/><feComposite operator="in" in2="SourceAlpha"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="20" result="b"/><feOffset in="b" dy="18" result="o"/>
    <feFlood flood-color="#6B3E00" flood-opacity="0.38"/><feComposite in2="o" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="sealShadow" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="9"/><feOffset dy="9" result="o"/>
    <feFlood flood-color="#4A2A00" flood-opacity="0.45"/><feComposite in2="o" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="frost" x="0" y="0" width="100%" height="100%"><feGaussianBlur stdDeviation="14"/></filter>
  <clipPath id="tileClip"><path d="${tile}"/></clipPath>
  <clipPath id="pocketClip"><path d="${pocket}"/></clipPath>
  <g id="letter">
    <rect x="${sheet.x}" y="${sheet.y}" width="${sheet.w}" height="${sheet.h}" rx="${sheet.r}" fill="url(#sheetG)"/>
    ${writing}${caret}
  </g>
</defs>

<!-- Tile -->
<g filter="url(#drop)">
  <path d="${tile}" fill="url(#tileG)"/>
</g>
<g clip-path="url(#tileClip)">
  <path d="${tile}" fill="url(#tileGlow)"/>
  <path d="${comb}" fill="none" stroke="#FFF6E0" stroke-opacity="0.32" stroke-width="5" mask="url(#combMask)"/>
</g>
<path d="${tile}" fill="none" stroke="url(#rim)" stroke-width="5" transform="translate(512 512) scale(0.994) translate(-512 -512)"/>

<!-- Envelope back -->
<rect x="${env.x}" y="${env.y}" width="${env.w}" height="${env.h}" rx="${env.r}" fill="url(#backG)" filter="url(#soft)"/>
<!-- Shadow of the letter inside the envelope -->
<rect x="${sheet.x + 8}" y="${sheet.y + 22}" width="${sheet.w - 16}" height="${sheet.h - 20}" rx="${sheet.r}" fill="#6B3E00" opacity="0.18" filter="url(#frost)"/>
<!-- The letter -->
<use href="#letter"/>

<!-- Frosted-glass front pocket: the letter shows through, blurred -->
<g clip-path="url(#pocketClip)">
  <rect x="${env.x}" y="${env.y}" width="${env.w}" height="${env.h}" fill="url(#backG)"/>
  <use href="#letter" filter="url(#frost)" opacity="0.9"/>
  <path d="${pocket}" fill="url(#glassG)"/>
  <!-- a soft diagonal sheen -->
  <path d="M${env.x},${env.y + 120} L${env.x + 260},${env.y} L${env.x + 340},${env.y} L${env.x},${env.y + 230} Z" fill="#FFFFFF" opacity="0.22"/>
</g>
<path d="${pocket}" fill="none" stroke="url(#glassEdge)" stroke-width="4"/>
<!-- inner fold lines toward the bottom corners -->
<path d="M${env.x + 26},${env.y + env.h - 26} L${vTip.x - 40},${vTip.y + 8} M${env.x + env.w - 26},${env.y + env.h - 26} L${vTip.x + 40},${vTip.y + 8}"
  stroke="${H.focus}" stroke-opacity="0.16" stroke-width="5" stroke-linecap="round" fill="none"/>

<!-- Wax seal -->
<g filter="url(#sealShadow)">
  <path d="${roundHex(vTip.x, vTip.y - 6, 84)}" fill="url(#sealG)"/>
</g>
<path d="${roundHex(vTip.x, vTip.y - 6, 66, 0.2)}" fill="none" stroke="#FFE3A8" stroke-opacity="0.55" stroke-width="4"/>
<text x="${vTip.x}" y="${vTip.y + 22}" text-anchor="middle" font-family="NunitoK, Nunito, sans-serif" font-weight="800" font-size="84" fill="#FFF6E2">K</text>
<ellipse cx="${vTip.x - 34}" cy="${vTip.y - 50}" rx="22" ry="12" fill="#FFFFFF" opacity="0.38" transform="rotate(-30 ${vTip.x - 34} ${vTip.y - 50})"/>
</svg>
`;

writeFileSync(join(here, "kiri-icon.svg"), svg);
console.log("wrote scripts/icon/kiri-icon.svg");

const out = resolve(process.argv[2] ?? join(repo, "App/Kiri/Assets.xcassets/AppIcon.appiconset"));
let chromium;
try { ({ chromium } = await import("playwright")); } catch {
  try { ({ chromium } = (await import("node:module")).createRequire(import.meta.url)("playwright")); } catch {
    console.log("Playwright not found; skipped the PNGs."); process.exit(0);
  }
}
mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
const images = [];
for (const points of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const px = points * scale;
    const page = await browser.newPage({ viewport: { width: px, height: px } });
    await page.setContent(`<html><body style="margin:0;background:transparent">
      <img src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}" width="${px}" height="${px}" style="display:block"></body></html>`);
    await page.waitForFunction(() => document.images[0].complete);
    const name = `icon_${points}x${points}${scale === 2 ? "@2x" : ""}.png`;
    await page.screenshot({ path: join(out, name), omitBackground: true });
    await page.close();
    images.push({ filename: name, idiom: "mac", scale: `${scale}x`, size: `${points}x${points}` });
  }
}
await browser.close();
writeFileSync(join(out, "Contents.json"), JSON.stringify({ images, info: { author: "xcode", version: 1 } }, null, 2) + "\n");
console.log(`wrote ${images.length} images to ${out}`);
