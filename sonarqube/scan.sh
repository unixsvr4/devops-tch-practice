#!/bin/bash
# Local SAST scan — SonarQube Community on Mac M1
# Run from repo root: bash sonarqube/scan.sh
#
# First run: ~2 min for SonarQube to start + DB to initialise.
# Subsequent runs: ~20s (containers already up).
#
# Scanner priority:
#   1. Native arm64 sonar-scanner (brew install sonar-scanner) — fastest
#   2. Docker sonar-scanner-cli (amd64, runs via Rosetta)      — no install needed

set -euo pipefail

SONAR_URL="http://localhost:9000"
SONAR_PASS="admin"
PROJECT_KEY="tch-payment-app"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/sonarqube/docker-compose.yml"

# ── [1] Start SonarQube if not running ───────────────────────────────────────
if ! docker compose -f "$COMPOSE_FILE" ps -q sonarqube 2>/dev/null | grep -q .; then
    echo "[1/4] Starting SonarQube + Postgres..."
    docker compose -f "$COMPOSE_FILE" up -d
else
    echo "[1/4] SonarQube already running."
fi

# ── [2] Wait for SonarQube to be UP ─────────────────────────────────────────
echo "[2/4] Waiting for SonarQube to be ready (up to ~2 min on first start)..."
until curl -sf "$SONAR_URL/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
    sleep 5; printf '.'
done
echo " UP."

# One-time: change default admin password (safe to re-run — fails silently if done)
curl -sf -u "admin:admin" -X POST "$SONAR_URL/api/users/change_password" \
    --data-urlencode "login=admin" \
    --data-urlencode "previousPassword=admin" \
    --data-urlencode "password=$SONAR_PASS" 2>/dev/null || true

# ── [3] Create project + generate token ─────────────────────────────────────
echo "[3/4] Configuring project '$PROJECT_KEY'..."

curl -sf -u "admin:$SONAR_PASS" -X POST "$SONAR_URL/api/projects/create" \
    --data-urlencode "project=$PROJECT_KEY" \
    --data-urlencode "name=TCH Payment Service" \
    --data-urlencode "visibility=public" 2>/dev/null || true

TOKEN=$(curl -sf -u "admin:$SONAR_PASS" -X POST "$SONAR_URL/api/user_tokens/generate" \
    --data-urlencode "name=scan-$(date +%s)" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# ── [4] Run the scanner ──────────────────────────────────────────────────────
echo "[4/4] Scanning app/..."

if command -v sonar-scanner &>/dev/null; then
    # Native arm64 via Homebrew — preferred on M1
    echo "  Using native sonar-scanner ($(sonar-scanner --version 2>&1 | head -1))"
    cd "$REPO_ROOT/app"
    sonar-scanner \
        -Dsonar.host.url="$SONAR_URL" \
        -Dsonar.token="$TOKEN" \
        -Dsonar.projectKey="$PROJECT_KEY" \
        -Dsonar.projectName="TCH Payment Service" \
        -Dsonar.sources="." \
        -Dsonar.language=py \
        -Dsonar.python.version=3.12 \
        -Dsonar.exclusions="**/__pycache__/**,**/*.pyc"
else
    # Fallback: Docker image (amd64, runs via Rosetta — works, ~30s slower)
    echo "  Using sonar-scanner-cli via Docker (amd64/Rosetta)"
    echo "  Tip: brew install sonar-scanner  ← gets you a native arm64 binary"
    docker run --rm \
        -v "$REPO_ROOT/app:/usr/src" \
        -v "$REPO_ROOT/sonarqube/sonar-project.properties:/usr/src/sonar-project.properties:ro" \
        -e SONAR_HOST_URL="http://host.docker.internal:9000" \
        -e SONAR_TOKEN="$TOKEN" \
        sonarsource/sonar-scanner-cli:latest
fi

echo ""
echo "Scan complete."
echo "Results  → $SONAR_URL/dashboard?id=$PROJECT_KEY"
echo "Login    → admin / $SONAR_PASS"
echo ""
echo "Quality Gate status:"
sleep 5   # give SonarQube a moment to compute the gate
curl -sf -u "admin:$SONAR_PASS" \
    "$SONAR_URL/api/qualitygates/project_status?projectKey=$PROJECT_KEY" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
status = d['projectStatus']['status']
icon = '✓' if status == 'OK' else '✗'
print(f'  {icon} Quality Gate: {status}')
for c in d['projectStatus'].get('conditions', []):
    if c['status'] != 'OK':
        print(f\"    FAILED: {c['metricKey']} = {c['actualValue']} (threshold {c['errorThreshold']})\")
" 2>/dev/null || echo "  (gate result not yet available — check the UI)"
echo ""
echo "Interview point: in CI the SONAR_TOKEN is a GitHub secret."
echo "The pipeline step uses 'sonar.qualitygate.wait=true' to block the build"
echo "if the Quality Gate fails — same as what .github/workflows/secure-pipeline.yml shows."
