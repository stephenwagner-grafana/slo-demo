// Lumen Analytics frontend bootstrap.
// Fetches feature flag, conditionally loads the dynamic-panels module,
// reports the resulting page_load outcome via /api/telemetry.

(function () {
  const page = document.body.dataset.page;
  const needsDynamicPanels = document.body.dataset.needsDynamicPanels === "true";
  const browser = detectBrowser(navigator.userAgent);
  const startTime = performance.now();

  fetch("/api/config")
    .then((r) => r.json())
    .then((cfg) => {
      if (needsDynamicPanels && cfg.enableDynamicPanels) {
        return loadDynamicPanels().then(() => report("success"));
      }
      report("success");
    })
    .catch((err) => {
      report("failure", String(err && err.message ? err.message : err));
    });

  function loadDynamicPanels() {
    return new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "/js/dynamic-panels.js";
      s.onload = () => {
        try {
          window.LumenDynamicPanels.mount("#dynamic-panel-mount");
          resolve();
        } catch (e) {
          reject(e);
        }
      };
      s.onerror = () => reject(new Error("dynamic-panels script load failed"));
      document.head.appendChild(s);
    });
  }

  function detectBrowser(ua) {
    if (/Firefox\//.test(ua)) return "firefox";
    if (/Edg\//.test(ua)) return "edge";
    if (/Chrome\//.test(ua)) return "chrome";
    if (/Safari\//.test(ua)) return "safari";
    return "other";
  }

  function report(status, errorMessage) {
    const duration = Math.round(performance.now() - startTime);
    const payload = { page, browser, status, durationMs: duration };
    if (errorMessage) payload.error = errorMessage;
    navigator.sendBeacon
      ? navigator.sendBeacon("/api/telemetry", JSON.stringify(payload))
      : fetch("/api/telemetry", { method: "POST", body: JSON.stringify(payload), keepalive: true });
    if (status === "failure") {
      const fb = document.getElementById("static-fallback");
      if (fb) fb.hidden = false;
    }
  }
})();
