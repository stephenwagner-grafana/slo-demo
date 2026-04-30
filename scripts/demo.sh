#!/usr/bin/env bash
# Lumen Analytics SLO investigation demo — interactive runner.
#
# Walks an audience through:
#   0. Reset state (flag off in repo + cluster, close any prior auto-PRs/issues)
#   1. Show the healthy SLI on the dashboard
#   2. "An engineer ships enableDynamicPanels=true" — push to GitHub + apply to cluster
#   3. Watch the SLI break for Firefox sessions
#   4. The 99.5%/30d burn-rate alert fires → webhook → investigator
#   5. Sift correlation summary, rollback PR opened, tracking issue filed
#   6. Merge the PR; SLI recovers
#
# At each step the script pauses for ENTER so the presenter can narrate.
#
# Required: kubectl context on the slo-demo cluster, gh auth, jq.
# Optional env: AUTO_ADVANCE=1 (no pauses), CLEAN_ONLY=1 (only step 0).
set -euo pipefail

REPO="${REPO:-stephenwagner-grafana/slo-demo}"
NS="${NS:-slo-demo}"
CONFIGMAP_PATH="${CONFIGMAP_PATH:-manifests/configmap-flags.yaml}"
DASHBOARD_URL="${DASHBOARD_URL:-https://stephenwagner.grafana.net/d/slo-demo-overview/lumen-analytics-slo}"
ALERT_URL="${ALERT_URL:-https://stephenwagner.grafana.net/alerting/grafana/ffklwrcpdmdq8d/view}"
SITE_URL="${SITE_URL:-http://lumen.wombatwags.com}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
gray()  { printf '\033[90m%s\033[0m\n' "$*"; }

pause() {
  if [ "${AUTO_ADVANCE:-0}" = "1" ]; then sleep 2; return; fi
  read -r -p "$(printf '\033[1m▶ %s — press ENTER\033[0m' "$1")" _ </dev/tty
}

step() { echo; bold "═══ $* ═══"; }

current_flag() {
  kubectl get configmap lumen-flags -n "$NS" \
    -o jsonpath='{.data.flags\.json}' | grep -oE 'true|false' | head -1
}

current_error_rate() {
  kubectl exec -n "$NS" deployment/middleware -- python3 -c '
import json, urllib.request
m = urllib.request.urlopen("http://localhost:8000/metrics", timeout=2).read().decode()
total = success = 0.0
for line in m.splitlines():
    if line.startswith("page_loads_total{"):
        v = float(line.rsplit(" ", 1)[1])
        total += v
        if "status=\"success\"" in line: success += v
print(f"{(1 - success/total)*100:.2f}" if total else "0.00")
' 2>/dev/null
}

set_flag_in_repo() {
  local target=$1   # true|false
  local sha
  sha=$(gh api "repos/${REPO}/contents/${CONFIGMAP_PATH}" --jq .sha)
  local content
  content=$(gh api "repos/${REPO}/contents/${CONFIGMAP_PATH}" --jq .content | base64 -d)
  local new
  new=$(echo "$content" | sed -E "s/(\"enableDynamicPanels\":[[:space:]]*)(true|false)/\1${target}/")
  if [ "$content" = "$new" ]; then echo "  repo already has enableDynamicPanels: ${target}"; return; fi
  echo "$new" | base64 -w 0 | python3 -c '
import json, sys
sha=sys.argv[1]; target=sys.argv[2]
print(json.dumps({"message": f"Set enableDynamicPanels={target}", "content": sys.stdin.read().strip(), "sha": sha}))
' "$sha" "$target" | gh api --method PUT "repos/${REPO}/contents/${CONFIGMAP_PATH}" --input - >/dev/null
  echo "  pushed enableDynamicPanels=${target} to ${REPO}"
}

apply_flag_to_cluster() {
  local target=$1
  kubectl patch configmap lumen-flags -n "$NS" --type=merge \
    -p "{\"data\":{\"flags.json\":\"{\\n  \\\"enableDynamicPanels\\\": ${target}\\n}\\n\"}}" >/dev/null
  kubectl rollout restart deployment/middleware -n "$NS" >/dev/null
  kubectl rollout status deployment/middleware -n "$NS" --timeout=90s >/dev/null
  echo "  middleware rolled out with enableDynamicPanels=${target}"
}

close_open_auto_prs() {
  gh pr list -R "$REPO" --state open --search "investigator/revert-dynamic-panels" --json number --jq '.[].number' \
    | while read -r n; do gh pr close "$n" -R "$REPO" --delete-branch >/dev/null && echo "  closed PR #${n}"; done
  gh issue list -R "$REPO" --state open --label auto-filed --json number --jq '.[].number' \
    | while read -r n; do gh issue close "$n" -R "$REPO" >/dev/null && echo "  closed issue #${n}"; done
}

# -----------------------------------------------------------------------------
# Step 0 — reset
# -----------------------------------------------------------------------------
step "0. Reset state"
gray "  Site:      $SITE_URL"
gray "  Dashboard: $DASHBOARD_URL"
gray "  Alert:     $ALERT_URL"
echo
echo "  Flipping flag OFF (repo + cluster) and closing prior auto PRs/issues…"
set_flag_in_repo false
apply_flag_to_cluster false
close_open_auto_prs
echo
echo "  Current cluster flag: $(current_flag)"
echo "  Current error rate:   $(current_error_rate)%"

if [ "${CLEAN_ONLY:-0}" = "1" ]; then green "Clean-only mode — exiting."; exit 0; fi

pause "Open the dashboard and the alert — show all-green baseline"

# -----------------------------------------------------------------------------
# Step 1 — narrate the SLO
# -----------------------------------------------------------------------------
step "1. The SLO"
cat <<EOF
  Lumen Analytics has a 99.5%/30-day uptime SLO governed by page-load success
  rate. Loadgen sends a steady mix of Chrome (50%), Firefox (30%), Safari (20%)
  across 4 pages — 2 of which need the new "dynamic panels" feature.

  SLI:  sum(rate(page_loads_total{status="success"}[5m]))
       / sum(rate(page_loads_total[5m]))
EOF
pause "Move on to the change"

# -----------------------------------------------------------------------------
# Step 2 — engineer ships a change
# -----------------------------------------------------------------------------
step "2. An engineer ships enableDynamicPanels=true"
echo "  This is the change going to GitHub:"
echo
gray "    # manifests/configmap-flags.yaml"
gray "    -      \"enableDynamicPanels\": false"
gray "    +      \"enableDynamicPanels\": true"
echo
pause "Push to repo + apply to cluster"
set_flag_in_repo true
apply_flag_to_cluster true

# -----------------------------------------------------------------------------
# Step 3 — watch SLI break
# -----------------------------------------------------------------------------
step "3. SLI degrades — Firefox sessions hit TypeError"
echo "  Tailing error rate for ~3 minutes (sampled every 15s)…"
for i in $(seq 1 12); do
  printf "    %s  error rate: " "$(date +%H:%M:%S)"
  rate=$(current_error_rate)
  if (( $(echo "$rate >= 5" | bc -l) )); then red "${rate}%  ⚠ above SLO threshold"
  elif (( $(echo "$rate >= 1" | bc -l) )); then printf '\033[33m%s%%\033[0m\n' "$rate"
  else green "${rate}%"; fi
  sleep 15
done
pause "Switch to alert view — should be Pending or Firing"

# -----------------------------------------------------------------------------
# Step 4 — alert fires; investigator runs
# -----------------------------------------------------------------------------
step "4. Burn-rate alert fires → webhook → investigator"
cat <<EOF
  The alert webhook hits the investigator service in-cluster:
    POST https://slo-investigator.wombatwags.com/webhook
    headers: X-Webhook-Token: <shared secret>

  The investigator:
    1. Triggers a Sift investigation (Grafana ML).
    2. Reads back the correlation: Firefox + flag flip.
    3. Opens a PR reverting manifests/configmap-flags.yaml.
    4. Files a tracking issue describing the proper Firefox-compat fix.
EOF
pause "Watch the investigator log + GitHub for the new PR"

echo "  Tail of investigator logs:"
gray "  ────────────────────────────"
kubectl logs -n "$NS" deployment/investigator --tail=20 | sed 's/^/    /'
echo
echo "  Open PRs:"
gh pr list -R "$REPO" --state open --json number,title,url \
  --jq '.[] | "    #\(.number)  \(.title)\n    \(.url)"' || echo "    (none yet — alert may still be Pending)"
echo
echo "  Open auto-filed issues:"
gh issue list -R "$REPO" --state open --label auto-filed --json number,title,url \
  --jq '.[] | "    #\(.number)  \(.title)\n    \(.url)"' || echo "    (none yet)"

pause "Show the PR description + Sift summary"

# -----------------------------------------------------------------------------
# Step 5 — merge + recovery
# -----------------------------------------------------------------------------
step "5. Merge the rollback PR; SLI recovers"
pr=$(gh pr list -R "$REPO" --state open --search "investigator/revert-dynamic-panels" --json number --jq '.[0].number' || echo "")
if [ -n "$pr" ] && [ "$pr" != "null" ]; then
  echo "  Merging PR #${pr}…"
  gh pr merge "$pr" -R "$REPO" --squash --delete-branch
  echo "  Applying the reverted configmap to the cluster (simulating CD)…"
  apply_flag_to_cluster false
else
  red "  No open auto-PR found. If the alert hasn't fired yet, wait and re-run from step 4."
  apply_flag_to_cluster false
fi

echo
echo "  Tailing recovery for ~2 minutes…"
for i in $(seq 1 8); do
  printf "    %s  error rate: " "$(date +%H:%M:%S)"
  rate=$(current_error_rate)
  if (( $(echo "$rate >= 5" | bc -l) )); then red "${rate}%"
  elif (( $(echo "$rate >= 1" | bc -l) )); then printf '\033[33m%s%%\033[0m\n' "$rate"
  else green "${rate}%  ✓ recovered"; fi
  sleep 15
done

green "Demo complete."
