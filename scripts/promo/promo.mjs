// Kiri's promotional graphics and the website's images, drawn from real
// screenshots of the app on Honey paper. Colors are Honey tokens (KiriKit
// Honey.swift, light), the type is Nunito (KiriKit/Sources/KiriKit/Fonts).
//
// Usage: node scripts/promo/promo.mjs
// Needs Playwright (npm i -D playwright, or any global install).
//
// Reads the app's screenshots from docs/promo/shots (window captures made
// with `screencapture -o -l <window>`, so transparent corners and no shadow):
//   hero-light.png, hero-dark.png  the main window, light and dark
//   palette.png, find.png, markdown.png, settings.png
//   themes/<id>-light.png, themes/<id>-dark.png   one per color theme
// A missing file falls back to the nearest one there is.
//
// Writes:
//   docs/promo/hero.png        2560 x 1440, the README's picture
//   docs/promo/social.png      1280 x 640, GitHub's social preview and og:image
//   docs/promo/light-dark.png  2560 x 1440, light and dark side by side
//   docs/promo/themes.png      2560 x 1440, the six color themes
//   site/assets/…              the website's images (WebP screenshots, icon,
//                              favicon, the og:image)
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");
const shots = join(repo, "docs/promo/shots");
const out = join(repo, "docs/promo");
const site = join(repo, "site/assets");

const themes = JSON.parse(readFileSync(join(repo, "scripts/themes/themes.json"), "utf8"));
const C = {
  canvas: "#F5EEE1", surface: "#FFFCF6", surface2: "#F2E8D6", line: "#E8DAC3",
  fg: "#3B2A2F", muted: "#76615A", accent: "#E09A2D", ink: "#995A05",
  soft: "#FBE7C2", focus: "#B8700E",
};

const dataURL = (path, type = "image/png") => `data:${type};base64,${readFileSync(path).toString("base64")}`;
function shot(...names) {
  for (const n of names) {
    const p = join(shots, n);
    if (existsSync(p)) return dataURL(p);
  }
  throw new Error(`none of ${names.join(", ")} in docs/promo/shots`);
}
const has = (n) => existsSync(join(shots, n));
const icon = dataURL(join(repo, "App/Kiri/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"));
const themeIcon = (id) => dataURL(join(repo, `App/Kiri/ThemeIcons/ThemeIcon-${id}.png`));

const fonts = [400, 600, 700, 800].map((w) =>
  `@font-face{font-family:Nunito;font-weight:${w};src:url(${dataURL(join(repo, `KiriKit/Sources/KiriKit/Fonts/Nunito-${w}.ttf`), "font/ttf")})}`).join("");

// Honeycomb, as an SVG data URL for a CSS background, faded with a mask.
function combSVG(r = 22, color = C.accent, opacity = 0.16) {
  const dx = r * Math.sqrt(3), dy = r * 1.5, w = dx, h = dy * 2;
  const hex = (cx, cy) => {
    const p = [];
    for (let i = 0; i < 6; i++) {
      const t = ((-90 + i * 60) * Math.PI) / 180;
      p.push(`${(cx + (r - 2) * Math.cos(t)).toFixed(2)},${(cy + (r - 2) * Math.sin(t)).toFixed(2)}`);
    }
    return `M${p.join("L")}Z`;
  };
  const d = hex(0, 0) + hex(w, 0) + hex(w / 2, dy) + hex(0, 2 * dy) + hex(w, 2 * dy);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w.toFixed(2)}" height="${h.toFixed(2)}"><path d="${d}" fill="none" stroke="${color}" stroke-opacity="${opacity}" stroke-width="1.6"/></svg>`;
  return `url("data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}")`;
}

const base = `
${fonts}
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:100%;height:100%}
body{font-family:Nunito;color:${C.fg};background:${C.canvas};overflow:hidden;-webkit-font-smoothing:antialiased}
.paper{position:absolute;inset:0;
  background:
    radial-gradient(120% 90% at 0% 0%, #FFFBF3 0%, rgba(255,251,243,0) 55%),
    radial-gradient(70% 70% at 100% 100%, ${C.soft} 0%, rgba(251,231,194,0) 70%),
    ${C.canvas}}
.comb{position:absolute;background-image:${combSVG()};
  -webkit-mask-image:radial-gradient(closest-side, #000 20%, transparent 100%)}
.hex{position:absolute;width:var(--s);height:calc(var(--s)*1.1547);
  clip-path:polygon(50% 0,100% 25%,100% 75%,50% 100%,0 75%,0 25%);
  background:linear-gradient(160deg,#FFD27E,${C.accent} 60%,#C47A12);opacity:var(--o,.85)}
.win{position:absolute;display:block;border-radius:14px;
  filter:drop-shadow(0 2px 3px rgba(91,58,26,.16)) drop-shadow(0 22px 40px rgba(91,58,26,.22)) drop-shadow(0 60px 90px rgba(91,58,26,.16))}
.win.dark{filter:drop-shadow(0 2px 3px rgba(20,10,0,.3)) drop-shadow(0 24px 44px rgba(40,22,4,.35)) drop-shadow(0 60px 90px rgba(40,22,4,.22))}
.icon{filter:drop-shadow(0 10px 18px rgba(150,90,10,.28))}
.name{font-weight:800;letter-spacing:-.02em;line-height:1}
.tag{font-weight:600;color:${C.muted};line-height:1.25}
.chips{display:flex;gap:10px;flex-wrap:wrap}
.chip{font-weight:700;font-size:15px;color:${C.ink};background:rgba(251,231,194,.85);border:1px solid rgba(224,154,45,.35);
  border-radius:999px;padding:7px 14px}
`;

const html = (body, css = "") => `<!doctype html><html><head><meta charset="utf-8"><style>${base}${css}</style></head><body>${body}</body></html>`;

// --- the pictures -----------------------------------------------------------

function hero() {
  return html(`
  <div class="paper"></div>
  <div class="comb" style="left:-120px;top:-120px;width:560px;height:520px"></div>
  <div class="comb" style="right:-160px;bottom:-200px;width:720px;height:640px"></div>
  <div class="hex" style="--s:26px;left:520px;top:92px;--o:.55;transform:rotate(8deg)"></div>
  <div class="hex" style="--s:14px;left:92px;top:600px;--o:.45"></div>
  <div class="hex" style="--s:18px;left:1200px;top:60px;--o:.5;transform:rotate(-12deg)"></div>
  <div style="position:absolute;left:84px;top:178px;width:420px">
    <img class="icon" src="${icon}" style="width:132px;height:132px;margin-left:-10px">
    <div class="name" style="font-size:88px;margin-top:14px">Kiri</div>
    <div class="tag" style="font-size:29px;margin-top:16px">A beautiful text editor<br>for quick edits.</div>
    <div class="chips" style="margin-top:30px">
      <span class="chip">Native SwiftUI</span><span class="chip">Liquid Glass</span><span class="chip">macOS 26</span>
    </div>
  </div>
  <img class="win dark" src="${shot("hero-dark.png")}" style="width:600px;left:650px;top:48px">
  <img class="win" src="${shot("hero-light.png")}" style="width:640px;left:530px;top:226px">
  `);
}

function social() {
  return html(`
  <div class="paper"></div>
  <div class="comb" style="left:-140px;top:-140px;width:520px;height:480px"></div>
  <div class="comb" style="right:-160px;bottom:-200px;width:640px;height:560px"></div>
  <div class="hex" style="--s:22px;left:470px;top:70px;--o:.55;transform:rotate(8deg)"></div>
  <div style="position:absolute;left:80px;top:150px;width:420px">
    <img class="icon" src="${icon}" style="width:118px;height:118px;margin-left:-9px">
    <div class="name" style="font-size:80px;margin-top:10px">Kiri</div>
    <div class="tag" style="font-size:27px;margin-top:14px">A beautiful text editor<br>for quick edits on the Mac.</div>
    <div style="margin-top:24px;font-weight:700;font-size:18px;color:${C.ink}">kiri.hellsoft.se</div>
  </div>
  <img class="win" src="${shot("hero-light.png")}" style="width:700px;left:520px;top:120px">
  `);
}

function lightDark() {
  return html(`
  <div class="paper"></div>
  <div style="position:absolute;inset:0;background:linear-gradient(115deg,transparent 0 50%,#16120E 50% 100%)"></div>
  <div class="comb" style="left:-120px;top:-140px;width:560px;height:520px"></div>
  <div class="comb" style="right:-140px;bottom:-180px;width:600px;height:560px;opacity:.6"></div>
  <img class="win" src="${shot("hero-light.png")}" style="width:600px;left:40px;top:150px">
  <img class="win dark" src="${shot("hero-dark.png")}" style="width:600px;left:640px;top:150px">
  <div class="name" style="position:absolute;left:44px;top:58px;font-size:40px">Light</div>
  <div class="name" style="position:absolute;right:44px;bottom:52px;font-size:40px;color:#F6ECE0">Dark</div>
  `);
}

function themeGrid() {
  const cards = themes.map((t) => {
    const T = (k, i = 0) => t.tokens[k][i];
    const pic = has(`themes/${t.id}-light.png`) ? shot(`themes/${t.id}-light.png`) : null;
    const pic2 = has(`themes/${t.id}-dark.png`) ? shot(`themes/${t.id}-dark.png`) : null;
    const art = pic
      ? `<div style="position:relative;height:200px">
           ${pic2 ? `<img class="win dark" src="${pic2}" style="width:220px;left:120px;top:0">` : ""}
           <img class="win" src="${pic}" style="width:240px;left:10px;top:${pic2 ? 34 : 14}px">
         </div>`
      : `<div style="height:200px;display:flex;align-items:center;justify-content:center">
           <img class="icon" src="${themeIcon(t.id)}" style="width:156px;height:156px">
         </div>`;
    return `<div style="position:relative;border-radius:28px;padding:24px 26px 22px;overflow:hidden;
        background:linear-gradient(160deg,${T("surface")} 0%,${T("canvas")} 100%);
        box-shadow:0 1px 0 rgba(255,255,255,.8) inset,0 0 0 1px ${T("line")},0 18px 40px rgba(91,58,26,.12)">
      ${art}
      <div style="display:flex;align-items:center;gap:12px;margin-top:16px">
        <span style="width:18px;height:18px;border-radius:50%;background:${T("accent")};box-shadow:0 0 0 4px ${T("accent-soft")}"></span>
        <span class="name" style="font-size:28px;color:${T("fg")}">${t.name}</span>
      </div>
      <div class="tag" style="font-size:17px;margin-top:6px;color:${T("fg-muted")}">${t.blurb}</div>
    </div>`;
  }).join("");
  return html(`
  <div class="paper"></div>
  <div class="comb" style="left:-120px;top:-160px;width:520px;height:460px"></div>
  <div style="position:absolute;left:0;right:0;top:44px;text-align:center">
    <div class="name" style="font-size:46px">Six themes, light and dark</div>
  </div>
  <div style="position:absolute;left:60px;right:60px;top:120px;display:grid;grid-template-columns:repeat(3,1fr);gap:26px">${cards}</div>
  `);
}

// --- rendering --------------------------------------------------------------

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  for (const from of [repo, here, process.cwd()]) {
    try { return require(require.resolve("playwright", { paths: [from] })); } catch {}
  }
  return require("playwright");
}

const { chromium } = loadPlaywright();
const browser = await chromium.launch();
mkdirSync(out, { recursive: true });
mkdirSync(join(site, "shots"), { recursive: true });
mkdirSync(join(site, "themes"), { recursive: true });

async function render(doc, path, w, h, scale) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: scale });
  await page.setContent(doc, { waitUntil: "load" });
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path });
  await page.close();
  console.log("wrote", path.replace(repo + "/", ""));
}

// An image re-encoded (and scaled to `width` px) in the browser, for the site.
async function encode(src, path, { width, type = "image/webp", quality = 0.9 } = {}) {
  const page = await browser.newPage();
  const b64 = await page.evaluate(async ({ src, width, type, quality }) => {
    const img = new Image();
    img.src = src;
    await img.decode();
    const w = width ?? img.naturalWidth, h = Math.round((img.naturalHeight * w) / img.naturalWidth);
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    const g = c.getContext("2d");
    g.imageSmoothingQuality = "high";
    g.drawImage(img, 0, 0, w, h);
    return c.toDataURL(type, quality).split(",")[1];
  }, { src, width, type, quality });
  writeFileSync(path, Buffer.from(b64, "base64"));
  await page.close();
  console.log("wrote", path.replace(repo + "/", ""));
}

await render(hero(), join(out, "hero.png"), 1280, 720, 2);
await render(social(), join(out, "social.png"), 1280, 640, 1);
await render(lightDark(), join(out, "light-dark.png"), 1280, 720, 2);
await render(themeGrid(), join(out, "themes.png"), 1280, 720 + 90, 2);

// The website's images.
await encode(dataURL(join(out, "social.png")), join(site, "og.png"), { type: "image/png" });
await encode(dataURL(join(out, "hero.png")), join(site, "hero.webp"), { width: 1920, quality: 0.88 });
await encode(dataURL(join(out, "themes.png")), join(site, "themes.webp"), { width: 1920, quality: 0.88 });
await encode(icon, join(site, "icon.png"), { width: 256, type: "image/png" });
await encode(icon, join(site, "favicon.png"), { width: 64, type: "image/png" });
await encode(icon, join(site, "apple-touch-icon.png"), { width: 180, type: "image/png" });
for (const [name, ...fallback] of [
  ["hero-light.png"], ["hero-dark.png"], ["palette.png", "hero-light.png"], ["find.png", "hero-light.png"],
  ["markdown.png", "hero-light.png"], ["settings.png", "hero-light.png"],
]) {
  await encode(shot(name, ...fallback), join(site, "shots", name.replace(".png", ".webp")), { width: 1600 });
}
for (const t of themes) {
  for (const mode of ["light", "dark"]) {
    const n = `themes/${t.id}-${mode}.png`;
    if (has(n)) await encode(shot(n), join(site, "themes", `${t.id}-${mode}.webp`), { width: 1600 });
  }
  await encode(themeIcon(t.id), join(site, "themes", `icon-${t.id}.png`), { width: 160, type: "image/png" });
}
await browser.close();
