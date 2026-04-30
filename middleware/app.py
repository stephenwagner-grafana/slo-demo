"""Lumen Analytics middleware.

Exposes:
  GET  /api/config       -> feature flags (read from FLAGS_FILE configmap mount)
  GET  /api/products     -> products list (postgres)
  GET  /api/reports      -> reports list (postgres)
  POST /api/telemetry    -> page_load outcome from frontend / loadgen
  GET  /metrics          -> Prometheus exposition
  GET  /healthz          -> liveness

OTel traces and logs are exported to OTLP (Alloy at $OTEL_EXPORTER_OTLP_ENDPOINT).
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import psycopg
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "lumen-middleware")
FLAGS_FILE = Path(os.environ.get("FLAGS_FILE", "/etc/flags/flags.json"))
PG_DSN = os.environ.get(
    "PG_DSN", "postgresql://lumen:lumen@postgres.slo-demo.svc.cluster.local:5432/lumen"
)

resource = Resource.create({"service.name": SERVICE_NAME})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
LoggingInstrumentor().instrument(set_logging_format=True, log_level=logging.INFO)
log = logging.getLogger("lumen-middleware")
tracer = trace.get_tracer(SERVICE_NAME)

PAGE_LOADS = Counter(
    "page_loads_total",
    "Frontend page load outcomes",
    ["page", "browser", "status"],
)
PAGE_LOAD_DURATION = Histogram(
    "page_load_duration_ms",
    "Frontend-reported page load duration in ms",
    ["page", "browser"],
    buckets=(50, 100, 250, 500, 1000, 2500, 5000, 10000),
)
DB_QUERIES = Counter("db_queries_total", "Postgres queries", ["query", "status"])

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)


def read_flags() -> dict:
    try:
        return json.loads(FLAGS_FILE.read_text())
    except FileNotFoundError:
        return {"enableDynamicPanels": False}


def db_query(sql: str, label: str):
    with tracer.start_as_current_span(f"db.{label}"):
        try:
            with psycopg.connect(PG_DSN, connect_timeout=3) as conn:
                with conn.cursor() as cur:
                    cur.execute(sql)
                    rows = cur.fetchall()
                    cols = [d[0] for d in cur.description]
                    DB_QUERIES.labels(query=label, status="success").inc()
                    return [dict(zip(cols, r)) for r in rows]
        except Exception as e:
            DB_QUERIES.labels(query=label, status="error").inc()
            log.exception("db query %s failed", label)
            raise


@app.get("/api/config")
def get_config():
    flags = read_flags()
    return {"enableDynamicPanels": bool(flags.get("enableDynamicPanels", False))}


@app.get("/api/products")
def get_products():
    rows = db_query("SELECT id, name, price FROM products ORDER BY id", "products")
    return {"products": rows}


@app.get("/api/reports")
def get_reports():
    rows = db_query(
        "SELECT id, title, generated_at FROM reports ORDER BY generated_at DESC LIMIT 25",
        "reports",
    )
    return {"reports": rows}


@app.post("/api/telemetry")
async def telemetry(request: Request):
    body = await request.body()
    try:
        data = json.loads(body or b"{}")
    except json.JSONDecodeError:
        return JSONResponse({"error": "bad json"}, status_code=400)
    page = str(data.get("page", "unknown"))
    browser = str(data.get("browser", "other"))
    status = str(data.get("status", "unknown"))
    duration = data.get("durationMs")
    PAGE_LOADS.labels(page=page, browser=browser, status=status).inc()
    if isinstance(duration, (int, float)):
        PAGE_LOAD_DURATION.labels(page=page, browser=browser).observe(duration)
    if status == "failure":
        log.warning(
            "page_load_failure page=%s browser=%s error=%s",
            page,
            browser,
            data.get("error"),
        )
    return {"ok": True}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/healthz")
def healthz():
    return {"ok": True}
