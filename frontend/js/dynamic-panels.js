// Dynamic panels module — uses CSS.highlights (Chromium-only, not in Firefox).
// This is the demo's planted bug: in Firefox, CSS.highlights is undefined and
// the module throws TypeError before mounting any panels.

(function () {
  function mount(selector) {
    const root = document.querySelector(selector);
    if (!root) throw new Error("mount root not found: " + selector);

    // Highlight registry for animated panel borders. Chromium-only API.
    const highlight = new Highlight();
    CSS.highlights.set("panel-active", highlight);

    const panels = ["Revenue", "Active Users", "Latency p95", "Error rate"];
    panels.forEach((title) => {
      const el = document.createElement("div");
      el.className = "panel";
      el.innerHTML =
        "<h3>" + title + "</h3><p class='metric'>" + Math.round(Math.random() * 100) + "</p>";
      root.appendChild(el);
    });
  }

  window.LumenDynamicPanels = { mount };
})();
