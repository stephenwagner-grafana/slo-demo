# slo-demo

Grafana Cloud SLO investigation demo. A multi-tier "Lumen Analytics" website runs in
k3s (frontend → middleware → postgres) with a 99.5%/30-day uptime SLO governed by
page-load success rate. A `enableDynamicPanels` feature flag, when toggled on,
breaks Firefox sessions because the dynamic-panels module uses `CSS.highlights` —
a Chromium-only API.

## Story

1. CronJob flips `enableDynamicPanels` every 6h.
2. When `true`, Firefox sessions hit `TypeError: CSS.highlights is undefined` on
   pages that render dynamic panels (~50% of pages).
3. SLI (`page_loads_total{status="success"} / page_loads_total`) drops; multi-window
   multi-burn-rate alert fires.
4. Alert webhook hits the `investigator` service.
5. Investigator triggers a Sift investigation (Grafana ML), reads back the
   correlation (Firefox + recent flag flip), and:
   - Opens a GitHub PR against `manifests/configmap-flags.yaml` reverting the flag.
   - Files a tracking issue describing the proper Firefox-compat fix.
6. Knowledge graph in Grafana shows frontend → middleware → postgres dependency.
7. SRE merges the PR; SLI recovers.

## Components

| Path | What it is |
|---|---|
| `frontend/` | nginx-served multi-page SPA + the planted `dynamic-panels.js` bug |
| `middleware/` | Python FastAPI, OTel-instrumented, postgres-backed |
| `postgres/` | `init.sql` for sample data |
| `loadgen/` | Python, mixed Chrome/Firefox/Safari user-agents — drives the SLI |
| `alloy/` | OTel collector + Prom scrape + log tailing → Grafana Cloud |
| `investigator/` | Webhook → Sift → GitHub PR + tracking issue |
| `manifests/` | k8s resources, RBAC, CronJob, configmap-flags.yaml |

## Deploy

Requires:
- A k3s/k8s cluster
- `grafana-cloud-credentials` secret in the `fake-shop` namespace (see
  [Grafana Cloud creds spec](#grafana-cloud-credentials-format)) — `deploy.sh`
  copies it into `slo-demo`.

```bash
./deploy.sh
```

Then populate the investigator secret. `WEBHOOK_TOKEN` is a shared secret the
Grafana contact point sends in the `X-Webhook-Token` header:

```bash
WEBHOOK_TOKEN=$(openssl rand -hex 24)
kubectl create secret generic investigator-secrets -n slo-demo \
  --from-literal=GITHUB_TOKEN=ghp_xxx \
  --from-literal=GRAFANA_URL=https://yourstack.grafana.net \
  --from-literal=GRAFANA_TOKEN=glsa_xxx \
  --from-literal=WEBHOOK_TOKEN="$WEBHOOK_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Wire the alert to the investigator

The alert rule (`Lumen Page Load Burn Rate`, UID `ffklwrcpdmdq8d`) lives in
Grafana Cloud. To create the webhook contact point and route the alert there:

```bash
export GRAFANA_URL=https://yourstack.grafana.net
export GRAFANA_TOKEN=glsa_xxx        # service-account token with alerting:write
./scripts/setup-contact-point.sh
```

This creates the `slo-demo-investigator` contact point and sets the alert's
notification settings to use it. It pulls the shared webhook secret from the
in-cluster `investigator-secrets`.

## Manual flag toggle

```bash
# turn on (triggers the cascade)
kubectl patch configmap lumen-flags -n slo-demo --type merge \
  -p '{"data":{"flags.json":"{\n  \"enableDynamicPanels\": true\n}\n"}}'
kubectl rollout restart deployment/middleware -n slo-demo
```

## Grafana Cloud credentials format

The secret in `fake-shop` is shaped like:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-cloud-credentials
type: Opaque
stringData:
  GRAFANA_CLOUD_API_KEY:         glc_...
  GRAFANA_CLOUD_INSTANCE_ID:     "1372178"
  GRAFANA_CLOUD_LOKI_URL:        https://logs-prod-036.grafana.net/loki/api/v1/push
  GRAFANA_CLOUD_LOKI_USER:       "1329972"
  GRAFANA_CLOUD_OTLP_ENDPOINT:   https://otlp-gateway-prod-us-east-2.grafana.net/otlp
  GRAFANA_CLOUD_PROMETHEUS_URL:  https://prometheus-prod-56-prod-us-east-2.grafana.net/api/prom/push
  GRAFANA_CLOUD_PROMETHEUS_USER: "2668591"
```
