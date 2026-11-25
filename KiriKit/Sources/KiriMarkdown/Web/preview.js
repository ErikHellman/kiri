// Kiri's Markdown preview page script. It runs in the app's own JavaScript
// world (WKContentWorld.defaultClient), never the page's: the page itself
// runs no scripts. The app calls `kiriPreview.update` with each rendering
// (MarkdownHTML) and posts to `kiri` for what only it can do (copying).
(() => {
  "use strict";
  if (window.kiriPreview) return;

  const post = (message) => {
    try { window.webkit.messageHandlers.kiri.postMessage(message); } catch (e) { /* not in Kiri */ }
  };

  /** The blocks that say which line of the file they start on, in page order. */
  const blocks = () => Array.from(document.querySelectorAll("[data-line]"));

  /** The line of the block at the top of the window. */
  const topLine = () => {
    if (window.scrollY < 4) return 1;
    let best = 1;
    for (const el of blocks()) {
      const r = el.getBoundingClientRect();
      if (r.height === 0) continue;
      if (r.top <= 8) best = Number(el.dataset.line) || best;
      else break;
    }
    return best;
  };

  /** Scrolls the block that has `line` to the top; returns that block's line. */
  const scrollToLine = (line) => {
    if (line <= 1) { window.scrollTo(0, 0); return 1; }
    let target = null;
    for (const el of blocks()) {
      const l = Number(el.dataset.line);
      if (l <= line) target = el; else break;
    }
    if (!target) { window.scrollTo(0, 0); return 1; }
    const y = target.getBoundingClientRect().top + window.scrollY - 12;
    window.scrollTo(0, Math.max(0, y));
    return topLine();
  };

  // Where the reader is, told to the app once scrolling settles, so
  // switching back to the text shows the same place.
  let scrollTimer = 0;
  window.addEventListener("scroll", () => {
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => post({ top: topLine() }), 120);
  }, { passive: true });

  const addCopyButtons = (root) => {
    for (const block of root.querySelectorAll(".code")) {
      if (block.querySelector(".copy")) continue;
      const button = document.createElement("button");
      button.className = "copy";
      button.type = "button";
      button.textContent = "Copy";
      button.setAttribute("aria-label", "Copy code");
      button.addEventListener("click", () => {
        post({ copy: block.querySelector("code").textContent });
        button.textContent = "Copied";
        button.classList.add("done");
        setTimeout(() => { button.textContent = "Copy"; button.classList.remove("done"); }, 1500);
      });
      block.appendChild(button);
    }
  };

  // MARK: Mermaid

  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  /** Mermaid in Honey: the theme's tokens as its theme variables. */
  const mermaidConfig = () => {
    const dark = document.documentElement.style.colorScheme === "dark"
      || getComputedStyle(document.documentElement).colorScheme === "dark";
    const v = {
      darkMode: dark,
      background: "transparent",
      fontFamily: "Nunito, system-ui, sans-serif",
      fontSize: "14px",
      primaryColor: css("--surface-2"),
      primaryTextColor: css("--fg"),
      primaryBorderColor: css("--accent"),
      secondaryColor: css("--accent-soft"),
      secondaryTextColor: css("--fg"),
      secondaryBorderColor: css("--line"),
      tertiaryColor: css("--surface-3"),
      tertiaryTextColor: css("--fg"),
      tertiaryBorderColor: css("--line"),
      lineColor: css("--fg-muted"),
      textColor: css("--fg"),
      mainBkg: css("--surface-2"),
      nodeBorder: css("--accent"),
      clusterBkg: css("--surface"),
      clusterBorder: css("--line"),
      titleColor: css("--fg"),
      edgeLabelBackground: css("--surface"),
      noteBkgColor: css("--accent-soft"),
      noteTextColor: css("--fg"),
      noteBorderColor: css("--accent"),
      actorBkg: css("--surface-2"),
      actorBorder: css("--accent"),
      actorTextColor: css("--fg"),
      actorLineColor: css("--fg-muted"),
      signalColor: css("--fg"),
      signalTextColor: css("--fg"),
      labelBoxBkgColor: css("--surface-2"),
      labelBoxBorderColor: css("--accent"),
      labelTextColor: css("--fg"),
      loopTextColor: css("--fg"),
      activationBkgColor: css("--accent-soft"),
      activationBorderColor: css("--accent"),
      sequenceNumberColor: css("--accent-fg"),
      errorBkgColor: css("--surface-2"),
      errorTextColor: css("--danger"),
      git0: css("--accent"), git1: css("--syn-function"), git2: css("--syn-keyword"), git3: css("--syn-string"),
      git4: css("--syn-type"), git5: css("--syn-property"), git6: css("--syn-number"), git7: css("--syn-tag"),
      pie1: css("--accent"), pie2: css("--syn-function"), pie3: css("--syn-keyword"), pie4: css("--syn-string"),
      pie5: css("--syn-type"), pie6: css("--syn-property"), pie7: css("--syn-number"), pie8: css("--syn-tag"),
      pieTitleTextColor: css("--fg"), pieSectionTextColor: css("--accent-fg"), pieLegendTextColor: css("--fg"),
      pieStrokeColor: css("--surface"), pieOuterStrokeColor: css("--line"),
    };
    return { startOnLoad: false, securityLevel: "strict", theme: "base", themeVariables: v, darkMode: dark,
             fontFamily: v.fontFamily, sequence: { mirrorActors: false } };
  };

  let drawn = 0;
  const drawMermaid = async () => {
    const figures = Array.from(document.querySelectorAll("figure.mermaid"));
    if (!figures.length) return true;
    if (!window.mermaid) return false;
    try { await document.fonts.ready; } catch (e) { /* draw anyway */ }
    window.mermaid.initialize(mermaidConfig());
    for (const figure of figures) {
      const source = figure.querySelector(".mermaid-source");
      if (!source) continue;
      const id = "kiri-mermaid-" + (++drawn);
      try {
        const { svg } = await window.mermaid.render(id, source.textContent);
        for (const old of figure.querySelectorAll("svg, .mermaid-error")) old.remove();
        figure.insertAdjacentHTML("afterbegin", svg);
        figure.classList.add("drawn");
        figure.classList.remove("failed");
      } catch (e) {
        document.getElementById(id)?.remove();
        document.getElementById("d" + id)?.remove();
        for (const old of figure.querySelectorAll("svg, .mermaid-error")) old.remove();
        const error = document.createElement("p");
        error.className = "mermaid-error";
        error.textContent = "This diagram has a mistake: " + String((e && e.message) || e).split("\n")[0];
        figure.insertBefore(error, source);
        figure.classList.add("failed");
        figure.classList.remove("drawn");
      }
    }
    return true;
  };

  const waiting = () => document.querySelector("figure.mermaid") !== null && !window.mermaid;

  window.kiriPreview = {
    /**
     * Shows a rendering: `html` (unchanged when null) in the page's colors
     * `style` (unchanged when null), at the block that has `line` (where
     * it is when null), its diagrams drawn if Mermaid has loaded. Returns
     * the line of the block at the top, and whether diagrams wait for
     * Mermaid (`redraw` once it has loaded).
     */
    async show(html, style, line) {
      const page = document.getElementById("kiri-page");
      const keep = line === null ? topLine() : line;
      if (style !== null) document.getElementById("kiri-style").textContent = style;
      if (html !== null) {
        page.innerHTML = html;
        addCopyButtons(page);
      }
      scrollToLine(keep);
      if (window.mermaid && document.querySelector("figure.mermaid")) {
        await drawMermaid();
        scrollToLine(keep);
      }
      return { top: topLine(), waiting: waiting() };
    },
    /** Draws the diagrams again (Mermaid has loaded), keeping the place. */
    async redraw(line) {
      const keep = line === null ? topLine() : line;
      await drawMermaid();
      scrollToLine(keep);
      return { top: topLine(), waiting: waiting() };
    },
    topLine,
  };
})();
