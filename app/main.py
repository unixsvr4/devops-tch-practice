"""
TCH DevOps Practice — Payment Service
Financial microservice: four golden signals, structured JSON logging, Prometheus metrics.
Simulates real payment processing with realistic error and latency distributions.
"""
import os
import time
import random
from datetime import datetime, timezone

import structlog
from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import (
    Counter, Histogram, Gauge,
    generate_latest, CONTENT_TYPE_LATEST,
)

# ── Structured JSON logging (stdout + file for ELK) ─────────────────────────
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)
log = structlog.get_logger()
LOG_FILE = os.getenv("LOG_FILE", "/logs/payment-service.log")


def _write_log(msg: str):
    print(msg, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


# ── Four Golden Signals ──────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total", "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5],
)
IN_FLIGHT = Gauge("http_requests_in_flight", "Requests currently in flight")

# Business metrics
PAYMENT_ERRORS   = Counter("payment_errors_total", "Payment errors by type", ["error_type"])
PAYMENT_AMOUNT   = Histogram("payment_amount_usd", "Payment amounts (USD)",
                             buckets=[10, 50, 100, 500, 1000, 5000, 10000])

app = FastAPI(title="tch-payment-service", version="1.0.0")


@app.middleware("http")
async def golden_signals_middleware(request: Request, call_next):
    IN_FLIGHT.inc()
    start = time.perf_counter()
    response = await call_next(request)
    duration = time.perf_counter() - start
    path = request.url.path
    REQUEST_COUNT.labels(
        method=request.method, endpoint=path, status_code=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(method=request.method, endpoint=path).observe(duration)
    IN_FLIGHT.dec()
    return response


@app.get("/health")
def health():
    return {"status": "ok", "service": "tch-payment-service"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/payments")
async def create_payment():
    amount = round(random.uniform(10, 9_999), 2)
    payment_id = f"PAY-{random.randint(100_000, 999_999)}"

    # 1.5% DB timeout — realistic for high-load payment processing
    if random.random() < 0.015:
        PAYMENT_ERRORS.labels(error_type="db_timeout").inc()
        _write_log(str({"level": "error", "event": "payment.db_timeout",
                        "payment_id": payment_id, "amount": amount}))
        raise HTTPException(status_code=500, detail="Payment processor timeout")

    time.sleep(random.uniform(0.05, 0.2))
    PAYMENT_AMOUNT.observe(amount)
    _write_log(str({"level": "info", "event": "payment.created",
                    "payment_id": payment_id, "amount": amount, "status": "pending"}))
    return {"payment_id": payment_id, "amount": amount, "status": "pending", "currency": "USD"}


@app.get("/api/payments/{payment_id}")
def get_payment(payment_id: str):
    if not payment_id.startswith("PAY-"):
        PAYMENT_ERRORS.labels(error_type="invalid_id").inc()
        raise HTTPException(status_code=404, detail="Payment not found")
    time.sleep(random.uniform(0.005, 0.03))
    statuses = ["completed"] * 7 + ["pending"] * 2 + ["failed"]
    status = random.choice(statuses)
    _write_log(str({"level": "info", "event": "payment.fetched",
                    "payment_id": payment_id, "status": status}))
    return {"payment_id": payment_id, "status": status,
            "updated_at": datetime.now(timezone.utc).isoformat()}


@app.get("/api/transactions")
def list_transactions():
    # 5% of requests hit a slow path — drives p99 latency demo in Grafana
    if random.random() < 0.05:
        time.sleep(random.uniform(0.45, 0.9))
    time.sleep(random.uniform(0.02, 0.1))
    _write_log(str({"level": "info", "event": "transactions.listed", "count": 25}))
    return {
        "transactions": [
            {"id": f"TXN-{i}", "amount": round(random.uniform(10, 5_000), 2),
             "status": "settled"} for i in range(1, 6)
        ]
    }


@app.get("/api/settlements")
def get_settlements():
    time.sleep(random.uniform(0.01, 0.06))
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    _write_log(str({"level": "info", "event": "settlements.fetched",
                    "settlement_date": today, "total": 1_247_832.50}))
    return {"settlement_date": today, "total_settled_usd": 1_247_832.50, "transaction_count": 1542}
