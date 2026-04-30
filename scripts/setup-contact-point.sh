#!/usr/bin/env bash
# Creates / updates the Grafana Cloud webhook contact point that fires the
# investigator when the "Lumen Page Load Burn Rate" alert goes critical, and
# wires that alert's notification settings to use it.
#
# Required env:
#   GRAFANA_URL   e.g. https://stephenwagner.grafana.net
#   GRAFANA_TOKEN service-account token with alerting:write
#
# Reads the webhook shared secret from the cluster:
#   kubectl get secret investigator-secrets -n slo-demo -o jsonpath='{.data.WEBHOOK_TOKEN}' | base64 -d
set -euo pipefail

: "${GRAFANA_URL:?set GRAFANA_URL=https://<stack>.grafana.net}"
: "${GRAFANA_TOKEN:?set GRAFANA_TOKEN=glsa_...}"

CP_NAME="${CP_NAME:-slo-demo-investigator}"
WEBHOOK_URL="${WEBHOOK_URL:-https://slo-investigator.wombatwags.com/webhook}"
ALERT_UID="${ALERT_UID:-ffklwrcpdmdq8d}"

WEBHOOK_TOKEN=$(kubectl get secret investigator-secrets -n slo-demo \
  -o jsonpath='{.data.WEBHOOK_TOKEN}' | base64 -d)

echo "Creating webhook contact point '${CP_NAME}' -> ${WEBHOOK_URL}"
curl -fsS -X POST "${GRAFANA_URL%/}/api/v1/provisioning/contact-points" \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Disable-Provenance: true" \
  -d @- <<JSON
{
  "name": "${CP_NAME}",
  "type": "webhook",
  "settings": {
    "url": "${WEBHOOK_URL}",
    "httpMethod": "POST",
    "headers": {
      "X-Webhook-Token": "${WEBHOOK_TOKEN}"
    }
  },
  "disableResolveMessage": false
}
JSON
echo

echo "Wiring alert ${ALERT_UID} -> contact point ${CP_NAME}"
# Read existing rule, patch notification_settings.receiver, PUT it back.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsS "${GRAFANA_URL%/}/api/v1/provisioning/alert-rules/${ALERT_UID}" \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" >"$tmp"

python3 - "$tmp" "$CP_NAME" <<'PY'
import json, sys
path, receiver = sys.argv[1], sys.argv[2]
with open(path) as f:
    rule = json.load(f)
rule["notification_settings"] = {"receiver": receiver}
with open(path, "w") as f:
    json.dump(rule, f)
PY

curl -fsS -X PUT "${GRAFANA_URL%/}/api/v1/provisioning/alert-rules/${ALERT_UID}" \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Disable-Provenance: true" \
  --data @"$tmp" >/dev/null
echo "Done."
