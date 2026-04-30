#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "══════════════════════════════════════════════════════"
echo "  Deploying SLO Investigation Demo"
echo "══════════════════════════════════════════════════════"

echo "[1/8] Namespace..."
kubectl create namespace slo-demo --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[2/8] Copying grafana-cloud-credentials secret..."
kubectl get secret grafana-cloud-credentials -n fake-shop -o json \
  | python3 -c "
import json, sys
s = json.load(sys.stdin)
s['metadata'] = {'name': 'grafana-cloud-credentials', 'namespace': 'slo-demo'}
json.dump(s, sys.stdout)
" | kubectl apply -f - >/dev/null

echo "[3/8] Source configmaps..."

kubectl create configmap postgres-init -n slo-demo \
  --from-file=init.sql=postgres/init.sql \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap middleware-src -n slo-demo \
  --from-file=app.py=middleware/app.py \
  --from-file=requirements.txt=middleware/requirements.txt \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap frontend-html -n slo-demo \
  --from-file=index.html=frontend/index.html \
  --from-file=products.html=frontend/products.html \
  --from-file=reports.html=frontend/reports.html \
  --from-file=search.html=frontend/search.html \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap frontend-css -n slo-demo \
  --from-file=styles.css=frontend/css/styles.css \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap frontend-js -n slo-demo \
  --from-file=app.js=frontend/js/app.js \
  --from-file=dynamic-panels.js=frontend/js/dynamic-panels.js \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap loadgen-src -n slo-demo \
  --from-file=loadgen.py=loadgen/loadgen.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap investigator-src -n slo-demo \
  --from-file=app.py=investigator/app.py \
  --from-file=requirements.txt=investigator/requirements.txt \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[4/8] Investigator secret stub..."
if ! kubectl get secret investigator-secrets -n slo-demo >/dev/null 2>&1; then
  kubectl create secret generic investigator-secrets -n slo-demo \
    --from-literal=GITHUB_TOKEN=placeholder-set-me \
    --from-literal=GRAFANA_URL=https://stephenwagner.grafana.net \
    --from-literal=GRAFANA_TOKEN=placeholder-set-me >/dev/null
fi

echo "[5/8] Applying main manifests..."
kubectl apply -f manifests/k8s-manifests.yaml >/dev/null

echo "[6/8] Applying Alloy..."
kubectl apply -f alloy/alloy.yaml >/dev/null

echo "[7/8] Restarting deployments..."
for d in postgres middleware frontend loadgen investigator alloy; do
  kubectl rollout restart deployment/$d -n slo-demo 2>/dev/null || true
done

echo "[8/8] Waiting for rollouts..."
for d in postgres middleware frontend alloy investigator; do
  kubectl rollout status deployment/$d -n slo-demo --timeout=90s 2>&1 | sed 's/^/    /'
done

echo ""
echo "  Frontend:     kubectl port-forward -n slo-demo svc/frontend 8080:80"
echo "  Investigator: kubectl port-forward -n slo-demo svc/investigator 8080:8080"
echo ""
kubectl get pods -n slo-demo
