#!/usr/bin/env python3
"""Kiri's color themes, derived from Honey.

Every theme starts from the Honey tokens (KiriKit Honey.swift) and moves them
in OKLCH: the neutrals (paper and ink) to the theme's hue and chroma, the
accent family to the theme's accent hue, and the syntax colors by a small hue
turn. Lightness is kept, so the contrast stays close to Honey's; then every
promise in docs/DESIGN.md §3 (the HoneyTests checks) is enforced by nudging
lightness until it holds.

Usage: python3 scripts/themes/make-themes.py
Writes KiriKit/Sources/KiriKit/HoneyThemes.swift and scripts/themes/themes.json
(read by scripts/icon/kiri-icon.mjs for the per-theme app icons).
"""
import json, math, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../.."))
HONEY = os.path.join(REPO, "KiriKit/Sources/KiriKit/Honey.swift")

# --- color math -------------------------------------------------------------

def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def lin_to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

def hex_to_oklch(v):
    r, g, b = [srgb_to_lin(((v >> s) & 0xFF) / 255) for s in (16, 8, 0)]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = [math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s)]
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360

def oklch_to_rgb(L, C, h):
    a, b = C * math.cos(math.radians(h)), C * math.sin(math.radians(h))
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return r, g, bl

def oklch_to_hex(L, C, h):
    L = min(max(L, 0), 1)
    # Reduce chroma until the color is inside sRGB.
    lo, hi = 0.0, C
    rgb = oklch_to_rgb(L, C, h)
    if not all(-1e-6 <= x <= 1 + 1e-6 for x in rgb):
        for _ in range(30):
            mid = (lo + hi) / 2
            if all(-1e-6 <= x <= 1 + 1e-6 for x in oklch_to_rgb(L, mid, h)): lo = mid
            else: hi = mid
        rgb = oklch_to_rgb(L, lo, h)
    r, g, b = [round(min(max(lin_to_srgb(min(max(x, 0), 1)), 0), 1) * 255) for x in rgb]
    return (r << 16) | (g << 8) | b

def luminance(v):
    r, g, b = [srgb_to_lin(((v >> s) & 0xFF) / 255) for s in (16, 8, 0)]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    x, y = luminance(a), luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)

# --- Honey ------------------------------------------------------------------

def read_honey():
    src = open(HONEY).read()
    tokens = {}
    for m in re.finditer(r'static let (\w+) = Token\("([\w-]+)", light: 0x(\w+), dark: 0x(\w+)(?:, hcLight: 0x(\w+), hcDark: 0x(\w+))?\)', src):
        _, name, l, d, hl, hd = m.groups()
        l, d = int(l, 16), int(d, 16)
        tokens[name] = [l, d, int(hl, 16) if hl else l, int(hd, 16) if hd else d]
    return tokens

NEUTRAL = {"canvas", "surface", "surface-2", "surface-3", "line", "fg", "fg-muted", "current-line",
           "gutter", "syn-comment", "syn-punctuation"}
ACCENT = {"accent", "accent-fg", "accent-ink", "accent-soft", "focus", "selection", "syn-heading"}
FIXED = {"danger", "danger-fill", "ok"}
HONEY_NEUTRAL_HUE = 70.0
HONEY_ACCENT_HUE = 70.0

# --- the themes -------------------------------------------------------------
# neutral: (hue, chroma scale), accent: (hue, chroma scale), syntax: hue turn.

THEMES = [
    dict(id="honey", name="Honey", blurb="Warm cream and amber. Kiri's own."),
    dict(id="matcha", name="Matcha", blurb="Green tea and rice paper.",
         neutral=(112, 0.85), accent=(132, 0.95), syntax=-12),
    dict(id="sakura", name="Sakura", blurb="Cherry blossom on soft blush.",
         neutral=(18, 0.8), accent=(2, 1.0), syntax=8),
    dict(id="tide", name="Tide", blurb="Sea glass and deep water.",
         neutral=(215, 0.7), accent=(205, 1.0), syntax=-6),
    dict(id="lavender", name="Lavender", blurb="Dusky violet and lilac.",
         neutral=(300, 0.75), accent=(298, 1.0), syntax=10),
    dict(id="graphite", name="Graphite", blurb="Quiet greys, one blue accent.",
         neutral=(255, 0.22), accent=(252, 1.15), syntax=0),
]

def turn(h, d):
    return (h + d) % 360

def delta(h, base):
    """Signed hue difference, -180...180."""
    return (h - base + 180) % 360 - 180

def move(v, kind, t):
    L, C, h = hex_to_oklch(v)
    if kind == "neutral":
        hue, k = t["neutral"]
        # Keep the neutral's own small hue offsets from Honey's base hue.
        return oklch_to_hex(L, C * k, turn(hue, delta(h, HONEY_NEUTRAL_HUE) * 0.3 if C > 0.01 else 0))
    if kind == "accent":
        hue, k = t["accent"]
        return oklch_to_hex(L, C * k, turn(hue, delta(h, HONEY_ACCENT_HUE) * 0.5))
    if kind == "syntax":
        return oklch_to_hex(L, C, turn(h, t["syntax"]))
    return v

def kind_of(name):
    if name in NEUTRAL: return "neutral"
    if name in ACCENT: return "accent"
    if name in FIXED: return "fixed"
    return "syntax"

MODES = [(False, False), (True, False), (False, True), (True, True)]

def nudge(tokens, name, mode, toward_dark):
    i = MODES.index(mode)
    L, C, h = hex_to_oklch(tokens[name][i])
    L = max(0, min(1, L + (-0.004 if toward_dark else 0.004)))
    tokens[name][i] = oklch_to_hex(L, C, h)

def enforce(tokens):
    """The contrast promises (HoneyTests), fixed by moving the named side."""
    for _ in range(400):
        ok = True
        for mode in MODES:
            dark, hc = mode
            i = MODES.index(mode)
            text = 7.0 if hc else 4.5
            rules = []
            for bg in ["surface", "surface-2", "canvas", "current-line"]:
                rules.append(("fg", bg, text, "fg"))
            rules.append(("fg", "selection", text, "selection"))
            rules += [("fg-muted", "surface", 4.5, "fg-muted"), ("accent-ink", "surface", 4.5, "accent-ink"),
                      ("accent-fg", "accent", 7.0, "accent-fg"), ("ok", "surface", 4.5, "ok"),
                      ("danger", "surface", 4.5, "danger")]
            g = 4.5 if hc else 3.0
            rules += [("gutter", "surface", g, "gutter"), ("gutter", "current-line", g, "gutter"),
                      ("focus", "surface", 3.0, "focus"), ("focus", "surface-2", 3.0, "focus")]
            for name in SYNTAX_NAMES:
                for bg in ["surface", "current-line"]:
                    rules.append((name, bg, text, name))
            for fgn, bgn, need, fix in rules:
                if contrast(tokens[fgn][i], tokens[bgn][i]) + 1e-3 < need + 0.05:
                    ok = False
                    # Text goes away from the paper; a background goes away from the text.
                    other = tokens[bgn][i] if fix == fgn else tokens[fgn][i]
                    toward_dark = luminance(other) > 0.18
                    nudge(tokens, fix, mode, toward_dark)
        if ok: return
    raise SystemExit("contrast did not converge")

SYNTAX_NAMES = []

def build():
    honey = read_honey()
    SYNTAX_NAMES[:] = [n for n in honey if n.startswith("syn-")]
    out = []
    for t in THEMES:
        if t["id"] == "honey":
            out.append((t, {k: list(v) for k, v in honey.items()}))
            continue
        tokens = {name: [move(v, kind_of(name), t) for v in vals] for name, vals in honey.items()}
        enforce(tokens)
        out.append((t, tokens))
    return out

# Icon colors (scripts/icon/kiri-icon.mjs), moved like the tokens.
ICON = {
    "canvas": ("#F5EEE1", "neutral"), "surface": ("#FFFCF6", "neutral"), "glassTop": ("#FFFDF8", "neutral"), "surface2": ("#F2E8D6", "neutral"),
    "surface3": ("#EADCC4", "neutral"), "backLow": ("#D9C3A0", "neutral"), "fg": ("#3B2A2F", "neutral"),
    "accent": ("#E09A2D", "accent"), "accentHi": ("#F5B656", "accent"), "accentInk": ("#995A05", "accent"),
    "focus": ("#B8700E", "accent"), "accentSoft": ("#FBE7C2", "accent"), "tileHi": ("#FFCB73", "accent"),
    "tileLo": ("#C47A12", "accent"), "glow": ("#FFF3D6", "accent"), "comb": ("#FFF6E0", "accent"),
    "rimLo": ("#FFE2A8", "accent"), "sealRim": ("#FFE3A8", "accent"), "sealText": ("#FFF6E2", "accent"),
    "sealLo": ("#7A4404", "accent"), "inkWarm": ("#5A3A1A", "neutral"), "inkDeep": ("#6B3E00", "accent"),
    "inkSeal": ("#4A2A00", "accent"), "keyword": ("#9B2C6E", "syntax"), "string": ("#4E7A1F", "syntax"),
    "type": ("#1F6F8B", "syntax"),
}

def icon_colors(t):
    res = {}
    for k, (hx, kind) in ICON.items():
        v = int(hx[1:], 16)
        if t["id"] != "honey": v = move(v, kind, t)
        res[k] = "#%06X" % v
    return res

def swift_name(name):
    parts = name.split("-")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])

def write(themes):
    lines = ["// Generated by scripts/themes/make-themes.py. Do not edit; change the script and run it again.",
             "", "public extension Honey.Theme {"]
    for t, tokens in themes:
        if t["id"] == "honey": continue
        lines.append(f'    /// {t["blurb"]}')
        lines.append(f'    static let {t["id"]} = Honey.Theme(id: "{t["id"]}", name: "{t["name"]}", blurb: "{t["blurb"]}", tokens: [')
        for name, (l, d, hl, hd) in tokens.items():
            lines.append(f'        "{name}": .init("{name}", light: 0x{l:06X}, dark: 0x{d:06X}, hcLight: 0x{hl:06X}, hcDark: 0x{hd:06X}),')
        lines.append("    ])")
    lines.append("")
    lines.append("    /// Every theme, in the order Settings shows them.")
    lines.append("    static let all: [Honey.Theme] = [" + ", ".join(t["id"] for t, _ in themes) + "]")
    lines.append("}")
    open(os.path.join(REPO, "KiriKit/Sources/KiriKit/HoneyThemes.swift"), "w").write("\n".join(lines) + "\n")
    data = [dict(id=t["id"], name=t["name"], blurb=t["blurb"], icon=icon_colors(t),
                 tokens={n: ["#%06X" % x for x in v] for n, v in tokens.items()}) for t, tokens in themes]
    open(os.path.join(HERE, "themes.json"), "w").write(json.dumps(data, indent=1) + "\n")
    print("wrote KiriKit/Sources/KiriKit/HoneyThemes.swift and scripts/themes/themes.json")

if __name__ == "__main__":
    write(build())
