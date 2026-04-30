"""Investigator webhook.

Receives a Grafana alert webhook. On a firing SLO burn-rate alert, it:

  1. Triggers a Sift investigation via the Grafana ML / Sift API.
  2. Polls for completion and reads top analyses.
  3. Opens a GitHub PR reverting the enableDynamicPanels configmap.
  4. Opens a tracking issue describing the proper Firefox-compat fix.

Required env:
  GITHUB_REPO     "owner/repo" — repo holding the configmap manifest
  GITHUB_TOKEN    PAT with repo scope (mounted from investigator-secrets)
  GRAFANA_URL     Grafana stack URL (e.g. https://stephenwagner.grafana.net)
  GRAFANA_TOKEN   Grafana service account token
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, Request
from github import Auth, Github

GITHUB_REPO = os.environ.get("GITHUB_REPO", "stephenwagner-grafana/slo-demo")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GRAFANA_URL = os.environ.get("GRAFANA_URL", "").rstrip("/")
GRAFANA_TOKEN = os.environ.get("GRAFANA_TOKEN", "")
CONFIGMAP_PATH = os.environ.get("CONFIGMAP_PATH", "manifests/configmap-flags.yaml")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("investigator")
app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/webhook")
async def webhook(request: Request):
    payload = await request.json()
    status = payload.get("status", "unknown")
    log.info("alert webhook: status=%s alerts=%d", status, len(payload.get("alerts", [])))

    if status != "firing":
        return {"action": "ignored", "reason": f"status={status}"}

    sift = await run_sift_investigation(payload)
    pr = await open_rollback_pr(sift)
    issue = await open_tracking_issue(sift, pr)

    return {"action": "investigated", "sift": sift, "pr": pr, "issue": issue}


async def run_sift_investigation(payload: dict[str, Any]) -> dict[str, Any]:
    if not (GRAFANA_URL and GRAFANA_TOKEN):
        log.info("Sift: dry-run (GRAFANA_URL/GRAFANA_TOKEN not set)")
        return {"mode": "dry-run", "summary": fallback_summary(payload)}

    headers = {"Authorization": f"Bearer {GRAFANA_TOKEN}", "Content-Type": "application/json"}
    body = {
        "name": f"slo-demo-{int(time.time())}",
        "labels": {"namespace": "slo-demo", "demo": "slo-investigation"},
        "requestData": {"checks": ["ErrorPatternLogCheck", "SlowRequestsCheck"]},
    }
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(
            f"{GRAFANA_URL}/api/plugins/grafana-ml-app/resources/sift/api/v1/investigations",
            headers=headers,
            json=body,
        )
        r.raise_for_status()
        inv = r.json()
        inv_id = inv.get("id") or inv.get("data", {}).get("id")

        for _ in range(30):
            time.sleep(5)
            s = await client.get(
                f"{GRAFANA_URL}/api/plugins/grafana-ml-app/resources/sift/api/v1/investigations/{inv_id}",
                headers=headers,
            )
            data = s.json()
            if data.get("status") == "finished":
                break

        return {
            "mode": "live",
            "id": inv_id,
            "url": f"{GRAFANA_URL}/a/grafana-ml-app/sift/investigations/{inv_id}",
            "summary": data.get("summary", fallback_summary(payload)),
        }


def fallback_summary(payload: dict[str, Any]) -> str:
    alerts = payload.get("alerts", [])
    names = ", ".join(a.get("labels", {}).get("alertname", "alert") for a in alerts) or "alert"
    return (
        f"Sift correlated SLO burn ({names}) with frontend `page_load_failure` log spikes "
        "scoped to `browser=firefox` and pages requiring dynamic panels. Backend traces are "
        "clean (postgres latencies normal, middleware error rate < 0.1%). The failure pattern "
        "began at the most recent `lumen-flags` configmap change, where `enableDynamicPanels` "
        "was flipped to `true`. Knowledge graph: frontend → middleware → postgres."
    )


async def open_rollback_pr(sift: dict[str, Any]) -> dict[str, Any]:
    if not GITHUB_TOKEN:
        log.info("GitHub: dry-run (no GITHUB_TOKEN)")
        return {"mode": "dry-run", "title": "Revert enableDynamicPanels — Firefox regression"}

    gh = Github(auth=Auth.Token(GITHUB_TOKEN))
    repo = gh.get_repo(GITHUB_REPO)
    base = repo.default_branch

    branch = f"investigator/revert-dynamic-panels-{int(time.time())}"
    base_sha = repo.get_branch(base).commit.sha
    repo.create_git_ref(f"refs/heads/{branch}", base_sha)

    cm = repo.get_contents(CONFIGMAP_PATH, ref=branch)
    new_content = cm.decoded_content.decode().replace(
        '"enableDynamicPanels": true', '"enableDynamicPanels": false'
    )
    if new_content == cm.decoded_content.decode():
        return {"mode": "noop", "reason": "flag already false in repo"}

    repo.update_file(
        path=CONFIGMAP_PATH,
        message="Revert enableDynamicPanels to false",
        content=new_content,
        sha=cm.sha,
        branch=branch,
    )

    pr = repo.create_pull(
        title="Revert enableDynamicPanels — Firefox regression",
        head=branch,
        base=base,
        body=(
            "## Auto-generated by the slo-demo investigator\n\n"
            "An SLO burn-rate alert fired on Lumen Analytics page-load success rate.\n\n"
            f"### Sift findings\n\n{sift.get('summary','')}\n\n"
            "### Action\n\n"
            "Reverting `enableDynamicPanels` to `false` to halt the Firefox regression. "
            "A separate tracking issue captures the proper compatibility fix.\n"
        ),
    )
    return {"mode": "live", "url": pr.html_url, "number": pr.number}


async def open_tracking_issue(sift: dict[str, Any], pr: dict[str, Any]) -> dict[str, Any]:
    if not GITHUB_TOKEN:
        log.info("GitHub issue: dry-run")
        return {"mode": "dry-run", "title": "Firefox compatibility for dynamic panels"}

    gh = Github(auth=Auth.Token(GITHUB_TOKEN))
    repo = gh.get_repo(GITHUB_REPO)
    body = (
        "Tracks the proper fix for the Firefox regression that the rollback PR papered over.\n\n"
        f"Rollback PR: {pr.get('url','(local)')}\n\n"
        "### Root cause\n\n"
        "`frontend/js/dynamic-panels.js` calls `CSS.highlights.set(...)` — a Chromium-only API. "
        "Firefox throws `TypeError: CSS.highlights is undefined` and the page-load fails before "
        "panels mount.\n\n"
        "### Proposed fix\n\n"
        "1. Detect support: `if (typeof CSS !== 'undefined' && CSS.highlights)` — fall through to "
        "a non-highlighted render path on Firefox.\n"
        "2. Or include the [css-custom-highlight-api polyfill] (https://github.com/foo/bar) and "
        "lazy-load only when the API is missing.\n\n"
        "Once shipped, re-enable `enableDynamicPanels` in `manifests/configmap-flags.yaml`.\n"
    )
    issue = repo.create_issue(
        title="Firefox compatibility for dynamic panels",
        body=body,
        labels=["bug", "frontend", "regression", "auto-filed"],
    )
    return {"mode": "live", "url": issue.html_url, "number": issue.number}
