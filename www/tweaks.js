// Market Stress Copilot — Tweaks overlay
// Floating bottom-right button + popup panel.
// Pure CSS-var manipulation; no Shiny round-trips. Persists in localStorage.

(function () {
  const STORAGE_KEY = "msc_tweaks_v1";
  const DEFAULTS = {
    accent: "#a3ff12",
    density: "comfort",     // "compact" | "comfort"
    sidebar: "show",        // "show"    | "hide"
  };

  const ACCENT_SWATCHES = [
    "#a3ff12",  // acid green (default)
    "#5b8def",  // electric blue
    "#b48cff",  // soft purple
    "#ffb84d",  // amber
    "#ff5470",  // rose
    "#ffffff",  // monochrome white
  ];

  function load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return { ...DEFAULTS };
      return { ...DEFAULTS, ...JSON.parse(raw) };
    } catch (_) {
      return { ...DEFAULTS };
    }
  }

  function save(state) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (_) {}
  }

  function apply(state) {
    document.documentElement.style.setProperty("--accent", state.accent);

    const body = document.body;
    body.classList.toggle("density-compact", state.density === "compact");
    body.classList.toggle("density-comfort", state.density === "comfort");
    body.classList.toggle("sidebar-hidden",  state.sidebar === "hide");
  }

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === "class") node.className = attrs[k];
      else if (k === "style") node.setAttribute("style", attrs[k]);
      else if (k.startsWith("on") && typeof attrs[k] === "function") {
        node.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
      } else node.setAttribute(k, attrs[k]);
    }
    (children || []).forEach((c) => {
      if (c == null) return;
      if (typeof c === "string") node.appendChild(document.createTextNode(c));
      else node.appendChild(c);
    });
    return node;
  }

  function buildToggle(onClick) {
    return el("button", {
      class: "tweaks-toggle",
      type: "button",
      title: "Tweaks",
      onClick,
    }, ["⚙"]);
  }

  function buildPanel(state, update) {
    const panel = el("div", { class: "tweaks-panel", role: "dialog", "aria-label": "Tweaks" });

    const header = el("div", { class: "tweaks-panel__head" }, [
      el("span", { class: "tweaks-panel__title" }, ["Tweaks"]),
      el("button", {
        class: "tweaks-panel__close",
        type: "button",
        title: "Close",
        onClick: () => panel.classList.remove("open"),
      }, ["×"]),
    ]);

    // ----- Theme accent -----
    const swatches = el("div", { class: "tweaks-swatches" },
      ACCENT_SWATCHES.map((color) => {
        const s = el("button", {
          class: "tweaks-swatch" + (color === state.accent ? " active" : ""),
          type: "button",
          title: color,
          style: "background:" + color,
          onClick: () => {
            state.accent = color;
            update(state);
            // refresh active marker
            panel.querySelectorAll(".tweaks-swatch").forEach((b) =>
              b.classList.toggle("active", b.getAttribute("title") === color));
          },
        });
        return s;
      })
    );

    // ----- Density -----
    const density = el("div", { class: "tweaks-radio" },
      [
        ["compact", "Compact"],
        ["comfort", "Comfort"],
      ].map(([val, label]) => el("button", {
        class: "tweaks-radio__btn" + (state.density === val ? " active" : ""),
        type: "button",
        "data-value": val,
        onClick: () => {
          state.density = val;
          update(state);
          density.querySelectorAll(".tweaks-radio__btn").forEach((b) =>
            b.classList.toggle("active", b.getAttribute("data-value") === val));
        },
      }, [label]))
    );

    // ----- Sidebar -----
    const sidebar = el("div", { class: "tweaks-radio" },
      [
        ["show", "Show"],
        ["hide", "Hide"],
      ].map(([val, label]) => el("button", {
        class: "tweaks-radio__btn" + (state.sidebar === val ? " active" : ""),
        type: "button",
        "data-value": val,
        onClick: () => {
          state.sidebar = val;
          update(state);
          sidebar.querySelectorAll(".tweaks-radio__btn").forEach((b) =>
            b.classList.toggle("active", b.getAttribute("data-value") === val));
        },
      }, [label]))
    );

    // ----- Reset -----
    const reset = el("button", {
      class: "tweaks-reset",
      type: "button",
      onClick: () => {
        Object.assign(state, DEFAULTS);
        update(state);
        // Reflow swatches/radios visual state
        panel.querySelectorAll(".tweaks-swatch").forEach((b) =>
          b.classList.toggle("active", b.getAttribute("title") === state.accent));
        density.querySelectorAll(".tweaks-radio__btn").forEach((b) =>
          b.classList.toggle("active", b.getAttribute("data-value") === state.density));
        sidebar.querySelectorAll(".tweaks-radio__btn").forEach((b) =>
          b.classList.toggle("active", b.getAttribute("data-value") === state.sidebar));
      },
    }, ["Reset to defaults"]);

    panel.appendChild(header);
    panel.appendChild(el("div", { class: "tweaks-section" }, [
      el("div", { class: "tweaks-label" }, ["THEME"]),
      el("div", { class: "tweaks-row" }, [
        el("span", { class: "tweaks-row__key" }, ["Accent"]),
        swatches,
      ]),
      el("div", { class: "tweaks-row" }, [
        el("span", { class: "tweaks-row__key" }, ["Density"]),
        density,
      ]),
      el("div", { class: "tweaks-row" }, [
        el("span", { class: "tweaks-row__key" }, ["Sidebar"]),
        sidebar,
      ]),
    ]));
    panel.appendChild(el("div", { class: "tweaks-section" }, [reset]));

    return panel;
  }

  function init() {
    if (document.querySelector(".tweaks-host")) return;

    const state = load();
    apply(state);

    const update = (s) => { save(s); apply(s); };

    const host = el("div", { class: "tweaks-host" });
    const panel = buildPanel(state, update);
    const toggle = buildToggle(() => panel.classList.toggle("open"));

    host.appendChild(panel);
    host.appendChild(toggle);
    document.body.appendChild(host);

    // Close panel on outside click
    document.addEventListener("mousedown", (e) => {
      if (!panel.classList.contains("open")) return;
      if (host.contains(e.target)) return;
      panel.classList.remove("open");
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
