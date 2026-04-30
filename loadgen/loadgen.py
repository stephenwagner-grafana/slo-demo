"""Lumen loadgen.

Simulates browsers (Chrome / Firefox / Safari) hitting frontend pages and reports
the resulting page_load outcome to /api/telemetry. The bug is reproduced in code:
when enableDynamicPanels is true AND the page needs dynamic panels AND the browser
is Firefox, the page_load fails (matches what real Firefox would do).
"""
from __future__ import annotations

import json
import logging
import os
import random
import sys
import time
import urllib.request

FRONTEND_URL = os.environ.get("FRONTEND_URL", "http://frontend.slo-demo.svc.cluster.local")
MIDDLEWARE_URL = os.environ.get(
    "MIDDLEWARE_URL", "http://middleware.slo-demo.svc.cluster.local:8000"
)
RPS = float(os.environ.get("RPS", "5"))

PAGES = [
    {"path": "/",             "name": "home",     "needsDynamicPanels": False},
    {"path": "/products.html","name": "products", "needsDynamicPanels": True},
    {"path": "/reports.html", "name": "reports",  "needsDynamicPanels": True},
    {"path": "/search.html",  "name": "search",   "needsDynamicPanels": False},
]

BROWSERS = [
    ("chrome",  0.50, "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
    ("firefox", 0.30, "Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0"),
    ("safari",  0.20, "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"),
]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("loadgen")


def pick_browser() -> tuple[str, str]:
    r = random.random()
    cum = 0.0
    for name, weight, ua in BROWSERS:
        cum += weight
        if r <= cum:
            return name, ua
    return BROWSERS[-1][0], BROWSERS[-1][2]


def fetch_config() -> bool:
    try:
        with urllib.request.urlopen(f"{MIDDLEWARE_URL}/api/config", timeout=2) as r:
            data = json.load(r)
            return bool(data.get("enableDynamicPanels", False))
    except Exception as e:
        log.warning("fetch_config failed: %s", e)
        return False


def fetch_page(page: dict, ua: str) -> int:
    req = urllib.request.Request(f"{FRONTEND_URL}{page['path']}", headers={"User-Agent": ua})
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            r.read()
        return int((time.time() - start) * 1000)
    except Exception as e:
        log.warning("fetch_page %s failed: %s", page["path"], e)
        return int((time.time() - start) * 1000)


def post_telemetry(page: str, browser: str, status: str, duration_ms: int, error: str | None):
    payload = {"page": page, "browser": browser, "status": status, "durationMs": duration_ms}
    if error:
        payload["error"] = error
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{MIDDLEWARE_URL}/api/telemetry",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=2).read()
    except Exception as e:
        log.warning("post_telemetry failed: %s", e)


def simulate_one():
    page = random.choice(PAGES)
    browser, ua = pick_browser()
    flag_on = fetch_config()
    duration = fetch_page(page, ua)

    if page["needsDynamicPanels"] and flag_on and browser == "firefox":
        post_telemetry(page["name"], browser, "failure", duration,
                       "TypeError: CSS.highlights is undefined")
    else:
        post_telemetry(page["name"], browser, "success", duration, None)


def main():
    interval = 1.0 / RPS if RPS > 0 else 1.0
    log.info("loadgen starting: frontend=%s middleware=%s rps=%.2f",
             FRONTEND_URL, MIDDLEWARE_URL, RPS)
    while True:
        try:
            simulate_one()
        except Exception:
            log.exception("simulate_one crashed")
        time.sleep(interval)


if __name__ == "__main__":
    sys.exit(main())
