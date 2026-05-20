#!/bin/bash
# Generate steady payment traffic so golden signals appear in Grafana
BASE="${1:-http://localhost:8080}"
echo "Sending payment traffic to $BASE — Ctrl+C to stop"
echo "Grafana → http://localhost:3000  (admin/admin) → Payment SLOs — TCH"
PAY_IDS=("PAY-100001" "PAY-200002" "PAY-300003" "INVALID-999")
while true; do
    curl -sf -X POST "$BASE/api/payments"                              > /dev/null
    curl -sf "$BASE/api/payments/${PAY_IDS[$((RANDOM % 4))]}"         > /dev/null
    curl -sf "$BASE/api/transactions"                                  > /dev/null
    curl -sf "$BASE/api/settlements"                                   > /dev/null
    sleep 0.4
done
