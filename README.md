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
- `grafana-cloud-credentials` secret in the `fake-shop` namespace — `deploy.sh`
  copies it into `slo-demo`.

```bash
./deploy.sh
```

Then populate the investigator secret:

```bash
kubectl create secret generic investigator-secrets -n slo-demo \
  --from-literal=GITHUB_TOKEN=ghp_xxx \
  --from-literal=GRAFANA_URL=https://yourstack.grafana.net \
  --from-literal=GRAFANA_TOKEN=glsa_xxx \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Manual flag toggle

```bash
kubectl patch configmap lumen-flags -n slo-demo --type merge \
  -p '{"data":{"flags.json":"{\n  \"enableDynamicPanels\": true\n}\n"}}'
kubectl rollout restart deployment/middleware -n slo-demo
```
